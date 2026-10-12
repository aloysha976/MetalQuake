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

// gl_texmgr.c -- Texture manager managing GPU texture resources

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"

static const int    gl_solid_format = 3;
static const int    gl_alpha_format = 4;

static cvar_t    gl_texturemode = {"gl_texturemode", "", CVAR_ARCHIVE};
// Note: gl_texture_anisotropy is registered in mq_context.m to prevent duplicate definitions
static cvar_t    gl_max_size = {"gl_max_size", "0", CVAR_NONE};
static cvar_t    gl_picmip = {"gl_picmip", "0", CVAR_NONE};
static GLint    gl_hardware_maxsize;

#define    MAX_GLTEXTURES    4096
static int numgltextures;
static gltexture_t    *active_gltextures, *free_gltextures;
gltexture_t        *notexture, *nulltexture;

unsigned int d_8to24table[256];
unsigned int d_8to24table_fbright[256];
unsigned int d_8to24table_fbright_fence[256];
unsigned int d_8to24table_nobright[256];
unsigned int d_8to24table_nobright_fence[256];
unsigned int d_8to24table_conchars[256];

/*
 ================================================================================
 
 COMMANDS
 
 ================================================================================
 */

typedef struct
{
    int    magfilter;
    int    minfilter;
    const char  *name;
} glmode_t;
static glmode_t glmodes[] = {
    {GL_NEAREST, GL_NEAREST,        "GL_NEAREST"},
    {GL_NEAREST, GL_NEAREST_MIPMAP_NEAREST,    "GL_NEAREST_MIPMAP_NEAREST"},
    {GL_NEAREST, GL_NEAREST_MIPMAP_LINEAR,    "GL_NEAREST_MIPMAP_LINEAR"},
    {GL_LINEAR,  GL_LINEAR,            "GL_LINEAR"},
    {GL_LINEAR,  GL_LINEAR_MIPMAP_NEAREST,    "GL_LINEAR_MIPMAP_NEAREST"},
    {GL_LINEAR,  GL_LINEAR_MIPMAP_LINEAR,    "GL_LINEAR_MIPMAP_LINEAR"},
};
#define NUM_GLMODES (int)Q_COUNTOF(glmodes)
static int glmode_idx = NUM_GLMODES - 1; /* Trilinear default */

/*
 ===============
 TexMgr_DescribeTextureModes_f -- Report available texture filtering modes
 ===============
 */
static void TexMgr_DescribeTextureModes_f (void)
{
    int i;
    for (i = 0; i < NUM_GLMODES; i++)
        Con_SafePrintf ("   %2i: %s\n", i + 1, glmodes[i].name);
    Con_Printf ("%i modes\n", i);
}

/*
 ===============
 TexMgr_SetFilterModes
 ===============
 */
static void TexMgr_SetFilterModes (gltexture_t *glt)
{
    // Texture filtering configuration in Metal is decoupled from MTLTexture objects
    // and managed globally via MTLSamplerState in mq_context.m
    (void)glt;
}

/*
 ===============
 TexMgr_TextureMode_f -- Invoked upon gl_texturemode modification
 ===============
 */
static void TexMgr_TextureMode_f (cvar_t *var)
{
    gltexture_t    *glt;
    int i;
    
    for (i = 0; i < NUM_GLMODES; i++)
    {
        if (!Q_strcmp (glmodes[i].name, gl_texturemode.string))
        {
            if (glmode_idx != i)
            {
                glmode_idx = i;
                for (glt = active_gltextures; glt; glt = glt->next)
                    TexMgr_SetFilterModes (glt);
                Sbar_Changed (); // Invalidate status bar graphics to refresh filtering state
            }
            return;
        }
    }
    
    for (i = 0; i < NUM_GLMODES; i++)
    {
        if (!q_strcasecmp (glmodes[i].name, gl_texturemode.string))
        {
            Cvar_SetQuick (&gl_texturemode, glmodes[i].name);
            return;
        }
    }
    
    i = atoi(gl_texturemode.string);
    if (i >= 1 && i <= NUM_GLMODES)
    {
        Cvar_SetQuick (&gl_texturemode, glmodes[i-1].name);
        return;
    }
    
    Con_Printf ("\"%s\" is not a valid texturemode\n", gl_texturemode.string);
    Cvar_SetQuick (&gl_texturemode, glmodes[glmode_idx].name);
}

/*
 ===============
 TexMgr_Imagelist_f -- Reports active texture memory usage
 ===============
 */
static void TexMgr_Imagelist_f (void)
{
    float mb;
    float texels = 0;
    gltexture_t	*glt;
    
    for (glt = active_gltextures; glt; glt = glt->next)
    {
        Con_SafePrintf ("   %4i x%4i %s\n", glt->width, glt->height, glt->name);
        if (glt->flags & TEXPREF_MIPMAP)
            texels += glt->width * glt->height * 4.0f / 3.0f;
        else
            texels += (glt->width * glt->height);
    }
    
    mb = texels * (Cvar_VariableValue("vid_bpp") / 8.0f) / 0x100000;
    Con_Printf ("%i textures %i pixels %1.1f megabytes\n", numgltextures, (int)texels, mb);
}

/*
 ===============
 TexMgr_Imagedump_f -- dump all current textures to TGA files
 ===============
 */
#ifndef __EMSCRIPTEN__
/*
 ===============
 TexMgr_Imagedump_f
 ===============
 */
