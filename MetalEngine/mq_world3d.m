//
//  mq_world3d.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#include "quakedef.h"
#import <simd/simd.h>
#import "MetalBridge.h"
#import "mq_internal.h"
#import "mq_log.h"
#import "mq_pbr.h"
#import "mq_rt.h"
#import "mq_world_vbo.h"
#import <Metal/Metal.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/CAMetalLayer.h>

// Telemetry counters
uint32_t g_mqStatDrawCalls = 0;
uint32_t g_mqStatWorldPolys = 0;

// External Metal state declarations (definitions reside in their respective modules; see mq_internal.h).
extern id<MTLDevice> g_device;
extern id<MTLRenderCommandEncoder> g_renderEncoder;
extern CAMetalLayer *g_metalLayer;
extern id<MTLRenderPipelineState> g_worldPipelineState;
extern id<MTLDepthStencilState> g_depthState3D;
extern id<MTLDepthStencilState> g_depthStateSky;
extern id<MTLSamplerState> g_samplerState;
static id<MTLDepthStencilState> s_depthStateWater = nil;
extern CFMutableSetRef g_validTextures;

// Indicates whether the compressed weapon depth range [0..0.3] (or inverted [0.7..1.0]) is active.
bool g_metalGunDepth = false;

// Pipeline states for transparent geometry (sprites, water surfaces) and additive effects (particles, explosions).
id<MTLRenderPipelineState> g_worldBlendedPipelineState = nil;
id<MTLRenderPipelineState> g_worldAdditivePipelineState = nil;
static id<MTLRenderPipelineState> s_particlePipelineState = nil;
static id<MTLRenderPipelineState> s_shadowPipelineState = nil;
static id<MTLRenderPipelineState> s_worldStaticPipelineState = nil;
static id<MTLRenderPipelineState> s_worldTurbulentPipelineState = nil;
static id<MTLRenderPipelineState> s_aliasPipelineState = nil;
static id<MTLRenderPipelineState> s_spriteBatchPipelineState = nil;

static id<MTLRenderPipelineState> s_aliasGpuPipelineState = nil;
static id<MTLRenderPipelineState> s_aliasGpuBlendedPipelineState = nil;
static id<MTLSamplerState>        s_aliasModelSampler = nil;
static id<MTLRenderPipelineState> s_aliasBlendedPipelineState = nil;

// Static 1x1 black texture used as a fallback for models without a glow/fullbright mask.
static id<MTLTexture> s_aliasBlackTexture = nil;

// Persistent Argument Buffer for Tier 2 bindless world materials (1024 textures x 8 bytes)
#define MQ_MAX_WORLD_TEXTURES 1024
static id<MTLBuffer> s_worldMaterialBuffer = nil;

id<MTLTexture> R_Metal_GetBlackTexture(void)
{
    if (s_aliasBlackTexture)
        return s_aliasBlackTexture;
    if (!g_device)
        return nil;
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:1
                                                                                   height:1
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    s_aliasBlackTexture = [g_device newTextureWithDescriptor:desc];
    s_aliasBlackTexture.label = @"3D Alias Black 1x1";
    
    uint32_t blackPixel = 0x00000000;
    [s_aliasBlackTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                           mipmapLevel:0
                             withBytes:&blackPixel
                           bytesPerRow:4];
    return s_aliasBlackTexture;
}

// Volumetric fog and camera frame state (populated from QuakeCore via R_Metal_SetFogState in R_SetupView, gl_rmain.c).
static simd_float3 g_fogColor = { 0.0f, 0.0f, 0.0f };
static float g_fogDensity = 0.0f;
static simd_float3 g_cameraOrigin = { 0.0f, 0.0f, 0.0f };

// Active per-frame dynamic lights for per-pixel lighting.
// Gathered once per frame from QuakeCore (R_GatherPerPixelDlights, gl_rmain.c).
#define MQ_GPU_DLIGHTS 32
typedef struct {
    simd_float4 posRadius;  // xyz = position (Quake coordinate system), w = radius
    simd_float4 rgbPad;     // rgb = color, w = unused padding
} MQGpuDlight;

typedef struct {
    simd_float4x4 mvpMatrix;
    int useTexture;
    int useLightmap;
    int isTurbulent;
    float time;
    simd_float4 fogColorDensity;   // xyz = fog color, w = density
    simd_float4 cameraOriginPad;   // xyz = camera origin, w = unused padding
    int numDlights;
    int pbrEnabled;                // 1 = PBR enabled, 0 = legacy pipeline
    int pbrDebug;                  // 0 = off, 1 = tangents, 2 = normals, 3 = bitangents
    int useGlow;                   // 1 = sample glow mask from slot 1
    simd_float4 liquidAlphas;      // x = water, y = lava, z = slime, w = teleporter
    MQGpuDlight dlights[MQ_GPU_DLIGHTS];
} MetalWorldUniforms;

static MetalWorldUniforms s_lastUniformsData;
static bool s_hasCachedUniforms = false;
static id<MTLBuffer> s_cachedUB = nil;
static NSUInteger s_cachedUBOffset = 0;
static id<MTLBuffer> s_lastBoundUB = nil;
static NSUInteger s_lastBoundUBOffset = (NSUInteger)-1;

static MQGpuDlight g_frameDlights[MQ_GPU_DLIGHTS];
static int g_numFrameDlights = 0;

extern float g_metalTime;
static MetalWorldUniforms s_frameTemplate;
static id<MTLRenderCommandEncoder> s_lastEncoderRef = nil;

// World geometry is rendered in world space, where per-pixel lighting evaluates correctly.
// Brush models (doors, platforms) are evaluated in model space: per-pixel dynamic lights are
// disabled for them to avoid light leaking or tracking issues, falling back to lightmaps (vkQuake behavior).
// Reset to true at the beginning of each frame (BeginFrame).
static bool g_perPixelEligible = true;

void R_Metal_EnablePerPixelDlights(bool enable)
{
    g_perPixelEligible = enable;
}

void R_Metal_SetFrameDlights(const float *packed, int count)
{
    // Invoked once per frame from R_SetupView before all draw calls.
    // Also resets the bmodel exclusion flag from the preceding frame.
    g_perPixelEligible = true;
    
    if (count > MQ_GPU_DLIGHTS)
        count = MQ_GPU_DLIGHTS;
    g_numFrameDlights = count;
    for (int i = 0; i < count; i++) {
        const float *s = packed + (size_t)i * 8;
        g_frameDlights[i].posRadius = (simd_float4){ s[0], s[1], s[2], s[3] };
        g_frameDlights[i].rgbPad    = (simd_float4){ s[4], s[5], s[6], 0.0f };
    }
}

void R_Metal_SetFogState(float r, float g, float b, float density,
                         float camX, float camY, float camZ)
{
    g_fogColor = (simd_float3){ r, g, b };
    g_fogDensity = density;
    g_cameraOrigin = (simd_float3){ camX, camY, camZ };
}

void R_Metal_RebuildBlended3DPipelines(MTLPixelFormat fmt); // Forward declaration

void R_Metal_Init3DPipeline(void)
{
    if (!g_device) {
        printf("[Metal3D] Error: g_device is NULL in R_Metal_Init3DPipeline\n");
        return;
    }
    
    if (g_worldBlendedPipelineState && g_worldAdditivePipelineState)
        return;
    
    // Target format reflects the current scene format (RGBA16Float under HDR)
    // rather than hardcoded BGRA8, preventing PSO/attachment format mismatch on the initial blended pass.
    R_Metal_RebuildBlended3DPipelines(g_sceneFormat);
}

