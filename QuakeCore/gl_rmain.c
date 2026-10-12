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
// r_main.c

#define GL_SILENCE_DEPRECATION 1

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"

// Global model-view-projection matrix and time tracker for active 3D frame
simd_float4x4 g_metalWorldMVP;
float g_metalTime = 0.0f;

vec3_t        modelorg, r_entorigin;
entity_t    *currententity;

int            r_visframecount;    // Incremented upon entering a new PVS leaf
int            r_framecount;        // Monotonic frame counter used for dynamic light push validation

mplane_t    frustum[4];

//johnfitz -- rendering statistics
int rs_brushpolys, rs_aliaspolys, rs_skypolys;
int rs_dynamiclightmaps, rs_brushpasses, rs_aliaspasses, rs_skypasses;

//
// View origin and coordinate frame
//
vec3_t    vup;
vec3_t    vpn;
vec3_t    vright;
vec3_t    r_origin;

float r_fovx, r_fovy; //johnfitz -- rendering fov may deviate due to water warping and stereo skew

//
// Viewport configuration
//
refdef_t    r_refdef;

mleaf_t        *r_viewleaf, *r_oldviewleaf;

int        d_lightstylevalue[256];    // 8.8 fixed-point fraction of base light intensity


cvar_t    r_norefresh = {"r_norefresh","0",CVAR_NONE};
cvar_t    r_drawentities = {"r_drawentities","1",CVAR_NONE};
cvar_t    r_drawviewmodel = {"r_drawviewmodel","1",CVAR_NONE};
cvar_t    r_speeds = {"r_speeds","0",CVAR_NONE};
cvar_t    r_pos = {"r_pos","0",CVAR_NONE};
cvar_t    r_fullbright = {"r_fullbright","0",CVAR_NONE};
cvar_t    r_lightmap = {"r_lightmap","0",CVAR_NONE};
cvar_t    r_shadows = {"r_shadows","0",CVAR_ARCHIVE};
cvar_t    r_wateralpha = {"r_wateralpha","0.8",CVAR_ARCHIVE}; // Translucent water surface alpha
cvar_t    r_litwater = {"r_litwater","1",CVAR_NONE};
cvar_t    r_dynamic = {"r_dynamic","1",CVAR_ARCHIVE};
cvar_t    r_novis = {"r_novis","0",CVAR_ARCHIVE};

// Dynamic point lights: evaluated per-pixel in world fragment shader (1) vs legacy lightmap modification (0)
cvar_t    r_perpixel_dlights = {"r_perpixel_dlights","1",CVAR_ARCHIVE};

cvar_t    gl_finish = {"gl_finish","0",CVAR_NONE};
cvar_t    gl_clear = {"gl_clear","1",CVAR_NONE};
cvar_t    gl_cull = {"gl_cull","1",CVAR_NONE};
cvar_t    gl_smoothmodels = {"gl_smoothmodels","1",CVAR_NONE};
cvar_t    gl_affinemodels = {"gl_affinemodels","0",CVAR_NONE};
cvar_t    gl_polyblend = {"gl_polyblend","1",CVAR_NONE};
cvar_t    gl_flashblend = {"gl_flashblend","0",CVAR_ARCHIVE};
cvar_t    gl_playermip = {"gl_playermip","0",CVAR_NONE};
cvar_t    gl_nocolors = {"gl_nocolors","0",CVAR_NONE};

