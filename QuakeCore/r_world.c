/*
 Copyright (C) 1996-2001 Id Software, Inc.
 Copyright (C) 2002-2009 John Fitzgibbons and others
 Copyright (C) 2007-2008 Kristian Duske
 Copyright (C) 2010-2014 QuakeSpasm developers
 
 This program is free software; you can redistribute it and/or
 modify it under the terms of the GNU General Public License
 as published by the Free Software Foundation; either version 2
 of the License, or (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 
 See the GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 
 */
// r_world.c: world model rendering

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"
#include "mq_rt.h"
#include "mq_world_vbo.h"

// Maximum batch geometry size (64K vertices for 16-bit / 32-bit indices)
#define MQ_WORLD_BATCH_MAX_VERTS 65535

// Scene and lightmap external state
simd_float4x4 g_metalWorldMVP;

// Reusable vertex scratch buffer for bmodels and fallback paths
static MetalWorldVertex *g_surfVertScratch = NULL;
static uint32_t g_surfVertScratchCap = 0;
static MetalWorldVertex *R_GetSurfVertScratch (uint32_t count)
{
    if (count > g_surfVertScratchCap)
    {
        uint32_t newCap = g_surfVertScratchCap ? g_surfVertScratchCap : 4096;
        while (newCap < count)
            newCap *= 2;
        free(g_surfVertScratch);
        g_surfVertScratch = (MetalWorldVertex *)malloc(newCap * sizeof(MetalWorldVertex));
        if (!g_surfVertScratch)
        {
            g_surfVertScratchCap = 0;
            return NULL;
        }
        g_surfVertScratchCap = newCap;
    }
    return g_surfVertScratch;
}

// Reusable world index scratch buffer (4 bytes per index vs 80 bytes per vertex)
static uint32_t *g_surfIndexScratch = NULL;
static uint32_t g_surfIndexScratchCap = 0;
static uint32_t *R_GetSurfIndexScratch (uint32_t count)
{
    if (count > g_surfIndexScratchCap)
    {
        uint32_t newCap = g_surfIndexScratchCap ? g_surfIndexScratchCap : 16384;
        while (newCap < count)
            newCap *= 2;
        free(g_surfIndexScratch);
        g_surfIndexScratch = (uint32_t *)malloc(newCap * sizeof(uint32_t));
        if (!g_surfIndexScratch)
        {
            g_surfIndexScratchCap = 0;
            return NULL;
        }
        g_surfIndexScratchCap = newCap;
    }
    return g_surfIndexScratch;
}

extern cvar_t gl_fullbrights, r_drawflat, gl_overbright, r_oldwater, r_oldskyleaf, r_showtris; //johnfitz

byte *SV_FatPVS (vec3_t org, qmodel_t *worldmodel);

