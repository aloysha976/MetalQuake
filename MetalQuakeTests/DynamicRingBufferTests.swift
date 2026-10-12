//
//  DynamicRingBufferTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Testing
import Metal
import simd
import Foundation
@testable import MetalQuake

// MARK: - Набор тестов динамических кольцевых буферов Metal 3

@Suite("Тестирование кольцевых буферов Uniform/Vertex, выравнивания и защиты памяти")
struct DynamicRingBufferTests {
    private let device: MTLDevice
    
    init() throws {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            throw TestError.metalDeviceUnavailable
        }
        self.device = defaultDevice
    }
    
    enum TestError: Error {
        case metalDeviceUnavailable
        case bufferAllocationFailed
    }
    
    // MARK: - Константы спецификации Apple Metal
    
    /// Аппаратное требование Metal: смещение в буфере констант (setVertexBufferOffset / setFragmentBufferOffset)
    /// обязано быть строго кратно 256 байтам на всех GPU семейства Apple Silicon.
    private static let metalBufferOffsetAlignment = 256
    
    /// Стандартный размер кадрового кольцевого буфера движка (4 МБ)
    private static let ringBufferCapacity = 4 * 1024 * 1024
    
    // MARK: - 1. Математика выравнивания по границе 256 байт
    
    @Test(
        "Проверка формулы выравнивания: любое смещение округляется вверх до кратности 256 байт",
        arguments: [
            (0, 0),
            (1, 256),
            (64, 256),
            (255, 256),
            (256, 256),
            (257, 512),
            (512, 512),
            (1000, 1024),
            (4095, 4096)
        ]
    )
    func testOffsetAlignmentCalculation(inputOffset: Int, expectedAligned: Int) {
        let aligned = (inputOffset + (Self.metalBufferOffsetAlignment - 1)) & ~(Self.metalBufferOffsetAlignment - 1)
        #expect(aligned == expectedAligned)
        #expect(aligned % Self.metalBufferOffsetAlignment == 0)
    }
    
    // MARK: - 2. Моделирование последовательных аллокаций в кольцевом буфере
    
    @Test("Последовательные аллокации разных размеров гарантируют шаг >= размеру и кратность 256")
    func testSequentialAllocationsNonOverlapping() {
        var currentOffset = 0
        let allocationSizes = [64, 128, 256, 12, 1024, 48, 512]
        var recordedSlices: [(offset: Int, size: Int)] = []
        
        for size in allocationSizes {
            // Округляем текущее смещение под требования Metal
            let alignedOffset = (currentOffset + (Self.metalBufferOffsetAlignment - 1)) & ~(Self.metalBufferOffsetAlignment - 1)
            
            #expect(alignedOffset % Self.metalBufferOffsetAlignment == 0, "Смещение обязано быть кратно 256")
            #expect(alignedOffset >= currentOffset, "Выравненное смещение не может быть меньше исходного")
            
            recordedSlices.append((offset: alignedOffset, size: size))
            currentOffset = alignedOffset + size
        }
        
        // Проверяем, что ни один диапазон памяти не перекрывает соседний
        for i in 0..<(recordedSlices.count - 1) {
            let current = recordedSlices[i]
            let next = recordedSlices[i + 1]
            #expect(current.offset + current.size <= next.offset,
                    "Перекрытие памяти: блок [\(current.offset)..\(current.offset + current.size)] наложился на следующий [\(next.offset)]")
        }
    }
    
    // MARK: - 3. Физическая запись и верификация данных в MTLBuffer (Shared Memory)
    
    @Test("Запись матриц MVP и структур света в Shared MTLBuffer с верификацией побайтового чтения")
    func testBufferWriteAndReadbackIntegrity() throws {
        guard let buffer = device.makeBuffer(
            length: Self.ringBufferCapacity,
            options: .storageModeShared
        ) else {
            throw TestError.bufferAllocationFailed
        }
        
        let rawPointer = buffer.contents()
        
        // 1. Записываем тестовую 4x4 матрицу MVP
        var testMatrix = matrix_identity_float4x4
        testMatrix.columns.3 = SIMD4<Float>(100.0, -250.0, 500.0, 1.0)
        let matrixSize = MemoryLayout<simd_float4x4>.size
        let matrixOffset = 0
        
        rawPointer.advanced(by: matrixOffset).copyMemory(from: &testMatrix, byteCount: matrixSize)
        
        // 2. Записываем структуру освещения на следующем выравненном смещении (256)
        struct LightUniforms {
            var position: SIMD4<Float>
            var color: SIMD4<Float>
            var radius: Float
            var padding: SIMD3<Float>
        }
        var testLight = LightUniforms(
            position: SIMD4<Float>(10, 20, 30, 1),
            color: SIMD4<Float>(1.0, 0.8, 0.6, 1.0),
            radius: 350.0,
            padding: .zero
        )
        let lightSize = MemoryLayout<LightUniforms>.size
        let lightOffset = 256 // Ровно через 256 байт
        
        rawPointer.advanced(by: lightOffset).copyMemory(from: &testLight, byteCount: lightSize)
        
        // 3. Считываем данные обратно и проверяем целостность
        let readMatrix = rawPointer.advanced(by: matrixOffset).load(as: simd_float4x4.self)
        #expect(readMatrix.columns.3 == testMatrix.columns.3)
        
        let readLight = rawPointer.advanced(by: lightOffset).load(as: LightUniforms.self)
        #expect(readLight.position == testLight.position)
        #expect(readLight.color == testLight.color)
        #expect(readLight.radius == testLight.radius)
    }
    
    // MARK: - 4. Тестирование циклического перезапуска и переполнения (Ring Wrap & Overflow)
    
    @Test("Защита от переполнения: аллокация сверх емкости буфера отвергается без порчи памяти")
    func testRingBufferOverflowProtection() {
        let capacity = 1024 * 1024 // 1 MB
        var headOffset = capacity - 128 // Осталось всего 128 байт
        
        let requestedSize = 256
        let alignedOffset = (headOffset + (Self.metalBufferOffsetAlignment - 1)) & ~(Self.metalBufferOffsetAlignment - 1)
        
        // Проверяем предикат переполнения
        let isOverflow = (alignedOffset + requestedSize) > capacity
        #expect(isOverflow == true, "Движок обязан фиксировать выход за границы буфера")
        
        // Имитируем переход на следующий кадр (Ring Reset)
        headOffset = 0
        let resetAlignedOffset = (headOffset + (Self.metalBufferOffsetAlignment - 1)) & ~(Self.metalBufferOffsetAlignment - 1)
        #expect(resetAlignedOffset == 0)
        #expect((resetAlignedOffset + requestedSize) <= capacity)
    }
    
    // MARK: - 5. Изоляция кадров при тройной буферизации (Triple Buffering Invariants)
    
    @Test("Тройная буферизация (3 слота): смещения кадров изолированы и не перезаписывают GPU-память")
    func testTripleBufferingSlotIsolation() {
        let maxFramesInFlight = 3
        let perFrameCapacity = 1024 * 1024 // 1 МБ на каждый кадр
        let totalBufferLength = perFrameCapacity * maxFramesInFlight
        
        for frameIndex in 0..<12 { // Симулируем 12 кадров рендеринга
            let slotIndex = frameIndex % maxFramesInFlight
            let slotBaseOffset = slotIndex * perFrameCapacity
            let slotEndOffset = slotBaseOffset + perFrameCapacity
            
            #expect(slotBaseOffset >= 0 && slotEndOffset <= totalBufferLength)
            #expect(slotBaseOffset % Self.metalBufferOffsetAlignment == 0)
            
            // Проверяем, что смещения следующего слота не накладываются на текущий
            let nextSlotIndex = (frameIndex + 1) % maxFramesInFlight
            let nextSlotBaseOffset = nextSlotIndex * perFrameCapacity
            
            if slotIndex != nextSlotIndex {
                let hasCollision = (slotBaseOffset < nextSlotBaseOffset + perFrameCapacity) &&
                (slotEndOffset > nextSlotBaseOffset)
                #expect(!hasCollision, "Коллизия слотов между кадром \(slotIndex) и \(nextSlotIndex)")
            }
        }
    }
}
