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
#define MAX_SPRITE_TEXTURES 16

static MetalWorldVertex s_spriteQueueVerts[MAX_QUEUED_SPRITES * 6];
static int             s_numQueuedSpriteVerts = 0;

static void           *s_registeredSpriteTextures[MAX_SPRITE_TEXTURES];
static uint32_t        s_numRegisteredSpriteTextures = 0;

static uint32_t R_Sprite_RegisterTexture(void *texHandle)
{
    if (!texHandle)
        return 0;
    
    for (uint32_t i = 0; i < s_numRegisteredSpriteTextures; i++) {
        if (s_registeredSpriteTextures[i] == texHandle)
            return i;
    }
    
    // Если 16 слотов исчерпаны — сбрасываем текущий батч
    if (s_numRegisteredSpriteTextures >= MAX_SPRITE_TEXTURES) {
        R_Sprite_Flush();
    }
    
    uint32_t slot = s_numRegisteredSpriteTextures++;
    s_registeredSpriteTextures[slot] = texHandle;
    return slot;
}

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
    
    // Проверяем заполнение очереди вершин
    if (s_numQueuedSpriteVerts + 6 > MAX_QUEUED_SPRITES * 6) {
        R_Sprite_Flush();
    }
    
    // Регистрируем текстуру в текущем батче и записываем индекс слота в lightmapCoord.x
    float slotIdx = (float)R_Sprite_RegisterTexture(texHandle);
    for (int v = 0; v < 6; v++) {
        verts[v].lightmapCoord.x = slotIdx;
    }
    
    memcpy(&s_spriteQueueVerts[s_numQueuedSpriteVerts], verts, sizeof(verts));
    s_numQueuedSpriteVerts += 6;
}

/*
 ================
 R_Sprite_Flush -- Submit all queued billboard sprites in a single draw call
 ================
 */
void R_Sprite_Flush (void)
{
    if (s_numQueuedSpriteVerts == 0 || s_numRegisteredSpriteTextures == 0) {
        s_numQueuedSpriteVerts = 0;
        s_numRegisteredSpriteTextures = 0;
        return;
    }
    
    extern simd_float4x4 g_metalWorldMVP;
    
    R_Metal_DrawSpriteBatch(s_spriteQueueVerts, (uint32_t)s_numQueuedSpriteVerts,
                            g_metalWorldMVP,
                            s_registeredSpriteTextures, s_numRegisteredSpriteTextures);
    
    s_numQueuedSpriteVerts = 0;
    s_numRegisteredSpriteTextures = 0;
}
