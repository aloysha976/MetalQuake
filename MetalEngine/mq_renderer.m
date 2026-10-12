//
//  mq_renderer.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Frame orchestration: BeginFrame / EndFrame.
//  Coordinates the execution sequence of rendering stages; specific implementations
//  reside in dedicated modules:
//    mq_context         — Device and CAMetalLayer setup
//    mq_window_macos    — AppKit window focus management and input diagnostics
//    mq_frame_textures  — Per-frame render target resources
//    mq_pipelines       — Pipeline state objects (PSOs)
//    mq_hdr_edr         — HDR, bloom, and tonemapping pipeline
//    mq_metalfx         — Upscaling integration
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "quakedef.h"

// Global frame objects
id<MTLCommandBuffer> g_commandBuffer = nil;
id<MTLRenderCommandEncoder> g_renderEncoder = nil;
id<CAMetalDrawable> g_currentDrawable = nil;

// Destination for the upcoming Flush2D call: 0 = scene encoder, 1 = overlay encoder
int g_mqFlushDestination = 0;

// Effective render target dimensions (internal render resolution when MetalFX is active, otherwise drawable size).
// 3D viewports must match this resolution to avoid incorrect zooming and edge clipping.
NSUInteger g_mqRenderTargetW = 0, g_mqRenderTargetH = 0;

// Indicates whether deferred UI overlay rendering is active.
// When active, 2D UI batch flushes to the scene encoder are deferred until the overlay pass
// to prevent rendering HUD elements at the reduced 3D scene resolution.
bool MQ_Renderer_DeferUIActive(void)
{
    return g_hdrActive && g_fxActive && MQ_Metalfx_UpscaleAvailable() &&
    (g_uiPipelineNoDepth != nil);
}

// Frame recursion depth counter: 0 = idle, 1 = primary frame, >1 = nested SCR_UpdateScreen (e.g. Con_Printf).
// Nested EndFrame invocations must act as a no-op to prevent premature presentation or PSO attachment asserts.
static int s_metalInFrame = 0;

// Gamma pass is enabled only when vid_gamma or vid_contrast deviate from neutral (1.0).
// Evaluated in BeginFrame and consumed in EndFrame.
static bool s_gammaActive = false;