void R_Metal_DrawPolySurface (msurface_t *fa, simd_float4x4 mvp)
{
    if (!fa || !fa->polys) return;
    
    glpoly_t *p = fa->polys;
    if (p->numverts < 3) return;
    
    // Diffuse texture
    gltexture_t *diffuseTex = (gltexture_t *)fa->texinfo->texture->gltexture;
    void *diffuseHandle = diffuseTex ? diffuseTex->metalTexture : NULL;
    
    // Retrieve lightmap Metal handle via accessor
    void *lightmapHandle = R_GetLightmapTextureHandle(fa->lightmaptexturenum);
    
    // Scratch buffer allocation to avoid per-surface runtime allocations
    uint32_t vertCount = 3 * (p->numverts - 2);
    MetalWorldVertex *verts = R_GetSurfVertScratch(vertCount);
    if (!verts) return;
    
    float normScale = (fa->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
    simd_float3 surfNormal = fa->plane ? (simd_float3){
        fa->plane->normal[0] * normScale,
        fa->plane->normal[1] * normScale,
        fa->plane->normal[2] * normScale
    } : (simd_float3){ 0.0f, 0.0f, 1.0f };
    simd_float4 surfTangent = MQ_ComputeSurfaceTangent(fa, surfNormal);
    
    uint32_t n = 0;
    for (int i = 0; i < p->numverts - 2; i++)
    {
        const int idx[3] = { 0, i + 1, i + 2 };
        for (int k = 0; k < 3; k++)
        {
            const float *v = p->verts[idx[k]];
            verts[n].position      = (simd_float3){ v[0], v[1], v[2] };
            verts[n].normal        = surfNormal;
            verts[n].tangent       = surfTangent;
            verts[n].texCoord      = (simd_float2){ v[3], v[4] };
            verts[n].lightmapCoord = (simd_float2){ v[5], v[6] };
            verts[n].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
            n++;
        }
    }
    
    R_Metal_Draw3DPolygons(verts, vertCount, mvp, diffuseHandle, lightmapHandle, false, false, "world-solid");
}

//==============================================================================
//
// SETUP CHAINS
//
//==============================================================================

/*
 ================
 R_ClearTextureChains -- ericw
 
 clears texture chains for all textures used by the given model, and also
 clears the lightmap chains
 ================
 */
void R_ClearTextureChains (qmodel_t *mod, texchain_t chain)
{
    int i;
    
    // set all chains to null
    for (i=0 ; i<mod->numtextures ; i++)
        if (mod->textures[i])
            mod->textures[i]->texturechains[chain] = NULL;
    
    // clear lightmap chains
    for (i=0 ; i<lightmap_count ; i++)
        lightmaps[i].polys = NULL;
}

/*
 ================
 R_ChainSurface -- ericw -- adds the given surface to its texture chain
 ================
 */
void R_ChainSurface (msurface_t *surf, texchain_t chain)
{
    surf->texturechain = surf->texinfo->texture->texturechains[chain];
    surf->texinfo->texture->texturechains[chain] = surf;
}

/*
 ================
 R_BackFaceCull -- johnfitz -- returns true if the surface is facing away from vieworg
 ================
 */
qboolean R_BackFaceCull (msurface_t *surf)
{
    double dot;
    
    if (surf->plane->type < 3)
        dot = r_refdef.vieworg[surf->plane->type] - surf->plane->dist;
    else
        dot = DotProduct (r_refdef.vieworg, surf->plane->normal) - surf->plane->dist;
    
    if ((dot < 0) ^ !!(surf->flags & SURF_PLANEBACK))
        return true;
    
    return false;
}

/*
 ===============
 R_MarkSurfaces -- johnfitz -- mark surfaces based on PVS and rebuild texture chains
 ===============
 */
void R_MarkSurfaces (void)
{
    byte		*vis;
    mleaf_t		*leaf;
    msurface_t	*surf, **mark;
    int			i, j;
    qboolean	nearwaterportal;
    
    // clear lightmap chains
    for (i=0 ; i<lightmap_count ; i++)
        lightmaps[i].polys = NULL;
    
    // check this leaf for water portals
    // TODO: loop through all water surfs and use distance to leaf cullbox
    nearwaterportal = false;
    for (i=0, mark = r_viewleaf->firstmarksurface; i < r_viewleaf->nummarksurfaces; i++, mark++)
        if ((*mark)->flags & SURF_DRAWTURB)
            nearwaterportal = true;
    
    // choose vis data
    if (r_novis.value || r_viewleaf->contents == CONTENTS_SOLID || r_viewleaf->contents == CONTENTS_SKY)
        vis = Mod_NoVisPVS (cl.worldmodel);
    else if (nearwaterportal)
        vis = SV_FatPVS (r_origin, cl.worldmodel);
    else
        vis = Mod_LeafPVS (r_viewleaf, cl.worldmodel);
    
    r_visframecount++;
    
    // set all chains to null
    for (i=0 ; i<cl.worldmodel->numtextures ; i++)
        if (cl.worldmodel->textures[i])
            cl.worldmodel->textures[i]->texturechains[chain_world] = NULL;
    
    // iterate through leaves, marking surfaces
    leaf = &cl.worldmodel->leafs[1];
    for (i=0 ; i<cl.worldmodel->numleafs ; i++, leaf++)
    {
        if (vis[i>>3] & (1<<(i&7)))
        {
            if (R_CullBox(leaf->minmaxs, leaf->minmaxs + 3))
                continue;
            
            if (r_oldskyleaf.value || leaf->contents != CONTENTS_SKY)
                for (j=0, mark = leaf->firstmarksurface; j<leaf->nummarksurfaces; j++, mark++)
                {
                    surf = *mark;
                    if (surf->visframe != r_visframecount)
                    {
                        surf->visframe = r_visframecount;
                        if (!R_CullBox(surf->mins, surf->maxs) && !R_BackFaceCull (surf))
                        {
                            rs_brushpolys++; //count wpolys here
                            R_ChainSurface(surf, chain_world);
                            R_RenderDynamicLightmaps(surf);
                            if (surf->texinfo->texture->warpimage)
                                surf->texinfo->texture->update_warp = true;
                        }
                    }
                }
            
            // add static models
            if (leaf->efrags)
                R_StoreEfrags (&leaf->efrags);
        }
    }
}

//==============================================================================
//
// DRAW CHAINS
//
//==============================================================================

/*
 =============
 R_BeginTransparentDrawing -- ericw
 =============
 */
// Blending modes are configured in R_Metal_Draw3DPolygons via blendMode.
// TODO: When entalpha < 1 is used for brush models, dispatch an alpha-blended pass
// using entity alpha written to the vertex color channel.
static void R_BeginTransparentDrawing (float entalpha)
{
    (void)entalpha;
}

/*
 =============
 R_EndTransparentDrawing -- ericw
 =============
 */
static void R_EndTransparentDrawing (float entalpha)
{
    (void)entalpha;
}

/*
 ================
 R_DrawTextureChains_ShowTris -- johnfitz
 ================
 */
void R_DrawTextureChains_ShowTris (qmodel_t *model, texchain_t chain)
{
    int			i;
    msurface_t	*s;
    texture_t	*t;
    glpoly_t	*p;
    
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        if (!t)
            continue;
        
        if (r_oldwater.value && t->texturechains[chain] && (t->texturechains[chain]->flags & SURF_DRAWTURB))
        {
            for (s = t->texturechains[chain]; s; s = s->texturechain)
                for (p = s->polys->next; p; p = p->next)
                {
                    DrawGLTriangleFan (p);
                }
        }
        else
        {
            for (s = t->texturechains[chain]; s; s = s->texturechain)
            {
                DrawGLTriangleFan (s->polys);
            }
        }
    }
}

/*
 ================
 R_DrawTextureChains_Drawflat -- johnfitz
 ================
 */
void R_DrawTextureChains_Drawflat (qmodel_t *model, texchain_t chain)
{
    int			i;
    msurface_t	*s;
    texture_t	*t;
    glpoly_t	*p;
    
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        if (!t)
            continue;
        
        if (r_oldwater.value && t->texturechains[chain] && (t->texturechains[chain]->flags & SURF_DRAWTURB))
        {
            for (s = t->texturechains[chain]; s; s = s->texturechain)
                for (p = s->polys->next; p; p = p->next)
                {
                    srand((unsigned int) (uintptr_t) p);
                    glColor3f (rand()%256/255.0, rand()%256/255.0, rand()%256/255.0);
                    DrawGLPoly (p);
                    rs_brushpasses++;
                }
        }
        else
        {
            for (s = t->texturechains[chain]; s; s = s->texturechain)
            {
                srand((unsigned int) (uintptr_t) s->polys);
                glColor3f (rand()%256/255.0, rand()%256/255.0, rand()%256/255.0);
                DrawGLPoly (s->polys);
                rs_brushpasses++;
            }
        }
    }
    glColor3f (1,1,1);
    srand ((int) (cl.time * 1000));
}

