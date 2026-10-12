//
//  mq_pipelines.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Render pipeline state factory: UI (with and without depth attachment),
//  3D world, and classic gamma pass. Blended 3D variants reside in mq_world3d.m,
//  while HDR, bloom, and motion vector pipelines are handled in their respective modules.
//

#import <Metal/Metal.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "mq_rt.h"

id<MTLRenderPipelineState> g_uiPipelineState = nil;
id<MTLRenderPipelineState> g_worldPipelineState = nil;
id<MTLRenderPipelineState> g_gammaPipelineState = nil;

// UI pipeline state without depth attachment: used for the overlay pass rendered over
// post-processing effects (the UI overlay pass lacks a depth texture, which the standard UI PSO requires).
id<MTLRenderPipelineState> g_uiPipelineNoDepth = nil;

// Builds pipeline states rendering to the target render texture (scene or drawable).
// Invoked from the lazy initialization block in BeginFrame and upon toggling HDR mode (RGBA16Float).
void MQ_BuildCorePipelines(MTLPixelFormat targetFmt, id<MTLLibrary> defaultLibrary)
{
    NSError *error = nil;
    
    // --- 2D UI PIPELINE ---
    id<MTLFunction> uiVertexFunc = [defaultLibrary newFunctionWithName:@"ui_vertex_main"];
    id<MTLFunction> uiFragmentFunc = [defaultLibrary newFunctionWithName:@"ui_fragment_main"];
    
    if (!uiVertexFunc || !uiFragmentFunc) {
        printf("[Metal Error] Could not find 2D UI shader functions in defaultLibrary!\n");
        return;
    }
    
    MTLRenderPipelineDescriptor *uiPipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    uiPipelineDesc.label = @"Quake 2D UI Pipeline";
    uiPipelineDesc.vertexFunction = uiVertexFunc;
    uiPipelineDesc.fragmentFunction = uiFragmentFunc;
    uiPipelineDesc.colorAttachments[0].pixelFormat = targetFmt;
    uiPipelineDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    
    uiPipelineDesc.colorAttachments[0].blendingEnabled = YES;
    uiPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    uiPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    uiPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    uiPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    uiPipelineDesc.rasterSampleCount = MQ_PSOSampleCount();
    g_uiPipelineState = [g_device newRenderPipelineStateWithDescriptor:uiPipelineDesc error:&error];
    if (!g_uiPipelineState || error) {
        printf("[Metal Error] Failed to create 2D UI Pipeline (%d): %s\n",
               (int)targetFmt, error ? [[error localizedDescription] UTF8String] : "Unknown error");
    }
    
    // Equivalent 2D UI pipeline without depth attachment: the post-FX overlay pass renders
    // directly to the drawable without a depth attachment, which would fail pipeline validation
    // if depthAttachmentPixelFormat were set.
    {
        MTLRenderPipelineDescriptor *uiNoDepth = [[MTLRenderPipelineDescriptor alloc] init];
        uiNoDepth.label = @"Quake 2D UI Pipeline (no depth, post-FX overlay)";
        uiNoDepth.vertexFunction = uiVertexFunc;
        uiNoDepth.fragmentFunction = uiFragmentFunc;
        // The overlay pass renders directly into the drawable target (BGRA8 / RGBA16F-EDR)
        // rather than the scene texture, avoiding PSO-to-attachment format mismatches.
        uiNoDepth.colorAttachments[0].pixelFormat =
        g_edrActive ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
        uiNoDepth.colorAttachments[0].blendingEnabled = YES;
        uiNoDepth.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        uiNoDepth.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        uiNoDepth.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        uiNoDepth.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        
        uiNoDepth.rasterSampleCount = 1; // The overlay renders to the drawable, which does not support MSAA
        g_uiPipelineNoDepth = [g_device newRenderPipelineStateWithDescriptor:uiNoDepth error:&error];
        if (!g_uiPipelineNoDepth || error) {
            printf("[Metal Error] Failed to create UI-noDepth Pipeline (%d): %s\n",
               (int)targetFmt, error ? [[error localizedDescription] UTF8String] : "?");
        }
    }
    
    // --- 3D WORLD PIPELINE ---
    id<MTLFunction> worldVertexFunc = [defaultLibrary newFunctionWithName:@"world_vertex_main"];
    id<MTLFunction> worldFragmentFunc = [defaultLibrary newFunctionWithName:@"world_fragment_main"];
    
    if (worldVertexFunc && worldFragmentFunc) {
        MTLRenderPipelineDescriptor *worldPipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
        worldPipelineDesc.label = @"Quake 3D World Pipeline";
        worldPipelineDesc.vertexFunction = worldVertexFunc;
        worldPipelineDesc.fragmentFunction = worldFragmentFunc;
        worldPipelineDesc.colorAttachments[0].pixelFormat = targetFmt;
        worldPipelineDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        worldPipelineDesc.colorAttachments[0].blendingEnabled = NO;
        
        worldPipelineDesc.rasterSampleCount = MQ_PSOSampleCount();
        NSError *worldError = nil;
        g_worldPipelineState = [g_device newRenderPipelineStateWithDescriptor:worldPipelineDesc error:&worldError];
        if (!g_worldPipelineState) {
            printf("[Metal Error] Failed to create 3D World Pipeline: %s\n",
                   worldError ? [[worldError localizedDescription] UTF8String] : "Unknown error");
        }
    }
    
    // Hardware ray tracing pipeline compilation matching scene format
    MQ_RT_BuildPipeline(targetFmt, defaultLibrary);
}

// Classic gamma/contrast post-process pass (vid_gamma / vid_contrast when r_hdr = 0).
// Always BGRA8: utilized strictly when both scene and drawable use BGRA8Unorm.
// HDR mode builds its dedicated tonemapping pipeline in mq_hdr_edr.m.
void MQ_Pipelines_BuildGamma(id<MTLLibrary> defaultLibrary)
{
    if (!g_device || !defaultLibrary)
        return;
    
    MTLRenderPipelineDescriptor *gammaPipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    gammaPipelineDesc.label = @"Quake Gamma Post-Process Pipeline";
    gammaPipelineDesc.vertexFunction = [defaultLibrary newFunctionWithName:@"gamma_vertex_main"];
    gammaPipelineDesc.fragmentFunction = [defaultLibrary newFunctionWithName:@"gamma_fragment_main"];
    gammaPipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    gammaPipelineDesc.colorAttachments[0].blendingEnabled = NO;
    
    NSError *gammaError = nil;
    g_gammaPipelineState = [g_device newRenderPipelineStateWithDescriptor:gammaPipelineDesc error:&gammaError];
    if (!g_gammaPipelineState) {
        printf("[Metal Error] Failed to create Gamma Pipeline: %s\n",
               gammaError ? [[gammaError localizedDescription] UTF8String] : "Unknown error");
    }
}

// Lazy initialization of core pipelines matching the target format:
// Invoked from BeginFrame on the initial frame to prevent redundant PSO recompilation at startup.
void MQ_Pipelines_LazyBuildCore(MTLPixelFormat targetFmt)
{
    if (g_uiPipelineState && g_worldPipelineState)
        return;
    
    id<MTLLibrary> lib = [g_device newDefaultLibrary];
    if (lib)
        MQ_BuildCorePipelines(targetFmt, lib);
    R_Metal_RebuildBlended3DPipelines(targetFmt);
}