//johnfitz -- modern extensions
cvar_t    r_stereo = {"r_stereo","0",CVAR_NONE};
cvar_t    r_stereodepth = {"r_stereodepth","128",CVAR_NONE};
cvar_t    r_clearcolor = {"r_clearcolor","2",CVAR_ARCHIVE};
cvar_t    r_drawflat = {"r_drawflat","0",CVAR_NONE};
cvar_t    r_flatlightstyles = {"r_flatlightstyles", "0", CVAR_NONE};
cvar_t    gl_fullbrights = {"gl_fullbrights", "1", CVAR_ARCHIVE};
cvar_t    gl_farclip = {"gl_farclip", "65536", CVAR_ARCHIVE};
cvar_t    gl_overbright = {"gl_overbright", "1", CVAR_ARCHIVE};
cvar_t    gl_overbright_models = {"gl_overbright_models", "1", CVAR_ARCHIVE};
cvar_t    r_oldskyleaf = {"r_oldskyleaf", "0", CVAR_NONE};
cvar_t    r_drawworld = {"r_drawworld", "1", CVAR_NONE};
cvar_t    r_showtris = {"r_showtris", "0", CVAR_NONE};
cvar_t    r_showbboxes = {"r_showbboxes", "0", CVAR_NONE};
cvar_t    r_lerpmodels = {"r_lerpmodels", "1", CVAR_NONE};
cvar_t    r_lerpmove = {"r_lerpmove", "1", CVAR_NONE};
cvar_t    r_interpolate = {"r_interpolate", "1", CVAR_NONE}; // Fixed-timestep render state interpolation

// HDR & EDR rendering pipeline
cvar_t    r_hdr       = {"r_hdr", "1", CVAR_ARCHIVE};   // RGBA16Float offscreen render target and tonemapping
cvar_t    r_edr_force = {"r_edr_force", "-1", CVAR_NONE}; // EDR headroom mode: -1 auto, 0 off, 1 forced
cvar_t    r_edr_boost = {"r_edr_boost", "0.6", CVAR_NONE};  // Specular and bright-pass EDR headroom scalar
cvar_t    r_hdr_exposure = {"r_hdr_exposure", "1.3", CVAR_NONE}; // Tonemapper exposure scale

// Bloom filter chain (requires r_hdr 1)
cvar_t    r_bloom           = {"r_bloom", "0", CVAR_ARCHIVE};    // Optical glow on bright surfaces
cvar_t    r_bloom_intensity = {"r_bloom_intensity", "0.45", CVAR_NONE};
cvar_t    r_bloom_threshold = {"r_bloom_threshold", "1.0", CVAR_NONE};

// MetalFX upscaling runtime control
cvar_t    metalfx_mode  = {"metalfx_mode", "0", CVAR_ARCHIVE};   // Upscaler mode: 0 off, 1 spatial, 2 temporal
cvar_t    metalfx_scale = {"metalfx_scale", "0.75", CVAR_ARCHIVE}; // Internal rendering resolution scale factor
cvar_t    r_nolerp_list = {"r_nolerp_list", "progs/flame.mdl,progs/flame2.mdl,progs/braztall.mdl,progs/brazshrt.mdl,progs/longtrch.mdl,progs/flame_pyre.mdl,progs/v_saw.mdl,progs/v_xfist.mdl,progs/h2stuff/newfire.mdl", CVAR_NONE};
cvar_t    r_noshadow_list = {"r_noshadow_list", "progs/flame2.mdl,progs/flame.mdl,progs/bolt1.mdl,progs/bolt2.mdl,progs/bolt3.mdl,progs/laser.mdl", CVAR_NONE};

extern cvar_t    r_vfog;
//johnfitz

cvar_t    gl_zfix = {"gl_zfix", "0", CVAR_NONE}; // QuakeSpasm coplanar z-fighting mitigation

// Lava and slime liquid opacity (configured to full opacity independent of r_wateralpha)
cvar_t    r_lavaalpha = {"r_lavaalpha","1.0",CVAR_ARCHIVE};
cvar_t    r_telealpha = {"r_telealpha","1.0",CVAR_ARCHIVE};
cvar_t    r_slimealpha = {"r_slimealpha","1.0",CVAR_ARCHIVE};

float    map_wateralpha, map_lavaalpha, map_telealpha, map_slimealpha;

qboolean r_drawflat_cheatsafe, r_fullbright_cheatsafe, r_lightmap_cheatsafe, r_drawworld_cheatsafe; //johnfitz

