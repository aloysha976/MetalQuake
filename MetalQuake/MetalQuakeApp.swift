//
//  MetalQuakeApp.swift
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

import SwiftUI
import AppKit

// MARK: - Application Delegate Lifecycle Manager

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var isGameRunning: Bool = false
    static weak var launcherWindowRef: NSWindow?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Prevent macOS from terminating the application when game windows are dismissed
        return false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.isGameRunning {
            return .terminateCancel
        }
        return .terminateNow
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.restoreLauncherWindow()
        return true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.restoreLauncherWindow()
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        // Terminate application when the launcher window close button is explicitly clicked
        if let win = notification.object as? NSWindow, win == Self.launcherWindowRef, !Self.isGameRunning {
            NSApp.terminate(nil)
        }
    }
    
    static func restoreLauncherWindow() {
        DispatchQueue.main.async {
            // Dismiss active engine game windows while preserving the launcher window
            for window in NSApp.windows {
                let className = String(describing: type(of: window))
                if className.contains("MQGameWindow") || className.contains("SDL") {
                    window.orderOut(nil)
                    window.close()
                }
            }
            
            // Restore tracked launcher window reference
            if let win = launcherWindowRef {
                win.setIsVisible(true)
                win.deminiaturize(nil)
                win.makeKeyAndOrderFront(nil)
            } else {
                // Fallback: locate primary SwiftUI host window
                for window in NSApp.windows {
                    let className = String(describing: type(of: window))
                    if !className.contains("MQGameWindow") && !className.contains("SDL") && !(window is NSPanel) {
                        launcherWindowRef = window
                        window.setIsVisible(true)
                        window.deminiaturize(nil)
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }
            
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

// MARK: - NSApp.delegate Override Protection

extension NSApplication {
    private static let swizzleSetDelegateOnce: Void = {
        let originalSelector = #selector(setter: NSApplication.delegate)
        let swizzledSelector = #selector(mq_setDelegate(_:))
        guard let originalMethod = class_getInstanceMethod(NSApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSApplication.self, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    
    static func preventDelegateOverride() {
        _ = swizzleSetDelegateOnce
    }
    
    @objc func mq_setDelegate(_ newDelegate: NSApplicationDelegate?) {
        // Prevent underlying C/Objective-C engine routines from overriding the application delegate
        if self.delegate is AppDelegate && !(newDelegate is AppDelegate) {
            return
        }
        self.mq_setDelegate(newDelegate)
    }
}

@main
struct MetalQuakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Prevent macOS window restoration from preserving a closed window state across launches
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        NSApplication.preventDelegateOverride()
        
        // Headless execution mode: "-engine <args>" runs the engine directly without launcher UI
        var args = CommandLine.arguments
        guard let eIdx = args.firstIndex(of: "-engine") else { return }
        args = Array(args[(eIdx + 1)...])
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("MetalQuake")]
        for a in args { argv.append(strdup(a)) }
        let rc = QuakeEngine_Main(Int32(argv.count), &argv)
        for p in argv where p != nil { free(p) }
        exit(rc)
    }
    
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        WindowGroup(id: "launcher") {
            MetalQuakeLauncher()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 640, height: 650)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MetalQuake") {
                    openWindow(id: "about")
                }
            }
        }
        
        Window("About MetalQuake", id: "about") {
            AboutMetalQuakeView()
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}
