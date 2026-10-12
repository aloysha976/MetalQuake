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
// r_brush.c: brush model rendering. renamed from r_surf.c

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"
#include "mq_world_vbo.h"

extern cvar_t gl_fullbrights, r_drawflat, gl_overbright, r_oldwater; //johnfitz
extern cvar_t gl_zfix; // QuakeSpasm z-fighting fix

// Per-frame aggregate counters for dynamic lightmap tracking
// (updated during R_RenderDynamicLightmaps / R_UploadLightmap below)
static int s_eDlightSurfMarks = 0;
static int s_eRegionsUploaded = 0;

extern simd_float4x4 g_metalWorldMVP; // Metal view-projection matrix for current frame (r_world.c)

int		gl_lightmap_format;
int		lightmap_bytes;

#define MAX_SANITY_LIGHTMAPS (1u<<20)
struct lightmap_s	*lightmaps;
int		lightmap_count;

static int	allocated[LMBLOCK_WIDTH];
static int	last_lightmap_allocated;

static unsigned	blocklights[LMBLOCK_WIDTH*LMBLOCK_HEIGHT*3]; //johnfitz -- was 18*18, added lit support (*3) and loosened surface extents maximum (LMBLOCK_WIDTH*LMBLOCK_HEIGHT)


/*
 ===============
 R_TextureAnimation -- johnfitz -- added "frame" param to eliminate use of "currententity" global
 
 Returns the proper texture for a given time and base texture
 ===============
 */
texture_t *R_TextureAnimation (texture_t *base, int frame)
{
    int		relative;
    int		count;
    
    if (frame)
        if (base->alternate_anims)
            base = base->alternate_anims;
    
    if (!base->anim_total)
        return base;
    
    relative = (int)(cl.time*10) % base->anim_total;
    
    count = 0;
    while (base->anim_min > relative || base->anim_max <= relative)
    {
        base = base->anim_next;
        if (!base)
            Sys_Error ("R_TextureAnimation: broken cycle");
        if (++count > 100)
            Sys_Error ("R_TextureAnimation: infinite cycle");
    }
    
    return base;
}

/*
 ================
 DrawGLPoly -- Legacy stub for Metal backend
 ================
 */
void DrawGLPoly (glpoly_t *p)
{
    // Legacy OpenGL immediate mode (glBegin/glEnd) is obsolete.
    // Surface geometry is packed into MetalWorldVertex buffers
    // and dispatched via R_Metal_Draw3DPolygons / R_Metal_Draw3DWorldBindless.
    (void)p;
}

/*
 ================
 DrawGLTriangleFan -- Legacy stub for Metal backend
 ================
 */
void DrawGLTriangleFan (glpoly_t *p)
{
    // Legacy triangle fan immediate mode rendering is obsolete in Metal.
    (void)p;
}

/*
 =============================================================
 
 BRUSH MODELS
 
 =============================================================
 */

// Matrix primitives for brush submodels using column-major layout matching MSL conventions.
static simd_float4x4 R_Brush_MatrixTranslation (float x, float y, float z)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = (simd_float4){ x, y, z, 1.0f };
    return m;
}

static simd_float4x4 R_Brush_MatrixScale (float sx, float sy, float sz)
{
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){ sx, 0.0f, 0.0f, 0.0f };
    m.columns[1] = (simd_float4){ 0.0f, sy, 0.0f, 0.0f };
    m.columns[2] = (simd_float4){ 0.0f, 0.0f, sz, 0.0f };
    return m;
}

static simd_float4x4 R_Brush_MatrixRotateX (float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[1] = (simd_float4){ 0.0f,  c, s, 0.0f };
    m.columns[2] = (simd_float4){ 0.0f, -s, c, 0.0f };
    return m;
}

static simd_float4x4 R_Brush_MatrixRotateY (float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){ c, 0.0f, -s, 0.0f };
    m.columns[2] = (simd_float4){ s, 0.0f,  c, 0.0f };
    return m;
}

static simd_float4x4 R_Brush_MatrixRotateZ (float deg)
{
    float rad = deg * (M_PI / 180.0f);
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = (simd_float4){  c, s, 0.0f, 0.0f };
    m.columns[1] = (simd_float4){ -s, c, 0.0f, 0.0f };
    return m;
}