static void TexMgr_Imagedump_f (void)
{
    Con_Printf ("imagedump is unsupported on the Metal backend.\n");
}
#endif

/*
 ===============
 TexMgr_FrameUsage -- Reports texture memory bandwidth consumed during the active frame
 ===============
 */
float TexMgr_FrameUsage (void)
{
    float mb;
    float texels = 0;
    gltexture_t	*glt;
    
    for (glt = active_gltextures; glt; glt = glt->next)
    {
        if (glt->visframe == r_framecount)
        {
            if (glt->flags & TEXPREF_MIPMAP)
                texels += glt->width * glt->height * 4.0f / 3.0f;
            else
                texels += (glt->width * glt->height);
        }
    }
    
    mb = texels * (Cvar_VariableValue("vid_bpp") / 8.0f) / 0x100000;
    return mb;
}

/*
 ================================================================================
 
 TEXTURE MANAGER
 
 ================================================================================
 */

/*
 ================
 TexMgr_FindTexture
 ================
 */
gltexture_t *TexMgr_FindTexture (qmodel_t *owner, const char *name)
{
    gltexture_t	*glt;
    
    if (name)
    {
        for (glt = active_gltextures; glt; glt = glt->next)
        {
            if (glt->owner == owner && !strcmp (glt->name, name))
                return glt;
        }
    }
    
    return NULL;
}

/*
 ================
 TexMgr_NewTexture
 ================
 */
gltexture_t *TexMgr_NewTexture (void)
{
    gltexture_t *glt;
    static int g_fake_texnum = 100;
    
    if (numgltextures == MAX_GLTEXTURES)
        Sys_Error("numgltextures == MAX_GLTEXTURES\n");
    
    glt = free_gltextures;
    free_gltextures = glt->next;
    
    memset(glt, 0, sizeof(gltexture_t));
    
    glt->next = active_gltextures;
    active_gltextures = glt;
    
    glt->texnum = g_fake_texnum++;
    numgltextures++;
    return glt;
}

static void GL_DeleteTexture (gltexture_t *texture);

//ericw -- workaround for preventing TexMgr_FreeTexture during TexMgr_ReloadImages
static qboolean in_reload_images;

/*
 ================
 TexMgr_FreeTexture
 ================
 */
void TexMgr_FreeTexture (gltexture_t *kill)
{
    gltexture_t *glt;
    
    if (in_reload_images)
        return;
    
    if (kill == NULL)
    {
        Con_Printf ("TexMgr_FreeTexture: NULL texture\n");
        return;
    }
    
    if (active_gltextures == kill)
    {
        active_gltextures = kill->next;
        kill->next = free_gltextures;
        free_gltextures = kill;
        
        GL_DeleteTexture(kill);
        numgltextures--;
        return;
    }
    
    for (glt = active_gltextures; glt; glt = glt->next)
    {
        if (glt->next == kill)
        {
            glt->next = kill->next;
            kill->next = free_gltextures;
            free_gltextures = kill;
            
            GL_DeleteTexture(kill);
            numgltextures--;
            return;
        }
    }
    
    Con_Printf ("TexMgr_FreeTexture: not found\n");
}

/*
 ================
 TexMgr_FreeTextures
 
 compares each bit in "flags" to the one in glt->flags only if that bit is active in "mask"
 ================
 */
void TexMgr_FreeTextures (unsigned int flags, unsigned int mask)
{
    gltexture_t *glt, *next;
    
    for (glt = active_gltextures; glt; glt = next)
    {
        next = glt->next;
        if ((glt->flags & mask) == (flags & mask))
            TexMgr_FreeTexture (glt);
    }
}

/*
 ================
 TexMgr_FreeTexturesForOwner
 ================
 */
void TexMgr_FreeTexturesForOwner (qmodel_t *owner)
{
    gltexture_t *glt, *next;
    
    for (glt = active_gltextures; glt; glt = next)
    {
        next = glt->next;
        if (glt && glt->owner == owner)
            TexMgr_FreeTexture (glt);
    }
}

/*
 ================
 TexMgr_DeleteTextureObjects
 ================
 */
void TexMgr_DeleteTextureObjects (void)
{
    gltexture_t *glt;
    
    for (glt = active_gltextures; glt; glt = glt->next)
    {
        GL_DeleteTexture (glt);
    }
}

/*
 ================================================================================
 
 INIT
 
 ================================================================================
 */

/*
 =================
 TexMgr_LoadPalette -- Loads and initializes standard, fullbright, and conchars palettes
 =================
 */
