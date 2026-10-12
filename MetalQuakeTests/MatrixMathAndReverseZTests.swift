//
//  MatrixMathAndReverseZTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Testing
import simd
import Foundation
@testable import MetalQuake

// MARK: - C-API Forward Declarations

@_silgen_name("R_Metal_ComputeMVP")
private func R_Metal_ComputeMVP(
    _ fovY_deg: Float,
    _ aspect: Float,
    _ zNear: Float,
    _ zFar: Float,
    _ origin: SIMD3<Float>,
    _ angles: SIMD3<Float>
) -> simd_float4x4

// MARK: - Набор тестов матричной математики, Reverse-Z и базиса камеры

@Suite("Тестирование математики матриц MVP, инвариантов Reverse-Z и проекций")
struct MatrixMathAndReverseZTests {
    
    // MARK: - Вспомогательные функции
    
    /// Трансформация мировой 3D-точки матрицей MVP в координаты отсечения (Clip Space)
    private func transformPoint(_ point: SIMD3<Float>, with mvp: simd_float4x4) -> SIMD4<Float> {
        let v = SIMD4<Float>(point.x, point.y, point.z, 1.0)
        return mvp * v
    }
    
    /// Преобразование вектора Clip Space в нормализованные координаты устройства NDC (деление на W)
    private func toNDC(_ clip: SIMD4<Float>) -> SIMD3<Float> {
        guard abs(clip.w) > 1e-7 else { return .zero }
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }
    
    // MARK: - 1. Тестирование инвариантов Reverse-Z (Ближняя плоскость -> 1.0, Дальняя -> 0.0)
    
    @Test(
        "Проверка Reverse-Z: zNear проецируется в NDC Z = 1.0, zFar проецируется в NDC Z = 0.0",
        arguments: [
            (Float(4.0), Float(4096.0)),
            (Float(8.0), Float(8192.0)),
            (Float(1.0), Float(2048.0))
        ]
    )
    func testReverseZDepthPlanes(zNear: Float, zFar: Float) {
        let origin = SIMD3<Float>(0, 0, 0)
        // В Quake углы (Pitch=0, Yaw=0, Roll=0) направляют взгляд вдоль вектора +X (Forward = (1, 0, 0))
        let angles = SIMD3<Float>(0, 0, 0)
        let fovY: Float = 90.0
        let aspect: Float = 16.0 / 9.0
        
        let mvp = R_Metal_ComputeMVP(fovY, aspect, zNear, zFar, origin, angles)
        
        // 1. Точка строго на ближней плоскости отсечения (zNear вдоль оси взгляда +X)
        let nearPoint = SIMD3<Float>(zNear, 0, 0)
        let nearClip = transformPoint(nearPoint, with: mvp)
        let nearNDC = toNDC(nearClip)
        
        // Инвариант Reverse-Z: на zNear глубина строго 1.0
        #expect(abs(nearNDC.z - 1.0) < 0.001, "На ближней плоскости zNear глубина NDC обязана быть 1.0 (получено \(nearNDC.z))")
        #expect(nearClip.w > 0, "Координата W для видимой точки обязана быть положительной")
        
        // 2. Точка строго на дальней плоскости отсечения (zFar вдоль оси взгляда +X)
        let farPoint = SIMD3<Float>(zFar, 0, 0)
        let farClip = transformPoint(farPoint, with: mvp)
        let farNDC = toNDC(farClip)
        
        // Инвариант Reverse-Z: на zFar глубина строго 0.0
        #expect(abs(farNDC.z - 0.0) < 0.001, "На дальней плоскости zFar глубина NDC обязана быть 0.0 (получено \(farNDC.z))")
        
        // 3. Точка посередине диапазона: глубина должна монотонно убывать от 1.0 к 0.0
        let midPoint = SIMD3<Float>((zNear + zFar) * 0.5, 0, 0)
        let midNDC = toNDC(transformPoint(midPoint, with: mvp))
        #expect(midNDC.z > 0.0 && midNDC.z < 1.0, "Промежуточная точка обязана лежать строго внутри диапазона (0.0, 1.0)")
    }
    
    // MARK: - 2. Проверка смещения камеры (Translation Invariance)
    
    @Test("Проверка смещения камеры: положение origin не нарушает расчет глубины")
    func testCameraTranslationInvariance() {
        let camOrigin = SIMD3<Float>(1024.0, -512.0, 256.0)
        let angles = SIMD3<Float>(0, 0, 0) // Взгляд вдоль +X
        let zNear: Float = 4.0
        let zFar: Float = 4096.0
        
        let mvp = R_Metal_ComputeMVP(90.0, 1.0, zNear, zFar, camOrigin, angles)
        
        // Точка на zNear перед смещенной камерой
        let worldNearPoint = camOrigin + SIMD3<Float>(zNear, 0, 0)
        let nearNDC = toNDC(transformPoint(worldNearPoint, with: mvp))
        
        #expect(abs(nearNDC.z - 1.0) < 0.001)
        #expect(abs(nearNDC.x) < 0.001)
        #expect(abs(nearNDC.y) < 0.001)
    }
    
