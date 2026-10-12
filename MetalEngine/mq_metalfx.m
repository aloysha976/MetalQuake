//
//  mq_metalfx.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  MetalFX integration: Spatial and Temporal upscalers.
//    - Frame scheduling: internal render size (drawable × metalfx_scale),
//    - Halton(2,3)x8 jitter sequence for Temporal upscaling,
//    - Screen-space RG16F motion vectors from depth via inverse(cur)/prev reprojection.
//

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <simd/simd.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "quakedef.h"

extern simd_float4x4 g_metalWorldMVP; // gl_rmain.c: current frame world viewProj

bool g_fxActive = false;              // metalfx_mode > 0 and actively applied

static id<MTLFXSpatialScaler> g_spatialScaler = nil;

// Temporal upscaler: MetalFX scaler instance, motion vector pipeline, and RG16F render target.
static id<MTLFXTemporalScaler> g_tScaler = nil;
static NSUInteger s_fxInputW = 0, s_fxInputH = 0; // Scaler expected input resolution
static id<MTLRenderPipelineState> g_motionPipeline = nil; // RG16Float render target PSO
static id<MTLTexture> g_motionTex  = nil;
static int   s_jitterIdx    = 0;
static float s_curJX = 0.f, s_curJY = 0.f;
static float s_prevJX = 0.f, s_prevJY = 0.f; // Previous frame subpixel jitter
static int   s_tResetFrames = 2;
static simd_float4x4 s_prevViewProj;   // Initialized on the first frame

// Linear clamp sampler for post-processing chain (used by motion vector pass).
static id<MTLSamplerState> MQ_Metalfx_LinearClampSampler(void)
{
    static id<MTLSamplerState> sampler = nil;
    if (!sampler) {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        // Depth sampling for motion vector reconstruction requires nearest filtering
        // to prevent edge bleeding and depth interpolation artifacts along geometry silhouettes.
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler = [g_device newSamplerStateWithDescriptor:sd];
    }
    return sampler;
}

float MQ_Metalfx_JitterX(void) { return s_curJX; }
float MQ_Metalfx_JitterY(void) { return s_curJY; }

// Frame planning: updates active state, computes internal render resolution, and updates jitter offsets.
// Called once per frame from BeginFrame after nextDrawable/vid synchronization.
void MQ_Metalfx_UpdateFrame(NSUInteger texW, NSUInteger texH,
                            NSUInteger *outRenW, NSUInteger *outRenH)
{
    // Evaluate active state
    {
        bool fxWanted = (metalfx_mode.value > 0.f);
        if (fxWanted != g_fxActive) {
            g_fxActive = fxWanted;
            if (!fxWanted) {
                g_spatialScaler = nil;
                g_tScaler = nil;
                g_fxIntermediate = nil;
                MLog(MQ_LVL_ALWAYS, "HDR", "metalfx disabled");
            }
        }
    }
    
    // Internal render resolution: drawableSize * metalfx_scale
    NSUInteger renW = texW, renH = texH;
    if (g_fxActive)
    {
        float sc = (float)metalfx_scale.value;
        if (sc < 0.5f) sc = 0.5f;
        if (sc > 0.9f) sc = 0.9f;
        renW = ((NSUInteger)((double)texW  * sc)) & ~1UL;
        renH = ((NSUInteger)((double)texH * sc)) & ~1UL;
        if (renW < 320) renW = 320;
        if (renH < 200) renH = 200;
    }
    *outRenW = renW;
    *outRenH = renH;
    
    bool fxTemporal = g_fxActive && (int)metalfx_mode.value >= 2;
    
    // Disable jitter during intermission screens:
    // With a static camera, subpixel jitter causes perceptible visual jitter in static UI/world elements.
    if (fxTemporal && !cl.intermission)
    {
        static const float h2[8] = {0.5f,0.25f,0.75f,0.125f,0.625f,0.375f,0.875f,0.0625f};
        static const float h3[8] = {0.33333334f,0.6666667f,0.11111111f,0.44444445f,
            0.7777778f,0.22222222f,0.5555556f,0.8888889f};
        // Per Apple MetalFX guidelines, jitter offsets must be within [-0.5, 0.5] pixel bounds.
        s_curJX = h2[s_jitterIdx & 7] - 0.5f;
        s_curJY = h3[s_jitterIdx & 7] - 0.5f;
        s_jitterIdx++;
    }
    else
    {
        s_curJX = 0.f;
        s_curJY = 0.f;
    }
}

