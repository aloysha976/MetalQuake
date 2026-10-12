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
// r_misc.c

#include "quakedef.h"
#include "MetalBridge.h"

//johnfitz -- new cvars
extern cvar_t r_stereo;
extern cvar_t r_stereodepth;
extern cvar_t r_clearcolor;
extern cvar_t r_drawflat;
extern cvar_t r_flatlightstyles;
extern cvar_t gl_fullbrights;
extern cvar_t gl_farclip;
extern cvar_t gl_overbright;
extern cvar_t gl_overbright_models;
extern cvar_t r_waterquality;
extern cvar_t r_oldwater;
extern cvar_t r_waterwarp;
extern cvar_t r_oldskyleaf;
extern cvar_t r_drawworld;
extern cvar_t r_showtris;
extern cvar_t r_showbboxes;
extern cvar_t r_lerpmodels;
extern cvar_t r_lerpmove;
extern cvar_t r_nolerp_list;
extern cvar_t r_noshadow_list;
//johnfitz
extern cvar_t gl_zfix; // QuakeSpasm z-fighting fix

extern gltexture_t *playertextures[MAX_SCOREBOARD]; //johnfitz

cvar_t    r_lightmapwide = {"r_lightmapwide","0",CVAR_ROM};


/*
 ====================
 GL_Overbright_f -- johnfitz
 ====================
 */
static void GL_Overbright_f (cvar_t *var)
{
    R_RebuildAllLightmaps ();
}

/*
 ====================
 GL_Fullbrights_f -- johnfitz
 ====================
 */
static void GL_Fullbrights_f (cvar_t *var)
{
    TexMgr_ReloadNobrightImages ();
}

/*
 ====================
 R_SetClearColor_f
 ====================
 */
static void R_SetClearColor_f (cvar_t *var)
{
    // Fixed-function glClearColor omitted; render pass clear color
    // is set via MTLClearColor within the active MTLRenderPassDescriptor.
    (void)var;
}

/*
 ===============
 R_Model_ExtraFlags_List_f -- johnfitz -- invoked upon r_nolerp_list or r_noshadow_list modification
 ===============
 */
static void R_Model_ExtraFlags_List_f (cvar_t *var)
{
    int i;
    for (i=0; i < MAX_MODELS; i++)
        Mod_SetExtraFlags (cl.model_precache[i]);
}

/*
 ====================
 R_SetWateralpha_f -- ericw
 ====================
 */
static void R_SetWateralpha_f (cvar_t *var)
{
    map_wateralpha = var->value;
}

/*
 ====================
 R_SetLavaalpha_f -- ericw
 ====================
 */
static void R_SetLavaalpha_f (cvar_t *var)
{
    map_lavaalpha = var->value;
}

/*
 ====================
 R_SetTelealpha_f -- ericw
 ====================
 */
static void R_SetTelealpha_f (cvar_t *var)
{
    map_telealpha = var->value;
}

/*
 ====================
 R_SetSlimealpha_f -- ericw
 ====================
 */
static void R_SetSlimealpha_f (cvar_t *var)
{
    map_slimealpha = var->value;
}

/*
 ====================
 GL_WaterAlphaForSurface -- ericw
 ====================
 */
float GL_WaterAlphaForSurface (msurface_t *fa)
{
    if (fa->flags & SURF_DRAWLAVA)
        return map_lavaalpha > 0 ? map_lavaalpha : map_wateralpha;
    else if (fa->flags & SURF_DRAWTELE)
        return map_telealpha > 0 ? map_telealpha : map_wateralpha;
    else if (fa->flags & SURF_DRAWSLIME)
        return map_slimealpha > 0 ? map_slimealpha : map_wateralpha;
    else
        return map_wateralpha;
}


#include "MetalBridge.h"

/*
 ===============
 R_Init
 ===============
 */
