//
//  mq_world_vbo.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#include "quakedef.h"

#import "mq_world_vbo.h"
#import "mq_internal.h"
#import "mq_log.h"
#import "mq_rt.h"

static id<MTLBuffer> s_worldVBO = nil;
static qmodel_t *s_lastBakedModel = NULL;

static uint32_t s_totalVertexCount = 0;
static uint32_t s_opaqueVertexCount = 0;
static uint32_t s_opaqueTriangleCount = 0;
static uint32_t s_totalTriangleCount = 0;

// Computes the orthonormal surface tangent U and bitangent handedness sign for a BSP surface.
simd_float4 MQ_ComputeSurfaceTangent(const msurface_t *surf, simd_float3 normal)
{
    if (!surf || !surf->texinfo) {
        return (simd_float4){ 1.0f, 0.0f, 0.0f, 1.0f };
    }
    
    // Texture projection axis vectors U and V in Quake world coordinates
    simd_float3 s_vec = (simd_float3){
        surf->texinfo->vecs[0][0],
        surf->texinfo->vecs[0][1],
        surf->texinfo->vecs[0][2]
    };
    simd_float3 v_vec = (simd_float3){
        surf->texinfo->vecs[1][0],
        surf->texinfo->vecs[1][1],
        surf->texinfo->vecs[1][2]
    };
    
    // Gram-Schmidt orthogonalization: T = normalize(S - N * dot(N, S))
    simd_float3 n = normal;
    float n_dot_s = simd_dot(n, s_vec);
    simd_float3 t_raw = s_vec - n * n_dot_s;
    float t_len_sq = simd_dot(t_raw, t_raw);
    simd_float3 t = (t_len_sq > 1e-6f) ? simd_normalize(t_raw) : (simd_float3){ 1.0f, 0.0f, 0.0f };
    
    // Bitangent handedness: test cross(N, T) orientation against the V axis
    simd_float3 bitangent = simd_cross(n, t);
    float handedness = (simd_dot(bitangent, v_vec) < 0.0f) ? -1.0f : 1.0f;
    
    return (simd_float4){ t.x, t.y, t.z, handedness };
}

bool MQ_WorldVBO_IsReady(void)
{
    return s_worldVBO != nil && s_totalVertexCount > 0;
}

id<MTLBuffer> MQ_WorldVBO_GetBuffer(void)
{
    return s_worldVBO;
}

uint32_t MQ_WorldVBO_GetTotalVertexCount(void)
{
    return s_totalVertexCount;
}

uint32_t MQ_WorldVBO_GetOpaqueVertexCount(void)
{
    return s_opaqueVertexCount;
}

uint32_t MQ_WorldVBO_GetOpaqueTriangleCount(void)
{
    return s_opaqueTriangleCount;
}

uint32_t MQ_WorldVBO_GetTotalTriangleCount(void)
{
    return s_totalTriangleCount;
}

void MQ_WorldVBO_Clear(void)
{
    s_worldVBO = nil;
    s_lastBakedModel = NULL;
    s_totalVertexCount = 0;
    s_opaqueVertexCount = 0;
    s_opaqueTriangleCount = 0;
    s_totalTriangleCount = 0;
    
    // Invalidate ray tracing BVH structures when world geometry is reset
    if (MQ_RT_IsSupported()) {
        MQ_RT_ClearWorldBVH();
    }
}

