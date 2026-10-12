//
//  mq_ui2d.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

//
// mq_ui2d.m -- 2D/UI layer of the MetalQuake Metal renderer.
//

#import "quakedef.h"
#import "MetalBridge.h"
#import "mq_internal.h"
#import "mq_log.h"

#import <Metal/Metal.h>
#import <simd/simd.h>

#ifndef MAX_2D_VERTICES
#define MAX_2D_VERTICES 65536
#endif

extern id<MTLRenderCommandEncoder> g_renderEncoder;
extern id<MTLSamplerState>         g_samplerState;
extern id<MTLDepthStencilState>    g_depthState2D;
extern CFMutableSetRef             g_validTextures;
extern CAMetalLayer               *g_metalLayer;

// Pipeline override for post-FX overlay passes (using a no-depth PSO)
static id<MTLRenderPipelineState> s_uiPipelineOverride = nil;
void R_Metal_SetUIPipelineOverride(void *p)
{
    s_uiPipelineOverride = (__bridge id<MTLRenderPipelineState>)p;
}

// ======================================================================
// Segmented Batch
// ======================================================================

static MetalVertex g_uiVertices[MAX_2D_VERTICES];
static uint32_t    g_uiVertexCount = 0;   // Accumulated vertex count
static uint32_t    g_segStart      = 0;   // Starting index of the current segment
static void       *g_current2DTexture = NULL;

typedef struct {
    uint32_t        start;
    uint32_t        count;
    simd_float4x4   ortho;
    MTLViewport     vp;
    void           *tex;
    bool            texValid;
} ui_segment_t;

#define MAX_UI_SEGMENTS 256
static ui_segment_t g_segments[MAX_UI_SEGMENTS];
static int          g_segmentCount = 0;

// Pending canvas state -- applied to newly added vertices
static float       g_orthoLeft = 0.0f, g_orthoRight = 800.0f;
static float       g_orthoBottom = 600.0f, g_orthoTop = 0.0f;
static MTLViewport g_currentViewport = {0, 0, 800, 600, 0.0, 1.0};

// Scale and offset factors for CPU-side transformation of canvas coordinates to screen space
static float       g_canvasScaleX  = 1.0f;
static float       g_canvasScaleY  = 1.0f;
static float       g_canvasOffsetX = 0.0f;
static float       g_canvasOffsetY = 0.0f;

// Shared orthographic projection matrix and screen viewport for all 2D segments
static simd_float4x4 g_globalOrtho;
static MTLViewport   g_globalViewport = {0, 0, 800, 600, 0.0, 1.0};

// Static 1x1 white texture for solid color fills (Draw_Fill / Fade)
static id<MTLTexture> s_uiWhiteTexture = nil;

// Forward declaration for UI_RegisterTexture
static void UI_CloseSegment(void);

static id<MTLTexture> UI_GetWhiteTexture(void)
{
    if (s_uiWhiteTexture)
        return s_uiWhiteTexture;
    if (!g_device)
        return nil;
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:1
                                                                                   height:1
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    s_uiWhiteTexture = [g_device newTextureWithDescriptor:desc];
    s_uiWhiteTexture.label = @"2D UI White 1x1";
    
    uint32_t whitePixel = 0xFFFFFFFF;
    [s_uiWhiteTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                        mipmapLevel:0
                          withBytes:&whitePixel
                        bytesPerRow:4];
    return s_uiWhiteTexture;
}

// Per-frame 2D UI texture registry (supporting up to 16 textures per batch)
#define MAX_UI_TEXTURES 16
static id<MTLTexture> s_registeredTextures[MAX_UI_TEXTURES];
static uint32_t       s_registeredTextureCount = 0;

static void UI_ResetTextureRegistry(void)
{
    s_registeredTextures[0] = UI_GetWhiteTexture();
    for (uint32_t i = 1; i < MAX_UI_TEXTURES; i++) {
        s_registeredTextures[i] = nil;
    }
    s_registeredTextureCount = 1; // Slot 0 is reserved for the white fallback texture
}

