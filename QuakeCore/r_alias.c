/*
 Copyright (C) 1996-2001 Id Software, Inc.
 Copyright (C) 2002-2009 John Fitzgibbons and others
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

//r_alias.c -- alias model rendering

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"
#include <dispatch/dispatch.h>

extern simd_float4x4 g_metalWorldMVP;
extern cvar_t r_drawflat, gl_overbright_models, gl_fullbrights, r_lerpmodels, r_lerpmove, r_shadows; //johnfitz & Alexey Chernyak
extern cvar_t scr_fov, cl_gun_fovscale;

//johnfitz -- struct for passing lerp information to drawing functions
typedef struct {
    short pose1;
    short pose2;
    float blend;
    vec3_t origin;
    vec3_t angles;
} lerpdata_t;

// values for shadow matrix
#define SHADOW_SKEW_X -0.7
#define SHADOW_SKEW_Y 0.0
#define SHADOW_VSCALE 0.0
#define SHADOW_HEIGHT 0.1

// Metal matrix utilities
static simd_float4x4 R_Metal_MatrixTranslation(float x, float y, float z)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (simd_float4){ x, y, z, 1.0f };
    return m;
}

static simd_float4x4 R_Metal_MatrixScale(float sx, float sy, float sz)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){ sx, 0.0f, 0.0f, 0.0f };
    m.columns[1] = (simd_float4){ 0.0f, sy, 0.0f, 0.0f };
    m.columns[2] = (simd_float4){ 0.0f, 0.0f, sz, 0.0f };
    m.columns[3] = (simd_float4){ 0.0f, 0.0f, 0.0f, 1.0f };
    return m;
}

static simd_float4x4 R_Metal_MatrixRotateZ(float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){  c, s, 0.0f, 0.0f };
    m.columns[1] = (simd_float4){ -s, c, 0.0f, 0.0f };
    return m;
}

static simd_float4x4 R_Metal_MatrixRotateY(float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){ c, 0.0f, -s, 0.0f };
    m.columns[2] = (simd_float4){ s, 0.0f,  c, 0.0f };
    return m;
}

static simd_float4x4 R_Metal_MatrixRotateX(float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[1] = (simd_float4){ 0.0f,  c, s, 0.0f };
    m.columns[2] = (simd_float4){ 0.0f, -s, c, 0.0f };
    return m;
}

static simd_float4x4 R_Metal_ComputeEntityMVP(entity_t *e, aliashdr_t *paliashdr, lerpdata_t *lerpdata, float fovscale)
{
    float scalefactor = ENTSCALE_DECODE(e->scale);
    
    simd_float4x4 m = R_Metal_MatrixTranslation(lerpdata->origin[0], lerpdata->origin[1], lerpdata->origin[2]);
    m = simd_mul(m, R_Metal_MatrixRotateZ(lerpdata->angles[1]));
    m = simd_mul(m, R_Metal_MatrixRotateY(-lerpdata->angles[0]));
    m = simd_mul(m, R_Metal_MatrixRotateX(lerpdata->angles[2]));
    
    if (scalefactor != 1.0f) {
        m = simd_mul(m, R_Metal_MatrixScale(scalefactor, scalefactor, scalefactor));
    }
    
    m = simd_mul(m, R_Metal_MatrixTranslation(paliashdr->scale_origin[0],
                                              paliashdr->scale_origin[1] * fovscale,
                                              paliashdr->scale_origin[2] * fovscale));
    
    m = simd_mul(m, R_Metal_MatrixScale(paliashdr->scale[0],
                                        paliashdr->scale[1] * fovscale,
                                        paliashdr->scale[2] * fovscale));
    
    return simd_mul(g_metalWorldMVP, m);
}

static simd_float4x4 R_Metal_ComputeShadowMVP(entity_t *e, aliashdr_t *paliashdr, lerpdata_t *lerpdata, float lheight)
{
    float scalefactor = ENTSCALE_DECODE(e->scale);
    
    simd_float4x4 sm = matrix_identity_float4x4;
    sm.columns[2] = (simd_float4){ SHADOW_SKEW_X, SHADOW_SKEW_Y, SHADOW_VSCALE, 0.0f };
    sm.columns[3] = (simd_float4){ 0.0f, 0.0f, SHADOW_HEIGHT, 1.0f };
    
    simd_float4x4 m = R_Metal_MatrixTranslation(lerpdata->origin[0], lerpdata->origin[1], lerpdata->origin[2]);
    m = simd_mul(m, R_Metal_MatrixTranslation(0.0f, 0.0f, -lheight));
    m = simd_mul(m, sm);
    m = simd_mul(m, R_Metal_MatrixTranslation(0.0f, 0.0f, lheight));
    m = simd_mul(m, R_Metal_MatrixRotateZ(lerpdata->angles[1]));
    m = simd_mul(m, R_Metal_MatrixRotateY(-lerpdata->angles[0]));
    m = simd_mul(m, R_Metal_MatrixRotateX(lerpdata->angles[2]));
    
    if (scalefactor != 1.0f) {
        m = simd_mul(m, R_Metal_MatrixScale(scalefactor, scalefactor, scalefactor));
    }
    
    m = simd_mul(m, R_Metal_MatrixTranslation(paliashdr->scale_origin[0], paliashdr->scale_origin[1], paliashdr->scale_origin[2]));
    m = simd_mul(m, R_Metal_MatrixScale(paliashdr->scale[0], paliashdr->scale[1], paliashdr->scale[2]));
    
    return simd_mul(g_metalWorldMVP, m);
}

//up to 16 color translated skins
gltexture_t *playertextures[MAX_SCOREBOARD]; //johnfitz -- changed to an array of pointers

// Dynamically resizing scratch buffers for synchronous alias models (viewmodel, shadows)
static MetalWorldVertex *s_aliasMeshScratch = NULL;
static uint32_t s_aliasMeshScratchCap = 0;
static MetalWorldVertex *s_aliasTempScratch = NULL;
static uint32_t s_aliasTempScratchCap = 0;

// World model parallel batching structures (GCD)
#define MQ_MAX_ALIAS_JOBS 1024
#define ALIAS_MAX_TEMP_VERTS 256

typedef struct {
    aliashdr_t       *paliashdr;
    lerpdata_t        lerpdata;
    simd_float4x4     entityMVP;
    void             *metalTex;
    void             *glowTex; // Fullbright glow mask texture (eyes, runes, panels)
    simd_float3       baseLight;
    const float      *shadedots;
    float             entalpha;
    qboolean          shading;
    int               blendMode;
    const char       *tag;
    
    MetalWorldVertex *meshVerts;
    uint32_t          maxVerts;
    uint32_t          outCount;
} alias_job_t;

static alias_job_t s_aliasJobs[MQ_MAX_ALIAS_JOBS];

static MetalWorldVertex *s_aliasParallelPool = NULL;
static size_t s_aliasParallelPoolCap = 0;

static bool R_Alias_EnsurePoolCapacity(size_t totalVerts)
{
    if (totalVerts > s_aliasParallelPoolCap) {
        size_t newCap = s_aliasParallelPoolCap ? s_aliasParallelPoolCap : 65536;
        while (newCap < totalVerts) newCap *= 2;
        free(s_aliasParallelPool);
        s_aliasParallelPool = (MetalWorldVertex *)malloc(newCap * sizeof(MetalWorldVertex));
        s_aliasParallelPoolCap = s_aliasParallelPool ? newCap : 0;
        if (!s_aliasParallelPool) return false;
    }
    return true;
}

// Thread-safe mesh unpacking job (executed in parallel on CPU worker threads)
static void R_Alias_UnpackJob(alias_job_t *job)
{
    aliashdr_t *paliashdr = job->paliashdr;
    lerpdata_t *lerpdata = &job->lerpdata;
    trivertx_t *verts1, *verts2;
    int *commands;
    int count;
    float u, v;
    float blend, iblend;
    qboolean lerping;
    
    // Per-strip temporary buffer stored on thread stack (~20 KB)
    MetalWorldVertex tempVerts[ALIAS_MAX_TEMP_VERTS];
    
    if (lerpdata->pose1 != lerpdata->pose2)
    {
        lerping = true;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata->pose1 * paliashdr->poseverts;
        verts2 += lerpdata->pose2 * paliashdr->poseverts;
        blend   = lerpdata->blend;
        iblend  = 1.0f - blend;
    }
    else
    {
        lerping = false;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata->pose1 * paliashdr->poseverts;
        blend   = iblend = 0.0f;
    }
    
    commands = (int *)((byte *)paliashdr + paliashdr->commands);
    
    MetalWorldVertex *meshVerts = job->meshVerts;
    uint32_t maxVerts = job->maxVerts;
    uint32_t outCount = 0;
    
    const simd_float3 blend3  = (simd_float3){ blend, blend, blend };
    const simd_float3 iblend3 = (simd_float3){ iblend, iblend, iblend };
    const simd_float3 baseLight = job->baseLight;
    const simd_float3 defNormal = (simd_float3){ 0.0f, 0.0f, 1.0f };
    const simd_float4 defTangent = (simd_float4){ 1.0f, 0.0f, 0.0f, 1.0f };
    const float *dots = job->shadedots;
    const qboolean doShading = job->shading;
    const simd_float4 unlitColor = (simd_float4){ 1.0f, 1.0f, 1.0f, job->entalpha };
    
    while (1)
    {
        count = *commands++;
        if (!count)
            break;
        
        qboolean isFan = (count < 0);
        int numVerts = isFan ? -count : count;
        
        // Stack buffer overflow guard: skip only this strip
        if (numVerts > ALIAS_MAX_TEMP_VERTS)
        {
            commands += numVerts * 2;
            verts1 += numVerts;
            if (lerping) verts2 += numVerts;
            continue;
        }
        
        for (int j = 0; j < numVerts; j++)
        {
            u = ((float *)commands)[0];
            v = ((float *)commands)[1];
            commands += 2;
            
            simd_float3 pos;
            float norm = 1.0f;
            
            if (lerping)
            {
                simd_float3 p1 = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                simd_float3 p2 = (simd_float3){ (float)verts2->v[0], (float)verts2->v[1], (float)verts2->v[2] };
                pos = p1 * iblend3 + p2 * blend3;
                
                if (doShading)
                    norm = dots[verts1->lightnormalindex] * iblend + dots[verts2->lightnormalindex] * blend;
                
                verts1++;
                verts2++;
            }
            else
            {
                pos = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                if (doShading)
                    norm = dots[verts1->lightnormalindex];
                
                verts1++;
            }
            
            simd_float4 color;
            if (doShading)
            {
                float dotVal = (norm > 0.0f) ? norm : 0.0f;
                float lightFactor = 0.40f + 0.60f * dotVal;
                simd_float3 lit = baseLight * lightFactor;
                color = (simd_float4){ lit.x, lit.y, lit.z, job->entalpha };
            }
            else
            {
                color = unlitColor;
            }
            
            tempVerts[j].position      = pos;
            tempVerts[j].normal        = defNormal;
            tempVerts[j].tangent       = defTangent;
            tempVerts[j].texCoord      = (simd_float2){ u, v };
            tempVerts[j].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
            tempVerts[j].color         = color;
        }
        
        if (isFan)
        {
            for (int k = 1; k < numVerts - 1; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    meshVerts[outCount++] = tempVerts[0];
                    meshVerts[outCount++] = tempVerts[k];
                    meshVerts[outCount++] = tempVerts[k + 1];
                }
            }
        }
        else
        {
            for (int k = 0; k < numVerts - 2; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    if (k & 1)
                    {
                        meshVerts[outCount++] = tempVerts[k + 1];
                        meshVerts[outCount++] = tempVerts[k];
                        meshVerts[outCount++] = tempVerts[k + 2];
                    }
                    else
                    {
                        meshVerts[outCount++] = tempVerts[k];
                        meshVerts[outCount++] = tempVerts[k + 1];
                        meshVerts[outCount++] = tempVerts[k + 2];
                    }
                }
            }
        }
    }
    
    job->outCount = outCount;
}

static MetalWorldVertex *R_GetAliasMeshScratch(uint32_t count)
{
    if (count > s_aliasMeshScratchCap) {
        uint32_t newCap = s_aliasMeshScratchCap ? s_aliasMeshScratchCap : 8192;
        while (newCap < count) newCap *= 2;
        free(s_aliasMeshScratch);
        s_aliasMeshScratch = (MetalWorldVertex *)malloc(newCap * sizeof(MetalWorldVertex));
        s_aliasMeshScratchCap = s_aliasMeshScratch ? newCap : 0;
    }
    return s_aliasMeshScratch;
}

static MetalWorldVertex *R_GetAliasTempScratch(uint32_t count)
{
    if (count > s_aliasTempScratchCap) {
        uint32_t newCap = s_aliasTempScratchCap ? s_aliasTempScratchCap : 1024;
        while (newCap < count) newCap *= 2;
        free(s_aliasTempScratch);
        s_aliasTempScratch = (MetalWorldVertex *)malloc(newCap * sizeof(MetalWorldVertex));
        s_aliasTempScratchCap = s_aliasTempScratch ? newCap : 0;
    }
    return s_aliasTempScratch;
}

const float    r_avertexnormals[NUMVERTEXNORMALS][3] = {
#include "anorms.h"
};

extern vec3_t    lightcolor; //johnfitz -- replaces "float shadelight" for lit support

// precalculated dot products for quantized angles
#define SHADEDOT_QUANT 16
static const float    r_avertexnormal_dots[SHADEDOT_QUANT][256] = {
#include "anorm_dots.h"
};

extern    vec3_t    lightspot;

static const float    *shadedots = r_avertexnormal_dots[0];
static vec3_t    shadevector;

static float    entalpha; //johnfitz

static qboolean overbright; //johnfitz

static qboolean shading = true; //johnfitz -- if false, disable vertex shading for various reasons (fullbright, r_lightmap, showtris, etc)

/*
 =============
 GLAlias_CreateShaders -- Legacy stub for Metal backend
 =============
 */
