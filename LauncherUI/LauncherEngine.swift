//
//  LauncherEngine.swift
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import SwiftUI
import AppKit
import Combine
import Metal
import MetalFX
import CoreText

// MARK: - Quake Font Manager

/// Manages bitmap and vector font loading for DpQuake
enum QuakeFont {
    static let fontName = "DpQuake"
    
    // Lazy registration evaluated prior to constructing initial SwiftUI Text views
    private static let _autoRegister: Void = {
        registerIfNeeded()
    }()
    
    static func registerIfNeeded() {
        guard let url = Bundle.main.url(forResource: "DpQuake", withExtension: "ttf") else {
            print("[Font] ERROR: DpQuake TTF not found in bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Re-registration errors (kCTFontManagerErrorAlreadyRegistered = 105) are safely ignored
        }
    }
    
    static func font(size: CGFloat) -> Font {
        _ = _autoRegister
        return Font.custom(fontName, size: size)
    }
}

// MARK: - MetalFX Capabilities

/// Queries hardware capabilities of the active Apple Silicon GPU
final class MetalFXCapabilities {
    static let shared = MetalFXCapabilities()
    
    let isSpatialSupported: Bool
    let isTemporalSupported: Bool
    let isHardwareRayTracingSupported: Bool
    let gpuName: String
    
    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.isSpatialSupported = false
            self.isTemporalSupported = false
            self.isHardwareRayTracingSupported = false
            self.gpuName = "Unknown GPU"
            return
        }
        self.gpuName = device.name
        self.isSpatialSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        self.isTemporalSupported = MTLFXTemporalScalerDescriptor.supportsDevice(device)
        
        // Hardware ray tracing acceleration is available in Apple 9 GPU family (M3, M4, and newer)
        if #available(macOS 14.0, *) {
            self.isHardwareRayTracingSupported = device.supportsFamily(.apple9) && device.supportsRaytracing
        } else {
            self.isHardwareRayTracingSupported = false
        }
    }
}

// MARK: - Session Log File Manager

/// Manages disk-backed session log files
final class LogFileManager {
    static let shared = LogFileManager()
    
    var logsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logsDir = appSupport.appendingPathComponent("MetalQuake/Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir
    }
    
    @discardableResult
    func startNewSession() -> String {
        let dirPath = logsDirectoryURL.path
        if let cPath = MLog_InitSession(dirPath) {
            return String(cString: cPath)
        }
        return ""
    }
    
    func closeSession() {
        MLog_CloseSession()
    }
    
    func revealInFinder() {
        if let cPath = MLog_GetCurrentLogPath(), strlen(cPath) > 0 {
            let path = String(cString: cPath)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: logsDirectoryURL.path)
                return
            }
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsDirectoryURL.path)
    }
    
    func openInDefaultEditor() {
        if let cPath = MLog_GetCurrentLogPath(), strlen(cPath) > 0 {
            let path = String(cString: cPath)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return
            }
        }
        NSWorkspace.shared.open(logsDirectoryURL)
    }
}

// MARK: - Engine Launch Configuration

/// Configuration snapshot passed to C engine launch arguments
struct LaunchConfig {
    var gameFolderPath: String
    var gameFolderBookmarkB64: String
    var selectedMod: String
    var startMap: String
    var skillLevel: Int
    
    var selectedDisplayIndex: Int
    var fullscreen: Bool
    var selectedResolution: String
    var preserveAspect: Bool
    var scaleFilter: Int
    var vsync: Bool
    var uncappedFPS: Bool
    var targetFPS: Double
    
    var gammaValue: Double
    var contrastValue: Double
    
    var metalFXMode: String
    var metalFXPreset: String
    var anisotropy: Int
    var waterAlpha: Double
    var lerpModels: Bool
    var dynamicShadows: Bool
    var pbrEnabled: Bool
    var rtEnabled: Bool
    var hdrEnabled: Bool
    var bloomEnabled: Bool
    var bloomQuality: Int
    var msaaSamples: Int
    var freelook: Bool
    var crosshairEnabled: Bool
    var fieldOfView: Double
    
    var enableSpatialAudio: Bool
    var sfxVolume: Double
    var bgmVolume: Double
}