/*
 ================
 R_DrawTextureChains_Glow -- johnfitz
 ================
 */
// Fullbright surface rendering: additive blend of fb texture over base pass.
static void R_Metal_DrawGlowSurface (msurface_t *fa, void *glowTexHandle, simd_float4x4 mvp)
{
    if (!fa || !fa->polys || !glowTexHandle) return;
    
    glpoly_t *p = fa->polys;
    if (p->numverts < 3) return;
    
    uint32_t vertCount = 3 * (p->numverts - 2);
    MetalWorldVertex *verts = R_GetSurfVertScratch(vertCount);
    if (!verts) return;
    
    float normScale = (fa->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
    simd_float3 surfNormal = fa->plane ? (simd_float3){
        fa->plane->normal[0] * normScale,
        fa->plane->normal[1] * normScale,
        fa->plane->normal[2] * normScale
    } : (simd_float3){ 0.0f, 0.0f, 1.0f };
    
    uint32_t n = 0;
    for (int i = 0; i < p->numverts - 2; i++)
    {
        const int idx[3] = { 0, i + 1, i + 2 };
        for (int k = 0; k < 3; k++)
        {
            const float *v = p->verts[idx[k]];
            verts[n].position      = (simd_float3){ v[0], v[1], v[2] };
            verts[n].normal        = surfNormal;
            verts[n].texCoord      = (simd_float2){ v[3], v[4] };
            verts[n].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
            verts[n].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
            n++;
        }
    }
    
    R_Metal_Draw3DPolygons(verts, vertCount, mvp, glowTexHandle, NULL,
                           METAL_BLEND_ADDITIVE, false, "world-glow");
}

void R_DrawTextureChains_Glow (qmodel_t *model, entity_t *ent, texchain_t chain, simd_float4x4 mvp)
{
    int            i;
    msurface_t    *s;
    texture_t    *t;
    gltexture_t    *glt;
    qboolean       useWorldVBO = (model == cl.worldmodel) && MQ_WorldVBO_IsReady();
    
    uint32_t *batchIndices = useWorldVBO ? R_GetSurfIndexScratch(MQ_WORLD_BATCH_MAX_VERTS) : NULL;
    MetalWorldVertex *batchVerts = useWorldVBO ? NULL : R_GetSurfVertScratch(MQ_WORLD_BATCH_MAX_VERTS);
    
    if (useWorldVBO && !batchIndices) return;
    if (!useWorldVBO && !batchVerts) return;
    
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || !(glt = R_TextureAnimation(t, ent != NULL ? ent->frame : 0)->fullbright))
            continue;
        
        void *glowHandle = glt->metalTexture;
        if (!glowHandle)
            continue;
        
        if (useWorldVBO)
        {
            uint32_t batchIndexCount = 0;
            
            for (s = t->texturechains[chain]; s; s = s->texturechain)
            {
                uint32_t numVerts = (uint32_t)s->vbo_numverts;
                if (numVerts == 0)
                    continue;
                
                if (batchIndexCount + numVerts > MQ_WORLD_BATCH_MAX_VERTS)
                {
                    R_Metal_Draw3DWorldIndexed(batchIndices, batchIndexCount, mvp, glowHandle, NULL,
                                               METAL_BLEND_ADDITIVE, false, "world-glow-ibo-batch");
                    batchIndexCount = 0;
                }
                
                uint32_t first = (uint32_t)s->vbo_firstvert;
                for (uint32_t k = 0; k < numVerts; k++)
                {
                    batchIndices[batchIndexCount++] = first + k;
                }
                rs_brushpasses++;
            }
            
            if (batchIndexCount > 0)
            {
                R_Metal_Draw3DWorldIndexed(batchIndices, batchIndexCount, mvp, glowHandle, NULL,
                                           METAL_BLEND_ADDITIVE, false, "world-glow-ibo-batch");
            }
        }
        else
        {
            uint32_t batchVertCount = 0;
            
            for (s = t->texturechains[chain]; s; s = s->texturechain)
            {
                if (!s->polys || s->polys->numverts < 3)
                    continue;
                
                glpoly_t *p = s->polys;
                uint32_t polyVertCount = 3 * (p->numverts - 2);
                
                if (batchVertCount + polyVertCount > MQ_WORLD_BATCH_MAX_VERTS)
                {
                    R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, glowHandle, NULL,
                                           METAL_BLEND_ADDITIVE, false, "world-glow-batch");
                    batchVertCount = 0;
                }
                
                float normScale = (s->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
                simd_float3 surfNormal = s->plane ? (simd_float3){
                    s->plane->normal[0] * normScale,
                    s->plane->normal[1] * normScale,
                    s->plane->normal[2] * normScale
                } : (simd_float3){ 0.0f, 0.0f, 1.0f };
                simd_float4 surfTangent = MQ_ComputeSurfaceTangent(s, surfNormal);
                
                for (int j = 0; j < p->numverts - 2; j++)
                {
                    const int idx[3] = { 0, j + 1, j + 2 };
                    for (int k = 0; k < 3; k++)
                    {
                        const float *v = p->verts[idx[k]];
                        batchVerts[batchVertCount].position      = (simd_float3){ v[0], v[1], v[2] };
                        batchVerts[batchVertCount].normal        = surfNormal;
                        batchVerts[batchVertCount].tangent       = surfTangent;
                        batchVerts[batchVertCount].texCoord      = (simd_float2){ v[3], v[4] };
                        batchVerts[batchVertCount].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
                        batchVerts[batchVertCount].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
                        batchVertCount++;
                    }
                }
                rs_brushpasses++;
            }
            
            if (batchVertCount > 0)
            {
                R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, glowHandle, NULL,
                                       METAL_BLEND_ADDITIVE, false, "world-glow-batch");
            }
        }
    }
}