void GLAlias_CreateShaders (void)
{
    // Legacy GLSL 1.10 pipeline is removed.
    // Model shaders are compiled in MSL (Shaders.metal -> alias_fragment_main).
    // Pipeline State is initialized in mq_world3d.m (s_aliasPipelineState).
}

/*
 =============
 GL_DrawAliasFrame_GLSL -- Legacy stub for Metal backend
 =============
 */
void GL_DrawAliasFrame_GLSL (aliashdr_t *paliashdr, lerpdata_t lerpdata, gltexture_t *tx, gltexture_t *fb)
{
    // OpenGL VBO calls (glDrawElements) are replaced in the Metal pipeline.
    // Alias model and monster rendering is handled by:
    // 1. R_DrawAliasEntitiesOnList() - multithreaded mesh unpacking on CPU (GCD).
    // 2. GL_DrawAliasFrame_Metal() - SIMD-accelerated frame lerping.
    // 3. R_Metal_Draw3DPolygons() - Metal command encoding.
    (void)paliashdr;
    (void)lerpdata;
    (void)tx;
    (void)fb;
}

/*
 =============
 GL_DrawAliasFrame -- Metal (Zero Allocations + SIMD Vectorized Lerp)
 =============
 */
void GL_DrawAliasFrame_Metal (aliashdr_t *paliashdr, lerpdata_t lerpdata, simd_float4x4 entityMVP, void *metalTexture, void *glowTexture)
{
    trivertx_t *verts1, *verts2;
    int *commands;
    int count;
    float u, v;
    float blend, iblend;
    qboolean lerping;
    
    if (lerpdata.pose1 != lerpdata.pose2)
    {
        lerping = true;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata.pose1 * paliashdr->poseverts;
        verts2 += lerpdata.pose2 * paliashdr->poseverts;
        blend   = lerpdata.blend;
        iblend  = 1.0f - blend;
    }
    else
    {
        lerping = false;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata.pose1 * paliashdr->poseverts;
        blend   = iblend = 0.0f;
    }
    
    commands = (int *)((byte *)paliashdr + paliashdr->commands);
    
    // Reuse persistent scratch buffers to avoid allocation overhead
    uint32_t maxVerts = (uint32_t)paliashdr->numtris * 3;
    MetalWorldVertex *meshVerts = R_GetAliasMeshScratch(maxVerts);
    MetalWorldVertex *tempVerts = R_GetAliasTempScratch(maxVerts);
    if (!meshVerts || !tempVerts) {
        return;
    }
    
    uint32_t outCount = 0;
    
    // SIMD constants for frame interpolation and vertex lighting
    const simd_float3 blend3  = (simd_float3){ blend, blend, blend };
    const simd_float3 iblend3 = (simd_float3){ iblend, iblend, iblend };
    const simd_float3 baseLight = shading ? (simd_float3){ lightcolor[0], lightcolor[1], lightcolor[2] }
    : (simd_float3){ 1.0f, 1.0f, 1.0f };
    const simd_float3 defNormal = (simd_float3){ 0.0f, 0.0f, 1.0f };
    const simd_float4 defTangent = (simd_float4){ 1.0f, 0.0f, 0.0f, 1.0f };
    
    while (1)
    {
        count = *commands++;
        if (!count)
            break;
        
        qboolean isFan = (count < 0);
        int numVerts = isFan ? -count : count;
        if (numVerts > (int)maxVerts) {
            MLog(MQ_LVL_ALWAYS, "GFX·MESH", "ERROR: command %d verts exceeds mesh capacity -- stream corrupted", numVerts);
            break;
        }
        
        for (int j = 0; j < numVerts; j++)
        {
            u = ((float *)commands)[0];
            v = ((float *)commands)[1];
            commands += 2;
            
            simd_float3 pos;
            float norm = 1.0f;
            
            if (lerping)
            {
                // Vectorized vertex position lerping with SIMD FMA
                simd_float3 p1 = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                simd_float3 p2 = (simd_float3){ (float)verts2->v[0], (float)verts2->v[1], (float)verts2->v[2] };
                pos = p1 * iblend3 + p2 * blend3;
                
                norm = shadedots[verts1->lightnormalindex] * iblend + shadedots[verts2->lightnormalindex] * blend;
                verts1++;
                verts2++;
            }
            else
            {
                pos = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                norm = shadedots[verts1->lightnormalindex];
                verts1++;
            }
            
            simd_float4 color;
            if (shading)
            {
                float dot = (norm > 0.0f) ? norm : 0.0f;
                float lightFactor = 0.40f + 0.60f * dot;
                simd_float3 lit = baseLight * lightFactor;
                color = (simd_float4){ lit.x, lit.y, lit.z, entalpha };
            }
            else
            {
                color = (simd_float4){ 1.0f, 1.0f, 1.0f, entalpha };
            }
            
            tempVerts[j].position      = pos;
            tempVerts[j].normal        = defNormal;
            tempVerts[j].tangent       = defTangent;
            tempVerts[j].texCoord      = (simd_float2){ u, v };
            tempVerts[j].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
            tempVerts[j].color         = color;
        }
        
        // Triangulate strips and fans
        if (isFan)
        {
            for (int k = 1; k < numVerts - 1; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    meshVerts[outCount++] = tempVerts[0];
                    meshVerts[outCount++] = tempVerts[k];
                    meshVerts[outCount++] = tempVerts[k + 1];
                }
            }
        }
        else
        {
            for (int k = 0; k < numVerts - 2; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    if (k & 1)
                    {
                        meshVerts[outCount++] = tempVerts[k + 1];
                        meshVerts[outCount++] = tempVerts[k];
                        meshVerts[outCount++] = tempVerts[k + 2];
                    }
                    else
                    {
                        meshVerts[outCount++] = tempVerts[k];
                        meshVerts[outCount++] = tempVerts[k + 1];
                        meshVerts[outCount++] = tempVerts[k + 2];
                    }
                }
            }
        }
    }
    
    if (outCount > 0)
    {
        if (MLog_Budget("GFX·MESH", 50))
            MLog(MQ_LVL_DEV, "GFX·MESH", "draw verts=%u blend=%d tex=%s shading=%d entalpha=%.2f",
                 outCount, (entalpha < 1.0f) ? 1 : 0,
                 metalTexture ? "yes" : "NULL", shading ? 1 : 0, entalpha);
        
        R_Metal_Draw3DPolygons(meshVerts, outCount, entityMVP, metalTexture, glowTexture,
                               (entalpha < 1.0f) ? METAL_BLEND_ALPHA : METAL_BLEND_OPAQUE, false,
                               (currententity == &cl.viewent) ? "alias-viewmodel" : "alias-world");
    }
    
    // Scratch buffer is reused across frames; no free required
    rs_aliaspasses += paliashdr->numtris;
}

