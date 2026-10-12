//
//  mq_frame_textures.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Per-frame texture lifecycle: depth, offscreen scene,
//  bloom ping-pong, and MetalFX intermediate render targets.
//  Texture reallocations utilize a 2-frame debounce window to avoid
//  excessive 4K texture churn during macOS fullscreen window animations.
//

#import <Metal/Metal.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "quakedef.h"

extern cvar_t vid_fsaa; // Defined in vid_macos.m
cvar_t r_mq_bloom_quality = {"r_mq_bloom_quality", "0", CVAR_ARCHIVE}; // 0 = half-res, 1 = quarter-res

id<MTLTexture> g_depthTexture = nil;        // Resolved depth (consumed by motion pass and MetalFX)
id<MTLTexture> g_depthTextureMSAA = nil;    // MSAA depth target (nil if fsaa is disabled)
id<MTLTexture> g_sceneTexture = nil;        // Resolved scene (consumed by post-process and MetalFX)
id<MTLTexture> g_sceneTextureMSAA = nil;    // MSAA color target (nil if fsaa is disabled)
id<MTLTexture> g_bloomTexA = nil;
id<MTLTexture> g_bloomTexB = nil;
id<MTLTexture> g_fxIntermediate = nil;      // Full-resolution RGBA16Float destination for MetalFX upscaler

// Evaluates vid_fsaa into a supported sample count verified against device capabilities.
// Degrades gracefully (8x -> 4x -> 2x) based on hardware support limits.
int MQ_MSAASampleCount(void)
{
    static int cached = -1;
    if (cached >= 0) return cached;

    int want = (int)vid_fsaa.value;
    if (want < 2) { cached = 0; return 0; }
    if (want > 8) want = 8;

    // Graceful degradation: 8 -> 4 -> 2 based on device support
    static const int candidates[] = { 8, 4, 2 };
    for (unsigned i = 0; i < sizeof(candidates)/sizeof(candidates[0]); i++) {
        int s = candidates[i];
        if (s > want) continue;
        if ([g_device supportsTextureSampleCount:s]) {
            if (s != want)
                MLog(MQ_LVL_ALWAYS, "MQ-MSAA",
                     "vid_fsaa %d → %dx (device limit)", want, s);
            cached = s;
            return s;
        }
    }
    MLog(MQ_LVL_ALWAYS, "MQ-MSAA", "MSAA is unsupported on this device");
    cached = 0;
    return 0;
}

// Returns rasterSampleCount for pipeline descriptors.
// In Metal, rasterSampleCount must be at least 1; 0 is invalid and fails pipeline creation.
NSUInteger MQ_PSOSampleCount(void)
{
    int s = MQ_MSAASampleCount();
    return s > 1 ? (NSUInteger)s : 1;
}

// Initial depth texture allocation without debounce
static void R_Metal_CreateDepthTexture(NSUInteger width, NSUInteger height)
{
    if (!g_device || width == 0 || height == 0) return;
    const int samples = MQ_MSAASampleCount();

    // Resolved depth: consumed by motion vector passes and MetalFX temporal upscaler
    MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    depthDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    depthDesc.storageMode = MTLStorageModePrivate;
    g_depthTexture = [g_device newTextureWithDescriptor:depthDesc];

    // Multisampling depth attachment with depth resolve
    if (samples > 1)
    {
        MTLTextureDescriptor *msDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                           width:width
                                                                                          height:height
                                                                                       mipmapped:NO];
        msDesc.usage = MTLTextureUsageRenderTarget;
        // On Apple Silicon TBDR, memoryless storage keeps MSAA samples strictly in on-chip Tile SRAM
        if ([g_device supportsFamily:MTLGPUFamilyApple1]) {
            msDesc.storageMode = MTLStorageModeMemoryless;
        } else {
            msDesc.storageMode = MTLStorageModePrivate;
        }
        msDesc.textureType = MTLTextureType2DMultisample;
        msDesc.sampleCount = samples;
        // Note: depthResolveFilter is configured on the render pass descriptor, not the texture descriptor
        g_depthTextureMSAA = [g_device newTextureWithDescriptor:msDesc];
    }
    else
    {
        g_depthTextureMSAA = nil;
    }
}

void R_Metal_UpdateDepthTexture(NSUInteger width, NSUInteger height)
{
    if (!g_device || width == 0 || height == 0) return;

    // Debounce logic: during fullscreen transitions, drawableSize can fluctuate every frame.
    // Wait for 2 consecutive stable frames of matching dimensions before reallocating textures.
    static NSUInteger pendingW = 0, pendingH = 0;
    static int stableFrames = 0;

    // Allocate immediately if uninitialized
    if (!g_depthTexture) {
        R_Metal_CreateDepthTexture(width, height);
        return;
    }

    // Reallocate only if dimensions or MSAA configuration deviate from current state
    const BOOL msaaOk = (MQ_MSAASampleCount() > 1) == (g_depthTextureMSAA != nil);
    if (g_depthTexture.width == width && g_depthTexture.height == height && msaaOk) {
        pendingW = pendingH = 0;
        stableFrames = 0;
        return;
    }

    if (pendingW == width && pendingH == height) {
        if (++stableFrames < 2)
            return; // Await confirmation on next frame
    } else {
        pendingW = width;
        pendingH = height;
        stableFrames = 1;
        return; // Dimension changed again; reset debounce
    }

    R_Metal_CreateDepthTexture(width, height);
    MLog(MQ_LVL_DEV, "GFX·DEPTH", "depth texture created %ux%u (msaa=%d)",
         (unsigned)width, (unsigned)height, MQ_MSAASampleCount());
}

