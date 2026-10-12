//
//  mq_context.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Metal context management: device, command queue, sampler state,
//  and depth-stencil states. Native Cocoa window layer is owned by
//  vid_macos.m (QuakeCore) and passed via R_Metal_SetLayer and
//  R_Metal_ConfigureNativeWindow.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "mq_pbr.h"
#import "mq_rt.h"
#import "quakedef.h"

// Global context variable definitions
id<MTLDevice> g_device = nil;
id<MTLCommandQueue> g_commandQueue = nil;
CAMetalLayer *g_metalLayer = nil;

id<MTLSamplerState> g_samplerState = nil;
id<MTLDepthStencilState> g_depthState2D = nil;
id<MTLDepthStencilState> g_depthState3D = nil;
id<MTLDepthStencilState> g_depthStateSky = nil;
id<MTLBuffer> g_uiVertexBuffer = nil;
id<MTLBuffer> g_fullscreenQuadBuffer = nil;

// Anisotropic filtering control cvar
cvar_t gl_texture_anisotropy = {"gl_texture_anisotropy", "16", CVAR_ARCHIVE};
extern cvar_t r_mq_bloom_quality; // Defined in mq_frame_textures.m

// PBR control cvars
cvar_t r_pbr       = {"r_pbr", "0", CVAR_ARCHIVE};
cvar_t r_pbr_debug = {"r_pbr_debug", "0", 0};

// Hardware ray tracing control cvar
cvar_t r_rt        = {"r_rt", "0", CVAR_ARCHIVE};

bool R_PBR_IsEnabled(void)
{
    return r_pbr.value != 0.0f;
}

int R_PBR_GetDebugMode(void)
{
    return (int)r_pbr_debug.value;
}

bool R_RT_IsEnabled(void)
{
    return r_rt.value != 0.0f;
}

void R_Metal_UpdateSampler(void)
{
    if (!g_device) return;
    
    NSUInteger aniso = (NSUInteger)gl_texture_anisotropy.value;
    if (aniso < 1) aniso = 1;
    if (aniso > 16) aniso = 16;
    
    MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    
    // Critical for alias models: NotMipmapped disables sampling non-existent mip levels for .mdl files
    samplerDesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
    
    samplerDesc.maxAnisotropy = aniso;
    samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    
    g_samplerState = [g_device newSamplerStateWithDescriptor:samplerDesc];
    
    // Log sampler configuration details in development profile
    MLog(MQ_LVL_DEV, "INIT", "Sampler: min/mag=Linear mipFilter=%s maxAniso=%lu",
         samplerDesc.mipFilter == MTLSamplerMipFilterNotMipmapped ? "NotMipmapped" :
         samplerDesc.mipFilter == MTLSamplerMipFilterLinear ? "Linear" : "Nearest",
         (unsigned long)aniso);
}

static void R_Anisotropy_Callback(cvar_t *var)
{
    R_Metal_UpdateSampler();
}

