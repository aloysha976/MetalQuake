//
//  mq_vertex_buffer.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Dynamic triple-buffered ring buffer for vertices.
//  Replaces chunked setVertexBytes calls with a single upload and draw per batch.
//
//  Synchronized with the GPU via dispatch_semaphore:
//  The CPU writes to frame N while the GPU consumes frames N-1 and N-2.
//

#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <string.h>
#import "mq_internal.h"
#import "mq_log.h"

#define MQ_VB_FRAME_COUNT     3
#define MQ_VB_CAPACITY_BYTES  (32 * 1024 * 1024) // 32 MB per frame buffer capacity
#define MQ_VB_ALIGNMENT       256

static id<MTLBuffer>        s_vbFrames[MQ_VB_FRAME_COUNT];
static dispatch_semaphore_t s_vbSemaphore = nil;
static int                  s_vbIndex = 0;
static NSUInteger           s_vbOffset = 0;
static bool                 s_vbFrameActive = false;

static void MQ_VertexBuffer_EnsureInit(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!g_device)
            return;
        
        s_vbSemaphore = dispatch_semaphore_create(MQ_VB_FRAME_COUNT);
        
        for (int i = 0; i < MQ_VB_FRAME_COUNT; i++) {
            s_vbFrames[i] = [g_device newBufferWithLength:MQ_VB_CAPACITY_BYTES
                                                  options:MTLResourceStorageModeShared];
            if (s_vbFrames[i]) {
                s_vbFrames[i].label = [NSString stringWithFormat:@"MQ Vertex Ring %d", i];
            }
        }
        
        MLog(MQ_LVL_ALWAYS, "GFX·VB",
             "vertex ring buffer initialized: %d frames x %.1f MB",
             MQ_VB_FRAME_COUNT, MQ_VB_CAPACITY_BYTES / (1024.0 * 1024.0));
    });
}

static NSUInteger MQ_VB_AlignUp(NSUInteger value)
{
    return (value + MQ_VB_ALIGNMENT - 1) & ~(NSUInteger)(MQ_VB_ALIGNMENT - 1);
}

void MQ_VertexBuffer_BeginFrame(id<MTLCommandBuffer> cb)
{
    (void)cb;
    
    MQ_VertexBuffer_EnsureInit();
    
    // Guard against an uncompleted previous frame state
    if (s_vbFrameActive) {
        MLog(MQ_LVL_ALWAYS, "GFX·VB",
             "BeginFrame while previous vertex-ring frame active — forcing cancel");
        s_vbFrameActive = false;
        dispatch_semaphore_signal(s_vbSemaphore);
    }
    
    // 100 ms timeout to prevent indefinite thread deadlock
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC));
    if (dispatch_semaphore_wait(s_vbSemaphore, timeout) != 0) {
        MLog(MQ_LVL_ALWAYS, "GFX·VB",
             "WARNING: vertex ring semaphore timed out — forcing recovery");
    }
    
    s_vbIndex = (s_vbIndex + 1) % MQ_VB_FRAME_COUNT;
    s_vbOffset = 0;
    s_vbFrameActive = true;
}

void MQ_VertexBuffer_EndFrame(id<MTLCommandBuffer> cb)
{
    if (!s_vbFrameActive)
        return;
    
    s_vbFrameActive = false;
    
    if (cb) {
        dispatch_semaphore_t sem = s_vbSemaphore;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            (void)completed;
            dispatch_semaphore_signal(sem);
        }];
    } else {
        dispatch_semaphore_signal(s_vbSemaphore);
    }
}

void MQ_VertexBuffer_CancelFrame(void)
{
    if (!s_vbFrameActive)
        return;
    
    s_vbFrameActive = false;
    dispatch_semaphore_signal(s_vbSemaphore);
}

bool MQ_VertexBuffer_Upload(const void *data,
                            uint32_t sizeBytes,
                            id<MTLBuffer> *outBuffer,
                            NSUInteger *outOffset)
{
    if (!s_vbFrameActive || !data || sizeBytes == 0 || !outBuffer || !outOffset)
        return false;
    
    if (!s_vbFrames[s_vbIndex])
        return false;
    
    NSUInteger alignedOffset = MQ_VB_AlignUp(s_vbOffset);
    
    if (alignedOffset + sizeBytes > MQ_VB_CAPACITY_BYTES) {
        return false;
    }
    
    uint8_t *dst = (uint8_t *)s_vbFrames[s_vbIndex].contents;
    memcpy(dst + alignedOffset, data, sizeBytes);
    
    *outBuffer = s_vbFrames[s_vbIndex];
    *outOffset = alignedOffset;
    
    s_vbOffset = alignedOffset + sizeBytes;
    return true;
}
