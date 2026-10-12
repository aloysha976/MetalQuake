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
//r_sprite.c -- sprite model rendering

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"

// Sprite batching queue for accumulating quads prior to submission
#define MAX_QUEUED_SPRITES 512

typedef struct {
    void            *tex;
    MetalWorldVertex verts[6];
} queued_sprite_t;

static queued_sprite_t s_spriteQueue[MAX_QUEUED_SPRITES];
static int             s_numQueuedSprites = 0;

/*
 ================
 R_GetSpriteFrame
 ================
 */
mspriteframe_t *R_GetSpriteFrame (entity_t *currentent)
{
    msprite_t		*psprite;
    mspritegroup_t	*pspritegroup;
    mspriteframe_t	*pspriteframe;
    int				i, numframes, frame;
    float			*pintervals, fullinterval, targettime, time;
    
    psprite = (msprite_t *) currentent->model->cache.data;
    frame = currentent->frame;
    
    if ((frame >= psprite->numframes) || (frame < 0))
    {
        Con_DPrintf ("R_DrawSprite: no such frame %d for '%s'\n", frame, currentent->model->name);
        frame = 0;
    }
    
    if (psprite->frames[frame].type == SPR_SINGLE)
    {
        pspriteframe = psprite->frames[frame].frameptr;
    }
    else if (psprite->frames[frame].type == SPR_ANGLED)
    {
        // erysdren - angled sprites code backported from FTEQW
        vec3_t axis[3];
        AngleVectors(currentent->angles, axis[0], axis[1], axis[2]);
        {
            float f = DotProduct(vpn, axis[0]);
            float r = DotProduct(vright, axis[0]);
            int dir = (atan2(r, f)+1.125*M_PI)*(4/M_PI);
            pspritegroup = (mspritegroup_t *)psprite->frames[frame].frameptr;
            pspriteframe = pspritegroup->frames[dir&7];
        }
    }
    else
    {
        pspritegroup = (mspritegroup_t *)psprite->frames[frame].frameptr;
        pintervals = pspritegroup->intervals;
        numframes = pspritegroup->numframes;
        fullinterval = pintervals[numframes-1];
        
        time = cl.time + currentent->syncbase;
        
        // when loading in Mod_LoadSpriteGroup, we guaranteed all interval values
        // are positive, so we don't have to worry about division by 0
        targettime = time - ((int)(time / fullinterval)) * fullinterval;
        
        for (i = 0; i < (numframes-1); i++)
        {
            if (pintervals[i] > targettime)
                break;
        }
        
        pspriteframe = pspritegroup->frames[i];
    }
    
    return pspriteframe;
}

/*
 R_DrawSpriteModel -- johnfitz -- rewritten: now supports all orientations
 Billboard geometry generation for .spr files
 */
