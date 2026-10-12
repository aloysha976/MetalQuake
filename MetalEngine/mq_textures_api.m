//
//  mq_textures_api.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#import "mq_internal.h"
#import "mq_log.h"

CFMutableSetRef g_validTextures = NULL;

void *R_Metal_CreateTexture(int width, int height, const void *rgbaData)
{
    return R_Metal_CreateTextureEx(width, height, rgbaData, NULL);
}

void *R_Metal_CreateTextureEx(int width, int height, const void *rgbaData, const char *dbgName)
{
    if (!g_device) R_Metal_Init();
    if (!g_device || width <= 0 || height <= 0 || !rgbaData) {
        MLog(MQ_LVL_ALWAYS, "GFX·TEX", "ERROR: create rejected (device=%p size=%dx%d data=%p)",
             g_device, width, height, rgbaData);
        return NULL;
    }
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    
    id<MTLTexture> texture = [g_device newTextureWithDescriptor:desc];
    if (!texture) return NULL;
    
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [texture replaceRegion:region mipmapLevel:0 withBytes:rgbaData bytesPerRow:width * 4];
    
    void *handle = (__bridge_retained void *)texture;
    
    // Detect completely black textures:
    // If all opaque pixels have RGB == 0, shaders will multiply the surface color by black regardless of lighting.
    // False positives for legitimately dark textures (*_glow masks, 'black') are suppressed.
    {
        bool suppressBlackWarning = dbgName &&
        (strstr(dbgName, "_glow") != NULL ||
         strstr(dbgName, "_GLOW") != NULL ||
         strstr(dbgName, "black") != NULL);
        
        const unsigned char *px = (const unsigned char *)rgbaData;
        long opaquePixels = 0, blackPixels = 0;
        for (long i = 0; i < (long)width * height; i++, px += 4) {
            if (px[3] > 0) {
                opaquePixels++;
                if (px[0] == 0 && px[1] == 0 && px[2] == 0)
                    blackPixels++;
            }
        }
        if (!suppressBlackWarning && opaquePixels > 0 && blackPixels == opaquePixels) {
            MLog(MQ_LVL_ALWAYS, "GFX·TEX", "WARNING: ALL-BLACK texture %s %dx%d mtl=%p "
                 "(all opaque pixels have RGB=0 — possible palette or data issue)",
                 dbgName ? dbgName : "?", width, height, handle);
        } else {
            MLog(MQ_LVL_DEV, "GFX·TEX", "create %s %dx%d mtl=%p (black %ld/%ld px)",
                 dbgName ? dbgName : "?", width, height, handle, blackPixels, opaquePixels);
        }
    }
    
    // Lazy initialization of the active texture tracking set
    if (!g_validTextures) {
        g_validTextures = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    }
    CFSetAddValue(g_validTextures, handle);
    
    return handle;
}

void R_Metal_FreeTexture(void *texHandle)
{
    if (!texHandle) return;
    
    MLog(MQ_LVL_DEV, "GFX·TEX", "free mtl=%p", texHandle);
    
    if (g_validTextures) {
        CFSetRemoveValue(g_validTextures, texHandle);
    }
    
    id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)texHandle;
    tex = nil;
}

// Updates a subregion of a shared-storage texture from CPU memory.
// Used by dynamic lightmap pipelines (R_UploadLightmap / R_RebuildAllLightmaps):
// replaceRegion on MTLStorageModeShared performs a direct row-wise memory copy on the CPU
// without stalling the GPU pipeline.
void R_Metal_UpdateTextureRegion(void *texHandle, int x, int y, int width, int height,
                                 const void *data, int bytesPerRow)
{
    if (!texHandle || !data || width <= 0 || height <= 0)
        return;
    
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texHandle;
    if (!tex)
        return;
    
    // Clamp region bounds to texture dimensions
    if (x < 0 || y < 0 || x + width > (int)tex.width || y + height > (int)tex.height) {
        MLog(MQ_LVL_ALWAYS, "GFX·TEX",
             "region out of bounds: req(%d,%d %dx%d) tex(%ux%u) — clipped",
             x, y, width, height, (unsigned)tex.width, (unsigned)tex.height);
        if (x < 0) { width += x; x = 0; }
        if (y < 0) { height += y; y = 0; }
        if (x + width > (int)tex.width)  width  = (int)tex.width  - x;
        if (y + height > (int)tex.height) height = (int)tex.height - y;
        if (width <= 0 || height <= 0)
            return;
    }
    
    MTLRegion region = MTLRegionMake2D(x, y, width, height);
    [tex replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:bytesPerRow];
}
