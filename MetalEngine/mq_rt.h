//
//  mq_rt.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Metal 3 hardware ray tracing infrastructure (MetalRT).
//

#ifndef mq_rt_h
#define mq_rt_h

#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>

#if defined(__OBJC__)
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the ray tracing subsystem and queries hardware ray tracing capabilities.
#if defined(__OBJC__)
void MQ_RT_Init(id<MTLDevice> device);
id<MTLAccelerationStructure> MQ_RT_GetWorldTLAS(void);
#else
void MQ_RT_Init(void *device);
void *MQ_RT_GetWorldTLAS(void);
#endif

// Checks whether hardware ray tracing is supported (Apple Silicon Apple 9 family — M3, M4, and newer).
bool MQ_RT_IsSupported(void);

// Evaluates whether ray tracing is currently active (hardware supported and r_rt cvar enabled).
bool MQ_RT_IsEnabled(void);

// Compiles ray tracing pipeline states matching the target frame format (RGBA16Float / BGRA8).
#if defined(__OBJC__)
void MQ_RT_BuildPipeline(MTLPixelFormat targetFmt, id<MTLLibrary> defaultLibrary);
id<MTLRenderPipelineState> MQ_RT_GetWorldPipeline(void);
id<MTLRenderPipelineState> MQ_RT_GetStaticWorldPipeline(void);
#endif

// Binds the TLAS to the fragment stage and declares BLAS/TLAS resource residency for the encoder.
#if defined(__OBJC__)
void MQ_RT_BindResources(id<MTLRenderCommandEncoder> encoder);
#else
void MQ_RT_BindResources(void *encoder);
#endif

// Builds static world BLAS and TLAS via zero-copy directly from the persistent world VBO.
#if defined(__OBJC__)
void MQ_RT_BuildWorldBVH_ZeroCopy(id<MTLBuffer> worldVBO, uint32_t opaqueTriangleCount);
#else
void MQ_RT_BuildWorldBVH_ZeroCopy(void *worldVBO, uint32_t opaqueTriangleCount);
#endif

// Builds static world BLAS and TLAS from a raw triangle vertex buffer (fallback/legacy path).
void MQ_RT_BuildWorldBVH(const simd_float3 *triVertices, uint32_t triangleCount);

// Releases and resets acceleration structures during map transition or unload.
void MQ_RT_ClearWorldBVH(void);

#ifdef __cplusplus
}
#endif

#endif /* mq_rt_h */
