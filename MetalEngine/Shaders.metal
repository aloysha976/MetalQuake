//
//  Shaders.metal
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#include <metal_stdlib>
#include "MetalBridge.h"
#include "PBRShaders.h"

using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoords;
    float2 lightmapCoords;
    float4 color;
};

// ==========================================
// 2D UI & HUD SHADER (Multi-Texture Single Batch)
// ==========================================

vertex VertexOut ui_vertex_main(uint vertexID [[vertex_id]],
                                constant MetalVertex *vertices [[buffer(BufferIndexVertices)]],
                                constant FrameUniforms &uniforms [[buffer(BufferIndexUniforms)]])
{
    VertexOut out;
    MetalVertex v = vertices[vertexID];
    
    out.position = uniforms.projectionMatrix * float4(v.position, 1.0);
    out.texCoords = v.texCoord;
    // Uses lightmapCoord.x as the texture array index (0..15)
    out.lightmapCoords = v.lightmapCoord;
    out.color = v.color;
    
    return out;
}

fragment float4 ui_fragment_main(VertexOut in [[stage_in]],
                                 array<texture2d<float>, 16> uiTextures [[texture(TextureIndexBase)]],
                                 sampler textureSampler [[sampler(0)]],
                                 constant FrameUniforms &uniforms [[buffer(BufferIndexUniforms)]])
{
    uint texIndex = clamp(uint(in.lightmapCoords.x + 0.5), 0u, 15u);
    float4 texColor = uiTextures[texIndex].sample(textureSampler, in.texCoords);
    return texColor * in.color;
}

// =======================================================
// 3D WORLD SHADERS (BSP & Lightmaps)
// =======================================================

struct WorldVertex {
    float3 position;
    float3 normal;
    float4 tangent; // xyz = tangent in world space, w = bitangent sign
    float2 texCoord;
    float2 lightmapCoord;
    simd_float4 color;
};

// GPU dynamic light structure for per-pixel illumination.
// posRadius: xyz = world position (Quake coordinate system), w = influence radius.
// rgbPad:    rgb = light color [0..1], w = unused padding.
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
    float4 fogColorDensity;   // xyz = fog color, w = density (0 = disabled)
    float4 cameraOriginPad;   // xyz = camera position, w = unused padding
    int numDlights;           // Count of active dynamic lights in array
    int pbrEnabled;           // 1 = PBR enabled, 0 = legacy pipeline
    int pbrDebug;             // 0 = disabled, 1 = tangents, 2 = normals, 3 = bitangents
    int useGlow;              // 1 = sample glow/fullbright mask from slot 1
    GpuDlight dlights[MQ_GPU_DLIGHTS];
};

struct WorldVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 lightmapCoord;
    float4 color;
    float3 worldPos;
    float3 normal;
    float4 tangent; // Tangent frame passed to fragment stage
    float  fogDistance; // Eye-space depth distance from camera (supports world geometry and entities)
};

vertex WorldVertexOut world_vertex_main(
                                        uint vertexID [[vertex_id]],
                                        constant WorldVertex* vertices [[buffer(0)]],
                                        constant WorldUniforms& uniforms [[buffer(1)]])
{
    WorldVertexOut out;
    WorldVertex v = vertices[vertexID];
    
    // Sanitize input coordinates against NaN / Inf (e.g. degenerate sprites, particles, shadows)
    float3 pos = v.position;
    if (any(isnan(pos)) || any(isinf(pos))) {
        out.position = float4(0.0, 0.0, 0.0, 0.0);
        out.worldPos = float3(0.0);
        out.texCoord = float2(0.0);
        out.lightmapCoord = float2(0.0);
        out.color = float4(0.0);
        out.normal = float3(0.0, 0.0, 1.0);
        out.tangent = float4(1.0, 0.0, 0.0, 1.0);
        return out;
    }
    
    out.position = uniforms.mvpMatrix * float4(pos, 1.0);
    out.fogDistance = max(out.position.w, 0.0); // Retain linear distance to camera
    out.texCoord = v.texCoord;
    out.lightmapCoord = v.lightmapCoord;
    out.color = v.color;
    out.worldPos = pos;
    out.normal = v.normal;
    out.tangent = v.tangent;
    return out;
}

