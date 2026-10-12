//
//  MetalQuakeLauncher.swift
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import SwiftUI
import AppKit

// MARK: - Main Launcher View

/// Primary MetalQuake launcher window: manages tab navigation, AppStorage state bindings, and engine bootstrapping
struct MetalQuakeLauncher: View {
    // Shared engine logic coordinator
    @StateObject private var engine = LauncherEngine.shared
    
    // Internal navigation and modal presentation state
    @State private var activeTab: LauncherTab = .game
    @State private var showAboutSheet: Bool = false
    @State private var showResetAlert: Bool = false
    static let showAboutNotification = Notification.Name("MQShowAboutNotification")
    
    // --- Game & Mod Configuration ---
    @AppStorage("gameFolderPath") private var gameFolderPath: String = ""
    @AppStorage("gameFolderBookmarkB64") private var gameFolderBookmarkB64: String = ""
    @AppStorage("selectedMod") private var selectedMod: String = "id1"
    @AppStorage("startMap") private var startMap: String = "start"
    @AppStorage("skillLevel") private var skillLevel: Int = 1
    
    // --- Metal 3 & MetalFX Configuration ---
    @AppStorage("metalFXMode") private var metalFXMode: String = MetalFXMode.disabled.rawValue
    @AppStorage("metalFXPreset") private var metalFXPreset: String = MetalFXPreset.quality.rawValue
    @AppStorage("anisotropy") private var anisotropy: Int = 16
    @AppStorage("waterAlpha") private var waterAlpha: Double = 0.70
    @AppStorage("lerpModels") private var lerpModels: Bool = true
    @AppStorage("dynamicShadows") private var dynamicShadows: Bool = false
    @AppStorage("pbrEnabled") private var pbrEnabled: Bool = false
    @AppStorage("rtEnabled") private var rtEnabled: Bool = false
    @AppStorage("hdrEnabled") private var hdrEnabled: Bool = true
    @AppStorage("bloomEnabled") private var bloomEnabled: Bool = false
    @AppStorage("bloomQuality") private var bloomQuality: Int = 0 // 0 = High, 1 = Performance
    @AppStorage("msaaSamples") private var msaaSamples: Int = 0
    @AppStorage("freelook") private var freelook: Bool = true
    @AppStorage("crosshairEnabled") private var crosshairEnabled: Bool = true
    @AppStorage("fieldOfView") private var fieldOfView: Double = 90.0
    
    // --- Display & Resolution Configuration ---
    @AppStorage("fullscreen") private var fullscreen: Bool = false
    @AppStorage("preserveAspect") private var preserveAspect: Bool = false
    @AppStorage("scaleFilter") private var scaleFilter: Int = 0 // 0 = Linear, 1 = Nearest
    @AppStorage("selectedResolution") private var selectedResolution: String = "1920x1080"
    @AppStorage("selectedDisplayIndex") private var selectedDisplayIndex: Int = 0
    @AppStorage("vsync") private var vsync: Bool = true
    @AppStorage("targetFPS") private var targetFPS: Double = 120
    @AppStorage("uncappedFPS") private var uncappedFPS: Bool = true
    
    // --- Gamma & Contrast Configuration (Neutral QuakeSpasm baseline = 1.0) ---
    @AppStorage("gammaValue") private var gammaValue: Double = 1.0
    @AppStorage("contrastValue") private var contrastValue: Double = 1.0
    
    // --- Audio Configuration ---
    @AppStorage("enableSpatialAudio") private var enableSpatialAudio: Bool = true
    @AppStorage("bgmVolume") private var bgmVolume: Double = 0.7
    @AppStorage("sfxVolume") private var sfxVolume: Double = 0.8
    
    // --- Diagnostics & Logging Configuration ---
    @AppStorage("logProfile") private var logProfile: Int = MQLogProfile.release.rawValue
    
    /// Launcher version string from main bundle Info.plist
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
    
