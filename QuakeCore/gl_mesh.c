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
// gl_mesh.c: triangle model functions

#include "quakedef.h"


/*
 =================================================================
 
 ALIAS MODEL DISPLAY LIST GENERATION
 
 =================================================================
 */

static unsigned char    used[MAXALIASTRIS];

// The command list stores vertex counts and s/t texture coordinates
// valid across all animation poses
static int        commands[MAXALIASTRIS*7 + 1];
static int        numcommands;

// All frames have their vertices rearranged and expanded to match
// the order expected by the command list
static int        vertexorder[MAXALIASTRIS * 3];
static int        numorder;

static int        stripverts[MAXALIASTRIS + 2];
static int        striptris[MAXALIASTRIS];
static int        stripcount;

/*
 ================
 StripLength
 ================
 */
static int StripLength (int starttri, int startv)
{
    int            m1, m2;
    int            j;
    mtriangle_t    *last, *check;
    int            k;
    
    used[starttri] = 2;
    
    last = &triangles[starttri];
    
    stripverts[0] = last->vertindex[(startv)%3];
    stripverts[1] = last->vertindex[(startv+1)%3];
    stripverts[2] = last->vertindex[(startv+2)%3];
    
    striptris[0] = starttri;
    stripcount = 1;
    
    m1 = last->vertindex[(startv+2)%3];
    m2 = last->vertindex[(startv+1)%3];
    
    // Search for an adjacent triangle matching winding
nexttri:
    for (j=starttri+1, check=&triangles[starttri+1] ; j<pheader->numtris ; j++, check++)
    {
        if (check->facesfront != last->facesfront)
            continue;
        for (k=0 ; k<3 ; k++)
        {
            if (check->vertindex[k] != m1)
                continue;
            if (check->vertindex[ (k+1)%3 ] != m2)
                continue;
            
            // Triangle connects to current strip
            
            // If already claimed, terminate this tristrip
            if (used[j])
                goto done;
            
            // Update edge vertex indices
            if (stripcount & 1)
                m2 = check->vertindex[ (k+2)%3 ];
            else
                m1 = check->vertindex[ (k+2)%3 ];
            
            stripverts[stripcount+2] = check->vertindex[ (k+2)%3 ];
            striptris[stripcount] = j;
            stripcount++;
            
            used[j] = 2;
            goto nexttri;
        }
    }
done:
    
    // Clear temporary reservation flags
    for (j=starttri+1 ; j<pheader->numtris ; j++)
        if (used[j] == 2)
            used[j] = 0;
    
    return stripcount;
}

/*
 ===========
 FanLength
 ===========
 */
static int FanLength (int starttri, int startv)
{
    int        m1, m2;
    int        j;
    mtriangle_t    *last, *check;
    int        k;
    
    used[starttri] = 2;
    
    last = &triangles[starttri];
    
    stripverts[0] = last->vertindex[(startv)%3];
    stripverts[1] = last->vertindex[(startv+1)%3];
    stripverts[2] = last->vertindex[(startv+2)%3];
    
    striptris[0] = starttri;
    stripcount = 1;
    
    m1 = last->vertindex[(startv+0)%3];
    m2 = last->vertindex[(startv+2)%3];
    
    
    // Search for an adjacent triangle matching winding
nexttri:
    for (j=starttri+1, check=&triangles[starttri+1] ; j<pheader->numtris ; j++, check++)
    {
        if (check->facesfront != last->facesfront)
            continue;
        for (k=0 ; k<3 ; k++)
        {
            if (check->vertindex[k] != m1)
                continue;
            if (check->vertindex[ (k+1)%3 ] != m2)
                continue;
            
            // Triangle connects to current fan
            
            // If already claimed, terminate this trifan
            if (used[j])
                goto done;
            
            // Advance fan edge
            m2 = check->vertindex[ (k+2)%3 ];
            
            stripverts[stripcount+2] = m2;
            striptris[stripcount] = j;
            stripcount++;
            
            used[j] = 2;
            goto nexttri;
        }
    }
done:
    
    // Clear temporary reservation flags
    for (j=starttri+1 ; j<pheader->numtris ; j++)
        if (used[j] == 2)
            used[j] = 0;
    
    return stripcount;
}


/*
 ================
 BuildTris
 
 Generates a list of trifans or strips
 for the model, which holds for all poses
 ================
 */