/*
 ================
 R_DrawTextureChains_Multitexture -- Static VBO + Dynamic IBO by PVS
 ================
 */
void R_DrawTextureChains_Multitexture (qmodel_t *model, entity_t *ent, texchain_t chain, simd_float4x4 mvp)
{
    int         i, lm;
    msurface_t *s;
    texture_t  *t;
    qboolean    useWorldVBO = (model == cl.worldmodel) && MQ_WorldVBO_IsReady();
    
    // =========================================================================
    // Bindless fast-path: render all opaque static world geometry in 1 draw call
    // =========================================================================
    if (useWorldVBO)
    {
        uint32_t maxIndices = MQ_WorldVBO_GetOpaqueVertexCount();
        if (maxIndices == 0) maxIndices = 65536;
        uint32_t *batchIndices = R_GetSurfIndexScratch(maxIndices);
        if (!batchIndices) return;
        
        uint32_t totalIndices = 0;
        
        // 1. Gather indices for all visible opaque map surfaces
        for (i = 0; i < model->numtextures; i++)
        {
            t = model->textures[i];
            if (!t || !t->texturechains[chain] || (t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWSKY | SURF_DRAWTILED | SURF_NOTEXTURE)))
                continue;
            
            for (s = t->texturechains[chain]; s; s = s->texturechain)
            {
                uint32_t numVerts = (uint32_t)s->vbo_numverts;
                if (numVerts == 0)
                    continue;
                
                uint32_t first = (uint32_t)s->vbo_firstvert;
                for (uint32_t k = 0; k < numVerts; k++)
                {
                    batchIndices[totalIndices++] = first + k;
                }
                rs_brushpasses++;
            }
        }
        
        if (totalIndices == 0)
            return;
        
        // 2. Build texture arrays (handling animated switches and monitors)
        void *diffuseHandles[96];
        uint32_t numDiffuse = (model->numtextures > 96) ? 96 : (uint32_t)model->numtextures;
        for (uint32_t d = 0; d < numDiffuse; d++)
        {
            texture_t *tex = model->textures[d];
            if (tex)
            {
                texture_t *animTex = R_TextureAnimation(tex, ent ? ent->frame : 0);
                gltexture_t *glt = animTex ? (gltexture_t *)animTex->gltexture : (gltexture_t *)tex->gltexture;
                diffuseHandles[d] = glt ? glt->metalTexture : NULL;
            }
            else
            {
                diffuseHandles[d] = NULL;
            }
        }
        
        // 3. Build lightmap page arrays
        void *lightmapHandles[32];
        uint32_t numLightmaps = (lightmap_count > 32) ? 32 : (uint32_t)lightmap_count;
        for (uint32_t lmn = 0; lmn < numLightmaps; lmn++)
        {
            lightmapHandles[lmn] = R_GetLightmapTextureHandle(lmn);
        }
        
        // Diagnostic log: output to both engine console and persistent MLog
        static int s_bindlessCheck = 0;
        if (s_bindlessCheck < 5) {
            Con_Printf("[Metal3D] World Render: BINDLESS FAST-PATH (%u indices, 1 draw call, tex=%d, lm=%d, RT=%s)\n",
                       totalIndices, model->numtextures, lightmap_count,
                       (MQ_RT_IsEnabled() && MQ_RT_GetWorldTLAS()) ? "ON" : "OFF");
            MLog(MQ_LVL_ALWAYS, "Metal3D", "World Render: BINDLESS FAST-PATH (%u indices, 1 draw call, tex=%d, lm=%d, RT=%s)",
                 totalIndices, model->numtextures, lightmap_count,
                 (MQ_RT_IsEnabled() && MQ_RT_GetWorldTLAS()) ? "ON" : "OFF");
            s_bindlessCheck++;
        }
        
        // 4. Single draw call submission for the entire static level
        R_Metal_Draw3DWorldBindless(batchIndices, totalIndices, mvp,
                                    diffuseHandles, numDiffuse,
                                    lightmapHandles, numLightmaps,
                                    "world-static-bindless");
        return;
    }
    
    // Fallback diagnostic log: invoked only when VBO is not ready
    if (model == cl.worldmodel)
    {
        static int s_fallbackCheck = 0;
        if (s_fallbackCheck < 5) {
            Con_Printf("[Metal3D] World Render: FALLBACK TO BUCKETS (vboReady=%d)\n",
                       MQ_WorldVBO_IsReady());
            s_fallbackCheck++;
        }
    }
    
    // Temporary chain heads for each lightmap (supports up to 128 lightmaps)
