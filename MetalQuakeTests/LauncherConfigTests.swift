//
//  LauncherConfigTests.swift
//  MetalQuakeTests
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Testing
import Foundation
import AppKit
@testable import MetalQuake

// MARK: - Тестовый набор конфигурации и логики лаунчера

@Suite("Тестирование логики лаунчера, конфигурации и аргументов запуска")
@MainActor
struct LauncherConfigTests {
    
    // MARK: - Вспомогательные фабрики и утилиты
    
    /// Генерация базовой конфигурации с возможностью точечного переопределения параметров для тестов
    private func makeConfig(
        gameFolderPath: String = "/Users/testuser/Games/Quake",
        gameFolderBookmarkB64: String = "",
        selectedMod: String = "id1",
        startMap: String = "start",
        skillLevel: Int = 1,
        selectedDisplayIndex: Int = 0,
        fullscreen: Bool = false,
        selectedResolution: String = "1920x1080",
        preserveAspect: Bool = false,
        scaleFilter: Int = 0,
        vsync: Bool = true,
        uncappedFPS: Bool = true,
        targetFPS: Double = 120.0,
        gammaValue: Double = 1.0,
        contrastValue: Double = 1.0,
        metalFXMode: String = MetalFXMode.disabled.rawValue,
        metalFXPreset: String = MetalFXPreset.quality.rawValue,
        anisotropy: Int = 16,
        waterAlpha: Double = 0.70,
        lerpModels: Bool = true,
        dynamicShadows: Bool = false,
        pbrEnabled: Bool = false,
        rtEnabled: Bool = false,
        hdrEnabled: Bool = true,
        bloomEnabled: Bool = false,
        bloomQuality: Int = 0,
        msaaSamples: Int = 0,
        freelook: Bool = true,
        crosshairEnabled: Bool = true,
        fieldOfView: Double = 90.0,
        enableSpatialAudio: Bool = true,
        sfxVolume: Double = 0.8,
        bgmVolume: Double = 0.7
    ) -> LaunchConfig {
        LaunchConfig(
            gameFolderPath: gameFolderPath,
            gameFolderBookmarkB64: gameFolderBookmarkB64,
            selectedMod: selectedMod,
            startMap: startMap,
            skillLevel: skillLevel,
            selectedDisplayIndex: selectedDisplayIndex,
            fullscreen: fullscreen,
            selectedResolution: selectedResolution,
            preserveAspect: preserveAspect,
            scaleFilter: scaleFilter,
            vsync: vsync,
            uncappedFPS: uncappedFPS,
            targetFPS: targetFPS,
            gammaValue: gammaValue,
            contrastValue: contrastValue,
            metalFXMode: metalFXMode,
            metalFXPreset: metalFXPreset,
            anisotropy: anisotropy,
            waterAlpha: waterAlpha,
            lerpModels: lerpModels,
            dynamicShadows: dynamicShadows,
            pbrEnabled: pbrEnabled,
            rtEnabled: rtEnabled,
            hdrEnabled: hdrEnabled,
            bloomEnabled: bloomEnabled,
            bloomQuality: bloomQuality,
            msaaSamples: msaaSamples,
            freelook: freelook,
            crosshairEnabled: crosshairEnabled,
            fieldOfView: fieldOfView,
            enableSpatialAudio: enableSpatialAudio,
            sfxVolume: sfxVolume,
            bgmVolume: bgmVolume
        )
    }
    
    /// Извлечение значения CVar из массива переданных аргументов вида `["+set", "cvar_name", "value"]`
    private func getCvarValue(_ name: String, from args: [String]) -> String? {
        for i in 0..<(args.count - 2) {
            if args[i] == "+set" && args[i + 1] == name {
                return args[i + 2]
            }
        }
        return nil
    }
    
    /// Проверка наличия пары ключа и значения флага вида `["-flag", "value"]`
    private func hasFlagPair(_ flag: String, value: String, in args: [String]) -> Bool {
        for i in 0..<(args.count - 1) {
            if args[i] == flag && args[i + 1] == value {
                return true
            }
        }
        return false
    }
    
    // MARK: - 1. Тестирование MetalFX пресетов и коэффициентов масштабирования
    