/*
 =================
 R_SetupAliasFrame -- johnfitz -- rewritten to support lerping
 =================
 */
void R_SetupAliasFrame (aliashdr_t *paliashdr, int frame, lerpdata_t *lerpdata)
{
    entity_t        *e = currententity;
    int                posenum, numposes;
    
    if ((frame >= paliashdr->numframes) || (frame < 0))
    {
        Con_DPrintf ("R_AliasSetupFrame: no such frame %d for '%s'\n", frame, e->model->name);
        frame = 0;
    }
    
    posenum = paliashdr->frames[frame].firstpose;
    numposes = paliashdr->frames[frame].numposes;
    
    if (numposes > 1)
    {
        e->lerptime = paliashdr->frames[frame].interval;
        posenum += (int)(cl.time / e->lerptime) % numposes;
    }
    else
        e->lerptime = 0.1;
    
    if (e->lerpflags & LERP_RESETANIM) //kill any lerp in progress
    {
        e->lerpstart = 0;
        e->previouspose = posenum;
        e->currentpose = posenum;
        e->lerpflags -= LERP_RESETANIM;
    }
    else if (e->currentpose != posenum) // pose changed, start new lerp
    {
        if (e->lerpflags & LERP_RESETANIM2) //defer lerping one more time
        {
            e->lerpstart = 0;
            e->previouspose = posenum;
            e->currentpose = posenum;
            e->lerpflags -= LERP_RESETANIM2;
        }
        else
        {
            e->lerpstart = cl.time;
            e->previouspose = e->currentpose;
            e->currentpose = posenum;
        }
    }
    
    //set up values
    if (r_lerpmodels.value && !(e->model->flags & MOD_NOLERP && r_lerpmodels.value != 2))
    {
        if (e->lerpflags & LERP_FINISH && numposes == 1)
            lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / (e->lerpfinish - e->lerpstart), 1.0f);
        else
            lerpdata->blend = CLAMP (0.0f, (float)(cl.time - e->lerpstart) / e->lerptime, 1.0f);
        if (lerpdata->blend == 1.0f)
            e->previouspose = e->currentpose;
        lerpdata->pose1 = e->previouspose;
        lerpdata->pose2 = e->currentpose;
    }
    else //don't lerp
    {
        lerpdata->blend = 1;
        lerpdata->pose1 = posenum;
        lerpdata->pose2 = posenum;
    }
}