void R_DrawSpriteModel (entity_t *e)
{
    vec3_t            point, v_forward, v_right, v_up;
    vec3_t            p0, p1, p2, p3;
    msprite_t        *psprite;
    mspriteframe_t    *frame;
    float            *s_up, *s_right;
    float            angle, sr, cr;
    float            scale = ENTSCALE_DECODE(e->scale);
    
    frame = R_GetSpriteFrame (e);
    psprite = (msprite_t *) e->model->cache.data;
    
    switch(psprite->type)
    {
        case SPR_VP_PARALLEL_UPRIGHT: //faces view plane, up is towards the heavens
            v_up[0] = 0;
            v_up[1] = 0;
            v_up[2] = 1;
            CrossProduct(vpn, v_up, v_right);
            VectorNormalizeFast(v_right);
            s_up = v_up;
            s_right = v_right;
            break;
        case SPR_FACING_UPRIGHT: //faces camera origin, up is towards the heavens
            VectorSubtract(e->origin, r_origin, v_forward);
            v_forward[2] = 0;
            VectorNormalizeFast(v_forward);
            v_right[0] = v_forward[1];
            v_right[1] = -v_forward[0];
            v_right[2] = 0;
            v_up[0] = 0;
            v_up[1] = 0;
            v_up[2] = 1;
            s_up = v_up;
            s_right = v_right;
            break;
        case SPR_VP_PARALLEL: //faces view plane, up is towards the top of the screen
            s_up = vup;
            s_right = vright;
            break;
        case SPR_ORIENTED: //pitch yaw roll are independent of camera
            AngleVectors (e->angles, v_forward, v_right, v_up);
            s_up = v_up;
            s_right = v_right;
            break;
        case SPR_VP_PARALLEL_ORIENTED: //faces view plane, but obeys roll value
            angle = e->angles[ROLL] * M_PI_DIV_180;
            sr = sin(angle);
            cr = cos(angle);
            v_right[0] = vright[0] * cr + vup[0] * sr;
            v_right[1] = vright[1] * cr + vup[1] * sr;
            v_right[2] = vright[2] * cr + vup[2] * sr;
            v_up[0] = vright[0] * -sr + vup[0] * cr;
            v_up[1] = vright[1] * -sr + vup[1] * cr;
            v_up[2] = vright[2] * -sr + vup[2] * cr;
            s_up = v_up;
            s_right = v_right;
            break;
        default:
            return;
    }
    
    // Depth offset for wall-mounted decals (impact marks, stains) to prevent Z-fighting with BSP surfaces
    if (psprite->type == SPR_ORIENTED)
        R_Metal_SetPolygonOffset (OFFSET_DECAL);
    
    // Quad vertices in world coordinates
    VectorMA (e->origin, frame->down * scale, s_up, point);
    VectorMA (point, frame->left * scale, s_right, p0);
    VectorMA (e->origin, frame->up * scale, s_up, point);
    VectorMA (point, frame->left * scale, s_right, p1);
    VectorMA (e->origin, frame->up * scale, s_up, point);
    VectorMA (point, frame->right * scale, s_right, p2);
    VectorMA (e->origin, frame->down * scale, s_up, point);
    VectorMA (point, frame->right * scale, s_right, p3);
    
    extern simd_float4x4 g_metalWorldMVP;
    
    // Assemble 2 triangles with valid tangent frame vectors
    MetalWorldVertex verts[6];
    const simd_float4 color = (simd_float4){ 1.0f, 1.0f, 1.0f, 1.0f };
    const simd_float3 defNormal = (simd_float3){ 0.0f, 0.0f, 1.0f };
    const simd_float4 defTangent = (simd_float4){ 1.0f, 0.0f, 0.0f, 1.0f };
    
    verts[0].position      = (simd_float3){ p0[0], p0[1], p0[2] };
    verts[0].normal        = defNormal;
    verts[0].tangent       = defTangent;
    verts[0].texCoord      = (simd_float2){ 0.0f, frame->tmax };
    verts[0].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
    verts[0].color         = color;
    
    verts[1].position      = (simd_float3){ p1[0], p1[1], p1[2] };
    verts[1].normal        = defNormal;
    verts[1].tangent       = defTangent;
    verts[1].texCoord      = (simd_float2){ 0.0f, 0.0f };
    verts[1].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
    verts[1].color         = color;
    
    verts[2].position      = (simd_float3){ p2[0], p2[1], p2[2] };
    verts[2].normal        = defNormal;
    verts[2].tangent       = defTangent;
    verts[2].texCoord      = (simd_float2){ frame->smax, 0.0f };
    verts[2].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
    verts[2].color         = color;
    
    verts[3] = verts[0];
    verts[4] = verts[2];
    
    verts[5].position      = (simd_float3){ p3[0], p3[1], p3[2] };
    verts[5].normal        = defNormal;
    verts[5].tangent       = defTangent;
    verts[5].texCoord      = (simd_float2){ frame->smax, frame->tmax };
    verts[5].lightmapCoord = (simd_float2){ 0.0f, 0.0f };
    verts[5].color         = color;
    
    void *texHandle = (frame->gltexture && frame->gltexture->metalTexture) ? frame->gltexture->metalTexture : NULL;
    if (!texHandle && notexture) {
        texHandle = notexture->metalTexture;
    }
    
    // Sprite diagnostics: name, texture handle, quad bounds
    if (MLog_Budget("ENG·SPRITE", 30)) {
        float size = (frame->up - frame->down) * scale;
        MLog(MQ_LVL_DEV, "ENG·SPRITE", "'%s' tex=%p size=%.1f org=(%.0f %.0f %.0f)",
             e->model->name, texHandle, size,
             e->origin[0], e->origin[1], e->origin[2]);
    }
    
    // Decals are rendered individually with custom depth offset
    if (psprite->type == SPR_ORIENTED)
    {
        R_Metal_Draw3DPolygons(verts, 6, g_metalWorldMVP, texHandle, NULL, METAL_BLEND_ALPHA, false, "sprite-oriented");
        R_Metal_SetPolygonOffset (0);
        return;
    }
    
    // Enqueue standard billboard sprites for batching
    if (s_numQueuedSprites < MAX_QUEUED_SPRITES)
    {
        queued_sprite_t *q = &s_spriteQueue[s_numQueuedSprites++];
        q->tex = texHandle;
        memcpy(q->verts, verts, sizeof(verts));
    }
    else
    {
        // Flush queue on buffer saturation
        R_Sprite_Flush();
        queued_sprite_t *q = &s_spriteQueue[s_numQueuedSprites++];
        q->tex = texHandle;
        memcpy(q->verts, verts, sizeof(verts));
    }
}

/*
 ================
 R_Sprite_Flush -- Group quads by texture and submit batched draws to Metal
 ================
 */
void R_Sprite_Flush (void)
{
    if (s_numQueuedSprites == 0)
        return;
    
    extern simd_float4x4 g_metalWorldMVP;
    static MetalWorldVertex s_batchVerts[MAX_QUEUED_SPRITES * 6];
    
    // Group quads by unique texture to minimize draw calls
    for (int i = 0; i < s_numQueuedSprites; i++)
    {
        void *curTex = s_spriteQueue[i].tex;
        if (!curTex)
            continue; // Quad was already processed in a previous pass
        
        uint32_t batchVertCount = 0;
        for (int j = i; j < s_numQueuedSprites; j++)
        {
            if (s_spriteQueue[j].tex == curTex)
            {
                memcpy(&s_batchVerts[batchVertCount], s_spriteQueue[j].verts, sizeof(s_spriteQueue[j].verts));
                batchVertCount += 6;
                s_spriteQueue[j].tex = NULL; // Mark as consumed
            }
        }
        
        if (batchVertCount > 0)
        {
            R_Metal_Draw3DPolygons(s_batchVerts, batchVertCount, g_metalWorldMVP,
                                   curTex, NULL, METAL_BLEND_ALPHA, false, "sprite-batch");
        }
    }
    
    s_numQueuedSprites = 0;
}