void TexMgr_LoadPalette (void)
{
    byte *pal, *src, *dst;
    int i, mark;
    FILE *f;
    
    COM_FOpenFile ("gfx/palette.lmp", &f, NULL);
    if (!f)
        Sys_Error ("Couldn't load gfx/palette.lmp");
    
    mark = Hunk_LowMark ();
    pal = (byte *) Hunk_Alloc (768);
    if (!fread(pal, 768, 1, f))
        Sys_Error ("Failed reading gfx/palette.lmp");
    fclose(f);
    
    // Standard palette: index 255 is transparent
    dst = (byte *)d_8to24table;
    src = pal;
    for (i = 0; i < 256; i++)
    {
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = 255;
    }
    ((byte *) &d_8to24table[255]) [3] = 0;
    
    // Fullbright palette: indices 0-223 are black for additive passes
    src = pal + 224*3;
    dst = (byte *) &d_8to24table_fbright[224];
    for (i = 224; i < 256; i++)
    {
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = 255;
    }
    for (i = 0; i < 224; i++)
    {
        dst = (byte *) &d_8to24table_fbright[i];
        dst[3] = 255;
        dst[2] = dst[1] = dst[0] = 0;
    }
    
    // Nobright palette: indices 224-255 are black for additive masking
    dst = (byte *)d_8to24table_nobright;
    src = pal;
    for (i = 0; i < 256; i++)
    {
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = *src++;
        *dst++ = 255;
    }
    for (i = 224; i < 256; i++)
    {
        dst = (byte *) &d_8to24table_nobright[i];
        dst[3] = 255;
        dst[2] = dst[1] = dst[0] = 0;
    }
    
    // Fullbright palette for fence textures
    memcpy(d_8to24table_fbright_fence, d_8to24table_fbright, 256*4);
    d_8to24table_fbright_fence[255] = 0;
    
    // Nobright palette for fence textures
    memcpy(d_8to24table_nobright_fence, d_8to24table_nobright, 256*4);
    d_8to24table_nobright_fence[255] = 0;
    
    // Conchars font palette: indices 0 and 255 are transparent
    memcpy(d_8to24table_conchars, d_8to24table, 256*4);
    ((byte *) &d_8to24table_conchars[0]) [3] = 0;
    
    Hunk_FreeToLowMark (mark);
}

/*
 =================
 TexMgr_LoadMiptexPalette -- Converts 24-bit palette to 32-bit RGBA
 =================
 */
static void TexMgr_LoadMiptexPalette (byte *in, byte *out, int numcolors, unsigned flags)
{
    extern cvar_t gl_fullbrights;
    int              i, numnobright;
    
    if (numcolors == 0)
        return;
    
    if (!(flags & (TEXPREF_FULLBRIGHT | TEXPREF_NOBRIGHT)))
    {
        for (i = 0; i < numcolors; i++)
        {
            *out++ = *in++;
            *out++ = *in++;
            *out++ = *in++;
            *out++ = 255;
        }
    }
    else
    {
        numnobright = q_min (224, numcolors);
        if (flags & TEXPREF_NOBRIGHT)
        {
            if (!gl_fullbrights.value)
                numnobright = numcolors;
            for (i = 0; i < numnobright; i++)
            {
                *out++ = *in++;
                *out++ = *in++;
                *out++ = *in++;
                *out++ = 255;
            }
            // 224-255 are black for additive blending
            for (i = numnobright; i < numcolors; i++)
            {
                *out++ = 0;
                *out++ = 0;
                *out++ = 0;
                *out++ = 255;
            }
        }
        else
        {
            // 0-223 are black for additive blending
            for (i = 0; i < numnobright; i++)
            {
                *out++ = 0;
                *out++ = 0;
                *out++ = 0;
                *out++ = 255;
            }
            in += numnobright * 3;
            for (i = numnobright; i < numcolors; i++)
            {
                *out++ = *in++;
                *out++ = *in++;
                *out++ = *in++;
                *out++ = 255;
            }
        }
    }
    
    // Index 255 is transparent
    if (flags & TEXPREF_ALPHA)
        out[-1] = 0;
}

/*
 ================
 TexMgr_NewGame
 ================
 */
void TexMgr_NewGame (void)
{
    TexMgr_FreeTextures (0, TEXPREF_PERSIST); // Purge non-persistent textures
    TexMgr_LoadPalette ();
}

/*
 =============
 TexMgr_RecalcWarpImageSize
 =============
 */
void TexMgr_RecalcWarpImageSize (void)
{
    gl_warpimagesize = 128;
}

/*
 ================
 TexMgr_Init -- Texture manager initialization
 ================
 */
void TexMgr_Init (void)
{
    int i;
    static byte notexture_data[16] = {159,91,83,255,0,0,0,255,0,0,0,255,159,91,83,255}; // Black and pink checkerboard
    static byte nulltexture_data[16] = {127,191,255,255,0,0,0,255,0,0,0,255,127,191,255,255}; // Black and blue checkerboard
    
    free_gltextures = (gltexture_t *) Hunk_AllocName (MAX_GLTEXTURES * sizeof(gltexture_t), "gltextures");
    memset(free_gltextures, 0, MAX_GLTEXTURES * sizeof(gltexture_t));
    
    active_gltextures = NULL;
    for (i = 0; i < MAX_GLTEXTURES - 1; i++)
        free_gltextures[i].next = &free_gltextures[i+1];
    free_gltextures[i].next = NULL;
    numgltextures = 0;
    
    TexMgr_LoadPalette ();
    
    Cvar_RegisterVariable (&gl_max_size);
    Cvar_RegisterVariable (&gl_picmip);
    gl_texturemode.string = glmodes[glmode_idx].name;
    Cvar_RegisterVariable (&gl_texturemode);
    Cvar_SetCallback (&gl_texturemode, &TexMgr_TextureMode_f);
    Cmd_AddCommand ("gl_describetexturemodes", &TexMgr_DescribeTextureModes_f);
    Cmd_AddCommand ("imagelist", &TexMgr_Imagelist_f);
#ifndef __EMSCRIPTEN__
    Cmd_AddCommand ("imagedump", &TexMgr_Imagedump_f);
#endif
    gl_hardware_maxsize = 16384;
    
    notexture = TexMgr_LoadImage (NULL, "notexture", 2, 2, SRC_RGBA, notexture_data, "", (src_offset_t)notexture_data, TEXPREF_NEAREST | TEXPREF_PERSIST | TEXPREF_NOPICMIP);
    nulltexture = TexMgr_LoadImage (NULL, "nulltexture", 2, 2, SRC_RGBA, nulltexture_data, "", (src_offset_t)nulltexture_data, TEXPREF_NEAREST | TEXPREF_PERSIST | TEXPREF_NOPICMIP);
    
    r_notexture_mip->gltexture = r_notexture_mip2->gltexture = notexture;
    
    gl_warpimagesize = 0;
    TexMgr_RecalcWarpImageSize ();
}

