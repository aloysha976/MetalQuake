# MetalQuake

<p align="center">
  <img src="Assets/app_icon.png" alt="MetalQuake Icon" width="128" height="128">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B%20(Sonoma%20%7C%20Sequoia%20%7C%20Tahoe%20%7C%20Golden%20Gate)-000000?style=flat-square&logo=apple&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Architecture-Apple%20Silicon%20(M1%20to%20M6)-FF3B30?style=flat-square&logo=apple" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Graphics-Metal%203%20%2B%20MetalFX-0071e3?style=flat-square" alt="Metal 3">
  <img src="https://img.shields.io/badge/License-GPL--2.0--or--later-blue?style=flat-square" alt="License">
</p>

---

Native Apple Metal port of QuakeSpasm for macOS. Tailored specifically for Apple Silicon with MetalFX upscaling (Spatial & Temporal), a 16-bit HDR rendering pipeline with EDR, PBR materials, optical bloom, smooth model interpolation, and immersive 3D Spatial Audio. Plays the 1996 classic at ultra-high framerates with flawless ProMotion (120 Hz+) display support.

---

## Key Highlights

- **Native Metal 3 Graphics Pipeline:** Fully replaces legacy OpenGL with modern, low-overhead Apple Metal 3 shaders and compute pipelines.
- **MetalFX Upscaling:** Integrated Spatial and Temporal upscalers for razor-sharp visuals at 4K/5K native outputs with minimal GPU overhead.
- **16-bit HDR & EDR Support:** True high dynamic range (RGBA16Float) tailored for Liquid Retina XDR displays and high-brightness panels.
- **Optical Bloom & PBR Materials:** Subtle physically-based surface reflections and atmospheric glow around torches, lava, and explosions.
- **Smooth Model Interpolation (Lerp):** Upgrades the original 10 fps monster and weapon animations to fluid modern framerates.
- **Apple Spatial 3D Audio:** Immersive positional audio powered natively by `AVAudioEngine`.
- **No SDL Dependency:** Replaced legacy SDL layers with fully native macOS window management and input handling.
- **Native Gamepad & Haptics Support:** Powered by GameController.framework with support for DualSense, Xbox, and MFi controllers, featuring rumble/haptics and hot-plugging. (not tested)
- **Game Center Achievements Ready:** Built-in GameKit integration for native macOS achievements (implemented in codebase, toggled off until an active Apple Developer account is linked).
- **Modern SwiftUI Launcher:** Native macOS settings center with Sandbox bookmark persistence, monitor resolution selection, aspect ratio controls, and diagnostics logging.

---

## System Requirements

- **Processor:** Apple Silicon Mac (M1, M2, M3, M4, M5, M6 or Pro / Max / Ultra variants).
- **Operating System:** macOS 14.0 Sonoma, macOS 15.0 Sequoia, macOS 26 Tahoe, macOS 27 Golden Gate (or newer).
- **Game Assets:** Original Quake data files (`pak0.pak` and `pak1.pak`) from a registered copy (Steam, GOG, or original CD-ROM).

---

## Quick Start Guide

1. Download the latest **MetalQuake** release from the [Releases](../../releases) section (or install via the Mac App Store / build from source).
2. Launch **MetalQuake**.
3. Under the **Game & Mods** tab, click **Browse...** in the *Game Data Directory* box.
4. Select your Quake installation folder containing the `id1` directory (with `pak0.pak` and `pak1.pak`).
5. Choose your display resolution, enable desired graphical enhancements, and hit **LAUNCH METALQUAKE**.

---

## Mission Packs & Mods

MetalQuake automatically scans your game directory for installed expansions and community campaigns:
- **id1** (Original Quake)
- **hipnotic** (Mission Pack 1: *Scourge of Armagon*)
- **rogue** (Mission Pack 2: *Dissolution of Eternity*)
- **dopa** (Episode 5: *Dimension of the Past*)
- **mg1** (*Dimension of the Machine*)
- **mg3** (*Dawn of the Machine*)
- Custom mod directories with valid `.pak` archives.

---

## Logging & Reporting Issues

If you encounter crashes, render glitches, or engine deadlocks:
1. Open the launcher and navigate to the **Logging** tab.
2. Click **Reveal in Finder** to locate your session log (formatted as `metalquake_YYYY-MM-DD_HH-mm-ss.log`).
3. Open a ticket via the [Issue Tracker](../../issues) using the Bug Report template, and attach the log along with your Mac model and macOS version.

---

## Support the Developer

If you enjoy playing Quake natively on Apple Silicon and would like to support future updates and engine improvements:

- **Bitcoin (BTC):** `bc1qemmfh8h4hglaqnkmyq0hhs48vhqm4te357nass`
- **Ethereum (ETH / ERC-20):** `0x977904c6779023c4fb2e13122ea5e805d8dc9286`
- **Litecoin (LTC):** `MSzYvCSeYfTU14UXMZhShv9gwMNarZCpZi`
- **USDT (ERC-20):** `0x977904c6779023c4fb2e13122ea5e805d8dc9286`
- **USDT (TRC-20):** `TPgQvJAgFxdNST9WhZ9RpoD6ivQQf9irMv`


---

## Credits & License

- **MetalQuake Port & Native Engine:** Alexey Chernyak
- **QuakeSpasm:** Eric Wasylishen, Steven Aussie, Ozkan Sezer & contributors
- **FitzQuake:** John Fitzgibbons
- **Original Quake Engine:** Id Software, Inc.

This project is licensed under the **GNU General Public License v2.0 or later** (`GPL-2.0-or-later`). See the [LICENSE](LICENSE) file for complete details.

*Disclaimer: Quake is a registered trademark of id Software LLC / Bethesda Softworks / ZeniMax Media. MetalQuake is an independent open-source source port and is not affiliated with, endorsed by, or sponsored by id Software or Bethesda.*
