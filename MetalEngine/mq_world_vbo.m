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
static id<MTLTexture> s_worldLightmapArray = nil;
static id<MTLBuffer> s_worldMaterialBuffer = nil;
#define MQ_MAX_WORLD_TEXTURES 1024
static id<MTLResource> s_residentTextures[MQ_MAX_WORLD_TEXTURES];
static uint32_t s_residentCount = 0;
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

id<MTLTexture> MQ_WorldLightmapArray_GetTexture(void)
{
    return s_worldLightmapArray;
}

void MQ_WorldLightmapArray_Allocate(uint32_t numLayers)
{
    if (!g_device) return;
    
    if (numLayers == 0) {
        numLayers = 1;
    }
    
    s_worldLightmapArray = nil;
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:256
                                                                                   height:256
                                                                                mipmapped:NO];
    desc.textureType = MTLTextureType2DArray;
    desc.arrayLength = (NSUInteger)numLayers;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    
    s_worldLightmapArray = [g_device newTextureWithDescriptor:desc];
    s_worldLightmapArray.label = [NSString stringWithFormat:@"MQ World Lightmaps 2D Array (%u layers)", numLayers];
    
    MLog(MQ_LVL_ALWAYS, "GFX·TEX", "Allocated World Lightmap 2D Array: 256x256x%u mtl=%p",
         numLayers, (__bridge void *)s_worldLightmapArray);
}