cvar_t    r_scale = {"r_scale", "1", CVAR_ARCHIVE};

//==============================================================================
//
// GLSL GAMMA CORRECTION
//
//==============================================================================

void GLSLGamma_DeleteTexture (void)
{
    // Legacy OpenGL gamma texture omitted; tonemapping and color grading managed in Metal post-process
}

void GLSLGamma_GammaCorrect (void)
{
    // Fullscreen gamma readback and copy pass omitted.
    // Gamma correction, contrast, exposure, HDR and EDR scaling are evaluated in Metal post-processing shaders.
}

/*
 =================
 R_CullBox -- johnfitz -- replaced with new function from lordhavoc
 
 Returns true if the bounding box is completely outside the frustum
 =================
 */
qboolean R_CullBox (vec3_t emins, vec3_t emaxs)
{
    int i;
    mplane_t *p;
    byte signbits;
    float vec[3];
    
    for (i = 0; i < 4; i++)
    {
        p = frustum + i;
        signbits = p->signbits;
        vec[0] = ((signbits & 1) ? emins : emaxs)[0];
        vec[1] = ((signbits & 2) ? emins : emaxs)[1];
        vec[2] = ((signbits & 4) ? emins : emaxs)[2];
        if (p->normal[0]*vec[0] + p->normal[1]*vec[1] + p->normal[2]*vec[2] < p->dist)
            return true;
    }
    return false;
}

/*
 ===============
 R_CullModelForEntity -- johnfitz -- uses correct bounds based on rotation
 ===============
 */
qboolean R_CullModelForEntity (entity_t *e)
{
    vec3_t mins, maxs;
    vec_t scalefactor, *minbounds, *maxbounds;
    
    if (e->angles[0] || e->angles[2]) // Pitch or roll
    {
        minbounds = e->model->rmins;
        maxbounds = e->model->rmaxs;
    }
    else if (e->angles[1]) // Yaw
    {
        minbounds = e->model->ymins;
        maxbounds = e->model->ymaxs;
    }
    else // No rotation
    {
        minbounds = e->model->mins;
        maxbounds = e->model->maxs;
    }
    
    scalefactor = ENTSCALE_DECODE(e->scale);
    if (scalefactor != 1.0f)
    {
        VectorMA (e->origin, scalefactor, minbounds, mins);
        VectorMA (e->origin, scalefactor, maxbounds, maxs);
    }
    else
    {
        VectorAdd (e->origin, minbounds, mins);
        VectorAdd (e->origin, maxbounds, maxs);
    }
    
    return R_CullBox (mins, maxs);
}

/*
 ===============
 R_RotateForEntity
 ===============
 */
void R_RotateForEntity (vec3_t origin, vec3_t angles, unsigned char scale)
{
    // Fixed-function matrix stack manipulations omitted.
    // Model and entity transformations are evaluated via SIMD simd_float4x4 structures in model rendering passes.
    (void)origin;
    (void)angles;
    (void)scale;
}

/*
 =============
 GL_PolygonOffset -- johnfitz
 
 Negative offset bias shifts polygon depth towards camera
 =============
 */
void GL_PolygonOffset (int offset)
{
    // Translates to pipeline depth bias in Metal rasterizer
    R_Metal_SetPolygonOffset (offset);
}

//==============================================================================
//
// SETUP FRAME
//
//==============================================================================

int SignbitsForPlane (mplane_t *out)
{
    int    bits, j;
    
    // Fast box-plane classification bitmask
    bits = 0;
    for (j=0 ; j<3 ; j++)
    {
        if (out->normal[j] < 0)
            bits |= 1<<j;
    }
    return bits;
}

/*
 ===============
 TurnVector -- johnfitz
 
 Rotates forward vector toward side axis on the shared plane.
 When angle = 90, result matches side vector.
 Assumes orthogonal, normalized input vectors.
 ===============
 */