// Reallocates Spatial scaler when input/output dimensions change.
static void R_Metalfx_EnsureFxScaler(NSUInteger renW, NSUInteger renH,
                                     NSUInteger drawW, NSUInteger drawH)
{
    static NSUInteger s_inW = 0, s_inH = 0, s_outW = 0, s_outH = 0;
    if (!g_device)
        return;
    if (g_spatialScaler && s_inW == renW && s_inH == renH &&
        s_outW == drawW && s_outH == drawH)
        return;
    
    if (![MTLFXSpatialScalerDescriptor supportsDevice:g_device]) {
        static bool logged = false;
        if (!logged) {
            MLog(MQ_LVL_ALWAYS, "HDR", "MetalFX Spatial unsupported on this device");
            logged = true;
        }
        return;
    }
    
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.inputWidth = renW;
    d.inputHeight = renH;
    d.outputWidth = drawW;
    d.outputHeight = drawH;
    d.colorTextureFormat = MTLPixelFormatRGBA16Float;   // HDR scene input
    d.outputTextureFormat = MTLPixelFormatRGBA16Float;  // Intermediate buffer prior to tonemapping
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    
    g_spatialScaler = [d newSpatialScalerWithDevice:g_device];
    s_inW = renW;  s_inH = renH;
    s_outW = drawW; s_outH = drawH;
    s_fxInputW = renW; s_fxInputH = renH;
    MLog(MQ_LVL_ALWAYS, "HDR",
         "metalfx spatial scaler %lux%lu -> %lux%lu",
         (unsigned long)renW, (unsigned long)renH,
         (unsigned long)drawW, (unsigned long)drawH);
}

// Strips subpixel camera jitter from the MVP matrix.
// This allows reconstructing world-space coordinates from the depth buffer
// without double jitter compensation, which would otherwise induce shaking on static geometry.
static simd_float4x4 MQ_UnjitterMVP(simd_float4x4 m, float jxPx, float jyPx, float renW, float renH)
{
    float jx = jxPx * 2.0f / renW;
    float jy = jyPx * 2.0f / renH;
    simd_float4x4 res = m;
    for (int c = 0; c < 4; c++) {
        res.columns[c].x -= jx * m.columns[c].w;
        res.columns[c].y -= jy * m.columns[c].w;
    }
    return res;
}

// Temporal upscaler: allocates scaler instance, motion vector pipeline, and RG16F texture.
static void R_Metalfx_EnsureTemporal(NSUInteger renW, NSUInteger renH,
                                     NSUInteger drawW, NSUInteger drawH)
{
    if (!g_device)
        return;
    
    if (!g_motionPipeline)
    {
        id<MTLLibrary> lib = [g_device newDefaultLibrary];
        id<MTLFunction> v = lib ? [lib newFunctionWithName:@"gamma_vertex_main"] : nil;
        id<MTLFunction> f = lib ? [lib newFunctionWithName:@"motion_fragment_main"] : nil;
        if (v && f) {
            MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
            d.label = @"Quake Motion Vectors Pass";
            d.vertexFunction = v;
            d.fragmentFunction = f;
            d.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
            d.colorAttachments[0].blendingEnabled = NO;
            // No depth attachment: the motion vector pass reads depth as a regular shader texture;
            // specifying depthAttachmentPixelFormat on a pass without depth attachment triggers a validation assert.
            NSError *err = nil;
            g_motionPipeline = [g_device newRenderPipelineStateWithDescriptor:d error:&err];
        }
    }
    
    if (!g_motionTex || g_motionTex.width != renW || g_motionTex.height != renH)
    {
        MTLTextureDescriptor *md = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                      width:renW height:renH mipmapped:NO];
        md.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        md.storageMode = MTLStorageModePrivate;
        g_motionTex = [g_device newTextureWithDescriptor:md];
    }
    
    static NSUInteger s_inW=0,s_inH=0,s_outW=0,s_outH=0;
    if (g_tScaler && s_inW==renW && s_inH==renH && s_outW==drawW && s_outH==drawH)
        return;
    
    if (![MTLFXTemporalScalerDescriptor supportsDevice:g_device])
    {
        static bool logged=false;
        if (!logged) { MLog(MQ_LVL_ALWAYS,"HDR","MetalFX Temporal unsupported"); logged=true; }
        return;
    }
    
    MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
    d.inputWidth = renW;   d.inputHeight = renH;
    d.outputWidth = drawW; d.outputHeight = drawH;
    d.colorTextureFormat  = MTLPixelFormatRGBA16Float;
    d.depthTextureFormat  = MTLPixelFormatDepth32Float_Stencil8;
    d.motionTextureFormat = MTLPixelFormatRG16Float;
    d.outputTextureFormat = MTLPixelFormatRGBA16Float;
    d.autoExposureEnabled = NO;
    d.requiresSynchronousInitialization = YES;
    
    g_tScaler = [d newTemporalScalerWithDevice:g_device];
    s_inW=renW; s_inH=renH; s_outW=drawW; s_outH=drawH;
    s_fxInputW=renW; s_fxInputH=renH;
    s_tResetFrames = 2; // Trigger reset on the first frames following creation
    MLog(MQ_LVL_ALWAYS, "HDR",
         "metalfx temporal scaler %lux%lu -> %lux%lu",
         (unsigned long)renW,(unsigned long)renH,(unsigned long)drawW,(unsigned long)drawH);
}