#define MQ_MAX_LM_BUCKETS 128
    msurface_t *lmBuckets[MQ_MAX_LM_BUCKETS];
    
    uint32_t *batchIndices = useWorldVBO ? R_GetSurfIndexScratch(MQ_WORLD_BATCH_MAX_VERTS) : NULL;
    MetalWorldVertex *batchVerts = useWorldVBO ? NULL : R_GetSurfVertScratch(MQ_WORLD_BATCH_MAX_VERTS);
    
    if (useWorldVBO && !batchIndices) return;
    if (!useWorldVBO && !batchVerts) return;
    
    for (i = 0; i < model->numtextures; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || (t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWSKY | SURF_DRAWTILED | SURF_NOTEXTURE)))
            continue;
        
        gltexture_t *diffuseTex = (gltexture_t *)R_TextureAnimation(t, ent ? ent->frame : 0)->gltexture;
        void *diffuseHandle = diffuseTex ? diffuseTex->metalTexture : NULL;
        
        memset(lmBuckets, 0, sizeof(lmBuckets));
        
        // 1. Sort current texture surfaces into lightmap buckets
        for (s = t->texturechains[chain]; s; s = s->texturechain)
        {
            int lmIndex = s->lightmaptexturenum;
            if (lmIndex < 0 || lmIndex >= MQ_MAX_LM_BUCKETS)
                lmIndex = 0;
            
            s->polys->chain = (glpoly_t *)lmBuckets[lmIndex];
            lmBuckets[lmIndex] = s;
        }
        
        // 2. Render each bucket: exactly one draw call per lightmap
        for (lm = 0; lm < MQ_MAX_LM_BUCKETS; lm++)
        {
            if (!lmBuckets[lm])
                continue;
            
            void *lmHandle = R_GetLightmapTextureHandle(lm);
            
            if (useWorldVBO)
            {
                // Compact 32-bit index path for static world VBO
                uint32_t batchIndexCount = 0;
                
                for (s = lmBuckets[lm]; s; s = (msurface_t *)s->polys->chain)
                {
                    uint32_t numVerts = (uint32_t)s->vbo_numverts;
                    if (numVerts == 0)
                        continue;
                    
                    if (batchIndexCount + numVerts > MQ_WORLD_BATCH_MAX_VERTS)
                    {
                        R_Metal_Draw3DWorldIndexed(batchIndices, batchIndexCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_OPAQUE, false, "world-ibo-batch");
                        batchIndexCount = 0;
                    }
                    
                    uint32_t first = (uint32_t)s->vbo_firstvert;
                    for (uint32_t k = 0; k < numVerts; k++)
                    {
                        batchIndices[batchIndexCount++] = first + k;
                    }
                    rs_brushpasses++;
                }
                
                if (batchIndexCount > 0)
                {
                    R_Metal_Draw3DWorldIndexed(batchIndices, batchIndexCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_OPAQUE, false, "world-ibo-batch");
                }
            }
            else
            {
                // Fallback path for brush submodels (doors, lifts)
                uint32_t batchVertCount = 0;
                
                for (s = lmBuckets[lm]; s; s = (msurface_t *)s->polys->chain)
                {
                    glpoly_t *p = s->polys;
                    if (!p || p->numverts < 3)
                        continue;
                    
                    uint32_t polyVertCount = 3 * (p->numverts - 2);
                    if (batchVertCount + polyVertCount > MQ_WORLD_BATCH_MAX_VERTS)
                    {
                        R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_OPAQUE, false, "bmodel-batch");
                        batchVertCount = 0;
                    }
                    
                    float normScale = (s->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
                    simd_float3 surfNormal = s->plane ? (simd_float3){
                        s->plane->normal[0] * normScale,
                        s->plane->normal[1] * normScale,
                        s->plane->normal[2] * normScale
                    } : (simd_float3){ 0.0f, 0.0f, 1.0f };
                    simd_float4 surfTangent = MQ_ComputeSurfaceTangent(s, surfNormal);
                    
                    for (int j = 0; j < p->numverts - 2; j++)
                    {
                        const int idx[3] = { 0, j + 1, j + 2 };
                        for (int k = 0; k < 3; k++)
                        {
                            const float *v = p->verts[idx[k]];
                            batchVerts[batchVertCount].position      = (simd_float3){ v[0], v[1], v[2] };
                            batchVerts[batchVertCount].normal        = surfNormal;
                            batchVerts[batchVertCount].tangent       = surfTangent;
                            batchVerts[batchVertCount].texCoord      = (simd_float2){ v[3], v[4] };
                            batchVerts[batchVertCount].lightmapCoord = (simd_float2){ v[5], v[6] };
                            batchVerts[batchVertCount].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
                            batchVertCount++;
                        }
                    }
                    rs_brushpasses++;
                }
                
                if (batchVertCount > 0)
                {
                    R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_OPAQUE, false, "bmodel-batch");
                }
            }
        }
    }
}

/*
 ================
 R_DrawTextureChains_NoTexture -- johnfitz
 
 draws surfs whose textures were missing from the BSP
 ================
 */
void R_DrawTextureChains_NoTexture (qmodel_t *model, texchain_t chain)
{
    int			i;
    msurface_t	*s;
    texture_t	*t;
    qboolean	bound;
    
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_NOTEXTURE))
            continue;
        
        bound = false;
        
        for (s = t->texturechains[chain]; s; s = s->texturechain)
        {
            if (!bound) //only bind once we are sure we need this texture
            {
                GL_Bind (t->gltexture);
                bound = true;
            }
            DrawGLPoly (s->polys);
            rs_brushpasses++;
        }
    }
}

/*
 ================
 R_DrawTextureChains_TextureOnly -- johnfitz
 ================
 */