void TurnVector (vec3_t out, const vec3_t forward, const vec3_t side, float angle)
{
    float scale_forward, scale_side;
    
    scale_forward = cos( DEG2RAD( angle ) );
    scale_side = sin( DEG2RAD( angle ) );
    
    out[0] = scale_forward*forward[0] + scale_side*side[0];
    out[1] = scale_forward*forward[1] + scale_side*side[1];
    out[2] = scale_forward*forward[2] + scale_side*side[2];
}

/*
 ===============
 R_SetFrustum -- johnfitz -- rewritten
 ===============
 */
void R_SetFrustum (float fovx, float fovy)
{
    int        i;
    
    if (r_stereo.value)
        fovx += 10; // Expand horizontal FOV slightly to mitigate stereo culling skew
    
    TurnVector(frustum[0].normal, vpn, vright, fovx/2 - 90); // Left clipping plane
    TurnVector(frustum[1].normal, vpn, vright, 90 - fovx/2); // Right clipping plane
    TurnVector(frustum[2].normal, vpn, vup, 90 - fovy/2);   // Bottom clipping plane
    TurnVector(frustum[3].normal, vpn, vup, fovy/2 - 90);   // Top clipping plane
    
    for (i=0 ; i<4 ; i++)
    {
        frustum[i].type = PLANE_ANYZ;
        frustum[i].dist = DotProduct (r_origin, frustum[i].normal);
        frustum[i].signbits = SignbitsForPlane (&frustum[i]);
    }
}

#define NEARCLIP 4
float frustum_skew = 0.0;

/*
 =============
 GL_SetFrustum / R_SetupGL / R_Clear
 =============
 */
void GL_SetFrustum (float fovx, float fovy)
{
    // Legacy fixed-function frustum setup omitted
    (void)fovx;
    (void)fovy;
}

void R_SetupGL (void)
{
    // Viewport and projection transforms are dispatched directly via R_Metal_ComputeMVP()
}

void R_Clear (void)
{
    // Clear operations handled implicitly via MTLLoadActionClear on the primary render pass descriptor
}

/*
 ===============
 R_SetupScene -- johnfitz -- per-eye initialization in stereo mode
 ===============
 */
void R_SetupScene (void)
{
    R_SetupGL ();
}

/*
 ===============
 R_GatherPerPixelDlights
 
 Gathers active dynamic lights into a GPU uniform buffer (up to 32 emitters).
 When budget is exceeded, nearest lights to the camera are prioritized.
 Positions match engine coordinates directly without axis remapping.
 ===============
 */
#define MQ_MAX_GPU_DLIGHTS    32