// Rebuilds blended pipelines targeting the designated color attachment format (scene/drawable).
// Called from R_Metal_ApplyHDRMode when toggling HDR state.
void R_Metal_RebuildBlended3DPipelines(MTLPixelFormat fmt)
{
    if (!g_device) {
        printf("[Metal3D] Error: g_device is NULL in RebuildBlended3DPipelines\n");
        return;
    }
    
    NSError *error = nil;
    id<MTLLibrary> library = [g_device newDefaultLibrary];
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"world_vertex_main"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"world_fragment_main"];
    if (!vertexFunc || !fragmentFunc) {
        printf("[Metal3D] Error: world_vertex_main/world_fragment_main not found\n");
        return;
    }
    
    // 1. Alpha-blended pipeline for sprites and decals (SourceAlpha, OneMinusSourceAlpha)
    {
        MTLRenderPipelineDescriptor *blendedDesc = [MTLRenderPipelineDescriptor new];
        blendedDesc.label = @"Quake 3D World Pipeline (Blended Alpha)";
        blendedDesc.vertexFunction = vertexFunc;
        blendedDesc.fragmentFunction = fragmentFunc;
        blendedDesc.colorAttachments[0].pixelFormat = fmt;
        blendedDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        
        blendedDesc.colorAttachments[0].blendingEnabled = YES;
        blendedDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        blendedDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        blendedDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        blendedDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        blendedDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        blendedDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        
        blendedDesc.rasterSampleCount = MQ_PSOSampleCount();
        g_worldBlendedPipelineState = [g_device newRenderPipelineStateWithDescriptor:blendedDesc error:&error];
    }
    
    // 2. Additive pipeline for fire, explosions, and glowing particles (SourceAlpha, One)
    {
        MTLRenderPipelineDescriptor *additiveDesc = [MTLRenderPipelineDescriptor new];
        additiveDesc.label = @"Quake 3D World Pipeline (Additive Particles)";
        additiveDesc.vertexFunction = vertexFunc;
        additiveDesc.fragmentFunction = fragmentFunc;
        additiveDesc.colorAttachments[0].pixelFormat = fmt;
        additiveDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        
        additiveDesc.colorAttachments[0].blendingEnabled = YES;
        additiveDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        additiveDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        additiveDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        additiveDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        additiveDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        additiveDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        
        additiveDesc.rasterSampleCount = MQ_PSOSampleCount();
        g_worldAdditivePipelineState = [g_device newRenderPipelineStateWithDescriptor:additiveDesc error:&error];
    }
    
    // 2b. Alpha-blended pipeline for entity shadows
    {
        id<MTLFunction> shadowFragFunc = [library newFunctionWithName:@"shadow_fragment_main"];
        if (vertexFunc && shadowFragFunc) {
            MTLRenderPipelineDescriptor *shDesc = [MTLRenderPipelineDescriptor new];
            shDesc.label = @"Quake 3D Shadow Pipeline (Blended Alpha)";
            shDesc.vertexFunction = vertexFunc;
            shDesc.fragmentFunction = shadowFragFunc;
            shDesc.colorAttachments[0].pixelFormat = fmt;
            shDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            
            shDesc.colorAttachments[0].blendingEnabled = YES;
            shDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            shDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            shDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            shDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            shDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            shDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            
            shDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_shadowPipelineState = [g_device newRenderPipelineStateWithDescriptor:shDesc error:&error];
        }
    }
    
    // 3. Instanced particle pipeline (procedural quad + additive blending)
    {
        id<MTLFunction> pVertFunc = [library newFunctionWithName:@"particle_vertex_main"];
        id<MTLFunction> pFragFunc = [library newFunctionWithName:@"particle_fragment_main"];
        if (pVertFunc && pFragFunc) {
            MTLRenderPipelineDescriptor *pDesc = [MTLRenderPipelineDescriptor new];
            pDesc.label = @"Quake Particles Instanced (Additive)";
            pDesc.vertexFunction = pVertFunc;
            pDesc.fragmentFunction = pFragFunc;
            pDesc.colorAttachments[0].pixelFormat = fmt;
            pDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            
            pDesc.colorAttachments[0].blendingEnabled = YES;
            pDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            pDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            pDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            pDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            pDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
            pDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
            
            pDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_particlePipelineState = [g_device newRenderPipelineStateWithDescriptor:pDesc error:&error];
        }
    }
    
    // 3b. Batched multi-texture sprite pipeline (alpha blended, read-only depth)
    {
        id<MTLFunction> spriteFragFunc = [library newFunctionWithName:@"sprite_fragment_main"];
        if (vertexFunc && spriteFragFunc) {
            MTLRenderPipelineDescriptor *spDesc = [MTLRenderPipelineDescriptor new];
            spDesc.label = @"Quake 3D Sprite Multi-Texture Pipeline";
            spDesc.vertexFunction = vertexFunc;
            spDesc.fragmentFunction = spriteFragFunc;
            spDesc.colorAttachments[0].pixelFormat = fmt;
            spDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            
            spDesc.colorAttachments[0].blendingEnabled = YES;
            spDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            spDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            spDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            spDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            spDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            spDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            
            spDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_spriteBatchPipelineState = [g_device newRenderPipelineStateWithDescriptor:spDesc error:&error];
            if (error) {
                printf("[Metal3D] Error building sprite_batch_pipeline: %s\n",
                       error.localizedDescription.UTF8String);
            }
        }
    }
    
    // 4. Monolithic static world bindless pipeline (single draw call pass)
    {
        id<MTLFunction> staticFragFunc = [library newFunctionWithName:@"world_static_fragment_main"];
        if (vertexFunc && staticFragFunc) {
            MTLRenderPipelineDescriptor *sDesc = [MTLRenderPipelineDescriptor new];
            sDesc.label = @"Quake 3D World Static Bindless Pipeline";
            sDesc.vertexFunction = vertexFunc;
            sDesc.fragmentFunction = staticFragFunc;
            sDesc.colorAttachments[0].pixelFormat = fmt;
            sDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            sDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_worldStaticPipelineState = [g_device newRenderPipelineStateWithDescriptor:sDesc error:&error];
            if (error) {
                printf("[Metal3D] Error building world_static_pipeline: %s\n",
                       error.localizedDescription.UTF8String);
            }
        }
        
        // Turbulent liquids bindless pipeline (Alpha blended: SourceAlpha, OneMinusSourceAlpha)
        id<MTLFunction> turbFragFunc = [library newFunctionWithName:@"world_turbulent_fragment_main"];
        if (vertexFunc && turbFragFunc) {
            MTLRenderPipelineDescriptor *tDesc = [MTLRenderPipelineDescriptor new];
            tDesc.label = @"Quake 3D World Turbulent Bindless Pipeline";
            tDesc.vertexFunction = vertexFunc;
            tDesc.fragmentFunction = turbFragFunc;
            tDesc.colorAttachments[0].pixelFormat = fmt;
            tDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            
            tDesc.colorAttachments[0].blendingEnabled = YES;
            tDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            tDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            tDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            tDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            tDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            tDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            
            tDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_worldTurbulentPipelineState = [g_device newRenderPipelineStateWithDescriptor:tDesc error:&error];
            if (error) {
                printf("[Metal3D] Error building world_turbulent_pipeline: %s\n",
                       error.localizedDescription.UTF8String);
            }
        }
    }
    // 5. Dedicated pipelines for Alias models (entities and viewmodels)
    {
        id<MTLFunction> aliasFragFunc = [library newFunctionWithName:@"alias_fragment_main"];
        if (vertexFunc && aliasFragFunc) {
            MTLRenderPipelineDescriptor *aDesc = [MTLRenderPipelineDescriptor new];
            aDesc.label = @"Quake 3D Alias Model Pipeline (Opaque)";
            aDesc.vertexFunction = vertexFunc;
            aDesc.fragmentFunction = aliasFragFunc;
            aDesc.colorAttachments[0].pixelFormat = fmt;
            aDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            aDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_aliasPipelineState = [g_device newRenderPipelineStateWithDescriptor:aDesc error:&error];
            
            aDesc.label = @"Quake 3D Alias Model Pipeline (Blended)";
            aDesc.colorAttachments[0].blendingEnabled = YES;
            aDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            aDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            aDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            aDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            aDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            aDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            s_aliasBlendedPipelineState = [g_device newRenderPipelineStateWithDescriptor:aDesc error:&error];
        }
    }
    // 5b. Alias GPU vertex lerp pipelines (Metal 3)
    {
        id<MTLFunction> gpuVertFunc = [library newFunctionWithName:@"alias_gpu_vertex_main"];
        id<MTLFunction> gpuFragFunc = [library newFunctionWithName:@"alias_gpu_fragment_main"];
        if (gpuVertFunc && gpuFragFunc) {
            MTLRenderPipelineDescriptor *aDesc = [MTLRenderPipelineDescriptor new];
            aDesc.label = @"Quake Alias GPU Opaque Pipeline";
            aDesc.vertexFunction = gpuVertFunc;
            aDesc.fragmentFunction = gpuFragFunc;
            aDesc.colorAttachments[0].pixelFormat = fmt;
            aDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            aDesc.colorAttachments[0].blendingEnabled = NO;
            aDesc.rasterSampleCount = MQ_PSOSampleCount();
            s_aliasGpuPipelineState = [g_device newRenderPipelineStateWithDescriptor:aDesc error:&error];
            if (error) {
                printf("[Metal3D] Error building alias_gpu_pipeline: %s\n",
                       error.localizedDescription.UTF8String);
            }
            
            aDesc.label = @"Quake Alias GPU Blended Pipeline";
            aDesc.colorAttachments[0].blendingEnabled = YES;
            aDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            aDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            aDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            aDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            aDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            aDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            s_aliasGpuBlendedPipelineState = [g_device newRenderPipelineStateWithDescriptor:aDesc error:&error];
        }
        
        if (!s_aliasModelSampler) {
            MTLSamplerDescriptor *sDesc = [MTLSamplerDescriptor new];
            sDesc.minFilter = MTLSamplerMinMagFilterLinear;
            sDesc.magFilter = MTLSamplerMinMagFilterLinear;
            sDesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
            sDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
            sDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
            s_aliasModelSampler = [g_device newSamplerStateWithDescriptor:sDesc];
        }
    }
    // 6. Hardware ray tracing pipeline compilation (if supported by Apple Silicon)
    if (MQ_RT_IsSupported()) {
        MQ_RT_BuildPipeline(fmt, library);
    }
}

