//
//  mq_internal.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  INTERNAL MetalEngine header (private to renderer modules).
//  Public C-ABI for QuakeCore and Shaders.metal is declared strictly in MetalBridge.h.
//
//    1. Shared Metal runtime objects (single global definition in owning module)
//    2. Render command encoder shadow state cache (mq_encoder_state.m)
//    3. Cross-module prototypes and frame execution state
//
#ifndef mq_internal_h
#define mq_internal_h

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "MetalBridge.h"

#define MAX_2D_VERTICES 16384

// PBR runtime state queries (isolates cvar_t access from Metal modules)
bool R_PBR_IsEnabled(void);
int  R_PBR_GetDebugMode(void);

// Ray tracing cvar query (r_rt)
bool R_RT_IsEnabled(void);

// ============================================================
// 1. Shared Metal Objects
//    Each variable is defined in EXACTLY one implementation module:
//      g_device/g_commandQueue/g_samplerState/g_depthState*/g_metalLayer
//        -> mq_context.m
//      g_uiPipelineState/g_worldPipelineState/g_gammaPipelineState/
//      g_uiPipelineNoDepth                              -> mq_pipelines.m
//      g_commandBuffer/g_renderEncoder/g_currentDrawable -> mq_renderer.m
//      g_sceneTexture/g_bloomTexA/B                     -> mq_frame_textures.m
// ============================================================
extern id<MTLDevice> g_device;
extern id<MTLCommandQueue> g_commandQueue;
extern id<MTLCommandBuffer> g_commandBuffer;
extern id<MTLRenderCommandEncoder> g_renderEncoder;
extern CAMetalLayer *g_metalLayer;
extern id<CAMetalDrawable> g_currentDrawable;
extern id<MTLBuffer> g_fullscreenQuadBuffer;

extern id<MTLSamplerState> g_samplerState;
extern id<MTLDepthStencilState> g_depthState2D;
extern id<MTLDepthStencilState> g_depthState3D;
extern id<MTLDepthStencilState> g_depthStateSky;

extern id<MTLRenderPipelineState> g_uiPipelineState;
extern id<MTLRenderPipelineState> g_worldPipelineState;

// Active texture validation registry (mq_textures_api.m)
extern CFMutableSetRef g_validTextures;

// Native game window reference (mq_window_macos.m)
extern NSWindow *g_gameNSWindow;

// ============================================================
// 2. Render Encoder Shadow State Caching (mq_encoder_state.m).
// Every setRenderPipelineState / setFragmentTexture call encodes commands into
// the command buffer. Across frames rendering thousands of world surfaces, most
// bindings are redundant. The wrappers below bypass encoding if the state matches.
// Cache is shared across ALL modules (3D, 2D, gamma pass). Direct encoder changes
// must be routed through these accessors.
// ============================================================
void MQEncoder_SetRenderPipelineState(id<MTLRenderPipelineState> p);
void MQEncoder_SetDepthStencilState(id<MTLDepthStencilState> d);
void MQEncoder_SetViewport(MTLViewport vp);
void MQEncoder_SetCullMode(MTLCullMode mode);
void MQEncoder_SetFragmentTexture(id<MTLTexture> t, NSUInteger index);
void MQEncoder_SetFragmentSamplerState(id<MTLSamplerState> s, NSUInteger index);
void MQEncoder_SetFragmentBytes(const void *bytes, NSUInteger length, NSUInteger index);
void MQEncoder_ResetStateCache(void); // Invoked when creating a new encoder in BeginFrame

// ============================================================
// 3. Cross-Module Prototypes and State
// ============================================================
// ---- mq_vertex_buffer.m: Dynamic vertex ring buffer
void MQ_VertexBuffer_BeginFrame(id<MTLCommandBuffer> cb);
void MQ_VertexBuffer_EndFrame(id<MTLCommandBuffer> cb);
void MQ_VertexBuffer_CancelFrame(void);
bool MQ_VertexBuffer_Upload(const void *data,
                            uint32_t sizeBytes,
                            id<MTLBuffer> *outBuffer,
                            NSUInteger *outOffset);
// ---- mq_uniform_buffer.m: Dynamic uniform ring buffer
void MQ_UniformBuffer_BeginFrame(id<MTLCommandBuffer> cb);
void MQ_UniformBuffer_EndFrame(id<MTLCommandBuffer> cb);
void MQ_UniformBuffer_CancelFrame(void);
bool MQ_UniformBuffer_Upload(const void *data,
                             uint32_t sizeBytes,
                             id<MTLBuffer> *outBuffer,
                             NSUInteger *outOffset);