void R_GatherPerPixelDlights (void)
{
    float    packed[MQ_MAX_GPU_DLIGHTS * 8];
    float    dist2[MQ_MAX_GPU_DLIGHTS];
    int    count = 0;
    int    i, j;
    
    if (!r_perpixel_dlights.value)
    {
        R_Metal_SetFrameDlights (NULL, 0);
        return;
    }
    
    byte *view_pvs = (r_viewleaf && cl.worldmodel) ? Mod_LeafPVS (r_viewleaf, cl.worldmodel) : NULL;
    
    for (i = 0; i < MAX_DLIGHTS; i++)
    {
        dlight_t    *l = &cl_dlights[i];
        float        dx, dy, dz, d2;
        
        if (l->die < cl.time || l->radius <= 0)
            continue;
        
        // PVS visibility check: cull lights located in unvisited leaves
        if (view_pvs && cl.worldmodel && cl.worldmodel->leafs)
        {
            mleaf_t *dleaf = Mod_PointInLeaf (l->origin, cl.worldmodel);
            if (dleaf)
            {
                int leafnum = (int)(dleaf - cl.worldmodel->leafs - 1);
                if (leafnum >= 0 && !(view_pvs[leafnum >> 3] & (1 << (leafnum & 7))))
                    continue;
            }
        }
        
        // Frustum culling against bounding sphere of light emitter
        vec3_t lmins, lmaxs;
        lmins[0] = l->origin[0] - l->radius;
        lmins[1] = l->origin[1] - l->radius;
        lmins[2] = l->origin[2] - l->radius;
        lmaxs[0] = l->origin[0] + l->radius;
        lmaxs[1] = l->origin[1] + l->radius;
        lmaxs[2] = l->origin[2] + l->radius;
        if (R_CullBox (lmins, lmaxs))
            continue;
        
        dx = l->origin[0] - r_origin[0];
        dy = l->origin[1] - r_origin[1];
        dz = l->origin[2] - r_origin[2];
        d2 = dx*dx + dy*dy + dz*dz;
        
        if (count < MQ_MAX_GPU_DLIGHTS)
        {
            // Sorted insertion by squared distance
            for (j = count; j > 0 && dist2[j-1] > d2; j--)
            {
                dist2[j] = dist2[j-1];
                memcpy (&packed[j*8], &packed[(j-1)*8], 8 * sizeof(float));
            }
        }
        else
        {
            if (d2 >= dist2[MQ_MAX_GPU_DLIGHTS-1])
                continue; // Exceeds distance of all currently tracked emitters
            // Evict farthest light emitter in the tail slot
            for (j = MQ_MAX_GPU_DLIGHTS-1; j > 0 && dist2[j-1] > d2; j--)
            {
                dist2[j] = dist2[j-1];
                memcpy (&packed[j*8], &packed[(j-1)*8], 8 * sizeof(float));
            }
            count = MQ_MAX_GPU_DLIGHTS;
        }
        
        packed[j*8+0] = l->origin[0];
        packed[j*8+1] = l->origin[1];
        packed[j*8+2] = l->origin[2];
        packed[j*8+3] = l->radius;
        packed[j*8+4] = l->color[0];
        packed[j*8+5] = l->color[1];
        packed[j*8+6] = l->color[2];
        packed[j*8+7] = 0.0f;
        dist2[j] = d2;
        count++;
    }
    
    R_Metal_SetFrameDlights (packed, count);
    
    if (count > 0 && MLog_Budget("DLT·GPU", 8))
        MLog(MQ_LVL_DEV, "DLT·GPU",
             "per-pixel lights=%d nearest=%.0f", count, sqrt(dist2[0]));
}

/*
 ===============
 R_SetupView -- johnfitz -- per-frame setup evaluated prior to stereo rendering
 ===============
 */
void R_SetupView (void)
{
    static qboolean s_flatStylesRegistered = false;
    if (!s_flatStylesRegistered)
    {
        Cvar_RegisterVariable (&r_flatlightstyles);
        s_flatStylesRegistered = true;
    }
    
    // When per-pixel dynamic lights are active, legacy CPU lightmap marking passes are bypassed
    if (!r_perpixel_dlights.value)
        R_PushDlights ();
    
    R_AnimateLight ();
    r_framecount++;
    
    Fog_SetupFrame (); //johnfitz
    
    // Construct orientation vectors from active view angles
    VectorCopy (r_refdef.vieworg, r_origin);
    AngleVectors (r_refdef.viewangles, vpn, vright, vup);
    
    // Volumetric fog parameters and camera origin for world_fragment_main
    R_Metal_SetFogState (Fog_GetColor()[0], Fog_GetColor()[1], Fog_GetColor()[2],
                         Fog_GetDensity() / 64.0f, r_origin[0], r_origin[1], r_origin[2]);
    
    // Populate active dynamic light uniforms for per-pixel shader evaluation
    R_GatherPerPixelDlights ();
    
    // Update leaf visibility
    r_oldviewleaf = r_viewleaf;
    r_viewleaf = Mod_PointInLeaf (r_origin, cl.worldmodel);
    
    V_SetContentsColor (r_viewleaf->contents);
    V_CalcBlend ();
    
    //johnfitz -- compute r_fovx and r_fovy
    r_fovx = r_refdef.fov_x;
    r_fovy = r_refdef.fov_y;
    if (r_waterwarp.value)
    {
        int contents = Mod_PointInLeaf (r_origin, cl.worldmodel)->contents;
        if (contents == CONTENTS_WATER || contents == CONTENTS_SLIME || contents == CONTENTS_LAVA)
        {
            r_fovx = atan(tan(DEG2RAD(r_refdef.fov_x) / 2) * (0.97 + sin(cl.time * 1.5) * 0.03)) * 2 / M_PI_DIV_180;
            r_fovy = atan(tan(DEG2RAD(r_refdef.fov_y) / 2) * (1.03 - sin(cl.time * 1.5) * 0.03)) * 2 / M_PI_DIV_180;
        }
    }
    //johnfitz
    
    R_SetFrustum (r_fovx, r_fovy); //johnfitz -- configure frustum planes
    
    R_MarkSurfaces (); //johnfitz -- construct PVS texture chains
    
    R_UpdateWarpTextures (); //johnfitz -- generate procedural liquid surfaces prior to clear
    
    R_Clear ();
    
    //johnfitz -- cheat-protect draw modes
    r_drawflat_cheatsafe = r_fullbright_cheatsafe = r_lightmap_cheatsafe = false;
    r_drawworld_cheatsafe = true;
}