void R_Init (void)
{
    // Register rendering configuration cvars
    extern cvar_t r_drawentities, r_drawviewmodel, r_drawworld;
    extern cvar_t r_lerpmodels, r_lerpmove;
    extern cvar_t r_interpolate;
    extern cvar_t gl_farclip, gl_fullbrights, gl_overbright, gl_overbright_models;
    extern cvar_t r_wateralpha, r_lavaalpha, r_telealpha, r_slimealpha;
    extern cvar_t r_novis, r_shadows, r_dynamic, r_speeds;
    extern cvar_t r_hdr, r_edr_force, r_edr_boost, r_hdr_exposure;
    extern cvar_t r_bloom, r_bloom_intensity, r_bloom_threshold;
    extern cvar_t metalfx_mode, metalfx_scale;
    
    Cvar_RegisterVariable (&r_drawentities);
    Cvar_RegisterVariable (&r_drawviewmodel);
    Cvar_RegisterVariable (&r_drawworld);
    Cvar_RegisterVariable (&r_lerpmodels);
    Cvar_RegisterVariable (&r_lerpmove);
    Cvar_RegisterVariable (&r_interpolate);
    Cvar_RegisterVariable (&gl_farclip);
    Cvar_RegisterVariable (&gl_fullbrights);
    Cvar_RegisterVariable (&gl_overbright);
    Cvar_RegisterVariable (&gl_overbright_models);
    Cvar_RegisterVariable (&r_wateralpha);
    Cvar_RegisterVariable (&r_lavaalpha);
    Cvar_RegisterVariable (&r_telealpha);
    Cvar_RegisterVariable (&r_slimealpha);
    Cvar_RegisterVariable (&r_novis);
    Cvar_RegisterVariable (&r_shadows);
    Cvar_RegisterVariable (&r_dynamic);
    Cvar_RegisterVariable (&r_perpixel_dlights);
    Cvar_RegisterVariable (&r_hdr);
    Cvar_RegisterVariable (&r_edr_force);
    Cvar_RegisterVariable (&r_edr_boost);
    Cvar_RegisterVariable (&r_hdr_exposure);
    Cvar_RegisterVariable (&r_bloom);
    Cvar_RegisterVariable (&r_bloom_intensity);
    Cvar_RegisterVariable (&r_bloom_threshold);
    Cvar_RegisterVariable (&metalfx_mode);
    Cvar_RegisterVariable (&metalfx_scale);
    Cvar_RegisterVariable (&r_speeds);
    
    Cvar_SetCallback (&r_wateralpha, R_SetWateralpha_f);
    Cvar_SetCallback (&r_lavaalpha, R_SetLavaalpha_f);
    Cvar_SetCallback (&r_telealpha, R_SetTelealpha_f);
    Cvar_SetCallback (&r_slimealpha, R_SetSlimealpha_f);
    
    // Initialize Metal device, command queue, and pipeline states
    R_Metal_Init ();
    R_Metal_Init3DPipeline();
    
    // Preallocate particle pool early before active hunk cache allocations begin
    // to prevent memory fragmentation and cache alignment assertions during map switches
    R_InitParticles ();
    
    Sky_Init ();
}

/*
 ===============
 R_TranslatePlayerSkin -- johnfitz -- rewritten.  also, only handles new colors, not new skins
 ===============
 */
void R_TranslatePlayerSkin (int playernum)
{
    int            top, bottom;
    
    top = (cl.scores[playernum].colors & 0xf0)>>4;
    bottom = cl.scores[playernum].colors &15;
    
    //FIXME: if gl_nocolors is on, then turned off, the textures may be out of sync with the scoreboard colors.
    if (!gl_nocolors.value)
    {
        if (playertextures[playernum])
            TexMgr_ReloadImage (playertextures[playernum], top, bottom);
    }
}

/*
 ===============
 R_TranslateNewPlayerSkin -- johnfitz -- split off of TranslatePlayerSkin -- this is called when
 the skin or model actually changes, instead of just new colors
 added bug fix from bengt jardup
 ===============
 */
void R_TranslateNewPlayerSkin (int playernum)
{
    char        name[64];
    byte        *pixels;
    aliashdr_t    *paliashdr;
    int        skinnum;
    
    // Retrieve target player entity and verify model format
    currententity = &cl_entities[1+playernum];
    
    if (!currententity->model || currententity->model->type != mod_alias)
        return;
    
    paliashdr = (aliashdr_t *)Mod_Extradata (currententity->model);
    
    skinnum = currententity->skinnum;
    
    // Validate skin index boundary bounds
    if (skinnum < 0 || skinnum >= paliashdr->numskins)
    {
        Con_DPrintf("(%d): Invalid player skin #%d\n", playernum, skinnum);
        skinnum = 0;
    }
    
    pixels = (byte *)paliashdr + paliashdr->texels[skinnum];
    
    // Upload player skin texture with dynamic recoloring support
    q_snprintf(name, sizeof(name), "player_%i", playernum);
    playertextures[playernum] = TexMgr_LoadImage (currententity->model, name, paliashdr->skinwidth, paliashdr->skinheight,
                                                  SRC_INDEXED, pixels, paliashdr->gltextures[skinnum][0]->source_file, paliashdr->gltextures[skinnum][0]->source_offset, TEXPREF_PAD | TEXPREF_OVERWRITE);
    
    // Apply team shirt and pant color translations
    R_TranslatePlayerSkin (playernum);
}

/*
 ===============
 R_NewGame -- johnfitz -- handle a game switch
 ===============
 */
