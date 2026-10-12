//
//  mq_pbr.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#import "mq_pbr.h"
#import "mq_internal.h"
#import "mq_log.h"

static id<MTLTexture> s_defaultNormalTex   = nil; // [128, 128, 255] -> vector [0, 0, 1]
static id<MTLTexture> s_defaultRMAOTex    = nil; // R=Roughness(200), G=Metallic(0), B=AO(255)
static id<MTLTexture> s_defaultEmissionTex = nil; // [0, 0, 0, 255]

static id<MTLTexture> Create1x1Texture(id<MTLDevice> device, uint8_t r, uint8_t g, uint8_t b, uint8_t a, NSString *label)
{
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:1
                                                                                   height:1
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    tex.label = label;
    
    uint8_t pixel[4] = { r, g, b, a };
    [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:pixel bytesPerRow:4];
    return tex;
}

void MQ_PBR_Init(id<MTLDevice> device)
{
    if (!device) return;
    
    // 1. Flat neutral normal: [0, 0, 1] in tangent space
    s_defaultNormalTex = Create1x1Texture(device, 128, 128, 255, 255, @"PBR Default Flat Normal");
    
    // 2. Standard dielectric: roughness ~0.78, 0 metallic, 1.0 AO
    s_defaultRMAOTex = Create1x1Texture(device, 200, 0, 255, 255, @"PBR Default RMAO");
    
    // 3. Zero emission (black)
    s_defaultEmissionTex = Create1x1Texture(device, 0, 0, 0, 255, @"PBR Default Black Emission");
    
    MLog(MQ_LVL_ALWAYS, "PBR", "default 1x1 fallback textures initialized (normal, rmao, emission)");
}

id<MTLTexture> MQ_PBR_GetDefaultNormalTexture(void)   { return s_defaultNormalTex; }
id<MTLTexture> MQ_PBR_GetDefaultRMAOTexture(void)     { return s_defaultRMAOTex; }
id<MTLTexture> MQ_PBR_GetDefaultEmissionTexture(void) { return s_defaultEmissionTex; }

void MQ_PBR_BindMaterialTextures(void *customNormal, void *customRMAO, void *customEmission)
{
    // Slot 2: Normal Map
    id<MTLTexture> normTex = customNormal ? (__bridge id<MTLTexture>)customNormal : s_defaultNormalTex;
    MQEncoder_SetFragmentTexture(normTex, 2);
    
    // Slot 3: Roughness / Metallic / AO
    id<MTLTexture> rmaoTex = customRMAO ? (__bridge id<MTLTexture>)customRMAO : s_defaultRMAOTex;
    MQEncoder_SetFragmentTexture(rmaoTex, 3);
    
    // Slot 4: Emission
    id<MTLTexture> emitTex = customEmission ? (__bridge id<MTLTexture>)customEmission : s_defaultEmissionTex;
    MQEncoder_SetFragmentTexture(emitTex, 4);
}