//==============================================================================
//
// RENDER VIEW
//
//==============================================================================

/*
 =============
 R_InterpolateEntity
 
 Smoothly interpolates an entity between its previous and current simulation ticks
 when the display refresh rate exceeds sv_tickrate.
 Recomputed from immutable tick snapshots; safe for repeated per-frame invocation.
 =============
 */
static void R_InterpolateEntity (entity_t *e)
{
    float    s, d;
    vec3_t    delta;
    int    j;
    
    if (!e->interp_valid || g_interpAlpha <= 0)
        return;
    
    s = g_interpAlpha;
    
    VectorSubtract (e->cur_origin, e->prev_origin, delta);
    if (DotProduct(delta,delta) > 100*100)
        return; // Displacement exceeds threshold; treat as teleportation rather than locomotion
    
    VectorMA (e->prev_origin, s, delta, e->origin);
    
    for (j=0 ; j<3 ; j++)
    {
        d = e->cur_angles[j] - e->prev_angles[j];
        if (d > 180)
            d -= 360;
        else if (d < -180)
            d += 360;
        e->angles[j] = e->prev_angles[j] + s*d;
    }
}

/*
 =============
 R_ApplyRenderInterpolation
 
 Invoked once per rendered frame prior to camera view setup and geometry dispatch.
 Interpolates player origin and orientation to stabilize camera movement.
 =============
 */
void R_ApplyRenderInterpolation (void)
{
    int    i;
    
    if (!r_interpolate.value)
        return;
    
    R_InterpolateEntity (&cl_entities[cl.viewentity]);
    for (i=0 ; i<cl_numvisedicts ; i++)
        R_InterpolateEntity (cl_visedicts[i]);
}

extern void R_DrawAliasEntitiesOnList (qboolean alphapass);

/*
 ============
 R_DrawEntitiesOnList
 ============
 */
void R_DrawEntitiesOnList (qboolean alphapass)
{
    int        i;
    
    if (!r_drawentities.value)
        return;
    
    // 1. Batched processing for alias mesh entities (monsters, items, projectiles)
    R_DrawAliasEntitiesOnList (alphapass);
    
    // 2. Brush submodels (doors, buttons, lifts) and sprite entities
    for (i=0 ; i<cl_numvisedicts ; i++)
    {
        currententity = cl_visedicts[i];
        
        if ((ENTALPHA_DECODE(currententity->alpha) < 1 && !alphapass) ||
            (ENTALPHA_DECODE(currententity->alpha) == 1 && alphapass))
            continue;
        
        if (currententity == &cl_entities[cl.viewentity])
            currententity->angles[0] *= 0.3;
        
        switch (currententity->model->type)
        {
            case mod_brush:
                R_DrawBrushModel (currententity);
                break;
            case mod_sprite:
                R_DrawSpriteModel (currententity);
                break;
            default:
                break;
        }
    }
    
    // Flush accumulated world billboard sprites
    R_Sprite_Flush ();
}