void R_NewGame (void)
{
    int i;
    
    // Clear player texture references (backing GPU textures are released via TexMgr_NewGame)
    for (i=0; i<MAX_SCOREBOARD; i++)
        playertextures[i] = NULL;
}

/*
 =============
 R_ParseWorldspawn
 
 Evaluates map-level liquid transparency parameters upon map load
 =============
 */
static void R_ParseWorldspawn (void)
{
    char key[128], value[4096];
    const char *data;
    
    map_wateralpha = r_wateralpha.value;
    map_lavaalpha = r_lavaalpha.value;
    map_telealpha = r_telealpha.value;
    map_slimealpha = r_slimealpha.value;
    
    data = COM_Parse(cl.worldmodel->entities);
    if (!data)
        return;
    if (com_token[0] != '{')
        return;
    
    while (1)
    {
        data = COM_Parse(data);
        if (!data)
            return;
        if (com_token[0] == '}')
            break; // End of worldspawn entity
        if (com_token[0] == '_')
            q_strlcpy(key, com_token + 1, sizeof(key));
        else
            q_strlcpy(key, com_token, sizeof(key));
        while (key[0] && key[strlen(key)-1] == ' ') // Strip trailing whitespace
            key[strlen(key)-1] = 0;
        data = COM_ParseEx(data, CPE_ALLOWTRUNC);
        if (!data)
            return;
        q_strlcpy(value, com_token, sizeof(value));
        
        if (!strcmp("wateralpha", key))
            map_wateralpha = atof(value);
        
        if (!strcmp("lavaalpha", key))
            map_lavaalpha = atof(value);
        
        if (!strcmp("telealpha", key))
            map_telealpha = atof(value);
        
        if (!strcmp("slimealpha", key))
            map_slimealpha = atof(value);
    }
}


/*
 ===============
 R_NewMap
 ===============
 */
void R_NewMap (void)
{
    int        i;
    
    for (i=0 ; i<256 ; i++)
        d_lightstylevalue[i] = 264;        // Default unscaled lightstyle value
    
    // Clear leaf entity fragments
    for (i=0 ; i<cl.worldmodel->numleafs ; i++)
        cl.worldmodel->leafs[i].efrags = NULL;
    
    r_viewleaf = NULL;
    R_ClearParticles ();
    
    GL_BuildLightmaps ();
    GL_BuildBModelVertexBuffer ();
    
    r_framecount = 0;
    r_visframecount = 0;
    
    Sky_NewMap (); // Skybox parameters from worldspawn
    Fog_NewMap (); // Global volumetric fog from worldspawn
    R_ParseWorldspawn (); // Liquid alpha properties
    
    load_subdivide_size = gl_subdivide_size.value;
}

/*
 ====================
 R_TimeRefresh_f
 
 Diagnostic performance benchmark rotating full circle
 ====================
 */
void R_TimeRefresh_f (void)
{
    int        i;
    float        start, stop, time;
    
    if (cls.state != ca_connected)
    {
        Con_Printf("Not connected to a server\n");
        return;
    }
    
    start = Sys_DoubleTime ();
    for (i = 0; i < 128; i++)
    {
        GL_BeginRendering(&glx, &gly, &glwidth, &glheight);
        r_refdef.viewangles[1] = i/128.0*360.0;
        R_RenderView ();
        GL_EndRendering ();
    }
    
    glFinish ();
    stop = Sys_DoubleTime ();
    time = stop-start;
    Con_Printf ("%f seconds (%f fps)\n", time, 128/time);
}

void D_FlushCaches (void)
{
}

/*
 ================================================================================
 
 GLSL & VBO INFRASTRUCTURE
 
 ================================================================================
 */

GLint GL_GetUniformLocation (GLuint *programPtr, const char *name)
{
    // Uniform locations are superseded by argument buffer and direct buffer bindings
    (void)programPtr;
    (void)name;
    return -1;
}

GLuint GL_CreateProgram (const GLchar *vertSource, const GLchar *fragSource, int numbindings, const glsl_attrib_binding_t *bindings)
{
    // Runtime GLSL shader compilation superseded by compiled Metal libraries
    (void)vertSource;
    (void)fragSource;
    (void)numbindings;
    (void)bindings;
    return 0;
}

void R_DeleteShaders (void)
{
    // Metal pipeline states and function libraries are managed via ARC lifecycle
}

void GL_BindBuffer (GLenum target, GLuint buffer)
{
    // Global OpenGL buffer bindings superseded by direct encoder bindings
    (void)target;
    (void)buffer;
}

void GL_ClearBufferBindings (void)
{
    // No-op for Metal pipeline state
}
