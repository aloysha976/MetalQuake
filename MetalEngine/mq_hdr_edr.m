//
//  mq_hdr_edr.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  HDR/EDR state machine and final post-processing passes:
//    - r_hdr activation/deactivation and EDR display headroom tracking,
//    - Bloom chain (bright-pass + separable blur, half-res ping-pong targets),
//    - Tonemapping from RGBA16Float to drawable (SDR filmic / EDR highlight expansion),
//    - Legacy gamma pass (r_hdr = 0).
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "quakedef.h"

// ======================================================================
// HDR pipeline (r_hdr): RGBA16Float scene buffer with tonemapping.
// r_hdr == 0 preserves exact legacy rendering (BGRA8Unorm, classic gamma pass).
// EDR: When display reports headroom > 1.0 (controlled via r_edr_force),
// the drawable switches to RGBA16Float + extendedLinearSRGB, allowing specular
// highlights to exceed standard SDR white.
// ======================================================================
id<MTLRenderPipelineState> g_postHDRPipeline = nil;
bool g_hdrActive   = false;   // r_hdr active and applied
bool g_edrActive   = false;   // Drawable configured for EDR
float g_edrHeadroom = 1.0f;
MTLPixelFormat g_sceneFormat = MTLPixelFormatBGRA8Unorm;

// Flag indicating CAMetalLayer pixel format changed; the current drawable
// is stale and the frame must be skipped to avoid PSO format validation asserts.
volatile bool g_hdrLayerDirty = false;

// Bloom pipelines (HDR mode only) targeting half-resolution RGBA16Float buffers
static id<MTLRenderPipelineState> g_brightPipeline = nil;
static id<MTLRenderPipelineState> g_blurPipeline   = nil;

// Post-processing linear clamp sampler, shared between bloom and tonemapping passes
static id<MTLSamplerState> MQ_HDR_PostSampler(void)
{
    static id<MTLSamplerState> postSampler = nil;
    if (!postSampler) {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        postSampler = [g_device newSamplerStateWithDescriptor:sd];
    }
    return postSampler;
}

// Nearest-neighbor sampler for crisp retro pixel scaling
static id<MTLSamplerState> MQ_HDR_NearestSampler(void)
{
    static id<MTLSamplerState> nearestSampler = nil;
    if (!nearestSampler) {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        nearestSampler = [g_device newSamplerStateWithDescriptor:sd];
    }
    return nearestSampler;
}

// Selects active scaling sampler based on vid_scale_filter cvar (0 = Linear, 1 = Nearest)
static id<MTLSamplerState> MQ_HDR_ActiveScaleSampler(void)
{
    cvar_t *sf = Cvar_FindVar("vid_scale_filter");
    if (sf && sf->value > 0.0f) {
        return MQ_HDR_NearestSampler();
    }
    return MQ_HDR_PostSampler();
}

static void R_Metal_ApplyDisplayEDR(bool edrOn)
{
    if (!g_metalLayer)
        return;
    
    static CGColorSpaceRef s_savedColorSpace = nil;
    if (!s_savedColorSpace && edrOn)
        s_savedColorSpace = g_metalLayer.colorspace; // Preserve to restore upon disabling EDR
    
    MTLPixelFormat prevFmt = g_metalLayer.pixelFormat;
    if (edrOn) {
        g_metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
        g_metalLayer.wantsExtendedDynamicRangeContent = YES;
        g_metalLayer.colorspace =
        CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    } else {
        g_metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_metalLayer.wantsExtendedDynamicRangeContent = NO;
        g_metalLayer.colorspace = s_savedColorSpace ?: CGColorSpaceCreateDeviceRGB();
    }
    
    // Invalidate frame if layer format changed after drawable was requested
    if (g_metalLayer.pixelFormat != prevFmt)
        g_hdrLayerDirty = true;
}