fragment float4 world_fragment_main(
                                    WorldVertexOut in [[stage_in]],
                                    texture2d<float> baseTexture [[texture(TextureIndexBase)]],
                                    texture2d<float> lightmapTexture [[texture(TextureIndexLightmap)]],
                                    texture2d<float> normalTexture [[texture(TextureIndexNormal)]],
                                    texture2d<float> rmaoTexture [[texture(TextureIndexRMAO)]],
                                    texture2d<float> emissionTexture [[texture(TextureIndexEmission)]],
                                    sampler textureSampler [[sampler(0)]],
                                    constant WorldUniforms& uniforms [[buffer(1)]])
{
    // Tangent frame inspection modes
    if (uniforms.pbrDebug == 1) {
        // Visualize tangent: remap [-1..1] -> [0..1]
        return float4(normalize(in.tangent.xyz) * 0.5 + 0.5, 1.0);
    } else if (uniforms.pbrDebug == 2) {
        // Visualize geometric polygon normal
        return float4(normalize(in.normal) * 0.5 + 0.5, 1.0);
    } else if (uniforms.pbrDebug == 3) {
        // Visualize bitangent (B = cross(N, T) * sign)
        float3 N = normalize(in.normal);
        float3 T = normalize(in.tangent.xyz);
        float3 B = cross(N, T) * in.tangent.w;
        return float4(normalize(B) * 0.5 + 0.5, 1.0);
    }
    
    // Prevent magenta tinting: lightmapped world geometry packs material indices into in.color
    // (texIdx in red, lmIdx in green). Reset base color to 1.0 to avoid modulating pixels by indices.
    float4 color = uniforms.useLightmap ? float4(1.0f) : in.color;
    float2 uv = in.texCoord;
    
    // 1. Turbulent liquid distortion (matches QuakeSpasm/vkQuake WARPCALC approximation)
    if (uniforms.isTurbulent) {
        // Quake scrolls texture coordinates by 64 units and distorts with cross-axis sin waves
        float waveTime = uniforms.time * (128.0 / 3.14159265);
        float waveS = sin((uv.y * 128.0 * 2.0 + waveTime) * (3.14159265 / 128.0)) * (8.0 / 128.0);
        float waveT = sin((uv.x * 128.0 * 2.0 + waveTime) * (3.14159265 / 128.0)) * (8.0 / 128.0);
        uv += float2(waveS, waveT);
    }
    
    // 2. Diffuse texture sampling
    if (uniforms.useTexture) {
        float4 texColor = baseTexture.sample(textureSampler, uv);
        color.rgb *= texColor.rgb;
        color.a *= texColor.a;
    }
    // 3. Lighting evaluation
    if (uniforms.pbrEnabled) {
        // =======================================================
        // PBR PIPELINE (Cook-Torrance + Normal Mapping + RMAO)
        // =======================================================
        
        // Sample PBR texture maps (slots 2, 3, 4)
        float3 normalMap = normalTexture.sample(textureSampler, uv).rgb * 2.0f - 1.0f;
        float4 rmaoSample = rmaoTexture.sample(textureSampler, uv);
        float3 emission = emissionTexture.sample(textureSampler, uv).rgb;
        
        float roughness = clamp(rmaoSample.r, 0.04f, 1.0f);
        float metallic  = clamp(rmaoSample.g, 0.0f, 1.0f);
        float ao        = clamp(rmaoSample.b, 0.0f, 1.0f);
        
        // Transform normal from tangent space to world space via TBN basis
        float3 geomN = normalize(in.normal);
        float3 T     = normalize(in.tangent.xyz);
        float3 B     = cross(geomN, T) * in.tangent.w;
        float3x3 TBN = float3x3(T, B, geomN);
        float3 N     = normalize(TBN * normalMap);
        
        // Orient normal toward view direction for two-sided / flat surfaces
        float3 V = normalize(uniforms.cameraOriginPad.xyz - in.worldPos);
        if (dot(N, V) < 0.0f) {
            N = -N;
        }
        
        // Dielectric baseline F0 ~ 0.04, metallic surfaces derive F0 from albedo
        float3 F0 = mix(float3(0.04f), color.rgb, metallic);
        
        // Diffuse ambient lighting evaluated from lightmaps modulated by ambient occlusion
        float3 ambient = float3(0.0f);
        if (uniforms.useLightmap) {
            float3 lm = lightmapTexture.sample(textureSampler, in.lightmapCoord).rgb * 2.0f;
            ambient = lm * color.rgb * (1.0f - metallic) * ao;
            // Minor ambient specular term for metals under static lighting
            ambient += lm * F0 * 0.15f * ao;
        } else if (uniforms.isTurbulent) {
            ambient = color.rgb * 1.0f; // vkQuake fullbright without artificial over-exposure
        } else {
            ambient = color.rgb * 1.5f;
        }
        
        // Direct lighting from dynamic light sources (projectiles, explosions, muzzle flashes)
        float3 directLight = float3(0.0f);
        for (int i = 0; i < uniforms.numDlights; ++i) {
            float radius = uniforms.dlights[i].posRadius.w;
            float3 toLight = uniforms.dlights[i].posRadius.xyz - in.worldPos;
            directLight += PBR_EvaluateDirectLight(
                                                   N, V, toLight, radius,
                                                   uniforms.dlights[i].rgbPad.rgb,
                                                   color.rgb, roughness, metallic, F0
                                                   );
        }
        
        // Combined PBR surface radiance
        color.rgb = ambient + directLight + emission;
        
    } else {
        // =======================================================
        // CLASSIC LIGHTING (Vanilla QuakeSpasm Path)
        // =======================================================
        if (uniforms.useLightmap) {
            float3 lm = lightmapTexture.sample(textureSampler, in.lightmapCoord).rgb;
            
            if (uniforms.numDlights > 0) {
                float3 N = normalize(in.normal);
                if (dot(N, N) < 0.1) {
                    float3 dX = dfdx(in.worldPos);
                    float3 dY = dfdy(in.worldPos);
                    N = normalize(cross(dX, dY));
                }
                
                float3 toCam = uniforms.cameraOriginPad.xyz - in.worldPos;
                if (dot(N, toCam) < 0.0) {
                    N = -N;
                }
                
                for (int i = 0; i < uniforms.numDlights; ++i) {
                    float radius = uniforms.dlights[i].posRadius.w;
                    float3 toLight = uniforms.dlights[i].posRadius.xyz - in.worldPos;
                    
                    // 1. AABB early out: cull distant lights with minimal ALU cycles
                    float3 dBox = abs(toLight);
                    if (dBox.x >= radius || dBox.y >= radius || dBox.z >= radius)
                        continue;
                    
                    float distSq = dot(toLight, toLight);
                    if (distSq >= radius * radius || distSq < 1e-6)
                        continue;
                    
                    // 2. Backface culling: skip lights behind the surface plane prior to normalization
                    float NdotLightVec = dot(N, toLight);
                    if (NdotLightVec <= 0.0)
                        continue;
                    
                    // 3. Fast hardware reciprocal square root on Apple Silicon
                    float invDist = rsqrt(distSq);
                    float NdotL = NdotLightVec * invDist;
                    float dist = distSq * invDist;
                    float f = (1.0 - dist / radius) * NdotL;
                    lm += uniforms.dlights[i].rgbPad.rgb * f;
                }
            }
            
            color.rgb *= lm * 2.0;
        } else if (uniforms.isTurbulent) {
            color.rgb *= 1.0; // Preserves high contrast between surface crust and lava/slime
        } else {
            color.rgb *= 1.0;
        }
    }
    
    // 4. Volumetric fog (exponential fog model matching QuakeSpasm, gl_fog.c):
    // Uses in.fogDistance (eye-space camera depth) to ensure accurate evaluation across
    // world BSP geometry, monsters, corpses, and model-space items.
    if (uniforms.fogColorDensity.w > 0.0) {
        float dist = in.fogDistance;
        float fogFactor = exp2(-uniforms.fogColorDensity.w * uniforms.fogColorDensity.w *
                               dist * dist * 1.4426950408889634); // 1/ln(2)
        color.rgb = mix(uniforms.fogColorDensity.xyz, color.rgb, clamp(fogFactor, 0.0, 1.0));
    }
    
    // Fullscreen tonemapping and gamma correction are executed in gamma_fragment_main.
    
    return color;
}

