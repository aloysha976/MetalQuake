//
//  mq_rt.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#import "mq_rt.h"
#import "mq_internal.h"
#import "mq_log.h"

static bool s_rtHardwareSupported = false;
static id<MTLDevice> s_rtDevice = nil;

void MQ_RT_Init(id<MTLDevice> device)
{
    s_rtDevice = device;
    if (!device) {
        s_rtHardwareSupported = false;
        return;
    }
    
    // Verify hardware ray tracing support (Apple 9 GPU family / macOS 14+)
    if (@available(macOS 14.0, *)) {
        s_rtHardwareSupported = [device supportsFamily:MTLGPUFamilyApple9] && [device supportsRaytracing];
    } else {
        s_rtHardwareSupported = false;
    }
    
    MLog(MQ_LVL_ALWAYS, "RT", "Hardware Ray Tracing: %s (Device: %s)",
         s_rtHardwareSupported ? "ENABLED (Apple Silicon RT Core)" : "UNSUPPORTED",
         device.name.UTF8String);
}

bool MQ_RT_IsSupported(void)
{
    return s_rtHardwareSupported;
}

bool MQ_RT_IsEnabled(void)
{
    return s_rtHardwareSupported && R_RT_IsEnabled();
}

// ======================================================================
// MetalRT Hardware Acceleration Structures (BLAS + TLAS)
// ======================================================================

static id<MTLAccelerationStructure> s_worldBLAS = nil;
static id<MTLAccelerationStructure> s_worldTLAS = nil;
static id<MTLBuffer> s_worldVertexBuffer = nil;
static id<MTLBuffer> s_instanceDescriptorBuffer = nil;
static uint32_t s_worldTriangleCount = 0;

static id<MTLRenderPipelineState> s_worldRTPipeline = nil;
static id<MTLRenderPipelineState> s_worldStaticRTPipeline = nil;

void MQ_RT_BuildPipeline(MTLPixelFormat targetFmt, id<MTLLibrary> defaultLibrary)
{
    if (!s_rtHardwareSupported || !defaultLibrary) {
        s_worldRTPipeline = nil;
        s_worldStaticRTPipeline = nil;
        return;
    }
    
    id<MTLFunction> vertFunc = [defaultLibrary newFunctionWithName:@"world_vertex_main"];
    id<MTLFunction> fragFunc = [defaultLibrary newFunctionWithName:@"world_rt_fragment_main"];
    id<MTLFunction> staticFragFunc = [defaultLibrary newFunctionWithName:@"world_static_rt_fragment_main"];
    
    NSError *err = nil;
    
    // 1. Classic forward ray-traced pipeline (bmodels / dynamic geometry fallback)
    if (vertFunc && fragFunc) {
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label = @"Quake RT World Pipeline (Fallback / Bmodels)";
        desc.vertexFunction = vertFunc;
        desc.fragmentFunction = fragFunc;
        desc.colorAttachments[0].pixelFormat = targetFmt;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        desc.colorAttachments[0].blendingEnabled = NO;
        desc.rasterSampleCount = MQ_PSOSampleCount();
        
        s_worldRTPipeline = [s_rtDevice newRenderPipelineStateWithDescriptor:desc error:&err];
    }
    
    // 2. Monolithic static world bindless pipeline with MetalRT
    if (vertFunc && staticFragFunc) {
        MTLRenderPipelineDescriptor *sDesc = [[MTLRenderPipelineDescriptor alloc] init];
        sDesc.label = @"Quake RT World Static Bindless Pipeline (1 Draw Call)";
        sDesc.vertexFunction = vertFunc;
        sDesc.fragmentFunction = staticFragFunc;
        sDesc.colorAttachments[0].pixelFormat = targetFmt;
        sDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        sDesc.colorAttachments[0].blendingEnabled = NO;
        sDesc.rasterSampleCount = MQ_PSOSampleCount();
        
        s_worldStaticRTPipeline = [s_rtDevice newRenderPipelineStateWithDescriptor:sDesc error:&err];
        if (s_worldStaticRTPipeline) {
            MLog(MQ_LVL_ALWAYS, "RT", "RT World Static Bindless Pipeline created successfully");
        }
    }
}