// ======================================================================
// Applies or removes HDR mode: rebuilds pipelines for target format and
// updates drawable settings. Invoked exclusively from MQ_HDR_AutoTick.
// ======================================================================
static void MQ_HDR_ApplyMode(bool hdrWanted)
{
    if (!g_device)
        return;
    
    // --- Display EDR Evaluation ---
    float headroom = 1.0f;
    bool  edrOn = false;
    if (hdrWanted) {
        NSScreen *scr = (g_gameNSWindow && g_gameNSWindow.screen)
        ? g_gameNSWindow.screen : [NSScreen mainScreen];
        double hr = scr ? scr.maximumPotentialExtendedDynamicRangeColorComponentValue : 1.0;
        int force = (int)r_edr_force.value;
        if (force == 1)      edrOn = true;                 // Explicitly forced
        else if (force == 0) edrOn = false;                // Disabled
        else                 edrOn = (hr > 1.05);          // Automatic detection
        
        if (edrOn)
            headroom = (float)(hr > 1.05 ? hr : 1.5);      // Safe fallback when forced
    }
    
    g_hdrActive   = hdrWanted;
    g_edrActive   = hdrWanted ? edrOn : false;
    g_edrHeadroom = hdrWanted ? headroom : 1.0f;
    g_sceneFormat = hdrWanted ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    
    // Rebuild core pipelines for the target scene format and invalidate scene texture
    id<MTLLibrary> lib = [g_device newDefaultLibrary];
    if (lib)
        MQ_BuildCorePipelines(g_sceneFormat, lib);
    R_Metal_RebuildBlended3DPipelines(g_sceneFormat);
    g_sceneTexture = nil; // Will be recreated in UpdateSceneTexture with updated format
    
    // Update layer and drawable settings
    R_Metal_ApplyDisplayEDR(hdrWanted && edrOn);
    
    // Compile post-processing pipeline matching drawable format
    if (hdrWanted) {
        id<MTLFunction> v = lib ? [lib newFunctionWithName:@"gamma_vertex_main"] : nil;
        id<MTLFunction> f = lib ? [lib newFunctionWithName:@"postprocess_fragment_main"] : nil;
        if (v && f) {
            MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
            d.label = @"Quake HDR Post-Process Pipeline";
            d.vertexFunction = v;
            d.fragmentFunction = f;
            d.colorAttachments[0].pixelFormat =
            g_edrActive ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
            d.colorAttachments[0].blendingEnabled = NO;
            NSError *err = nil;
            g_postHDRPipeline = [g_device newRenderPipelineStateWithDescriptor:d error:&err];
            if (!g_postHDRPipeline)
                printf("[Metal Error] HDR post pipeline failed: %s\n",
                       err ? [[err localizedDescription] UTF8String] : "?");
        }
        
        // Compile bloom pipelines (target: RGBA16Float)
        if (!g_brightPipeline || !g_blurPipeline) {
            id<MTLFunction> bv = lib ? [lib newFunctionWithName:@"gamma_vertex_main"] : nil;
            id<MTLFunction> bf = lib ? [lib newFunctionWithName:@"brightpass_fragment_main"] : nil;
            id<MTLFunction> lf = lib ? [lib newFunctionWithName:@"blur9_fragment_main"] : nil;
            if (bv && bf && lf) {
                MTLRenderPipelineDescriptor *bd = [[MTLRenderPipelineDescriptor alloc] init];
                bd.label = @"Quake Bloom Bright-Pass";
                bd.vertexFunction = bv;
                bd.fragmentFunction = bf;
                bd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
                bd.colorAttachments[0].blendingEnabled = NO;
                g_brightPipeline = [g_device newRenderPipelineStateWithDescriptor:bd error:nil];
                
                MTLRenderPipelineDescriptor *ld = [[MTLRenderPipelineDescriptor alloc] init];
                ld.label = @"Quake Bloom Blur 9-tap";
                ld.vertexFunction = bv;
                ld.fragmentFunction = lf;
                ld.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
                ld.colorAttachments[0].blendingEnabled = NO;
                g_blurPipeline = [g_device newRenderPipelineStateWithDescriptor:ld error:nil];
                
                g_bloomTexA = nil; // Will be recreated matching scene dimensions
                g_bloomTexB = nil;
            }
        }
    } else {
        g_postHDRPipeline = nil;
    }
    
    MLog(MQ_LVL_ALWAYS, "HDR",
         "mode=%s | edr=%d headroom=%.2f boost=%.2f | scene=%s drawable=%s",
         hdrWanted ? "HDR" : "CLASSIC",
         g_edrActive ? 1 : 0, g_edrHeadroom, (float)r_edr_boost.value,
         g_sceneFormat == MTLPixelFormatRGBA16Float ? "RGBA16Float" : "BGRA8Unorm",
         g_edrActive ? "RGBA16Float(EDR)" : "BGRA8Unorm");
}

