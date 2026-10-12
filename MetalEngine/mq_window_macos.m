//
//  mq_window_macos.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  AppKit renderer integration layer. Pure native Cocoa implementation:
//  ConfigureNativeWindow accepts NSWindow* directly from vid_macos.m.
//  Layer backing scale is owned by vid_macos.m (render size strictly matches backing pixels);
//  this module manages window resizing and focus restoration.
//

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "mq_internal.h"
#import "mq_log.h"
#import "quakedef.h"

// Updates display target and scale configuration upon screen change
extern void VID_WindowDidChangeScreen(void);

NSWindow *g_gameNSWindow = nil;

// Focus heal attempt tracking: reset on DidResignKey to guarantee rapid response (0.25s)
// immediately following focus loss rather than suffering a 2.0s cooldown window.
static CFAbsoluteTime s_lastHealTime = 0;
static int            s_healAttempts = 0;

void R_Metal_GetAppTitle(char *outTitle, size_t maxLen)
{
    if (!outTitle || maxLen == 0) return;
    
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *appName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?:
        [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: @"MetalQuake";
        NSString *appVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1.0";
        
        NSString *fullTitle = [NSString stringWithFormat:@"%@ v%@ (Metal 3)", appName, appVersion];
        snprintf(outTitle, maxLen, "%s", [fullTitle UTF8String]);
    }
}

// Enforces layer geometry and engine projection updates during window resize.
// Note: contentsScale is maintained exclusively by vid_macos.m.
void R_Metal_HandleWindowResize(NSWindow *nswin)
{
    if (!nswin || !g_metalLayer) return;
    
    NSView *contentView = nswin.contentView;
    if (!contentView) return;
    
    NSRect bounds = contentView.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    
    CGFloat scale = g_metalLayer.contentsScale > 0 ? g_metalLayer.contentsScale : 1.0;
    CGSize pixelSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
    
    // 1. Resize views and CAMetalLayer to encompass the entire window bounds
    for (NSView *subview in contentView.subviews) {
        subview.frame = bounds;
    }
    g_metalLayer.frame = bounds;
    g_metalLayer.drawableSize = pixelSize;
    
    // 2. Update Quake core viewport parameters
    vid.width = (int)pixelSize.width;
    vid.height = (int)pixelSize.height;
    SCR_UpdateConwidth(vid.width, vid.height);
    vid.recalc_refdef = 1;
    
    // 3. Reallocate depth attachment matching the new resolution
    R_Metal_UpdateDepthTexture((NSUInteger)pixelSize.width, (NSUInteger)pixelSize.height);
}