static uint32_t UI_RegisterTexture(id<MTLTexture> tex)
{
    if (!tex)
        return 0; // Fallback to white texture
    
    if (s_registeredTextureCount == 0)
        UI_ResetTextureRegistry();
    
    // Check if the texture is already registered in the current batch
    for (uint32_t i = 0; i < s_registeredTextureCount; i++) {
        if (s_registeredTextures[i] == tex)
            return i;
    }
    
    // If texture slots are exhausted, flush the current segment and reset registry
    if (s_registeredTextureCount >= MAX_UI_TEXTURES) {
        UI_CloseSegment();
        UI_ResetTextureRegistry();
    }
    
    uint32_t slot = s_registeredTextureCount++;
    s_registeredTextures[slot] = tex;
    return slot;
}

// Target scale for immediate rendering paths (e.g. PolyBlend) when rendering to a scaled scene buffer.
// Render scale is configured during the scene encoder pass; defaults to 1.0.
static float s_tgtScaleX = 1.0f, s_tgtScaleY = 1.0f;
void R_Metal_SetUITargetScale(float sx, float sy)
{
    s_tgtScaleX = sx > 0 ? sx : 1.0f;
    s_tgtScaleY = sy > 0 ? sy : 1.0f;
}

extern id<MTLRenderPipelineState> g_uiPipelineState;

static id<MTLRenderPipelineState> UI_ActivePipeline(void)
{
    return s_uiPipelineOverride ? s_uiPipelineOverride : g_uiPipelineState;
}

static simd_float4x4 make_ortho_matrix(float left, float right, float bottom, float top)
{
    float rl = right - left, tb = top - bottom;
    if (rl == 0) rl = 800;
    if (tb == 0) tb = 600;
    // Canvas coordinates follow a y-down convention (bottom > top, e.g. console SetCanvas(0,352,200,0): tb=-200).
    // Target mapping: y=0 -> NDC +1 (top), y=H -> NDC -1 (bottom); Y-scale = +2/tb (negative when tb < 0).
    return (simd_float4x4){
        (simd_float4){ 2.0f / rl, 0, 0, 0 },
        (simd_float4){ 0, 2.0f / tb, 0, 0 },
        (simd_float4){ 0, 0, 1.0f, 0 },
        (simd_float4){ -(right + left) / rl, -(top + bottom) / tb, 0, 1 }
    };
}

// Finalizes the active segment if uncommitted vertices are pending
static void UI_CloseSegment(void)
{
    if (g_segStart >= g_uiVertexCount)
        return;
    
    if (g_segmentCount >= MAX_UI_SEGMENTS)
    {
        static bool warned = false;
        if (!warned) {
            MLog(MQ_LVL_ALWAYS, "GFX·2D", "segment overflow -- merging into last");
            warned = true;
        }
        ui_segment_t *last = &g_segments[g_segmentCount - 1];
        last->count = g_uiVertexCount - last->start;
        g_segStart = g_uiVertexCount;
        return;
    }
    
    ui_segment_t *s = &g_segments[g_segmentCount++];
    s->start    = g_segStart;
    s->count    = g_uiVertexCount - g_segStart;
    s->ortho    = g_globalOrtho;
    s->vp       = g_globalViewport;
    s->tex      = g_current2DTexture;
    // Bypasses CFSetContainsValue during 2D batching; texture validity is guaranteed
    // by engine lifecycle and optionally validated in debug builds.
    s->texValid = (g_current2DTexture != NULL);
#ifndef MQ_NO_TEXTURE_VALIDATION
    if (g_current2DTexture && g_validTextures &&
        !CFSetContainsValue(g_validTextures, g_current2DTexture)) {
        s->texValid = false;
    }
#endif
    g_segStart  = g_uiVertexCount;
}

void R_Metal_SetCanvas(float left, float right, float bottom, float top,
                       float vpX, float vpY, float vpW, float vpH)
{
    // Canvas updates do not close the active segment; coordinates are transformed on the CPU
    g_orthoLeft = left;
    g_orthoRight = right;
    g_orthoBottom = bottom;
    g_orthoTop = top;
    
    g_currentViewport.originX = vpX;
    g_currentViewport.originY = vpY;
    g_currentViewport.width   = vpW;
    g_currentViewport.height  = vpH;
    
    // Precompute transformation coefficients to global screen pixels
    float rl = (right - left);
    float tb = (bottom - top);
    g_canvasScaleX  = (rl != 0.0f) ? (vpW / rl) : 1.0f;
    g_canvasScaleY  = (tb != 0.0f) ? (vpH / tb) : 1.0f;
    g_canvasOffsetX = vpX - left * g_canvasScaleX;
    g_canvasOffsetY = vpY - top * g_canvasScaleY;
    
    if (MLog_Budget("GFX·2D", 25))
        MLog(MQ_LVL_DEV, "GFX·2D", "SetCanvas L%.0f R%.0f B%.0f T%.0f -> vp(%.0f,%.0f %.0fx%.0f)",
             left, right, bottom, top, vpX, vpY, vpW, vpH);
}

