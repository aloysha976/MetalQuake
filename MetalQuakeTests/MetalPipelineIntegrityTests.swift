//
//  MetalPipelineIntegrityTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Testing
import Metal
import Foundation
@testable import MetalQuake

@Suite("Проверка целостности графических пайплайнов и шейдеров Metal 3")
struct MetalPipelineIntegrityTests {
    private let device: MTLDevice
    private let library: MTLLibrary
    
    init() throws {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            throw TestError.metalDeviceUnavailable
        }
        self.device = defaultDevice
        self.library = try Self.loadShaderLibrary(device: defaultDevice)
    }
    
    enum TestError: Error {
        case metalDeviceUnavailable
        case shaderLibraryNotFound
    }
    
    // MARK: - Загрузчик библиотеки шейдеров
    
    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        let candidateBundles = [
            Bundle.main,
            Bundle(for: LauncherEngine.self),
            Bundle(identifier: "com.alexeychernyak.MetalQuake")
        ].compactMap { $0 }
        
        for bundle in candidateBundles {
            if let lib = try? device.makeDefaultLibrary(bundle: bundle) {
                return lib
            }
            if let url = bundle.url(forResource: "default", withExtension: "metallib"),
               let lib = try? device.makeLibrary(URL: url) {
                return lib
            }
        }
        
        if let defaultLib = device.makeDefaultLibrary() {
            return defaultLib
        }
        
        throw TestError.shaderLibraryNotFound
    }
    
    // MARK: - 1. Проверка наличия всех шейдерных точек входа
    
    @Test(
        "Проверка регистрации всех точек входа Shaders.metal",
        arguments: [
            "ui_vertex_main",
            "ui_fragment_main",
            "world_vertex_main",
            "world_fragment_main",
            "gamma_vertex_main",
            "gamma_fragment_main",
            "postprocess_fragment_main",
            "brightpass_fragment_main",
            "blur9_fragment_main",
            "motion_fragment_main"
        ]
    )
    func testShaderFunctionsExist(functionName: String) {
        let function = library.makeFunction(name: functionName)
        #expect(function != nil, "Шейдерная функция '\(functionName)' отсутствует в собранной MTLLibrary")
    }
    
    // MARK: - 2. Пайплайны 2D UI (Классический с Depth и Overlay без Depth)
    
    @Test(
        "Сборка 2D UI пайплайнов под SDR (BGRA8) и HDR (RGBA16F)",
        arguments: [
            MTLPixelFormat.bgra8Unorm,
            MTLPixelFormat.rgba16Float
        ]
    )
    func testUIPipelineStateCreation(pixelFormat: MTLPixelFormat) throws {
        guard let vertFunc = library.makeFunction(name: "ui_vertex_main"),
              let fragFunc = library.makeFunction(name: "ui_fragment_main") else {
            Issue.record("Не найдены шейдеры 2D UI")
            return
        }
        
        // 1. Стандартный 2D UI с Depth32Float_Stencil8
        let uiDesc = MTLRenderPipelineDescriptor()
        uiDesc.label = "Test Quake 2D UI"
        uiDesc.vertexFunction = vertFunc
        uiDesc.fragmentFunction = fragFunc
        uiDesc.colorAttachments[0].pixelFormat = pixelFormat
        uiDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        
        uiDesc.colorAttachments[0].isBlendingEnabled = true
        uiDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        uiDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        uiDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        uiDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        let uiPSO = try device.makeRenderPipelineState(descriptor: uiDesc)
        #expect(uiPSO.device === device)
        
        // 2. Overlay UI (без Depth-аттачмента, рисует поверх апскейла в drawable)
        let overlayDesc = MTLRenderPipelineDescriptor()
        overlayDesc.label = "Test Quake 2D UI Overlay (No Depth)"
        overlayDesc.vertexFunction = vertFunc
        overlayDesc.fragmentFunction = fragFunc
        overlayDesc.colorAttachments[0].pixelFormat = pixelFormat
        overlayDesc.depthAttachmentPixelFormat = .invalid
        
        overlayDesc.colorAttachments[0].isBlendingEnabled = true
        overlayDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        overlayDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        overlayDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        let overlayPSO = try device.makeRenderPipelineState(descriptor: overlayDesc)
        #expect(overlayPSO.device === device)
    }
    
    // MARK: - 3. Пайплайны 3D мира и мультисэмплинг (MSAA 1x, 2x, 4x)
    
    @Test(
        "Сборка 3D World пайплайна с разными форматами цвета и уровнями MSAA",
        arguments: [
            (MTLPixelFormat.bgra8Unorm, 1),
            (MTLPixelFormat.rgba16Float, 1),
            (MTLPixelFormat.bgra8Unorm, 2),
            (MTLPixelFormat.rgba16Float, 2),
            (MTLPixelFormat.bgra8Unorm, 4),
            (MTLPixelFormat.rgba16Float, 4)
        ]
    )
    func testWorldPipelineStateWithMSAA(format: MTLPixelFormat, samples: Int) throws {
        guard device.supportsTextureSampleCount(samples) else {
            return
        }
        
        guard let vertFunc = library.makeFunction(name: "world_vertex_main"),
              let fragFunc = library.makeFunction(name: "world_fragment_main") else {
            Issue.record("Не найдены шейдеры 3D World")
            return
        }
        
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Test World Pipeline MSAA \(samples)x"
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = format
        desc.colorAttachments[0].isBlendingEnabled = false
        desc.depthAttachmentPixelFormat = .depth32Float_stencil8
        desc.rasterSampleCount = samples
        
        let pso = try device.makeRenderPipelineState(descriptor: desc)
        #expect(pso.device === device)
    }
    
    // MARK: - 4. Блендинг 3D мира (Alpha для воды/декалей и Additive для огня/взрывов)
    
    @Test("Сборка прозрачного (Alpha) и аддитивного (Additive) 3D пайплайнов")
    func testWorldBlendedAndAdditivePipelines() throws {
        guard let vertFunc = library.makeFunction(name: "world_vertex_main"),
              let fragFunc = library.makeFunction(name: "world_fragment_main") else {
            Issue.record("Не найдены шейдеры 3D World")
            return
        }
        
        let baseDesc = MTLRenderPipelineDescriptor()
        baseDesc.vertexFunction = vertFunc
        baseDesc.fragmentFunction = fragFunc
        baseDesc.colorAttachments[0].pixelFormat = .rgba16Float
        baseDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        baseDesc.colorAttachments[0].isBlendingEnabled = true
        baseDesc.colorAttachments[0].rgbBlendOperation = .add
        baseDesc.colorAttachments[0].alphaBlendOperation = .add
        
        // 1. Alpha Blending (SourceAlpha, OneMinusSourceAlpha)
        baseDesc.label = "Test 3D Alpha Blended"
        baseDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        baseDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        baseDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        baseDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        let alphaPSO = try device.makeRenderPipelineState(descriptor: baseDesc)
        #expect(alphaPSO.device === device)
        
        // 2. Additive Blending (SourceAlpha, One)
        baseDesc.label = "Test 3D Additive"
        baseDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        baseDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        baseDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        baseDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        
        let additivePSO = try device.makeRenderPipelineState(descriptor: baseDesc)
        #expect(additivePSO.device === device)
    }
    
    // MARK: - 5. Цепочка постобработки: Bloom, HDR Tonemap и Classic Gamma
    
    @Test("Сборка пайплайнов гамма-коррекции, HDR тонемаппера и Bloom-фильтров")
    func testPostProcessingPipelines() throws {
        guard let gammaVert = library.makeFunction(name: "gamma_vertex_main") else {
            Issue.record("Шейдер gamma_vertex_main не найден")
            return
        }
        
        // 1. Классическая гамма (BGRA8 -> BGRA8)
        if let gammaFrag = library.makeFunction(name: "gamma_fragment_main") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Test Classic Gamma"
            desc.vertexFunction = gammaVert
            desc.fragmentFunction = gammaFrag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            
            let pso = try device.makeRenderPipelineState(descriptor: desc)
            #expect(pso.device === device)
        }
        
        // 2. HDR Тонемаппер (RGBA16Float -> BGRA8 или RGBA16Float EDR)
        if let postFrag = library.makeFunction(name: "postprocess_fragment_main") {
            for outFmt in [MTLPixelFormat.bgra8Unorm, MTLPixelFormat.rgba16Float] {
                let desc = MTLRenderPipelineDescriptor()
                desc.label = "Test HDR Tonemap Out: \(outFmt.rawValue)"
                desc.vertexFunction = gammaVert
                desc.fragmentFunction = postFrag
                desc.colorAttachments[0].pixelFormat = outFmt
                desc.colorAttachments[0].isBlendingEnabled = false
                
                let pso = try device.makeRenderPipelineState(descriptor: desc)
                #expect(pso.device === device)
            }
        }
        
        // 3. Bloom Bright-Pass и Blur 9-Tap (RGBA16Float)
        if let brightFrag = library.makeFunction(name: "brightpass_fragment_main"),
           let blurFrag = library.makeFunction(name: "blur9_fragment_main") {
            let brightDesc = MTLRenderPipelineDescriptor()
            brightDesc.label = "Test Bloom Bright-Pass"
            brightDesc.vertexFunction = gammaVert
            brightDesc.fragmentFunction = brightFrag
            brightDesc.colorAttachments[0].pixelFormat = .rgba16Float
            brightDesc.colorAttachments[0].isBlendingEnabled = false
            let brightPSO = try device.makeRenderPipelineState(descriptor: brightDesc)
            #expect(brightPSO.device === device)
            
            let blurDesc = MTLRenderPipelineDescriptor()
            blurDesc.label = "Test Bloom Blur 9-Tap"
            blurDesc.vertexFunction = gammaVert
            blurDesc.fragmentFunction = blurFrag
            blurDesc.colorAttachments[0].pixelFormat = .rgba16Float
            blurDesc.colorAttachments[0].isBlendingEnabled = false
            let blurPSO = try device.makeRenderPipelineState(descriptor: blurDesc)
            #expect(blurPSO.device === device)
        }
    }
    
    // MARK: - 6. Векторы движения MetalFX Temporal (RG16Float без Depth)
    
    @Test("Сборка пайплайна векторов движения MetalFX Temporal (RG16Float, без Depth-аттачмента)")
    func testMotionVectorsPipeline() throws {
        guard let vertFunc = library.makeFunction(name: "gamma_vertex_main"),
              let motionFrag = library.makeFunction(name: "motion_fragment_main") else {
            Issue.record("Не найдены шейдеры gamma_vertex_main или motion_fragment_main")
            return
        }
        
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Test MetalFX Motion Vectors"
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = motionFrag
        desc.colorAttachments[0].pixelFormat = .rg16Float
        desc.colorAttachments[0].isBlendingEnabled = false
        // Векторный проход читает depth как текстуру, depth-аттачмента у прохода нет
        desc.depthAttachmentPixelFormat = .invalid
        
        let pso = try device.makeRenderPipelineState(descriptor: desc)
        #expect(pso.device === device)
    }
    
    // MARK: - 7. Конфигурации Depth-Stencil (Reverse-Z)
    
    @Test("Проверка состояний Depth-Stencil под инварианты Reverse-Z")
    func testReverseZDepthStencilStates() {
        // 1. 3D Мир (Reverse-Z: GreaterEqual, запись включена)
        let worldDepthDesc = MTLDepthStencilDescriptor()
        worldDepthDesc.depthCompareFunction = .greaterEqual
        worldDepthDesc.isDepthWriteEnabled = true
        let worldDepthState = device.makeDepthStencilState(descriptor: worldDepthDesc)
        #expect(worldDepthState != nil)
        
        // 2. Небо (Reverse-Z: GreaterEqual, запись выключена)
        let skyDepthDesc = MTLDepthStencilDescriptor()
        skyDepthDesc.depthCompareFunction = .greaterEqual
        skyDepthDesc.isDepthWriteEnabled = false
        let skyDepthState = device.makeDepthStencilState(descriptor: skyDepthDesc)
        #expect(skyDepthState != nil)
        
        // 3. 2D UI (Всегда поверх: Always, запись выключена)
        let uiDepthDesc = MTLDepthStencilDescriptor()
        uiDepthDesc.depthCompareFunction = .always
        uiDepthDesc.isDepthWriteEnabled = false
        let uiDepthState = device.makeDepthStencilState(descriptor: uiDepthDesc)
        #expect(uiDepthState != nil)
    }
}