/*
 ================================================================================
 
 IMAGE LOADING
 
 ================================================================================
 */

/*
 ================
 TexMgr_Pad -- Returns smallest power-of-two greater than or equal to s
 ================
 */
int TexMgr_Pad (int s)
{
    int i;
    for (i = 1; i < s; i<<=1)
        ;
    return i;
}

/*
 ===============
 TexMgr_SafeTextureSize -- Returns dimension clamped to hardware and user constraints
 ===============
 */
int TexMgr_SafeTextureSize (int s)
{
    int p = (int)gl_max_size.value;
    if (!gl_texture_NPOT)
        s = TexMgr_Pad(s);
    if (p > 0) {
        p = TexMgr_Pad(p);
        if (p < s) s = p;
    }
    if (s > gl_hardware_maxsize)
        s = gl_hardware_maxsize;
    return s;
}

/*
 ================
 TexMgr_PadConditional -- Conditional padding matching texture dimension constraints
 ================
 */
int TexMgr_PadConditional (int s)
{
    if (s < TexMgr_SafeTextureSize(s))
        return TexMgr_Pad(s);
    return s;
}

/*
 ================
 TexMgr_MipMapW
 ================
 */
static unsigned *TexMgr_MipMapW (unsigned *data, int width, int height)
{
    int    i, size;
    byte    *out, *in;
    
    out = in = (byte *)data;
    size = (width*height)>>1;
    
    for (i = 0; i < size; i++, out += 4, in += 8)
    {
        out[0] = (in[0] + in[4])>>1;
        out[1] = (in[1] + in[5])>>1;
        out[2] = (in[2] + in[6])>>1;
        out[3] = (in[3] + in[7])>>1;
    }
    
    return data;
}

/*
 ================
 TexMgr_MipMapH
 ================
 */
static unsigned *TexMgr_MipMapH (unsigned *data, int width, int height)
{
    int    i, j;
    byte    *out, *in;
    
    out = in = (byte *)data;
    height>>=1;
    width<<=2;
    
    for (i = 0; i < height; i++, in += width)
    {
        for (j = 0; j < width; j += 4, out += 4, in += 4)
        {
            out[0] = (in[0] + in[width+0])>>1;
            out[1] = (in[1] + in[width+1])>>1;
            out[2] = (in[2] + in[width+2])>>1;
            out[3] = (in[3] + in[width+3])>>1;
        }
    }
    
    return data;
}

/*
 ================
 TexMgr_ResampleTexture -- Bilinear resample to power-of-two dimensions
 ================
 */
static unsigned *TexMgr_ResampleTexture (unsigned *in, int inwidth, int inheight, qboolean alpha)
{
    byte *nwpx, *nepx, *swpx, *sepx, *dest;
    unsigned xfrac, yfrac, x, y, modx, mody, imodx, imody, injump, outjump;
    unsigned *out;
    int i, j, outwidth, outheight;
    
    if (inwidth == TexMgr_Pad(inwidth) && inheight == TexMgr_Pad(inheight))
        return in;
    
    outwidth = TexMgr_Pad(inwidth);
    outheight = TexMgr_Pad(inheight);
    out = (unsigned *) Hunk_Alloc(outwidth*outheight*4);
    
    xfrac = ((inwidth-1) << 16) / (outwidth-1);
    yfrac = ((inheight-1) << 16) / (outheight-1);
    y = outjump = 0;
    
    for (i = 0; i < outheight; i++)
    {
        mody = (y>>8) & 0xFF;
        imody = 256 - mody;
        injump = (y>>16) * inwidth;
        x = 0;
        
        for (j = 0; j < outwidth; j++)
        {
            modx = (x>>8) & 0xFF;
            imodx = 256 - modx;
            
            nwpx = (byte *)(in + (x>>16) + injump);
            nepx = nwpx + 4;
            swpx = nwpx + inwidth*4;
            sepx = swpx + 4;
            
            dest = (byte *)(out + outjump + j);
            
            dest[0] = (nwpx[0]*imodx*imody + nepx[0]*modx*imody + swpx[0]*imodx*mody + sepx[0]*modx*mody)>>16;
            dest[1] = (nwpx[1]*imodx*imody + nepx[1]*modx*imody + swpx[1]*imodx*mody + sepx[1]*modx*mody)>>16;
            dest[2] = (nwpx[2]*imodx*imody + nepx[2]*modx*imody + swpx[2]*imodx*mody + sepx[2]*modx*mody)>>16;
            if (alpha)
                dest[3] = (nwpx[3]*imodx*imody + nepx[3]*modx*imody + swpx[3]*imodx*mody + sepx[3]*modx*mody)>>16;
            else
                dest[3] = 255;
            
            x += xfrac;
        }
        outjump += outwidth;
        y += yfrac;
    }
    
    return out;
}

