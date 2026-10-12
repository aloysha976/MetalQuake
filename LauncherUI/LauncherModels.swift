//
//  LauncherModels.swift
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import Foundation

// MARK: - Launcher Navigation Tabs

/// Navigation tabs displayed in the primary launcher window
enum LauncherTab: String, CaseIterable, Identifiable {
    case game = "Game & Mods"
    case display = "Display"
    case graphics = "Metal & FX"
    case audio = "Audio"
    case support = "Support"
    
    var id: String { rawValue }
    
    /// SF Symbols system icon name for the tab
    var icon: String {
        switch self {
        case .game: return "gamecontroller.fill"
        case .display: return "display"
        case .graphics: return "sparkles"
        case .audio: return "speaker.wave.3.fill"
        case .support: return "lifepreserver.fill"
        }
    }
}

// MARK: - MetalFX Enums

/// Apple MetalFX upscaling runtime modes
enum MetalFXMode: String, CaseIterable, Identifiable {
    case disabled = "Disabled (Native)"
    case spatial = "MetalFX Spatial (v1 - Fast)"
    case temporal = "MetalFX Temporal (v2 - High Quality)"
    
    var id: String { rawValue }
}

/// Internal rendering resolution presets when MetalFX scaling is active
enum MetalFXPreset: String, CaseIterable, Identifiable {
    case performance = "Performance (0.50x)"
    case balanced = "Balanced (0.67x)"
    case quality = "Quality (0.75x)"
    case ultraQuality = "Ultra Quality (0.85x)"
    
    var id: String { rawValue }
    
    /// Resolution scaling factor relative to native display target
    var scaleFactor: Float {
        switch self {
        case .performance: return 0.50
        case .balanced: return 0.67
        case .quality: return 0.75
        case .ultraQuality: return 0.85
        }
    }
}

// MARK: - Display Option

/// Describes a physical display monitor connected to the system
struct DisplayOption: Identifiable, Equatable {
    /// Display index matching CGGetActiveDisplayList and SDL enumeration order
    let id: Int
    /// Localized display name including primary screen annotations
    let name: String
    /// Physical native panel resolution (e.g., "3840x2160")
    let pixelSize: String
}

// MARK: - Diagnostics Logging Profiles

/// Engine diagnostic logging profiles (mirrors r_metal_log.h)
enum MQLogProfile: Int, CaseIterable, Identifiable {
    case release = 0
    case dev = 1
    case full = 2
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .release: return "Release"
        case .dev: return "Dev"
        case .full: return "Full"
        }
    }
    
    var description: String {
        switch self {
        case .release:
            return "End-user profile: initialization, errors, anomalies, and shutdown."
        case .dev:
            return "Diagnostics: all render pipeline stages rate-limited per tag (~200 lines per session)."
        case .full:
            return "Verbose logging without per-tag budgets (subject to 200,000 line global cap)."
        }
    }
}

// MARK: - Launcher Shared Constants

/// Shared static configuration presets and hardware limits
enum LauncherConstants {
    /// Maximum 2D texture dimension supported across all Apple Silicon GPUs: 16384px (16K)
    static let metalMaxTextureEdge: Int = 16384
    
    /// Available anisotropic filtering levels
    static let anisoLevels: [Int] = [1, 2, 4, 8, 16]
    
    /// Supported hardware multisample antialiasing (MSAA) sample counts
    static let msaaLevels: [Int] = [0, 2, 4, 8]
    
    /// Classic Quake skill level titles
    static let skillNames: [String] = [
        "0: Easy",
        "1: Normal",
        "2: Hard",
        "3: Nightmare"
    ]
    
    /// Standard rendering resolution presets (retro 4:3 and modern widescreen 16:9)
    static let standardResolutions: [String] = [
        "3840x2160",
        "2560x1440",
        "1920x1080",
        "1280x720",
        "960x540",   // Retro 16:9 (quarter of 1080p)
        "640x360",   // Ultra-retro 16:9 (one-sixth of 4K)
        "1024x768",  // Classic 4:3
        "800x600",   // Classic 4:3
        "640x480",   // Classic 4:3
        "320x240"    // Low-resolution retro 4:3
    ]
}