/*
 ========================
 R_BrushEntityMatrix
 
 Brush entity local transform matrix:
 T(origin) * RotZ(yaw) * RotY(-pitch) * RotX(roll) * Scale.
 Rotation order and inverted pitch compensate for legacy Quake pitch convention
 (e->angles[0] was negated prior to OpenGL matrix stack operations).
 ========================
 */
static simd_float4x4 R_BrushEntityMatrix (const vec3_t origin, const vec3_t angles, float scalefactor)
{
    simd_float4x4 m = R_Brush_MatrixTranslation(origin[0], origin[1], origin[2]);
    m = simd_mul(m, R_Brush_MatrixRotateZ(angles[1]));
    m = simd_mul(m, R_Brush_MatrixRotateY(-angles[0])); // stupid quake bug
    m = simd_mul(m, R_Brush_MatrixRotateX(angles[2]));
    
    if (scalefactor != 1.0f)
        m = simd_mul(m, R_Brush_MatrixScale(scalefactor, scalefactor, scalefactor));
    
    return m;
}

/*
 ================
 R_DrawBrushModel
 ================
 */
void R_DrawBrushModel (entity_t *e)
{
    int            i, k;
    msurface_t    *psurf;
    float        dot;
    mplane_t    *pplane;
    qmodel_t    *clmodel;
    
    if (R_CullModelForEntity(e))
        return;
    
    currententity = e;
    clmodel = e->model;
    
    VectorSubtract (r_refdef.vieworg, e->origin, modelorg);
    if (e->angles[0] || e->angles[1] || e->angles[2])
    {
        vec3_t    temp;
        vec3_t    forward, right, up;
        
        VectorCopy (modelorg, temp);
        AngleVectors (e->angles, forward, right, up);
        modelorg[0] = DotProduct (temp, forward);
        modelorg[1] = -DotProduct (temp, right);
        modelorg[2] = DotProduct (temp, up);
    }
    
    psurf = &clmodel->surfaces[clmodel->firstmodelsurface];
    
    // calculate dynamic lighting for bmodel if it's not an instanced model
    // Brush models are lit using surface lightmaps (their vertices are in model space,
    // so world-space dynamic light positions cannot be directly applied in the per-pixel shader)
    if (clmodel->firstmodelsurface != 0 && !gl_flashblend.value)
    {
        for (k=0 ; k<MAX_DLIGHTS ; k++)
        {
            if ((cl_dlights[k].die < cl.time) ||
                (!cl_dlights[k].radius))
                continue;
            
            R_MarkLights (&cl_dlights[k], k,
                          clmodel->nodes + clmodel->hulls[0].firstclipnode);
        }
    }
    
    // Brush entity transformation matrix replaces legacy OpenGL matrix stack
    // (glPushMatrix / R_RotateForEntity). gl_zfix offsets the origin by DIST_EPSILON
    // to prevent z-fighting as in standard QuakeSpasm.
    vec3_t bmodel_origin;
    VectorCopy (e->origin, bmodel_origin);
    if (gl_zfix.value)
    {
        bmodel_origin[0] -= DIST_EPSILON;
        bmodel_origin[1] -= DIST_EPSILON;
        bmodel_origin[2] -= DIST_EPSILON;
    }
    simd_float4x4 entityMVP = simd_mul(g_metalWorldMVP,
                                       R_BrushEntityMatrix(bmodel_origin, e->angles, ENTSCALE_DECODE(e->scale)));
    
    // Disable per-pixel dlights for brush models to account for model-space coordinates
    R_Metal_EnablePerPixelDlights (false);
    
    R_ClearTextureChains (clmodel, chain_model);
    for (i=0 ; i<clmodel->nummodelsurfaces ; i++, psurf++)
    {
        pplane = psurf->plane;
        dot = DotProduct (modelorg, pplane->normal) - pplane->dist;
        if (((psurf->flags & SURF_PLANEBACK) && (dot < -BACKFACE_EPSILON)) ||
            (!(psurf->flags & SURF_PLANEBACK) && (dot > BACKFACE_EPSILON)))
        {
            R_ChainSurface (psurf, chain_model);
            R_RenderDynamicLightmaps(psurf);
            rs_brushpolys++;
        }
    }
    
    // Render brush model texture chains using entity transform matrix
    R_DrawTextureChains (clmodel, e, chain_model, entityMVP);
    R_DrawTextureChains_Water (clmodel, e, chain_model, entityMVP);
    
    // Restore per-pixel dynamic lights for subsequent world draws
    R_Metal_EnablePerPixelDlights (true);
}
/*
 =================
 R_DrawBrushModel_ShowTris -- Legacy stub for Metal backend
 =================
 */