    // MARK: - 3. Проверка вращения камеры (Pitch, Yaw, Roll) и ортонормированности базиса
    
    @Test(
        "Ортонормированность базиса камеры при произвольных углах Эйлера",
        arguments: [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(45, 90, 0),
            SIMD3<Float>(-30, 180, 15),
            SIMD3<Float>(85, -45, -20)
        ]
    )
    func testCameraViewBasisOrthonormality(angles: SIMD3<Float>) {
        // Воспроизводим формулы AngleVectors из mathlib движка
        let pitch = angles.x * (.pi / 180.0)
        let yaw   = angles.y * (.pi / 180.0)
        let roll  = angles.z * (.pi / 180.0)
        
        let sp = sin(pitch), cp = cos(pitch)
        let sy = sin(yaw),   cy = cos(yaw)
        let sr = sin(roll),  cr = cos(roll)
        
        let forward = SIMD3<Float>(cp * cy, cp * sy, -sp)
        let right   = SIMD3<Float>(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp)
        let up      = SIMD3<Float>(cr * sp * cy + sr * sy,   cr * sp * sy - sr * cy,  cr * cp)
        
        // 1. Проверка единичной длины векторов
        #expect(abs(simd_length(forward) - 1.0) < 1e-5)
        #expect(abs(simd_length(right) - 1.0) < 1e-5)
        #expect(abs(simd_length(up) - 1.0) < 1e-5)
        
        // 2. Проверка взаимной ортогональности (скалярное произведение = 0)
        #expect(abs(simd_dot(forward, right)) < 1e-5, "Forward и Right не перпендикулярны")
        #expect(abs(simd_dot(forward, up)) < 1e-5, "Forward и Up не перпендикулярны")
        #expect(abs(simd_dot(right, up)) < 1e-5, "Right и Up не перпендикулярны")
    }
    
    // MARK: - 4. Отсечение геометрии позади камеры (Frustum Culling W < 0)
    
    @Test("Точки позади камеры дают отрицательный W (отсечение клиппером GPU)")
    func testPointsBehindCameraHaveNegativeW() {
        let origin = SIMD3<Float>(0, 0, 0)
        let angles = SIMD3<Float>(0, 0, 0) // Взгляд вдоль +X
        
        let mvp = R_Metal_ComputeMVP(90.0, 1.0, 4.0, 4096.0, origin, angles)
        
        // Точка находится строго позади камеры (X = -100)
        let behindPoint = SIMD3<Float>(-100.0, 0, 0)
        let clip = transformPoint(behindPoint, with: mvp)
        
        #expect(clip.w < 0.0, "Точка позади плоскости камеры обязана иметь W < 0 для аппаратного отсечения")
    }
    
    // MARK: - 5. Тестирование 2D Ortho матрицы Quake (Y-Down конвенция)
    
    @Test("Матрица 2D Ortho переводит координаты экрана [0..W, 0..H] в корректный NDC [-1..1, +1..-1]")
    func testOrthoMatrixYDownConvention() {
        let left: Float = 0.0
        let right: Float = 800.0
        let bottom: Float = 600.0 // В Quake bottom > top (y-down)
        let top: Float = 0.0
        
        let rl = right - left
        let tb = top - bottom
        
        // Точная формула из make_ortho_matrix в mq_ui2d.m
        let ortho = simd_float4x4(
            SIMD4<Float>(2.0 / rl, 0, 0, 0),
            SIMD4<Float>(0, 2.0 / tb, 0, 0),
            SIMD4<Float>(0, 0, 1.0, 0),
            SIMD4<Float>(-(right + left) / rl, -(top + bottom) / tb, 0, 1.0)
        )
        
        // 1. Верхний левый угол экрана (0, 0) обязан перейти в NDC (-1.0, +1.0)
        let topLeft = ortho * SIMD4<Float>(0, 0, 0, 1)
        #expect(abs(topLeft.x - (-1.0)) < 1e-5)
        #expect(abs(topLeft.y - (1.0)) < 1e-5)
        
        // 2. Нижний правый угол экрана (800, 600) обязан перейти в NDC (+1.0, -1.0)
        let bottomRight = ortho * SIMD4<Float>(800, 600, 0, 1)
        #expect(abs(bottomRight.x - (1.0)) < 1e-5)
        #expect(abs(bottomRight.y - (-1.0)) < 1e-5)
        
        // 3. Центр экрана (400, 300) обязан перейти строго в центр NDC (0.0, 0.0)
        let center = ortho * SIMD4<Float>(400, 300, 0, 1)
        #expect(abs(center.x) < 1e-5)
        #expect(abs(center.y) < 1e-5)
    }
}
