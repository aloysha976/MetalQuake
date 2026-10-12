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

#ifndef _GL_TEXMAN_H
#define _GL_TEXMAN_H

// gl_texmgr.h -- FitzQuake texture manager. Manages GPU texture resources.

#define TEXPREF_NONE            0x0000
#define TEXPREF_MIPMAP            0x0001    // Generate mipmaps
// TEXPREF_NEAREST and TEXPREF_LINEAR are mutually exclusive with TEXPREF_MIPMAP
#define TEXPREF_LINEAR            0x0002    // Force linear filtering
#define TEXPREF_NEAREST            0x0004    // Force nearest-neighbor filtering
#define TEXPREF_ALPHA            0x0008    // Enable alpha channel
#define TEXPREF_PAD                0x0010    // Pad dimensions to power of two
#define TEXPREF_PERSIST            0x0020    // Persistent resource (never freed)
#define TEXPREF_OVERWRITE        0x0040    // Overwrite existing texture with identical name
#define TEXPREF_NOPICMIP        0x0080    // Bypass mipmap reduction (load at full resolution)
#define TEXPREF_FULLBRIGHT        0x0100    // Use fullbright palette mask
#define TEXPREF_NOBRIGHT        0x0200    // Use nobright palette mask
#define TEXPREF_CONCHARS        0x0400    // Use conchars palette
#define TEXPREF_WARPIMAGE        0x0800    // Procedural warp buffer flag

enum srcformat {SRC_INDEXED, SRC_LIGHTMAP, SRC_RGBA, SRC_INDEXED_PALETTE};

typedef uintptr_t src_offset_t;

typedef struct gltexture_s {
    // Managed by texture manager
    GLuint                texnum;            // Synthetic texture UID for Quake codebase compatibility
    void                *metalTexture;    // Native id<MTLTexture> handle
    struct gltexture_s    *next;
    qmodel_t            *owner;
    // Managed by image loader
    char                name[64];
    unsigned int        width;            // Render target / GPU texture width
    unsigned int        height;            // Render target / GPU texture height
    unsigned int        flags;
    char                source_file[MAX_QPATH]; // Relative path to asset source, or empty if memory-backed
    src_offset_t        source_offset;    // Byte offset into file or memory address pointer
    enum srcformat        source_format;    // Pixel encoding format (indexed, lightmap, or rgba)
    unsigned int        source_width;    // Native width in source data
    unsigned int        source_height;    // Native height in source data
    unsigned short        source_crc;        // CRC calculated prior to texture processing
    signed char            shirt;            // Shirt translation color (0-13), or -1 if unmapped
    signed char            pants;            // Pants translation color (0-13), or -1 if unmapped
    // Render telemetry
    int                    visframe;        // Matches r_framecount when bound during active frame
} gltexture_t;

extern gltexture_t *notexture;
extern gltexture_t *nulltexture;

extern unsigned int d_8to24table[256];
extern unsigned int d_8to24table_fbright[256];
extern unsigned int d_8to24table_nobright[256];
extern unsigned int d_8to24table_conchars[256];

// TEXTURE MANAGER

float TexMgr_FrameUsage (void);
gltexture_t *TexMgr_FindTexture (qmodel_t *owner, const char *name);
gltexture_t *TexMgr_NewTexture (void);
void TexMgr_FreeTexture (gltexture_t *kill);
void TexMgr_FreeTextures (unsigned int flags, unsigned int mask);
void TexMgr_FreeTexturesForOwner (qmodel_t *owner);
void TexMgr_NewGame (void);
void TexMgr_Init (void);
void TexMgr_DeleteTextureObjects (void);

// IMAGE LOADING
gltexture_t *TexMgr_LoadImage (qmodel_t *owner, const char *name, int width, int height, enum srcformat format,
                               byte *data, const char *source_file, src_offset_t source_offset, unsigned flags);
void TexMgr_ReloadImage (gltexture_t *glt, int shirt, int pants);
void TexMgr_ReloadImages (void);
void TexMgr_ReloadNobrightImages (void);

int TexMgr_Pad(int s);
int TexMgr_SafeTextureSize (int s);
int TexMgr_PadConditional (int s);

// TEXTURE BINDING & PIPELINE SYNCHRONIZATION

void GL_SelectTexture (GLenum target);
void GL_DisableMultitexture (void);
void GL_EnableMultitexture (void);
void GL_Bind (gltexture_t *texture);        // Binds texture to 2D UI pipeline (R_Metal_BindTexture2D)
void GL_ClearBindings (void);

#endif    /* _GL_TEXMAN_H */
