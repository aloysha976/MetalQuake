//
//  mq_pbr.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  PBR material subsystem: manages fallback textures
//  and binds PBR material maps to Metal pipeline stages.
//

#ifndef mq_pbr_h
#define mq_pbr_h

#import <Metal/Metal.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initializes procedural 1x1 fallback textures (invoked from R_Metal_Init)
void MQ_PBR_Init(id<MTLDevice> device);

// Accessors for default fallback texture resources
id<MTLTexture> MQ_PBR_GetDefaultNormalTexture(void);
id<MTLTexture> MQ_PBR_GetDefaultRMAOTexture(void);
id<MTLTexture> MQ_PBR_GetDefaultEmissionTexture(void);

// Binds PBR material textures to active fragment encoder slots (slots 2, 3, 4)
void MQ_PBR_BindMaterialTextures(void *customNormal, void *customRMAO, void *customEmission);

#ifdef __cplusplus
}
#endif

#endif /* mq_pbr_h */