// Configures native window properties from NSWindow handle
void R_Metal_ConfigureNativeWindow(void *nativeWindowHandle, const char *title)
{
    if (!nativeWindowHandle) return;
    
    @autoreleasepool {
        NSWindow *nswin = (__bridge NSWindow *)nativeWindowHandle;
        if (nswin) {
            // Retain window reference for focus management and diagnostics
            g_gameNSWindow = nswin;
            
            if (title) {
                nswin.title = [NSString stringWithUTF8String:title];
            }
            
            // Native Spaces fullscreen via the green zoom button is disabled to avoid display anomalies.
            // Fullscreen is managed via custom borderless/mode-switch logic in vid_macos.m.
            nswin.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
            
            // Register resize observers
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResizeNotification
                                                              object:nswin
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                R_Metal_HandleWindowResize(nswin);
            }];
            
            // Screen configuration change observers.
            // Adapt window bounds and backing scale first, then resize backing store and depth buffers.
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeScreenNotification
                                                              object:nswin
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                MLog(MQ_LVL_DEV, "VID", "NSWindowDidChangeScreenNotification fired");
                VID_WindowDidChangeScreen();
                R_Metal_HandleWindowResize(nswin);
            }];
            
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidChangeBackingPropertiesNotification
                                                              object:nswin
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                MLog(MQ_LVL_DEV, "VID", "NSWindowDidChangeBackingPropertiesNotification fired");
                VID_WindowDidChangeScreen();
                R_Metal_HandleWindowResize(nswin);
            }];
            
            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                MLog(MQ_LVL_DEV, "VID", "NSApplicationDidChangeScreenParametersNotification fired");
                VID_WindowDidChangeScreen();
                R_Metal_HandleWindowResize(nswin);
            }];
            
            // Mouse capture policy is managed in in_macos.m.
            // Reset focus heal cooldown on resign key to re-engage recovery immediately.
            [[NSNotificationCenter defaultCenter]
             addObserverForName:NSWindowDidResignKeyNotification
             object:nswin
             queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                s_lastHealTime = 0;
                MLog(MQ_LVL_DEV, "INPUT", "window did resign key -> focus-heal cooldown reset");
            }];
            
            // Ensure mouse grab if application reactivates while the window is already key
            [[NSNotificationCenter defaultCenter]
             addObserverForName:NSApplicationDidBecomeActiveNotification
             object:nil
             queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                if (g_gameNSWindow && g_gameNSWindow.isKeyWindow) {
                    IN_Activate();
                    MLog(MQ_LVL_DEV, "INPUT", "app became active (keyWin=1) -> ensure mouse grab");
                }
            }];
            
            [[NSNotificationCenter defaultCenter]
             addObserverForName:NSWindowDidResignKeyNotification
             object:nswin
             queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                // Defer releasing cursor grab if the application remains active (e.g. transient alerts)
                if (NSApp.isActive) {
                    MLog(MQ_LVL_DEV, "INPUT", "window resign key but app still active -> defer ungrab");
                } else {
                    IN_Deactivate(true);
                    s_lastHealTime = 0;
                    MLog(MQ_LVL_DEV, "INPUT", "window did resign key (app inactive) -> mouse ungrab, heal reset");
                }
            }];
            
            // Diagnostics: trace window focus loss and identify competing key windows
            [[NSNotificationCenter defaultCenter]
             addObserverForName:NSWindowDidBecomeKeyNotification
             object:nil
             queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                NSWindow *w = note.object;
                if (w && w != nswin)
                    MLog(MQ_LVL_ALWAYS, "FOCUS·THIEF",
                         "key stolen by win#%lu '%s' class=%s visible=%d",
                         (unsigned long)w.windowNumber,
                         (w.title ?: @"").UTF8String,
                         NSStringFromClass([w class]).UTF8String,
                         w.isVisible ? 1 : 0);
            }];
            
            [[NSNotificationCenter defaultCenter]
             addObserverForName:NSApplicationDidResignActiveNotification
             object:nil
             queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
                MLog(MQ_LVL_ALWAYS, "FOCUS·THIEF",
                     "APP RESIGNED ACTIVE (keyWin now %s)",
                     ([NSApp.keyWindow title] ?: @"<none>").UTF8String);
            }];
        }
    }
}

// Explicit application and window activation routine
void R_Metal_ActivateGameWindow(void)
{
    @autoreleasepool {
        if (@available(macOS 14.0, *))
            [NSApp activate];
        else
            [NSApp activateIgnoringOtherApps:YES];
        
        if (g_gameNSWindow) {
            // Evaluate fullscreen state via engine flags and borderless mask
            cvar_t *fsVar = Cvar_FindVar("vid_fullscreen");
            bool isFS = (modestate == MS_FULLSCREEN) ||
                        (fsVar && fsVar->value != 0.0f) ||
                        (g_gameNSWindow.styleMask == NSWindowStyleMaskBorderless);
            
            if (isFS) {
                // Hide system Menu Bar and Dock; elevate window level above main menu
                NSApp.presentationOptions = NSApplicationPresentationHideMenuBar |
                                            NSApplicationPresentationHideDock;
                g_gameNSWindow.level = NSMainMenuWindowLevel + 1;
            } else {
                NSApp.presentationOptions = NSApplicationPresentationDefault;
                g_gameNSWindow.level = NSNormalWindowLevel;
            }
            
            [g_gameNSWindow makeKeyAndOrderFront:nil];
            g_gameNSWindow.acceptsMouseMovedEvents = YES;
            g_gameNSWindow.ignoresMouseEvents      = NO;
            // Clear pending key states on cold start
            Key_ClearStates();
            MLog(MQ_LVL_DEV, "INPUT", "Game window activated (key=%d, level=%ld)",
                 g_gameNSWindow.isKeyWindow ? 1 : 0, (long)g_gameNSWindow.level);
        } else {
            MLog(MQ_LVL_ALWAYS, "INPUT", "g_gameNSWindow is NULL, activation skipped");
        }
    }
}