void R_DrawTextureChains_TextureOnly (qmodel_t *model, entity_t *ent, texchain_t chain)
{
    int			i;
    msurface_t	*s;
    texture_t	*t;
    qboolean	bound;
    
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || t->texturechains[chain]->flags & (SURF_DRAWTURB | SURF_DRAWSKY))
            continue;
        
        bound = false;
        
        for (s = t->texturechains[chain]; s; s = s->texturechain)
        {
            if (!bound) //only bind once we are sure we need this texture
            {
                GL_Bind ((R_TextureAnimation(t, ent != NULL ? ent->frame : 0))->gltexture);
                
                if (t->texturechains[chain]->flags & SURF_DRAWFENCE)
                    glEnable (GL_ALPHA_TEST); // Flip alpha test back on
                
                bound = true;
            }
            DrawGLPoly (s->polys);
            rs_brushpasses++;
        }
        
        if (bound && t->texturechains[chain]->flags & SURF_DRAWFENCE)
            glDisable (GL_ALPHA_TEST); // Flip alpha test back off
    }
}

/*
 ================
 GL_WaterAlphaForEntitySurface -- ericw
 
 Returns the water alpha to use for the entity and surface combination.
 ================
 */
float GL_WaterAlphaForEntitySurface (entity_t *ent, msurface_t *s)
{
    float entalpha;
    if (ent == NULL || ent->alpha == ENTALPHA_DEFAULT)
        entalpha = GL_WaterAlphaForSurface(s);
    else
        entalpha = ENTALPHA_DECODE(ent->alpha);
    return entalpha;
}

/*
 ================
 R_Metal_DrawWaterPolySurface -- vkQuake alpha model
 ================
 */
void R_Metal_DrawWaterPolySurface (msurface_t *fa, entity_t *ent, simd_float4x4 mvp)
{
    if (!fa || !fa->polys) return;
    
    glpoly_t *p = fa->polys;
    if (p->numverts < 3) return;
    
    // Animated texture frame (*lava1, *water0, *tele01, etc.)
    texture_t *t = fa->texinfo->texture;
    texture_t *animTex = R_TextureAnimation(t, (ent != NULL) ? ent->frame : 0);
    gltexture_t *diffuseTex = (animTex && animTex->gltexture) ? animTex->gltexture : t->gltexture;
    void *diffuseHandle = (diffuseTex && diffuseTex->metalTexture) ? diffuseTex->metalTexture : NULL;
    
    // Lightmaps are skipped for lava and teleports (self-illuminated surfaces)
    void *lightmapHandle = NULL;
    if (!(fa->texinfo->flags & TEX_SPECIAL))
    {
        lightmapHandle = R_GetLightmapTextureHandle(fa->lightmaptexturenum);
    }
    
    // Compute alpha using vkQuake precedence rules with direct cvar fallback
    extern cvar_t r_wateralpha, r_lavaalpha, r_telealpha, r_slimealpha;
    extern float map_wateralpha, map_lavaalpha, map_telealpha, map_slimealpha;
    
    float alpha = 1.0f;
    
    if (fa->flags & SURF_DRAWLAVA) {
        if (r_lavaalpha.value > 0.0f)
            alpha = r_lavaalpha.value;
        else if (map_lavaalpha > 0.0f)
            alpha = map_lavaalpha;
        else if (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f)
            alpha = r_wateralpha.value;
        else if (map_wateralpha > 0.0f)
            alpha = map_wateralpha;
    } else if (fa->flags & SURF_DRAWSLIME) {
        if (r_slimealpha.value > 0.0f)
            alpha = r_slimealpha.value;
        else if (map_slimealpha > 0.0f)
            alpha = map_slimealpha;
        else if (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f)
            alpha = r_wateralpha.value;
        else if (map_wateralpha > 0.0f)
            alpha = map_wateralpha;
    } else if (fa->flags & SURF_DRAWTELE) {
        if (r_telealpha.value > 0.0f)
            alpha = r_telealpha.value;
        else if (map_telealpha > 0.0f)
            alpha = map_telealpha;
        else if (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f)
            alpha = r_wateralpha.value;
        else if (map_wateralpha > 0.0f)
            alpha = map_wateralpha;
    } else {
        // Standard water
        if (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f)
            alpha = r_wateralpha.value;
        else if (map_wateralpha > 0.0f)
            alpha = map_wateralpha;
    }
    
    // Guard against zero/invisible alpha: clamp strictly to (0.0, 1.0]
    if (alpha <= 0.0f || alpha > 1.0f) {
        alpha = 1.0f;
    }
    
    uint32_t vertCount = 3 * (p->numverts - 2);
    MetalWorldVertex *verts = R_GetSurfVertScratch(vertCount);
    if (!verts) return;
    
    float normScale = (fa->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
    simd_float3 surfNormal = fa->plane ? (simd_float3){
        fa->plane->normal[0] * normScale,
        fa->plane->normal[1] * normScale,
        fa->plane->normal[2] * normScale
    } : (simd_float3){ 0.0f, 0.0f, 1.0f };
    
    uint32_t n = 0;
    for (int i = 0; i < p->numverts - 2; i++)
    {
        const int idx[3] = { 0, i + 1, i + 2 };
        for (int k = 0; k < 3; k++)
        {
            const float *v = p->verts[idx[k]];
            verts[n].position      = (simd_float3){ v[0], v[1], v[2] };
            verts[n].normal        = surfNormal;
            verts[n].texCoord      = (simd_float2){ v[3], v[4] };
            verts[n].lightmapCoord = (simd_float2){ v[5], v[6] };
            verts[n].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, alpha };
            n++;
        }
    }
    
    // Render using blended pipeline state
    R_Metal_Draw3DPolygons(verts, vertCount, mvp, diffuseHandle, lightmapHandle, true, true, "world-water");
}