// Constructs a perspective projection matrix with subpixel jitter (following Apple MetalFX guidelines).
static simd_float4x4 make_perspective(float fovY_rad, float aspect, float zNear, float zFar, float jitterX_px, float jitterY_px, float renderW, float renderH)
{
    float yScale = 1.0f / tanf(fovY_rad * 0.5f);
    float xScale = yScale / aspect;
    
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){ xScale, 0.0f, 0.0f, 0.0f };
    m.columns[1] = (simd_float4){ 0.0f, yScale, 0.0f, 0.0f };
    
    // Subpixel clip-space jitter for MetalFX Temporal anti-aliasing / upscaling
    float jitterX_clip = (jitterX_px * 2.0f) / renderW;
    float jitterY_clip = (jitterY_px * 2.0f) / renderH;
    
    // Reverse-Z formulation:
    // zNear maps to 1.0 (near plane), zFar maps to 0.0 (far plane).
    // Maximizes 32-bit floating-point precision near zero, eliminating distant z-fighting and motion vector jitter.
    m.columns[2] = (simd_float4){ jitterX_clip, jitterY_clip, zNear / (zNear - zFar), 1.0f };
    m.columns[3] = (simd_float4){ 0.0f, 0.0f, (zNear * zFar) / (zFar - zNear), 0.0f };
    
    return m;
}

simd_float4x4 R_Metal_ComputeMVP(float fovY_deg, float aspect, float zNear, float zFar,
                                 simd_float3 origin, simd_float3 angles)
{
    // 1. Perspective projection with subpixel jitter for temporal upscaling
    float fovRad = fovY_deg * (M_PI / 180.0f);
    
    // Fall back to g_mqRenderTargetW/H (initialized in BeginFrame)
    float renderW = (g_mqRenderTargetW > 0) ? (float)g_mqRenderTargetW : 800.0f;
    float renderH = (g_mqRenderTargetH > 0) ? (float)g_mqRenderTargetH : 600.0f;
    
    simd_float4x4 proj = make_perspective(fovRad, aspect, zNear, zFar,
                                          MQ_Metalfx_JitterX(), MQ_Metalfx_JitterY(),
                                          renderW, renderH);
    // 2. Camera basis vectors (matching AngleVectors in mathlib)
    float pitch = angles.x * (M_PI / 180.0f);
    float yaw   = angles.y * (M_PI / 180.0f);
    float roll  = angles.z * (M_PI / 180.0f);
    
    float sp = sinf(pitch), cp = cosf(pitch);
    float sy = sinf(yaw),   cy = cosf(yaw);
    float sr = sinf(roll),  cr = cosf(roll);
    
    simd_float3 forward = {  cp*cy, cp*sy, -sp };
    simd_float3 right   = { -sr*sp*cy + cr*sy, -sr*sp*sy - cr*cy, -sr*cp };
    simd_float3 up      = {  cr*sp*cy + sr*sy,  cr*sp*sy - sr*cy,  cr*cp };
    
    // 3. View matrix: rows represent camera basis vectors (right, up, forward).
    // Column-major storage stores world-axis row components across columns.
    simd_float4x4 view = matrix_identity_float4x4;
    view.columns[0] = (simd_float4){ right.x,   up.x,   forward.x,   0.0f };
    view.columns[1] = (simd_float4){ right.y,   up.y,   forward.y,   0.0f };
    view.columns[2] = (simd_float4){ right.z,   up.z,   forward.z,   0.0f };
    view.columns[3] = (simd_float4){ -simd_dot(right, origin),
        -simd_dot(up, origin),
        -simd_dot(forward, origin), 1.0f };
    
    return simd_mul(proj, view);
}


extern void R_Metal_Flush2D(void);