/*
 =============
 R_DrawViewModel -- johnfitz
 =============
 */
void R_DrawViewModel (void)
{
    if (!r_drawviewmodel.value || !r_drawentities.value || chase_active.value)
        return;
    
    if (cl.items & IT_INVISIBILITY || cl.stats[STAT_HEALTH] <= 0)
        return;
    
    currententity = &cl.viewent;
    if (!currententity->model || currententity->model->type != mod_alias)
        return;
    
    // Gun depth range prevents viewmodel from clipping through world geometry
    R_Metal_SetGunDepthRange(true);
    R_DrawAliasModel (currententity);
    R_Metal_SetGunDepthRange(false);
}

/*
 ==============================================================================
 
 DEBUG OVERLAYS (ShowTris, BBoxes)
 
 ==============================================================================
 */

void R_EmitWirePoint (vec3_t origin)
{
    (void)origin;
}

void R_EmitWireBox (vec3_t mins, vec3_t maxs)
{
    (void)mins;
    (void)maxs;
}

void R_ShowBoundingBoxes (void)
{
}

void R_ShowTris (void)
{
}

/*
 ================
 R_DrawShadows -- Batched alias entity shadow projection pass
 ================
 */
extern void R_DrawAliasShadows (void);

void R_DrawShadows (void)
{
    R_DrawAliasShadows ();
}

/*
 ================
 R_RenderScene
 ================
 */
void R_RenderScene (void)
{
    R_SetupScene ();
    
    // 1. Sky surfaces
    Sky_DrawSky ();
    
    // 2. Opaque world geometry and models
    R_DrawWorld ();
    R_DrawEntitiesOnList (false);
    
    // 3. Entity projection shadows (rendered over opaque surfaces when r_shadows is enabled)
    R_DrawShadows ();
    
    // 4. Liquid surfaces and translucent entities
    R_DrawWorld_Water ();
    R_DrawEntitiesOnList (true);
    
    // 5. Active player weapon viewmodel
    R_DrawViewModel ();
    
    // 6. Instanced particle systems
    R_DrawParticles ();
    
    // 7. Wireframe debug overlays (when enabled)
    R_ShowTris ();
}

/*
 =============
 R_ScaleView
 =============
 */
void R_ScaleView_DeleteTexture (void)
{
    // Legacy software scale texture omitted
}

void R_ScaleView (void)
{
    // Software blit scaling omitted; resolution scaling handled via MetalFX spatial/temporal pipelines
}

/*
 ================
 R_RenderView
 ================
 */