void R_Metal_Init(void)
{
    if (g_device) return;
    
    // 1. Initialize default system Metal device
    g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) {
        MLog(MQ_LVL_ALWAYS, "INIT", "ERROR: Metal 3 is not supported on this device");
        return;
    }
    
    // Device name is critical for diagnostics across all profiles
    MLog(MQ_LVL_ALWAYS, "INIT", "Metal device: %s", g_device.name.UTF8String);
    
    // Renderer compilation timestamp for tracking binary freshness
    MLog(MQ_LVL_ALWAYS, "INIT", "renderer build: %s %s", __DATE__, __TIME__);
    
    if (!g_validTextures) {
        g_validTextures = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    }
    
    // 2. Register cvars and build default texture sampler
    static bool s_cvarsRegistered = false;
    if (!s_cvarsRegistered) {
        Cvar_RegisterVariable(&gl_texture_anisotropy);
        Cvar_SetCallback(&gl_texture_anisotropy, R_Anisotropy_Callback);
        Cvar_RegisterVariable(&r_mq_bloom_quality);
        Cvar_RegisterVariable(&r_pbr);
        Cvar_RegisterVariable(&r_pbr_debug);
        Cvar_RegisterVariable(&r_rt);
        s_cvarsRegistered = true;
    }
    R_Metal_UpdateSampler();
    
    // 3. Create Metal command queue
    g_commandQueue = [g_device newCommandQueue];
    
    // 4. Create depth-stencil states for 2D UI and 3D scenes
    // Reverse-Z convention: GreaterEqual comparison where near objects have Z close to 1.0
    MTLDepthStencilDescriptor *depthDesc3D = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc3D.depthCompareFunction = MTLCompareFunctionGreaterEqual;
    depthDesc3D.depthWriteEnabled = YES;
    g_depthState3D = [g_device newDepthStencilStateWithDescriptor:depthDesc3D];
    
    MTLDepthStencilDescriptor *depthDescSky = [[MTLDepthStencilDescriptor alloc] init];
    depthDescSky.depthCompareFunction = MTLCompareFunctionGreaterEqual;
    depthDescSky.depthWriteEnabled = NO;  // Disable depth writes for sky and cloud surfaces
    g_depthStateSky = [g_device newDepthStencilStateWithDescriptor:depthDescSky];
    
    MTLDepthStencilDescriptor *depthDesc2D = [[MTLDepthStencilDescriptor alloc] init];
    depthDesc2D.depthCompareFunction = MTLCompareFunctionAlways; // 2D overlays always pass
    depthDesc2D.depthWriteEnabled = NO;                          // 2D passes do not write to depth
    g_depthState2D = [g_device newDepthStencilStateWithDescriptor:depthDesc2D];
    
    // 5. Shader library initialization
    id<MTLLibrary> defaultLibrary = [g_device newDefaultLibrary];
    if (!defaultLibrary) {
        printf("[Metal Error] Failed to load defaultLibrary!\n");
        return;
    }
    
    // UI and World pipelines are built lazily in BeginFrame matching the final target format.
    // Build the classic gamma pipeline immediately.
    MQ_Pipelines_BuildGamma(defaultLibrary);
    
    // 6. 2D UI vertex buffer
    if (!g_uiVertexBuffer) {
        g_uiVertexBuffer = [g_device newBufferWithLength:sizeof(MetalVertex) * MAX_2D_VERTICES
                                                 options:MTLResourceStorageModeShared];
    }
    
    // 7. Initialize PBR subsystem and fallback textures
    MQ_PBR_Init(g_device);
    
    // 8. Initialize hardware ray tracing subsystem
    MQ_RT_Init(g_device);
    
    // Static fullscreen quad for post-processing passes
    static const float kFullscreenQuadPositions[6][2] = {
        { -1.0f, -1.0f }, {  1.0f, -1.0f }, {  1.0f,  1.0f },
        { -1.0f, -1.0f }, {  1.0f,  1.0f }, { -1.0f,  1.0f }
    };
    
    if (!g_fullscreenQuadBuffer) {
        g_fullscreenQuadBuffer = [g_device newBufferWithBytes:kFullscreenQuadPositions
                                                       length:sizeof(kFullscreenQuadPositions)
                                                      options:MTLResourceStorageModeShared];
        g_fullscreenQuadBuffer.label = @"MQ Fullscreen Quad VB";
    }
}

void R_Metal_SetLayer(void *layer)
{
    if (layer) {
        g_metalLayer = (__bridge CAMetalLayer *)layer;
        // Prevent nextDrawable from stalling the main thread indefinitely
        g_metalLayer.allowsNextDrawableTimeout = YES;
        // Framebuffer readback requires framebufferOnly = NO when MQ_READBACK=1 is set.
        // Must be configured prior to acquiring the first drawable.
        if (getenv("MQ_READBACK"))
            g_metalLayer.framebufferOnly = NO;
    } else {
        MLog(MQ_LVL_ALWAYS, "INIT", "ERROR: R_Metal_SetLayer(nil) — frames will not be encoded");
    }
}