void R_DrawBrushModel_ShowTris (entity_t *e)
{
    // OpenGL matrix stack (glPushMatrix / R_RotateForEntity) is obsolete.
    // Brush models are transformed via SIMD entityMVP matrices inside R_DrawBrushModel().
    (void)e;
}

/*
 =============================================================
 
 LIGHTMAPS
 
 =============================================================
 */

/*
 ================
 R_RenderDynamicLightmaps
 called during rendering
 ================
 */
void R_RenderDynamicLightmaps (msurface_t *fa)
{
    byte        *base;
    int            maps;
    glRect_t    *theRect;
    int smax, tmax;
    int dlMarked; // Whether this surface is marked by a dynamic light
    
    if (fa->flags & SURF_DRAWTILED) //johnfitz -- not a lightmapped surface
        return;
    
    // Distinguish dlight modification from lightstyle animated updates
    dlMarked = (fa->dlightframe == r_framecount) || fa->cached_dlight;
    
    // add to lightmap chain
    fa->polys->chain = lightmaps[fa->lightmaptexturenum].polys;
    lightmaps[fa->lightmaptexturenum].polys = fa->polys;
    
    // check for lightmap modification
    for (maps=0; maps < MAXLIGHTMAPS && fa->styles[maps] != 255; maps++)
        if (d_lightstylevalue[fa->styles[maps]] != fa->cached_light[maps])
            goto dynamic;
    
    if (dlMarked)
    {
    dynamic:
        if (r_dynamic.value)
        {
            struct lightmap_s *lm = &lightmaps[fa->lightmaptexturenum];
            lm->modified = true;
            // Track dynamic light surface updates per frame
            if (dlMarked)
                s_eDlightSurfMarks++;
            theRect = &lm->rectchange;
            if (fa->light_t < theRect->t) {
                if (theRect->h)
                    theRect->h += theRect->t - fa->light_t;
                theRect->t = fa->light_t;
            }
            if (fa->light_s < theRect->l) {
                if (theRect->w)
                    theRect->w += theRect->l - fa->light_s;
                theRect->l = fa->light_s;
            }
            smax = (fa->extents[0]>>4)+1;
            tmax = (fa->extents[1]>>4)+1;
            if ((theRect->w + theRect->l) < (fa->light_s + smax))
                theRect->w = (fa->light_s-theRect->l)+smax;
            if ((theRect->h + theRect->t) < (fa->light_t + tmax))
                theRect->h = (fa->light_t-theRect->t)+tmax;
            base = lm->data;
            base += fa->light_t * LMBLOCK_WIDTH * lightmap_bytes + fa->light_s * lightmap_bytes;
            R_BuildLightMap (fa, base, LMBLOCK_WIDTH*lightmap_bytes);
        }
    }
}

/*
 ========================
 AllocBlock -- returns a texture number and the position inside it
 ========================
 */