/*
 ================
 R_DrawTextureChains_Water -- Batched turbulent surfaces
 ================
 */
void R_DrawTextureChains_Water (qmodel_t *model, entity_t *ent, texchain_t chain, simd_float4x4 mvp)
{
    int i;
    msurface_t *s;
    texture_t *t;
    
    if (r_drawflat_cheatsafe || r_lightmap_cheatsafe)
        return;
    
    extern cvar_t r_wateralpha, r_lavaalpha, r_telealpha, r_slimealpha;
    extern float map_wateralpha, map_lavaalpha, map_telealpha, map_slimealpha;
    
    MetalWorldVertex *batchVerts = R_GetSurfVertScratch(MQ_WORLD_BATCH_MAX_VERTS);
    if (!batchVerts)
        return;
    
    for (i = 0; i < model->numtextures; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTURB))
            continue;
        
        texture_t *animTex = R_TextureAnimation(t, (ent != NULL) ? ent->frame : 0);
        gltexture_t *diffuseTex = (animTex && animTex->gltexture) ? animTex->gltexture : t->gltexture;
        void *diffuseHandle = (diffuseTex && diffuseTex->metalTexture) ? diffuseTex->metalTexture : NULL;
        
        int currentLightmapNum = -1;
        uint32_t batchVertCount = 0;
        
        for (s = t->texturechains[chain]; s; s = s->texturechain)
        {
            if (!s->polys || s->polys->numverts < 3)
                continue;
            
            glpoly_t *p = s->polys;
            uint32_t polyVertCount = 3 * (p->numverts - 2);
            
            int lm = (s->texinfo->flags & TEX_SPECIAL) ? -1 : s->lightmaptexturenum;
            
            if ((lm != currentLightmapNum && batchVertCount > 0) ||
                (batchVertCount + polyVertCount > MQ_WORLD_BATCH_MAX_VERTS))
            {
                void *lmHandle = (currentLightmapNum >= 0) ? R_GetLightmapTextureHandle(currentLightmapNum) : NULL;
                R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_ALPHA, true, "world-water-batch");
                batchVertCount = 0;
            }
            
            currentLightmapNum = lm;
            
            float alpha = 1.0f;
            if (s->flags & SURF_DRAWLAVA) {
                alpha = (r_lavaalpha.value > 0.0f) ? r_lavaalpha.value : (map_lavaalpha > 0.0f ? map_lavaalpha : 1.0f);
            } else if (s->flags & SURF_DRAWSLIME) {
                alpha = (r_slimealpha.value > 0.0f) ? r_slimealpha.value : (map_slimealpha > 0.0f ? map_slimealpha : 1.0f);
            } else if (s->flags & SURF_DRAWTELE) {
                alpha = (r_telealpha.value > 0.0f) ? r_telealpha.value : (map_telealpha > 0.0f ? map_telealpha : 1.0f);
            } else {
                alpha = (r_wateralpha.value > 0.0f && r_wateralpha.value < 1.0f) ? r_wateralpha.value : (map_wateralpha > 0.0f ? map_wateralpha : 1.0f);
            }
            if (alpha <= 0.0f || alpha > 1.0f) alpha = 1.0f;
            
            float normScale = (s->flags & SURF_PLANEBACK) ? -1.0f : 1.0f;
            simd_float3 surfNormal = s->plane ? (simd_float3){
                s->plane->normal[0] * normScale,
                s->plane->normal[1] * normScale,
                s->plane->normal[2] * normScale
            } : (simd_float3){ 0.0f, 0.0f, 1.0f };
            simd_float4 surfTangent = MQ_ComputeSurfaceTangent(s, surfNormal);
            
            for (int j = 0; j < p->numverts - 2; j++)
            {
                const int idx[3] = { 0, j + 1, j + 2 };
                for (int k = 0; k < 3; k++)
                {
                    const float *v = p->verts[idx[k]];
                    batchVerts[batchVertCount].position      = (simd_float3){ v[0], v[1], v[2] };
                    batchVerts[batchVertCount].normal        = surfNormal;
                    batchVerts[batchVertCount].tangent       = surfTangent;
                    batchVerts[batchVertCount].texCoord      = (simd_float2){ v[3], v[4] };
                    batchVerts[batchVertCount].lightmapCoord = (simd_float2){ v[5], v[6] };
                    batchVerts[batchVertCount].color         = (simd_float4){ 1.0f, 1.0f, 1.0f, alpha };
                    batchVertCount++;
                }
            }
            rs_brushpasses++;
        }
        
        if (batchVertCount > 0)
        {
            void *lmHandle = (currentLightmapNum >= 0) ? R_GetLightmapTextureHandle(currentLightmapNum) : NULL;
            R_Metal_Draw3DPolygons(batchVerts, batchVertCount, mvp, diffuseHandle, lmHandle, METAL_BLEND_ALPHA, true, "world-water-batch");
        }
    }
}

/*
 ================
 R_DrawTextureChains_White -- johnfitz -- draw sky and water as white polys when r_lightmap is 1
 ================
 */
void R_DrawTextureChains_White (qmodel_t *model, texchain_t chain)
{
    int			i;
    msurface_t	*s;
    texture_t	*t;
    
    glDisable (GL_TEXTURE_2D);
    for (i=0 ; i<model->numtextures ; i++)
    {
        t = model->textures[i];
        
        if (!t || !t->texturechains[chain] || !(t->texturechains[chain]->flags & SURF_DRAWTILED))
            continue;
        
        for (s = t->texturechains[chain]; s; s = s->texturechain)
        {
            DrawGLPoly (s->polys);
            rs_brushpasses++;
        }
    }
    glEnable (GL_TEXTURE_2D);
}

