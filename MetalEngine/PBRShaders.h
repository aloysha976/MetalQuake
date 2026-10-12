//
//  PBRShaders.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//
//  Physically based Cook-Torrance BRDF evaluation (GGX / Smith / Fresnel-Schlick)
//

#ifndef PBRShaders_h
#define PBRShaders_h

#include <metal_stdlib>
using namespace metal;

// 1. Fresnel-Schlick: ratio of reflected light at grazing angles
static inline float3 PBR_FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0f - F0) * pow(clamp(1.0f - cosTheta, 0.0f, 1.0f), 5.0f);
}

// 2. Trowbridge-Reitz GGX NDF: normal distribution function of microfacets
static inline float PBR_DistributionGGX(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0f);
    float NdotH2 = NdotH * NdotH;
    
    float denom = (NdotH2 * (a2 - 1.0f) + 1.0f);
    denom = M_PI_F * denom * denom;
    
    return a2 / max(denom, 1e-5f);
}

// 3. Geometry Schlick-GGX: microfacet shadowing and masking
static inline float PBR_GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0f);
    float k = (r * r) / 8.0f; // k parameter for analytical point light sources
    
    float denom = NdotV * (1.0f - k) + k;
    return NdotV / max(denom, 1e-5f);
}

// 4. Smith Geometry: masking-shadowing function combining view and light directions
static inline float PBR_GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0f);
    float NdotL = max(dot(N, L), 0.0f);
    float ggx1 = PBR_GeometrySchlickGGX(NdotV, roughness);
    float ggx2 = PBR_GeometrySchlickGGX(NdotL, roughness);
    
    return ggx1 * ggx2;
}

// 5. Direct lighting evaluation for a single dynamic point light (dlight)
static inline float3 PBR_EvaluateDirectLight(
                                             float3 N,
                                             float3 V,
                                             float3 toLight,
                                             float radius,
                                             float3 lightColor,
                                             float3 albedo,
                                             float roughness,
                                             float metallic,
                                             float3 F0)
{
    float distSq = dot(toLight, toLight);
    if (distSq >= radius * radius || distSq < 1e-6f)
        return float3(0.0f);
    
    float dist = sqrt(distSq);
    float3 L = toLight / dist;
    float3 H = normalize(V + L);
    
    float NdotL = max(dot(N, L), 0.0f);
    if (NdotL <= 0.0f)
        return float3(0.0f);
    
    float NdotV = max(dot(N, V), 0.001f);
    
    // Cook-Torrance specular BRDF
    float NDF = PBR_DistributionGGX(N, H, roughness);
    float G   = PBR_GeometrySmith(N, V, L, roughness);
    float3 F  = PBR_FresnelSchlick(max(dot(H, V), 0.0f), F0);
    
    float3 numerator = NDF * G * F;
    float denominator = 4.0f * NdotV * NdotL + 0.0001f;
    float3 specular = numerator / denominator;
    
    // Energy conservation: diffuse term accounts only for unreflected refracted light
    float3 kD = (float3(1.0f) - F) * (1.0f - metallic);
    float3 diffuse = kD * albedo / M_PI_F;
    
    // Quake linear light attenuation scaled for physical radiance
    float attenuation = (1.0f - dist / radius);
    float3 radiance = lightColor * attenuation * M_PI_F;
    
    return (diffuse + specular) * radiance * NdotL;
}

#endif /* PBRShaders_h */