/*
 =================
 R_SetupEntityTransform -- johnfitz -- set up transform part of lerpdata
 =================
 */
void R_SetupEntityTransform (entity_t *e, lerpdata_t *lerpdata)
{
    float blend;
    vec3_t d;
    int i;
    
    // if LERP_RESETMOVE, kill any lerps in progress
    if (e->lerpflags & LERP_RESETMOVE)
    {
        e->movelerpstart = 0;
        VectorCopy (e->origin, e->previousorigin);
        VectorCopy (e->origin, e->currentorigin);
        VectorCopy (e->angles, e->previousangles);
        VectorCopy (e->angles, e->currentangles);
        e->lerpflags -= LERP_RESETMOVE;
    }
    else if (!VectorCompare (e->origin, e->currentorigin) || !VectorCompare (e->angles, e->currentangles)) // origin/angles changed, start new lerp
    {
        e->movelerpstart = cl.time;
        VectorCopy (e->currentorigin, e->previousorigin);
        VectorCopy (e->origin,  e->currentorigin);
        VectorCopy (e->currentangles, e->previousangles);
        VectorCopy (e->angles,  e->currentangles);
    }
    
    //set up values
    if (r_lerpmove.value && e != &cl.viewent && e->lerpflags & LERP_MOVESTEP)
    {
        if (e->lerpflags & LERP_FINISH)
            blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / (e->lerpfinish - e->movelerpstart), 1.0f);
        else
            blend = CLAMP (0.0f, (float)(cl.time - e->movelerpstart) / 0.1f, 1.0f);
        
        //translation
        VectorSubtract (e->currentorigin, e->previousorigin, d);
        lerpdata->origin[0] = e->previousorigin[0] + d[0] * blend;
        lerpdata->origin[1] = e->previousorigin[1] + d[1] * blend;
        lerpdata->origin[2] = e->previousorigin[2] + d[2] * blend;
        
        //rotation
        VectorSubtract (e->currentangles, e->previousangles, d);
        for (i = 0; i < 3; i++)
        {
            if (d[i] > 180)  d[i] -= 360;
            if (d[i] < -180) d[i] += 360;
        }
        lerpdata->angles[0] = e->previousangles[0] + d[0] * blend;
        lerpdata->angles[1] = e->previousangles[1] + d[1] * blend;
        lerpdata->angles[2] = e->previousangles[2] + d[2] * blend;
    }
    else //don't lerp
    {
        VectorCopy (e->origin, lerpdata->origin);
        VectorCopy (e->angles, lerpdata->angles);
    }
}