    @Test("Проверка scaleFactor для всех пресетов MetalFX", arguments: [
        (MetalFXPreset.performance, Float(0.50)),
        (MetalFXPreset.balanced, Float(0.67)),
        (MetalFXPreset.quality, Float(0.75)),
        (MetalFXPreset.ultraQuality, Float(0.85))
    ])
    func testMetalFXPresetScaleFactors(preset: MetalFXPreset, expectedScale: Float) {
        #expect(preset.scaleFactor == expectedScale)
    }
    
    @Test("Проверка идентификаторов и отображаемых имен режимов MetalFX", arguments: [
        (MetalFXMode.disabled, "Disabled (Native)"),
        (MetalFXMode.spatial, "MetalFX Spatial (v1 - Fast)"),
        (MetalFXMode.temporal, "MetalFX Temporal (v2 - High Quality)")
    ])
    func testMetalFXModeIdentifiers(mode: MetalFXMode, expectedRaw: String) {
        #expect(mode.rawValue == expectedRaw)
        #expect(mode.id == expectedRaw)
    }
    
    // MARK: - 2. Тестирование констант лаунчера
    
    @Test("Проверка базовых лимитов и стандартных пулов LauncherConstants")
    func testLauncherConstantsInvariants() {
        #expect(LauncherConstants.metalMaxTextureEdge == 16384)
        #expect(LauncherConstants.anisoLevels == [1, 2, 4, 8, 16])
        #expect(LauncherConstants.msaaLevels == [0, 2, 4, 8])
        #expect(LauncherConstants.skillNames.count == 4)
        #expect(LauncherConstants.standardResolutions.contains("1920x1080"))
        #expect(LauncherConstants.standardResolutions.contains("3840x2160"))
        #expect(LauncherConstants.standardResolutions.contains("320x240"))
    }
    
    // MARK: - 3. Тестирование генерации аргументов CLI C-движка
    
    @Test("Генерация аргументов: базовые флаги Quake, папка и активный мод")
    func testCommandLineBasicFlags() {
        let config = makeConfig(
            gameFolderPath: "/Volumes/Games/Quake",
            selectedMod: "rogue",
            startMap: "r1m1"
        )
        let args = LauncherEngine.buildArguments(config: config, resolvedGameFolder: "/Volumes/Games/Quake")
        
        #expect(args.first == "MetalQuake")
        #expect(hasFlagPair("-basedir", value: "/Volumes/Games/Quake", in: args))
        #expect(hasFlagPair("-game", value: "rogue", in: args))
        #expect(hasFlagPair("+map", value: "r1m1", in: args))
    }
    
    @Test("Генерация аргументов: стандартный mod 'id1' не должен добавлять флаг -game")
    func testCommandLineDefaultModOmitsGameFlag() {
        let config = makeConfig(selectedMod: "id1")
        let args = LauncherEngine.buildArguments(config: config, resolvedGameFolder: "/Quake")
        
        #expect(!args.contains("-game"))
    }
    
    @Test("Генерация аргументов: расчет разрешения и режима Fullscreen")
    func testCommandLineResolutionAndFullscreen() {
        // Оконный режим с кастомным разрешением
        let windowedConfig = makeConfig(fullscreen: false, selectedResolution: "2560x1440")
        let windowedArgs = LauncherEngine.buildArguments(config: windowedConfig, resolvedGameFolder: "/Quake")
        
        #expect(!windowedArgs.contains("-fullscreen"))
        #expect(hasFlagPair("-width", value: "2560", in: windowedArgs))
        #expect(hasFlagPair("-height", value: "1440", in: windowedArgs))
        
        // Полноэкранный режим
        let fsConfig = makeConfig(fullscreen: true, selectedResolution: "1920x1080")
        let fsArgs = LauncherEngine.buildArguments(config: fsConfig, resolvedGameFolder: "/Quake")
        
        #expect(fsArgs.contains("-fullscreen"))
        #expect(hasFlagPair("-width", value: "1920", in: fsArgs))
        #expect(hasFlagPair("-height", value: "1080", in: fsArgs))
        
        // Native Retina не должна передавать фиксированные width/height
        let retinaConfig = makeConfig(fullscreen: false, selectedResolution: "Native Retina")
        let retinaArgs = LauncherEngine.buildArguments(config: retinaConfig, resolvedGameFolder: "/Quake")
        
        #expect(!retinaArgs.contains("-width"))
        #expect(!retinaArgs.contains("-height"))
    }
    