// Automatically tracks display headroom changes and mode transitions.
// Cvar changes (r_hdr / metalfx) apply immediately. Screen headroom variations
// require 10 consecutive stable frames and a 1-second cooldown to avoid rapid PSO reallocations.
void MQ_HDR_AutoTick(void)
{
    bool hdrWanted = (r_hdr.value > 0.f) || g_fxActive;
    NSScreen *curScr = (g_gameNSWindow && g_gameNSWindow.screen)
    ? g_gameNSWindow.screen : [NSScreen mainScreen];
    double hr = curScr ? curScr.maximumPotentialExtendedDynamicRangeColorComponentValue : 1.0;
    
    static double s_lastHR = -1.0;
    static double s_pendingHR = -1.0;
    static int    s_pendingFrames = 0;
    static CFAbsoluteTime s_lastApply = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    
    if (hdrWanted != g_hdrActive)
    {
        // User action: apply immediately
        MQ_HDR_ApplyMode(hdrWanted);
        s_lastApply = now;
        s_lastHR = hr;
        s_pendingHR = -1.0;
        s_pendingFrames = 0;
        return;
    }
    
    if (!hdrWanted)
    {
        s_lastHR = hr;
        return;
    }
    
    if (s_lastHR >= 0 && fabs(hr - s_lastHR) > 0.01)
    {
        if (s_pendingHR >= 0 && fabs(hr - s_pendingHR) <= 0.01)
            s_pendingFrames++;
        else
        {
            s_pendingHR = hr;
            s_pendingFrames = 1;
        }
        
        if (s_pendingFrames >= 10 && now - s_lastApply >= 1.0)
        {
            MLog(MQ_LVL_ALWAYS, "HDR",
                 "EDR headroom %.2f -> %.2f (stable %d frames) — reapply",
                 s_lastHR, hr, s_pendingFrames);
            MQ_HDR_ApplyMode(hdrWanted);
            s_lastApply = now;
            s_lastHR = hr;
            s_pendingHR = -1.0;
            s_pendingFrames = 0;
        }
    }
    else
    {
        s_lastHR = hr;
        s_pendingHR = -1.0;
        s_pendingFrames = 0;
    }
}