// =======================================================
// GAMMA & CONTRAST POST-PROCESS (vid_gamma / vid_contrast)
// =======================================================

struct GammaUniforms {
    float gammaValue;     // Directly maps to vid_gamma: <1 brightens (vkQuake default 0.9), >1 darkens
    float contrastValue;  // Multiplicative vid_contrast, clamped to [1..2]
    float headroom;       // Display EDR headroom multiplier (>= 1.0; 1.0 represents standard SDR)
    float edrBoost;       // Boost intensity for highlights exceeding standard white (r_edr_boost)
    float bloomIntensity; // r_bloom_intensity
    float hasBloom;       // 1 = bloom texture bound to slot 1
    float exposure;       // r_hdr_exposure: exposure compensation for filmic tonemapping
    float _pad1;
};

// Uniforms for bloom pipeline passes
struct BloomBrightUniforms {
    float threshold;      // r_bloom_threshold: luminance cutoff threshold
    float knee;           // Soft knee width
    float _pad0;
    float _pad1;
};

struct BlurUniforms {
    float texelX;         // 1/source_width
    float texelY;         // 1/source_height
    float dirX;           // Kernel direction (1, 0) for horizontal pass
    float dirY;           // Kernel direction (0, 1) for vertical pass
};

struct GammaVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex GammaVertexOut gamma_vertex_main(
                                        uint vertexID [[vertex_id]],
                                        const device float2* positions [[buffer(0)]],
                                        constant GammaUniforms& uniforms [[buffer(1)]])
{
    GammaVertexOut out;
    float2 p = positions[vertexID];
    out.position = float4(p, 0.0, 1.0);
    // NDC y points upward, texture coordinates point downward: y = +1 -> v = 0
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

fragment float4 gamma_fragment_main(
                                    GammaVertexOut in [[stage_in]],
                                    texture2d<float> sceneTexture [[texture(0)]],
                                    sampler textureSampler [[sampler(0)]],
                                    constant GammaUniforms& uniforms [[buffer(1)]])
{
    float3 c = sceneTexture.sample(textureSampler, in.uv).rgb;
    
    // QuakeSpasm/vkQuake gamma math (GLSLGamma_GammaCorrect):
    // 1) Multiplicative contrast clamped to [1..2]; 2) Direct pow(c, gamma) without inverting.
    c *= clamp(uniforms.contrastValue, 1.0, 2.0);
    c = pow(c, float3(uniforms.gammaValue));
    
    return clamp(float4(c, 1.0), 0.0, 1.0);
}

// ======================================================================
// HDR Post-Processing: Tonemaps RGBA16Float scene buffer.
// headroom == 1 -> Standard SDR: filmic ACES approximation + QuakeSpasm gamma curve.
// headroom > 1  -> Extended Dynamic Range (EDR): preserves SDR base curve while
//                  expanding specular highlights up to available display headroom.
// ======================================================================
static inline float3 MQ_AcesFilmic(float3 x)
{
    // Narkowicz 2015 ACES approximation
    return clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0.0, 1.0);
}