/*
 ===============
 TexMgr_AlphaEdgeFix
 
 Eliminates color fringing along transparent alpha boundaries
 ===============
 */
static void TexMgr_AlphaEdgeFix (byte *data, int width, int height)
{
    int    i, j, n = 0, b, c[3] = {0,0,0},
    lastrow, thisrow, nextrow,
    lastpix, thispix, nextpix;
    byte    *dest = data;
    
    for (i = 0; i < height; i++)
    {
        lastrow = width * 4 * ((i == 0) ? height-1 : i-1);
        thisrow = width * 4 * i;
        nextrow = width * 4 * ((i == height-1) ? 0 : i+1);
        
        for (j = 0; j < width; j++, dest += 4)
        {
            if (dest[3])
                continue;
            
            lastpix = 4 * ((j == 0) ? width-1 : j-1);
            thispix = 4 * j;
            nextpix = 4 * ((j == width-1) ? 0 : j+1);
            
            b = lastrow + lastpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = thisrow + lastpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = nextrow + lastpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = lastrow + thispix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = nextrow + thispix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = lastrow + nextpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = thisrow + nextpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            b = nextrow + nextpix; if (data[b+3]) {c[0] += data[b]; c[1] += data[b+1]; c[2] += data[b+2]; n++;}
            
            if (n)
            {
                dest[0] = (byte)(c[0]/n);
                dest[1] = (byte)(c[1]/n);
                dest[2] = (byte)(c[2]/n);
                
                n = c[0] = c[1] = c[2] = 0;
            }
        }
    }
}

/*
 ===============
 TexMgr_PadEdgeFixW -- Clamps edge texels across padded width boundaries
 ===============
 */
static void TexMgr_PadEdgeFixW (byte *data, int width, int height)
{
    byte *src, *dst;
    int i, padw, padh;
    
    padw = TexMgr_PadConditional(width);
    padh = TexMgr_PadConditional(height);
    
    src = data + (width - 1) * 4;
    for (i = 0; i < padh; i++)
    {
        src[4] = src[0];
        src[5] = src[1];
        src[6] = src[2];
        src += padw * 4;
    }
    
    src = data;
    dst = data + (padw - 1) * 4;
    for (i = 0; i < padh; i++)
    {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        src += padw * 4;
        dst += padw * 4;
    }
}

/*
 ===============
 TexMgr_PadEdgeFixH -- Clamps edge texels across padded height boundaries
 ===============
 */
static void TexMgr_PadEdgeFixH (byte *data, int width, int height)
{
    byte *src, *dst;
    int i, padw, padh;
    
    padw = TexMgr_PadConditional(width);
    padh = TexMgr_PadConditional(height);
    
    dst = data + height * padw * 4;
    src = dst - padw * 4;
    for (i = 0; i < padw; i++)
    {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        src += 4;
        dst += 4;
    }
    
    dst = data + (padh - 1) * padw * 4;
    src = data;
    for (i = 0; i < padw; i++)
    {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        src += 4;
        dst += 4;
    }
}

/*
 ================
 TexMgr_8to32 -- Translates 8-bit indexed palette data into 32-bit RGBA
 ================
 */
static unsigned *TexMgr_8to32 (byte *in, int pixels, unsigned int *usepal)
{
    int i;
    unsigned *out, *data;
    
    out = data = (unsigned *) Hunk_Alloc(pixels*4);
    
    for (i = 0; i < pixels; i++)
        *out++ = usepal[*in++];
    
    return data;
}

/*
 ================
 TexMgr_PadImageW
 ================
 */
static byte *TexMgr_PadImageW (byte *in, int width, int height, byte padbyte)
{
    int i, j, outwidth;
    byte *out, *data;
    
    if (width == TexMgr_Pad(width))
        return in;
    
    outwidth = TexMgr_Pad(width);
    
    out = data = (byte *) Hunk_Alloc(outwidth*height);
    
    for (i = 0; i < height; i++)
    {
        for (j = 0; j < width; j++)
            *out++ = *in++;
        for (  ; j < outwidth; j++)
            *out++ = padbyte;
    }
    
    return data;
}

/*
 ================
 TexMgr_PadImageH
 ================
 */
static byte *TexMgr_PadImageH (byte *in, int width, int height, byte padbyte)
{
    int i, srcpix, dstpix;
    byte *data, *out;
    
    if (height == TexMgr_Pad(height))
        return in;
    
    srcpix = width * height;
    dstpix = width * TexMgr_Pad(height);
    
    out = data = (byte *) Hunk_Alloc(dstpix);
    
    for (i = 0; i < srcpix; i++)
        *out++ = *in++;
    for (     ; i < dstpix; i++)
        *out++ = padbyte;
    
    return data;
}

/*
 ================
 TexMgr_LoadImage32 -- Processes 32-bit source data and creates Metal texture
 ================
 */
