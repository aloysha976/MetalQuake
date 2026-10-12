//
//  mq_encoder_state.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#import "mq_internal.h"
#import "mq_log.h"

// Shadow state cache and redundant binding counters for performance telemetry
static id<MTLRenderPipelineState> s_cachedPipeline = nil;
static id<MTLDepthStencilState> s_cachedDepth = nil;
static MTLViewport s_cachedViewport = { -1, -1, -1, -1, -1, -1 };
static MTLCullMode s_cachedCullMode;
static bool s_cullModeValid = false;
static id<MTLTexture> s_cachedFragTextures[8] = { nil };
static id<MTLSamplerState> s_cachedSamplers[4] = { nil };

// Fragment uniform cache (dedicated to buffer index 1)
// Sized to accommodate WorldUniforms containing GpuDlight[32] (~1152 bytes)
#define MQ_FRAG_UNIFORM_MAX 1536
static uint8_t s_cachedFragBytes[MQ_FRAG_UNIFORM_MAX];
static NSUInteger s_cachedFragLen = 0;
static NSUInteger s_cachedFragSkipCount = 0; // Per-frame statistics

void MQEncoder_ResetStateCache(void)
{
    s_cachedPipeline = nil;
    s_cachedDepth = nil;
    s_cachedViewport = (MTLViewport){ -1, -1, -1, -1, -1, -1 };
    s_cullModeValid = false;
    for (int i = 0; i < 8; i++) s_cachedFragTextures[i] = nil;
    for (int i = 0; i < 4; i++) s_cachedSamplers[i] = nil;
    s_cachedFragLen = 0;
    if (s_cachedFragSkipCount > 0)
        MLog(MQ_LVL_FULL, "GFX·STATE", "frame skipped %u redundant binds",
             (unsigned)s_cachedFragSkipCount);
}

void MQEncoder_SetRenderPipelineState(id<MTLRenderPipelineState> p)
{
    if (!g_renderEncoder || p == nil || p == s_cachedPipeline) return;
    [g_renderEncoder setRenderPipelineState:p];
    s_cachedPipeline = p;
}

void MQEncoder_SetDepthStencilState(id<MTLDepthStencilState> d)
{
    if (!g_renderEncoder || d == nil || d == s_cachedDepth) return;
    [g_renderEncoder setDepthStencilState:d];
    s_cachedDepth = d;
}

void MQEncoder_SetViewport(MTLViewport vp)
{
    if (!g_renderEncoder) return;
    if (vp.originX == s_cachedViewport.originX && vp.originY == s_cachedViewport.originY &&
        vp.width == s_cachedViewport.width && vp.height == s_cachedViewport.height &&
        vp.znear == s_cachedViewport.znear && vp.zfar == s_cachedViewport.zfar)
        return;
    [g_renderEncoder setViewport:vp];
    s_cachedViewport = vp;
}

void MQEncoder_SetCullMode(MTLCullMode mode)
{
    if (!g_renderEncoder) return;
    if (s_cullModeValid && mode == s_cachedCullMode) return;
    [g_renderEncoder setCullMode:mode];
    s_cachedCullMode = mode;
    s_cullModeValid = true;
}

void MQEncoder_SetFragmentTexture(id<MTLTexture> t, NSUInteger index)
{
    if (!g_renderEncoder || index >= 8) return;
    if (t == s_cachedFragTextures[index]) {
        // Redundant texture bind to the same slot — bypass
        if (t != nil) s_cachedFragSkipCount++;
        return;
    }
    [g_renderEncoder setFragmentTexture:t atIndex:index];
    s_cachedFragTextures[index] = t;
}

void MQEncoder_SetFragmentSamplerState(id<MTLSamplerState> s, NSUInteger index)
{
    if (!g_renderEncoder || index >= 4) return;
    if (s == s_cachedSamplers[index]) return;
    [g_renderEncoder setFragmentSamplerState:s atIndex:index];
    s_cachedSamplers[index] = s;
}

void MQEncoder_SetFragmentBytes(const void *bytes, NSUInteger length, NSUInteger index)
{
    if (!g_renderEncoder || !bytes || length > MQ_FRAG_UNIFORM_MAX) return;
    if (index == 1 && length == s_cachedFragLen &&
        memcmp(s_cachedFragBytes, bytes, length) == 0) {
        s_cachedFragSkipCount++;
        return; // Identical uniforms (contiguous surface chain sharing active MVP)
    }
    [g_renderEncoder setFragmentBytes:bytes length:length atIndex:index];
    if (index == 1) {
        memcpy(s_cachedFragBytes, bytes, length);
        s_cachedFragLen = length;
    }
}