void MQ_WorldVBO_Build(qmodel_t *worldmodel)
{
    if (!g_device || !worldmodel) {
        MQ_WorldVBO_Clear();
        return;
    }
    
    // Guard against redundant baking if the active model VBO is already valid
    if (s_lastBakedModel == worldmodel && s_worldVBO != nil) {
        return;
    }
    
    // Clear previous vertex buffers and MetalRT acceleration structures before rebuild
    MQ_WorldVBO_Clear();
    
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    s_lastBakedModel = worldmodel;
    
    // 1. Count world polygons and triangles
    uint32_t opaqueTris = 0;
    uint32_t turbTris = 0;
    
    for (int i = 0; i < worldmodel->numsurfaces; i++) {
        msurface_t *surf = &worldmodel->surfaces[i];
        if (!surf->polys || (surf->flags & SURF_DRAWSKY)) {
            continue;
        }
        
        uint32_t tris = 0;
        for (glpoly_t *p = surf->polys; p; p = p->next) {
            if (p->numverts >= 3) {
                tris += (p->numverts - 2);
            }
        }
        
        if (surf->flags & SURF_DRAWTURB) {
            turbTris += tris;
        } else {
            opaqueTris += tris;
        }
    }
    
    uint32_t totalTris = opaqueTris + turbTris;
    if (totalTris == 0) {
        MQ_WorldVBO_Clear();
        MQ_RT_ClearWorldBVH();
        return;
    }
    
    uint32_t totalVerts = totalTris * 3;
    NSUInteger bufferSize = (NSUInteger)totalVerts * sizeof(MetalWorldVertex);
    
    // 2. Allocate persistent MTLBuffer in shared memory for zero-copy access
    s_worldVBO = [g_device newBufferWithLength:bufferSize
                                       options:MTLResourceStorageModeShared];
    if (!s_worldVBO) {
        MLog(MQ_LVL_ALWAYS, "GFX·VBO", "ERROR: Failed to allocate static world VBO (%u verts, %.2f MB)",
             totalVerts, (double)bufferSize / (1024.0 * 1024.0));
        MQ_WorldVBO_Clear();
        return;
    }
    s_worldVBO.label = @"MQ World Static VBO";
    
    MetalWorldVertex *dst = (MetalWorldVertex *)s_worldVBO.contents;
    uint32_t vertOffset = 0;
    
    // 3. Pass 1: Opaque surfaces starting at offset 0.
    // MetalRT BLAS requirement: a contiguous, unbroken range of opaque triangles.
    for (int i = 0; i < worldmodel->numsurfaces; i++) {
        msurface_t *surf = &worldmodel->surfaces[i];
        if (!surf->polys || (surf->flags & (SURF_DRAWSKY | SURF_DRAWTURB))) {
            surf->vbo_firstvert = 0;
            surf->vbo_numverts = 0;
            continue;
        }
        
        surf->vbo_firstvert = (int)vertOffset;
        uint32_t startVert = vertOffset;
        
        float normScale = (surf->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
        simd_float3 surfNormal = surf->plane ? (simd_float3){
            surf->plane->normal[0] * normScale,
            surf->plane->normal[1] * normScale,
            surf->plane->normal[2] * normScale
        } : (simd_float3){ 0.0f, 0.0f, 1.0f };
        simd_float4 surfTangent = MQ_ComputeSurfaceTangent(surf, surfNormal);
        
        // Compute diffuse texture index and lightmap page index for bindless rendering
        float texIdx = 0.0f;
        if (surf->texinfo && surf->texinfo->texture) {
            for (int t = 0; t < worldmodel->numtextures; t++) {
                if (worldmodel->textures[t] == surf->texinfo->texture) {
                    texIdx = (float)t;
                    break;
                }
            }
        }
        float lmIdx = (surf->lightmaptexturenum >= 0) ? (float)surf->lightmaptexturenum : 0.0f;
        simd_float4 vertColor = (simd_float4){ texIdx, lmIdx, 1.0f, 1.0f };
        
        for (glpoly_t *p = surf->polys; p; p = p->next) {
            for (int j = 0; j < p->numverts - 2; j++) {
                const int idx[3] = { 0, j + 1, j + 2 };
                for (int k = 0; k < 3; k++) {
                    const float *v = p->verts[idx[k]];
                    dst[vertOffset].position      = (simd_float3){ v[0], v[1], v[2] };
                    dst[vertOffset].normal        = surfNormal;
                    dst[vertOffset].tangent       = surfTangent;
                    dst[vertOffset].texCoord      = (simd_float2){ v[3], v[4] };
                    dst[vertOffset].lightmapCoord = (simd_float2){ v[5], v[6] };
                    dst[vertOffset].color         = vertColor;
                    vertOffset++;
                }
            }
        }
        surf->vbo_numverts = (int)(vertOffset - startVert);
    }
    
    s_opaqueTriangleCount = opaqueTris;
    s_opaqueVertexCount = vertOffset;
    
    // 4. Pass 2: Transparent and turbulent surfaces (Water / Lava / Slime / Teleporter)
    for (int i = 0; i < worldmodel->numsurfaces; i++) {
        msurface_t *surf = &worldmodel->surfaces[i];
        if (!surf->polys || !(surf->flags & SURF_DRAWTURB)) {
            continue;
        }
        
        surf->vbo_firstvert = (int)vertOffset;
        uint32_t startVert = vertOffset;
        
        float normScale = (surf->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
        simd_float3 surfNormal = surf->plane ? (simd_float3){
            surf->plane->normal[0] * normScale,
            surf->plane->normal[1] * normScale,
            surf->plane->normal[2] * normScale
        } : (simd_float3){ 0.0f, 0.0f, 1.0f };
        simd_float4 surfTangent = MQ_ComputeSurfaceTangent(surf, surfNormal);
        
        for (glpoly_t *p = surf->polys; p; p = p->next) {
            for (int j = 0; j < p->numverts - 2; j++) {
                const int idx[3] = { 0, j + 1, j + 2 };
                for (int k = 0; k < 3; k++) {
                    const float *v = p->verts[idx[k]];
                    dst[vertOffset].position      = (simd_float3){ v[0], v[1], v[2] };
                    dst[vertOffset].normal        = surfNormal;
                    dst[vertOffset].tangent       = surfTangent;
                    dst[vertOffset].texCoord      = (simd_float2){ v[3], v[4] };
                    dst[vertOffset].lightmapCoord = (simd_float2){ v[5], v[6] };
                    dst[vertOffset].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
                    vertOffset++;
                }
            }
        }
        surf->vbo_numverts = (int)(vertOffset - startVert);
    }
    
    s_totalTriangleCount = totalTris;
    s_totalVertexCount = vertOffset;
    
    double dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    MLog(MQ_LVL_ALWAYS, "GFX·VBO",
         "World static VBO baked: %u verts (%u opaque tris, %u turb tris) in %.2f ms (%.1f MB)",
         s_totalVertexCount, s_opaqueTriangleCount, turbTris, dtMs,
         (double)bufferSize / (1024.0 * 1024.0));
    
    // 5. Build MetalRT BLAS/TLAS directly from the baked VBO via zero-copy access
    if (MQ_RT_IsSupported()) {
        MQ_RT_BuildWorldBVH_ZeroCopy(s_worldVBO, s_opaqueTriangleCount);
    }
}

void MQ_WorldVBO_BuildIfNeeded(qmodel_t *worldmodel)
{
    if (!worldmodel) return;
    if (s_lastBakedModel == worldmodel && s_worldVBO != nil) return;
    MQ_WorldVBO_Build(worldmodel);
}