static void TexMgr_LoadImage32 (gltexture_t *glt, unsigned *data)
{
    int    internalformat,    miplevel, mipwidth, mipheight, picmip;
    
    if (!gl_texture_NPOT)
    {
        data = TexMgr_ResampleTexture (data, glt->width, glt->height, glt->flags & TEXPREF_ALPHA);
        glt->width = TexMgr_Pad(glt->width);
        glt->height = TexMgr_Pad(glt->height);
    }
    
    picmip = (glt->flags & TEXPREF_NOPICMIP) ? 0 : q_max((int)gl_picmip.value, 0);
    mipwidth = TexMgr_SafeTextureSize (glt->width >> picmip);
    mipheight = TexMgr_SafeTextureSize (glt->height >> picmip);
    while ((int) glt->width > mipwidth)
    {
        TexMgr_MipMapW (data, glt->width, glt->height);
        glt->width >>= 1;
        if (glt->flags & TEXPREF_ALPHA)
            TexMgr_AlphaEdgeFix ((byte *)data, glt->width, glt->height);
    }
    while ((int) glt->height > mipheight)
    {
        TexMgr_MipMapH (data, glt->width, glt->height);
        glt->height >>= 1;
        if (glt->flags & TEXPREF_ALPHA)
            TexMgr_AlphaEdgeFix ((byte *)data, glt->width, glt->height);
    }
    
    GL_Bind (glt);
    if (glt->metalTexture) {
        R_Metal_FreeTexture(glt->metalTexture);
        glt->metalTexture = NULL;
    }
    glt->metalTexture = R_Metal_CreateTextureEx((int)glt->width, (int)glt->height, data, glt->name);
    
    MLog(MQ_LVL_DEV, "ENG·TEX", "LoadImage32 '%s' %dx%d flags=0x%X -> mtl=%s",
         glt->name, (int)glt->width, (int)glt->height, glt->flags,
         glt->metalTexture ? "OK" : "NULL!");
    
    GL_Bind (glt);
    
    (void)internalformat;
    (void)miplevel;
}

/*
 ================
 TexMgr_LoadImage8 -- Processes 8-bit indexed source data and passes to LoadImage32
 ================
 */
static void TexMgr_LoadImage8 (gltexture_t *glt, byte *data, unsigned int *usepal)
{
    extern cvar_t gl_fullbrights;
    qboolean padw = false, padh = false;
    byte padbyte = 0;
    int i;
    
    // Patch shell casing texture flaw from b_shell1.bsp
    if (strstr(glt->name, "shot1sid") &&
        glt->width == 32 && glt->height == 32 &&
        CRC_Block(data, 1024) == 65393)
    {
        memcpy (data, data + 32*31, 32);
    }
    
    // Detect redundant alpha flags
    if (glt->flags & TEXPREF_ALPHA && !(glt->flags & TEXPREF_CONCHARS))
    {
        for (i = 0; i < (int) (glt->width * glt->height); i++)
            if (data[i] == 255)
                break;
        if (i == (int) (glt->width * glt->height))
            glt->flags -= TEXPREF_ALPHA;
    }
    
    // Select palette mapping and padding byte
    if (!usepal)
    {
        if (glt->flags & TEXPREF_FULLBRIGHT)
        {
            if (glt->flags & TEXPREF_ALPHA)
                usepal = d_8to24table_fbright_fence;
            else
                usepal = d_8to24table_fbright;
            padbyte = 0;
        }
        else if (glt->flags & TEXPREF_NOBRIGHT && gl_fullbrights.value)
        {
            if (glt->flags & TEXPREF_ALPHA)
                usepal = d_8to24table_nobright_fence;
            else
                usepal = d_8to24table_nobright;
            padbyte = 0;
        }
        else if (glt->flags & TEXPREF_CONCHARS)
        {
            usepal = d_8to24table_conchars;
            padbyte = 0;
        }
        else
        {
            usepal = d_8to24table;
            padbyte = 255;
        }
    }
    
    // Pad dimensions if not downsampled later
    if (glt->flags & TEXPREF_PAD)
    {
        if ((int) glt->width < TexMgr_SafeTextureSize(glt->width))
        {
            data = TexMgr_PadImageW (data, glt->width, glt->height, padbyte);
            glt->width = TexMgr_Pad(glt->width);
            padw = true;
        }
        if ((int) glt->height < TexMgr_SafeTextureSize(glt->height))
        {
            data = TexMgr_PadImageH (data, glt->width, glt->height, padbyte);
            glt->height = TexMgr_Pad(glt->height);
            padh = true;
        }
    }
    
    data = (byte *)TexMgr_8to32(data, glt->width * glt->height, usepal);
    
    if (glt->flags & TEXPREF_ALPHA)
        TexMgr_AlphaEdgeFix (data, glt->width, glt->height);
    else
    {
        if (padw)
            TexMgr_PadEdgeFixW (data, glt->source_width, glt->source_height);
        if (padh)
            TexMgr_PadEdgeFixH (data, glt->source_width, glt->source_height);
    }
    
    if (glt->metalTexture) {
        R_Metal_FreeTexture(glt->metalTexture);
        glt->metalTexture = NULL;
    }
    glt->metalTexture = R_Metal_CreateTextureEx((int)glt->width, (int)glt->height, data, glt->name);
    
    MLog(MQ_LVL_DEV, "ENG·TEX", "LoadImage8  '%s' %dx%d flags=0x%X -> mtl=%s",
         glt->name, (int)glt->width, (int)glt->height, glt->flags,
         glt->metalTexture ? "OK" : "NULL!");
    
    GL_Bind (glt);
}

/*
 TexMgr_LoadLightmap -- Uploads lightmap buffers to Metal textures
 */