static bool R_Metal_Setup3DWorldState(simd_float4x4 mvpMatrix,
                                      void *diffuseTexture, void *lightmapTexture,
                                      int blendMode, bool isTurbulent,
                                      uint32_t count, bool isIndexed,
                                      const char *tag)
{
    if (!g_renderEncoder || !g_worldPipelineState || count == 0) {
        return false;
    }
    
    // Invalidate cached uniforms whenever a new command encoder begins
    static id<MTLRenderCommandEncoder> s_lastEncoder = nil;
    if (g_renderEncoder != s_lastEncoder) {
        s_lastEncoder = g_renderEncoder;
        s_hasCachedUniforms = false;
    }
    
    if (!MQ_Renderer_DeferUIActive()) {
        R_Metal_Flush2D();
        s_hasCachedUniforms = false;
    }
    
    // Stale texture validation
    bool diffuseValid = true, lightmapValid = true;
#ifndef MQ_NO_TEXTURE_VALIDATION
    if (diffuseTexture && g_validTextures && !CFSetContainsValue(g_validTextures, diffuseTexture)) {
        MLog(MQ_LVL_ALWAYS, "GFX·DRAW", "ERROR: [%s] STALE/FREED diffuse texture %p!",
             tag ? tag : "?", diffuseTexture);
        diffuseValid = false;
    }
    if (lightmapTexture && g_validTextures && !CFSetContainsValue(g_validTextures, lightmapTexture)) {
        MLog(MQ_LVL_ALWAYS, "GFX·DRAW", "ERROR: [%s] STALE/FREED lightmap texture %p!",
             tag ? tag : "?", lightmapTexture);
        lightmapValid = false;
    }
#endif
    
    extern CAMetalLayer *g_metalLayer;
    extern bool g_metalGunDepth;
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    double vpZNear = g_metalGunDepth ? 0.7 : 0.0;
    double vpZFar  = 1.0;
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, vpZNear, vpZFar };
    MQEncoder_SetViewport(vp3D);
    
    if (MLog_Budget(tag ? tag : "GFX·DRAW", 15))
        MLog(MQ_LVL_DEV, "GFX·DRAW", "[%s] %sblend=%s tex=%s lm=%s count=%u zrange=[%.1f..%.1f]",
             tag ? tag : "?",
             isIndexed ? "IBO " : "",
             blendMode == 2 ? "ADD" : blendMode == 1 ? "ALPHA" : "OPAQUE",
             !diffuseTexture ? "-" : (diffuseValid ? "ok" : "STALE!"),
             !lightmapTexture ? "-" : (lightmapValid ? "ok" : "STALE!"),
             count, vp3D.znear, vp3D.zfar);
    
    // Direct only Alias models to alias_fragment_main; shadows use the dedicated shadow pipeline
    bool isAlias = (tag && (strcmp(tag, "alias-world") == 0 ||
                            strcmp(tag, "alias-viewmodel") == 0 ||
                            strcmp(tag, "alias-batch-world") == 0));
    bool isShadow = (tag && strcmp(tag, "entity-shadow-batch") == 0);
    
    // Select pipeline and depth stencil states
    if (isShadow) {
        MQEncoder_SetRenderPipelineState(s_shadowPipelineState ?: (g_worldBlendedPipelineState ?: g_worldPipelineState));
        if (g_depthStateSky)
            MQEncoder_SetDepthStencilState(g_depthStateSky);
    } else if (isAlias) {
        if (blendMode == 1 /* METAL_BLEND_ALPHA */) {
            MQEncoder_SetRenderPipelineState(s_aliasBlendedPipelineState ?: g_worldBlendedPipelineState);
            if (g_depthStateSky)
                MQEncoder_SetDepthStencilState(g_depthStateSky);
        } else {
            MQEncoder_SetRenderPipelineState(s_aliasPipelineState ?: g_worldPipelineState);
            if (g_depthState3D)
                MQEncoder_SetDepthStencilState(g_depthState3D);
        }
    } else if (blendMode == 2 /* METAL_BLEND_ADDITIVE */) {
        if (!g_worldAdditivePipelineState)
            R_Metal_Init3DPipeline();
        MQEncoder_SetRenderPipelineState(g_worldAdditivePipelineState ?: g_worldPipelineState);
        if (g_depthStateSky)
            MQEncoder_SetDepthStencilState(g_depthStateSky);
    } else if (blendMode == 1 /* METAL_BLEND_ALPHA */) {
        if (!g_worldBlendedPipelineState)
            R_Metal_Init3DPipeline();
        MQEncoder_SetRenderPipelineState(g_worldBlendedPipelineState ?: g_worldPipelineState);
        if (g_depthStateSky)
            MQEncoder_SetDepthStencilState(g_depthStateSky);
    } else {
        id<MTLRenderPipelineState> rtPipe = MQ_RT_GetWorldPipeline();
        
        if (MQ_RT_IsEnabled() && rtPipe && MQ_RT_GetWorldTLAS()) {
            MQEncoder_SetRenderPipelineState(rtPipe);
            MQ_RT_BindResources(g_renderEncoder);
        } else {
            MQEncoder_SetRenderPipelineState(g_worldPipelineState);
        }
        
        if (g_depthState3D)
            MQEncoder_SetDepthStencilState(g_depthState3D);
    }
    
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    if (g_renderEncoder != s_lastEncoderRef) {
        s_lastEncoderRef = g_renderEncoder;
        memset(&s_frameTemplate, 0, sizeof(s_frameTemplate));
        memcpy(s_frameTemplate.dlights, g_frameDlights, sizeof(g_frameDlights));
        
        // Evaluate liquid alphas matching vkQuake cvar hierarchy
        extern cvar_t r_wateralpha, r_lavaalpha, r_telealpha, r_slimealpha;
        extern float map_wateralpha, map_lavaalpha, map_telealpha, map_slimealpha;
        
        float wA = (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f) ? r_wateralpha.value : (map_wateralpha > 0.0f ? map_wateralpha : 1.0f);
        float lA = (r_lavaalpha.value > 0.0f) ? r_lavaalpha.value : (map_lavaalpha > 0.0f ? map_lavaalpha : wA);
        float sA = (r_slimealpha.value > 0.0f) ? r_slimealpha.value : (map_slimealpha > 0.0f ? map_slimealpha : wA);
        float tA = (r_telealpha.value > 0.0f) ? r_telealpha.value : (map_telealpha > 0.0f ? map_telealpha : wA);
        
        s_frameTemplate.liquidAlphas = (simd_float4){
            (wA <= 0.0f || wA > 1.0f) ? 1.0f : wA,
            (lA <= 0.0f || lA > 1.0f) ? 1.0f : lA,
            (sA <= 0.0f || sA > 1.0f) ? 1.0f : sA,
            (tA <= 0.0f || tA > 1.0f) ? 1.0f : tA
        };
    }
    
    MetalWorldUniforms uniforms = s_frameTemplate;
    
    bool hasGlow = (isAlias && lightmapTexture != NULL);
    
    uniforms.mvpMatrix = mvpMatrix;
    uniforms.useTexture = (diffuseTexture != NULL) ? 1 : 0;
    uniforms.useLightmap = (!isAlias && lightmapTexture != NULL) ? 1 : 0;
    uniforms.useGlow = hasGlow ? 1 : 0;
    uniforms.isTurbulent = isTurbulent ? 1 : 0;
    uniforms.time = g_metalTime;
    
    if (g_metalGunDepth) {
        uniforms.fogColorDensity = (simd_float4){ 0.0f, 0.0f, 0.0f, 0.0f };
    } else if (blendMode == 2 /* METAL_BLEND_ADDITIVE */) {
        uniforms.fogColorDensity = (simd_float4){ 0.0f, 0.0f, 0.0f, g_fogDensity };
    } else {
        uniforms.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y,
            g_fogColor.z, g_fogDensity };
    }
    
    uniforms.cameraOriginPad = (simd_float4){ g_cameraOrigin.x, g_cameraOrigin.y,
        g_cameraOrigin.z, 0.0f };
    uniforms.numDlights = g_perPixelEligible ? g_numFrameDlights : 0;
    // Для bmodels форсируем классический пайплайн, пока PBR не поддержан в world_static_fragment_main
    uniforms.pbrEnabled = 0;
    uniforms.pbrDebug   = 0;
    
    if (!s_hasCachedUniforms || memcmp(&s_lastUniformsData, &uniforms, sizeof(uniforms)) != 0) {
        uint32_t ubSize = (uint32_t)sizeof(uniforms);
        id<MTLBuffer> localUB = nil;
        NSUInteger localOffset = 0;
        
        if (MQ_UniformBuffer_Upload(&uniforms, ubSize, &localUB, &localOffset)) {
            s_cachedUB = localUB;
            s_cachedUBOffset = localOffset;
            memcpy(&s_lastUniformsData, &uniforms, sizeof(uniforms));
            s_hasCachedUniforms = true;
        } else {
            s_cachedUB = nil;
            s_hasCachedUniforms = false;
        }
    }
    
    // Avoid redundant uniform buffer rebinding on the active encoder
    if (s_cachedUB) {
        if (s_lastBoundUB != s_cachedUB || s_lastBoundUBOffset != s_cachedUBOffset) {
            [g_renderEncoder setVertexBuffer:s_cachedUB offset:s_cachedUBOffset atIndex:1];
            [g_renderEncoder setFragmentBuffer:s_cachedUB offset:s_cachedUBOffset atIndex:1];
            s_lastBoundUB = s_cachedUB;
            s_lastBoundUBOffset = s_cachedUBOffset;
        }
    } else {
        [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), 1);
        s_lastBoundUB = nil;
        s_lastBoundUBOffset = (NSUInteger)-1;
    }
    
    id<MTLTexture> blackTex = R_Metal_GetBlackTexture();
    
    if (diffuseTexture) {
        [g_renderEncoder setFragmentTexture:(__bridge id<MTLTexture>)diffuseTexture atIndex:0];
        MQEncoder_SetFragmentTexture((__bridge id<MTLTexture>)diffuseTexture, 0);
    } else {
        [g_renderEncoder setFragmentTexture:blackTex atIndex:0];
        MQEncoder_SetFragmentTexture(blackTex, 0);
    }
    
    if (lightmapTexture) {
        [g_renderEncoder setFragmentTexture:(__bridge id<MTLTexture>)lightmapTexture atIndex:1];
        MQEncoder_SetFragmentTexture((__bridge id<MTLTexture>)lightmapTexture, 1);
    } else {
        [g_renderEncoder setFragmentTexture:blackTex atIndex:1];
        MQEncoder_SetFragmentTexture(blackTex, 1);
    }
    
    if (uniforms.pbrEnabled) {
        MQ_PBR_BindMaterialTextures(NULL, NULL, NULL);
    }
    
    if (g_samplerState) {
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    }
    
    return true;
}