// MARK: - Launcher Core Engine & Coordinator

/// Central coordinator managing launcher state, display enumeration, and C engine execution
@MainActor
final class LauncherEngine: ObservableObject {
    static let shared = LauncherEngine()
    
    // Dynamic scanning and process states
    @Published var detectedPakFiles: [String] = []
    @Published var detectedMods: [String] = ["id1"]
    @Published var availableDisplays: [DisplayOption] = []
    @Published var availableResolutions: [String] = ["1920x1080", "Native Retina"]
    @Published var currentLogFileDisplay: String = "No active session"
    @Published var isEngineRunning: Bool = false
    @Published var hasPlayedOnce: Bool = false
    @Published var isSummaryCopied: Bool = false
    private var copyFeedbackTask: Task<Void, Never>?
    
    /// Launcher version string from Info.plist
    var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
    
    /// Security-scoped URL for accessing the game directory under App Sandbox
    private var securityScopeURL: URL?
    
    let fxCaps = MetalFXCapabilities.shared
    
    init() {}
    
    // MARK: - Diagnostics & Logging
    
    func applyLogProfile(_ profile: Int) {
        MLog_SetProfile(Int32(profile))
    }
    
    func appendLog(_ text: String) {
        MLog_WriteString(text)
    }
    
    func refreshCurrentLogDisplay() {
        if let cPath = MLog_GetCurrentLogPath(), strlen(cPath) > 0 {
            currentLogFileDisplay = URL(fileURLWithPath: String(cString: cPath)).lastPathComponent
        } else {
            currentLogFileDisplay = "Will be created on launch"
        }
    }
    
    /// Generates sanitized environment summary without user paths and copies to clipboard
    func copyDiagnosticReport(
        gameFolderPath: String,
        selectedMod: String,
        startMap: String,
        selectedDisplayIndex: Int,
        selectedResolution: String,
        metalFXMode: String,
        metalFXPreset: String,
        hdrEnabled: Bool,
        msaaSamples: Int,
        anisotropy: Int
    ) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        
        // Sanitize path: replace /Users/username with tilde ~
        let homeDir = NSHomeDirectory()
        let sanitizedPath = gameFolderPath.isEmpty ? "Not selected" : gameFolderPath.replacingOccurrences(of: homeDir, with: "~")
        let mapName = startMap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "start" : startMap
        