int AllocBlock (int w, int h, int *x, int *y)
{
    int		i, j;
    int		best, best2;
    int		texnum;
    
    // ericw -- rather than searching starting at lightmap 0 every time,
    // start at the last lightmap we allocated a surface in.
    // This makes AllocBlock much faster on large levels (can shave off 3+ seconds
    // of load time on a level with 180 lightmaps), at a cost of not quite packing
    // lightmaps as tightly vs. not doing this (uses ~5% more lightmaps)
    for (texnum=last_lightmap_allocated ; texnum<MAX_SANITY_LIGHTMAPS ; texnum++)
    {
        if (texnum == lightmap_count)
        {
            lightmap_count++;
            lightmaps = (struct lightmap_s *) realloc(lightmaps, sizeof(*lightmaps)*lightmap_count);
            memset(&lightmaps[texnum], 0, sizeof(lightmaps[texnum]));
            lightmaps[texnum].data = (byte *) calloc(1, 4*LMBLOCK_WIDTH*LMBLOCK_HEIGHT);
            //as we're only tracking one texture, we don't need multiple copies of allocated any more.
            memset(allocated, 0, sizeof(allocated));
        }
        best = LMBLOCK_HEIGHT;
        
        for (i=0 ; i<LMBLOCK_WIDTH-w ; i++)
        {
            best2 = 0;
            
            for (j=0 ; j<w ; j++)
            {
                if (allocated[i+j] >= best)
                    break;
                if (allocated[i+j] > best2)
                    best2 = allocated[i+j];
            }
            if (j == w)
            {	// this is a valid spot
                *x = i;
                *y = best = best2;
            }
        }
        
        if (best + h > LMBLOCK_HEIGHT)
            continue;
        
        for (i=0 ; i<w ; i++)
            allocated[*x + i] = best + h;
        
        last_lightmap_allocated = texnum;
        return texnum;
    }
    
    Sys_Error ("AllocBlock: full");
    return 0; //johnfitz -- shut up compiler
}


static mvertex_t	*r_pcurrentvertbase;
static  qmodel_t	*currentmodel;

/*
 ========================
 GL_CreateSurfaceLightmap
 ========================
 */
void GL_CreateSurfaceLightmap (msurface_t *surf)
{
    int		smax, tmax;
    byte	*base;
    
    if (surf->flags & SURF_DRAWTILED)
    {
        surf->lightmaptexturenum = -1;
        return;
    }
    
    smax = (surf->extents[0]>>4)+1;
    tmax = (surf->extents[1]>>4)+1;
    
    surf->lightmaptexturenum = AllocBlock (smax, tmax, &surf->light_s, &surf->light_t);
    base = lightmaps[surf->lightmaptexturenum].data;
    base += (surf->light_t * LMBLOCK_WIDTH + surf->light_s) * lightmap_bytes;
    R_BuildLightMap (surf, base, LMBLOCK_WIDTH*lightmap_bytes);
}

/*
 ================
 BuildSurfaceDisplayList -- called at level load time
 ================
 */
void BuildSurfaceDisplayList (msurface_t *fa)
{
    int			i, lindex, lnumverts;
    medge_t		*pedges, *r_pedge;
    float		*vec;
    float		s, t, s0, t0, sdiv, tdiv;
    glpoly_t	*poly;
    
    // reconstruct the polygon
    pedges = currentmodel->edges;
    lnumverts = fa->numedges;
    
    //
    // draw texture
    //
    poly = (glpoly_t *) Hunk_Alloc (sizeof(glpoly_t) + (lnumverts-4) * VERTEXSIZE*sizeof(float));
    poly->next = fa->polys;
    fa->polys = poly;
    poly->numverts = lnumverts;
    
    if (fa->flags & SURF_DRAWTURB)
    {
        // match Mod_PolyForUnlitSurface
        s0 = t0 = 0.f;
        sdiv = tdiv = 128.f;
    }
    else
    {
        s0 = fa->texinfo->vecs[0][3];
        t0 = fa->texinfo->vecs[1][3];
        sdiv = fa->texinfo->texture->width;
        tdiv = fa->texinfo->texture->height;
    }
    
    for (i=0 ; i<lnumverts ; i++)
    {
        lindex = currentmodel->surfedges[fa->firstedge + i];
        
        if (lindex > 0)
        {
            r_pedge = &pedges[lindex];
            vec = r_pcurrentvertbase[r_pedge->v[0]].position;
        }
        else
        {
            r_pedge = &pedges[-lindex];
            vec = r_pcurrentvertbase[r_pedge->v[1]].position;
        }
        s = DotProduct (vec, fa->texinfo->vecs[0]) + s0;
        s /= sdiv;
        
        t = DotProduct (vec, fa->texinfo->vecs[1]) + t0;
        t /= tdiv;
        
        VectorCopy (vec, poly->verts[i]);
        poly->verts[i][3] = s;
        poly->verts[i][4] = t;
        
        // Q64 RERELEASE texture shift
        if (fa->texinfo->texture->shift > 0)
        {
            poly->verts[i][3] /= ( 2 * fa->texinfo->texture->shift);
            poly->verts[i][4] /= ( 2 * fa->texinfo->texture->shift);
        }
        
        //
        // lightmap texture coordinates
        //
        s = DotProduct (vec, fa->texinfo->vecs[0]) + fa->texinfo->vecs[0][3];
        s -= fa->texturemins[0];
        s += fa->light_s*16;
        s += 8;
        s /= LMBLOCK_WIDTH*16; //fa->texinfo->texture->width;
        
        t = DotProduct (vec, fa->texinfo->vecs[1]) + fa->texinfo->vecs[1][3];
        t -= fa->texturemins[1];
        t += fa->light_t*16;
        t += 8;
        t /= LMBLOCK_HEIGHT*16; //fa->texinfo->texture->height;
        
        poly->verts[i][5] = s;
        poly->verts[i][6] = t;
    }
    
    //johnfitz -- removed gl_keeptjunctions code
    
    poly->numverts = lnumverts;
    
    // support r_oldwater 1 on lit water
    if (fa->flags & SURF_DRAWTURB)
        GL_SubdivideSurface (fa);
}