/*
 =================
 R_SetupAliasLighting -- johnfitz -- broken out from R_DrawAliasModel and rewritten
 =================
 */
void R_SetupAliasLighting (entity_t	*e)
{
    vec3_t		dist;
    float		add;
    int			i;
    int		quantizedangle;
    float		radiansangle;
    
    // if the initial trace is completely black, try again from above
    // this helps with models whose origin is slightly below ground level
    // (e.g. some of the candles in the DOTM start map)
    if (!R_LightPoint (e->origin))
    {
        vec3_t lpos;
        VectorCopy (e->origin, lpos);
        lpos[2] += e->model->maxs[2] * 0.5f;
        R_LightPoint (lpos);
    }
    
    //add dlights
    for (i=0 ; i<MAX_DLIGHTS ; i++)
    {
        if (cl_dlights[i].die >= cl.time)
        {
            VectorSubtract (currententity->origin, cl_dlights[i].origin, dist);
            add = cl_dlights[i].radius - VectorLength(dist);
            if (add > 0)
                VectorMA (lightcolor, add, cl_dlights[i].color, lightcolor);
        }
    }
    
    // minimum light value on gun (24)
    if (e == &cl.viewent)
    {
        add = 72.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
        if (add > 0.0f)
        {
            lightcolor[0] += add / 3.0f;
            lightcolor[1] += add / 3.0f;
            lightcolor[2] += add / 3.0f;
        }
    }
    
    // minimum light value on players (8)
    if (currententity > cl_entities && currententity <= cl_entities + cl.maxclients)
    {
        add = 24.0f - (lightcolor[0] + lightcolor[1] + lightcolor[2]);
        if (add > 0.0f)
        {
            lightcolor[0] += add / 3.0f;
            lightcolor[1] += add / 3.0f;
            lightcolor[2] += add / 3.0f;
        }
    }
    
    // clamp lighting so it doesn't overbright as much (96)
    if (overbright)
    {
        add = 288.0f / (lightcolor[0] + lightcolor[1] + lightcolor[2]);
        if (add < 1.0f)
            VectorScale(lightcolor, add, lightcolor);
    }
    
    //hack up the brightness when fullbrights but no overbrights (256)
    if (gl_fullbrights.value && !gl_overbright_models.value)
        if (e->model->flags & MOD_FBRIGHTHACK)
        {
            lightcolor[0] = 256.0f;
            lightcolor[1] = 256.0f;
            lightcolor[2] = 256.0f;
        }
    
    quantizedangle = ((int)(e->angles[1] * (SHADEDOT_QUANT / 360.0))) & (SHADEDOT_QUANT - 1);
    
    //ericw -- shadevector is passed to the shader to compute shadedots inside the
    //shader, see GLAlias_CreateShaders()
    radiansangle = (quantizedangle / 16.0) * 2.0 * 3.14159;
    shadevector[0] = cos(-radiansangle);
    shadevector[1] = sin(-radiansangle);
    shadevector[2] = 1;
    VectorNormalize(shadevector);
    //ericw --
    
    shadedots = r_avertexnormal_dots[quantizedangle];
    VectorScale (lightcolor, 1.0f / 200.0f, lightcolor);
    
    // Viewmodel lighting diagnostics: resolved color and shadedots quantization index
    if (e == &cl.viewent && MLog_Budget("ENG·LIGHT", 30))
        MLog(MQ_LVL_DEV, "ENG·LIGHT", "viewmodel '%s' lightcolor=(%.3f %.3f %.3f) shadeRow=%d",
             e->model->name, lightcolor[0], lightcolor[1], lightcolor[2], quantizedangle);
}

/*
 =================
 R_DrawAliasModel -- Metal 3
 =================
 */