void R_Metal_Flush2D(void)
{
    // Ensure the final active segment is closed
    UI_CloseSegment();
    
    id<MTLRenderPipelineState> pipe = nil;
    if (g_segmentCount == 0 || g_uiVertexCount == 0)
        goto done;
    if (!g_renderEncoder)
        goto done; // Outside of an active render pass: batch is discarded
    pipe = UI_ActivePipeline();
    if (!pipe)
        goto done;
    
    // Telemetry: track destination (0 = scene, 1 = overlay) and first segment viewport
    {
        static unsigned s_lastLog = 0;
        unsigned f = MLog_GetFrame();
        if (f == 1 || f == 60 || f == 300 || (f > 300 && f % 300 == 0)) {
            if (s_lastLog != f) {
                s_lastLog = f;
                MLog(MQ_LVL_ALWAYS, "HUD·DBG",
                     "flush dst=%d segs=%d vp0=(%.0f,%.0f %.0fx%.0f) verts=%u",
                     g_mqFlushDestination, g_segmentCount,
                     g_segments[0].vp.originX, g_segments[0].vp.originY,
                     g_segments[0].vp.width, g_segments[0].vp.height,
                     (unsigned)g_uiVertexCount);
            }
        }
    }
    
    // Set common 2D render states once for the entire pass
    MQEncoder_SetViewport(g_globalViewport);
    if (g_depthState2D)
        MQEncoder_SetDepthStencilState(g_depthState2D);
    MQEncoder_SetRenderPipelineState(pipe);
    MQEncoder_SetCullMode(MTLCullModeNone);
    if (g_samplerState)
        MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
    
    // Bind all 16 registered UI textures in a single call
    {
        id<MTLTexture> texturesToBind[MAX_UI_TEXTURES];
        id<MTLTexture> white = UI_GetWhiteTexture();
        for (uint32_t t = 0; t < MAX_UI_TEXTURES; t++) {
            texturesToBind[t] = (t < s_registeredTextureCount && s_registeredTextures[t]) ? s_registeredTextures[t] : white;
        }
        [g_renderEncoder setFragmentTextures:texturesToBind withRange:NSMakeRange(TextureIndexBase, MAX_UI_TEXTURES)];
    }
    
    for (int i = 0; i < g_segmentCount; i++)
    {
        ui_segment_t *s = &g_segments[i];
        
        FrameUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        uniforms.projectionMatrix = g_globalOrtho;
        uniforms.modelViewMatrix  = matrix_identity_float4x4;
        uniforms.useTexture       = 1;
        uniforms.useFullbright    = 0;
        
        // Upload uniforms via dynamic ring buffer
        {
            id<MTLBuffer> ub = nil;
            NSUInteger ubOffset = 0;
            uint32_t ubSize = (uint32_t)sizeof(uniforms);
            
            if (MQ_UniformBuffer_Upload(&uniforms, ubSize, &ub, &ubOffset)) {
                [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:BufferIndexUniforms];
                [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:BufferIndexUniforms];
            } else {
                [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:BufferIndexUniforms];
                MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), BufferIndexUniforms);
            }
        }
        
        if (g_samplerState)
            MQEncoder_SetFragmentSamplerState(g_samplerState, 0);
        
        if (MLog_Budget("GFX·2D-FLUSH", 15))
            MLog(MQ_LVL_DEV, "GFX·2D", "Flush seg%d: %u verts tex=%s",
                 i, s->count, s->texValid ? "ok" : "none");
        
        // Upload vertex data via dynamic ring buffer; fall back to chunked setVertexBytes on overflow
        {
            id<MTLBuffer> vb = nil;
            NSUInteger vbOffset = 0;
            uint32_t byteSize = s->count * (uint32_t)sizeof(MetalVertex);
            
            if (MQ_VertexBuffer_Upload(&g_uiVertices[s->start], byteSize, &vb, &vbOffset)) {
                [g_renderEncoder setVertexBuffer:vb
                                          offset:vbOffset
                                         atIndex:BufferIndexVertices];
                [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                    vertexStart:0
                                    vertexCount:s->count];
            } else {
                static bool warned = false;
                if (!warned) {
                    warned = true;
                    MLog(MQ_LVL_ALWAYS, "GFX·VB",
                         "vertex ring overflow in Flush2D — falling back to setVertexBytes");
                }
                
                const uint32_t kMaxVertsPerChunk = 72;
                uint32_t offset = 0;
                while (offset < s->count)
                {
                    uint32_t count = s->count - offset;
                    if (count > kMaxVertsPerChunk)
                        count = kMaxVertsPerChunk;
                    
                    [g_renderEncoder setVertexBytes:&g_uiVertices[s->start + offset]
                                             length:(NSUInteger)(count * sizeof(MetalVertex))
                                            atIndex:BufferIndexVertices];
                    [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                        vertexStart:0
                                        vertexCount:count];
                    offset += count;
                }
            }
        }
    }
    