/*
 ==================
 GL_BuildLightmaps -- called at level load time
 
 Builds the lightmap texture
 with all the surfaces from all brush models
 ==================
 */
void GL_BuildLightmaps (void)
{
    char	name[24];
    int		i, j;
    struct lightmap_s *lm;
    qmodel_t	*m;
    
    r_framecount = 1; // no dlightcache
    
    //Spike -- wipe out all the lightmap data (johnfitz -- the gltexture objects were already freed by Mod_ClearAll)
    for (i=0; i < lightmap_count; i++)
        free(lightmaps[i].data);
    free(lightmaps);
    lightmaps = NULL;
    last_lightmap_allocated = 0;
    lightmap_count = 0;
    
    gl_lightmap_format = GL_RGBA;//FIXME: hardcoded for now!
    
    switch (gl_lightmap_format)
    {
        case GL_RGBA:
            lightmap_bytes = 4;
            break;
        case GL_BGRA:
            lightmap_bytes = 4;
            break;
        default:
            Sys_Error ("GL_BuildLightmaps: bad lightmap format");
    }
    
    for (j=1 ; j<MAX_MODELS ; j++)
    {
        m = cl.model_precache[j];
        if (!m)
            break;
        if (m->name[0] == '*')
            continue;
        r_pcurrentvertbase = m->vertexes;
        currentmodel = m;
        for (i=0 ; i<m->numsurfaces ; i++)
        {
            //johnfitz -- rewritten to use SURF_DRAWTILED instead of the sky/water flags
            if (m->surfaces[i].flags & SURF_DRAWTILED)
                continue;
            GL_CreateSurfaceLightmap (m->surfaces + i);
            BuildSurfaceDisplayList (m->surfaces + i);
            //johnfitz
        }
    }
    
    //
    // upload all lightmaps that were filled
    //
    for (i=0; i<lightmap_count; i++)
    {
        lm = &lightmaps[i];
        lm->modified = false;
        lm->rectchange.l = LMBLOCK_WIDTH;
        lm->rectchange.t = LMBLOCK_HEIGHT;
        lm->rectchange.w = 0;
        lm->rectchange.h = 0;
        
        //johnfitz -- use texture manager
        sprintf(name, "lightmap%07i",i);
        lm->texture = TexMgr_LoadImage (cl.worldmodel, name, LMBLOCK_WIDTH, LMBLOCK_HEIGHT,
                                        SRC_LIGHTMAP, lm->data, "", (src_offset_t)lm->data, TEXPREF_LINEAR | TEXPREF_NOPICMIP);
        //johnfitz
    }
    
    //johnfitz -- warn about exceeding old limits
    //GLQuake limit was 64 textures of 128x128. Estimate how many 128x128 textures we would need
    //given that we are using lightmap_count of LMBLOCK_WIDTH x LMBLOCK_HEIGHT
    i = lightmap_count * ((LMBLOCK_WIDTH / 128) * (LMBLOCK_HEIGHT / 128));
    if (i > 64)
        Con_DWarning("%i lightmaps exceeds standard limit of 64.\n",i);
    //johnfitz
    
    // Bake static world geometry into VBO and generate acceleration structures
    MQ_WorldVBO_Build (cl.worldmodel);
}