void R_DrawAliasModel (entity_t *e)
{
    aliashdr_t  *paliashdr;
    int         anim, skinnum;
    gltexture_t *tx, *fb;
    lerpdata_t  lerpdata;
    float       fovscale = 1.0f;
    
    if (!e || !e->model)
        return;
    
    paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
    if (!paliashdr)
        return;
    
    currententity = e;
    R_SetupAliasFrame (paliashdr, e->frame, &lerpdata);
    R_SetupEntityTransform (e, &lerpdata);
    
    // Viewmodel (cl.viewent) is never frustum culled
    if (e != &cl.viewent && R_CullModelForEntity(e))
        return;
    
    if (e == &cl.viewent && scr_fov.value > 90.f && cl_gun_fovscale.value)
        fovscale = tan(scr_fov.value * (0.5f * M_PI / 180.f));
    
    overbright = !!gl_overbright_models.value;
    shading = true;
    
    if (r_drawflat_cheatsafe || r_lightmap_cheatsafe)
        entalpha = 1.0f;
    else
        entalpha = ENTALPHA_DECODE(e->alpha);
    
    if (entalpha == 0.0f)
        return;
    
    rs_aliaspolys += paliashdr->numtris;
    R_SetupAliasLighting (e);
    
    // Skin and texture selection
    anim = (int)(cl.time * 10) & 3;
    skinnum = e->skinnum;
    if ((skinnum >= paliashdr->numskins) || (skinnum < 0))
    {
        Con_DPrintf ("R_DrawAliasModel: no such skin # %d for '%s'\n", skinnum, e->model->name);
        skinnum = 0;
    }
    
    // For non-animated skins slots [1..3] are unpopulated; fall back to base slot [0]
    tx = paliashdr->gltextures[skinnum][anim];
    if (!tx)
        tx = paliashdr->gltextures[skinnum][0];
    
    fb = paliashdr->fbtextures[skinnum][anim];
    if (!fb)
        fb = paliashdr->fbtextures[skinnum][0];
    
    if (e->colormap != vid.colormap && !gl_nocolors.value)
    {
        if ((uintptr_t)e >= (uintptr_t)&cl_entities[1] && (uintptr_t)e <= (uintptr_t)&cl_entities[cl.maxclients])
            tx = playertextures[e - cl_entities - 1];
    }
    if (!gl_fullbrights.value)
        fb = NULL;
    
    void *metalTex = (tx && tx->metalTexture) ? tx->metalTexture : NULL;
    
    // Diagnostics logging: viewmodel and world models separated
    if (e == &cl.viewent)
    {
        if (MLog_Budget("ALIAS·VM", 60))
            MLog(MQ_LVL_DEV, "ALIAS·VM", "'%s' skin=%d anim=%d entalpha=%.2f tx=%p mtl=%s fb=%s",
                 e->model->name, skinnum, anim, entalpha, tx,
                 metalTex ? "yes" : "NULL", fb ? "yes" : "no");
    }
    else if (MLog_Budget("ENG·ALIAS", 20))
    {
        MLog(MQ_LVL_DEV, "ENG·ALIAS", "'%s' org=(%.0f %.0f %.0f) tris=%d mtl=%s",
             e->model->name, lerpdata.origin[0], lerpdata.origin[1], lerpdata.origin[2],
             paliashdr->numtris, metalTex ? "yes" : "NULL");
    }
    
    // Compute final MVP matrix for current entity
    simd_float4x4 entityMVP = R_Metal_ComputeEntityMVP(e, paliashdr, &lerpdata, fovscale);
    
    void *glowTex = (fb && fb->metalTexture) ? fb->metalTexture : NULL;
    
    // Single-pass rendering: diffuse texture and fullbright glow mask dispatched together
    GL_DrawAliasFrame_Metal(paliashdr, lerpdata, entityMVP, metalTex, glowTex);
}

#ifndef OFFSET_SHADOW
#define OFFSET_SHADOW 2
#endif

// Compute shadow model-to-world matrix using SIMD
static simd_float4x4 R_Metal_ComputeShadowModelMatrix(entity_t *e, aliashdr_t *paliashdr, lerpdata_t *lerpdata, float lheight)
{
    float scalefactor = ENTSCALE_DECODE(e->scale);
    
    simd_float4x4 sm = matrix_identity_float4x4;
    sm.columns[2] = (simd_float4){ SHADOW_SKEW_X, SHADOW_SKEW_Y, SHADOW_VSCALE, 0.0f };
    sm.columns[3] = (simd_float4){ 0.0f, 0.0f, SHADOW_HEIGHT, 1.0f };
    
    simd_float4x4 m = R_Metal_MatrixTranslation(lerpdata->origin[0], lerpdata->origin[1], lerpdata->origin[2]);
    m = simd_mul(m, R_Metal_MatrixTranslation(0.0f, 0.0f, -lheight));
    m = simd_mul(m, sm);
    m = simd_mul(m, R_Metal_MatrixTranslation(0.0f, 0.0f, lheight));
    m = simd_mul(m, R_Metal_MatrixRotateZ(lerpdata->angles[1]));
    m = simd_mul(m, R_Metal_MatrixRotateY(-lerpdata->angles[0]));
    m = simd_mul(m, R_Metal_MatrixRotateX(lerpdata->angles[2]));
    
    if (scalefactor != 1.0f) {
        m = simd_mul(m, R_Metal_MatrixScale(scalefactor, scalefactor, scalefactor));
    }
    
    m = simd_mul(m, R_Metal_MatrixTranslation(paliashdr->scale_origin[0], paliashdr->scale_origin[1], paliashdr->scale_origin[2]));
    m = simd_mul(m, R_Metal_MatrixScale(paliashdr->scale[0], paliashdr->scale[1], paliashdr->scale[2]));
    
    return m;
}

static MetalWorldVertex *s_shadowBatchPool = NULL;
static size_t s_shadowBatchPoolCap = 0;

static bool R_Alias_EnsureShadowPoolCapacity(size_t neededVerts)
{
    if (neededVerts > s_shadowBatchPoolCap) {
        size_t newCap = s_shadowBatchPoolCap ? s_shadowBatchPoolCap : 16384;
        while (newCap < neededVerts) newCap *= 2;
        free(s_shadowBatchPool);
        s_shadowBatchPool = (MetalWorldVertex *)malloc(newCap * sizeof(MetalWorldVertex));
        s_shadowBatchPoolCap = s_shadowBatchPool ? newCap : 0;
        if (!s_shadowBatchPool) return false;
    }
    return true;
}