void R_RenderView (void)
{
    double    time1, time2;
    
    if (r_norefresh.value)
        return;
    
    if (!cl.worldmodel)
        Sys_Error ("R_RenderView: NULL worldmodel");
    
    time1 = 0;
    if (r_speeds.value)
    {
        glFinish ();
        time1 = Sys_DoubleTime ();
        
        //johnfitz -- reset rendering statistics counters
        rs_brushpolys = rs_aliaspolys = rs_skypolys =
        rs_dynamiclightmaps = rs_aliaspasses = rs_skypasses = rs_brushpasses = 0;
    }
    else if (gl_finish.value)
        glFinish ();
    
    R_SetupView (); //johnfitz -- frame initialization
    
    // Compute 3D MVP matrix following r_refdef setup
    float aspect = (vid.height > 0) ? ((float)vid.width / (float)vid.height) : 1.333f;
    
    // Intermission camera lock: suppresses discrete server tick jitter during scoreboard screens
    static vec3_t s_intermission_locked_org;
    static vec3_t s_intermission_locked_ang;
    static qboolean s_intermission_was_active = false;
    
    if (cl.intermission)
    {
        if (!s_intermission_was_active)
        {
            VectorCopy (r_refdef.vieworg, s_intermission_locked_org);
            VectorCopy (r_refdef.viewangles, s_intermission_locked_ang);
            s_intermission_was_active = true;
        }
        VectorCopy (s_intermission_locked_org, r_refdef.vieworg);
        VectorCopy (s_intermission_locked_ang, r_refdef.viewangles);
    }
    else
    {
        s_intermission_was_active = false;
    }
    
    simd_float3 viewOrg = { r_refdef.vieworg[0], r_refdef.vieworg[1], r_refdef.vieworg[2] };
    simd_float3 viewAng = { r_refdef.viewangles[0], r_refdef.viewangles[1], r_refdef.viewangles[2] };
    
    float farClip = ((gl_farclip.value > 4096.0f) ? gl_farclip.value : 65536.0f) * 2.0f;
    g_metalWorldMVP = R_Metal_ComputeMVP(r_refdef.fov_y, aspect, 4.0f, farClip, viewOrg, viewAng);
    
    // Continuous real-time clock ensures smooth water turbulence across high-refresh displays
    g_metalTime = (float)realtime;
    
    //johnfitz -- stereoscopic rendering
    if (r_stereo.value)
    {
        float eyesep = CLAMP(-8.0f, r_stereo.value, 8.0f);
        float fdepth = CLAMP(32.0f, r_stereodepth.value, 1024.0f);
        
        AngleVectors (r_refdef.viewangles, vpn, vright, vup);
        
        // Render left eye pass (red channel)
        glColorMask(1, 0, 0, 1);
        VectorMA (r_refdef.vieworg, -0.5f * eyesep, vright, r_refdef.vieworg);
        frustum_skew = 0.5 * eyesep * NEARCLIP / fdepth;
        srand((int) (cl.time * 1000));
        
        R_RenderScene ();
        
        // Render right eye pass (cyan channel)
        glClear (GL_DEPTH_BUFFER_BIT);
        glColorMask(0, 1, 1, 1);
        VectorMA (r_refdef.vieworg, 1.0f * eyesep, vright, r_refdef.vieworg);
        frustum_skew = -frustum_skew;
        srand((int) (cl.time * 1000));
        
        R_RenderScene ();
        
        // Restore framebuffer state
        glColorMask(1, 1, 1, 1);
        VectorMA (r_refdef.vieworg, -0.5f * eyesep, vright, r_refdef.vieworg);
        frustum_skew = 0.0f;
    }
    else
    {
        R_RenderScene ();
    }
    //johnfitz
    
    R_ScaleView ();
    
    //johnfitz -- modified r_speeds output
    time2 = Sys_DoubleTime ();
    if (r_pos.value)
        Con_Printf ("x %i y %i z %i (pitch %i yaw %i roll %i)\n",
                    (int)cl_entities[cl.viewentity].origin[0],
                    (int)cl_entities[cl.viewentity].origin[1],
                    (int)cl_entities[cl.viewentity].origin[2],
                    (int)cl.viewangles[PITCH],
                    (int)cl.viewangles[YAW],
                    (int)cl.viewangles[ROLL]);
    else if (r_speeds.value == 2)
        Con_Printf ("%3i ms  %4i/%4i wpoly %4i/%4i epoly %3i lmap %4i/%4i sky %1.1f mtex\n",
                    (int)((time2-time1)*1000),
                    rs_brushpolys,
                    rs_brushpasses,
                    rs_aliaspolys,
                    rs_aliaspasses,
                    rs_dynamiclightmaps,
                    rs_skypolys,
                    rs_skypasses,
                    TexMgr_FrameUsage ());
    else if (r_speeds.value)
        Con_Printf ("%3i ms  %4i wpoly %4i epoly %3i lmap\n",
                    (int)((time2-time1)*1000),
                    rs_brushpolys,
                    rs_aliaspolys,
                    rs_dynamiclightmaps);
    //johnfitz
}