fragment float4 postprocess_fragment_main(
                                          GammaVertexOut in [[stage_in]],
                                          texture2d<float> sceneTexture [[texture(0)]],
                                          texture2d<float> bloomTexture [[texture(1)]],
                                          sampler textureSampler [[sampler(0)]],
                                          constant GammaUniforms& uniforms [[buffer(1)]])
{
    float3 c = sceneTexture.sample(textureSampler, in.uv).rgb;
    
    // Bloom is accumulated prior to tonemapping in linear radiance space
    if (uniforms.hasBloom > 0.5) {
        c += bloomTexture.sample(textureSampler, in.uv).rgb * uniforms.bloomIntensity;
    }
    
    // Apply exposure compensation before the non-linear filmic curve
    c *= uniforms.exposure;
    
    float W = max(uniforms.headroom, 1.0);
    float lum = max(c.r, max(c.g, c.b));
    
    if (W <= 1.001)
    {
        // --- Standard SDR Path: ACES filmic + QuakeSpasm gamma/contrast ---
        float3 m = MQ_AcesFilmic(c);
        m *= clamp(uniforms.contrastValue, 1.0, 2.0);
        m = pow(m, float3(uniforms.gammaValue));
        return float4(clamp(m, 0.0, 1.0), 1.0);
    }
    
    // --- Extended Dynamic Range (EDR) Path ---
    float3 base = MQ_AcesFilmic(c);
    base *= clamp(uniforms.contrastValue, 1.0, 2.0);
    base = pow(base, float3(uniforms.gammaValue));
    base = clamp(base, 0.0, 1.0);
    
    float excess = smoothstep(0.8, 2.0, lum) * uniforms.edrBoost * (W - 1.0);
    float3 edr = base * (1.0 + excess);
    
    // Manual gamma encoding for extendedLinearSRGB render targets to match SDR baseline
    // while allowing values above 1.0 to preserve linear highlight headroom
    edr = min(pow(edr, float3(2.2)), float3(W));
    
    return float4(edr, 1.0);
}