done:
    UI_ResetTextureRegistry();
    g_segmentCount = 0;
    g_uiVertexCount = 0;
    g_segStart = 0;
}

// Discards the pending 2D batch without encoding commands.
// Used for nested frame renders (e.g. Con_Printf triggering SCR_UpdateScreen).
void MQ_UI2D_DropBatch(void)
{
    g_segmentCount = 0;
    g_uiVertexCount = 0;
    g_segStart = 0;
}

void R_Metal_Draw2DQuad(float x, float y, float w, float h,
                        float s1, float t1, float s2, float t2,
                        simd_float4 color, void *metalTexture)
{
    id<MTLTexture> texObj = metalTexture ? (__bridge id<MTLTexture>)metalTexture : UI_GetWhiteTexture();
    float texSlot = (float)UI_RegisterTexture(texObj);
    
    // Flush active batch if vertex capacity would be exceeded, then restore canvas state
    if (g_uiVertexCount + 6 > MAX_2D_VERTICES) {
        if (g_renderEncoder) {
            void *savedTex = g_current2DTexture;
            float savedL = g_orthoLeft, savedR = g_orthoRight;
            float savedB = g_orthoBottom, savedT = g_orthoTop;
            MTLViewport savedVp = g_currentViewport;
            
            R_Metal_Flush2D();
            
            // Restore canvas for remaining quads in the current frame
            g_orthoLeft = savedL;
            g_orthoRight = savedR;
            g_orthoBottom = savedB;
            g_orthoTop = savedT;
            g_currentViewport = savedVp;
            g_current2DTexture = savedTex;
            g_segStart = 0;
        } else {
            return;
        }
    }
    
    // Transform quad corners from canvas coordinates to screen pixel coordinates
    float sx1 = x * g_canvasScaleX + g_canvasOffsetX;
    float sy1 = y * g_canvasScaleY + g_canvasOffsetY;
    float sx2 = (x + w) * g_canvasScaleX + g_canvasOffsetX;
    float sy2 = (y + h) * g_canvasScaleY + g_canvasOffsetY;
    
    simd_float2 lm = { texSlot, 0.0f };
    MetalVertex v[6] = {
        { {sx1, sy1, 0}, {s1, t1}, lm, color },
        { {sx2, sy1, 0}, {s2, t1}, lm, color },
        { {sx1, sy2, 0}, {s1, t2}, lm, color },
        
        { {sx2, sy1, 0}, {s2, t1}, lm, color },
        { {sx2, sy2, 0}, {s2, t2}, lm, color },
        { {sx1, sy2, 0}, {s1, t2}, lm, color }
    };
    
    memcpy(&g_uiVertices[g_uiVertexCount], v, sizeof(v));
    g_uiVertexCount += 6;
}