void MQ_WorldLightmapArray_UpdateSlice(uint32_t slice, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const void *bytes, uint32_t bytesPerRow)
{
    if (!s_worldLightmapArray || !bytes || w == 0 || h == 0) return;
    if (slice >= s_worldLightmapArray.arrayLength) return;
    
    NSUInteger bytesPerImage = (NSUInteger)bytesPerRow * 256;
    [s_worldLightmapArray replaceRegion:MTLRegionMake2D(x, y, w, h)
                            mipmapLevel:0
                                  slice:(NSUInteger)slice
                              withBytes:bytes
                            bytesPerRow:(NSUInteger)bytesPerRow
                          bytesPerImage:bytesPerImage];
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
    s_worldLightmapArray = nil;
    s_worldMaterialBuffer = nil;
    for (uint32_t i = 0; i < MQ_MAX_WORLD_TEXTURES; i++) {
        s_residentTextures[i] = nil;
    }
    s_residentCount = 0;
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

id<MTLBuffer> MQ_WorldMaterialBuffer_GetBuffer(void)
{
    return s_worldMaterialBuffer;
}

void MQ_WorldMaterialBuffer_BindResident(id<MTLRenderCommandEncoder> encoder)
{
    if (!encoder || s_residentCount == 0)
        return;
    
    [encoder useResources:s_residentTextures
                    count:s_residentCount
                    usage:MTLResourceUsageRead
                   stages:MTLRenderStageFragment];
}

void MQ_WorldMaterialBuffer_UpdateSlot(uint32_t index, void *diffuseHandle, void *glowHandle)
{
    if (!s_worldMaterialBuffer || index >= MQ_MAX_WORLD_TEXTURES)
        return;
    
    MTLResourceID *table = (MTLResourceID *)s_worldMaterialBuffer.contents;
    
    if (diffuseHandle) {
        id<MTLTexture> diffTex = (__bridge id<MTLTexture>)diffuseHandle;
        table[index] = diffTex.gpuResourceID;
    }
    
    id<MTLTexture> blackTex = R_Metal_GetBlackTexture();
    if (glowHandle) {
        id<MTLTexture> glowTex = (__bridge id<MTLTexture>)glowHandle;
        table[MQ_MAX_WORLD_TEXTURES + index] = glowTex.gpuResourceID;
    } else if (blackTex) {
        table[MQ_MAX_WORLD_TEXTURES + index] = blackTex.gpuResourceID;
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
                int i1 = (surf->flags & SURF_PLANEBACK) ? (j + 2) : (j + 1);
                int i2 = (surf->flags & SURF_PLANEBACK) ? (j + 1) : (j + 2);
                const int idx[3] = { 0, i1, i2 };
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
        
        // Find diffuse texture index in the world model table
        float texIdx = 0.0f;
        if (surf->texinfo && surf->texinfo->texture) {
            for (int t = 0; t < worldmodel->numtextures; t++) {
                if (worldmodel->textures[t] == surf->texinfo->texture) {
                    texIdx = (float)t;
                    break;
                }
            }
        }
        
        // Lava and teleports (TEX_SPECIAL) are self-illuminating; standard water uses lightmaps
        float lmIdx = 255.0f;
        if (surf->texinfo && !(surf->texinfo->flags & TEX_SPECIAL)) {
            lmIdx = (surf->lightmaptexturenum >= 0) ? (float)surf->lightmaptexturenum : 255.0f;
        }
        
        // Liquid type: 0 = water, 1 = lava, 2 = slime, 3 = teleporter
        float turbType = 0.0f;
        if (surf->flags & SURF_DRAWLAVA) {
            turbType = 1.0f;
        } else if (surf->flags & SURF_DRAWSLIME) {
            turbType = 2.0f;
        } else if (surf->flags & SURF_DRAWTELE) {
            turbType = 3.0f;
        }
        
        simd_float4 vertColor = (simd_float4){ texIdx, lmIdx, turbType, 1.0f };
        
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
    
    s_totalTriangleCount = totalTris;
    s_totalVertexCount = vertOffset;
    
    double dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    MLog(MQ_LVL_ALWAYS, "GFX·VBO",
         "World static VBO baked: %u verts (%u opaque tris, %u turb tris) in %.2f ms (%.1f MB)",
         s_totalVertexCount, s_opaqueTriangleCount, turbTris, dtMs,
         (double)bufferSize / (1024.0 * 1024.0));
    
    // 5. Allocate monolithic 2D Texture Array for all world lightmap pages
    extern int lightmap_count;
    MQ_WorldLightmapArray_Allocate((uint32_t)lightmap_count);
    
    // 6. Bake Tier 2 Argument Buffer for diffuse (0..1023) and glow (1024..2047) textures
    {
        extern cvar_t gl_fullbrights;
        
        id<MTLTexture> defaultTex = R_Metal_GetBlackTexture();
        MTLResourceID defaultResID = defaultTex ? defaultTex.gpuResourceID : (MTLResourceID){0};
        
        // 2048 дескрипторов: 1024 diffuse + 1024 glow (ровно 16 КБ)
        s_worldMaterialBuffer = [g_device newBufferWithLength:(MQ_MAX_WORLD_TEXTURES * 2) * sizeof(MTLResourceID)
                                                      options:MTLResourceStorageModeShared];
        s_worldMaterialBuffer.label = @"MQ World Material Table Buffer (Baked with Glow)";
        
        MTLResourceID *table = (MTLResourceID *)s_worldMaterialBuffer.contents;
        s_residentCount = 0;
        
        for (uint32_t i = 0; i < MQ_MAX_WORLD_TEXTURES; i++) {
            if (i < (uint32_t)worldmodel->numtextures && worldmodel->textures[i]) {
                texture_t *t = worldmodel->textures[i];
                gltexture_t *glt = (gltexture_t *)t->gltexture;
                id<MTLTexture> diffTex = glt ? (__bridge id<MTLTexture>)glt->metalTexture : defaultTex;
                if (diffTex) {
                    table[i] = diffTex.gpuResourceID;
                    s_residentTextures[s_residentCount++] = diffTex;
                } else {
                    table[i] = defaultResID;
                }
                
                // Glow texture (только если реально есть fullbright, иначе строго defaultTex)
                gltexture_t *glowGlt = (gl_fullbrights.value && t) ? t->fullbright : NULL;
                id<MTLTexture> glowTex = (glowGlt && glowGlt->metalTexture) ? (__bridge id<MTLTexture>)glowGlt->metalTexture : defaultTex;
                if (glowTex) {
                    table[MQ_MAX_WORLD_TEXTURES + i] = glowTex.gpuResourceID;
                    if (glowTex != defaultTex) {
                        s_residentTextures[s_residentCount++] = glowTex;
                    }
                } else {
                    table[MQ_MAX_WORLD_TEXTURES + i] = defaultResID;
                }
            } else {
                table[i] = defaultResID;
                table[MQ_MAX_WORLD_TEXTURES + i] = defaultResID;
            }
        }
        if (defaultTex) {
            s_residentTextures[s_residentCount++] = defaultTex;
        }
    }
    
    // 7. Build MetalRT BLAS/TLAS directly from the baked VBO via zero-copy access
    if (MQ_RT_IsSupported()) {
        MQ_RT_BuildWorldBVH_ZeroCopy(s_worldVBO, s_opaqueTriangleCount);
    }
}

void MQ_WorldVBO_BuildIfNeeded(qmodel_t *worldmodel)
{
    if (!worldmodel) return;
    // Проверяем не только указатель, но и совпадение количества поверхностей,
    // так как при загрузке новой карты память под worldmodel может быть переиспользована
    static int s_lastNumSurfaces = 0;
    if (s_lastBakedModel == worldmodel && s_worldVBO != nil && s_lastNumSurfaces == worldmodel->numsurfaces) return;
    s_lastNumSurfaces = worldmodel->numsurfaces;
    MQ_WorldVBO_Build(worldmodel);
}