// ======================================================================
// Bloom Pipeline: Bright-pass filter -> Separable 9-tap Gaussian blur.
// Executed in RGBA16Float at half-resolution.
// ======================================================================
fragment float4 brightpass_fragment_main(
                                         GammaVertexOut in [[stage_in]],
                                         texture2d<float> sceneTexture [[texture(0)]],
                                         sampler textureSampler [[sampler(0)]],
                                         constant BloomBrightUniforms& uniforms [[buffer(1)]])
{
    float3 c = sceneTexture.sample(textureSampler, in.uv).rgb;
    float lum = max(c.r, max(c.g, c.b));
    
    // Soft knee threshold: smooth ramp from (threshold - knee) to (threshold + knee)
    float t  = uniforms.threshold;
    float k  = max(uniforms.knee, 1e-3);
    float w  = clamp((lum - (t - k)) / (2.0 * k), 0.0, 1.0);
    
    return float4(c * w * w, 1.0);
}

fragment float4 blur9_fragment_main(
                                    GammaVertexOut in [[stage_in]],
                                    texture2d<float> srcTexture [[texture(0)]],
                                    sampler textureSampler [[sampler(0)]],
                                    constant BlurUniforms& uniforms [[buffer(1)]])
{
    // 9-tap binomial Gaussian weights
    const float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    
    float2 uv = in.uv;
    float2 step = float2(uniforms.dirX * uniforms.texelX,
                         uniforms.dirY * uniforms.texelY);
    
    float3 acc = srcTexture.sample(textureSampler, uv).rgb * w[0];
    for (int i = 1; i < 5; i++)
    {
        acc += srcTexture.sample(textureSampler, uv + step * float(i)).rgb * w[i];
        acc += srcTexture.sample(textureSampler, uv - step * float(i)).rgb * w[i];
    }
    return float4(acc, 1.0);
}

// ======================================================================
// MetalFX Temporal Motion Vectors:
// Reconstructs world-space position from depth -> reprojects to prevClip -> delta UV.
// ======================================================================
struct MVUniforms {
    float4x4 invCurViewProjJittered; // 64 bytes (offset 0)
    float4x4 prevViewProjNoJitter;   // 64 bytes (offset 64)
    float4x4 curViewProjNoJitter;    // 64 bytes (offset 128)
    float2   textureSize;            // 8 bytes  (offset 192)
    float2   _pad;                   // 8 bytes  (offset 200) - total 208 bytes
};

fragment float2 motion_fragment_main(
                                     GammaVertexOut in [[stage_in]],
                                     depth2d<float> depthTexture [[texture(0)]],
                                     constant MVUniforms& u [[buffer(1)]])
{
    uint2 px = uint2(in.position.xy);
    float z = depthTexture.read(px);
    
    // Under Reverse-Z, clear depth / sky evaluates to z = 0.0. Return zero vector for empty sky
    if (z <= 0.0) {
        return float2(0.0);
    }
    
    float2 ndc;
    ndc.x = in.uv.x * 2.0 - 1.0;
    ndc.y = 1.0 - in.uv.y * 2.0;
    
    // 1. Reconstruct world-space position using unjittered matrix inversion
    float4 world = u.invCurViewProjJittered * float4(ndc, z, 1.0);
    world /= world.w;
    
    // 2. Reproject into previous frame without subpixel jitter
    float4 prev = u.prevViewProjNoJitter * world;
    
    // Disocclusion guard: points behind the camera in the previous frame (w <= 0)
    // represent newly revealed geometry. Nullify vector to prevent temporal streaking.
    if (prev.w <= 0.001) {
        return float2(0.0);
    }
    
    float2 prevNDC = prev.xy / prev.w;
    float2 prevPx = (prevNDC * float2(0.5, -0.5) + 0.5) * u.textureSize;
    
    // 3. Project into current frame without jitter
    float4 cur = u.curViewProjNoJitter * world;
    if (cur.w <= 0.001) {
        return float2(0.0);
    }
    
    float2 curNDC = cur.xy / cur.w;
    float2 curPx = (curNDC * float2(0.5, -0.5) + 0.5) * u.textureSize;
    
    // 4. Compute physical pixel displacement vector in input resolution space (Apple convention: prev - cur)
    return prevPx - curPx;
}

// =======================================================
// ALIAS MODELS SHADER (Monsters & Weapons - Pure & Isolated)
// =======================================================