// Renders the pre-baked world geometry using a static VBO and dynamic IBO.
void R_Metal_Draw3DWorldIndexed(const uint32_t *indices, uint32_t indexCount,
                                simd_float4x4 mvpMatrix,
                                void *diffuseTexture, void *lightmapTexture,
                                int blendMode, bool isTurbulent,
                                const char *tag)
{
    if (!indices || indexCount == 0)
        return;
    
    if (indexCount % 3 != 0) {
        MLog(MQ_LVL_ALWAYS, "GFX·DRAW", "WARNING: %s indexCount %u not multiple of 3 — trimmed",
             tag ? tag : "?", indexCount);
        indexCount -= (indexCount % 3);
    }
    if (indexCount == 0)
        return;
    
    id<MTLBuffer> worldVB = MQ_WorldVBO_GetBuffer();
    if (!worldVB)
        return;
    
    if (!R_Metal_Setup3DWorldState(mvpMatrix, diffuseTexture, lightmapTexture,
                                   blendMode, isTurbulent, indexCount, true, tag)) {
        return;
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (indexCount / 3);
    
    // 1. Bind the persistent world vertex buffer only if not already bound
    static id<MTLBuffer> s_lastBoundWorldVB = nil;
    static id<MTLRenderCommandEncoder> s_lastVBEncoder = nil;
    if (g_renderEncoder != s_lastVBEncoder) {
        s_lastVBEncoder = g_renderEncoder;
        s_lastBoundWorldVB = nil;
    }
    if (s_lastBoundWorldVB != worldVB) {
        [g_renderEncoder setVertexBuffer:worldVB offset:0 atIndex:0];
        s_lastBoundWorldVB = worldVB;
    }
    
    // 2. Upload the compact per-frame index buffer via the dynamic ring buffer
    id<MTLBuffer> ib = nil;
    NSUInteger ibOffset = 0;
    uint32_t byteSize = indexCount * (uint32_t)sizeof(uint32_t);
    
    if (MQ_VertexBuffer_Upload(indices, byteSize, &ib, &ibOffset)) {
        [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:indexCount
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:ib
                             indexBufferOffset:ibOffset];
    } else {
        MLog(MQ_LVL_ALWAYS, "GFX·IBO", "ERROR: index ring buffer overflow (%u indices)", indexCount);
    }
}

void R_Metal_Draw3DPolygons(MetalWorldVertex *vertices, uint32_t vertexCount,
                            simd_float4x4 mvpMatrix,
                            void *diffuseTexture, void *lightmapTexture,
                            int blendMode, bool isTurbulent,
                            const char *tag)
{
    if (!vertices || vertexCount == 0)
        return;
    
    // Sanitize non-finite geometry coordinates
    for (uint32_t i = 0; i < vertexCount; i++) {
        if (isnan(vertices[i].position.x) || isinf(vertices[i].position.x) ||
            isnan(vertices[i].position.y) || isinf(vertices[i].position.y) ||
            isnan(vertices[i].position.z) || isinf(vertices[i].position.z)) {
            static int s_nanWarnCount = 0;
            if (s_nanWarnCount < 5) {
                MLog(MQ_LVL_ALWAYS, "GFX·WARN", "[%s] NaN/Inf detected in vertex %u! Sanitized to 0.",
                     tag ? tag : "?", i);
                s_nanWarnCount++;
            }
            vertices[i].position = (simd_float3){ 0.0f, 0.0f, 0.0f };
        }
    }
    
    if (vertexCount % 3 != 0) {
        MLog(MQ_LVL_ALWAYS, "GFX·DRAW", "WARNING: %s vertexCount %u not multiple of 3 — trimmed",
             tag ? tag : "?", vertexCount);
        vertexCount -= (vertexCount % 3);
    }
    if (vertexCount == 0)
        return;
    
    if (!R_Metal_Setup3DWorldState(mvpMatrix, diffuseTexture, lightmapTexture,
                                   blendMode, isTurbulent, vertexCount, false, tag)) {
        return;
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (vertexCount / 3);
    
    // Dynamic ring buffer upload for brush model geometry with chunked fallback
    {
        id<MTLBuffer> vb = nil;
        NSUInteger vbOffset = 0;
        uint32_t byteSize = vertexCount * (uint32_t)sizeof(MetalWorldVertex);
        
        if (MQ_VertexBuffer_Upload(vertices, byteSize, &vb, &vbOffset)) {
            [g_renderEncoder setVertexBuffer:vb offset:vbOffset atIndex:0];
            [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0
                                vertexCount:vertexCount];
        } else {
            static bool warned = false;
            if (!warned) {
                warned = true;
                MLog(MQ_LVL_ALWAYS, "GFX·VB",
                     "vertex ring overflow in Draw3DPolygons — falling back to setVertexBytes");
            }
            
            const uint32_t kMaxVertsPerChunk = (4096 / sizeof(MetalWorldVertex)) - ((4096 / sizeof(MetalWorldVertex)) % 3);
            uint32_t offset = 0;
            while (offset < vertexCount) {
                uint32_t count = vertexCount - offset;
                if (count > kMaxVertsPerChunk) {
                    count = kMaxVertsPerChunk;
                }
                count -= (count % 3);
                if (count == 0) {
                    break;
                }
                [g_renderEncoder setVertexBytes:&vertices[offset]
                                         length:(NSUInteger)(count * sizeof(MetalWorldVertex))
                                        atIndex:0];
                [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                    vertexStart:0
                                    vertexCount:count];
                offset += count;
            }
        }
    }
}

void R_Metal_SetGunDepthRange(bool gunDepth)
{
    if (!g_renderEncoder || !g_metalLayer) return;
    
    // Track gun depth mode to ensure Draw3DPolygons honors the compressed range instead of resetting to [0..1]
    extern bool g_metalGunDepth;
    g_metalGunDepth = gunDepth;
    
    // Frame render target dimensions (scaled when MetalFX is active), not drawable size
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : g_metalLayer.drawableSize.width;
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : g_metalLayer.drawableSize.height;
    
    // Reverse-Z: znear=0.0 (far), zfar=1.0 (near). Weapon depth range maps to [0.7 .. 1.0].
    double vpZNear = gunDepth ? 0.7 : 0.0;
    double vpZFar  = 1.0;
    MTLViewport vp = { 0.0, 0.0, vpW, vpH, vpZNear, vpZFar };
    MQEncoder_SetViewport(vp);
}

void R_Metal_SetPolygonOffset(int offset)
{
    if (!g_renderEncoder)
        return;
    
    if (offset == 0) {
        [g_renderEncoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    } else {
        // Reverse-Z: для приближения к камере глубина должна расти (+Z), поэтому bias положителен
        // В Metal: depthBias сдвигает значение после проекции. Для наклонных плоскостей увеличиваем slopeScale.
        float bias = (float)offset;
        [g_renderEncoder setDepthBias:bias slopeScale:0.0f clamp:0.0f];
    }
}

void R_Metal_DrawParticlesInstanced(const MetalParticleInstance *instances,
                                    uint32_t count,
                                    simd_float4x4 mvpMatrix,
                                    simd_float3 camOrigin,
                                    simd_float3 camVPN,
                                    simd_float3 camRight,
                                    simd_float3 camUp,
                                    void *particleTexture)
{
    if (!instances || count == 0 || !g_renderEncoder)
        return;
    
    if (!s_particlePipelineState)
        R_Metal_Init3DPipeline();
    
    if (!s_particlePipelineState)
        return;
    
    // 1. Configure 3D viewport
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp3D);
    
    // 2. Set pipeline and depth states (read Reverse-Z depth, depth writes disabled)
    MQEncoder_SetRenderPipelineState(s_particlePipelineState);
    if (g_depthStateSky)
        MQEncoder_SetDepthStencilState(g_depthStateSky);
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // 3. Assemble and upload camera uniforms (Buffer index 1)
    ParticleUniforms uniforms;
    uniforms.mvpMatrix    = mvpMatrix;
    uniforms.cameraOrigin = (simd_float4){ camOrigin.x, camOrigin.y, camOrigin.z, 0.0f };
    uniforms.cameraVPN    = (simd_float4){ camVPN.x, camVPN.y, camVPN.z, 0.0f };
    uniforms.cameraRight  = (simd_float4){ camRight.x, camRight.y, camRight.z, 0.0f };
    uniforms.cameraUp     = (simd_float4){ camUp.x, camUp.y, camUp.z, 0.0f };
    
    {
        id<MTLBuffer> ub = nil;
        NSUInteger ubOffset = 0;
        uint32_t ubSize = (uint32_t)sizeof(uniforms);
        if (MQ_UniformBuffer_Upload(&uniforms, ubSize, &ub, &ubOffset)) {
            [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:1];
        } else {
            [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        }
    }
    
    // 4. Bind texture and sampler states
    if (particleTexture) {
        MQEncoder_SetFragmentTexture((__bridge id<MTLTexture>)particleTexture, 0);
    }
    if (g_samplerState) {
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    }
    
    // 5. Upload instance array to ring buffer (Buffer index 0) and execute instanced draw
    {
        id<MTLBuffer> ib = nil;
        NSUInteger ibOffset = 0;
        uint32_t byteSize = count * (uint32_t)sizeof(MetalParticleInstance);
        
        if (MQ_VertexBuffer_Upload(instances, byteSize, &ib, &ibOffset)) {
            [g_renderEncoder setVertexBuffer:ib offset:ibOffset atIndex:0];
            [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0
                                vertexCount:6
                              instanceCount:count];
        } else {
            // Fallback path when dynamic ring buffer capacity is exceeded
            [g_renderEncoder setVertexBytes:instances length:byteSize atIndex:0];
            [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0
                                vertexCount:6
                              instanceCount:count];
        }
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (count * 2);
}

void R_Metal_Draw3DWorldBindless(const uint32_t *indices, uint32_t indexCount,
                                 simd_float4x4 mvpMatrix,
                                 void * const *diffuseTextures, uint32_t numDiffuse,
                                 void * const *lightmapTextures, uint32_t numLightmaps,
                                 const char *tag)
{
    if (!indices || indexCount == 0 || !g_renderEncoder)
        return;
    
    id<MTLBuffer> worldVB = MQ_WorldVBO_GetBuffer();
    if (!worldVB)
        return;
    
    if (!s_worldStaticPipelineState)
        R_Metal_Init3DPipeline();
    
    // 1. Configure frame viewport
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp3D);
    
    // 2. Configure pipeline states; switch to hardware ray tracing if active
    id<MTLRenderPipelineState> rtStaticPipe = MQ_RT_GetStaticWorldPipeline();
    bool useRT = (MQ_RT_IsEnabled() && rtStaticPipe && MQ_RT_GetWorldTLAS() != nil);
    
    if (useRT) {
        MQEncoder_SetRenderPipelineState(rtStaticPipe);
        MQ_RT_BindResources(g_renderEncoder);
    } else {
        MQEncoder_SetRenderPipelineState(s_worldStaticPipelineState ?: g_worldPipelineState);
    }
    
    if (g_depthState3D)
        MQEncoder_SetDepthStencilState(g_depthState3D);
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // 3. Assemble frame uniforms (Buffer index 1)
    if (g_renderEncoder != s_lastEncoderRef) {
        s_lastEncoderRef = g_renderEncoder;
        memset(&s_frameTemplate, 0, sizeof(s_frameTemplate));
        memcpy(s_frameTemplate.dlights, g_frameDlights, sizeof(g_frameDlights));
    }
    MetalWorldUniforms uniforms = s_frameTemplate;
    uniforms.mvpMatrix = mvpMatrix;
    uniforms.useTexture = 1;
    uniforms.useLightmap = 1;
    uniforms.isTurbulent = 0;
    uniforms.time = g_metalTime;
    uniforms.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y, g_fogColor.z, g_fogDensity };
    uniforms.cameraOriginPad = (simd_float4){ g_cameraOrigin.x, g_cameraOrigin.y, g_cameraOrigin.z, 0.0f };
    uniforms.numDlights = g_perPixelEligible ? g_numFrameDlights : 0;
    uniforms.pbrEnabled = 0;
    uniforms.pbrDebug   = 0;
    
    id<MTLBuffer> ub = nil;
    NSUInteger ubOffset = 0;
    if (MQ_UniformBuffer_Upload(&uniforms, sizeof(uniforms), &ub, &ubOffset)) {
        [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:1];
        [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:1];
    } else {
        [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), 1);
    }
    
    // 4. Bind pre-baked Tier 2 Argument Buffer for static world diffuse textures (Buffer slot 2)
    id<MTLBuffer> matBuffer = MQ_WorldMaterialBuffer_GetBuffer();
    if (matBuffer) {
        MQ_WorldMaterialBuffer_BindResident(g_renderEncoder);
        [g_renderEncoder setFragmentBuffer:matBuffer offset:0 atIndex:2];
    }
    
    // 5. Bind unified world lightmaps 2D texture array (texture slot 127)
    id<MTLTexture> lmArray = MQ_WorldLightmapArray_GetTexture();
    if (lmArray) {
        [g_renderEncoder setFragmentTexture:lmArray atIndex:127];
    } else {
        [g_renderEncoder setFragmentTexture:R_Metal_GetBlackTexture() atIndex:127];
    }
    
    if (g_samplerState) {
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    }
    
    // 6. Bind persistent world vertex buffer (Buffer index 0)
    [g_renderEncoder setVertexBuffer:worldVB offset:0 atIndex:0];
    
    // 7. Upload accumulated frame indices to dynamic index buffer and issue draw call
    id<MTLBuffer> ib = nil;
    NSUInteger ibOffset = 0;
    uint32_t byteSize = indexCount * (uint32_t)sizeof(uint32_t);
    
    if (MQ_VertexBuffer_Upload(indices, byteSize, &ib, &ibOffset)) {
        [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:indexCount
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:ib
                             indexBufferOffset:ibOffset];
    } else {
        MLog(MQ_LVL_ALWAYS, "GFX·IBO", "ERROR: index ring overflow in Draw3DWorldBindless (%u indices)", indexCount);
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (indexCount / 3);
    
    // Invalidate uniform cache state
    s_hasCachedUniforms = false;
    s_lastBoundUB = nil;
    s_lastBoundUBOffset = (NSUInteger)-1;
    memset(&s_lastUniformsData, 0, sizeof(s_lastUniformsData));
    
    // Reset buffer slot 2 and lightmap slot to unbind static world resources
    [g_renderEncoder setFragmentBuffer:nil offset:0 atIndex:2];
    id<MTLTexture> blackTex = R_Metal_GetBlackTexture();
    [g_renderEncoder setFragmentTexture:blackTex atIndex:127];
}

void R_Metal_Draw3DWorldTurbulentBindless(const uint32_t *indices, uint32_t indexCount,
                                          simd_float4x4 mvpMatrix,
                                          void * const *diffuseTextures, uint32_t numDiffuse,
                                          const char *tag)
{
    if (!indices || indexCount == 0 || !g_renderEncoder)
        return;
    
    id<MTLBuffer> worldVB = MQ_WorldVBO_GetBuffer();
    if (!worldVB)
        return;
    
    if (!s_worldTurbulentPipelineState)
        R_Metal_Init3DPipeline();
    
    // 1. Configure viewport
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp3D);
    
    // 2. Configure pipeline and depth states (Read-only depth for liquids)
    MQEncoder_SetRenderPipelineState(s_worldTurbulentPipelineState ?: g_worldBlendedPipelineState);
    
    if (!s_depthStateWater && g_device) {
        MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
        dsDesc.depthCompareFunction = MTLCompareFunctionGreaterEqual;
        dsDesc.depthWriteEnabled = NO;
        s_depthStateWater = [g_device newDepthStencilStateWithDescriptor:dsDesc];
    }
    
    if (s_depthStateWater) {
        MQEncoder_SetDepthStencilState(s_depthStateWater);
        [g_renderEncoder setDepthStencilState:s_depthStateWater];
    }
    
    MQEncoder_SetCullMode(MTLCullModeNone);
    [g_renderEncoder setCullMode:MTLCullModeNone];
    
    // 3. Assemble frame uniforms (Buffer index 1)
    if (g_renderEncoder != s_lastEncoderRef) {
        s_lastEncoderRef = g_renderEncoder;
        memset(&s_frameTemplate, 0, sizeof(s_frameTemplate));
        memcpy(s_frameTemplate.dlights, g_frameDlights, sizeof(g_frameDlights));
    }
    MetalWorldUniforms uniforms = s_frameTemplate;
    uniforms.mvpMatrix = mvpMatrix;
    uniforms.useTexture = 1;
    uniforms.useLightmap = 1;
    uniforms.isTurbulent = 1;
    uniforms.time = g_metalTime;
    uniforms.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y, g_fogColor.z, g_fogDensity };
    uniforms.cameraOriginPad = (simd_float4){ g_cameraOrigin.x, g_cameraOrigin.y, g_cameraOrigin.z, 0.0f };
    uniforms.numDlights = 0; // Liquids are lit via lightmaps and ambient warp
    uniforms.pbrEnabled = 0;
    uniforms.pbrDebug   = 0;
    
    id<MTLBuffer> ub = nil;
    NSUInteger ubOffset = 0;
    if (MQ_UniformBuffer_Upload(&uniforms, sizeof(uniforms), &ub, &ubOffset)) {
        [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:1];
        [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:1];
    } else {
        [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), 1);
    }
    
    // 4. Bind pre-baked Tier 2 Argument Buffer for static world diffuse textures (Buffer slot 2)
    id<MTLBuffer> matBuffer = MQ_WorldMaterialBuffer_GetBuffer();
    if (matBuffer) {
        MQ_WorldMaterialBuffer_BindResident(g_renderEncoder);
        [g_renderEncoder setFragmentBuffer:matBuffer offset:0 atIndex:2];
    }
    
    // 5. Bind unified world lightmaps 2D texture array (texture slot 127)
    id<MTLTexture> lmArray = MQ_WorldLightmapArray_GetTexture();
    if (lmArray) {
        [g_renderEncoder setFragmentTexture:lmArray atIndex:127];
    } else {
        [g_renderEncoder setFragmentTexture:R_Metal_GetBlackTexture() atIndex:127];
    }
    
    if (g_samplerState) {
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    }
    
    // 6. Bind persistent world vertex buffer (Buffer index 0)
    [g_renderEncoder setVertexBuffer:worldVB offset:0 atIndex:0];
    
    [g_renderEncoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    
    // 7. Upload dynamic index buffer and issue single draw call for all liquids
    id<MTLBuffer> ib = nil;
    NSUInteger ibOffset = 0;
    uint32_t byteSize = indexCount * (uint32_t)sizeof(uint32_t);
    
    if (MQ_VertexBuffer_Upload(indices, byteSize, &ib, &ibOffset)) {
        [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:indexCount
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:ib
                             indexBufferOffset:ibOffset];
    } else {
        MLog(MQ_LVL_ALWAYS, "GFX·IBO", "ERROR: index ring overflow in Draw3DWorldTurbulentBindless (%u indices)", indexCount);
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (indexCount / 3);
    
    // Reset buffer slot 2 and lightmap slot
    [g_renderEncoder setFragmentBuffer:nil offset:0 atIndex:2];
    id<MTLTexture> blackTex = R_Metal_GetBlackTexture();
    [g_renderEncoder setFragmentTexture:blackTex atIndex:127];
}

void R_Metal_DrawSpriteBatch(MetalWorldVertex *vertices, uint32_t vertexCount,
                             simd_float4x4 mvpMatrix,
                             void * const *textures, uint32_t textureCount)
{
    if (!vertices || vertexCount == 0 || !g_renderEncoder || !textures || textureCount == 0)
        return;
    
    if (!s_spriteBatchPipelineState)
        R_Metal_Init3DPipeline();
    
    if (!s_spriteBatchPipelineState)
        return;
    
    // 1. Viewport setup
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp3D);
    
    // 2. States: Sprite pipeline, Read-only Reverse-Z depth, No culling
    MQEncoder_SetRenderPipelineState(s_spriteBatchPipelineState);
    if (g_depthStateSky)
        MQEncoder_SetDepthStencilState(g_depthStateSky);
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // 3. Uniforms (MVP + Fog)
    MetalWorldUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    uniforms.mvpMatrix = mvpMatrix;
    uniforms.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y, g_fogColor.z, g_fogDensity };
    uniforms.time = g_metalTime;
    
    id<MTLBuffer> ub = nil;
    NSUInteger ubOffset = 0;
    if (MQ_UniformBuffer_Upload(&uniforms, sizeof(uniforms), &ub, &ubOffset)) {
        [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:1];
        [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:1];
    } else {
        [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), 1);
    }
    
    // 4. Bind array of up to 16 sprite textures in slot 0..15
    id<MTLTexture> texturesToBind[16];
    id<MTLTexture> blackTex = R_Metal_GetBlackTexture();
    for (uint32_t t = 0; t < 16; t++) {
        texturesToBind[t] = (t < textureCount && textures[t]) ? (__bridge id<MTLTexture>)textures[t] : blackTex;
    }
    [g_renderEncoder setFragmentTextures:texturesToBind withRange:NSMakeRange(0, 16)];
    
    if (g_samplerState) {
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    }
    
    // 5. Upload vertices & Draw
    id<MTLBuffer> vb = nil;
    NSUInteger vbOffset = 0;
    uint32_t byteSize = vertexCount * (uint32_t)sizeof(MetalWorldVertex);
    
    if (MQ_VertexBuffer_Upload(vertices, byteSize, &vb, &vbOffset)) {
        [g_renderEncoder setVertexBuffer:vb offset:vbOffset atIndex:0];
        [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0
                            vertexCount:vertexCount];
    } else {
        [g_renderEncoder setVertexBytes:vertices length:byteSize atIndex:0];
        [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0
                            vertexCount:vertexCount];
    }
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (vertexCount / 3);
}

