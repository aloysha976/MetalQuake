//
//  ControllerMathAndTangentTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Testing
import simd
import Foundation
@testable import MetalQuake

@Suite("Тестирование математики ввода геймпада и PBR тангенциального пространства")
struct ControllerMathAndTangentTests {
    
    // MARK: - Вспомогательные математические алгоритмы
    
    /// Алгоритм радиальной мертвой зоны стика с гладким перемасштабированием отклика
    private func applyRadialDeadzone(
        stick: SIMD2<Float>,
        deadzone: Float,
        curvePower: Float = 1.0
    ) -> SIMD2<Float> {
        let magnitude = simd_length(stick)
        guard magnitude > deadzone else {
            return .zero
        }
        
        // Нормализация вектора направления
        let direction = stick / magnitude
        
        // Масштабирование остатка диапазона в [0.0 ... 1.0]
        let scaledMagnitude = (magnitude - deadzone) / (1.0 - deadzone)
        let clampedMagnitude = min(max(scaledMagnitude, 0.0), 1.0)
        
        // Применение степенной кривой отклика для точности прицеливания
        let finalMagnitude = pow(clampedMagnitude, curvePower)
        
        return direction * finalMagnitude
    }
    
    /// Структура тангента с вектором направления и знаком бинормали
    struct TangentResult {
        var tangent: SIMD3<Float>
        var handedness: Float // +1.0 или -1.0
    }
    
    /// Вычисление тангента треугольника по 3D-вершинам и UV-координатам (алгоритм Грама — Шмидта)
    private func computeSurfaceTangent(
        p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>,
        uv0: SIMD2<Float>, uv1: SIMD2<Float>, uv2: SIMD2<Float>,
        normal: SIMD3<Float>
    ) -> TangentResult? {
        let edge1 = p1 - p0
        let edge2 = p2 - p0
        
        let deltaUV1 = uv1 - uv0
        let deltaUV2 = uv2 - uv0
        
        let det = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
        guard abs(det) > 1e-7 else {
            return nil // Вырожденная UV-развертка
        }
        
        let invDet = 1.0 / det
        let rawTangent = SIMD3<Float>(
            invDet * (deltaUV2.y * edge1.x - deltaUV1.y * edge2.x),
            invDet * (deltaUV2.y * edge1.y - deltaUV1.y * edge2.y),
            invDet * (deltaUV2.y * edge1.z - deltaUV1.y * edge2.z)
        )
        
        let rawBitangent = SIMD3<Float>(
            invDet * (-deltaUV2.x * edge1.x + deltaUV1.x * edge2.x),
            invDet * (-deltaUV2.x * edge1.y + deltaUV1.x * edge2.y),
            invDet * (-deltaUV2.x * edge1.z + deltaUV1.x * edge2.z)
        )
        
        // Ортогонализация Грама — Шмидта: T' = normalize(T - N * (N . T))
        let n = simd_normalize(normal)
        let orthoTangent = rawTangent - n * simd_dot(n, rawTangent)
        let tangentLength = simd_length(orthoTangent)
        guard tangentLength > 1e-7 else {
            return nil
        }
        let normalizedTangent = orthoTangent / tangentLength
        
        // Расчет знака бинормали (handedness): dot(cross(N, T), B) < 0 ? -1.0 : +1.0
        let crossNB = simd_cross(n, normalizedTangent)
        let handedness: Float = simd_dot(crossNB, rawBitangent) < 0.0 ? -1.0 : 1.0
        
        return TangentResult(tangent: normalizedTangent, handedness: handedness)
    }
    
    // MARK: - 1. Тестирование мертвой зоны контроллера (Stick Drift Suppression)
    
    @Test(
        "Дрейф стика внутри радиуса deadzone полностью подавляется в ноль",
        arguments: [
            SIMD2<Float>(0.05, 0.05),
            SIMD2<Float>(-0.12, 0.0),
            SIMD2<Float>(0.0, -0.14),
            SIMD2<Float>(0.10, -0.10)
        ]
    )
    func testStickDriftSuppression(stickDrift: SIMD2<Float>) {
        let deadzone: Float = 0.15
        let result = applyRadialDeadzone(stick: stickDrift, deadzone: deadzone)
        
        #expect(result.x == 0.0)
        #expect(result.y == 0.0)
    }
    
    @Test("Непрерывность отклика: на самой границе deadzone вектор стремится к нулю без рывка")
    func testDeadzoneThresholdSmoothness() {
        let deadzone: Float = 0.20
        // Точка чуть-чуть за пределами мертвой зоны
        let stick = SIMD2<Float>(deadzone + 0.001, 0.0)
        let result = applyRadialDeadzone(stick: stick, deadzone: deadzone)
        
        #expect(result.x > 0.0)
        #expect(result.x < 0.01, "При выходе из зоны отклик должен начинаться плавно с нуля")
    }
    
