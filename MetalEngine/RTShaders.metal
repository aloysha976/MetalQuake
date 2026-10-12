//
//  RTShaders.metal
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#include <metal_stdlib>
#include <metal_raytracing>
#include "MetalBridge.h"
#include "PBRShaders.h"

using namespace metal;
using namespace metal::raytracing;

struct GpuDlight {
    float4 posRadius;
    float4 rgbPad;
};

#define MQ_GPU_DLIGHTS 32

struct WorldUniforms {
    float4x4 mvpMatrix;
    int useTexture;
    int useLightmap;
    int isTurbulent;
    float time;
    float4 fogColorDensity;
    float4 cameraOriginPad;
    int numDlights;
    int pbrEnabled;
    int pbrDebug;
    int useGlow;
    GpuDlight dlights[MQ_GPU_DLIGHTS];
};

struct WorldVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 lightmapCoord;
    float4 color;
    float3 worldPos;
    float3 normal;
    float4 tangent;
    float  fogDistance;
};

// ======================================================================
// 1. Static BSP World Bindless Shader (Single Draw Call with Hardware RT Shadows)
// ======================================================================
fragment float4 world_static_rt_fragment_main(
                                              WorldVertexOut in [[stage_in]],
                                              array<texture2d<float>, 96> diffuseTextures  [[texture(0)]],
                                              array<texture2d<float>, 32> lightmapTextures [[texture(96)]],
                                              sampler textureSampler [[sampler(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              instance_acceleration_structure tlas [[buffer(2)]])
{
    uint texIdx = clamp(uint(in.color.r + 0.5f), 0u, 95u);
    uint lmIdx  = clamp(uint(in.color.g + 0.5f), 0u, 31u);
    
    float4 texColor = diffuseTextures[texIdx].sample(textureSampler, in.texCoord);
    float4 lmColor  = lightmapTextures[lmIdx].sample(textureSampler, in.lightmapCoord);
    
    float4 color;
    color.rgb = texColor.rgb * lmColor.rgb * 2.0f;
    color.a   = 1.0f;
    
    // Hardware ray-traced visibility rays for dynamic lights (dlights)
    if (uniforms.numDlights > 0) {
        float3 N = normalize(in.normal);
        float3 dynLight = float3(0.0f);
        
        for (int i = 0; i < uniforms.numDlights; i++) {
            float3 lpos   = uniforms.dlights[i].posRadius.xyz;
            float  radius = uniforms.dlights[i].posRadius.w;
            float3 toLight = lpos - in.worldPos;
            
            float distSq = dot(toLight, toLight);
            if (distSq >= radius * radius || distSq < 1e-6f)
                continue;
            
            float dist = sqrt(distSq);
            float3 L = toLight / dist;
            float NdotL = max(dot(N, L), 0.0f);
            if (NdotL <= 0.0f)
                continue;
            
            // --- Hardware Shadow Ray ---
            float3 rayOrigin = in.worldPos + N * 0.5f;
            float3 rayToLight = lpos - rayOrigin;
            float rayDist = length(rayToLight);
            
            if (rayDist >= 0.6f) {
                ray shadowRay;
                shadowRay.origin = rayOrigin;
                shadowRay.direction = rayToLight / rayDist;
                shadowRay.min_distance = 0.1f;
                shadowRay.max_distance = max(rayDist - 0.5f, 0.15f);
                
                intersector<instancing> inter;
                inter.assume_geometry_type(geometry_type::triangle);
                inter.force_opacity(forced_opacity::opaque);
                inter.accept_any_intersection(true); // Any-hit: any valid occluder confirms shadow
                
                auto result = inter.intersect(shadowRay, tlas);
                if (result.type != intersection_type::none) {
                    // Occluder found: surface point is in shadow from explosion/projectile
                    continue;
                }
            }
            
            float atten = (1.0f - dist / radius) * NdotL;
            dynLight += uniforms.dlights[i].rgbPad.xyz * atten;
        }
        color.rgb += texColor.rgb * dynLight * 2.0f;
    }
    
    // Volumetric exponential fog
    if (uniforms.fogColorDensity.w > 0.0f) {
        float dist = in.fogDistance;
        float fogFactor = exp2(-uniforms.fogColorDensity.w * uniforms.fogColorDensity.w *
                               dist * dist * 1.4426950408889634f);
        color.rgb = mix(uniforms.fogColorDensity.xyz, color.rgb, clamp(fogFactor, 0.0f, 1.0f));
    }
    
    return color;
}

// ======================================================================
// 2. Forward RT Shader (Doors, Moving Platforms, and Submodels)
// ======================================================================
fragment float4 world_rt_fragment_main(
                                       WorldVertexOut in [[stage_in]],
                                       texture2d<float> baseTexture [[texture(TextureIndexBase)]],
                                       texture2d<float> lightmapTexture [[texture(TextureIndexLightmap)]],
                                       texture2d<float> normalTexture [[texture(TextureIndexNormal)]],
                                       texture2d<float> rmaoTexture [[texture(TextureIndexRMAO)]],
                                       texture2d<float> emissionTexture [[texture(TextureIndexEmission)]],
                                       sampler textureSampler [[sampler(0)]],
                                       constant WorldUniforms& uniforms [[buffer(1)]],
                                       instance_acceleration_structure tlas [[buffer(2)]])
{
    float4 color = uniforms.useLightmap ? float4(1.0f) : in.color;
    float2 uv = in.texCoord;
    
    if (uniforms.isTurbulent) {
        float waveTime = uniforms.time * (128.0 / 3.14159265);
        float waveS = sin((uv.y * 128.0 * 2.0 + waveTime) * (3.14159265 / 128.0)) * (8.0 / 128.0);
        float waveT = sin((uv.x * 128.0 * 2.0 + waveTime) * (3.14159265 / 128.0)) * (8.0 / 128.0);
        uv += float2(waveS, waveT);
    }
    
    if (uniforms.useTexture) {
        float4 texColor = baseTexture.sample(textureSampler, uv);
        color.rgb *= texColor.rgb;
        color.a *= texColor.a;
    }
    
    float3 geomN = normalize(in.normal);
    float3 ambient = float3(0.0f);
    if (uniforms.useLightmap) {
        ambient = lightmapTexture.sample(textureSampler, in.lightmapCoord).rgb * color.rgb * 2.0f;
    } else {
        ambient = color.rgb * 1.0f;
    }
    
    float3 directLight = float3(0.0f);
    for (int i = 0; i < uniforms.numDlights; ++i) {
        float radius = uniforms.dlights[i].posRadius.w;
        float3 toLight = uniforms.dlights[i].posRadius.xyz - in.worldPos;
        float distSq = dot(toLight, toLight);
        
        if (distSq >= radius * radius || distSq < 1e-6f)
            continue;
        
        float dist = sqrt(distSq);
        float3 L = toLight / dist;
        float NdotL = max(dot(geomN, L), 0.0f);
        if (NdotL <= 0.0f)
            continue;
        
        float3 rayOrigin = in.worldPos + geomN * 0.5f;
        float3 rayToLight = uniforms.dlights[i].posRadius.xyz - rayOrigin;
        float rayDist = length(rayToLight);
        
        if (rayDist >= 0.6f) {
            ray shadowRay;
            shadowRay.origin = rayOrigin;
            shadowRay.direction = rayToLight / rayDist;
            shadowRay.min_distance = 0.1f;
            shadowRay.max_distance = max(rayDist - 0.5f, 0.15f);
            
            intersector<instancing> inter;
            inter.assume_geometry_type(geometry_type::triangle);
            inter.force_opacity(forced_opacity::opaque);
            inter.accept_any_intersection(true);
            
            auto result = inter.intersect(shadowRay, tlas);
            if (result.type != intersection_type::none)
                continue;
        }
        
        float atten = (1.0f - dist / radius) * NdotL;
        directLight += uniforms.dlights[i].rgbPad.xyz * atten;
    }
    
    color.rgb = ambient + (color.rgb * directLight * 2.0f);
    
    if (uniforms.fogColorDensity.w > 0.0f) {
        float dist = in.fogDistance;
        float fogFactor = exp2(-uniforms.fogColorDensity.w * uniforms.fogColorDensity.w *
                               dist * dist * 1.4426950408889634f);
        color.rgb = mix(uniforms.fogColorDensity.xyz, color.rgb, clamp(fogFactor, 0.0f, 1.0f));
    }
    
    return color;
}