// Allocates or reallocates scene color targets: MSAA render target and resolved texture
static void MQ_CreateSceneTexture(NSUInteger width, NSUInteger height, int samples)
{
    // Resolved color target: read by tonemapping, bloom, and MetalFX passes
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:g_sceneFormat
                                                                                    width:width height:height mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    g_sceneTexture = [g_device newTextureWithDescriptor:desc];

    if (samples > 1)
    {
        MTLTextureDescriptor *msDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:g_sceneFormat
                                                                                           width:width height:height mipmapped:NO];
        msDesc.usage = MTLTextureUsageRenderTarget;
        // On Apple Silicon TBDR, allocate MSAA color attachment as memoryless tile storage
        if ([g_device supportsFamily:MTLGPUFamilyApple1]) {
            msDesc.storageMode = MTLStorageModeMemoryless;
        } else {
            msDesc.storageMode = MTLStorageModePrivate;
        }
        msDesc.textureType = MTLTextureType2DMultisample;
        msDesc.sampleCount = samples;
        g_sceneTextureMSAA = [g_device newTextureWithDescriptor:msDesc];
    }
    else
    {
        g_sceneTextureMSAA = nil;
    }
}

// Offscreen scene render target management (RGBA16Float / BGRA8Unorm, private storage)
void R_Metal_UpdateSceneTexture(NSUInteger width, NSUInteger height)
{
    if (!g_device || width == 0 || height == 0)
        return;

    static NSUInteger pendingW = 0, pendingH = 0;
    static int stableFrames = 0;

    const int samples = MQ_MSAASampleCount();
    const BOOL msaaOk = (samples > 1) == (g_sceneTextureMSAA != nil);

    if (!g_sceneTexture || !msaaOk) {
        MQ_CreateSceneTexture(width, height, samples);
        pendingW = pendingH = 0;
        stableFrames = 0;
        return;
    }

    if (g_sceneTexture.width == width && g_sceneTexture.height == height) {
        pendingW = pendingH = 0;
        stableFrames = 0;
        return;
    }

    if (pendingW == width && pendingH == height) {
        if (++stableFrames < 2)
            return; // Wait for second stable frame of identical size
    } else {
        pendingW = width;
        pendingH = height;
        stableFrames = 1;
        return;
    }

    MQ_CreateSceneTexture(width, height, samples);
    MLog(MQ_LVL_DEV, "GFX·GAMMA", "scene texture recreated %ux%u (msaa=%d)",
         (unsigned)width, (unsigned)height, samples);
}

// Ping-pong targets for the bloom filter chain.
// Resolution depends on r_mq_bloom_quality:
//   0 = half-res (1/2, default, maximum quality)
//   1 = quarter-res (1/4, performance mode)
//
// Note: These textures must not use MTLStorageModeMemoryless because each buffer
// is sampled in a subsequent, separate render pass via setFragmentTexture.
// On TBDR GPUs, memoryless attachments are valid only within a single render pass.
void MQ_Textures_EnsureBloomTextures(NSUInteger sceneW, NSUInteger sceneH)
{
    if (!g_device || sceneW == 0 || sceneH == 0)
        return;

    // Quality mapping: 0 = half-res (1/2), 1 = quarter-res (1/4), clamped to [0, 1]
    int quality = (int)r_mq_bloom_quality.value;
    if (quality < 0) quality = 0;
    if (quality > 1) quality = 1;

    NSUInteger divisor = (quality == 1) ? 4 : 2;
    NSUInteger w = sceneW / divisor;
    NSUInteger h = sceneH / divisor;

    if (w == 0 || h == 0)
        return;

    if (g_bloomTexA && g_bloomTexA.width == w && g_bloomTexA.height == h &&
        g_bloomTexB && g_bloomTexB.width == w && g_bloomTexB.height == h)
        return;

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                 width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;

    g_bloomTexA = [g_device newTextureWithDescriptor:d];
    g_bloomTexB = [g_device newTextureWithDescriptor:d];

    g_bloomTexA.label = @"MQ Bloom A";
    g_bloomTexB.label = @"MQ Bloom B";

    MLog(MQ_LVL_DEV, "GFX·BLOOM",
         "bloom textures created %lux%lu (scene %lux%lu, quality=%s)",
         (unsigned long)w, (unsigned long)h,
         (unsigned long)sceneW, (unsigned long)sceneH,
         quality == 1 ? "quarter" : "half");
}

// Full-resolution RGBA16Float destination target for MetalFX upscaler
void MQ_Textures_EnsureFxIntermediate(NSUInteger drawW, NSUInteger drawH)
{
    if (!g_device || drawW == 0 || drawH == 0)
        return;
    if (g_fxIntermediate && g_fxIntermediate.width == drawW && g_fxIntermediate.height == drawH)
        return;

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                width:drawW height:drawH mipmapped:NO];
    // MetalFX spatial and temporal scalers write to outputTexture via compute kernels;
    // MTLTextureUsageShaderWrite is required to prevent compute validation assertions during encode.
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    g_fxIntermediate = [g_device newTextureWithDescriptor:d];
}