/*
 =============================================================
 
 VBO support -- Legacy stubs for Metal backend
 
 =============================================================
 */

GLuint gl_bmodel_vbo = 0;

void GL_DeleteBModelVertexBuffer (void)
{
    // Legacy OpenGL gl_bmodel_vbo is obsolete.
    gl_bmodel_vbo = 0;
}

void GL_BuildBModelVertexBuffer (void)
{
    // OpenGL vertex buffer construction for brush models is obsolete in Metal.
    // Static world geometry is baked into s_worldVBO via MQ_WorldVBO_Build(),
    // and dynamic brush models are dispatched per frame via R_Metal_Draw3DPolygons.
}

/*
 ===============
 R_AddDynamicLights
 ===============
 */
void R_AddDynamicLights (msurface_t *surf)
{
    int			lnum;
    int			sd, td;
    float		dist, rad, minlight;
    vec3_t		impact, local;
    int			s, t;
    int			i;
    int			smax, tmax;
    mtexinfo_t	*tex;
    //johnfitz -- lit support via lordhavoc
    float		cred, cgreen, cblue, brightness;
    unsigned	*bl;
    //johnfitz
    
    smax = (surf->extents[0]>>4)+1;
    tmax = (surf->extents[1]>>4)+1;
    tex = surf->texinfo;
    
    for (lnum=0 ; lnum<MAX_DLIGHTS ; lnum++)
    {
        if (! (surf->dlightbits[lnum >> 5] & (1U << (lnum & 31))))
            continue;		// not lit by this light
        
        rad = cl_dlights[lnum].radius;
        dist = DotProduct (cl_dlights[lnum].origin, surf->plane->normal) -
        surf->plane->dist;
        rad -= fabs(dist);
        minlight = cl_dlights[lnum].minlight;
        if (rad < minlight)
            continue;
        minlight = rad - minlight;
        
        for (i=0 ; i<3 ; i++)
        {
            impact[i] = cl_dlights[lnum].origin[i] -
            surf->plane->normal[i]*dist;
        }
        
        local[0] = DotProduct (impact, tex->vecs[0]) + tex->vecs[0][3];
        local[1] = DotProduct (impact, tex->vecs[1]) + tex->vecs[1][3];
        
        local[0] -= surf->texturemins[0];
        local[1] -= surf->texturemins[1];
        
        //johnfitz -- lit support via lordhavoc
        bl = blocklights;
        cred = cl_dlights[lnum].color[0] * 256.0f;
        cgreen = cl_dlights[lnum].color[1] * 256.0f;
        cblue = cl_dlights[lnum].color[2] * 256.0f;
        //johnfitz
        for (t = 0 ; t<tmax ; t++)
        {
            td = local[1] - t*16;
            if (td < 0)
                td = -td;
            for (s=0 ; s<smax ; s++)
            {
                sd = local[0] - s*16;
                if (sd < 0)
                    sd = -sd;
                if (sd > td)
                    dist = sd + (td>>1);
                else
                    dist = td + (sd>>1);
                if (dist < minlight)
                    //johnfitz -- lit support via lordhavoc
                {
                    brightness = rad - dist;
                    bl[0] += (int) (brightness * cred);
                    bl[1] += (int) (brightness * cgreen);
                    bl[2] += (int) (brightness * cblue);
                }
                bl += 3;
                //johnfitz
            }
        }
    }
}


/*
 ===============
 R_BuildLightMap -- johnfitz -- revised for lit support via lordhavoc
 
 Combine and scale multiple lightmaps into the 8.8 format in blocklights
 ===============
 */