void R_Metal_SetOrtho(float left, float right, float bottom, float top)
{
    UI_CloseSegment();
    g_orthoLeft = left;
    g_orthoRight = right;
    g_orthoBottom = bottom;
    g_orthoTop = top;
    
    // Store global projection matrix and screen viewport
    g_globalOrtho = make_ortho_matrix(left, right, bottom, top);
    float w = (right - left);
    float h = (bottom - top);
    g_globalViewport = (MTLViewport){ 0.0, 0.0, (double)(w > 0 ? w : 800.0), (double)(h != 0 ? fabsf(h) : 600.0), 0.0, 1.0 };
}

// Returns the active 2D canvas state for coordinate scale diagnostics
void R_Metal_GetCanvasState(float *ortho, float *vp)
{
    if (ortho)
    {
        ortho[0] = g_orthoLeft;
        ortho[1] = g_orthoRight;
        ortho[2] = g_orthoBottom;
        ortho[3] = g_orthoTop;
    }
    if (vp)
    {
        vp[0] = g_currentViewport.originX;
        vp[1] = g_currentViewport.originY;
        vp[2] = g_currentViewport.width;
        vp[3] = g_currentViewport.height;
    }
}

// Fullscreen screen-blend quad (e.g. V_PolyBlend) rendered directly in NDC.
// When running within a scene encoder under MetalFX, the viewport is scaled to match render resolution.
void R_Metal_DrawFullscreenColorQuad(float r, float g, float b, float a)
{
    if (!g_renderEncoder || !g_uiPipelineState || a <= 0.0f)
        return;
    
    // Freeze active 2D segments without flushing into this encoder pass
    UI_CloseSegment();
    
    simd_float4x4 identity = matrix_identity_float4x4;
    FrameUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    uniforms.projectionMatrix = identity;   // Vertices already in NDC
    uniforms.modelViewMatrix = identity;
    uniforms.useTexture = 0;
    uniforms.useFullbright = 0;
    
    double vpW = (g_metalLayer ? g_metalLayer.drawableSize.width  : 800.0) * s_tgtScaleX;
    double vpH = (g_metalLayer ? g_metalLayer.drawableSize.height : 600.0) * s_tgtScaleY;
    MTLViewport vp = { 0.0, 0.0, vpW, vpH, 0.0, 1.0 };
    MQEncoder_SetViewport(vp);
    
    if (g_depthState2D)
        MQEncoder_SetDepthStencilState(g_depthState2D);
    MQEncoder_SetRenderPipelineState(UI_ActivePipeline());
    MQEncoder_SetCullMode(MTLCullModeNone);
    
    // Upload uniforms via dynamic ring buffer
    {
        id<MTLBuffer> ub = nil;
        NSUInteger ubOffset = 0;
        uint32_t ubSize = (uint32_t)sizeof(uniforms);
        
        if (MQ_UniformBuffer_Upload(&uniforms, ubSize, &ub, &ubOffset)) {
            [g_renderEncoder setVertexBuffer:ub offset:ubOffset atIndex:BufferIndexUniforms];
            [g_renderEncoder setFragmentBuffer:ub offset:ubOffset atIndex:BufferIndexUniforms];
        } else {
            [g_renderEncoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:BufferIndexUniforms];
            MQEncoder_SetFragmentBytes(&uniforms, sizeof(uniforms), BufferIndexUniforms);
        }
    }
    
    simd_float4 color = { r, g, b, a };
    MetalVertex verts[6] = {
        { {-1.0f, -1.0f, 0}, {0, 0}, {0, 0}, color },
        { { 1.0f, -1.0f, 0}, {0, 0}, {0, 0}, color },
        { {-1.0f,  1.0f, 0}, {0, 0}, {0, 0}, color },
        
        { { 1.0f, -1.0f, 0}, {0, 0}, {0, 0}, color },
        { { 1.0f,  1.0f, 0}, {0, 0}, {0, 0}, color },
        { {-1.0f,  1.0f, 0}, {0, 0}, {0, 0}, color }
    };
    
    [g_renderEncoder setVertexBytes:verts length:sizeof(verts) atIndex:BufferIndexVertices];
    [g_renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

void R_Metal_BindTexture2D(void *metalTexture)
{
    void *effectiveTex = metalTexture ? metalTexture : (__bridge void *)UI_GetWhiteTexture();
    if (effectiveTex != g_current2DTexture) {
        UI_CloseSegment(); // Freeze active segment instead of flushing
        g_current2DTexture = effectiveTex;
    }
}