// Unpack shadow mesh directly into world space coordinates
static uint32_t R_Alias_UnpackShadowMesh(aliashdr_t *paliashdr, lerpdata_t *lerpdata,
                                         simd_float4x4 shadowModelMat, float shadowAlpha,
                                         MetalWorldVertex *dstVerts, uint32_t maxVerts)
{
    trivertx_t *verts1, *verts2;
    int *commands;
    int count;
    float blend, iblend;
    qboolean lerping;
    
    if (lerpdata->pose1 != lerpdata->pose2)
    {
        lerping = true;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata->pose1 * paliashdr->poseverts;
        verts2 += lerpdata->pose2 * paliashdr->poseverts;
        blend   = lerpdata->blend;
        iblend  = 1.0f - blend;
    }
    else
    {
        lerping = false;
        verts1  = (trivertx_t *)((byte *)paliashdr + paliashdr->posedata);
        verts2  = verts1;
        verts1 += lerpdata->pose1 * paliashdr->poseverts;
        blend   = iblend = 0.0f;
    }
    
    commands = (int *)((byte *)paliashdr + paliashdr->commands);
    MetalWorldVertex tempVerts[ALIAS_MAX_TEMP_VERTS];
    uint32_t outCount = 0;
    
    const simd_float3 blend3  = (simd_float3){ blend, blend, blend };
    const simd_float3 iblend3 = (simd_float3){ iblend, iblend, iblend };
    const simd_float4 shadowColor = (simd_float4){ 0.0f, 0.0f, 0.0f, shadowAlpha };
    const simd_float3 defNormal = (simd_float3){ 0.0f, 0.0f, 1.0f };
    const simd_float4 defTangent = (simd_float4){ 1.0f, 0.0f, 0.0f, 1.0f };
    
    while (1)
    {
        count = *commands++;
        if (!count)
            break;
        
        qboolean isFan = (count < 0);
        int numVerts = isFan ? -count : count;
        if (numVerts > ALIAS_MAX_TEMP_VERTS)
        {
            commands += numVerts * 2;
            verts1 += numVerts;
            if (lerping) verts2 += numVerts;
            continue;
        }
        
        for (int j = 0; j < numVerts; j++)
        {
            commands += 2; // Skip texture s/t coordinates
            
            simd_float3 pos;
            if (lerping)
            {
                simd_float3 p1 = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                simd_float3 p2 = (simd_float3){ (float)verts2->v[0], (float)verts2->v[1], (float)verts2->v[2] };
                pos = p1 * iblend3 + p2 * blend3;
                verts1++;
                verts2++;
            }
            else
            {
                pos = (simd_float3){ (float)verts1->v[0], (float)verts1->v[1], (float)verts1->v[2] };
                verts1++;
            }
            
            // Transform shadow vertex to world space
            simd_float4 worldPos = simd_mul(shadowModelMat, (simd_float4){ pos.x, pos.y, pos.z, 1.0f });
            
            tempVerts[j].position      = (simd_float3){ worldPos.x, worldPos.y, worldPos.z };
            tempVerts[j].normal        = defNormal;
            tempVerts[j].tangent       = defTangent;
            tempVerts[j].texCoord      = (simd_float2){ 0.0f, 0.0f };
            tempVerts[j].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
            tempVerts[j].color         = shadowColor;
        }
        
        if (isFan)
        {
            for (int k = 1; k < numVerts - 1; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    dstVerts[outCount++] = tempVerts[0];
                    dstVerts[outCount++] = tempVerts[k];
                    dstVerts[outCount++] = tempVerts[k + 1];
                }
            }
        }
        else
        {
            for (int k = 0; k < numVerts - 2; k++)
            {
                if (outCount + 3 <= maxVerts)
                {
                    if (k & 1)
                    {
                        dstVerts[outCount++] = tempVerts[k + 1];
                        dstVerts[outCount++] = tempVerts[k];
                        dstVerts[outCount++] = tempVerts[k + 2];
                    }
                    else
                    {
                        dstVerts[outCount++] = tempVerts[k];
                        dstVerts[outCount++] = tempVerts[k + 1];
                        dstVerts[outCount++] = tempVerts[k + 2];
                    }
                }
            }
        }
    }
    
    return outCount;
}

/*
 =============
 R_DrawAliasShadows -- Batched alias shadows rendered in a single draw call
 =============
 */
void R_DrawAliasShadows (void)
{
    if (!r_shadows.value || !r_drawentities.value || cl_numvisedicts == 0)
        return;
    
    if (r_drawflat_cheatsafe || r_lightmap_cheatsafe)
        return;
    
    // 1. Precalculate required vertex capacity
    size_t totalMaxVerts = 0;
    for (int i = 0; i < cl_numvisedicts; i++)
    {
        entity_t *e = cl_visedicts[i];
        if (!e || !e->model || e->model->type != mod_alias)
            continue;
        if (e == &cl.viewent || (e->model->flags & MOD_NOSHADOW))
            continue;
        aliashdr_t *hdr = (aliashdr_t *)Mod_Extradata(e->model);
        if (hdr)
            totalMaxVerts += (size_t)hdr->numtris * 3;
    }
    
    if (totalMaxVerts == 0)
        return;
    
    if (!R_Alias_EnsureShadowPoolCapacity(totalMaxVerts))
        return;
    
    uint32_t totalVerts = 0;
    
    // 2. Batch and unpack meshes into a unified buffer
    for (int i = 0; i < cl_numvisedicts; i++)
    {
        entity_t *e = cl_visedicts[i];
        if (!e || !e->model || e->model->type != mod_alias)
            continue;
        
        if (e == &cl.viewent || (e->model->flags & MOD_NOSHADOW))
            continue;
        
        float alpha = ENTALPHA_DECODE(e->alpha);
        if (alpha <= 0.0f)
            continue;
        
        if (R_CullModelForEntity(e))
            continue;
        
        aliashdr_t *paliashdr = (aliashdr_t *)Mod_Extradata(e->model);
        if (!paliashdr)
            continue;
        
        // State requirement: set currententity before helper calls
        currententity = e;
        
        lerpdata_t lerpdata;
        R_SetupAliasFrame(paliashdr, e->frame, &lerpdata);
        R_SetupEntityTransform(e, &lerpdata);
        
        R_LightPoint(e->origin);
        float lheight = e->origin[2] - lightspot[2];
        if (lheight < -16.0f || lheight > 256.0f)
            continue;
        
        simd_float4x4 shadowModelMat = R_Metal_ComputeShadowModelMatrix(e, paliashdr, &lerpdata, lheight);
        uint32_t meshMax = (uint32_t)paliashdr->numtris * 3;
        
        uint32_t unpacked = R_Alias_UnpackShadowMesh(paliashdr, &lerpdata,
                                                     shadowModelMat, 0.5f * alpha,
                                                     s_shadowBatchPool + totalVerts, meshMax);
        totalVerts += unpacked;
    }
    
    // 3. Single batched draw call for all alias shadows in the frame
    if (totalVerts > 0)
    {
        R_Metal_SetPolygonOffset(OFFSET_SHADOW);
        // Tag "entity-shadow-batch" selects the shadow fragment pipeline instead of alias_fragment_main
        R_Metal_Draw3DPolygons(s_shadowBatchPool, totalVerts, g_metalWorldMVP,
                               NULL, NULL, METAL_BLEND_ALPHA, false, "entity-shadow-batch");
        R_Metal_SetPolygonOffset(0);
    }
}

// Backward compatibility stub
void GL_DrawAliasShadow (entity_t *e)
{
    (void)e;
}