    @Test("Максимальное отклонение стика (длина 1.0) дает строго единичный отклик")
    func testMaxStickDeflectionGivesUnitOutput() {
        let deadzone: Float = 0.20
        let fullSticks: [SIMD2<Float>] = [
            SIMD2<Float>(1.0, 0.0),
            SIMD2<Float>(0.0, 1.0),
            SIMD2<Float>(-1.0, 0.0),
            SIMD2<Float>(0.7071, 0.7071)
        ]
        
        for stick in fullSticks {
            let result = applyRadialDeadzone(stick: stick, deadzone: deadzone)
            let magnitude = simd_length(result)
            #expect(abs(magnitude - 1.0) < 0.001)
        }
    }
    
    @Test("Квадратичная кривая чувствительности обеспечивает повышенную точность малых углов")
    func testSensitivityResponseCurves() {
        let deadzone: Float = 0.10
        let halfStick = SIMD2<Float>(0.55, 0.0)
        
        let linearResponse = applyRadialDeadzone(stick: halfStick, deadzone: deadzone, curvePower: 1.0)
        let quadraticResponse = applyRadialDeadzone(stick: halfStick, deadzone: deadzone, curvePower: 2.0)
        
        // Квадратичный отклик на средних углах должен быть меньше линейного для точности микродоводки
        #expect(quadraticResponse.x < linearResponse.x)
        #expect(abs(quadraticResponse.x - pow(linearResponse.x, 2.0)) < 1e-5)
    }
    
    // MARK: - 2. Тестирование PBR тангентов и ортогонализации Грама — Шмидта
    
    @Test("Тангент горизонтальной плоскости Quake (пол/потолок) строго перпендикулярен нормали (0, 0, 1)")
    func testFloorPlaneTangentOrthogonality() {
        // Треугольник пола в плоскости XY
        let p0 = SIMD3<Float>(0, 0, 0)
        let p1 = SIMD3<Float>(64, 0, 0)
        let p2 = SIMD3<Float>(0, 64, 0)
        
        let uv0 = SIMD2<Float>(0, 0)
        let uv1 = SIMD2<Float>(1, 0)
        let uv2 = SIMD2<Float>(0, 1)
        
        let normal = SIMD3<Float>(0, 0, 1)
        
        guard let result = computeSurfaceTangent(
            p0: p0, p1: p1, p2: p2,
            uv0: uv0, uv1: uv1, uv2: uv2,
            normal: normal
        ) else {
            Issue.record("Не удалось вычислить тангент")
            return
        }
        
        // 1. Длина тангента строго равна 1.0
        #expect(abs(simd_length(result.tangent) - 1.0) < 1e-5)
        
        // 2. Тангент и нормаль взаимно перпендикулярны
        let dotProduct = simd_dot(result.tangent, normal)
        #expect(abs(dotProduct) < 1e-5, "Тангент не перпендикулярен нормали: dot = \(dotProduct)")
        
        // 3. Для пола с такой разверткой вектор U идет вдоль оси +X
        #expect(abs(result.tangent.x - 1.0) < 1e-5)
        #expect(abs(result.tangent.y) < 1e-5)
        #expect(abs(result.tangent.z) < 1e-5)
        #expect(result.handedness == 1.0)
    }
    
    @Test("Тангент вертикальной стены Quake перпендикулярен нормали стены")
    func testWallPlaneTangentOrthogonality() {
        // Стена в плоскости XZ (нормаль вдоль +Y)
        let p0 = SIMD3<Float>(0, 0, 0)
        let p1 = SIMD3<Float>(128, 0, 0)
        let p2 = SIMD3<Float>(0, 0, 128)
        
        let uv0 = SIMD2<Float>(0, 1)
        let uv1 = SIMD2<Float>(1, 1)
        let uv2 = SIMD2<Float>(0, 0)
        
        let wallNormal = SIMD3<Float>(0, 1, 0)
        
        guard let result = computeSurfaceTangent(
            p0: p0, p1: p1, p2: p2,
            uv0: uv0, uv1: uv1, uv2: uv2,
            normal: wallNormal
        ) else {
            Issue.record("Не удалось вычислить тангент стены")
            return
        }
        
        #expect(abs(simd_length(result.tangent) - 1.0) < 1e-5)
        #expect(abs(simd_dot(result.tangent, wallNormal)) < 1e-5)
        #expect(abs(result.handedness) == 1.0)
    }
    
    @Test("Вырожденные треугольники с нулевой площадью UV возвращают nil без сбоя")
    func testDegenerateUVSurfaceReturnsNil() {
        let p0 = SIMD3<Float>(0, 0, 0)
        let p1 = SIMD3<Float>(10, 0, 0)
        let p2 = SIMD3<Float>(0, 10, 0)
        
        // Все вершины ссылаются на одну и ту же UV-точку (вырождение)
        let uv = SIMD2<Float>(0.5, 0.5)
        
        let result = computeSurfaceTangent(
            p0: p0, p1: p1, p2: p2,
            uv0: uv, uv1: uv, uv2: uv,
            normal: SIMD3<Float>(0, 0, 1)
        )
        
        #expect(result == nil, "При вырожденных UV функция обязана вернуть nil, предотвращая NaN")
    }
}