// Bloom execution chain: bright pass -> horizontal blur -> vertical blur.
// Encoded prior to upscaling and final tonemapping.
void MQ_HDR_EncodeBloomChain(void)
{
    id<MTLCommandBuffer> cb = g_commandBuffer;
    if (!cb || !g_sceneTexture)
        return;
    
    // Safety check: bypass bloom if disabled or intensity is zero to save GPU cycles
    bool bloomOn = (r_bloom.value > 0.f) &&
    (r_bloom_intensity.value > 0.f) &&
    g_brightPipeline && g_blurPipeline;
    if (bloomOn)
    {
        MQ_Textures_EnsureBloomTextures(g_sceneTexture.width, g_sceneTexture.height);
    }
    else
    {
        g_bloomTexA = nil; // Release memory when cvar is disabled
        g_bloomTexB = nil;
    }
    
    if (!bloomOn || !g_bloomTexA || !g_bloomTexB)
        return;
    
    float bw = (float)g_bloomTexA.width;
    float bh = (float)g_bloomTexA.height;
    MTLViewport vpHalf = { 0.0, 0.0, (double)bw, (double)bh, 0.0, 1.0 };
    id<MTLSamplerState> sampler = MQ_HDR_PostSampler();
    
    // Bright pass: scene -> A
    MTLRenderPassDescriptor *bp = [MTLRenderPassDescriptor renderPassDescriptor];
    bp.colorAttachments[0].texture = g_bloomTexA;
    bp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    bp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> be = [cb renderCommandEncoderWithDescriptor:bp];
    be.label = @"Bloom Bright-Pass";
    [be setViewport:vpHalf];
    [be setRenderPipelineState:g_brightPipeline];
    [be setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
    struct { float threshold, knee, pad0, pad1; } bu =
    { (float)r_bloom_threshold.value, 0.35f, 0, 0 };
    [be setFragmentBytes:&bu length:sizeof(bu) atIndex:1];
    [be setFragmentTexture:g_sceneTexture atIndex:0];
    [be setFragmentSamplerState:sampler atIndex:0];
    [be drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [be endEncoding];
    
    // Horizontal blur: A -> B
    MTLRenderPassDescriptor *bh_ = [MTLRenderPassDescriptor renderPassDescriptor];
    bh_.colorAttachments[0].texture = g_bloomTexB;
    bh_.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    bh_.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> he = [cb renderCommandEncoderWithDescriptor:bh_];
    he.label = @"Bloom Blur H";
    [he setViewport:vpHalf];
    [he setRenderPipelineState:g_blurPipeline];
    [he setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
    struct { float texelX, texelY, dirX, dirY; } hu =
    { 1.0f/bw, 1.0f/bh, 1.0f, 0.0f };
    [he setFragmentBytes:&hu length:sizeof(hu) atIndex:1];
    [he setFragmentTexture:g_bloomTexA atIndex:0];
    [he setFragmentSamplerState:sampler atIndex:0];
    [he drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [he endEncoding];
    
    // Vertical blur: B -> A
    MTLRenderPassDescriptor *bv2 = [MTLRenderPassDescriptor renderPassDescriptor];
    bv2.colorAttachments[0].texture = g_bloomTexA;
    bv2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    bv2.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> ve = [cb renderCommandEncoderWithDescriptor:bv2];
    ve.label = @"Bloom Blur V";
    [ve setViewport:vpHalf];
    [ve setRenderPipelineState:g_blurPipeline];
    [ve setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
    struct { float texelX, texelY, dirX, dirY; } vu =
    { 1.0f/bw, 1.0f/bh, 0.0f, 1.0f };
    [ve setFragmentBytes:&vu length:sizeof(vu) atIndex:1];
    [ve setFragmentTexture:g_bloomTexB atIndex:0];
    [ve setFragmentSamplerState:sampler atIndex:0];
    [ve drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [ve endEncoding];
}

// Computes viewport dimensions for final presentation: stretched (0) or
// aspect-ratio-corrected (1) with pillarbox/letterbox borders.
static MTLViewport MQ_HDR_CalculateViewport(double srcW, double srcH, double dstW, double dstH, bool *outPillarboxed)
{
    if (outPillarboxed) *outPillarboxed = false;
    if (srcW <= 0.0 || srcH <= 0.0 || dstW <= 0.0 || dstH <= 0.0) {
        return (MTLViewport){ 0.0, 0.0, dstW, dstH, 0.0, 1.0 };
    }

    cvar_t *cv = Cvar_FindVar("vid_preserve_aspect");
    if (!cv || cv->value == 0.0f) {
        // Stretch across full viewport without black bars
        return (MTLViewport){ 0.0, 0.0, dstW, dstH, 0.0, 1.0 };
    }

    double srcAspect = srcW / srcH;
    double dstAspect = dstW / dstH;

    // Direct stretch if aspect ratios match within 0.5% tolerance
    if (fabs(srcAspect - dstAspect) < 0.005) {
        return (MTLViewport){ 0.0, 0.0, dstW, dstH, 0.0, 1.0 };
    }

    double vpW = dstW;
    double vpH = dstH;
    double vpX = 0.0;
    double vpY = 0.0;

    if (srcAspect < dstAspect) {
        // Source is narrower than target (e.g. 4:3 on 16:9) -> Pillarbox
        vpW = floor(dstH * srcAspect);
        vpX = floor((dstW - vpW) * 0.5);
    } else {
        // Source is wider than target (e.g. 21:9 on 16:9) -> Letterbox
        vpH = floor(dstW / srcAspect);
        vpY = floor((dstH - vpH) * 0.5);
    }

    if (outPillarboxed) *outPillarboxed = true;
    return (MTLViewport){ vpX, vpY, vpW, vpH, 0.0, 1.0 };
}

// Final HDR pass: bloom accumulation + tonemapping (SDR filmic / EDR) -> drawable.
id<MTLRenderCommandEncoder> MQ_HDR_EncodeFinal(id<MTLCommandBuffer> cb, id<MTLTexture> postSrc)
{
    bool bloomOn = (r_bloom.value > 0.f) && g_brightPipeline && g_blurPipeline &&
    g_bloomTexA != nil;
    
    bool isPillarboxed = false;
    MTLViewport vp = MQ_HDR_CalculateViewport((double)postSrc.width,
                                             (double)postSrc.height,
                                             (double)g_currentDrawable.texture.width,
                                             (double)g_currentDrawable.texture.height,
                                             &isPillarboxed);

    MTLRenderPassDescriptor *postPass = [MTLRenderPassDescriptor renderPassDescriptor];
    postPass.colorAttachments[0].texture = g_currentDrawable.texture;
    // Clear canvas when pillarboxing is active, otherwise bypass clear to save bandwidth
    postPass.colorAttachments[0].loadAction = isPillarboxed ? MTLLoadActionClear : MTLLoadActionDontCare;
    postPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    postPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLRenderCommandEncoder> postEncoder = [cb renderCommandEncoderWithDescriptor:postPass];
    postEncoder.label = @"HDR Post-Process";
    
    float safeGamma = vid_gamma.value;
    if (safeGamma < 0.01f) safeGamma = 0.01f;
    
    // Layout must match GammaUniforms structure in Shaders.metal
    struct {
        float gammaValue;
        float contrastValue;
        float headroom;
        float edrBoost;
        float bloomIntensity;
        float hasBloom;
        float exposure;
        float _pad1;
    } gu = { safeGamma, (float)vid_contrast.value,
        g_edrHeadroom, (float)r_edr_boost.value,
        (float)r_bloom_intensity.value,
        (bloomOn && g_bloomTexA) ? 1.0f : 0.0f,
        (float)r_hdr_exposure.value, 0.0f };
    
    [postEncoder setViewport:vp];
    [postEncoder setRenderPipelineState:g_postHDRPipeline];
    [postEncoder setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
    [postEncoder setFragmentBytes:&gu length:sizeof(gu) atIndex:1];
    [postEncoder setFragmentTexture:postSrc atIndex:0];
    // Slot 1 remains bound: references bloom result or falls back to scene texture
    [postEncoder setFragmentTexture:(bloomOn ? g_bloomTexA : postSrc) atIndex:1];
    [postEncoder setFragmentSamplerState:MQ_HDR_ActiveScaleSampler() atIndex:0];
    
    [postEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    // Return active encoder to allow subsequent UI overlay drawing within the same pass
    return postEncoder;
}

// Classic post-processing path (r_hdr = 0): applies gamma/contrast from offscreen BGRA8.
id<MTLRenderCommandEncoder> MQ_HDR_EncodeClassicGamma(id<MTLCommandBuffer> cb)
{
    bool isPillarboxed = false;
    MTLViewport vp = MQ_HDR_CalculateViewport((double)g_sceneTexture.width,
                                             (double)g_sceneTexture.height,
                                             (double)g_currentDrawable.texture.width,
                                             (double)g_currentDrawable.texture.height,
                                             &isPillarboxed);

    MTLRenderPassDescriptor *gammaPass = [MTLRenderPassDescriptor renderPassDescriptor];
    gammaPass.colorAttachments[0].texture = g_currentDrawable.texture;
    gammaPass.colorAttachments[0].loadAction = isPillarboxed ? MTLLoadActionClear : MTLLoadActionDontCare;
    gammaPass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    gammaPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLRenderCommandEncoder> gammaEncoder = [cb renderCommandEncoderWithDescriptor:gammaPass];
    gammaEncoder.label = @"Gamma Post-Process";
    
    float safeGamma = vid_gamma.value;
    if (safeGamma < 0.01f) safeGamma = 0.01f;
    
    // Layout must match GammaUniforms structure in Shaders.metal.
    // Preserves QuakeSpasm/vkQuake behavior: direct pow(c, vid_gamma) without inversion
    struct {
        float gammaValue;
        float contrastValue;
        float _pad0;
        float _pad1;
        float _pad2;
        float _pad3;
        float _pad4;
        float _pad5;
    } gu = { safeGamma, (float)vid_contrast.value,
        0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
    
    [gammaEncoder setViewport:vp];
    [gammaEncoder setRenderPipelineState:g_gammaPipelineState];
    [gammaEncoder setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
    [gammaEncoder setFragmentBytes:&gu length:sizeof(gu) atIndex:1];
    [gammaEncoder setFragmentTexture:g_sceneTexture atIndex:0];
    
    [gammaEncoder setFragmentSamplerState:MQ_HDR_ActiveScaleSampler() atIndex:0];
    
    [gammaEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    // Return active encoder to allow piggybacking the UI overlay pass
    return gammaEncoder;
}

// ======================================================================
// Debug readback pipeline: captures scene / fxIntermediate / drawable textures.
// Validates rendering integrity across each post-processing stage.
// Enabled via MQ_READBACK=1 environment variable on frames 3, 20, and 100.
// Requires CAMetalLayer.framebufferOnly = NO.
// ======================================================================
#define MQ_RB_MAX 4
typedef struct {
    id<MTLTexture> view;        // Shared texture view over buffer
    id<MTLBuffer>  buf;
    char           tag[16];
    MTLPixelFormat fmt;
    NSUInteger     w, h, rowBytes;
} mq_rb_entry_t;

static mq_rb_entry_t s_rbEntries[MQ_RB_MAX];
static int           s_rbCount = 0;
static bool          s_rbEnabled = false;
static bool          s_rbEnvChecked = false;

static bool MQ_ReadbackEnabled(void)
{
    if (!s_rbEnvChecked) {
        s_rbEnvChecked = true;
        s_rbEnabled = (getenv("MQ_READBACK") != NULL);
    }
    return s_rbEnabled;
}

static bool MQ_ReadbackEncodeOne(id<MTLCommandBuffer> cb, id<MTLTexture> tex, const char *tag)
{
    if (!tex || !cb || s_rbCount >= MQ_RB_MAX)
        return false;
    
    NSUInteger bpp;
    switch (tex.pixelFormat) {
        case MTLPixelFormatRGBA16Float:  bpp = 8; break;
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB: bpp = 4; break;
        default:
            MLog(MQ_LVL_ALWAYS, "MQ·RB", "%s: Pixel format %lu unsupported for readback",
                 tag, (unsigned long)tex.pixelFormat);
            return false;
    }
    
    mq_rb_entry_t *e = &s_rbEntries[s_rbCount];
    e->w = tex.width; e->h = tex.height; e->fmt = tex.pixelFormat;
    e->rowBytes = ((tex.width * bpp + 255) / 256) * 256;
    
    // Allocate or reallocate buffer and texture view upon format or size change
    if (!e->buf || e->view.width != e->w || e->view.height != e->h ||
        e->view.pixelFormat != e->fmt)
    {
        e->buf = [g_device newBufferWithLength:e->rowBytes * e->h
                                       options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *d = [MTLTextureDescriptor
                                   texture2DDescriptorWithPixelFormat:e->fmt width:e->w height:e->h mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        d.usage = MTLTextureUsageShaderWrite;
        e->view = [e->buf newTextureWithDescriptor:d offset:0 bytesPerRow:e->rowBytes];
    }
    strlcpy(e->tag, tag, sizeof(e->tag));
    
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex
              sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(e->w, e->h, 1)
                toTexture:e->view destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    
    s_rbCount++;
    return true;
}

bool MQ_Debug_FrameReadbackEncode(id<MTLCommandBuffer> cb)
{
    s_rbCount = 0;
    if (!MQ_ReadbackEnabled() || !cb)
        return false;
    
    unsigned f = (unsigned)MLog_GetFrame();
    if (f != 3 && f != 20 && f != 100)
        return false;
    
    MLog(MQ_LVL_ALWAYS, "MQ·RB",
         "frame=%u hdr=%d edr=%d sceneFmt=%lu postHDR=%d gammaPSO=%d sceneMSAA=%d "
         "bloomA=%d fxInt=%d drawable=%ux%u@%lu",
         f, g_hdrActive ? 1 : 0, g_edrActive ? 1 : 0,
         (unsigned long)g_sceneFormat,
         g_postHDRPipeline != nil ? 1 : 0,
         g_gammaPipelineState != nil ? 1 : 0,
         g_sceneTextureMSAA != nil ? 1 : 0,
         g_bloomTexA != nil ? 1 : 0,
         g_fxIntermediate != nil ? 1 : 0,
         (unsigned)g_currentDrawable.texture.width,
         (unsigned)g_currentDrawable.texture.height,
         (unsigned long)g_currentDrawable.texture.pixelFormat);
    
    if (g_sceneTexture)     MQ_ReadbackEncodeOne(cb, g_sceneTexture, "SCENE");
    if (g_fxIntermediate)   MQ_ReadbackEncodeOne(cb, g_fxIntermediate, "FX-INT");
    if (g_currentDrawable)  MQ_ReadbackEncodeOne(cb, g_currentDrawable.texture, "DRAWABLE");
    return s_rbCount > 0;
}

void MQ_Debug_FrameReadbackScan(void)
{
    for (int i = 0; i < s_rbCount; i++)
    {
        mq_rb_entry_t *e = &s_rbEntries[i];
        const uint8_t *base = (const uint8_t *)e->buf.contents;
        if (!base) continue;
        
        float minL = 1e30f, maxL = -1e30f, sum = 0.0f;
        uint64_t n = 0, nonBlack = 0;
        
        for (NSUInteger y = 0; y < e->h; y += 4)
        {
            const uint8_t *row = base + y * e->rowBytes;
            for (NSUInteger x = 0; x < e->w; x += 4)
            {
                float r, g, b;
                if (e->fmt == MTLPixelFormatRGBA16Float) {
                    const _Float16 *px = (const _Float16 *)(row + x * 8);
                    r = (float)px[0]; g = (float)px[1]; b = (float)px[2];
                } else {
                    const uint8_t *px = row + x * 4; // BGRA
                    r = px[2] / 255.0f; g = px[1] / 255.0f; b = px[0] / 255.0f;
                }
                float lum = r > g ? (r > b ? r : b) : (g > b ? g : b);
                if (lum != lum) { // Handle NaN as anomaly
                    nonBlack++; n++; continue;
                }
                if (lum < minL) minL = lum;
                if (lum > maxL) maxL = lum;
                sum += lum; n++;
                if (lum > 1.0f / 255.0f) nonBlack++;
            }
        }
        
        MLog(MQ_LVL_ALWAYS, "MQ·RB",
             "%s %ux%u fmt=%lu: min=%.4f avg=%.4f max=%.4f nonblack=%.1f%%",
             e->tag, (unsigned)e->w, (unsigned)e->h, (unsigned long)e->fmt,
             n ? minL : 0.f, n ? sum / n : 0.f, n ? maxL : 0.f,
             n ? 100.0 * (double)nonBlack / (double)n : 0.0);
        
        // Save visual PNG dump of the drawable buffer for automated verification
        if (e->fmt == MTLPixelFormatBGRA8Unorm && e->buf.contents)
        {
            // Write to app container temporary directory
            NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:
                              @"mq_drawable_%s_f%u.png", e->tag, (unsigned)MLog_GetFrame()];
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            
            CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
            
            CGContextRef ctx = CGBitmapContextCreate((void *)e->buf.contents,
                                                     e->w, e->h, 8, e->rowBytes, cs,
                                                     bitmapInfo);
            if (ctx) {
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                if (img) {
                    CFURLRef url = CFURLCreateWithFileSystemPath(
                                                                 kCFAllocatorDefault, (__bridge CFStringRef)path,
                                                                 kCFURLPOSIXPathStyle, false);
                    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
                                                                                url, (__bridge CFStringRef)@"public.png", 1, NULL);
                    if (dst) {
                        CGImageDestinationAddImage(dst, img, NULL);
                        CGImageDestinationFinalize(dst);
                        CFRelease(dst);
                        
                        MLog(MQ_LVL_ALWAYS, "MQ·RB", "PNG saved: %s", path.UTF8String);
                    }
                    if (url) CFRelease(url);
                    CGImageRelease(img);
                }
                CGContextRelease(ctx);
            }
            CGColorSpaceRelease(cs);
        }
    }
}