/*
 =================
 R_DrawAliasModel_ShowTris -- Metal
 =================
 */
void R_DrawAliasModel_ShowTris (entity_t *e)
{
    aliashdr_t  *paliashdr;
    lerpdata_t  lerpdata;
    float       fovscale = 1.0f;
    
    if (R_CullModelForEntity(e))
        return;
    
    paliashdr = (aliashdr_t *)Mod_Extradata (e->model);
    R_SetupAliasFrame (paliashdr, e->frame, &lerpdata);
    R_SetupEntityTransform (e, &lerpdata);
    
    if (e == &cl.viewent && scr_fov.value > 90.f && cl_gun_fovscale.value)
        fovscale = tan(scr_fov.value * (0.5f * M_PI / 180.f));
    
    simd_float4x4 entityMVP = R_Metal_ComputeEntityMVP(e, paliashdr, &lerpdata, fovscale);
    
    shading = false;
    entalpha = 1.0f;
    GL_DrawAliasFrame_Metal (paliashdr, lerpdata, entityMVP, NULL, NULL);
}

/*
 =================
 R_DrawAliasEntitiesOnList -- Batch and render visible world alias models
 =================
 */
void R_DrawAliasEntitiesOnList (qboolean alphapass)
{
    if (!r_drawentities.value || cl_numvisedicts == 0)
        return;
    
    int numJobs = 0;
    size_t totalVertsNeeded = 0;
    
    // Phase 1: Collect alias rendering jobs on the main thread
    for (int i = 0; i < cl_numvisedicts; i++)
    {
        entity_t *e = cl_visedicts[i];
        if (!e || !e->model || e->model->type != mod_alias)
            continue;
        
        // Player viewmodel is rendered independently via R_DrawViewModel
        if (e == &cl.viewent)
            continue;
        
        float alpha = (r_drawflat_cheatsafe || r_lightmap_cheatsafe) ? 1.0f : ENTALPHA_DECODE(e->alpha);
        if (alpha <= 0.0f)
            continue;
        
        if ((alpha < 1.0f && !alphapass) || (alpha >= 1.0f && alphapass))
            continue;
        
        if (R_CullModelForEntity(e))
            continue;
        
        aliashdr_t *paliashdr = (aliashdr_t *)Mod_Extradata(e->model);
        if (!paliashdr)
            continue;
        
        currententity = e;
        lerpdata_t lerpdata;
        R_SetupAliasFrame(paliashdr, e->frame, &lerpdata);
        R_SetupEntityTransform(e, &lerpdata);
        
        overbright = !!gl_overbright_models.value;
        shading = true;
        entalpha = alpha;
        
        rs_aliaspolys += paliashdr->numtris;
        R_SetupAliasLighting(e);
        
        int anim = (int)(cl.time * 10) & 3;
        int skinnum = e->skinnum;
        if (skinnum >= paliashdr->numskins || skinnum < 0)
            skinnum = 0;
        
        gltexture_t *tx = paliashdr->gltextures[skinnum][anim];
        if (!tx) tx = paliashdr->gltextures[skinnum][0];
        
        gltexture_t *fb = paliashdr->fbtextures[skinnum][anim];
        if (!fb) fb = paliashdr->fbtextures[skinnum][0];
        
        if (e->colormap != vid.colormap && !gl_nocolors.value)
        {
            if ((uintptr_t)e >= (uintptr_t)&cl_entities[1] && (uintptr_t)e <= (uintptr_t)&cl_entities[cl.maxclients])
                tx = playertextures[e - cl_entities - 1];
        }
        if (!gl_fullbrights.value)
            fb = NULL;
        
        void *metalTex = (tx && tx->metalTexture) ? tx->metalTexture : NULL;
        simd_float4x4 entityMVP = R_Metal_ComputeEntityMVP(e, paliashdr, &lerpdata, 1.0f);
        uint32_t meshMax = (uint32_t)paliashdr->numtris * 3;
        
        // Base model pass with integrated fullbright glow mask
        if (numJobs < MQ_MAX_ALIAS_JOBS)
        {
            alias_job_t *job = &s_aliasJobs[numJobs++];
            job->paliashdr   = paliashdr;
            job->lerpdata    = lerpdata;
            job->entityMVP   = entityMVP;
            job->metalTex    = metalTex;
            job->glowTex     = (fb && fb->metalTexture) ? fb->metalTexture : NULL;
            job->baseLight   = (simd_float3){ lightcolor[0], lightcolor[1], lightcolor[2] };
            job->shadedots   = shadedots;
            job->entalpha    = alpha;
            job->shading     = true;
            job->blendMode   = (alpha < 1.0f) ? METAL_BLEND_ALPHA : METAL_BLEND_OPAQUE;
            job->tag         = "alias-batch-world";
            job->maxVerts    = meshMax;
            job->outCount    = 0;
            totalVertsNeeded += meshMax;
        }
    }
    
    if (numJobs == 0)
        return;
    
    if (!R_Alias_EnsurePoolCapacity(totalVertsNeeded))
        return;
    
    // Assign non-overlapping buffer slices to each job
    size_t vertOffset = 0;
    for (int i = 0; i < numJobs; i++)
    {
        s_aliasJobs[i].meshVerts = s_aliasParallelPool + vertOffset;
        vertOffset += s_aliasJobs[i].maxVerts;
    }
    
    // Phase 2: Unpack meshes. Use GCD parallel dispatch when job count >= 8 to avoid dispatch overhead on small batches
    if (numJobs >= 8)
    {
        dispatch_apply(numJobs, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t idx) {
            R_Alias_UnpackJob(&s_aliasJobs[idx]);
        });
    }
    else
    {
        for (int i = 0; i < numJobs; i++)
        {
            R_Alias_UnpackJob(&s_aliasJobs[i]);
        }
    }
    
    // Phase 3: Submit draw commands to the Metal command encoder
    for (int i = 0; i < numJobs; i++)
    {
        alias_job_t *job = &s_aliasJobs[i];
        if (job->outCount > 0)
        {
            R_Metal_Draw3DPolygons(job->meshVerts, job->outCount, job->entityMVP,
                                   job->metalTex, job->glowTex, job->blendMode, false, job->tag);
        }
        rs_aliaspasses += job->paliashdr->numtris;
    }
}