// Automatic window focus recovery tick.
// Uses an adaptive retry interval: the first 10 attempts execute at 0.25s intervals
// to capture the macOS user-interaction grace window, throttling to 2.0s thereafter.
void MQ_Window_FocusHealTick(void)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double cooldown = (s_healAttempts < 10) ? 0.25 : 2.0;
    
    // Hard cap at 60 attempts to prevent endless activation churn in headless or kiosk environments
    if (s_healAttempts >= 60)
        return;
    if (now - s_lastHealTime >= cooldown && g_gameNSWindow &&
        !g_gameNSWindow.isKeyWindow)
    {
        s_lastHealTime = now;
        s_healAttempts++;
        if (@available(macOS 14.0, *))
            [NSApp activate];
        else
            [NSApp activateIgnoringOtherApps:YES];
        
        // Re-issuing makeKeyAndOrderFront is mandatory: makeKey succeeds only when the app is active,
        // which may resolve asynchronously after the window is initially created.
        cvar_t *fsVar = Cvar_FindVar("vid_fullscreen");
        bool isFS = (modestate == MS_FULLSCREEN) ||
                    (fsVar && fsVar->value != 0.0f) ||
                    (g_gameNSWindow.styleMask == NSWindowStyleMaskBorderless);
        if (isFS) {
            g_gameNSWindow.level = NSMainMenuWindowLevel + 1;
        }
        [g_gameNSWindow makeKeyAndOrderFront:nil];
        Key_ClearStates();
        MLog(MQ_LVL_ALWAYS, "INPUT",
             "Focus heal #%d (frame=%u appActive=%d -> keyWin=%d)",
             s_healAttempts,
             MLog_GetFrame(),
             NSApp.isActive ? 1 : 0,
             g_gameNSWindow.isKeyWindow ? 1 : 0);
    }
}

// Input and window state telemetry tick (sampled every 600 frames and upon state transitions)
void MQ_Input_DiagnosticsTick(void)
{
    static unsigned s_lastLoggedFrame = 0;
    unsigned frame = MLog_GetFrame();
    bool due = (frame == 1 || frame == 60 || frame == 300 ||
                (frame > 300 && frame % 600 == 0));
    
    if (!g_gameNSWindow)
        return;
    
    int nowActive = NSApp.isActive ? 1 : 0;
    int nowKey    = g_gameNSWindow.isKeyWindow ? 1 : 0;
    
    static int s_prevActive = -1, s_prevKey = -1;
    if (nowActive != s_prevActive || nowKey != s_prevKey)
    {
        bool first = (s_prevActive < 0);
        s_prevActive = nowActive;
        s_prevKey    = nowKey;
        if (!first && MLog_Budget("INPUT", 24))
            MLog(MQ_LVL_ALWAYS, "INPUT",
                 "TRANS frame=%u appActive=%d keyWin=%d",
                 frame, nowActive, nowKey);
    }
    
    if (due && s_lastLoggedFrame != frame)
    {
        s_lastLoggedFrame = frame;
        MLog(MQ_LVL_DEV, "INPUT",
             "frame=%u appActive=%d keyWin=%d mini=%d visible=%d",
             frame, nowActive, nowKey,
             g_gameNSWindow.isMiniaturized ? 1 : 0,
             g_gameNSWindow.isVisible ? 1 : 0);
    }
}