static void TexMgr_LoadLightmap (gltexture_t *glt, byte *data)
{
    GL_Bind (glt);
    
    if (glt->metalTexture) {
        R_Metal_FreeTexture(glt->metalTexture);
        glt->metalTexture = NULL;
    }
    
    int size = glt->width * glt->height;
    byte *rgba_data = NULL;
    qboolean needs_free = false;
    
    // Expand 24-bit RGB lightmaps to 32-bit RGBA8Unorm for Metal texture compatibility
    if (lightmap_bytes == 3) {
        rgba_data = (byte *)malloc(size * 4);
        byte *src = data;
        byte *dst = rgba_data;
        for (int i = 0; i < size; i++) {
            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
            dst[3] = 255;
            src += 3;
            dst += 4;
        }
        needs_free = true;
    } else if (lightmap_bytes == 4) {
        rgba_data = data;
    } else {
        rgba_data = (byte *)malloc(size * 4);
        memset(rgba_data, 255, size * 4);
        needs_free = true;
    }
    
    glt->metalTexture = R_Metal_CreateTextureEx((int)glt->width, (int)glt->height, rgba_data, glt->name);
    
    if (needs_free && rgba_data != data) {
        free(rgba_data);
    }
    
    TexMgr_SetFilterModes (glt);
}


/*
 ================
 TexMgr_LoadImage8Valve
 ================
 */
static void TexMgr_LoadImage8Valve (gltexture_t *glt, byte *data)
{
    byte *in, *usepal;
    unsigned short colors;
    
    in = data + glt->source_width * glt->source_height;
    
    memcpy (&colors, in, 2);
    colors = LittleShort (colors);
    
    usepal = (byte *)Hunk_Alloc (colors * 4);
    TexMgr_LoadMiptexPalette (in + 2, usepal, colors, glt->flags);
    TexMgr_LoadImage8 (glt, data, (unsigned *)usepal);
}

/*
 ================
 TexMgr_LoadImage -- Primary unified entry point for texture loading
 ================
 */
gltexture_t *TexMgr_LoadImage (qmodel_t *owner, const char *name, int width, int height, enum srcformat format,
                               byte *data, const char *source_file, src_offset_t source_offset, unsigned flags)
{
    unsigned short crc;
    gltexture_t *glt;
    int mark;
    
    if (isDedicated)
        return NULL;
    
    switch (format)
    {
        case SRC_INDEXED:
        case SRC_INDEXED_PALETTE:
            crc = CRC_Block(data, width * height);
            break;
        case SRC_LIGHTMAP:
            crc = CRC_Block(data, width * height * lightmap_bytes);
            break;
        case SRC_RGBA:
            crc = CRC_Block(data, width * height * 4);
            break;
        default:
            crc = 0;
    }
    if ((flags & TEXPREF_OVERWRITE) && (glt = TexMgr_FindTexture (owner, name)))
    {
        if (glt->source_crc == crc)
            return glt;
    }
    else
        glt = TexMgr_NewTexture ();
    
    glt->owner = owner;
    q_strlcpy (glt->name, name, sizeof(glt->name));
    glt->width = width;
    glt->height = height;
    glt->flags = flags;
    glt->shirt = -1;
    glt->pants = -1;
    q_strlcpy (glt->source_file, source_file, sizeof(glt->source_file));
    glt->source_offset = source_offset;
    glt->source_format = format;
    glt->source_width = width;
    glt->source_height = height;
    glt->source_crc = crc;
    
    mark = Hunk_LowMark();
    
    switch (glt->source_format)
    {
        case SRC_INDEXED:
            TexMgr_LoadImage8 (glt, data, NULL);
            break;
        case SRC_LIGHTMAP:
            TexMgr_LoadLightmap (glt, data);
            break;
        case SRC_RGBA:
            TexMgr_LoadImage32 (glt, (unsigned *)data);
            break;
        case SRC_INDEXED_PALETTE:
            TexMgr_LoadImage8Valve (glt, data);
            break;
    }
    
    Hunk_FreeToLowMark(mark);
    
    return glt;
}

/*
 ================================================================================
 
 COLORMAPPING AND TEXTURE RELOADING
 
 ================================================================================
 */

/*
 ================
 TexMgr_ReloadImage -- Reloads texture and applies player colormapping
 ================
 */