// =========================================================================
// ALIAS MODEL GPU MESH MANAGEMENT (Metal 3)
// =========================================================================

void *R_Metal_AliasCreateMesh(const void *indices, uint32_t indexCount,
                              const void *uvs, uint32_t vertCount,
                              const void *poses, uint32_t numPoses, uint32_t poseVerts)
{
    if (!g_device || !indices || indexCount == 0 || !uvs || vertCount == 0 || !poses) {
        return NULL;
    }
    
    MetalAliasMesh *mesh = (MetalAliasMesh *)calloc(1, sizeof(MetalAliasMesh));
    if (!mesh) return NULL;
    
    // 1. Index buffer (uint16_t)
    NSUInteger indexBytes = (NSUInteger)indexCount * sizeof(uint16_t);
    id<MTLBuffer> ib = [g_device newBufferWithBytes:indices
                                             length:indexBytes
                                            options:MTLResourceStorageModeShared];
    ib.label = @"MQ Alias Model Index Buffer";
    mesh->indexBuffer = (__bridge_retained void *)ib;
    mesh->indexCount = indexCount;
    
    // 2. Static UV coordinates buffer (MetalAliasVertex: simd_float2)
    NSUInteger uvBytes = (NSUInteger)vertCount * sizeof(MetalAliasVertex);
    id<MTLBuffer> uvb = [g_device newBufferWithBytes:uvs
                                              length:uvBytes
                                             options:MTLResourceStorageModeShared];
    uvb.label = @"MQ Alias Model UV Buffer";
    mesh->uvBuffer = (__bridge_retained void *)uvb;
    mesh->vertCount = vertCount;
    
    // 3. Pose frames buffer (MetalAliasQuantizedVertex: 4 bytes per vertex)
    NSUInteger totalPoseVerts = (NSUInteger)numPoses * (NSUInteger)poseVerts;
    NSUInteger poseBytes = totalPoseVerts * sizeof(MetalAliasQuantizedVertex);
    id<MTLBuffer> pb = [g_device newBufferWithBytes:poses
                                             length:poseBytes
                                            options:MTLResourceStorageModeShared];
    pb.label = @"MQ Alias Model Poses Buffer";
    mesh->poseBuffer = (__bridge_retained void *)pb;
    mesh->numPoses = numPoses;
    mesh->poseVerts = poseVerts;
    
    return (void *)mesh;
}