// Ensures upscale render targets and scalers match current dimensions.
// Invoked from BeginFrame when (g_fxActive && g_hdrActive && postActive).
void MQ_Metalfx_EnsureTargets(NSUInteger renW, NSUInteger renH,
                              NSUInteger drawW, NSUInteger drawH)
{
    MQ_Textures_EnsureFxIntermediate(drawW, drawH);
    if ((int)metalfx_mode.value >= 2)
        R_Metalfx_EnsureTemporal(renW, renH, drawW, drawH);
    else
        R_Metalfx_EnsureFxScaler(renW, renH, drawW, drawH);
}

// Checks pipeline readiness for deferUI: active mode scaler exists and intermediate buffer is valid.
bool MQ_Metalfx_UpscaleAvailable(void)
{
    bool haveUpscaler = ((int)metalfx_mode.value >= 2)
    ? (g_tScaler != nil && g_motionPipeline != nil)
    : (g_spatialScaler != nil);
    return haveUpscaler && g_fxIntermediate != nil;
}

// Diagnostic helper logging internal MetalFX state for deferUI troubleshooting.
void MQ_Metalfx_DbgLog(void)
{
    MLog(MQ_LVL_ALWAYS, "HUD·DBG",
         "metalfx internals: mode=%.0f tScaler=%p motionPSO=%p motionTex=%p spatial=%p intermediate=%p",
         metalfx_mode.value, (__bridge void *)g_tScaler, (__bridge void *)g_motionPipeline,
         (__bridge void *)g_motionTex, (__bridge void *)g_spatialScaler,
         (__bridge void *)g_fxIntermediate);
}