void TexMgr_ReloadImage (gltexture_t *glt, int shirt, int pants)
{
    byte    translation[256];
    byte    *src, *dst, *data = NULL, *translated;
    int    mark, size, i;
    
    mark = Hunk_LowMark ();
    
    if (glt->source_file[0] && glt->source_offset) {
        FILE *f;
        int sz;
        COM_FOpenFile(glt->source_file, &f, NULL);
        if (!f) goto invalid;
        fseek (f, glt->source_offset, SEEK_CUR);
        size = glt->source_width * glt->source_height;
        if (glt->source_format == SRC_RGBA) {
            size *= 4;
        }
        else if (glt->source_format == SRC_LIGHTMAP) {
            size *= lightmap_bytes;
        }
        data = (byte *) Hunk_Alloc (size);
        sz = (int) fread (data, 1, size, f);
        fclose (f);
        if (sz != size) {
            Hunk_FreeToLowMark(mark);
            Host_Error("Read error for %s", glt->name);
        }
    }
    else if (glt->source_file[0] && !glt->source_offset) {
        data = Image_LoadImage (glt->source_file, (int *)&glt->source_width, (int *)&glt->source_height);
    }
    else if (!glt->source_file[0] && glt->source_offset) {
        data = (byte *) glt->source_offset;
    }
    if (!data) {
        invalid:    Con_Printf ("TexMgr_ReloadImage: invalid source for %s\n", glt->name);
        Hunk_FreeToLowMark(mark);
        return;
    }
    
    glt->width = glt->source_width;
    glt->height = glt->source_height;
    
    if (shirt > -1 && pants > -1)
    {
        if (glt->source_format == SRC_INDEXED)
        {
            glt->shirt = shirt;
            glt->pants = pants;
        }
        else
            Con_Printf ("TexMgr_ReloadImage: can't colormap a non SRC_INDEXED texture: %s\n", glt->name);
    }
    if (glt->shirt > -1 && glt->pants > -1)
    {
        for (i = 0; i < 256; i++)
            translation[i] = i;
        
        shirt = glt->shirt * 16;
        if (shirt < 128)
        {
            for (i = 0; i < 16; i++)
                translation[TOP_RANGE+i] = shirt + i;
        }
        else
        {
            for (i = 0; i < 16; i++)
                translation[TOP_RANGE+i] = shirt+15-i;
        }
        
        pants = glt->pants * 16;
        if (pants < 128)
        {
            for (i = 0; i < 16; i++)
                translation[BOTTOM_RANGE+i] = pants + i;
        }
        else
        {
            for (i = 0; i < 16; i++)
                translation[BOTTOM_RANGE+i] = pants+15-i;
        }
        
        size = glt->width * glt->height;
        dst = translated = (byte *) Hunk_Alloc (size);
        src = data;
        
        for (i = 0; i < size; i++)
            *dst++ = translation[*src++];
        
        data = translated;
    }
    
    switch (glt->source_format)
    {
        case SRC_INDEXED:
            TexMgr_LoadImage8 (glt, data, NULL);
            break;
        case SRC_LIGHTMAP:
            TexMgr_LoadLightmap (glt, data);
            break;
        case SRC_RGBA:
            TexMgr_LoadImage32 (glt, (unsigned *)data);
            break;
        case SRC_INDEXED_PALETTE:
            TexMgr_LoadImage8Valve (glt, data);
            break;
    }
    
    Hunk_FreeToLowMark(mark);
}

/*
 ================
 TexMgr_ReloadImages -- Reloads all texture images across video mode restarts
 ================
 */
void TexMgr_ReloadImages (void)
{
    gltexture_t *glt;
    
    in_reload_images = true;
    
    for (glt = active_gltextures; glt; glt = glt->next)
    {
        TexMgr_ReloadImage (glt, -1, -1);
    }
    
    in_reload_images = false;
}

/*
 ================
 TexMgr_ReloadNobrightImages -- Refreshes textures utilizing nobright palettes
 ================
 */
void TexMgr_ReloadNobrightImages (void)
{
    gltexture_t *glt;
    
    for (glt = active_gltextures; glt; glt = glt->next)
        if (glt->flags & TEXPREF_NOBRIGHT)
            TexMgr_ReloadImage(glt, -1, -1);
}

/*
 ================================================================================
 
 TEXTURE BINDING / TEXTURE UNIT SWITCHING
 
 ================================================================================
 */

static GLuint    currenttexture[3] = {GL_UNUSED_TEXTURE, GL_UNUSED_TEXTURE, GL_UNUSED_TEXTURE};
static GLenum    currenttarget = GL_TEXTURE0_ARB;
qboolean    mtexenabled = false;

/*
 ================
 GL_SelectTexture / Multitexture
 ================
 */
void GL_SelectTexture (GLenum target)
{
    currenttarget = target;
}

void GL_DisableMultitexture (void)
{
    mtexenabled = false;
}

void GL_EnableMultitexture (void)
{
    mtexenabled = true;
}

/*
 ================
 GL_Bind -- Binds texture to active pipeline stage
 ================
 */
void GL_Bind (gltexture_t *texture)
{
    if (!texture)
        texture = nulltexture;
    
    if (texture->texnum != currenttexture[currenttarget - GL_TEXTURE0_ARB])
    {
        currenttexture[currenttarget - GL_TEXTURE0_ARB] = texture->texnum;
        texture->visframe = r_framecount;
    }
    
    if (texture && texture->metalTexture) {
        R_Metal_BindTexture2D(texture->metalTexture);
    }
}

/*
 ================
 GL_DeleteTexture -- Releases Metal texture and invalidates cached bindings
 ================
 */
static void GL_DeleteTexture (gltexture_t *texture)
{
    if (!texture) return;
    
    if (texture->metalTexture) {
        R_Metal_FreeTexture(texture->metalTexture);
        texture->metalTexture = NULL;
    }
    
    if (texture->texnum == currenttexture[0]) currenttexture[0] = GL_UNUSED_TEXTURE;
    if (texture->texnum == currenttexture[1]) currenttexture[1] = GL_UNUSED_TEXTURE;
    if (texture->texnum == currenttexture[2]) currenttexture[2] = GL_UNUSED_TEXTURE;
    
    texture->texnum = 0;
}

/*
 ================
 GL_ClearBindings -- Invalidates cached texture bindings
 ================
 */
void GL_ClearBindings(void)
{
    int i;
    for (i = 0; i < 3; i++)
    {
        currenttexture[i] = GL_UNUSED_TEXTURE;
    }
}