void R_Metal_AliasFreeMesh(void *gpuMeshHandle)
{
    if (!gpuMeshHandle) return;
    
    MetalAliasMesh *mesh = (MetalAliasMesh *)gpuMeshHandle;
    
    if (mesh->indexBuffer) {
        id<MTLBuffer> ib = (__bridge_transfer id<MTLBuffer>)mesh->indexBuffer;
        ib = nil;
        mesh->indexBuffer = NULL;
    }
    
    if (mesh->uvBuffer) {
        id<MTLBuffer> uvb = (__bridge_transfer id<MTLBuffer>)mesh->uvBuffer;
        uvb = nil;
        mesh->uvBuffer = NULL;
    }
    
    if (mesh->poseBuffer) {
        id<MTLBuffer> pb = (__bridge_transfer id<MTLBuffer>)mesh->poseBuffer;
        pb = nil;
        mesh->poseBuffer = NULL;
    }
    
    free(mesh);
}

void R_Metal_DrawAliasMeshInstanced(void *gpuMeshHandle,
                                    const MetalAliasInstanceData *instances,
                                    uint32_t instanceCount,
                                    void *diffuseTexture, void *glowTexture,
                                    int blendMode, const char *tag)
{
    if (!gpuMeshHandle || !instances || instanceCount == 0 || !g_renderEncoder)
        return;
    
    MetalAliasMesh *mesh = (MetalAliasMesh *)gpuMeshHandle;
    id<MTLBuffer> ib = (__bridge id<MTLBuffer>)mesh->indexBuffer;
    id<MTLBuffer> uvb = (__bridge id<MTLBuffer>)mesh->uvBuffer;
    id<MTLBuffer> pb = (__bridge id<MTLBuffer>)mesh->poseBuffer;
    
    if (!ib || !uvb || !pb || mesh->indexCount == 0)
        return;
    
    if (!s_aliasGpuPipelineState)
        R_Metal_Init3DPipeline();
    
    // 1. Configure viewport (gun depth is always disabled for batched world instances)
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    double vpZNear = 0.0;
    double vpZFar  = 1.0;
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, vpZNear, vpZFar };
    MQEncoder_SetViewport(vp3D);
    
    // 2. Select pipeline and depth state
    if (blendMode == METAL_BLEND_ALPHA) {
        MQEncoder_SetRenderPipelineState(s_aliasGpuBlendedPipelineState);
        if (g_depthStateSky)
            MQEncoder_SetDepthStencilState(g_depthStateSky); // Read-only depth GreaterEqual
    } else {
        MQEncoder_SetRenderPipelineState(s_aliasGpuPipelineState);
        if (g_depthState3D)
            MQEncoder_SetDepthStencilState(g_depthState3D); // Depth write GreaterEqual
    }
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // 3. Bind static UV buffer (slot 0) and pose buffer (slot 1)
    [g_renderEncoder setVertexBuffer:uvb offset:0 atIndex:0];
    [g_renderEncoder setVertexBuffer:pb offset:0 atIndex:1];
    
    // 4. Upload instance array to ring buffer (slot 2)
    {
        id<MTLBuffer> instBuf = nil;
        NSUInteger instOffset = 0;
        uint32_t byteSize = instanceCount * (uint32_t)sizeof(MetalAliasInstanceData);
        
        if (MQ_VertexBuffer_Upload(instances, byteSize, &instBuf, &instOffset)) {
            [g_renderEncoder setVertexBuffer:instBuf offset:instOffset atIndex:2];
        } else {
            [g_renderEncoder setVertexBytes:instances length:byteSize atIndex:2];
        }
    }
    
    // 5. Upload batch uniforms (slot 3)
    {
        MetalAliasBatchUniforms batchUni;
        batchUni.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y, g_fogColor.z, g_fogDensity };
        batchUni.useGlow = (glowTexture != NULL) ? 1 : 0;
        batchUni._pad[0] = batchUni._pad[1] = batchUni._pad[2] = 0;
        
        id<MTLBuffer> ub = nil;
        NSUInteger ubOffset = 0;
        if (MQ_UniformBuffer_Upload(&batchUni, sizeof(batchUni), &ub, &ubOffset)) {
            [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:3];
            [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:3];
        } else {
            [g_renderEncoder setVertexBytes:&batchUni length:sizeof(batchUni) atIndex:3];
            [g_renderEncoder setFragmentBytes:&batchUni length:sizeof(batchUni) atIndex:3];
        }
    }
    
    // 6. Bind diffuse and glow textures
    id<MTLTexture> baseTex = diffuseTexture ? (__bridge id<MTLTexture>)diffuseTexture : R_Metal_GetBlackTexture();
    id<MTLTexture> fbrTex  = glowTexture    ? (__bridge id<MTLTexture>)glowTexture    : R_Metal_GetBlackTexture();
    
    [g_renderEncoder setFragmentTexture:baseTex atIndex:0];
    [g_renderEncoder setFragmentTexture:fbrTex  atIndex:1];
    
    if (s_aliasModelSampler) {
        MQEncoder_SetFragmentSamplerState(s_aliasModelSampler, 0);
    }
    
    // 7. Issue single instanced draw call
    [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:mesh->indexCount
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:ib
                         indexBufferOffset:0
                             instanceCount:instanceCount];
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (mesh->indexCount / 3) * instanceCount;
}

