//
//  mq_uniform_buffer.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Dynamic triple-buffered ring buffer for uniforms.
//  Replaces setVertexBytes for large uniform structures (e.g. WorldUniforms = 1152 bytes).
//  Enables a single upload and bind per batch instead of thousands of setVertexBytes calls per frame.
//

#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import "mq_internal.h"
#import "mq_log.h"

#define MQ_UB_FRAME_COUNT     3
#define MQ_UB_CAPACITY_BYTES  (16 * 1024 * 1024) // 16 MB per frame to accommodate dense map geometry
#define MQ_UB_ALIGNMENT       256

static id<MTLBuffer>        s_ubFrames[MQ_UB_FRAME_COUNT];
static dispatch_semaphore_t s_ubSemaphore = nil;
static int                  s_ubIndex = 0;
static NSUInteger           s_ubOffset = 0;
static bool                 s_ubFrameActive = false;

static void MQ_UniformBuffer_EnsureInit(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!g_device)
            return;
        
        s_ubSemaphore = dispatch_semaphore_create(MQ_UB_FRAME_COUNT);
        
        for (int i = 0; i < MQ_UB_FRAME_COUNT; i++) {
            s_ubFrames[i] = [g_device newBufferWithLength:MQ_UB_CAPACITY_BYTES
                                                  options:MTLResourceStorageModeShared];
            if (s_ubFrames[i]) {
                s_ubFrames[i].label = [NSString stringWithFormat:@"MQ Uniform Ring %d", i];
            }
        }
        
        MLog(MQ_LVL_ALWAYS, "GFX·UB",
             "uniform ring buffer initialized: %d frames x %.1f MB",
             MQ_UB_FRAME_COUNT, MQ_UB_CAPACITY_BYTES / (1024.0 * 1024.0));
    });
}

static NSUInteger MQ_UB_AlignUp(NSUInteger value)
{
    return (value + MQ_UB_ALIGNMENT - 1) & ~(NSUInteger)(MQ_UB_ALIGNMENT - 1);
}

void MQ_UniformBuffer_BeginFrame(id<MTLCommandBuffer> cb)
{
    (void)cb;
    
    MQ_UniformBuffer_EnsureInit();
    
    // Guard against an uncompleted previous frame state
    if (s_ubFrameActive) {
        MLog(MQ_LVL_ALWAYS, "GFX·UB",
             "BeginFrame while previous uniform-ring frame active — forcing cancel");
        s_ubFrameActive = false;
        dispatch_semaphore_signal(s_ubSemaphore);
    }
    
    // 100 ms timeout to prevent indefinite thread deadlock
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC));
    if (dispatch_semaphore_wait(s_ubSemaphore, timeout) != 0) {
        MLog(MQ_LVL_ALWAYS, "GFX·UB",
             "WARNING: uniform ring semaphore timed out — forcing recovery");
    }
    
    s_ubIndex = (s_ubIndex + 1) % MQ_UB_FRAME_COUNT;
    s_ubOffset = 0;
    s_ubFrameActive = true;
}

void MQ_UniformBuffer_EndFrame(id<MTLCommandBuffer> cb)
{
    if (!s_ubFrameActive)
        return;
    
    s_ubFrameActive = false;
    
    if (cb) {
        dispatch_semaphore_t sem = s_ubSemaphore;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            dispatch_semaphore_signal(sem);
        }];
    } else {
        dispatch_semaphore_signal(s_ubSemaphore);
    }
}

void MQ_UniformBuffer_CancelFrame(void)
{
    if (!s_ubFrameActive)
        return;
    
    s_ubFrameActive = false;
    dispatch_semaphore_signal(s_ubSemaphore);
}

bool MQ_UniformBuffer_Upload(const void *data,
                             uint32_t sizeBytes,
                             id<MTLBuffer> *outBuffer,
                             NSUInteger *outOffset)
{
    if (!s_ubFrameActive || !data || sizeBytes == 0 || !outBuffer || !outOffset)
        return false;
    
    if (!s_ubFrames[s_ubIndex])
        return false;
    
    NSUInteger alignedOffset = MQ_UB_AlignUp(s_ubOffset);
    
    if (alignedOffset + sizeBytes > MQ_UB_CAPACITY_BYTES) {
        return false;
    }
    
    uint8_t *dst = (uint8_t *)s_ubFrames[s_ubIndex].contents;
    memcpy(dst + alignedOffset, data, sizeBytes);
    
    *outBuffer = s_ubFrames[s_ubIndex];
    *outOffset = alignedOffset;
    
    s_ubOffset = alignedOffset + sizeBytes;
    return true;
}