id<MTLRenderPipelineState> MQ_RT_GetWorldPipeline(void)
{
    return s_worldRTPipeline;
}

id<MTLRenderPipelineState> MQ_RT_GetStaticWorldPipeline(void)
{
    return s_worldStaticRTPipeline;
}

void MQ_RT_BindResources(id<MTLRenderCommandEncoder> encoder)
{
    if (!encoder || !s_worldTLAS || !s_worldBLAS)
        return;
    
    // 1. Bind TLAS to buffer slot 2 of the fragment stage
    [encoder setFragmentAccelerationStructure:s_worldTLAS atBufferIndex:2];
    
    // 2. Declare resource residency for BLAS and TLAS (required by Metal Ray Tracing)
    [encoder useResource:s_worldBLAS usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [encoder useResource:s_worldTLAS usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    if (s_worldVertexBuffer) {
        [encoder useResource:s_worldVertexBuffer usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    }
}

void MQ_RT_ClearWorldBVH(void)
{
    s_worldBLAS = nil;
    s_worldTLAS = nil;
    s_worldVertexBuffer = nil;
    s_instanceDescriptorBuffer = nil;
    s_worldTriangleCount = 0;
}

id<MTLAccelerationStructure> MQ_RT_GetWorldTLAS(void)
{
    return s_worldTLAS;
}

void MQ_RT_BuildWorldBVH_ZeroCopy(id<MTLBuffer> worldVBO, uint32_t opaqueTriangleCount)
{
    if (!s_rtHardwareSupported || !MQ_RT_IsEnabled() || !s_rtDevice || !worldVBO || opaqueTriangleCount == 0) {
        MQ_RT_ClearWorldBVH();
        return;
    }
    
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    MQ_RT_ClearWorldBVH();
    
    // 1. Reference the static world VBO directly without additional memory allocations
    s_worldVertexBuffer = worldVBO;
    
    // 2. Configure BLAS geometry descriptor (Zero-Copy from MetalWorldVertex array, offset 0, stride sizeof(MetalWorldVertex))
    MTLAccelerationStructureTriangleGeometryDescriptor *geomDesc =
    [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    geomDesc.vertexBuffer = s_worldVertexBuffer;
    geomDesc.vertexBufferOffset = 0;
    geomDesc.vertexStride = sizeof(MetalWorldVertex);
    geomDesc.triangleCount = opaqueTriangleCount;
    geomDesc.opaque = YES;
    
    MTLPrimitiveAccelerationStructureDescriptor *blasDesc =
    [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    blasDesc.geometryDescriptors = @[ geomDesc ];
    
    // Compute required memory sizes for BLAS construction
    MTLAccelerationStructureSizes blasSizes = [s_rtDevice accelerationStructureSizesWithDescriptor:blasDesc];
    s_worldBLAS = [s_rtDevice newAccelerationStructureWithSize:blasSizes.accelerationStructureSize];
    s_worldBLAS.label = @"MQ RT World BLAS (Zero-Copy)";
    
    id<MTLBuffer> blasScratch = [s_rtDevice newBufferWithLength:blasSizes.buildScratchBufferSize
                                                        options:MTLResourceStorageModePrivate];
    
    // 3. Configure instance descriptor for TLAS using an identity transform matrix
    MTLAccelerationStructureInstanceDescriptor inst;
    memset(&inst, 0, sizeof(inst));
    inst.transformationMatrix.columns[0] = (MTLPackedFloat3){ 1.0f, 0.0f, 0.0f };
    inst.transformationMatrix.columns[1] = (MTLPackedFloat3){ 0.0f, 1.0f, 0.0f };
    inst.transformationMatrix.columns[2] = (MTLPackedFloat3){ 0.0f, 0.0f, 1.0f };
    inst.transformationMatrix.columns[3] = (MTLPackedFloat3){ 0.0f, 0.0f, 0.0f };
    inst.options = MTLAccelerationStructureInstanceOptionOpaque;
    inst.mask = 0xFF;
    inst.accelerationStructureIndex = 0;
    
    s_instanceDescriptorBuffer = [s_rtDevice newBufferWithBytes:&inst
                                                         length:sizeof(inst)
                                                        options:MTLResourceStorageModeShared];
    s_instanceDescriptorBuffer.label = @"MQ RT Instance Descriptors";
    
    MTLInstanceAccelerationStructureDescriptor *tlasDesc =
    [MTLInstanceAccelerationStructureDescriptor descriptor];
    tlasDesc.instancedAccelerationStructures = @[ s_worldBLAS ];
    tlasDesc.instanceCount = 1;
    tlasDesc.instanceDescriptorBuffer = s_instanceDescriptorBuffer;
    
    MTLAccelerationStructureSizes tlasSizes = [s_rtDevice accelerationStructureSizesWithDescriptor:tlasDesc];
    s_worldTLAS = [s_rtDevice newAccelerationStructureWithSize:tlasSizes.accelerationStructureSize];
    s_worldTLAS.label = @"MQ RT World TLAS";
    
    id<MTLBuffer> tlasScratch = [s_rtDevice newBufferWithLength:tlasSizes.buildScratchBufferSize
                                                        options:MTLResourceStorageModePrivate];
    
    // 4. Encode acceleration structure build commands on the GPU
    id<MTLCommandBuffer> cb = [g_commandQueue commandBuffer];
    cb.label = @"MQ RT Build Acceleration Structures (Zero-Copy)";
    
    id<MTLAccelerationStructureCommandEncoder> encoder = [cb accelerationStructureCommandEncoder];
    [encoder buildAccelerationStructure:s_worldBLAS
                             descriptor:blasDesc
                          scratchBuffer:blasScratch
                    scratchBufferOffset:0];
    
    [encoder buildAccelerationStructure:s_worldTLAS
                             descriptor:tlasDesc
                          scratchBuffer:tlasScratch
                    scratchBufferOffset:0];
    [encoder endEncoding];
    
    [cb commit];
    [cb waitUntilCompleted];
    
    s_worldTriangleCount = opaqueTriangleCount;
    double dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    MLog(MQ_LVL_ALWAYS, "RT", "World BVH built (Zero-Copy): %u triangles in %.2f ms (BLAS: %.1f KB, TLAS: %.1f KB)",
         opaqueTriangleCount, dtMs,
         (double)blasSizes.accelerationStructureSize / 1024.0,
         (double)tlasSizes.accelerationStructureSize / 1024.0);
}

void MQ_RT_BuildWorldBVH(const simd_float3 *triVertices, uint32_t triangleCount)
{
    if (!s_rtHardwareSupported || !MQ_RT_IsEnabled() || !s_rtDevice || !triVertices || triangleCount == 0) {
        MQ_RT_ClearWorldBVH();
        return;
    }
    
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    MQ_RT_ClearWorldBVH();
    
    // 1. Allocate triangle vertex buffer for world geometry
    NSUInteger vbSize = triangleCount * 3 * sizeof(simd_float3);
    s_worldVertexBuffer = [s_rtDevice newBufferWithBytes:triVertices
                                                  length:vbSize
                                                 options:MTLResourceStorageModeShared];
    s_worldVertexBuffer.label = @"MQ RT World Triangles";
    
    // 2. Configure BLAS geometry descriptor
    MTLAccelerationStructureTriangleGeometryDescriptor *geomDesc =
    [MTLAccelerationStructureTriangleGeometryDescriptor descriptor];
    geomDesc.vertexBuffer = s_worldVertexBuffer;
    geomDesc.vertexStride = sizeof(simd_float3);
    geomDesc.triangleCount = triangleCount;
    geomDesc.opaque = YES;
    
    MTLPrimitiveAccelerationStructureDescriptor *blasDesc =
    [MTLPrimitiveAccelerationStructureDescriptor descriptor];
    blasDesc.geometryDescriptors = @[ geomDesc ];
    
    // Compute required memory sizes for BLAS construction
    MTLAccelerationStructureSizes blasSizes = [s_rtDevice accelerationStructureSizesWithDescriptor:blasDesc];
    s_worldBLAS = [s_rtDevice newAccelerationStructureWithSize:blasSizes.accelerationStructureSize];
    s_worldBLAS.label = @"MQ RT World BLAS";
    
    id<MTLBuffer> blasScratch = [s_rtDevice newBufferWithLength:blasSizes.buildScratchBufferSize
                                                        options:MTLResourceStorageModePrivate];
    
    // 3. Configure instance descriptor for TLAS using an identity transform matrix
    MTLAccelerationStructureInstanceDescriptor inst;
    memset(&inst, 0, sizeof(inst));
    inst.transformationMatrix.columns[0] = (MTLPackedFloat3){ 1.0f, 0.0f, 0.0f };
    inst.transformationMatrix.columns[1] = (MTLPackedFloat3){ 0.0f, 1.0f, 0.0f };
    inst.transformationMatrix.columns[2] = (MTLPackedFloat3){ 0.0f, 0.0f, 1.0f };
    inst.transformationMatrix.columns[3] = (MTLPackedFloat3){ 0.0f, 0.0f, 0.0f };
    inst.options = MTLAccelerationStructureInstanceOptionOpaque;
    inst.mask = 0xFF;
    inst.accelerationStructureIndex = 0;
    
    s_instanceDescriptorBuffer = [s_rtDevice newBufferWithBytes:&inst
                                                         length:sizeof(inst)
                                                        options:MTLResourceStorageModeShared];
    s_instanceDescriptorBuffer.label = @"MQ RT Instance Descriptors";
    
    MTLInstanceAccelerationStructureDescriptor *tlasDesc =
    [MTLInstanceAccelerationStructureDescriptor descriptor];
    tlasDesc.instancedAccelerationStructures = @[ s_worldBLAS ];
    tlasDesc.instanceCount = 1;
    tlasDesc.instanceDescriptorBuffer = s_instanceDescriptorBuffer;
    
    MTLAccelerationStructureSizes tlasSizes = [s_rtDevice accelerationStructureSizesWithDescriptor:tlasDesc];
    s_worldTLAS = [s_rtDevice newAccelerationStructureWithSize:tlasSizes.accelerationStructureSize];
    s_worldTLAS.label = @"MQ RT World TLAS";
    
    id<MTLBuffer> tlasScratch = [s_rtDevice newBufferWithLength:tlasSizes.buildScratchBufferSize
                                                        options:MTLResourceStorageModePrivate];
    
    // 4. Encode acceleration structure build commands on the GPU
    id<MTLCommandBuffer> cb = [g_commandQueue commandBuffer];
    cb.label = @"MQ RT Build Acceleration Structures";
    
    id<MTLAccelerationStructureCommandEncoder> encoder = [cb accelerationStructureCommandEncoder];
    [encoder buildAccelerationStructure:s_worldBLAS
                             descriptor:blasDesc
                          scratchBuffer:blasScratch
                    scratchBufferOffset:0];
    
    [encoder buildAccelerationStructure:s_worldTLAS
                             descriptor:tlasDesc
                          scratchBuffer:tlasScratch
                    scratchBufferOffset:0];
    [encoder endEncoding];
    
    [cb commit];
    [cb waitUntilCompleted]; // Synchronize during map load
    
    s_worldTriangleCount = triangleCount;
    double dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    MLog(MQ_LVL_ALWAYS, "RT", "World BVH built: %u triangles in %.2f ms (BLAS: %.1f KB, TLAS: %.1f KB)",
         triangleCount, dtMs,
         (double)blasSizes.accelerationStructureSize / 1024.0,
         (double)tlasSizes.accelerationStructureSize / 1024.0);
}