void R_Metal_DrawAliasModelGPU(void *gpuMeshHandle,
                               uint32_t pose1, uint32_t pose2,
                               const MetalAliasUniforms *uniforms,
                               void *diffuseTexture, void *glowTexture,
                               int blendMode, const char *tag)
{
    if (!gpuMeshHandle || !uniforms || !g_renderEncoder)
        return;
    
    MetalAliasMesh *mesh = (MetalAliasMesh *)gpuMeshHandle;
    id<MTLBuffer> ib = (__bridge id<MTLBuffer>)mesh->indexBuffer;
    id<MTLBuffer> uvb = (__bridge id<MTLBuffer>)mesh->uvBuffer;
    id<MTLBuffer> pb = (__bridge id<MTLBuffer>)mesh->poseBuffer;
    
    if (!ib || !uvb || !pb || mesh->indexCount == 0)
        return;
    
    if (!s_aliasGpuPipelineState)
        R_Metal_Init3DPipeline();
    
    // 1. Configure viewport (handling gun depth compression [0.7..1.0] for viewmodel)
    extern bool g_metalGunDepth;
    double vpW = (g_mqRenderTargetW > 0) ? (double)g_mqRenderTargetW
    : (g_metalLayer ? g_metalLayer.drawableSize.width : 800.0);
    double vpH = (g_mqRenderTargetH > 0) ? (double)g_mqRenderTargetH
    : (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0);
    double vpZNear = g_metalGunDepth ? 0.7 : 0.0;
    double vpZFar  = 1.0;
    MTLViewport vp3D = { 0.0, 0.0, vpW, vpH, vpZNear, vpZFar };
    MQEncoder_SetViewport(vp3D);
    
    // 2. Select pipeline and depth state
    if (blendMode == METAL_BLEND_ALPHA) {
        MQEncoder_SetRenderPipelineState(s_aliasGpuBlendedPipelineState);
        if (g_depthStateSky)
            MQEncoder_SetDepthStencilState(g_depthStateSky);
    } else {
        MQEncoder_SetRenderPipelineState(s_aliasGpuPipelineState);
        if (g_depthState3D)
            MQEncoder_SetDepthStencilState(g_depthState3D);
    }
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // 3. Bind static UV buffer (slot 0) and pose buffer (slot 1)
    [g_renderEncoder setVertexBuffer:uvb offset:0 atIndex:0];
    [g_renderEncoder setVertexBuffer:pb offset:0 atIndex:1];
    
    // 4. Upload single instance to slot 2
    MetalAliasInstanceData inst = *uniforms;
    {
        id<MTLBuffer> instBuf = nil;
        NSUInteger instOffset = 0;
        if (MQ_VertexBuffer_Upload(&inst, sizeof(inst), &instBuf, &instOffset)) {
            [g_renderEncoder setVertexBuffer:instBuf offset:instOffset atIndex:2];
        } else {
            [g_renderEncoder setVertexBytes:&inst length:sizeof(inst) atIndex:2];
        }
    }
    
    // 5. Upload batch uniforms to slot 3
    {
        MetalAliasBatchUniforms batchUni;
        if (g_metalGunDepth) {
            batchUni.fogColorDensity = (simd_float4){ 0.0f, 0.0f, 0.0f, 0.0f };
        } else {
            batchUni.fogColorDensity = (simd_float4){ g_fogColor.x, g_fogColor.y, g_fogColor.z, g_fogDensity };
        }
        batchUni.useGlow = (glowTexture != NULL) ? 1 : 0;
        batchUni._pad[0] = batchUni._pad[1] = batchUni._pad[2] = 0;
        
        id<MTLBuffer> ub = nil;
        NSUInteger ubOffset = 0;
        if (MQ_UniformBuffer_Upload(&batchUni, sizeof(batchUni), &ub, &ubOffset)) {
            [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:3];
            [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:3];
        } else {
            [g_renderEncoder setVertexBytes:&batchUni length:sizeof(batchUni) atIndex:3];
            [g_renderEncoder setFragmentBytes:&batchUni length:sizeof(batchUni) atIndex:3];
        }
    }
    
    // 6. Bind diffuse and glow textures
    id<MTLTexture> baseTex = diffuseTexture ? (__bridge id<MTLTexture>)diffuseTexture : R_Metal_GetBlackTexture();
    id<MTLTexture> fbrTex  = glowTexture    ? (__bridge id<MTLTexture>)glowTexture    : R_Metal_GetBlackTexture();
    
    [g_renderEncoder setFragmentTexture:baseTex atIndex:0];
    [g_renderEncoder setFragmentTexture:fbrTex  atIndex:1];
    
    if (s_aliasModelSampler) {
        MQEncoder_SetFragmentSamplerState(s_aliasModelSampler, 0);
    }
    
    // 7. Draw single instance
    [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:mesh->indexCount
                                 indexType:MTLIndexTypeUInt16
                               indexBuffer:ib
                         indexBufferOffset:0
                             instanceCount:1];
    
    g_mqStatDrawCalls++;
    g_mqStatWorldPolys += (mesh->indexCount / 3);
}