static void BuildTris (void)
{
    int        i, j, k;
    int        startv;
    float    s, t;
    int        len, bestlen, besttype;
    int        bestverts[MAXALIASTRIS + 2];
    int        besttris[MAXALIASTRIS];
    int        type;
    
    //
    // Build triangle strips and fans
    //
    numorder = 0;
    numcommands = 0;
    memset (used, 0, sizeof(used));
    for (i = 0; i < pheader->numtris; i++)
    {
        // Pick an unused triangle and evaluate strip/fan candidates
        if (used[i])
            continue;
        
        bestlen = 0;
        besttype = 0;
        for (type = 0 ; type < 2 ; type++)
        {
            for (startv = 0; startv < 3; startv++)
            {
                if (type == 1)
                    len = StripLength (i, startv);
                else
                    len = FanLength (i, startv);
                if (len > bestlen)
                {
                    besttype = type;
                    bestlen = len;
                    for (j = 0; j < bestlen+2; j++)
                        bestverts[j] = stripverts[j];
                    for (j = 0; j < bestlen; j++)
                        besttris[j] = striptris[j];
                }
            }
        }
        
        // Mark the triangles in the selected strip as consumed
        for (j = 0; j < bestlen; j++)
            used[besttris[j]] = 1;
        
        if (besttype == 1)
            commands[numcommands++] = (bestlen+2);
        else
            commands[numcommands++] = -(bestlen+2);
        
        for (j = 0; j < bestlen+2; j++)
        {
            int        tmp;
            
            // Emit vertex index into the reorder buffer
            k = bestverts[j];
            vertexorder[numorder++] = k;
            
            // Emit normalized s/t coordinates into command stream
            s = stverts[k].s;
            t = stverts[k].t;
            if (!triangles[besttris[0]].facesfront && stverts[k].onseam)
                s += pheader->skinwidth / 2;    // Seam offset on back side
            s = (s + 0.5) / pheader->skinwidth;
            t = (t + 0.5) / pheader->skinheight;
            
            memcpy (&tmp, &s, 4);
            commands[numcommands++] = tmp;
            memcpy (&tmp, &t, 4);
            commands[numcommands++] = tmp;
        }
    }
    
    commands[numcommands++] = 0;        // End of command stream marker
    
    Con_DPrintf2 ("%3i tri %3i vert %3i cmd\n", pheader->numtris, numorder, numcommands);
}

static void GL_MakeAliasModelDisplayLists_VBO (qmodel_t *, aliashdr_t *);
static void GLMesh_LoadVertexBuffer (qmodel_t *m, const aliashdr_t *hdr);

/*
 ================
 GL_MakeAliasModelDisplayLists
 ================
 */
void GL_MakeAliasModelDisplayLists (qmodel_t *m, aliashdr_t *hdr)
{
    int        i, j;
    int            *cmds;
    trivertx_t    *verts;
    float    hscale, vscale; //johnfitz -- padded skins
    int        count; //johnfitz -- precompute texcoords for padded skins
    int        *loadcmds; //johnfitz
    aliashdr_t    *paliashdr = hdr;    // (aliashdr_t *)Mod_Extradata (m);
    
    //johnfitz -- padded skins
    hscale = (float)hdr->skinwidth/(float)TexMgr_PadConditional(hdr->skinwidth);
    vscale = (float)hdr->skinheight/(float)TexMgr_PadConditional(hdr->skinheight);
    //johnfitz
    
    //johnfitz -- generate meshes
    Con_DPrintf2 ("meshing %s...\n",m->name);
    BuildTris ();
    
    // Allocate and serialize alias model mesh data
    
    paliashdr->poseverts = numorder;
    
    cmds = (int *) Hunk_Alloc (numcommands * 4);
    paliashdr->commands = (byte *)cmds - (byte *)paliashdr;
    
    //johnfitz -- precompute texcoords for padded skins
    loadcmds = commands;
    while(1)
    {
        *cmds++ = count = *loadcmds++;
        
        if (!count)
            break;
        
        if (count < 0)
            count = -count;
        
        do
        {
            *(float *)cmds++ = hscale * (*(float *)loadcmds++);
            *(float *)cmds++ = vscale * (*(float *)loadcmds++);
        } while (--count);
    }
    //johnfitz
    
    verts = (trivertx_t *) Hunk_Alloc (paliashdr->numposes * paliashdr->poseverts * sizeof(trivertx_t));
    paliashdr->posedata = (byte *)verts - (byte *)paliashdr;
    for (i=0 ; i<paliashdr->numposes ; i++)
        for (j=0 ; j<numorder ; j++)
            *verts++ = poseverts[i][vertexorder[j]];
    
    // ericw
    GL_MakeAliasModelDisplayLists_VBO (m, paliashdr);
}

/*
 ================
 GL_MakeAliasModelDisplayLists_VBO
 ================
 */
static void GL_MakeAliasModelDisplayLists_VBO (qmodel_t *aliasmodel, aliashdr_t *paliashdr)
{
    // Redundant vertex and index staging for legacy OpenGL VBOs is omitted.
    // Preserves Hunk memory pools when loading maps with extensive model sets.
    // Model vertices are interpolated directly via SIMD NEON / GCD pipelines in r_alias.c.
    (void)aliasmodel;
    (void)paliashdr;
}

/*
 ================
 GLMesh_LoadVertexBuffers
 ================
 */
void GLMesh_LoadVertexBuffers (void)
{
    // Legacy OpenGL VBO allocations omitted.
}

/*
 ================
 GLMesh_DeleteVertexBuffers
 ================
 */
void GLMesh_DeleteVertexBuffers (void)
{
    // Release legacy OpenGL VBO references
    int j;
    qmodel_t *m;
    
    for (j = 1; j < MAX_MODELS; j++)
    {
        if (!(m = cl.model_precache[j])) break;
        if (m->type != mod_alias) continue;
        
        m->meshvbo = 0;
        m->meshindexesvbo = 0;
    }
}