void R_Metal_BeginFrame(void)
{
    if (s_metalInFrame > 0)
    {
        s_metalInFrame++; // Track nesting depth so matching EndFrame calls execute as no-ops
        static unsigned s_nestedSkips = 0;
        if (++s_nestedSkips <= 3 || (s_nestedSkips % 600) == 0)
            MLog(MQ_LVL_DEV, "GFX·FRAME", "nested BeginFrame skipped (#%u)", s_nestedSkips);
        return;
    }
    
    if (!g_device) R_Metal_Init();
    
    // Increment frame counter for logging prefix
    MLog_NextFrame();
    
    // Drain asynchronous audio stream logs (safe on main thread)
    AV_DrainLogs();
    
    // Pipeline telemetry: average render FPS and simulation rate measured over 5-second intervals
    {
        static double s_perfT0 = 0;
        static unsigned s_perfFrames = 0;
        static double s_perfSimTime = 0;
        double now = [NSDate timeIntervalSinceReferenceDate];
        s_perfFrames++;
        s_perfSimTime += g_frameSimTime;
        if (s_perfT0 <= 0) s_perfT0 = now;
        double perfDt = now - s_perfT0;
        if (perfDt >= 5.0)
        {
            int maxFps = 0;
            NSScreen *scr = g_gameNSWindow.screen ?: [NSScreen mainScreen];
            if (scr)
                maxFps = (int)scr.maximumFramesPerSecond;
            CGSize dsz = g_metalLayer ? g_metalLayer.drawableSize : CGSizeZero;
            uint32_t avgDraws = (s_perfFrames > 0) ? (g_mqStatDrawCalls / s_perfFrames) : 0;
            uint32_t avgPolys = (s_perfFrames > 0) ? (g_mqStatWorldPolys / s_perfFrames) : 0;
            MLog(MQ_LVL_ALWAYS, "PERF",
                 "render %.1f fps (drawable %.0fx%.0f) | draws/frame: %u | polys: %u | sim %.1f ticks/s",
                 s_perfFrames / perfDt, dsz.width, dsz.height,
                 avgDraws, avgPolys,
                 (s_perfSimTime / perfDt) / SIM_DT());
            g_mqStatDrawCalls = 0;
            g_mqStatWorldPolys = 0;
            s_perfT0 = now;
            s_perfFrames = 0;
            s_perfSimTime = 0;
        }
    }
    
    // Verbose frame marker logged only under FULL profile
    MLog(MQ_LVL_FULL, "GFX·FRAME", "===== BEGIN FRAME =====");
    
    if (!g_metalLayer) {
        static bool loggedLayer = false;
        if (!loggedLayer) {
            MLog(MQ_LVL_ALWAYS, "GFX·FRAME", "ERROR: g_metalLayer is NULL");
            loggedLayer = true;
        }
        return;
    }
    
    // 1. Synchronize drawable dimensions with layer geometry.
    // contentsScale is owned by vid_macos.m; recompute drawableSize from current backing scale.
    if (g_metalLayer.bounds.size.width > 0 && g_metalLayer.bounds.size.height > 0) {
        CGFloat scale = g_metalLayer.contentsScale > 0 ? g_metalLayer.contentsScale : 1.0;
        CGSize targetSize = CGSizeMake(g_metalLayer.bounds.size.width * scale,
                                       g_metalLayer.bounds.size.height * scale);
        if (!CGSizeEqualToSize(g_metalLayer.drawableSize, targetSize) && targetSize.width > 0) {
            g_metalLayer.drawableSize = targetSize;
        }
    }
    
    if (!g_metalLayer.device && g_device) {
        g_metalLayer.device = g_device;
        g_metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    }
    
    // 2. Acquire current drawable (handling transient window transitions safely)
    g_currentDrawable = [g_metalLayer nextDrawable];
    if (!g_currentDrawable) {
        static bool loggedDrawable = false;
        if (!loggedDrawable) {
            MLog(MQ_LVL_ALWAYS, "GFX·FRAME", "WARNING: nextDrawable is nil (window transitioning)");
            loggedDrawable = true;
        }
        return;
    }
    
    NSUInteger texWidth = g_currentDrawable.texture.width;
    NSUInteger texHeight = g_currentDrawable.texture.height;
    
    if (texWidth == 0 || texHeight == 0) {
        MLog(MQ_LVL_DEV, "GFX·FRAME", "drawable texture has zero size — frame skipped");
        g_currentDrawable = nil;
        return;
    }
    
    // Scene render resolution configured from launcher preferences
    extern int g_reqRenderWidth;
    extern int g_reqRenderHeight;
    extern cvar_t metalfx_mode;
    
    NSUInteger renW = texWidth;
    NSUInteger renH = texHeight;
    
    if (g_reqRenderWidth > 0 && g_reqRenderHeight > 0) {
        renW = (NSUInteger)g_reqRenderWidth;
        renH = (NSUInteger)g_reqRenderHeight;
    }
    
    // Update render resolution via MetalFX when enabled
    if ((int)metalfx_mode.value > 0) {
        MQ_Metalfx_UpdateFrame(texWidth, texHeight, &renW, &renH);
    }
    g_mqRenderTargetW = renW; // Stored for 3D viewport configuration
    g_mqRenderTargetH = renH;
    
    // 3. UI canvas resolution layout:
    // Native canvas resolution when deferring UI via MetalFX overlay, otherwise render resolution.
    bool willDeferUI = g_hdrActive && g_fxActive && MQ_Metalfx_UpscaleAvailable() && (g_uiPipelineNoDepth != nil);
    NSUInteger uiTargetW = willDeferUI ? texWidth : renW;
    NSUInteger uiTargetH = willDeferUI ? texHeight : renH;
    
    if (vid.width != (int)uiTargetW || vid.height != (int)uiTargetH) {
        MLog(MQ_LVL_ALWAYS, "GFX·FRAME", "UI Canvas: %dx%d | 3D Render Target: %ux%u (Screen: %ux%u)",
             (int)uiTargetW, (int)uiTargetH, (unsigned)renW, (unsigned)renH, (unsigned)texWidth, (unsigned)texHeight);
        
        vid.width = (int)uiTargetW;
        vid.height = (int)uiTargetH;
        SCR_UpdateConwidth(vid.width, vid.height);
        vid.recalc_refdef = 1;
    }
    
    // 4. Match depth buffer resolution strictly to render target dimensions
    R_Metal_UpdateDepthTexture(renW, renH);
    
    // Gamma pass is active only when gamma/contrast correction is applied; otherwise render directly to drawable
    s_gammaActive = (g_gammaPipelineState != nil) &&
    (vid_gamma.value != 1.0f || vid_contrast.value != 1.0f);
    
    // Evaluate dynamic HDR mode transitions and display EDR headroom changes
    MQ_HDR_AutoTick();
    
    // Skip frame if layer format changed after acquiring drawable to avoid pixel format mismatch
    if (g_hdrLayerDirty)
    {
        g_hdrLayerDirty = false;
        MLog(MQ_LVL_DEV, "HDR", "drawable format flip — frame skipped");
        g_currentDrawable = nil;
        return;
    }
    
    // Offscreen scene texture is required under HDR (tonemapping), MSAA, or when scaling to display resolution
    const int msaaSamples = MQ_MSAASampleCount();
    bool needsUpscale = (renW != texWidth || renH != texHeight);
    bool postActive = s_gammaActive || g_hdrActive || (msaaSamples > 1) || needsUpscale;
    
    if (postActive)
        R_Metal_UpdateSceneTexture(renW, renH);
    
    // Ensure MetalFX scalers and intermediate buffers match current dimensions
    if (g_fxActive && g_hdrActive && postActive)
        MQ_Metalfx_EnsureTargets(renW, renH, texWidth, texHeight);
    
    // Scale viewport for immediate 2D passes (e.g. PolyBlend) rendering into a low-resolution scene target
    {
        float sx = 1.0f, sy = 1.0f;
        if (postActive && texWidth > 0 && renW != texWidth)
        {
            sx = (float)renW / (float)texWidth;
            sy = (float)renH / (float)texHeight;
        }
        R_Metal_SetUITargetScale(sx, sy);
    }
    
    // Active frame boundary: subsequent nested BeginFrame/EndFrame calls are treated as no-ops
    s_metalInFrame = 1;
    
    g_commandBuffer = [g_commandQueue commandBuffer];
    
    // Advance frame slots for dynamic vertex and uniform ring buffers
    MQ_VertexBuffer_BeginFrame(g_commandBuffer);
    MQ_UniformBuffer_BeginFrame(g_commandBuffer);
    
    // Lazily build core pipeline states matching current scene format
    MQ_Pipelines_LazyBuildCore(g_sceneFormat);
    
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    const BOOL sceneMSAA = (g_sceneTextureMSAA != nil);
    passDesc.colorAttachments[0].texture = postActive ? (sceneMSAA ? g_sceneTextureMSAA : g_sceneTexture)
    : g_currentDrawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    if (sceneMSAA) {
        passDesc.colorAttachments[0].resolveTexture = g_sceneTexture;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    } else {
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    
    if (g_depthTexture) {
        const BOOL depthMSAA = (g_depthTextureMSAA != nil);
        passDesc.depthAttachment.texture = depthMSAA ? g_depthTextureMSAA : g_depthTexture;
        passDesc.depthAttachment.loadAction = MTLLoadActionClear;
        // Clear Reverse-Z depth to 0.0 (maximum distance)
        passDesc.depthAttachment.clearDepth = 0.0;
        
        // Depth32Float_Stencil8 serves as depth-only storage; stencil attachment is omitted as stencil operations are unused.
        
        if (depthMSAA) {
            passDesc.depthAttachment.resolveTexture = g_depthTexture;
            passDesc.depthAttachment.storeAction = MTLStoreActionMultisampleResolve;
            // In Reverse-Z, near geometry approaches 1.0; max depth resolve filter preserves closer surfaces and mitigates silhouette jitter.
            passDesc.depthAttachment.depthResolveFilter = MTLMultisampleDepthResolveFilterMax;
        } else {
            // Temporal upscaler reads depth during the motion vector pass; preserve depth contents when temporal scaling is active.
            extern cvar_t metalfx_mode;
            bool needsDepthStore = (g_fxActive && (int)metalfx_mode.value >= 2);
            passDesc.depthAttachment.storeAction = needsDepthStore ? MTLStoreActionStore : MTLStoreActionDontCare;
        }
    }
    
    g_renderEncoder = [g_commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    
    // Reset encoder state cache for new render pass
    MQEncoder_ResetStateCache();
    
    // 5. Set viewport to render target dimensions. Subpixel jitter is applied strictly within the projection matrix.
    MTLViewport vp = { 0.0, 0.0, (double)renW, (double)renH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp);
    
    if (g_depthState3D) {
        MQEncoder_SetDepthStencilState(g_depthState3D);
    }
    
    // Trigger window focus healing tick
    MQ_Window_FocusHealTick();
    
    // Sample input diagnostics tick
    MQ_Input_DiagnosticsTick();
}

void R_Metal_EndFrame(void)
{
    // Handle nested EndFrame invocations: only the outermost frame completes the presentation pipeline
    if (s_metalInFrame == 0)
    {
        R_Metal_Flush2D();
        return;
    }
    if (s_metalInFrame > 1)
    {
        s_metalInFrame--;
        MQ_UI2D_DropBatch();
        return;
    }
    s_metalInFrame = 0;
    
    // Clean up pipeline state if frame was skipped (e.g. during fullscreen transitions)
    if (!g_renderEncoder || !g_currentDrawable || !g_commandBuffer) {
        R_Metal_Flush2D();
        MQ_VertexBuffer_CancelFrame();
        MQ_UniformBuffer_CancelFrame();
        g_renderEncoder = nil;
        g_currentDrawable = nil;
        g_commandBuffer = nil;
        return;
    }
    
    // Under MetalFX, defer 2D UI elements to render at native display resolution in the overlay pass
    bool deferUI = g_hdrActive && g_fxActive && MQ_Metalfx_UpscaleAvailable() &&
    (g_uiPipelineNoDepth != nil);
    
    // Log HUD overlay deferral diagnostics
    {
        static unsigned s_hudDbgFrame = 0;
        unsigned f = MLog_GetFrame();
        if (f == 1 || f == 60 || f == 300 || (f > 300 && f % 300 == 0)) {
            if (s_hudDbgFrame != f) {
                s_hudDbgFrame = f;
                BOOL fmtOkNow = g_currentDrawable.texture.pixelFormat ==
                (g_edrActive ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm);
                MLog(MQ_LVL_ALWAYS, "HUD·DBG",
                     "defer=%d hdr=%d fx=%d avail=%d uiND=%d fmtOk=%d drawable=%ux%u",
                     deferUI ? 1 : 0,
                     g_hdrActive ? 1 : 0, g_fxActive ? 1 : 0,
                     MQ_Metalfx_UpscaleAvailable() ? 1 : 0,
                     g_uiPipelineNoDepth != nil ? 1 : 0,
                     fmtOkNow ? 1 : 0,
                     (unsigned)g_currentDrawable.texture.width,
                     (unsigned)g_currentDrawable.texture.height);
                MQ_Metalfx_DbgLog();
            }
        }
    }
    
    if (!deferUI)
        R_Metal_Flush2D();
    
    [g_renderEncoder endEncoding];
    g_renderEncoder = nil;
    
    // Reset UI target scale following scene pass completion
    R_Metal_SetUITargetScale(1.0f, 1.0f);
    
    // Guard against transient frame format mismatches on drawable
    MTLPixelFormat wantDrawableFmt = g_edrActive ? MTLPixelFormatRGBA16Float
    : MTLPixelFormatBGRA8Unorm;
    bool drawableFmtOk = (g_currentDrawable.texture.pixelFormat == wantDrawableFmt);
    
    // Final post-processing pass: classic gamma/contrast scaling or HDR bloom/MetalFX/tonemapping
    id<MTLRenderCommandEncoder> postEncoder = nil;
    
    if (g_hdrActive && g_postHDRPipeline && g_sceneTexture && drawableFmtOk)
    {
        // Execute bloom chain: bright pass -> horizontal blur -> vertical blur
        MQ_HDR_EncodeBloomChain();
        // MetalFX spatial/temporal upscale: scene target -> intermediate buffer
        id<MTLTexture> upscaled = MQ_Metalfx_EncodeUpscale(g_commandBuffer);
        // Tonemap / EDR pass targeting drawable surface
        postEncoder = MQ_HDR_EncodeFinal(g_commandBuffer, upscaled ?: g_sceneTexture);
    }
    else if ((s_gammaActive || g_sceneTextureMSAA || (g_sceneTexture && g_sceneTexture.width != g_currentDrawable.texture.width)) && g_sceneTexture && g_gammaPipelineState && drawableFmtOk)
    {
        // Classic gamma/contrast pass scaling scene directly to display target
        postEncoder = MQ_HDR_EncodeClassicGamma(g_commandBuffer);
    }
    
    // UI overlay pass: reuse post-processing encoder to keep TBDR tile memory resident
    if (deferUI && drawableFmtOk && postEncoder)
    {
        g_renderEncoder = postEncoder;
        g_mqFlushDestination = 1;
        
        if (g_depthState2D)
            MQEncoder_SetDepthStencilState(g_depthState2D);
        R_Metal_SetUIPipelineOverride((__bridge void *)(g_uiPipelineNoDepth));
        R_Metal_Flush2D();
        g_mqFlushDestination = 0;
        R_Metal_SetUIPipelineOverride(nil);
        
        [postEncoder endEncoding];
        postEncoder = nil;
    }
    else if (postEncoder)
    {
        // Finalize encoder if deferred UI is inactive or target format is mismatched
        [postEncoder endEncoding];
        postEncoder = nil;
    }
    
    // Optional debug frame readback
    bool rbActive = MQ_Debug_FrameReadbackEncode(g_commandBuffer);
    
    // Release dynamic ring buffer slots upon command buffer completion
    MQ_VertexBuffer_EndFrame(g_commandBuffer);
    MQ_UniformBuffer_EndFrame(g_commandBuffer);
    
    [g_commandBuffer presentDrawable:g_currentDrawable];
    [g_commandBuffer commit];
    
    if (rbActive) {
        [g_commandBuffer waitUntilCompleted];
        MQ_Debug_FrameReadbackScan();
    }
    
    // Log timestamp of first presented frame
    static bool s_firstPresent = false;
    if (!s_firstPresent) {
        s_firstPresent = true;
        MLog(MQ_LVL_ALWAYS, "BOOT", "first frame PRESENTED (drawable %ux%u)",
             (unsigned)g_currentDrawable.texture.width,
             (unsigned)g_currentDrawable.texture.height);
    }
    
    g_currentDrawable = nil;
    g_commandBuffer = nil;
}