        let report = """
            **MetalQuake Environment Report**
            - App Version: \(appVersionString)
            - OS: \(osString)
            - Hardware: \(fxCaps.gpuName)
            - Active Mod: \(selectedMod) | Map: \(mapName)
            - Display: \(selectedResolution) (Display #\(selectedDisplayIndex))
            - MetalFX: \(metalFXMode) (\(metalFXPreset))
            - Graphics: HDR: \(hdrEnabled ? "On" : "Off") | MSAA: \(msaaSamples)x | Aniso: \(anisotropy)x
            - Game Path: \(sanitizedPath)
            - Session Log: \(currentLogFileDisplay)
            """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        appendLog("[Diagnostics] Environment summary copied to clipboard.\n")
        
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            isSummaryCopied = true
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                isSummaryCopied = false
            }
        }
    }
    
    // MARK: - Display Service
    
    /// Returns native physical panel resolution (maximum 1:1 pixel mode)
    private func nativePixelSize(_ screen: NSScreen) -> (Int, Int)? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        let native = modes.filter { $0.pixelWidth == $0.width && $0.pixelHeight == $0.height }
        guard let best = native.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }
        return (best.width, best.height)
    }
    
    /// Enumerates displays preserving order matching underlying engine logic
    func scanDisplays(selectedDisplayIndex: Int, selectedResolution: inout String) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        
        let screens = NSScreen.screens
        var result: [DisplayOption] = []
        for index in 0..<Int(count) {
            let displayID = ids[index]
            let screen = screens.first(where: { scr in
                (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            })
            let name: String
            let pixelSize: String
            if let screen = screen {
                name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
                let (w, h) = nativePixelSize(screen) ?? (Int(screen.frame.size.width), Int(screen.frame.size.height))
                pixelSize = "\(w)x\(h)"
            } else {
                name = "Display \(index + 1)"
                pixelSize = "?"
            }
            let isMain = displayID == CGMainDisplayID() ? " (Main)" : ""
            result.append(DisplayOption(id: index, name: name + isMain, pixelSize: pixelSize))
        }
        availableDisplays = result
        reloadResolutions(displayIndex: selectedDisplayIndex, selectedResolution: &selectedResolution)
        appendLog("[Display] Displays discovered: \(availableDisplays.count) — " +
                  availableDisplays.map { "\($0.id):\($0.name) \($0.pixelSize)" }.joined(separator: "; ") + "\n")
    }
    
    /// Enumerates supported resolutions for the selected display
    func reloadResolutions(displayIndex: Int, selectedResolution: inout String) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        guard displayIndex < Int(count) else {
            availableResolutions = ["Native Retina"]
            return
        }
        let displayID = ids[displayIndex]
        
        var modes: Set<String> = []
        var totalModes = 0
        if let allModes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] {
            totalModes = allModes.count
            for m in allModes {
                guard m.pixelWidth == m.width,
                      m.pixelHeight == m.height else { continue }
                
                if m.width <= LauncherConstants.metalMaxTextureEdge && m.height <= LauncherConstants.metalMaxTextureEdge {
                    modes.insert("\(m.width)x\(m.height)")
                }
            }
        }
        appendLog("[Display] Display #\(displayIndex) modes: \(totalModes) total, \(modes.count) native\n")
        
        for res in LauncherConstants.standardResolutions {
            modes.insert(res)
        }
        
        let sorted = modes.sorted {
            let a = $0.split(separator: "x").compactMap { Int($0) }
            let b = $1.split(separator: "x").compactMap { Int($0) }
            return (a.first ?? 0) * (a.last ?? 0) > (b.first ?? 0) * (b.last ?? 0)
        }
        availableResolutions = sorted + ["Native Retina"]
        
        if !availableResolutions.contains(selectedResolution) {
            selectedResolution = "Native Retina"
        }
    }
    
    // MARK: - Game Folder & Sandbox Access
    
    /// Presents directory chooser dialog for Quake folder and creates security-scoped bookmark
    func selectGameFolder(selectedMod: inout String) -> (path: String, bookmarkB64: String)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            var bookmarkB64 = ""
            if let data = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
                bookmarkB64 = data.base64EncodedString()
                appendLog("[Launcher] Game folder bookmark saved: \(path)\n")
            } else {
                appendLog("[Launcher] WARNING: Failed to create bookmark for game directory\n")
            }
            scanFolder(path: path, selectedMod: &selectedMod)
            return (path, bookmarkB64)
        }
        return nil
    }
    
    /// Resolves security-scoped bookmark prior to starting the engine
    @discardableResult
    func resolveGameFolderAccess(path: inout String, bookmarkB64: String, selectedMod: inout String) -> String? {
        if let url = securityScopeURL {
            return path.isEmpty ? url.path : path
        }
        
        if !bookmarkB64.isEmpty, let data = Data(base64Encoded: bookmarkB64) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() {
                    securityScopeURL = url
                    let resolvedPath = url.path
                    if path != resolvedPath {
                        path = resolvedPath
                        scanFolder(path: resolvedPath, selectedMod: &selectedMod)
                    }
                    appendLog("[Launcher] Game folder access granted via bookmark: \(resolvedPath)\n")
                    return resolvedPath
                }
            }
            appendLog("[Launcher] WARNING: Game folder bookmark failed to resolve — reselect folder\n")
        }
        
        if !path.isEmpty {
            appendLog("[Launcher] WARNING: Path '\(path)' may lack access in App Sandbox without bookmark — reselect via Browse…\n")
            return path
        }
        return nil
    }
    
    func stopGameFolderAccess() {
        if let url = securityScopeURL {
            url.stopAccessingSecurityScopedResource()
            securityScopeURL = nil
            appendLog("[Launcher] Game folder security scope released\n")
        }
    }
    
    /// Scans game directory for id1 folder, PAK archives, and installed game modifications
    func scanFolder(path: String, selectedMod: inout String) {
        let fm = FileManager.default
        detectedPakFiles.removeAll()
        detectedMods.removeAll()
        
        let id1Path = (path as NSString).appendingPathComponent("id1")
        if let files = try? fm.contentsOfDirectory(atPath: id1Path) {
            detectedPakFiles = files.filter { $0.lowercased().hasSuffix(".pak") }
        }
        
        if let subdirs = try? fm.contentsOfDirectory(atPath: path) {
            for dir in subdirs {
                var isDir: ObjCBool = false
                let fullPath = (path as NSString).appendingPathComponent(dir)
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    detectedMods.append(dir)
                }
            }
        }
        
        if !detectedMods.contains("id1") {
            detectedMods.insert("id1", at: 0)
        }
        if !detectedMods.contains(selectedMod) {
            selectedMod = "id1"
        }
        
        appendLog("[Scanner] Found \(detectedPakFiles.count) PAKs in 'id1'. Subdirectories: \(detectedMods.joined(separator: ", "))\n")
    }
    
    // MARK: - Engine Boot & Execution
    
    /// Assembles command line arguments and boots the C-based Metal engine runtime
    func launchGame(config: LaunchConfig, onFolderMissing: () -> Void) {
        isEngineRunning = true
        
        let logPath = LogFileManager.shared.startNewSession()
        currentLogFileDisplay = URL(fileURLWithPath: logPath).lastPathComponent
        
        var currentPath = config.gameFolderPath
        var currentMod = config.selectedMod
        guard let resolvedGameFolder = resolveGameFolderAccess(path: &currentPath,
                                                               bookmarkB64: config.gameFolderBookmarkB64,
                                                               selectedMod: &currentMod) else {
            isEngineRunning = false
            appendLog("[Launcher] ERROR: Game directory not specified — provide path or select via Browse…\n")
            onFolderMissing()
            return
        }
        
        let launchT0 = Date()
        appendLog("[Launch] \(Int(launchT0.timeIntervalSince1970)) Launch requested, preparing arguments…\n")
        
        var args = ["MetalQuake"]
        
        if !resolvedGameFolder.isEmpty {
            args.append(contentsOf: ["-basedir", resolvedGameFolder])
        }
        if config.selectedMod != "id1" && !config.selectedMod.isEmpty {
            args.append(contentsOf: ["-game", config.selectedMod])
        }
        
        if !availableDisplays.isEmpty {
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
            "+set", "r_rt", (config.rtEnabled && fxCaps.isHardwareRayTracingSupported) ? "1" : "0",
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
        
        appendLog("\n[Launcher] Booting C-Engine on main thread with args:\n\(args.joined(separator: " "))\n\n")
        
        DispatchQueue.main.async {
            let launcherWindow = NSApp.keyWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) })
            AppDelegate.launcherWindowRef = launcherWindow
            // Hide launcher window during gameplay to prevent system overlays and Game Center from stealing focus
            launcherWindow?.orderOut(nil)
            
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            
            let cArgs = args.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            
            var cArgsArray = cArgs
            self.appendLog(String(format: "[Launch] Engine launched in %.2fs after click\n", Date().timeIntervalSince(launchT0)))
            
            AppDelegate.isGameRunning = true
            
            while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            
            var result: Int32 = 0
            autoreleasepool {
                result = QuakeEngine_Main(Int32(cArgs.count), &cArgsArray)
            }
            
            while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                _ = event
            }
            
            AppDelegate.isGameRunning = false
            self.isEngineRunning = false
            self.hasPlayedOnce = true
            
            self.appendLog(String(format: "[Launch] Engine terminated, code %d, total elapsed time %.2fs\n", result, Date().timeIntervalSince(launchT0)))
            self.appendLog("[Launcher] Engine terminated with exit code: \(result)\n")
            self.appendLog("[Launcher] Launcher restart required to start a new session.\n")
            
            LogFileManager.shared.closeSession()
            self.stopGameFolderAccess()
            AppDelegate.restoreLauncherWindow()
        }
    }
    
    /// Restarts the launcher application process
    func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.appendLog("[Launcher] Failed to relaunch: \(error.localizedDescription)\n")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