void R_BuildLightMap (msurface_t *surf, byte *dest, int stride)
{
    const int overbright = !!gl_overbright.value;
    // 10-bit packed format (r_lightmapwide) is incompatible with MTLPixelFormatRGBA8Unorm,
    // so 8-bit RGBA lightmaps are consistently used.
    const int wide10bits = 0;
    
    int			smax, tmax;
    unsigned		r, g, b;
    int			i, j, size;
    byte		*lightmap;
    unsigned	scale;
    int			maps;
    unsigned	*bl;
    
    surf->cached_dlight = (surf->dlightframe == r_framecount);
    
    smax = (surf->extents[0]>>4)+1;
    tmax = (surf->extents[1]>>4)+1;
    size = smax*tmax;
    lightmap = surf->samples;
    
    if (cl.worldmodel->lightdata)
    {
        // clear to no light
        memset (&blocklights[0], 0, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc
        
        // add all the lightmaps
        if (lightmap)
        {
            for (maps = 0 ; maps < MAXLIGHTMAPS && surf->styles[maps] != 255 ;
                 maps++)
            {
                scale = d_lightstylevalue[surf->styles[maps]];
                surf->cached_light[maps] = scale;    // 8.8 fraction
                //johnfitz -- lit support via lordhavoc
                bl = blocklights;
                for (i=0 ; i<size ; i++)
                {
                    *bl++ += *lightmap++ * scale;
                    *bl++ += *lightmap++ * scale;
                    *bl++ += *lightmap++ * scale;
                }
                //johnfitz
            }
        }
        
        // add all the dynamic lights
        if (surf->dlightframe == r_framecount)
            R_AddDynamicLights (surf);
    }
    else
    {
        // set to full bright if no light data
        memset (&blocklights[0], 255, size * 3 * sizeof (unsigned int)); //johnfitz -- lit support via lordhavoc
    }
    
    // bound, invert, and shift
    // store:
    switch (gl_lightmap_format)
    {
        case GL_RGBA:
            stride -= smax * 4;
            bl = blocklights;
            for (i=0 ; i<tmax ; i++, dest += stride)
            {
                for (j=0 ; j<smax ; j++)
                {
                    if (overbright)
                    {
                        r = *bl++ >> 8;
                        g = *bl++ >> 8;
                        b = *bl++ >> 8;
                    }
                    else
                    {
                        r = *bl++ >> 7;
                        g = *bl++ >> 7;
                        b = *bl++ >> 7;
                        if (wide10bits) {
                            // artifically clamp to 255 so gl_overbright 0 renders as expected in the wide10bits case
                            r = (r > 255) ? 255 : r;
                            g = (g > 255) ? 255 : g;
                            b = (b > 255) ? 255 : b;
                            goto loc0;
                        }
                    }
                    if (wide10bits)
                    {
                        r = (r > 1023)? 1023 : r;
                        g = (g > 1023)? 1023 : g;
                        b = (b > 1023)? 1023 : b;
                    loc0:
                        *(unsigned int*)dest = (r<<22) | (g<<12) | (b<<2) | 3;
                        dest += 4;
                    }
                    else
                    {
                        *dest++ = (r > 255)? 255 : r;
                        *dest++ = (g > 255)? 255 : g;
                        *dest++ = (b > 255)? 255 : b;
                        *dest++ = 255;
                    }
                }
            }
            break;
        case GL_BGRA:
            stride -= smax * 4;
            bl = blocklights;
            for (i=0 ; i<tmax ; i++, dest += stride)
            {
                for (j=0 ; j<smax ; j++)
                {
                    if (overbright)
                    {
                        r = *bl++ >> 8;
                        g = *bl++ >> 8;
                        b = *bl++ >> 8;
                    }
                    else
                    {
                        r = *bl++ >> 7;
                        g = *bl++ >> 7;
                        b = *bl++ >> 7;
                        if (wide10bits) {
                            // artifically clamp to 255 so gl_overbright 0 renders as expected in the wide10bits case
                            r = (r > 255) ? 255 : r;
                            g = (g > 255) ? 255 : g;
                            b = (b > 255) ? 255 : b;
                            goto loc1;
                        }
                    }
                    if (wide10bits)
                    {
                        r = (r > 1023)? 1023 : r;
                        g = (g > 1023)? 1023 : g;
                        b = (b > 1023)? 1023 : b;
                    loc1:
                        *(unsigned int*)dest = (b<<22) | (g<<12) | (r<<2) | 3;
                        dest += 4;
                    }
                    else
                    {
                        *dest++ = (b > 255)? 255 : b;
                        *dest++ = (g > 255)? 255 : g;
                        *dest++ = (r > 255)? 255 : r;
                        *dest++ = 255;
                    }
                }
            }
            break;
        default:
            Sys_Error ("R_BuildLightMap: bad lightmap format");
    }
}

/*
 ===============
 R_UploadLightmap -- johnfitz -- uploads the modified lightmap to opengl if necessary
 
 Uploads modified region rows to MTLTexture via R_Metal_UpdateTextureRegion
 (invoking replaceRegion on shared storage with CPU memcpy).
 ===============
 */

static void R_UploadLightmap(int lmap)
{
    struct lightmap_s *lm = &lightmaps[lmap];
    
    if (!lm->modified)
        return;
    
    lm->modified = false;
    
    if (lm->texture && lm->texture->metalTexture && lm->rectchange.h > 0)
    {
        // Diagnostics verifying dirty region upload to GPU
        if (MLog_Budget("DLT·REG", 15))
            MLog(MQ_LVL_DEV, "DLT·REG",
                 "lm#%d rect(t=%d h=%d full_w=%d)",
                 lmap, lm->rectchange.t, lm->rectchange.h, LMBLOCK_WIDTH);
        
        R_Metal_UpdateTextureRegion(lm->texture->metalTexture,
                                    0, lm->rectchange.t,
                                    LMBLOCK_WIDTH, lm->rectchange.h,
                                    lm->data + lm->rectchange.t * LMBLOCK_WIDTH * lightmap_bytes,
                                    LMBLOCK_WIDTH * lightmap_bytes);
        s_eRegionsUploaded++;
        rs_dynamiclightmaps++;
    }
    
    lm->rectchange.l = LMBLOCK_WIDTH;
    lm->rectchange.t = LMBLOCK_HEIGHT;
    lm->rectchange.h = 0;
    lm->rectchange.w = 0;
}

void R_UploadLightmaps (void)
{
    int lmap;
    
    for (lmap = 0; lmap < lightmap_count; lmap++)
        R_UploadLightmap(lmap); // GL_Bind is not needed: texture reference is retained in lightmap_s
    
    // Per-frame diagnostic aggregate: non-zero values confirm dynamic light pipeline activity
    if (s_eDlightSurfMarks > 0 || s_eRegionsUploaded > 0)
    {
        if (MLog_Budget("DLT·MARK", 20))
            MLog(MQ_LVL_DEV, "DLT·MARK",
                 "dlight surfaces=%d regions uploaded=%d",
                 s_eDlightSurfMarks, s_eRegionsUploaded);
        s_eDlightSurfMarks = 0;
        s_eRegionsUploaded = 0;
    }
}

/*
 ================
 R_RebuildAllLightmaps -- johnfitz -- called when gl_overbright gets toggled
 ================
 */
void R_RebuildAllLightmaps (void)
{
    int			i, j;
    qmodel_t	*mod;
    msurface_t	*fa;
    byte		*base;
    
    if (!cl.worldmodel) // is this the correct test?
        return;
    
    //for each surface in each model, rebuild lightmap with new scale
    for (i=1; i<MAX_MODELS; i++)
    {
        if (!(mod = cl.model_precache[i]))
            continue;
        fa = &mod->surfaces[mod->firstmodelsurface];
        for (j=0; j<mod->nummodelsurfaces; j++, fa++)
        {
            if (fa->flags & SURF_DRAWTILED)
                continue;
            base = lightmaps[fa->lightmaptexturenum].data;
            base += fa->light_t * LMBLOCK_WIDTH * lightmap_bytes + fa->light_s * lightmap_bytes;
            R_BuildLightMap (fa, base, LMBLOCK_WIDTH*lightmap_bytes);
        }
    }
    
    //for each lightmap, upload it
    // Full texture upload via replaceRegion for shared storage
    for (i=0; i<lightmap_count; i++)
    {
        if (lightmaps[i].texture && lightmaps[i].texture->metalTexture)
            R_Metal_UpdateTextureRegion (lightmaps[i].texture->metalTexture,
                                         0, 0, LMBLOCK_WIDTH, LMBLOCK_HEIGHT,
                                         lightmaps[i].data, LMBLOCK_WIDTH * lightmap_bytes);
    }
}

void *R_GetLightmapTextureHandle (int lightmapnum)
{
    if (lightmapnum < 0 || lightmapnum >= lightmap_count)
        return NULL;
    
    if (!lightmaps[lightmapnum].texture)
        return NULL;
    
    return lightmaps[lightmapnum].texture->metalTexture;
}