fragment float4 alias_fragment_main(
                                    WorldVertexOut in [[stage_in]],
                                    texture2d<float> baseTexture       [[texture(0)]],
                                    texture2d<float> fullbrightTexture [[texture(1)]],
                                    sampler textureSampler             [[sampler(0)]],
                                    constant WorldUniforms &uniforms   [[buffer(1)]])
{
    float4 texColor = baseTexture.sample(textureSampler, in.texCoord);
    
    // in.color holds Quake lighting: baseLight * (0.4 + 0.6 * dot)
    float4 color;
    color.rgb = texColor.rgb * in.color.rgb;
    color.a   = texColor.a * in.color.a;
    
    // Additive glow mask (eyes, runes) sampled only when useGlow is set
    if (uniforms.useGlow) {
        float3 glow = fullbrightTexture.sample(textureSampler, in.texCoord).rgb;
        color.rgb += glow;
    }
    
    // Volumetric fog for alias entities evaluated via in.fogDistance
    if (uniforms.fogColorDensity.w > 0.0) {
        float dist = in.fogDistance;
        float fogFactor = exp2(-uniforms.fogColorDensity.w * uniforms.fogColorDensity.w *
                               dist * dist * 1.4426950408889634);
        color.rgb = mix(uniforms.fogColorDensity.xyz, color.rgb, clamp(fogFactor, 0.0, 1.0));
    }
    
    return color;
}

// =======================================================
// PARTICLE INSTANCING SHADERS (Single Batch Billboard)
// =======================================================

struct ParticleVertexOut {
    float4 position [[position]];
    float2 texCoords;
    float4 color;
};

vertex ParticleVertexOut particle_vertex_main(
                                              uint vertexID [[vertex_id]],
                                              uint instanceID [[instance_id]],
                                              constant MetalParticleInstance *instances [[buffer(0)]],
                                              constant ParticleUniforms &uniforms [[buffer(1)]])
{
    // Procedural quad from 6 vertices (2 triangles)
    constexpr float2 quadOffsets[6] = {
        float2(-1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f),
        float2(-1.0f, -1.0f),
        float2( 1.0f,  1.0f),
        float2( 1.0f, -1.0f)
    };
    
    constexpr float2 quadUVs[6] = {
        float2(0.0f, 1.0f),
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f),
        float2(0.0f, 1.0f),
        float2(1.0f, 0.0f),
        float2(1.0f, 1.0f)
    };
    
    float2 offset = quadOffsets[vertexID];
    float2 uv = quadUVs[vertexID];
    
    MetalParticleInstance inst = instances[instanceID];
    float3 org = inst.posAndSize.xyz;
    
    // Evaluate perspective particle scaling on the GPU
    float dist = dot(org - uniforms.cameraOrigin.xyz, uniforms.cameraVPN.xyz);
    float scale = inst.posAndSize.w * (1.0f + max(dist, 0.0f) * 0.0024f);
    
    // Compute billboard orientation in parallel
    float3 worldPos = org + (uniforms.cameraRight.xyz * offset.x + uniforms.cameraUp.xyz * offset.y) * scale;
    
    ParticleVertexOut out;
    out.position = uniforms.mvpMatrix * float4(worldPos, 1.0);
    out.texCoords = uv;
    out.color = inst.color;
    return out;
}

fragment float4 particle_fragment_main(
                                       ParticleVertexOut in [[stage_in]],
                                       texture2d<float> particleTexture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]])
{
    float4 tex = particleTexture.sample(textureSampler, in.texCoords);
    return tex * in.color;
}

// =======================================================
// STATIC BSP WORLD BINDLESS SHADER (Single Batch)
// =======================================================

fragment float4 world_static_fragment_main(
                                           WorldVertexOut in [[stage_in]],
                                           array<texture2d<float>, 96> diffuseTextures  [[texture(0)]],
                                           array<texture2d<float>, 32> lightmapTextures [[texture(96)]],
                                           sampler textureSampler [[sampler(0)]],
                                           constant WorldUniforms &uniforms [[buffer(1)]])
{
    uint texIdx = clamp(uint(in.color.r + 0.5f), 0u, 95u);
    uint lmIdx  = clamp(uint(in.color.g + 0.5f), 0u, 31u);
    
    float4 texColor = diffuseTextures[texIdx].sample(textureSampler, in.texCoord);
    float4 lmColor  = lightmapTextures[lmIdx].sample(textureSampler, in.lightmapCoord);
    
    // Classic Quake overbright lighting multiplier (* 2.0)
    float4 color;
    color.rgb = texColor.rgb * lmColor.rgb * 2.0f;
    color.a   = 1.0f;
    
    // Dynamic light evaluation (per-pixel dlights) modulating surface texture
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
            
            float invDist = rsqrt(distSq);
            float NdotL = max(dot(N, toLight * invDist), 0.0f);
            float dist = distSq * invDist;
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