// Executes scene upscaling during EndFrame: runs motion vector pass + Temporal OR Spatial encode.
// Returns the intermediate destination texture (g_fxIntermediate), or nil if upscaling was bypassed
// (e.g. during dimension recreation latency frames; tonemapper reads the scene directly).
id<MTLTexture> MQ_Metalfx_EncodeUpscale(id<MTLCommandBuffer> cb)
{
    bool temporal = ((int)metalfx_mode.value >= 2);
    
    // Dimension synchronization gate: scene/depth reallocation undergoes debounce handling
    // and may lag behind the scaler by 1-2 frames during window resize events.
    // Encoding with mismatched dimensions triggers MetalFX validation assertions.
    bool fxSizesReady =
    g_sceneTexture && g_motionTex && g_depthTexture &&
    g_sceneTexture.width  == g_motionTex.width  &&
    g_sceneTexture.height == g_motionTex.height &&
    g_depthTexture.width  == g_sceneTexture.width &&
    g_depthTexture.height == g_sceneTexture.height;
    
    if (temporal && fxSizesReady)
    {
        R_Metalfx_EnsureTemporal(g_sceneTexture.width, g_sceneTexture.height,
                                 g_currentDrawable.texture.width,
                                 g_currentDrawable.texture.height);
    }
    
    if (temporal && fxSizesReady && g_tScaler && g_motionPipeline &&
        g_motionTex && g_depthTexture && g_fxIntermediate &&
        g_currentDrawable.texture.pixelFormat != MTLPixelFormatInvalid &&
        g_sceneTexture.width == g_tScaler.inputWidth &&
        g_sceneTexture.height == g_tScaler.inputHeight &&
        g_fxIntermediate.width == g_tScaler.outputWidth &&
        g_fxIntermediate.height == g_tScaler.outputHeight)
    {
        // 1) Reconstruct motion vectors from current-frame depth buffer
        MTLRenderPassDescriptor *mvPass = [MTLRenderPassDescriptor renderPassDescriptor];
        mvPass.colorAttachments[0].texture = g_motionTex;
        mvPass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        mvPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        
        id<MTLRenderCommandEncoder> mve = [cb renderCommandEncoderWithDescriptor:mvPass];
        mve.label = @"Motion Vectors";
        
        // Input scene dimensions
        float renderW = (float)g_sceneTexture.width;
        float renderH = (float)g_sceneTexture.height;
        
        // Guard first frame after reset to avoid uninitialized s_prevViewProj
        if (s_tResetFrames > 0) {
            s_prevViewProj = g_metalWorldMVP;
            s_prevJX = s_curJX;
            s_prevJY = s_curJY;
        }
        
        // Assemble matrices: current jittered matrix alongside unjittered variants
        simd_float4x4 curNoJitter = MQ_UnjitterMVP(g_metalWorldMVP, s_curJX, s_curJY, renderW, renderH);
        simd_float4x4 prevNoJitter = MQ_UnjitterMVP(s_prevViewProj, s_prevJX, s_prevJY, renderW, renderH);
        
        // Populate pass uniforms; inversion executed via hardware simd_inverse from <simd/simd.h>
        struct {
            simd_float4x4 invCurJittered;
            simd_float4x4 prevNoJitter;
            simd_float4x4 curNoJitter;
            simd_float2   texSize;
            simd_float2   _pad;
        } mu = {
            simd_inverse(g_metalWorldMVP),  // Precise SIMD matrix inverse
            prevNoJitter,                   // Previous frame view-projection without jitter
            curNoJitter,                    // Current frame view-projection without jitter
            { renderW, renderH },
            { 0.0f, 0.0f }
        };
        
        [mve setViewport:(MTLViewport){ 0,0,(double)g_motionTex.width,(double)g_motionTex.height,0,1 }];
        [mve setRenderPipelineState:g_motionPipeline];
        [mve setVertexBuffer:g_fullscreenQuadBuffer offset:0 atIndex:0];
        [mve setFragmentBytes:&mu length:sizeof(mu) atIndex:1];
        [mve setFragmentTexture:g_depthTexture atIndex:0];
        [mve setFragmentSamplerState:MQ_Metalfx_LinearClampSampler() atIndex:0];
        [mve drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [mve endEncoding];
        
        // 2) Temporal upscale encode pass
        g_tScaler.colorTexture  = g_sceneTexture;
        g_tScaler.depthTexture  = g_depthTexture;
        g_tScaler.motionTexture = g_motionTex;
        g_tScaler.outputTexture = g_fxIntermediate;
        g_tScaler.inputContentWidth  = g_sceneTexture.width;
        g_tScaler.inputContentHeight = g_sceneTexture.height;
        g_tScaler.jitterOffsetX = s_curJX;
        g_tScaler.jitterOffsetY = -s_curJY;
        // Motion vectors are generated directly in input resolution pixel units
        g_tScaler.motionVectorScaleX = 1.0f;
        g_tScaler.motionVectorScaleY = 1.0f;
        
        // Reverse-Z configuration:
        // Must notify scaler if projection and depth states use Reverse-Z,
        // otherwise disocclusion heuristics invert near/far planes.
        if (@available(macOS 14.0, *)) {
            g_tScaler.depthReversed = YES;
        }
        g_tScaler.reset = (s_tResetFrames > 0);
        if (s_tResetFrames > 0) s_tResetFrames--;
        
        [g_tScaler encodeToCommandBuffer:cb];
        
        s_prevViewProj = g_metalWorldMVP;
        s_prevJX = s_curJX;
        s_prevJY = s_curJY;
        return g_fxIntermediate;
    }
    else if (!temporal && g_spatialScaler && g_fxIntermediate && g_sceneTexture)
    {
        // Dimension synchronization gate for Spatial upscaler:
        // Skip upscaling during transient resize frames where intermediate or scene lags behind the scaler descriptor.
        if (g_sceneTexture.width   != g_spatialScaler.inputWidth  ||
            g_sceneTexture.height  != g_spatialScaler.inputHeight ||
            g_fxIntermediate.width  != g_spatialScaler.outputWidth ||
            g_fxIntermediate.height != g_spatialScaler.outputHeight)
        {
            return nil;
        }
        
        g_spatialScaler.colorTexture  = g_sceneTexture;
        g_spatialScaler.outputTexture = g_fxIntermediate;
        [g_spatialScaler encodeToCommandBuffer:cb];
        s_prevViewProj = g_metalWorldMVP;
        s_prevJX = s_curJX;
        s_prevJY = s_curJY;
        return g_fxIntermediate;
    }
    
    return nil;
}
