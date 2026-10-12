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
// gl_warp.c -- procedural water warp animation support

#include "quakedef.h"

extern cvar_t r_drawflat;

// Preserved for configuration and mod compatibility
cvar_t r_oldwater = {"r_oldwater", "0", CVAR_ARCHIVE};
cvar_t r_waterquality = {"r_waterquality", "8", CVAR_NONE};
cvar_t r_waterwarp = {"r_waterwarp", "1", CVAR_NONE};
cvar_t gl_subdivide_size = {"gl_subdivide_size", "128", CVAR_ARCHIVE};

int gl_warpimagesize;
float load_subdivide_size;

/*
 ================
 GL_SubdivideSurface
 ================
 */
void GL_SubdivideSurface (msurface_t *fa)
{
    // Software polygon subdivision on CPU is omitted, significantly reducing
    // Hunk memory consumption during map load. Procedural liquid turbulence
    // (water, lava, teleporters) is computed analytically within Metal fragment shaders.
    (void)fa;
}

/*
 ================
 DrawWaterPoly
 ================
 */
void DrawWaterPoly (glpoly_t *p)
{
    // Legacy immediate-mode water poly dispatch omitted.
    // Liquid surfaces are batched via R_DrawTextureChains_Water() in r_world.c.
    (void)p;
}

/*
 =============
 R_UpdateWarpTextures
 =============
 */
void R_UpdateWarpTextures (void)
{
    // Per-frame software offscreen rendering and glCopyTexSubImage2D texture readback
    // are omitted. UV wave distortion is evaluated directly on GPU in Metal shaders
    // (Shaders.metal -> world_fragment_main and RTShaders.metal -> world_rt_fragment_main).
}