    @Test("Генерация аргументов: частота кадров и логика VSync", arguments: [
        // (vsync, uncapped, targetFPS, ожидаемый host_maxfps)
        (true, false, 120.0, "0"),   // VSync активен -> локаут на 0 (драйверный кап)
        (false, true, 120.0, "0"),   // VSync выкл, Uncapped вкл -> 0
        (false, false, 144.0, "144") // VSync выкл, Uncapped выкл -> заданный таргет
    ])
    func testCommandLineFrameratePacing(vsync: Bool, uncapped: Bool, target: Double, expectedMaxFPS: String) {
        let config = makeConfig(vsync: vsync, uncappedFPS: uncapped, targetFPS: target)
        let args = LauncherEngine.buildArguments(config: config, resolvedGameFolder: "/Quake")
        
        #expect(getCvarValue("vid_vsync", from: args) == (vsync ? "1" : "0"))
        #expect(getCvarValue("host_maxfps", from: args) == expectedMaxFPS)
    }
    
    @Test("Генерация аргументов: режимы MetalFX и шкала разрешения", arguments: [
        (MetalFXMode.disabled.rawValue, MetalFXPreset.quality.rawValue, "0", "0.75"),
        (MetalFXMode.spatial.rawValue, MetalFXPreset.performance.rawValue, "1", "0.50"),
        (MetalFXMode.temporal.rawValue, MetalFXPreset.ultraQuality.rawValue, "2", "0.85")
    ])
    func testCommandLineMetalFXModes(mode: String, preset: String, expectedModeArg: String, expectedScaleArg: String) {
        let config = makeConfig(metalFXMode: mode, metalFXPreset: preset)
        let args = LauncherEngine.buildArguments(config: config, resolvedGameFolder: "/Quake")
        
        #expect(getCvarValue("metalfx_mode", from: args) == expectedModeArg)
        #expect(getCvarValue("metalfx_scale", from: args) == expectedScaleArg)
    }
    
    @Test("Генерация аргументов: правила включения HDR и Bloom")
    func testCommandLineHDRAndBloomInteraction() {
        // 1. Обычный HDR без Bloom
        let c1 = makeConfig(metalFXMode: MetalFXMode.disabled.rawValue, hdrEnabled: true, bloomEnabled: false)
        let a1 = LauncherEngine.buildArguments(config: c1, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("r_hdr", from: a1) == "1")
        #expect(getCvarValue("r_bloom", from: a1) == "0")
        
        // 2. Bloom включен, но HDR выключен -> Bloom должен быть подавлен (0)
        let c2 = makeConfig(metalFXMode: MetalFXMode.disabled.rawValue, hdrEnabled: false, bloomEnabled: true)
        let a2 = LauncherEngine.buildArguments(config: c2, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("r_hdr", from: a2) == "0")
        #expect(getCvarValue("r_bloom", from: a2) == "0")
        
        // 3. Bloom + HDR включены вместе
        let c3 = makeConfig(metalFXMode: MetalFXMode.disabled.rawValue, hdrEnabled: true, bloomEnabled: true)
        let a3 = LauncherEngine.buildArguments(config: c3, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("r_hdr", from: a3) == "1")
        #expect(getCvarValue("r_bloom", from: a3) == "1")
        
        // 4. MetalFX активен -> HDR принудительно активируется даже при hdrEnabled = false
        let c4 = makeConfig(metalFXMode: MetalFXMode.spatial.rawValue, hdrEnabled: false, bloomEnabled: false)
        let a4 = LauncherEngine.buildArguments(config: c4, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("r_hdr", from: a4) == "1")
    }
    
    @Test("Генерация аргументов: аудио бэкенд (AVAudioEngine vs SDL)")
    func testCommandLineAudioBackend() {
        let spatialAudioConfig = makeConfig(enableSpatialAudio: true)
        let spatialArgs = LauncherEngine.buildArguments(config: spatialAudioConfig, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("s_backend", from: spatialArgs) == "av")
        
        let sdlAudioConfig = makeConfig(enableSpatialAudio: false)
        let sdlArgs = LauncherEngine.buildArguments(config: sdlAudioConfig, resolvedGameFolder: "/Quake")
        #expect(getCvarValue("s_backend", from: sdlArgs) == "sdl")
    }
    