/*
 ================
 R_DrawLightmapChains -- Legacy stub for Metal backend
 ================
 */
void R_DrawLightmapChains (void)
{
    // Legacy dual-pass lightmap rendering is obsolete.
    // Diffuse and lightmap contributions are evaluated in a single pass
    // inside the world fragment shader.
}

/*
 =============
 GLWorld_CreateShaders -- Legacy stub for Metal backend
 =============
 */
void GLWorld_CreateShaders (void)
{
    // Legacy runtime GLSL compilation is replaced by MSL shaders
    // compiled from Shaders.metal and RTShaders.metal during engine initialization.
}

/*
 ================
 R_DrawTextureChains_GLSL -- Legacy stub for Metal backend
 ================
 */
void R_DrawTextureChains_GLSL (qmodel_t *model, entity_t *ent, texchain_t chain)
{
    // OpenGL VBO pipeline is replaced by R_DrawTextureChains_Multitexture().
    (void)model;
    (void)ent;
    (void)chain;
}

/*
 ================
 R_DrawLightmapChains_GLSL -- Legacy stub for Metal backend
 ================
 */
void R_DrawLightmapChains_GLSL (qmodel_t *model, entity_t *ent, texchain_t chain)
{
    // Debug lightmap-only rendering (r_lightmap 1) routes through R_DrawTextureChains_White()
    // and is handled via uniform state in the Metal pipeline.
    (void)model;
    (void)ent;
    (void)chain;
}

/*
 =============
 R_DrawWorld -- johnfitz -- rewritten
 =============
 */
void R_DrawTextureChains (qmodel_t *model, entity_t *ent, texchain_t chain, simd_float4x4 mvp)
{
    float entalpha = (ent != NULL) ? ENTALPHA_DECODE(ent->alpha) : 1.0f;
    
    // Upload modified lightmaps once per frame for the primary world model.
    // Brush submodels (doors, lifts) reuse the same lightmap atlas.
    if (model == cl.worldmodel)
        R_UploadLightmaps ();
    
    // Flat shaded rendering cheat mode
    if (r_drawflat_cheatsafe)
    {
        R_DrawTextureChains_Drawflat (model, chain);
        return;
    }
    
    // Texture-only unlit rendering cheat mode
    if (r_fullbright_cheatsafe)
    {
        R_DrawTextureChains_TextureOnly (model, ent, chain);
        goto fullbrights;
    }
    
    // Lightmaps-only rendering cheat mode
    if (r_lightmap_cheatsafe)
    {
        R_DrawTextureChains_White (model, chain);
        return;
    }
    
    // Primary single-pass multitexturing path
    R_BeginTransparentDrawing (entalpha);
    
    R_DrawTextureChains_Multitexture (model, ent, chain, mvp);
    
    R_EndTransparentDrawing (entalpha);
    
fullbrights:
    // Secondary glow pass is omitted in single-pass rendering mode
    // to avoid redundant geometry processing on TBDR architectures.
    /*
     if (gl_fullbrights.value)
     {
     Fog_StartAdditive ();
     R_DrawTextureChains_Glow (model, ent, chain, mvp);
     Fog_StopAdditive ();
     }
     */
    return;
}

/*
 =============
 R_DrawWorld
 =============
 */
void R_DrawWorld (void)
{
    // ===== DIAGNOSTIC: R_DrawWorld ENTRY =====
    {
        static int s_drawWorldCount = 0;
        if (s_drawWorldCount < 5) {
            Con_Printf("[Metal3D] R_DrawWorld ENTERED | cheatsafe=%d | worldmodel=%p\n",
                       r_drawworld_cheatsafe, cl.worldmodel);
            s_drawWorldCount++;
        }
    }
    // ===== END DIAGNOSTIC =====
    
    if (!r_drawworld_cheatsafe)
        return;
    
    // Ensure world static VBO and acceleration structures are constructed
    MQ_WorldVBO_BuildIfNeeded(cl.worldmodel);
    
    // Read player camera state and calculate view-projection matrix
    extern refdef_t r_refdef;
    extern cvar_t gl_farclip;
    float aspect = (vid.width > 0 && vid.height > 0) ? ((float)vid.width / (float)vid.height) : (4.0f / 3.0f);
    float farClip = ((gl_farclip.value > 4096.0f) ? gl_farclip.value : 65536.0f) * 2.0f;
    g_metalWorldMVP = R_Metal_ComputeMVP(r_refdef.fov_y, aspect, 4.0f, farClip,
                                         (simd_float3){r_refdef.vieworg[0], r_refdef.vieworg[1], r_refdef.vieworg[2]},
                                         (simd_float3){r_refdef.viewangles[0], r_refdef.viewangles[1], r_refdef.viewangles[2]});
    
    R_DrawTextureChains (cl.worldmodel, NULL, chain_world, g_metalWorldMVP);
}

/*
 =============
 R_DrawWorld_Water -- ericw -- moved from R_DrawTextureChains_Water, which is no longer specific to the world.
 =============
 */
void R_DrawWorld_Water (void)
{
    if (!r_drawworld_cheatsafe)
        return;
    
    R_DrawTextureChains_Water (cl.worldmodel, NULL, chain_world, g_metalWorldMVP);
}

/*
 =============
 R_DrawWorld_ShowTris -- ericw -- moved from R_DrawTextureChains_ShowTris, which is no longer specific to the world.
 =============
 */
void R_DrawWorld_ShowTris (void)
{
    if (!r_drawworld_cheatsafe)
        return;
    
    R_DrawTextureChains_ShowTris (cl.worldmodel, chain_world);
}
