//
//  mq_world_vbo.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Static world VBO (cl.worldmodel) designed for Apple Silicon Metal 3.
//  Bakes BSP vertices upon map loading: Position, Normal, Tangent (Gram-Schmidt),
//  Diffuse UV, and Lightmap UV.
//  Provides a zero-copy buffer for Metal ray tracing (BLAS) and a foundation for dynamic IBO rendering.
//

#ifndef mq_world_vbo_h
#define mq_world_vbo_h

#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>
#include "MetalBridge.h"

#if defined(__OBJC__)
#import <Metal/Metal.h>
#endif

// Forward declarations of Quake types (avoids pulling gl_model.h into the header)
struct qmodel_s;
struct msurface_s;

#ifdef __cplusplus
extern "C" {
#endif

// Computes orthonormal surface tangent U and bitangent handedness sign for a BSP surface.
simd_float4 MQ_ComputeSurfaceTangent(const struct msurface_s *surf, simd_float3 normal);

// Bakes all static surfaces of the worldmodel into a unified MTLBuffer.
void MQ_WorldVBO_Build(struct qmodel_s *worldmodel);

// Validates and bakes world geometry if the map has changed or has not yet been baked.
void MQ_WorldVBO_BuildIfNeeded(struct qmodel_s *worldmodel);

// Frees and clears the static VBO during map transition or reset.
void MQ_WorldVBO_Clear(void);

// Indicates whether the static world VBO is allocated and ready for rendering.
bool MQ_WorldVBO_IsReady(void);

// Returns a pointer to the static world MTLBuffer.
#if defined(__OBJC__)
id<MTLBuffer> MQ_WorldVBO_GetBuffer(void);
#else
void *MQ_WorldVBO_GetBuffer(void);
#endif

// Baked geometry telemetry and metrics.
uint32_t MQ_WorldVBO_GetTotalVertexCount(void);
uint32_t MQ_WorldVBO_GetOpaqueVertexCount(void);
uint32_t MQ_WorldVBO_GetOpaqueTriangleCount(void);
uint32_t MQ_WorldVBO_GetTotalTriangleCount(void);

#ifdef __cplusplus
}
#endif

#endif /* mq_world_vbo_h */
