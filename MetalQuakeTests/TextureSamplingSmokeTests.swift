//
//  TextureSamplingSmokeTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import XCTest
import Metal
import simd
@testable import MetalQuake

// MARK: - C-API Forward Declarations
@_silgen_name("Memory_Init")
private func Memory_Init(_ buf: UnsafeMutableRawPointer?, _ size: Int32)

@_silgen_name("R_Metal_CreateTextureEx")
private func R_Metal_CreateTextureEx(
    _ width: Int32,
    _ height: Int32,
    _ rgbaData: UnsafeRawPointer?,
    _ dbgName: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer?

@_silgen_name("R_Metal_FreeTexture")
private func R_Metal_FreeTexture(_ texHandle: UnsafeMutableRawPointer?)

@_silgen_name("R_Metal_UpdateTextureRegion")
private func R_Metal_UpdateTextureRegion(
    _ texHandle: UnsafeMutableRawPointer?,
    _ x: Int32,
    _ y: Int32,
    _ width: Int32,
    _ height: Int32,
    _ data: UnsafeRawPointer?,
    _ bytesPerRow: Int32
)

@_silgen_name("MQ_PBR_Init")
private func MQ_PBR_Init(_ device: AnyObject?)

@_silgen_name("MQ_PBR_GetDefaultNormalTexture")
private func MQ_PBR_GetDefaultNormalTexture() -> AnyObject?

@_silgen_name("MQ_PBR_GetDefaultRMAOTexture")
private func MQ_PBR_GetDefaultRMAOTexture() -> AnyObject?

@_silgen_name("MQ_PBR_GetDefaultEmissionTexture")
private func MQ_PBR_GetDefaultEmissionTexture() -> AnyObject?

// MARK: - Texture Sampling Smoke Tests

final class TextureSamplingSmokeTests: XCTestCase {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var shaderLibrary: MTLLibrary!
    
    // Статический пул памяти Quake для работы в режиме Unit-тестов
    private static var isEngineMemoryReady = false
    private static var engineHunkMemory: UnsafeMutableRawPointer?
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // 1. Штатно инициализируем память Quake один раз на весь прогон тестов
        if !Self.isEngineMemoryReady {
            let memorySize: Int32 = 32 * 1024 * 1024 // 32 MB под Hunk и Zone
            Self.engineHunkMemory = malloc(Int(memorySize))
            guard let memPtr = Self.engineHunkMemory else {
                XCTFail("Не удалось выделить системную память под тестовый Hunk Quake")
                return
            }
            Memory_Init(memPtr, memorySize)
            Self.isEngineMemoryReady = true
        }
        
        // 2. Инициализация Metal
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal 3 аппаратный девайс недоступен на данной системе")
        }
        device = defaultDevice
        
        guard let queue = device.makeCommandQueue() else {
            XCTFail("Не удалось инициализировать MTLCommandQueue")
            return
        }
        commandQueue = queue
        
        shaderLibrary = try loadShaderLibrary()
    }
    
    // MARK: - Вспомогательные методы загрузки шейдеров и создания ресурсов
    
    /// Загружает библиотеку шейдеров: сначала из бандла приложения, а при изоляции в тестовом таргете — компилирует тестовые шейдеры
    private func loadShaderLibrary() throws -> MTLLibrary {
        let bundlesToSearch = [
            Bundle(for: Self.self),
            Bundle.main,
            Bundle(identifier: "com.alexeychernyak.MetalQuake")
        ].compactMap { $0 }
        
        for bundle in bundlesToSearch {
            if let lib = try? device.makeDefaultLibrary(bundle: bundle) {
                return lib
            }
            if let metallibURL = bundle.url(forResource: "default", withExtension: "metallib"),
               let lib = try? device.makeLibrary(URL: metallibURL) {
                return lib
            }
        }
        
        // Автономный MSL-код (зеркало ui_vertex_main и ui_fragment_main из Shaders.metal)
        let fallbackMSL = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexInput {
            float3 position;
            float2 texCoord;
            float2 lightmapCoord;
            float4 color;
        };
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoords;
            float4 color;
        };
        
        struct Uniforms {
            float4x4 projectionMatrix;
            float4x4 modelViewMatrix;
            float4 fogColor;
            float fogDensity;
            float time;
            int useTexture;
            int useFullbright;
        };
        
        vertex VertexOut test_ui_vertex(uint vertexID [[vertex_id]],
                                        constant VertexInput *vertices [[buffer(0)]],
                                        constant Uniforms &uniforms [[buffer(1)]]) {
            VertexOut out;
            VertexInput v = vertices[vertexID];
            out.position = uniforms.projectionMatrix * float4(v.position, 1.0);
            out.texCoords = v.texCoord;
            out.color = v.color;
            return out;
        }
        
        fragment float4 test_ui_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> baseTexture [[texture(0)]],
                                         sampler textureSampler [[sampler(0)]],
                                         constant Uniforms &uniforms [[buffer(1)]]) {
            if (uniforms.useTexture) {
                float4 texColor = baseTexture.sample(textureSampler, in.texCoords);
                return texColor * in.color;
            }
            return in.color;
        }
        """
        
        let compileOptions = MTLCompileOptions()
        compileOptions.languageVersion = .version3_0
        return try device.makeLibrary(source: fallbackMSL, options: compileOptions)
    }
    
    /// Преобразует void* хэндл движка в нативный интерфейс MTLTexture
    private func castHandleToTexture(_ rawHandle: UnsafeMutableRawPointer) -> MTLTexture {
        return Unmanaged<AnyObject>.fromOpaque(rawHandle).takeUnretainedValue() as! MTLTexture
    }
    
    // MARK: - Тест 1: Базовое создание текстуры движком и прямой Readback
    
    func testEngineTextureCreationAndDirectReadback() throws {
        let width: Int32 = 4
        let height: Int32 = 4
        let pixelCount = Int(width * height)
        var sourcePixels = [UInt8](repeating: 0, count: pixelCount * 4)
        
        // Заполняем контрастным оранжевым цветом: RGBA (255, 128, 32, 255)
        for i in 0..<pixelCount {
            let offset = i * 4
            sourcePixels[offset + 0] = 255
            sourcePixels[offset + 1] = 128
            sourcePixels[offset + 2] = 32
            sourcePixels[offset + 3] = 255
        }
        
        let rawHandle = sourcePixels.withUnsafeBytes { bufferPtr in
            R_Metal_CreateTextureEx(width, height, bufferPtr.baseAddress, "Smoke_DirectReadback")
        }
        
        guard let handle = rawHandle else {
            XCTFail("R_Metal_CreateTextureEx вернул nil при создании валидной текстуры")
            return
        }
        defer { R_Metal_FreeTexture(handle) }
        
        let texture = castHandleToTexture(handle)
        XCTAssertEqual(texture.width, Int(width), "Ширина созданной MTLTexture не совпадает")
        XCTAssertEqual(texture.height, Int(height), "Высота созданной MTLTexture не совпадает")
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm, "Формат пикселей должен быть RGBA8Unorm")
        
        // Проверяем данные в памяти текстуры через getBytes:
        var readbackPixels = [UInt8](repeating: 0, count: pixelCount * 4)
        let region = MTLRegionMake2D(0, 0, Int(width), Int(height))
        texture.getBytes(&readbackPixels, bytesPerRow: Int(width) * 4, from: region, mipmapLevel: 0)
        
        for i in 0..<pixelCount {
            let offset = i * 4
            XCTAssertEqual(readbackPixels[offset + 0], 255, "Пиксель \(i): несоответствие красного канала")
            XCTAssertEqual(readbackPixels[offset + 1], 128, "Пиксель \(i): несоответствие зеленого канала")
            XCTAssertEqual(readbackPixels[offset + 2], 32, "Пиксель \(i): несоответствие синего канала")
            XCTAssertEqual(readbackPixels[offset + 3], 255, "Пиксель \(i): несоответствие альфа-канала")
        }
    }
    
    // MARK: - Тест 2: Частичное обновление региона текстуры (UpdateTextureRegion)
    
    func testTexturePartialRegionUpdate() throws {
        let width: Int32 = 8
        let height: Int32 = 8
        let totalBytes = Int(width * height * 4)
        var blackPixels = [UInt8](repeating: 0, count: totalBytes)
        
        // Инициализируем текстуру черным фоном с альфой 255
        for i in stride(from: 3, to: totalBytes, by: 4) {
            blackPixels[i] = 255
        }
        
        let rawHandle = blackPixels.withUnsafeBytes { bufferPtr in
            R_Metal_CreateTextureEx(width, height, bufferPtr.baseAddress, "Smoke_RegionUpdate")
        }
        guard let handle = rawHandle else {
            XCTFail("Не удалось создать текстуру для теста частичного обновления")
            return
        }
        defer { R_Metal_FreeTexture(handle) }
        
        // Обновляем центральный квадрат 4x4 красным цветом (x: 2, y: 2, w: 4, h: 4)
        let subW: Int32 = 4
        let subH: Int32 = 4
        let subBytes = Int(subW * subH * 4)
        var redSubPixels = [UInt8](repeating: 0, count: subBytes)
        for i in 0..<Int(subW * subH) {
            redSubPixels[i * 4 + 0] = 255 // R
            redSubPixels[i * 4 + 1] = 0   // G
            redSubPixels[i * 4 + 2] = 0   // B
            redSubPixels[i * 4 + 3] = 255 // A
        }
        
        redSubPixels.withUnsafeBytes { subBufferPtr in
            R_Metal_UpdateTextureRegion(handle, 2, 2, subW, subH, subBufferPtr.baseAddress, subW * 4)
        }
        
        let texture = castHandleToTexture(handle)
        var readback = [UInt8](repeating: 0, count: totalBytes)
        texture.getBytes(&readback, bytesPerRow: Int(width) * 4, from: MTLRegionMake2D(0, 0, Int(width), Int(height)), mipmapLevel: 0)
        
        // Проверяем: точка (0,0) должна остаться черной, а точка (3,3) должна стать красной
        let indexBlack = (0 * Int(width) + 0) * 4
        XCTAssertEqual(readback[indexBlack + 0], 0, "Фоновый пиксель был ошибочно перезаписан")
        XCTAssertEqual(readback[indexBlack + 3], 255)
        
        let indexRed = (3 * Int(width) + 3) * 4
        XCTAssertEqual(readback[indexRed + 0], 255, "Пиксель обновленного субрегиона не стал красным")
        XCTAssertEqual(readback[indexRed + 1], 0)
        XCTAssertEqual(readback[indexRed + 2], 0)
        XCTAssertEqual(readback[indexRed + 3], 255)
    }
    
    // MARK: - Тест 3: Защита детектора ALL-BLACK от крашей при черных текстурах
    
    func testAllBlackTextureDetectionDoesNotCrash() throws {
        let width: Int32 = 2
        let height: Int32 = 2
        var allBlackPixels = [UInt8](repeating: 0, count: Int(width * height * 4))
        for i in 0..<4 {
            allBlackPixels[i * 4 + 3] = 255 // Полная непрозрачность при RGB = 0
        }
        
        let rawHandle = allBlackPixels.withUnsafeBytes { bufferPtr in
            R_Metal_CreateTextureEx(width, height, bufferPtr.baseAddress, "test_pure_black_texture")
        }
        
        guard let handle = rawHandle else {
            XCTFail("Движок не должен возвращать nil для полностью черной текстуры")
            return
        }
        defer { R_Metal_FreeTexture(handle) }
        
        let texture = castHandleToTexture(handle)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
    }
    
    // MARK: - Тест 4: Smoke-тест сэмплирования через GPU Offscreen Render Pass
    
    func testOffscreenTextureRenderSmoke() throws {
        let renderW = 32
        let renderH = 32
        
        // 1. Создаем RenderTarget буфер цвета
        let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: renderW, height: renderH, mipmapped: false)
        rtDesc.usage = [.renderTarget, .shaderRead]
        rtDesc.storageMode = .shared
        guard let renderTarget = device.makeTexture(descriptor: rtDesc) else {
            XCTFail("Не удалось выделить оффскрин-буфер цвета")
            return
        }
        
        // 2. Создаем текстуру-источник 2x2 с 4 уникальными цветными квадрантами:
        // [0,0]: Красный  (255, 0, 0)      [1,0]: Зеленый (0, 255, 0)
        // [0,1]: Синий    (0, 0, 255)      [1,1]: Белый   (255, 255, 255)
        let srcPixels: [UInt8] = [
            255, 0,   0,   255,    0,   255, 0,   255,
            0,   0,   255, 255,    255, 255, 255, 255
        ]
        
        let rawHandle = srcPixels.withUnsafeBytes { bufferPtr in
            R_Metal_CreateTextureEx(2, 2, bufferPtr.baseAddress, "Smoke_QuadPalette")
        }
        guard let srcHandle = rawHandle else {
            XCTFail("Не удалось создать 2x2 палитровый источник")
            return
        }
        defer { R_Metal_FreeTexture(srcHandle) }
        let sourceTexture = castHandleToTexture(srcHandle)
        
        // 3. Создаем Nearest сэмплер для исключения интерполяционного шума на границах
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
            XCTFail("Не удалось создать MTLSamplerState")
            return
        }
        
        // 4. Сборка Render Pipeline State
        let vertFunc = shaderLibrary.makeFunction(name: "ui_vertex_main") ?? shaderLibrary.makeFunction(name: "test_ui_vertex")
        let fragFunc = shaderLibrary.makeFunction(name: "ui_fragment_main") ?? shaderLibrary.makeFunction(name: "test_ui_fragment")
        
        guard let vFunc = vertFunc, let fFunc = fragFunc else {
            XCTFail("Не найдены шейдерные функции отрисовки 2D UI")
            return
        }
        
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.label = "Smoke Test Texture PSO"
        psoDesc.vertexFunction = vFunc
        psoDesc.fragmentFunction = fFunc
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        psoDesc.colorAttachments[0].isBlendingEnabled = false
        
        let pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        
        // 5. Подготовка геометрического квада на весь экран [-1, 1] NDC
        struct MetalVertexPayload {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var lightmapCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }
        
        let quadVerts: [MetalVertexPayload] = [
            .init(position: .init(-1, -1, 0), texCoord: .init(0, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1, -1, 0), texCoord: .init(1, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init(-1,  1, 0), texCoord: .init(0, 0), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1, -1, 0), texCoord: .init(1, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1,  1, 0), texCoord: .init(1, 0), lightmapCoord: .zero, color: .one),
            .init(position: .init(-1,  1, 0), texCoord: .init(0, 0), lightmapCoord: .zero, color: .one)
        ]
        
        guard let vertexBuffer = device.makeBuffer(bytes: quadVerts,
                                                   length: MemoryLayout<MetalVertexPayload>.stride * quadVerts.count,
                                                   options: .storageModeShared) else {
            XCTFail("Не удалось выделить вершинный буфер")
            return
        }
        
        // 6. Подготовка кадровых юниформов (Identity matrix)
        struct UniformsPayload {
            var projectionMatrix: simd_float4x4 = matrix_identity_float4x4
            var modelViewMatrix: simd_float4x4 = matrix_identity_float4x4
            var fogColor: SIMD4<Float> = .zero
            var fogDensity: Float = 0
            var time: Float = 0
            var useTexture: Int32 = 1
            var useFullbright: Int32 = 0
        }
        
        var uniforms = UniformsPayload()
        guard let uniformBuffer = device.makeBuffer(bytes: &uniforms,
                                                    length: MemoryLayout<UniformsPayload>.stride,
                                                    options: .storageModeShared) else {
            XCTFail("Не удалось выделить буфер констант")
            return
        }
        
        // 7. Кодирование прохода рендеринга
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = renderTarget
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store
        
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            XCTFail("Не удалось создать RenderCommandEncoder")
            return
        }
        
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(renderW), height: Double(renderH), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pso)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        
        // 8. Считывание результата из RenderTarget
        var renderedPixels = [UInt8](repeating: 0, count: renderW * renderH * 4)
        renderTarget.getBytes(&renderedPixels,
                              bytesPerRow: renderW * 4,
                              from: MTLRegionMake2D(0, 0, renderW, renderH),
                              mipmapLevel: 0)
        
        func samplePixelAt(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * renderW + x) * 4
            return (renderedPixels[offset], renderedPixels[offset + 1], renderedPixels[offset + 2], renderedPixels[offset + 3])
        }
        
        // Выборка из центров 4 квадрантов изображения
        let topLeft = samplePixelAt(x: 8, y: 8)
        let topRight = samplePixelAt(x: 24, y: 8)
        let bottomLeft = samplePixelAt(x: 8, y: 24)
        let bottomRight = samplePixelAt(x: 24, y: 24)
        
        // Верхний левый квадрант обязан быть красным (255, 0, 0)
        XCTAssertGreaterThan(topLeft.r, 240, "Top-Left: текстура не отрисовалась, красный канал отсутствует")
        XCTAssertLessThan(topLeft.g, 15)
        XCTAssertLessThan(topLeft.b, 15)
        
        // Верхний правый квадрант обязан быть зеленым (0, 255, 0)
        XCTAssertLessThan(topRight.r, 15)
        XCTAssertGreaterThan(topRight.g, 240, "Top-Right: текстура не отрисовалась, зеленый канал отсутствует")
        XCTAssertLessThan(topRight.b, 15)
        
        // Нижний левый квадрант обязан быть синим (0, 0, 255)
        XCTAssertLessThan(bottomLeft.r, 15)
        XCTAssertLessThan(bottomLeft.g, 15)
        XCTAssertGreaterThan(bottomLeft.b, 240, "Bottom-Left: текстура не отрисовалась, синий канал отсутствует")
        
        // Нижний правый квадрант обязан быть белым (255, 255, 255)
        XCTAssertGreaterThan(bottomRight.r, 240, "Bottom-Right: текстура не отрисовалась, белый цвет нарушен")
        XCTAssertGreaterThan(bottomRight.g, 240)
        XCTAssertGreaterThan(bottomRight.b, 240)
    }
    
    // MARK: - Тест 5: Проверка процедурных fallback-текстур PBR (Normal, RMAO, Emission)
    
    func testPBRFallbackTexturesReadback() throws {
        MQ_PBR_Init(device)
        
        guard let normalObj = MQ_PBR_GetDefaultNormalTexture(),
              let rmaoObj = MQ_PBR_GetDefaultRMAOTexture(),
              let emissionObj = MQ_PBR_GetDefaultEmissionTexture() else {
            XCTFail("Процедурные текстуры PBR не инициализированы")
            return
        }
        
        let normalTex = normalObj as! MTLTexture
        let rmaoTex = rmaoObj as! MTLTexture
        let emissionTex = emissionObj as! MTLTexture
        
        var normalPixel = [UInt8](repeating: 0, count: 4)
        normalTex.getBytes(&normalPixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // Нейтральная нормаль в касательном пространстве [0, 0, 1] кодируется как (128, 128, 255)
        XCTAssertEqual(normalPixel[0], 128, "PBR Normal Map fallback: X должен быть 128")
        XCTAssertEqual(normalPixel[1], 128, "PBR Normal Map fallback: Y должен быть 128")
        XCTAssertEqual(normalPixel[2], 255, "PBR Normal Map fallback: Z должен быть 255")
        XCTAssertEqual(normalPixel[3], 255)
        
        var rmaoPixel = [UInt8](repeating: 0, count: 4)
        rmaoTex.getBytes(&rmaoPixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        // Диэлектрик: Roughness ~200 (0.78), Metal = 0, AO = 255 (1.0)
        XCTAssertEqual(rmaoPixel[0], 200, "PBR RMAO: некорректный дефолт шероховатости")
        XCTAssertEqual(rmaoPixel[1], 0,   "PBR RMAO: дефолтный металл должен быть 0")
        XCTAssertEqual(rmaoPixel[2], 255, "PBR RMAO: дефолтное затенение AO должно быть 255")
        
        var emissionPixel = [UInt8](repeating: 0, count: 4)
        emissionTex.getBytes(&emissionPixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(emissionPixel[0], 0, "PBR Emission fallback должен быть полностью черным")
        XCTAssertEqual(emissionPixel[1], 0)
        XCTAssertEqual(emissionPixel[2], 0)
    }
    
    // MARK: - Тест 6: Сэмплирование текстуры с альфа-блендингом
    
    func testTextureAlphaSampling() throws {
        let renderW = 8
        let renderH = 8
        
        let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: renderW, height: renderH, mipmapped: false)
        rtDesc.usage = [.renderTarget, .shaderRead]
        rtDesc.storageMode = .shared
        guard let renderTarget = device.makeTexture(descriptor: rtDesc) else {
            XCTFail("Не удалось создать буфер цвета")
            return
        }
        
        // Текстура 1x1 с 50% полупрозрачным белым цветом
        let halfAlphaPixel: [UInt8] = [255, 255, 255, 128]
        let rawHandle = halfAlphaPixel.withUnsafeBytes { bufferPtr in
            R_Metal_CreateTextureEx(1, 1, bufferPtr.baseAddress, "Smoke_HalfAlpha")
        }
        guard let srcHandle = rawHandle else {
            XCTFail("Не удалось создать полупрозрачную текстуру")
            return
        }
        defer { R_Metal_FreeTexture(srcHandle) }
        let sourceTexture = castHandleToTexture(srcHandle)
        
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .nearest
        samplerDesc.magFilter = .nearest
        guard let samplerState = device.makeSamplerState(descriptor: samplerDesc) else {
            XCTFail("Не удалось создать сэмплер")
            return
        }
        
        let vertFunc = shaderLibrary.makeFunction(name: "ui_vertex_main") ?? shaderLibrary.makeFunction(name: "test_ui_vertex")
        let fragFunc = shaderLibrary.makeFunction(name: "ui_fragment_main") ?? shaderLibrary.makeFunction(name: "test_ui_fragment")
        
        let psoDesc = MTLRenderPipelineDescriptor()
        psoDesc.vertexFunction = vertFunc
        psoDesc.fragmentFunction = fragFunc
        psoDesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        
        // Включаем нативный альфа-блендинг (SourceAlpha, OneMinusSourceAlpha)
        psoDesc.colorAttachments[0].isBlendingEnabled = true
        psoDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        psoDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        psoDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        psoDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        let pso = try device.makeRenderPipelineState(descriptor: psoDesc)
        
        struct VertexPayload {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var lightmapCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }
        
        let quadVerts: [VertexPayload] = [
            .init(position: .init(-1, -1, 0), texCoord: .init(0, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1, -1, 0), texCoord: .init(1, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init(-1,  1, 0), texCoord: .init(0, 0), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1, -1, 0), texCoord: .init(1, 1), lightmapCoord: .zero, color: .one),
            .init(position: .init( 1,  1, 0), texCoord: .init(1, 0), lightmapCoord: .zero, color: .one),
            .init(position: .init(-1,  1, 0), texCoord: .init(0, 0), lightmapCoord: .zero, color: .one)
        ]
        
        guard let vertexBuffer = device.makeBuffer(bytes: quadVerts, length: MemoryLayout<VertexPayload>.stride * 6, options: .storageModeShared) else {
            XCTFail("Не удалось создать вершинный буфер")
            return
        }
        
        struct UniformsPayload {
            var projectionMatrix: simd_float4x4 = matrix_identity_float4x4
            var modelViewMatrix: simd_float4x4 = matrix_identity_float4x4
            var fogColor: SIMD4<Float> = .zero
            var fogDensity: Float = 0
            var time: Float = 0
            var useTexture: Int32 = 1
            var useFullbright: Int32 = 0
        }
        
        var uniforms = UniformsPayload()
        guard let uniformBuffer = device.makeBuffer(bytes: &uniforms, length: MemoryLayout<UniformsPayload>.stride, options: .storageModeShared) else {
            XCTFail("Не удалось создать буфер юниформов")
            return
        }
        
        // Очищаем буфер в чисто черный цвет: (0, 0, 0, 1.0)
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = renderTarget
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store
        
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            XCTFail("Не удалось создать энкодер рендера")
            return
        }
        
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(renderW), height: Double(renderH), znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pso)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        
        var resultPixels = [UInt8](repeating: 0, count: renderW * renderH * 4)
        renderTarget.getBytes(&resultPixels, bytesPerRow: renderW * 4, from: MTLRegionMake2D(0, 0, renderW, renderH), mipmapLevel: 0)
        
        // Белый цвет 50% поверх черного фона дает результирующий оттенок ~128 (допуск 120...135)
        let centerR = resultPixels[0]
        let centerG = resultPixels[1]
        let centerB = resultPixels[2]
        
        XCTAssertGreaterThanOrEqual(centerR, 120, "Неверный расчет блендинга: цвет пикселя слишком темный")
        XCTAssertLessThanOrEqual(centerR, 135, "Неверный расчет блендинга: цвет пикселя слишком яркий")
        XCTAssertEqual(centerR, centerG, "Каналы серого цвета разбалансированы")
        XCTAssertEqual(centerG, centerB)
    }
}