// ---- mq_frame_textures.m: Frame render target resources (depth/scene/bloom/fx-intermediate)
void R_Metal_UpdateDepthTexture(NSUInteger width, NSUInteger height);
void R_Metal_UpdateSceneTexture(NSUInteger width, NSUInteger height);
void MQ_Textures_EnsureBloomTextures(NSUInteger sceneW, NSUInteger sceneH);
void MQ_Textures_EnsureFxIntermediate(NSUInteger drawW, NSUInteger drawH);
extern id<MTLTexture> g_sceneTexture;       // Resolved scene texture (consumed by post/MetalFX)
extern id<MTLTexture> g_sceneTextureMSAA;   // MSAA target (nil if fsaa is disabled)
extern id<MTLTexture> g_depthTexture;       // Resolved depth texture (consumed by motion pass)
extern id<MTLTexture> g_depthTextureMSAA;   // MSAA depth target (nil if fsaa is disabled)
extern id<MTLTexture> g_bloomTexA;          // Half-resolution ping-pong RGBA16Float target
extern id<MTLTexture> g_bloomTexB;
extern id<MTLTexture> g_fxIntermediate;     // Full-resolution RGBA16Float MetalFX upscale destination
int MQ_MSAASampleCount(void);               // Clamped sample count from vid_fsaa -> {0, 2, 4, 8}
NSUInteger MQ_PSOSampleCount(void);         // Raster sample count for pipeline state descriptors (1 if multisampling disabled)

// ---- mq_pipelines.m: Pipeline state factory
void MQ_BuildCorePipelines(MTLPixelFormat targetFmt, id<MTLLibrary> defaultLibrary);
void MQ_Pipelines_BuildGamma(id<MTLLibrary> defaultLibrary);
void MQ_Pipelines_LazyBuildCore(MTLPixelFormat targetFmt);
extern id<MTLRenderPipelineState> g_gammaPipelineState;
extern id<MTLRenderPipelineState> g_uiPipelineNoDepth;

// ---- mq_hdr_edr.m: HDR/EDR pipeline and post-processing passes
extern bool g_hdrActive;              // HDR active and applied
extern bool g_edrActive;              // Drawable configured for EDR
extern volatile bool g_hdrLayerDirty; // Layer pixel format changed — frame must be skipped
extern float g_edrHeadroom;
extern MTLPixelFormat g_sceneFormat;  // Scene render format (RGBA16Float / BGRA8Unorm)
extern id<MTLRenderPipelineState> g_postHDRPipeline;
void MQ_HDR_AutoTick(void);           // Automated EDR headroom updates, called from BeginFrame
void MQ_HDR_EncodeBloomChain(void);   // Bright-pass and separable blur passes, called from EndFrame
// Returns an active encoder allowing subsequent UI overlay encoding
id<MTLRenderCommandEncoder> MQ_HDR_EncodeFinal(id<MTLCommandBuffer> cb, id<MTLTexture> postSrc);
id<MTLRenderCommandEncoder> MQ_HDR_EncodeClassicGamma(id<MTLCommandBuffer> cb);

// ---- Diagnostic frame readback mechanism (mq_hdr_edr.m).
// Encodes blit copies of scene/fxIntermediate/drawable into shared memory on frames 20 and 100;
// caller waits for buffer completion before scanning pixels for diagnostics.
// Activated strictly when MQ_READBACK=1 is defined in the environment.
bool MQ_Debug_FrameReadbackEncode(id<MTLCommandBuffer> cb);
void MQ_Debug_FrameReadbackScan(void);

// ---- mq_metalfx.m: Spatial and Temporal upscalers
extern bool g_fxActive;               // metalfx_mode > 0 and actively applied
void MQ_Metalfx_UpdateFrame(NSUInteger texW, NSUInteger texH,
                            NSUInteger *outRenW, NSUInteger *outRenH);
float MQ_Metalfx_JitterX(void);
float MQ_Metalfx_JitterY(void);
void MQ_Metalfx_EnsureTargets(NSUInteger renW, NSUInteger renH,
                              NSUInteger drawW, NSUInteger drawH);
bool MQ_Metalfx_UpscaleAvailable(void);
void MQ_Metalfx_DbgLog(void);
id<MTLTexture> MQ_Metalfx_EncodeUpscale(id<MTLCommandBuffer> cb);

// ---- mq_window_macos.m: AppKit platform layer
void MQ_Window_FocusHealTick(void);   // Focus restoration tick, called from BeginFrame
void MQ_Input_DiagnosticsTick(void);  // Input diagnostics tick, called from BeginFrame

// Destination indicator for Flush2D (0 = scene pass, 1 = overlay pass; set by mq_renderer)
extern int g_mqFlushDestination;

// World geometry telemetry counters
extern uint32_t g_mqStatDrawCalls;
extern uint32_t g_mqStatWorldPolys;

// Frame render target dimensions (internal render resolution when MetalFX is active, otherwise drawable size)
extern NSUInteger g_mqRenderTargetW, g_mqRenderTargetH;

// Evaluates whether HUD is deferred to overlay pass (mid-frame 2D flushes disallowed)
bool MQ_Renderer_DeferUIActive(void);

// ---- mq_ui2d.m / mq_world3d.m: Cross-module declarations
void R_Metal_Flush2D(void);
void MQ_UI2D_DropBatch(void);
void R_Metal_SetUITargetScale(float sx, float sy);
void R_Metal_RebuildBlended3DPipelines(MTLPixelFormat fmt);
extern bool g_metalGunDepth; // Compressed weapon depth range state

#endif /* mq_internal_h */