    @Test("Генерация аргументов: блокировка аппаратного Ray Tracing без поддержки GPU")
    func testCommandLineRayTracingHardwareGate() {
        // Принудительно задаем отсутствие аппаратных RT-блоков
        let rtConfig = makeConfig(rtEnabled: true)
        let argsNoHW = LauncherEngine.buildArguments(config: rtConfig, resolvedGameFolder: "/Quake", isHardwareRayTracingSupported: false)
        #expect(getCvarValue("r_rt", from: argsNoHW) == "0")
        
        // При наличии аппаратных блоков
        let argsWithHW = LauncherEngine.buildArguments(config: rtConfig, resolvedGameFolder: "/Quake", isHardwareRayTracingSupported: true)
        #expect(getCvarValue("r_rt", from: argsWithHW) == "1")
    }
    
    // MARK: - 4. Тестирование сканера файлов и модов (File Scanner)
    
    @Test("Сканирование директории игры: обнаружение PAK-файлов и установленных модификаций")
    func testFolderScannerDetection() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("MQTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        // Создаем структуру id1 с паками
        let id1Dir = tempDir.appendingPathComponent("id1")
        try fm.createDirectory(at: id1Dir, withIntermediateDirectories: true)
        try Data("pak0".utf8).write(to: id1Dir.appendingPathComponent("pak0.pak"))
        try Data("pak1".utf8).write(to: id1Dir.appendingPathComponent("pak1.PAK")) // проверка case-insensitivity
        try Data("readme".utf8).write(to: id1Dir.appendingPathComponent("readme.txt"))
        
        // Создаем папки модов
        try fm.createDirectory(at: tempDir.appendingPathComponent("hipnotic"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDir.appendingPathComponent("rogue"), withIntermediateDirectories: true)
        // Создаем обычный файл в корне (не должен попасть в mods)
        try Data("autoexec".utf8).write(to: tempDir.appendingPathComponent("autoexec.cfg"))
        
        let engine = LauncherEngine.shared
        var selectedMod = "unknown_mod"
        
        engine.scanFolder(path: tempDir.path, selectedMod: &selectedMod)
        
        #expect(engine.detectedPakFiles.count == 2)
        #expect(engine.detectedPakFiles.contains(where: { $0.lowercased() == "pak0.pak" }))
        #expect(engine.detectedPakFiles.contains(where: { $0.lowercased() == "pak1.pak" }))
        
        #expect(engine.detectedMods.contains("id1"))
        #expect(engine.detectedMods.contains("hipnotic"))
        #expect(engine.detectedMods.contains("rogue"))
        #expect(!engine.detectedMods.contains("autoexec.cfg"))
        // Невалидный выбранный мод должен сброситься на "id1"
        #expect(selectedMod == "id1")
    }
    
    // MARK: - 5. Тестирование санитизации путей в отчете диагностики
    
    @Test("Обезличивание персональных путей пользователя при генерации Copy Summary")
    func testDiagnosticReportHomeDirectorySanitization() async {
        let engine = LauncherEngine.shared
        let homeDir = NSHomeDirectory()
        let privateGamePath = "\(homeDir)/MyPrivateFolder/Quake"
        
        engine.copyDiagnosticReport(
            gameFolderPath: privateGamePath,
            selectedMod: "id1",
            startMap: "start",
            selectedDisplayIndex: 0,
            selectedResolution: "1920x1080",
            metalFXMode: MetalFXMode.disabled.rawValue,
            metalFXPreset: MetalFXPreset.quality.rawValue,
            hdrEnabled: true,
            msaaSamples: 0,
            anisotropy: 16
        )
        
        let pasteboardString = NSPasteboard.general.string(forType: .string) ?? ""
        
        // Путь не должен содержать абсолютный префикс пользователя /Users/username
        #expect(!pasteboardString.contains(homeDir))
        // Должен быть заменен на ~
        #expect(pasteboardString.contains("~/MyPrivateFolder/Quake"))
        #expect(pasteboardString.contains("**MetalQuake Environment Report**"))
        #expect(pasteboardString.contains("Active Mod: id1"))
        
        // Даем асинхронному Task внутри copyDiagnosticReport тик на запуск
        try? await Task.sleep(for: .milliseconds(50))
        #expect(engine.isSummaryCopied == true)
    }
}

// MARK: - Расширение LauncherEngine для чистой сборки аргументов

extension LauncherEngine {
    /// Чистая функция сборки аргументов для запуска C-движка (используется как в тестах, так и в `launchGame`)
    static func buildArguments(
        config: LaunchConfig,
        resolvedGameFolder: String,
        isHardwareRayTracingSupported: Bool = true,
        hasAvailableDisplays: Bool = true
    ) -> [String] {
        var args = ["MetalQuake"]
        
        if !resolvedGameFolder.isEmpty {
            args.append(contentsOf: ["-basedir", resolvedGameFolder])
        }
        if config.selectedMod != "id1" && !config.selectedMod.isEmpty {
            args.append(contentsOf: ["-game", config.selectedMod])
        }
        
        if hasAvailableDisplays {
            args.append(contentsOf: ["-display", String(config.selectedDisplayIndex)])
        }
        
        if config.fullscreen {
            args.append("-fullscreen")
            if config.selectedResolution != "Native Retina" {
                let dims = config.selectedResolution.split(separator: "x")
                if dims.count == 2 {
                    args.append(contentsOf: ["-width", String(dims[0]), "-height", String(dims[1])])
                }
            }
        } else {
            if config.selectedResolution != "Native Retina" {
                let dims = config.selectedResolution.split(separator: "x")
                if dims.count == 2 {
                    args.append(contentsOf: ["-width", String(dims[0]), "-height", String(dims[1])])
                }
            }
        }
        
        let metalFXScale = MetalFXPreset.allCases.first { $0.rawValue == config.metalFXPreset }?.scaleFactor ?? 0.75
        let metalFXArg = config.metalFXMode == MetalFXMode.disabled.rawValue ? "0" :
        (config.metalFXMode == MetalFXMode.temporal.rawValue ? "2" : "1")
        
        args.append(contentsOf: [
            "+set", "gl_texture_anisotropy", "\(config.anisotropy)",
            "+set", "r_lerpmodels", config.lerpModels ? "1" : "0",
            "+set", "r_shadows", config.dynamicShadows ? "1" : "0",
            "+set", "r_pbr", config.pbrEnabled ? "1" : "0",
            "+set", "r_rt", (config.rtEnabled && isHardwareRayTracingSupported) ? "1" : "0",
            "+set", "fov", "\(Int(config.fieldOfView))",
            "+set", "skill", "\(config.skillLevel)",
            "+set", "vid_vsync", config.vsync ? "1" : "0",
            "+set", "vid_preserve_aspect", config.preserveAspect ? "1" : "0",
            "+set", "vid_scale_filter", "\(config.scaleFilter)",
            "+set", "host_maxfps", config.vsync ? "0" : (config.uncappedFPS ? "0" : "\(Int(config.targetFPS))"),
            "+set", "metalfx_mode", metalFXArg,
            "+set", "metalfx_scale", String(format: "%.2f", metalFXScale),
            "+set", "r_hdr", config.hdrEnabled || config.metalFXMode != MetalFXMode.disabled.rawValue ? "1" : "0",
            "+set", "r_bloom", config.bloomEnabled && config.hdrEnabled ? "1" : "0",
            "+set", "r_mq_bloom_quality", "\(config.bloomQuality)",
            "+set", "vid_fsaa", "\(config.msaaSamples)",
            "+set", "s_backend", config.enableSpatialAudio ? "av" : "sdl",
            "+set", "freelook", config.freelook ? "1" : "0",
            "+set", "crosshair", config.crosshairEnabled ? "1" : "0",
            "+set", "scr_sbarscale", "0",
            "+set", "scr_menuscale", "0",
            "+set", "scr_conscale", "0",
            "+set", "scr_crosshairscale", "0",
            "+set", "gamma", String(format: "%.2f", config.gammaValue),
            "+set", "contrast", String(format: "%.2f", config.contrastValue)
        ])
        
        if !config.startMap.isEmpty {
            args.append(contentsOf: ["+map", config.startMap])
        }
        
        return args
    }
}