    /// Contextual compatibility guidance regarding MSAA and MetalFX scaling
    private var msaaHint: (icon: String, color: Color, text: String) {
        let isUpscalerActive = (metalFXMode != MetalFXMode.disabled.rawValue)
        let samples = msaaSamples
        
        if isUpscalerActive {
            if samples == 0 {
                return ("checkmark.circle.fill", .green,
                        "Optimal: Upscaler resolves edge anti-aliasing without additional compute overhead.")
            } else {
                return ("exclamationmark.triangle.fill", .orange,
                        "Upscaler already provides edge anti-aliasing. Adding MSAA introduces redundant overhead and degrades performance. 'Off' recommended.")
            }
        } else {
            if samples >= 2 {
                return ("checkmark.circle.fill", .green,
                        "MSAA smooths geometry silhouettes at native resolution.")
            } else {
                return ("info.circle.fill", .blue,
                        "When running without upscaling, enabling 2x or 4x MSAA mitigates edge aliasing on geometry.")
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header: Title and version badge
            headerView
            
            // Tab navigation bar and preferences reset trigger
            HStack(spacing: 8) {
                Picker("", selection: $activeTab) {
                    ForEach(LauncherTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                
                Button(action: { showResetAlert = true }) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help("Reset all settings to defaults")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            
            Divider()
            
            // Scrollable settings pane for active tab
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch activeTab {
                    case .game:
                        gameSettingsSection
                    case .display:
                        displaySettingsSection
                    case .graphics:
                        graphicsSettingsSection
                    case .audio:
                        audioSettingsSection
                    case .support:
                        supportSettingsSection
                    }
                }
                .padding(14)
            }
            
            Divider()
            
            // Bottom execution bar and status indicator
            bottomLaunchBar
        }
        .frame(minWidth: 630, minHeight: 620)
        .alert("Reset Settings", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { resetToDefaults() }
        } message: {
            Text("Are you sure you want to restore all launcher settings to default values?")
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.showAboutNotification)) { _ in
            showAboutSheet = true
        }
        .sheet(isPresented: $showAboutSheet) {
            AboutMetalQuakeView()
        }
        .onAppear {
            QuakeFont.registerIfNeeded()
            
            // Resolve game directory via App Sandbox security-scoped bookmark
            _ = engine.resolveGameFolderAccess(path: &gameFolderPath,
                                               bookmarkB64: gameFolderBookmarkB64,
                                               selectedMod: &selectedMod)
            
            if !gameFolderPath.isEmpty {
                engine.scanFolder(path: gameFolderPath, selectedMod: &selectedMod)
            }
            
            engine.scanDisplays(selectedDisplayIndex: selectedDisplayIndex, selectedResolution: &selectedResolution)
            engine.applyLogProfile(logProfile)
            engine.refreshCurrentLogDisplay()
            
            // Automated launch trigger for diagnostics via MQ_AUTOLAUNCH=1
            if ProcessInfo.processInfo.environment["MQ_AUTOLAUNCH"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    triggerLaunch()
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("METALQUAKE")
                    .font(QuakeFont.font(size: 30))
                    .tracking(2)
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 0.24, green: 0.11, blue: 0.05), location: 0.0),
                                .init(color: Color(red: 0.55, green: 0.24, blue: 0.08), location: 0.28),
                                .init(color: Color(red: 0.82, green: 0.48, blue: 0.18), location: 0.62),
                                .init(color: Color(red: 0.95, green: 0.75, blue: 0.42), location: 0.88),
                                .init(color: Color(red: 1.00, green: 0.90, blue: 0.70), location: 1.0)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .shadow(color: Color.black.opacity(0.95), radius: 1.5, x: 0, y: 2)
                    .shadow(color: Color(red: 0.85, green: 0.35, blue: 0.08).opacity(0.35), radius: 4, x: 0, y: 0)
                
                Text(appVersionString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
    
    // MARK: - Tab: Game & Mods
    
    private var gameSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: HStack(spacing: 6) {
                Label("Game Data Directory", systemImage: "folder.fill").bold()
                InfoHelpButton(text: """
                Select the main Quake installation folder.
                The launcher expects this root folder to contain an 'id1' subfolder with 'pak0.pak'.
                
                Place all expansions and community mods alongside 'id1':
                • Quake/id1 (Base Game)
                • Quake/hipnotic (Mission Pack 1)
                • Quake/rogue (Mission Pack 2)
                
                Detected mods will appear in the selector below.
                """)
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Select Quake installation folder...", text: $gameFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Browse...") {
                            if let result = engine.selectGameFolder(selectedMod: &selectedMod) {
                                self.gameFolderPath = result.path
                                self.gameFolderBookmarkB64 = result.bookmarkB64
                            }
                        }
                    }
                    
                    if !engine.detectedPakFiles.isEmpty {
                        Label("Found: \(engine.detectedPakFiles.joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else {
                        HStack(spacing: 6) {
                            Label("Requires folder containing 'id1' with pak0.pak", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            
                            Text("Example: Quake / id1 / pak0.pak")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(6)
            }
            
            GroupBox(label: Label("Mission Pack & Campaign", systemImage: "puzzlepiece.extension.fill").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Active Mod / Game:", selection: $selectedMod) {
                        ForEach(engine.detectedMods, id: \.self) { mod in
                            Text(mod).tag(mod)
                        }
                        if !engine.detectedMods.contains(selectedMod) {
                            Text(selectedMod).tag(selectedMod)
                        }
                    }
                    
                    Picker("Difficulty:", selection: $skillLevel) {
                        ForEach(0..<LauncherConstants.skillNames.count, id: \.self) { i in
                            Text(LauncherConstants.skillNames[i]).tag(i)
                        }
                    }
                    
                    HStack {
                        Text("Starting Map:")
                        Spacer()
                        TextField("e.g. start, e1m1", text: $startMap)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .autocorrectionDisabled(true)
                    }
                }
                .padding(6)
            }
            
            GroupBox(label: Label("Controls & View", systemImage: "scope").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Field of View (FOV):")
                            Spacer()
                            resettableValueBadge(text: "\(Int(fieldOfView))°", defaultValueTitle: "90°") {
                                fieldOfView = 90.0
                            }
                        }
                        Slider(value: $fieldOfView, in: 75...120, step: 1.0)
                    }
                    
                    Toggle("Vertical Mouse Look (Freelook)", isOn: $freelook)
                    Toggle("Crosshair", isOn: $crosshairEnabled)
                }
                .padding(6)
            }
        }
    }
    
    // MARK: - Tab: Display
    
    private var displaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("Display & Video", systemImage: "macwindow").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Monitor:", selection: $selectedDisplayIndex) {
                        ForEach(engine.availableDisplays) { display in
                            Text("\(display.name) — \(display.pixelSize)").tag(display.id)
                        }
                    }
                    .onChange(of: selectedDisplayIndex) { _, newIndex in
                        engine.reloadResolutions(displayIndex: newIndex, selectedResolution: &selectedResolution)
                    }
                    
                    Picker("Render Resolution:", selection: $selectedResolution) {
                        ForEach(engine.availableResolutions, id: \.self) { res in
                            Text(res).tag(res)
                        }
                    }
                    .disabled(metalFXMode != MetalFXMode.disabled.rawValue)
                    .opacity(metalFXMode != MetalFXMode.disabled.rawValue ? 0.5 : 1.0)
                    
                    if metalFXMode != MetalFXMode.disabled.rawValue {
                        Text("MetalFX active: Output is locked to native display (\(engine.availableDisplays.first(where: { $0.id == selectedDisplayIndex })?.pixelSize ?? "4K")), internal resolution is governed by MetalFX Preset.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else {
                        Text("Display stays in native desktop mode; 3D scene renders at selected resolution.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Gamma:")
                                Spacer()
                                resettableValueBadge(text: String(format: "%.2f", gammaValue), defaultValueTitle: "1.00") {
                                    gammaValue = 1.0
                                }
                            }
                            Slider(value: $gammaValue, in: 0.5...2.0, step: 0.05)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Contrast:")
                                Spacer()
                                resettableValueBadge(text: String(format: "%.2f", contrastValue), defaultValueTitle: "1.00") {
                                    contrastValue = 1.0
                                }
                            }
                            Slider(value: $contrastValue, in: 1.0...2.0, step: 0.05)
                        }
                        Text("Recommended for optimal visuals: Gamma 0.9, Contrast 1.4")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 12) {
                        Label(engine.fxCaps.gpuName, systemImage: "cpu.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Label("Render up to 16K (Metal texture limit \(LauncherConstants.metalMaxTextureEdge)px)",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    
                    Toggle("Fullscreen Mode (Desktop)", isOn: $fullscreen)
                    Toggle("Preserve Aspect Ratio (Pillarbox 4:3)", isOn: $preserveAspect)
                    
                    if metalFXMode == MetalFXMode.disabled.rawValue {
                        Picker("Scaling Filter:", selection: $scaleFilter) {
                            Text("Smooth (Bilinear)").tag(0)
                            Text("Crisp Pixels (Nearest)").tag(1)
                        }
                    }
                    
                    Toggle("Vertical Synchronization (VSync)", isOn: $vsync)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Target Frame Rate:")
                            Spacer()
                            if vsync {
                                Text("Display VSync").monospacedDigit().bold().foregroundColor(.secondary)
                            } else if uncappedFPS {
                                Text("Uncapped").monospacedDigit().bold().foregroundColor(.secondary)
                            } else {
                                resettableValueBadge(text: "\(Int(targetFPS)) FPS", defaultValueTitle: "120 FPS") {
                                    targetFPS = 120.0
                                }
                            }
                        }
                        
                        Toggle("Uncapped (when VSync is off)", isOn: $uncappedFPS)
                            .disabled(vsync)
                            .opacity(vsync ? 0.4 : 1.0)
                        
                        Slider(value: $targetFPS, in: 30...240, step: 10)
                            .disabled(vsync || uncappedFPS)
                            .opacity((vsync || uncappedFPS) ? 0.4 : 1.0)
                        
                        if vsync {
                            Text("Frame rate is locked to the display's refresh rate. Software FPS caps are disabled to prevent double-pacing.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(6)
            }
        }
    }
    
    // MARK: - Tab: Graphics & MetalFX
    
    private var graphicsSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("MetalFX Upscaling", systemImage: "wand.and.stars").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("MetalFX Mode:", selection: $metalFXMode) {
                        Text(MetalFXMode.disabled.rawValue).tag(MetalFXMode.disabled.rawValue)
                        
                        Text(MetalFXMode.spatial.rawValue)
                            .tag(MetalFXMode.spatial.rawValue)
                            .opacity(engine.fxCaps.isSpatialSupported ? 1.0 : 0.5)
                        
                        Text(MetalFXMode.temporal.rawValue)
                            .tag(MetalFXMode.temporal.rawValue)
                            .opacity(engine.fxCaps.isTemporalSupported ? 1.0 : 0.5)
                    }
                    
                    if metalFXMode != MetalFXMode.disabled.rawValue {
                        Picker("Render Preset:", selection: $metalFXPreset) {
                            ForEach(MetalFXPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset.rawValue)
                            }
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Label("Spatial: \(engine.fxCaps.isSpatialSupported ? "Available" : "Unsupported")",
                              systemImage: engine.fxCaps.isSpatialSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(engine.fxCaps.isSpatialSupported ? .green : .secondary)
                        
                        Label("Temporal: \(engine.fxCaps.isTemporalSupported ? "Available" : "Unsupported")",
                              systemImage: engine.fxCaps.isTemporalSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(engine.fxCaps.isTemporalSupported ? .green : .secondary)
                    }
                }
                .padding(6)
            }
            
            GroupBox(label: Label("Graphics & Metal Pipeline", systemImage: "slider.horizontal.3").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Picker("Anisotropic Filtering:", selection: $anisotropy) {
                            ForEach(LauncherConstants.anisoLevels, id: \.self) { level in
                                Text(level == 1 ? "Off (1x)" : "\(level)x").tag(level)
                            }
                        }
                        InfoHelpButton(text: "Mitigates texture blur across oblique floor, ceiling, and wall angles, preserving high texture clarity into the distance.")
                    }
                    
                    HStack(spacing: 6) {
                        Toggle("", isOn: $lerpModels)
                            .labelsHidden()
                        Text("Model Animation Smoothing (Lerp)")
                        InfoHelpButton(text: "Classic 1996 Quake animates entities at fixed 10 Hz frame steps. This option interpolates intermediate keyframes for smooth entity animations at high frame rates.")
                        Spacer()
                    }
                    
                    HStack(spacing: 6) {
                        Toggle("", isOn: $hdrEnabled)
                            .labelsHidden()
                        Text("HDR Pipeline (RGBA16Float + EDR)")
                        InfoHelpButton(text: "Enables 16-bit floating-point scene rendering with Extended Dynamic Range (EDR). Liquid Retina XDR displays can render specular highlights brighter than standard white without clipping.")
                        Spacer()
                    }
                    
                    HStack(spacing: 6) {
                        Toggle("", isOn: $bloomEnabled)
                            .labelsHidden()
                            .disabled(!hdrEnabled)
                        Text("Bloom (glow on bright lights)")
                            .foregroundColor(!hdrEnabled ? .secondary : .primary)
                        InfoHelpButton(text: "Adds optical light bleed around lava, teleporters, torches, and rocket explosions. Requires HDR enabled.")
                        Spacer()
                    }
                    
                    if bloomEnabled && hdrEnabled {
                        Picker("Bloom Quality:", selection: $bloomQuality) {
                            Text("High (1/2 res)").tag(0)
                            Text("Performance (1/4 res)").tag(1)
                        }
                        .pickerStyle(.menu)
                    }
                    
                    HStack(spacing: 6) {
                        Toggle("", isOn: $pbrEnabled)
                            .labelsHidden()
                        Text("Physically Based Rendering (PBR)")
                        InfoHelpButton(text: "Applies physical roughness, metallic, and normal map material models to surfaces. Torches and muzzle flashes produce realistic specular highlights on wet masonry, floors, and armor.")
                        Spacer()
                    }
                    
                    HStack(spacing: 6) {
                        Picker("MSAA (Anti-Aliasing):", selection: $msaaSamples) {
                            Text("Off (0x)").tag(0)
                            Text("2x MSAA").tag(2)
                            Text("4x MSAA").tag(4)
                            Text("8x MSAA").tag(8)
                        }
                        .pickerStyle(.menu)
                        InfoHelpButton(text: "Hardware multisample anti-aliasing resolving geometric polygon edges.")
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: msaaHint.icon)
                                .foregroundColor(msaaHint.color)
                                .font(.caption2)
                            Text(msaaHint.text)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Toggle("", isOn: $dynamicShadows)
                            .labelsHidden()
                        Text("Entity Shadows (under models)")
                        InfoHelpButton(text: "Classic polygonal projection shadows cast by entities and weapon models. Supported across all Mac hardware configurations.")
                        Spacer()
                    }
                }
                .padding(6)
            }
            
            GroupBox(label: Label("Hardware Ray Tracing (Experimental)", systemImage: "rays").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    if engine.fxCaps.isHardwareRayTracingSupported {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $rtEnabled)
                                .labelsHidden()
                            Text("Ray Tracing: Light Shadows (MetalRT)")
                            InfoHelpButton(text: "Hardware-accelerated shadow ray traversal utilizing Apple M3/M4 RT cores. Muzzle flashes and rocket explosions project real-time ray-traced shadows from world geometry.")
                            Spacer()
                        }
                        
                        Label("Hardware RT acceleration active (\(engine.fxCaps.gpuName))", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                                .font(.body)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Requires Apple Silicon with RT cores (M3 and newer)")
                                    .font(.caption)
                                    .bold()
                                Text("Hardware ray tracing is unavailable on the active GPU (\(engine.fxCaps.gpuName)). The engine runs using the high-performance rasterization pipeline.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(6)
            }
        }
    }
    
    // MARK: - Tab: Audio
    
    private var audioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(label: Label("Audio Architecture", systemImage: "waveform").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Spatial 3D Audio (AVAudioEngine)", isOn: $enableSpatialAudio)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Sound Effects (SFX):")
                            Spacer()
                            resettableValueBadge(text: "\(Int(sfxVolume * 100))%", defaultValueTitle: "80%") {
                                sfxVolume = 0.8
                            }
                        }
                        Slider(value: $sfxVolume, in: 0.0...1.0, step: 0.05)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Background Music (BGM):")
                            Spacer()
                            resettableValueBadge(text: "\(Int(bgmVolume * 100))%", defaultValueTitle: "70%") {
                                bgmVolume = 0.7
                            }
                        }
                        Slider(value: $bgmVolume, in: 0.0...1.0, step: 0.05)
                    }
                }
                .padding(6)
            }
        }
    }
    
    // MARK: - Tab: Support & Diagnostics
    
    private var supportSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            // Block 1: Source code repository and issue tracker
            GroupBox(label: Label("Community & Source Code", systemImage: "network").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MetalQuake is an open-source project. Source code, Metal 3 shaders, and the issue tracker are hosted on GitHub.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/aloysha976/MetalQuake")!) {
                            Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .buttonStyle(.bordered)
                        
                        Link(destination: URL(string: "https://github.com/aloysha976/MetalQuake/issues")!) {
                            Label("Report an Issue", systemImage: "ladybug.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(6)
            }
            
            // Block 2: Session logs, profiles, and environment telemetry export
            GroupBox(label: Label("Diagnostics & Session Logs", systemImage: "slider.horizontal.below.square.and.square.filled").bold()) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Profile:", selection: $logProfile) {
                        ForEach(MQLogProfile.allCases) { profile in
                            Text(profile.title).tag(profile.rawValue)
                        }
                    }
                    .onChange(of: logProfile) { _, newValue in
                        engine.applyLogProfile(newValue)
                    }
                    
                    Text(MQLogProfile(rawValue: logProfile)?.description ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Divider()
                    
                    HStack {
                        Text("Current Log:")
                            .font(.caption)
                            .bold()
                        Text(engine.currentLogFileDisplay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    HStack(spacing: 10) {
                        Button(action: {
                            LogFileManager.shared.revealInFinder()
                        }) {
                            Label("Reveal in Finder", systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button(action: {
                            LogFileManager.shared.openInDefaultEditor()
                        }) {
                            Label("Open in Editor", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: {
                            engine.copyDiagnosticReport(
                                gameFolderPath: gameFolderPath,
                                selectedMod: selectedMod,
                                startMap: startMap,
                                selectedDisplayIndex: selectedDisplayIndex,
                                selectedResolution: selectedResolution,
                                metalFXMode: metalFXMode,
                                metalFXPreset: metalFXPreset,
                                hdrEnabled: hdrEnabled,
                                msaaSamples: msaaSamples,
                                anisotropy: anisotropy
                            )
                        }) {
                            Label(engine.isSummaryCopied ? "Copied!" : "Copy Summary",
                                  systemImage: engine.isSummaryCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .tint(engine.isSummaryCopied ? .green : .primary)
                    }
                    
                    Text("'Copy Summary' compiles a sanitized technical environment report for issue reports.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(6)
            }
            
            // Block 3: Attribution and Licensing
            GroupBox(label: Label("Attribution & License", systemImage: "text.badge.checkmark").bold()) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Port & Metal Engine:")
                            .font(.caption.bold())
                        Text("Alexey Chernyak")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Based on:")
                            .font(.caption.bold())
                        Text("QuakeSpasm, FitzQuake & id Software")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                        .padding(.vertical, 2)
                    
                    Text("Licensed under GNU General Public License v2.0 or later (GPL-2.0-or-later).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(6)
            }
        }
    }
    
    // MARK: - Bottom Launch Bar
    
    private var bottomLaunchBar: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                
                if engine.hasPlayedOnce {
                    Button(action: { engine.relaunchApplication() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                            Text("Restart Launcher to Play Again")
                                .font(.headline)
                        }
                        .frame(minWidth: 260)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)
                    .keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button(action: triggerLaunch) {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: engine.isEngineRunning ? "gearshape.2.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                            
                            Text(engine.isEngineRunning ? "ENGINE RUNNING..." : "LAUNCH METALQUAKE")
                                .font(QuakeFont.font(size: 16))
                                .tracking(1)
                                .offset(y: 2.5) // Optical vertical offset for letter Q descender
                        }
                        .frame(minWidth: 280)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(engine.isEngineRunning ? .orange : .accentColor)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(engine.isEngineRunning || engine.detectedPakFiles.isEmpty)
                }
                
                Spacer()
            }
            
            if !engine.detectedPakFiles.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Ready: \(selectedMod) (\(engine.detectedPakFiles.count) PAK files)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Select Quake directory to launch")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
    
    // MARK: - Helper UI Components
    
    private func resettableValueBadge(text: String, defaultValueTitle: String, onReset: @escaping () -> Void) -> some View {
        Button(action: onReset) {
            Text(text)
                .monospacedDigit()
                .bold()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Click to reset to default (\(defaultValueTitle))")
    }
    
    // MARK: - Actions
    
    /// Compiles launch parameters and triggers C-engine startup via LauncherEngine
    private func triggerLaunch() {
        let config = LaunchConfig(
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
        
        engine.launchGame(config: config) {
            // Callback: directory missing, present file selection panel
            if let result = engine.selectGameFolder(selectedMod: &selectedMod) {
                self.gameFolderPath = result.path
                self.gameFolderBookmarkB64 = result.bookmarkB64
            }
        }
    }
    
    /// Restores all AppStorage launcher settings to default values
    private func resetToDefaults() {
        metalFXMode = MetalFXMode.disabled.rawValue
        metalFXPreset = MetalFXPreset.quality.rawValue
        anisotropy = 16
        waterAlpha = 0.70
        lerpModels = true
        dynamicShadows = false
        pbrEnabled = false
        rtEnabled = false
        hdrEnabled = true
        bloomEnabled = false
        bloomQuality = 0
        msaaSamples = 0
        freelook = true
        crosshairEnabled = true
        fieldOfView = 90.0
        fullscreen = false
        preserveAspect = false
        scaleFilter = 0
        selectedResolution = "1920x1080"
        selectedDisplayIndex = 0
        gammaValue = 1.0
        contrastValue = 1.0
        vsync = true
        targetFPS = 120
        uncappedFPS = true
        enableSpatialAudio = true
        sfxVolume = 0.8
        bgmVolume = 0.7
        startMap = "start"
        skillLevel = 1
        logProfile = MQLogProfile.dev.rawValue
        engine.appendLog("[Launcher] All settings restored to default values.\n")
    }
}

// MARK: - Info Popover Button Component

/// Interactive info button presenting contextual popover help on click
struct InfoHelpButton: View {
    let text: String
    @State private var isShowingPopover: Bool = false
    
    var body: some View {
        Button(action: {
            isShowingPopover.toggle()
        }) {
            Image(systemName: isShowingPopover ? "info.circle.fill" : "info.circle")
                .foregroundColor(isShowingPopover ? .accentColor : .secondary)
                .font(.system(size: 13))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(text)
        .popover(isPresented: $isShowingPopover) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}

// MARK: - About MetalQuake Window View

/// Project information view covering engine credits, versioning, and licenses
struct AboutMetalQuakeView: View {
    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (Build \(b))"
    }
    
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            
            Text("MetalQuake")
                .font(.title2.bold())
            
            Text(versionString)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text("Port & macOS Native Engine")
                        .font(.caption.bold())
                    Text("Alexey Chernyak")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                VStack(spacing: 2) {
                    Text("Based on QuakeSpasm")
                        .font(.caption.bold())
                    Text("Eric Wasylishen, Steven Aussie, Ozkan Sezer & contributors")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                VStack(spacing: 2) {
                    Text("Based on FitzQuake")
                        .font(.caption.bold())
                    Text("John Fitzgibbons and others")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                VStack(spacing: 2) {
                    Text("Original Quake Engine")
                        .font(.caption.bold())
                    Text("Id Software, Inc.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            
            Divider()
            
            Text("Licensed under GNU General Public License v2")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Link(destination: URL(string: "https://github.com/aloysha976/MetalQuake")!) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("Source Code")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 360)
    }
}
