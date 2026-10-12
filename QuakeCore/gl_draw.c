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

// draw.c -- 2D drawing

#include "quakedef.h"
#include "MetalBridge.h"
#include "mq_log.h"

//extern unsigned char d_15to8table[65536]; //johnfitz -- never used

cvar_t        scr_conalpha = {"scr_conalpha", "0.5", CVAR_ARCHIVE}; //johnfitz

qpic_t        *draw_disc;
qpic_t        *draw_backtile;

gltexture_t *char_texture; //johnfitz
qpic_t        *pic_ovr, *pic_ins; //johnfitz -- new cursor handling
qpic_t        *pic_nul; //johnfitz -- for missing gfx, don't crash

//johnfitz -- new pics
byte pic_ovr_data[8][8] =
{
    {255,255,255,255,255,255,255,255},
    {255, 15, 15, 15, 15, 15, 15,255},
    {255, 15, 15, 15, 15, 15, 15,  2},
    {255, 15, 15, 15, 15, 15, 15,  2},
    {255, 15, 15, 15, 15, 15, 15,  2},
    {255, 15, 15, 15, 15, 15, 15,  2},
    {255, 15, 15, 15, 15, 15, 15,  2},
    {255,255,  2,  2,  2,  2,  2,  2},
};

byte pic_ins_data[9][8] =
{
    { 15, 15,255,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    { 15, 15,  2,255,255,255,255,255},
    {255,  2,  2,255,255,255,255,255},
};

byte pic_nul_data[8][8] =
{
    {252,252,252,252,  0,  0,  0,  0},
    {252,252,252,252,  0,  0,  0,  0},
    {252,252,252,252,  0,  0,  0,  0},
    {252,252,252,252,  0,  0,  0,  0},
    {  0,  0,  0,  0,252,252,252,252},
    {  0,  0,  0,  0,252,252,252,252},
    {  0,  0,  0,  0,252,252,252,252},
    {  0,  0,  0,  0,252,252,252,252},
};

byte pic_stipple_data[8][8] =
{
    {255,  0,  0,  0,255,  0,  0,  0},
    {  0,  0,255,  0,  0,  0,255,  0},
    {255,  0,  0,  0,255,  0,  0,  0},
    {  0,  0,255,  0,  0,  0,255,  0},
    {255,  0,  0,  0,255,  0,  0,  0},
    {  0,  0,255,  0,  0,  0,255,  0},
    {255,  0,  0,  0,255,  0,  0,  0},
    {  0,  0,255,  0,  0,  0,255,  0},
};

byte pic_crosshair_data[8][8] =
{
    {255,255,255,255,255,255,255,255},
    {255,255,255,  8,  9,255,255,255},
    {255,255,255,  6,  8,  2,255,255},
    {255,  6,  8,  8,  6,  8,  8,255},
    {255,255,  2,  8,  8,  2,  2,  2},
    {255,255,255,  7,  8,  2,255,255},
    {255,255,255,255,  2,  2,255,255},
    {255,255,255,255,255,255,255,255},
};
//johnfitz

canvastype currentcanvas = CANVAS_NONE; //johnfitz -- for GL_SetCanvas

//==============================================================================
//
//  PIC CACHING
//
//==============================================================================

typedef struct cachepic_s
{
    char        name[MAX_QPATH];
    qpic_t        pic;
    byte        padding[32];    // for appended glpic
} cachepic_t;

#define    MAX_CACHED_PICS        128
cachepic_t    menu_cachepics[MAX_CACHED_PICS];
int            menu_numcachepics;

byte        menuplyr_pixels[4096];

//  scrap allocation
//  Allocate all the little status bar objects into a single texture
//  to mitigate texture binding overhead

#define    MAX_SCRAPS        2
#define    BLOCK_WIDTH        256
#define    BLOCK_HEIGHT    256

int            scrap_allocated[MAX_SCRAPS][BLOCK_WIDTH];
byte        scrap_texels[MAX_SCRAPS][BLOCK_WIDTH*BLOCK_HEIGHT]; //johnfitz -- removed *4 after BLOCK_HEIGHT
qboolean    scrap_dirty;
gltexture_t    *scrap_textures[MAX_SCRAPS]; //johnfitz


/*
 ================
 Scrap_AllocBlock
 
 Returns an index into scrap_texnums[] and the allocated position inside it
 ================
 */
int Scrap_AllocBlock (int w, int h, int *x, int *y)
{
    int        i, j;
    int        best, best2;
    int        texnum;
    
    for (texnum=0 ; texnum<MAX_SCRAPS ; texnum++)
    {
        best = BLOCK_HEIGHT;
        
        for (i=0 ; i<BLOCK_WIDTH-w ; i++)
        {
            best2 = 0;
            
            for (j=0 ; j<w ; j++)
            {
                if (scrap_allocated[texnum][i+j] >= best)
                    break;
                if (scrap_allocated[texnum][i+j] > best2)
                    best2 = scrap_allocated[texnum][i+j];
            }
            if (j == w)
            {    // this is a valid spot
                *x = i;
                *y = best = best2;
            }
        }
        
        if (best + h > BLOCK_HEIGHT)
            continue;
        
        for (i=0 ; i<w ; i++)
            scrap_allocated[texnum][*x + i] = best + h;
        
        return texnum;
    }
    
    Sys_Error ("Scrap_AllocBlock: full"); //johnfitz -- correct function name
    return 0; //johnfitz -- shut up compiler
}

/*
 ================
 Scrap_Upload -- johnfitz -- now uses TexMgr
 ================
 */
void Scrap_Upload (void)
{
    char name[8];
    int    i;
    
    for (i=0; i<MAX_SCRAPS; i++)
    {
        q_snprintf (name, sizeof(name), "scrap%i", i);
        scrap_textures[i] = TexMgr_LoadImage (NULL, name, BLOCK_WIDTH, BLOCK_HEIGHT, SRC_INDEXED, scrap_texels[i],
                                              "", (src_offset_t)scrap_texels[i], TEXPREF_ALPHA | TEXPREF_OVERWRITE | TEXPREF_NOPICMIP);
    }
    
    scrap_dirty = false;
}

/*
 ================
 Draw_PicFromWad
 ================
 */
qpic_t *Draw_PicFromWad (const char *name)
{
    qpic_t    *p;
    glpic_t    gl;
    src_offset_t offset; //johnfitz
    
    p = (qpic_t *) W_GetLumpName (name);
    if (!p) return pic_nul; //johnfitz
    
    // load little ones into the scrap
    if (p->width < 64 && p->height < 64)
    {
        int        x, y;
        int        i, j, k;
        int        texnum;
        
        texnum = Scrap_AllocBlock (p->width, p->height, &x, &y);
        scrap_dirty = true;
        k = 0;
        for (i=0 ; i<p->height ; i++)
        {
            for (j=0 ; j<p->width ; j++, k++)
                scrap_texels[texnum][(y+i)*BLOCK_WIDTH + x + j] = p->data[k];
        }
        gl.gltexture = scrap_textures[texnum]; //johnfitz -- changed to an array
        //johnfitz -- no longer go from 0.01 to 0.99
        gl.sl = x/(float)BLOCK_WIDTH;
        gl.sh = (x+p->width)/(float)BLOCK_WIDTH;
        gl.tl = y/(float)BLOCK_WIDTH;
        gl.th = (y+p->height)/(float)BLOCK_WIDTH;
    }
    else
    {
        char texturename[64]; //johnfitz
        q_snprintf (texturename, sizeof(texturename), "%s:%s", WADFILENAME, name); //johnfitz
        
        offset = (src_offset_t)p - (src_offset_t)wad_base + sizeof(int)*2; //johnfitz
        
        gl.gltexture = TexMgr_LoadImage (NULL, texturename, p->width, p->height, SRC_INDEXED, p->data, WADFILENAME,
                                         offset, TEXPREF_ALPHA | TEXPREF_PAD | TEXPREF_NOPICMIP); //johnfitz -- TexMgr
        gl.sl = 0;
        gl.sh = (float)p->width/(float)TexMgr_PadConditional(p->width); //johnfitz
        gl.tl = 0;
        gl.th = (float)p->height/(float)TexMgr_PadConditional(p->height); //johnfitz
    }
    
    memcpy (p->data, &gl, sizeof(glpic_t));
    
    return p;
}

/*
 ================
 Draw_CachePic
 ================
 */
qpic_t    *Draw_CachePic (const char *path)
{
    cachepic_t    *pic;
    int            i;
    qpic_t        *dat;
    glpic_t        gl;
    
    for (pic=menu_cachepics, i=0 ; i<menu_numcachepics ; pic++, i++)
    {
        if (!strcmp (path, pic->name))
            return &pic->pic;
    }
    if (menu_numcachepics == MAX_CACHED_PICS)
        Sys_Error ("menu_numcachepics == MAX_CACHED_PICS");
    menu_numcachepics++;
    strcpy (pic->name, path);
    
    //
    // load the pic from disk
    //
    dat = (qpic_t *)COM_LoadTempFile (path, NULL);
    if (!dat)
        Sys_Error ("Draw_CachePic: failed to load %s", path);
    SwapPic (dat);
    
    // Translatable player picture storage used by the menu configuration dialog
    if (!strcmp (path, "gfx/menuplyr.lmp"))
        memcpy (menuplyr_pixels, dat->data, dat->width*dat->height);
    
    pic->pic.width = dat->width;
    pic->pic.height = dat->height;
    
    gl.gltexture = TexMgr_LoadImage (NULL, path, dat->width, dat->height, SRC_INDEXED, dat->data, path,
                                     sizeof(int)*2, TEXPREF_ALPHA | TEXPREF_PAD | TEXPREF_NOPICMIP); //johnfitz -- TexMgr
    gl.sl = 0;
    gl.sh = (float)dat->width/(float)TexMgr_PadConditional(dat->width); //johnfitz
    gl.tl = 0;
    gl.th = (float)dat->height/(float)TexMgr_PadConditional(dat->height); //johnfitz
    memcpy (pic->pic.data, &gl, sizeof(glpic_t));
    
    return &pic->pic;
}

/*
 ================
 Draw_MakePic -- johnfitz -- generate pics from internal data
 ================
 */
qpic_t *Draw_MakePic (const char *name, int width, int height, byte *data)
{
    int flags = TEXPREF_NEAREST | TEXPREF_ALPHA | TEXPREF_PERSIST | TEXPREF_NOPICMIP | TEXPREF_PAD;
    qpic_t        *pic;
    glpic_t        gl;
    
    pic = (qpic_t *) Hunk_Alloc (sizeof(qpic_t) - 4 + sizeof (glpic_t));
    pic->width = width;
    pic->height = height;
    
    gl.gltexture = TexMgr_LoadImage (NULL, name, width, height, SRC_INDEXED, data, "", (src_offset_t)data, flags);
    gl.sl = 0;
    gl.sh = (float)width/(float)TexMgr_PadConditional(width);
    gl.tl = 0;
    gl.th = (float)height/(float)TexMgr_PadConditional(height);
    memcpy (pic->data, &gl, sizeof(glpic_t));
    
    return pic;
}

//==============================================================================
//
//  INIT
//
//==============================================================================

/*
 ===============
 Draw_LoadPics -- johnfitz
 ===============
 */
void Draw_LoadPics (void)
{
    byte        *data;
    src_offset_t    offset;
    
    data = (byte *) W_GetLumpName ("conchars");
    if (!data) Sys_Error ("Draw_LoadPics: couldn't load conchars");
    offset = (src_offset_t)data - (src_offset_t)wad_base;
    char_texture = TexMgr_LoadImage (NULL, WADFILENAME":conchars", 128, 128, SRC_INDEXED, data,
                                     WADFILENAME, offset, TEXPREF_ALPHA | TEXPREF_NEAREST | TEXPREF_NOPICMIP | TEXPREF_CONCHARS);
    
    draw_disc = Draw_PicFromWad ("disc");
    draw_backtile = Draw_PicFromWad ("backtile");
}

/*
 ===============
 Draw_NewGame -- johnfitz
 ===============
 */
void Draw_NewGame (void)
{
    cachepic_t    *pic;
    int            i;
    
    // empty scrap and reallocate gltextures
    memset(scrap_allocated, 0, sizeof(scrap_allocated));
    memset(scrap_texels, 255, sizeof(scrap_texels));
    
    Scrap_Upload (); //creates 2 empty gltextures
    
    // reload wad pics
    W_LoadWadFile (); //johnfitz -- filename is now hard-coded for honesty
    Draw_LoadPics ();
    SCR_LoadPics ();
    Sbar_LoadPics ();
    
    // empty lmp cache
    for (pic = menu_cachepics, i = 0; i < menu_numcachepics; pic++, i++)
        pic->name[0] = 0;
    menu_numcachepics = 0;
}

/*
 ===============
 Draw_Init -- johnfitz -- rewritten
 ===============
 */
void Draw_Init (void)
{
    Cvar_RegisterVariable (&scr_conalpha);
    
    // clear scrap and allocate gltextures
    memset(scrap_allocated, 0, sizeof(scrap_allocated));
    memset(scrap_texels, 255, sizeof(scrap_texels));
    
    Scrap_Upload (); //creates 2 empty textures
    
    // create internal pics
    pic_ins = Draw_MakePic ("ins", 8, 9, &pic_ins_data[0][0]);
    pic_ovr = Draw_MakePic ("ovr", 8, 8, &pic_ovr_data[0][0]);
    pic_nul = Draw_MakePic ("nul", 8, 8, &pic_nul_data[0][0]);
    
    // load game pics
    Draw_LoadPics ();
}

//==============================================================================
//
//  2D DRAWING
//
//==============================================================================

/*
 ================
 Draw_CharacterQuad
 ================
 */
void Draw_CharacterQuad (int x, int y, char num)
{
    // Deprecated legacy immediate-mode vertex submission (glVertex2f) is omitted.
    // Character glyphs are batched via Draw_Character() -> R_Metal_Draw2DQuad().
    (void)x;
    (void)y;
    (void)num;
}

/*
 ================
 Draw_Character -- johnfitz -- modified to call Draw_CharacterQuad
 ================
 */
void Draw_Character (int x, int y, int num)
{
    num &= 255;
    if (num == 32)
        return;
    
    int row = num >> 4;
    int col = num & 15;
    
    float s1 = (float)col / 16.0f;
    float t1 = (float)row / 16.0f;
    float s2 = s1 + 0.0625f;
    float t2 = t1 + 0.0625f;
    
    // Validate font glyph texture presence and backing Metal resource
    {
        static bool s_fontChecked = false;
        if (!s_fontChecked) {
            s_fontChecked = true;
            if (!char_texture)
                MLog(MQ_LVL_ALWAYS, "ENG·HUD", "ERROR: char_texture is NULL — HUD fonts cannot be rendered");
            else if (!char_texture->metalTexture)
                MLog(MQ_LVL_ALWAYS, "ENG·HUD", "ERROR: char_texture '%s' %dx%d missing metalTexture — HUD fonts invisible",
                     char_texture->name, (int)char_texture->width, (int)char_texture->height);
            else
                MLog(MQ_LVL_DEV, "ENG·HUD", "char_texture '%s' %dx%d mtl=%p (OK)",
                     char_texture->name, (int)char_texture->width, (int)char_texture->height,
                     char_texture->metalTexture);
        }
    }
    
    simd_float4 color = {1.0f, 1.0f, 1.0f, 1.0f};
    void *texHandle = char_texture ? char_texture->metalTexture : NULL;
    
    R_Metal_Draw2DQuad((float)x, (float)y, 8.0f, 8.0f,
                       s1, t1, s2, t2,
                       color, texHandle);
}

/*
 ================
 Draw_String -- Render strings using Draw_Character quad batching
 ================
 */
void Draw_String (int x, int y, const char *str)
{
    if (y <= -8 || !str)
        return;
    
    while (*str)
    {
        if (*str != 32) // Skip space characters
            Draw_Character (x, y, *str);
        str++;
        x += 8;
    }
}

/*
 =============
 Draw_Pic -- Render textured quad with atlas UV mapping
 =============
 */
void Draw_Pic (int x, int y, qpic_t *pic)
{
    if (!pic)
        return;
    
    // In QuakeSpasm, pic->data encapsulates the glpic_t descriptor
    glpic_t *gl = (glpic_t *)pic->data;
    gltexture_t *gltex = gl ? gl->gltexture : NULL;
    void *texHandle = gltex ? gltex->metalTexture : NULL;
    
    if (!texHandle && notexture) {
        texHandle = notexture->metalTexture;
    }
    
    if (!texHandle) {
        return;
    }
    
    simd_float4 color = {1.0f, 1.0f, 1.0f, 1.0f};
    
    // Extract normalized UV coordinates from glpic_t (supporting atlas offsets and texture padding)
    float s1 = gl ? gl->sl : 0.0f;
    float t1 = gl ? gl->tl : 0.0f;
    float s2 = gl ? gl->sh : 1.0f;
    float t2 = gl ? gl->th : 1.0f;
    
    // Diagnostic logging for 2D image quads (monitors cursor and HUD element batching)
    if (MLog_Budget("ENG·PIC", 80))
        MLog(MQ_LVL_DEV, "ENG·PIC",
             "pic %ux%u at (%.1f,%.1f) uv=(%.3f,%.3f)-(%.3f,%.3f) tex=%p",
             pic->width, pic->height, (float)x, (float)y,
             s1, t1, s2, t2, texHandle);
    
    R_Metal_Draw2DQuad((float)x, (float)y,
                       (float)pic->width, (float)pic->height,
                       s1, t1, s2, t2,
                       color, texHandle);
}

/*
 =============
 Draw_TransPicTranslate -- johnfitz -- rewritten to use texmgr to do translation
 
 Only used for the player color selection menu
 =============
 */
void Draw_TransPicTranslate (int x, int y, qpic_t *pic, int top, int bottom)
{
    static int oldtop = -2;
    static int oldbottom = -2;
    
    if (top != oldtop || bottom != oldbottom)
    {
        glpic_t *p = (glpic_t *)pic->data;
        gltexture_t *glt = p->gltexture;
        oldtop = top;
        oldbottom = bottom;
        TexMgr_ReloadImage (glt, top, bottom);
    }
    Draw_Pic (x, y, pic);
}

/*
 ================
 Draw_ConsoleBackground -- johnfitz -- rewritten
 ================
 */
void Draw_ConsoleBackground (void)
{
    qpic_t *pic;
    float alpha;
    
    pic = Draw_CachePic ("gfx/conback.lmp");
    pic->width = vid.conwidth;
    pic->height = vid.conheight;
    
    alpha = (con_forcedup) ? 1.0f : scr_conalpha.value;
    
    GL_SetCanvas (CANVAS_CONSOLE);
    
    if (alpha > 0.0f)
    {
        // Console background transparency is submitted directly to the 2D pipeline
        Draw_Pic (0, 0, pic);
    }
}


/*
 =============
 Draw_TileClear -- Render tiled background pattern via 2D quad batching
 =============
 */
void Draw_TileClear (int x, int y, int w, int h)
{
    glpic_t *gl = draw_backtile ? (glpic_t *)draw_backtile->data : NULL;
    gltexture_t *gltex = gl ? gl->gltexture : NULL;
    void *texHandle = gltex ? gltex->metalTexture : NULL;
    
    if (!texHandle) return;
    
    simd_float4 color = {1.0f, 1.0f, 1.0f, 1.0f};
    
    R_Metal_Draw2DQuad((float)x, (float)y, (float)w, (float)h,
                       x / 64.0f, y / 64.0f,
                       (x + w) / 64.0f, (y + h) / 64.0f,
                       color, texHandle);
}

/*
 =============
 Draw_Fill
 
 Fills a box of pixels with a single color
 =============
 */
void Draw_Fill (int x, int y, int w, int h, int c, float alpha)
{
    byte *pal = (byte *)d_8to24table;
    c &= 255;
    
    simd_float4 color = {
        pal[c * 4 + 0] / 255.0f,
        pal[c * 4 + 1] / 255.0f,
        pal[c * 4 + 2] / 255.0f,
        alpha
    };
    
    // Pass NULL texture handle for solid color fill
    R_Metal_Draw2DQuad((float)x, (float)y, (float)w, (float)h,
                       0.0f, 0.0f, 1.0f, 1.0f,
                       color, NULL);
}

/*
 ================
 Draw_FadeScreen -- johnfitz -- revised
 ================
 */
void Draw_FadeScreen (void)
{
    GL_SetCanvas (CANVAS_DEFAULT);
    
    simd_float4 fadeColor = {0.0f, 0.0f, 0.0f, 0.5f};
    
    // Render translucent black overlay across the entire virtual canvas
    R_Metal_Draw2DQuad(0.0f, 0.0f, (float)glwidth, (float)glheight,
                       0.0f, 0.0f, 1.0f, 1.0f,
                       fadeColor, NULL);
    
    Sbar_Changed();
}

/*
 ================
 GL_SetCanvas -- Canvas viewport and orthographic projection management
 ================
 */
void GL_SetCanvas (canvastype newcanvas)
{
    extern vrect_t scr_vrect;
    float s;
    
    if (newcanvas == currentcanvas)
        return;
    
    currentcanvas = newcanvas;
    
    // Log canvas state transition for HUD scaling verification
    if (MLog_Budget("ENG·HUD-CANVAS", 15))
        MLog(MQ_LVL_DEV, "ENG·HUD", "GL_SetCanvas type=%d (gl=%dx%d con=%dx%d vid=%dx%d)",
             newcanvas, glwidth, glheight, vid.conwidth, vid.conheight, vid.width, vid.height);
    
    switch(newcanvas)
    {
        case CANVAS_DEFAULT:
            R_Metal_SetCanvas(0, glwidth, glheight, 0, glx, gly, glwidth, glheight);
            break;
        case CANVAS_CONSOLE:
            // Lock top-left origin at (0,0); drop-down console animation is handled by quad coordinates
            R_Metal_SetCanvas(0, vid.conwidth, vid.conheight, 0, glx, gly, glwidth, glheight);
            break;
        case CANVAS_MENU:
            s = q_min((float)glwidth / 320.0f, (float)glheight / 200.0f);
            // Automatic scaling (scr_menuscale <= 0): menu container targets proportional height against reference
            s = q_min(s, SCR_CanvasScaleRef(scr_menuscale.value, 800.0f));
            R_Metal_SetCanvas(0, 320, 200, 0,
                              glx + (glwidth - 320.0f * s) / 2.0f,
                              gly + (glheight - 200.0f * s) / 2.0f,
                              320.0f * s, 200.0f * s);
            break;
        case CANVAS_SBAR:
            // Status bar scaling unified with menu reference layout
            s = SCR_CanvasScaleRef(scr_sbarscale.value, 800.0f);
            if (s * 320.0f > (float)glwidth)
                s = (float)glwidth / 320.0f;   // Clamp to fit narrow windows
            if (cl.gametype == GAME_DEATHMATCH)
            {
                R_Metal_SetCanvas(0, glwidth / s, 48, 0,
                                  glx, gly + glheight - 48.0f * s,
                                  glwidth, 48.0f * s);
            }
            else
            {
                R_Metal_SetCanvas(0, 320, 48, 0,
                                  glx + (glwidth - 320.0f * s) / 2.0f,
                                  gly + glheight - 48.0f * s,
                                  320.0f * s, 48.0f * s);
            }
            break;
        case CANVAS_WARPIMAGE:
            R_Metal_SetCanvas(0, 128, 0, 128, glx, gly + glheight - gl_warpimagesize, gl_warpimagesize, gl_warpimagesize);
            break;
        case CANVAS_CROSSHAIR:
            // Crosshair canvas maps directly to physical viewport pixels around screen center.
            // Geometric crosshairs remain crisp across high magnification factors.
            R_Metal_SetCanvas(scr_vrect.width / -2.0f, scr_vrect.width / 2.0f,
                              scr_vrect.height / 2.0f, scr_vrect.height / -2.0f,
                              scr_vrect.x, glheight - scr_vrect.y - scr_vrect.height,
                              scr_vrect.width & ~1, scr_vrect.height & ~1);
            break;
        case CANVAS_BOTTOMLEFT:
            s = (float)glwidth / vid.conwidth;
            R_Metal_SetCanvas(0, 320, 200, 0, glx, gly, 320.0f * s, 200.0f * s);
            break;
        case CANVAS_BOTTOMRIGHT:
            s = (float)glwidth / vid.conwidth;
            R_Metal_SetCanvas(0, 320, 200, 0, glx + glwidth - 320.0f * s, gly, 320.0f * s, 200.0f * s);
            break;
        case CANVAS_TOPRIGHT:
            s = 1.0f;
            R_Metal_SetCanvas(0, 320, 200, 0, glx + glwidth - 320.0f * s, gly + glheight - 200.0f * s, 320.0f * s, 200.0f * s);
            break;
        default:
            Sys_Error ("GL_SetCanvas: bad canvas type");
    }
    
    // Validate effective canvas projection against physical viewport dimensions
    {
        float o[4], v[4];
        R_Metal_GetCanvasState(o, v);
        if (MLog_Budget("ENG·HUD-APPLIED", 15))
            MLog(MQ_LVL_DEV, "ENG·HUD",
                 "canvas applied: type=%d ortho=(%.0f..%.0f x %.0f..%.0f) "
                 "vp=(%.0f,%.0f %.0fx%.0f) px/unit=%.2f",
                 newcanvas, o[0], o[1], o[2], o[3],
                 v[0], v[1], v[2], v[3],
                 (o[1] - o[0]) > 0.0f ? v[2] / (o[1] - o[0]) : 0.0f);
    }
}

/*
 ================
 GL_Set2D -- johnfitz -- rewritten
 ================
 */
void GL_Set2D (void)
{
    // Lazy upload of modified scrap atlas textures:
    // Ensures status bar and HUD sub-textures packaged in scrap_texels are refreshed on GPU
    if (scrap_dirty)
        Scrap_Upload ();
    
    currentcanvas = CANVAS_INVALID;
    GL_SetCanvas (CANVAS_DEFAULT);
    
    // Forward window dimensions to the 2D orthographic projection matrix
    R_Metal_SetOrtho(0, vid.width, vid.height, 0);
}
