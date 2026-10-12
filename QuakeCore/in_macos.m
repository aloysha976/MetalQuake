/*
 Copyright (C) 1996-2001 Id Software, Inc.
 Copyright (C) 2002-2005 John Fitzgibbons and others
 Copyright (C) 2007-2008 Kristian Dusner
 Copyright (C) 2010-2014 QuakeSpasm developers
 
 This program is free software; you can redistribute it and/or
 modify it under the terms of the GNU General Public License
 as published by the Free Software Foundation; either version 2
 of the License, or (at your option) any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 
 See the GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */

// [MQ-NATIVE] in_macos.m — эталонный нативный ввод для macOS.
//
// Инварианты:
// 1. Относительная мышь: CGAssociateMouseAndMouseCursorPosition(false) + warp в центр окна.
// 2. Координаты варпа конвертируются AppKit (y-up) -> Quartz (y-down).
// 3. В игровом режиме мышиные события НЕ пробрасываются в [NSApp sendEvent:].
// 4. Единственный владелец граба — этот файл.
// 5. Граб только когда: приложение активно + окно key + key_dest==key_game + нет паузы.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGRemoteOperation.h>
#import <stdint.h>
#import <stdlib.h>

#import "quakedef.h"
#import "mq_log.h"
#import "in_gamecontroller.h"

#ifndef kCGNullDirectDisplay
#define kCGNullDirectDisplay ((CGDirectDisplayID)0)
#endif

extern void *VID_GetWindow(void);

extern cvar_t cl_maxpitch; /* johnfitz */
extern cvar_t cl_minpitch; /* johnfitz */

#define IN_LOG_ALWAYS(fmt, ...) MLog(MQ_LVL_ALWAYS, "INPUT", fmt, ##__VA_ARGS__)
#define IN_LOG_DEV(fmt, ...)    MLog(MQ_LVL_DEV,    "INPUT", fmt, ##__VA_ARGS__)

#define IN_LOG_MOVE(fmt, ...) \
do { \
if (MLog_Budget("INPUT·MOVE", 120)) \
MLog(MQ_LVL_DEV, "INPUT·MOVE", fmt, ##__VA_ARGS__); \
} while (0)

#define IN_LOG_BTN(fmt, ...) \
do { \
if (MLog_Budget("INPUT·BTN", 160)) \
MLog(MQ_LVL_DEV, "INPUT·BTN", fmt, ##__VA_ARGS__); \
} while (0)

#define IN_LOG_FOCUS(fmt, ...) \
do { \
if (in_debugfocus.value) \
IN_LOG_DEV(fmt, ##__VA_ARGS__); \
} while (0)

//==========================================================================
// Состояние
//==========================================================================

static qboolean s_noMouse = false;
static qboolean s_mouseGrabbed = false;
static qboolean s_cursorHidden = false;

static qboolean s_windowKey = true;
static qboolean s_appActive = true;
static qboolean s_textMode = false;

static volatile qboolean s_quitRequested = false;

static int s_totalDX = 0;
static int s_totalDY = 0;

static double s_fracDX = 0.0;
static double s_fracDY = 0.0;
static double s_wheelAccum = 0.0;
static int s_skipMotionEvents = 0; // [MetalQuake] Счётчик сброса спайков после варпа/загрузки

static int s_prevModifiers = 0;

// Не держим strong-ссылку на окно: окно принадлежит vid_macos.m.
static uintptr_t s_observedWindowPtr = 0;

static NSMutableArray *s_windowObservers = nil;
static NSMutableArray *s_appObservers = nil;
static qboolean s_appObserversInstalled = false;

static NSRect s_lastGrabFrame = {0};
static CGDirectDisplayID s_lastGrabDisplay = kCGNullDirectDisplay;

static cvar_t in_debugkeys  = {"in_debugkeys",  "0", CVAR_NONE};
static cvar_t in_debugmouse = {"in_debugmouse", "0", CVAR_NONE};
static cvar_t in_debugfocus = {"in_debugfocus", "0", CVAR_NONE};
cvar_t freelook      = {"freelook",      "1", CVAR_NONE};

static int buttonremap[] =
{
    K_MOUSE1,    // left      (buttonNumber 0)
    K_MOUSE3,    // right     (buttonNumber 1)
    K_MOUSE2,    // middle    (buttonNumber 2)
    K_MOUSE4,    // side      (buttonNumber 3)
    K_MOUSE5    // side      (buttonNumber 4)
};

//==========================================================================
// Forward declarations
//==========================================================================

static void IN_UpdateMouseGrab(void);
static void IN_SyncWindowObservers(void);
static void IN_SetMouseGrabbed(qboolean grab, const char *reason);
static qboolean IN_WantMouseGrab(void);
static qboolean IN_ShouldConsumeMouseEvents(void);
static qboolean IN_ShouldConsumeKeyboardEvents(void);

//==========================================================================
// Utilities
//==========================================================================

static NSWindow *IN_CurrentWindow(void)
{
    void *handle = VID_GetWindow();
    return handle ? (__bridge NSWindow *)handle : nil;
}

static CGDirectDisplayID IN_DisplayIDForWindow(NSWindow *win)
{
    NSScreen *scr = win.screen;
    
    if (!scr)
        scr = [NSScreen mainScreen];
    
    if (!scr)
        return CGMainDisplayID();
    
    NSNumber *num = [scr deviceDescription][@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]])
        return (CGDirectDisplayID)[num unsignedIntValue];
    
    return CGMainDisplayID();
}

static CGFloat IN_MenuBarScreenHeight(void)
{
    NSArray<NSScreen *> *screens = [NSScreen screens];
    
    if (screens.count > 0)
        return screens[0].frame.size.height;
    
    NSScreen *main = [NSScreen mainScreen];
    if (main)
        return main.frame.size.height;
    
    return CGDisplayBounds(CGMainDisplayID()).size.height;
}

static BOOL IN_QuartzCenterForWindow(NSWindow *win, CGPoint *out)
{
    if (!win || !out)
        return NO;
    
    NSView *content = win.contentView;
    NSRect local = content ? content.bounds
    : NSMakeRect(0, 0, win.frame.size.width, win.frame.size.height);
    
    if (local.size.width < 1.0 || local.size.height < 1.0)
        return NO;
    
    NSRect screenRect = [win convertRectToScreen:local];
    
    if (screenRect.size.width < 1.0 || screenRect.size.height < 1.0)
        return NO;
    
    // AppKit: origin внизу главного экрана, y вверх.
    // Quartz: origin вверху главного экрана, y вниз.
    // quartz_y = menuBarHeight - appkit_y
    CGFloat menuBarHeight = IN_MenuBarScreenHeight();
    
    out->x = NSMidX(screenRect);
    out->y = menuBarHeight - NSMidY(screenRect);
    
    return YES;
}

static void IN_LogWindowGeometry(NSWindow *win, const char *context)
{
    if (!win)
        return;
    
    if (!in_debugmouse.value && !in_debugfocus.value)
        return;
    
    NSRect content = win.contentView ? win.contentView.bounds
    : NSMakeRect(0, 0, win.frame.size.width, win.frame.size.height);
    NSRect screenRect = [win convertRectToScreen:content];
    CGPoint quartz = CGPointZero;
    
    IN_QuartzCenterForWindow(win, &quartz);
    
    IN_LOG_DEV("%s: win#%ld appKitFrame=(%.0f,%.0f %.0fx%.0f) appKitScreen=(%.0f,%.0f %.0fx%.0f) quartzCenter=(%.1f,%.1f) displayID=%u",
               context,
               (long)win.windowNumber,
               win.frame.origin.x, win.frame.origin.y, win.frame.size.width, win.frame.size.height,
               screenRect.origin.x, screenRect.origin.y, screenRect.size.width, screenRect.size.height,
               quartz.x, quartz.y,
               (unsigned)IN_DisplayIDForWindow(win));
}

//==========================================================================
// Grab / ungrab
//==========================================================================

static void IN_HideCursor(void)
{
    if (!s_cursorHidden)
    {
        [NSCursor hide];
        s_cursorHidden = true;
    }
}

static void IN_ShowCursor(void)
{
    if (s_cursorHidden)
    {
        [NSCursor unhide];
        s_cursorHidden = false;
    }
}

static void IN_AssociateCursor(qboolean associate, const char *reason)
{
    CGError err = CGAssociateMouseAndMouseCursorPosition(associate);
    
    if (err != kCGErrorSuccess)
    {
        IN_LOG_ALWAYS("CGAssociateMouseAndMouseCursorPosition(%d) failed: error=%d (%s)",
                      associate ? 1 : 0, (int)err, reason ? reason : "?");
    }
    else if (in_debugmouse.value || in_debugfocus.value)
    {
        IN_LOG_DEV("cursor associate=%d (%s)", associate ? 1 : 0, reason ? reason : "?");
    }
}

static qboolean IN_WantMouseGrab(void)
{
    if (s_noMouse)
        return false;
    
    if (!s_appActive)
        return false;
    
    if (!s_windowKey)
        return false;
    
    if (key_dest != key_game)
        return false;
    
    if (cl.paused)
        return false;
    
    if (!IN_CurrentWindow())
        return false;
    
    return true;
}

static qboolean IN_ShouldConsumeMouseEvents(void)
{
    if (s_noMouse)
        return false;
    
    if (s_mouseGrabbed)
        return true;
    
    return IN_WantMouseGrab();
}

static qboolean IN_ShouldConsumeKeyboardEvents(void)
{
    if (s_noMouse)
        return false;
    
    // [FIX] Игровое окно должно поглощать клавиатуру во всех режимах (игра, консоль, меню, пауза),
    // пока оно активно, чтобы AppKit не отправлял нажатия клавиш окну лаунчера.
    return s_windowKey;
}

static void IN_ClearLocalInputState(void)
{
    IN_GC_ClearStates();
    
    s_totalDX = 0;
    s_totalDY = 0;
    s_fracDX = 0.0;
    s_fracDY = 0.0;
    s_wheelAccum = 0.0;
    s_prevModifiers = 0;
    s_skipMotionEvents = 2; // [MetalQuake] Игнорируем первые 2 события после варпа/сброса
    
    // Сбрасываем скопившиеся мышиные события перемещения из очереди AppKit
    NSEvent *flushEvent;
    while ((flushEvent = [NSApp nextEventMatchingMask:(NSEventMaskMouseMoved |
                                                       NSEventMaskLeftMouseDragged |
                                                       NSEventMaskRightMouseDragged |
                                                       NSEventMaskOtherMouseDragged)
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES]) != nil)
    {
        // Выбрасываем фантомные события, сгенерированные во время загрузки/варпа
    }
}

static void IN_SetMouseGrabbed(qboolean grab, const char *reason)
{
    if (s_noMouse && grab)
        grab = false;
    
    if (grab)
    {
        NSWindow *win = IN_CurrentWindow();
        
        if (!win)
        {
            IN_LOG_DEV("grab skipped: no window (%s)", reason ? reason : "?");
            return;
        }
        
        CGPoint quartzCenter = CGPointZero;
        
        if (!IN_QuartzCenterForWindow(win, &quartzCenter))
        {
            IN_LOG_ALWAYS("grab failed: cannot compute Quartz center (%s)", reason ? reason : "?");
            IN_LogWindowGeometry(win, "grab-failed-geometry");
            return;
        }
        
        win.acceptsMouseMovedEvents = YES;
        win.ignoresMouseEvents = NO;
        
        CGError warpErr = CGWarpMouseCursorPosition(quartzCenter);
        
        // associate(false) после warp сбрасывает кэш позиции в event-системе.
        IN_AssociateCursor(false, reason);
        IN_HideCursor();
        
        s_mouseGrabbed = true;
        IN_ClearLocalInputState();
        
        s_lastGrabFrame = win.frame;
        s_lastGrabDisplay = IN_DisplayIDForWindow(win);
        
        if (warpErr != kCGErrorSuccess)
            IN_LOG_ALWAYS("CGWarpMouseCursorPosition failed: error=%d (%s)", (int)warpErr, reason ? reason : "?");
        
        if (in_debugmouse.value || in_debugfocus.value)
        {
            NSRect content = win.contentView ? win.contentView.bounds
            : NSMakeRect(0, 0, win.frame.size.width, win.frame.size.height);
            NSRect screenRect = [win convertRectToScreen:content];
            
            IN_LOG_DEV("mouse grab: %s | win#%ld appKitScreen=(%.0f,%.0f %.0fx%.0f) quartzCenter=(%.1f,%.1f) displayID=%u keyDest=%d appActive=%d keyWin=%d paused=%d",
                       reason ? reason : "?",
                       (long)win.windowNumber,
                       screenRect.origin.x, screenRect.origin.y, screenRect.size.width, screenRect.size.height,
                       quartzCenter.x, quartzCenter.y,
                       (unsigned)s_lastGrabDisplay,
                       key_dest,
                       s_appActive ? 1 : 0,
                       s_windowKey ? 1 : 0,
                       cl.paused ? 1 : 0);
        }
        else
        {
            IN_LOG_DEV("mouse grab: %s", reason ? reason : "?");
        }
    }
    else
    {
        if (s_mouseGrabbed || s_cursorHidden)
        {
            IN_AssociateCursor(true, reason);
            IN_ShowCursor();
            
            s_mouseGrabbed = false;
            IN_ClearLocalInputState();
            
            IN_LOG_DEV("mouse release: %s", reason ? reason : "?");
        }
    }
}

static void IN_UpdateMouseGrab(void)
{
    IN_SyncWindowObservers();
    
    qboolean want = IN_WantMouseGrab();
    NSWindow *win = IN_CurrentWindow();
    
    if (want)
    {
        qboolean geometryChanged = false;
        
        if (win)
        {
            CGDirectDisplayID currentDisplay = IN_DisplayIDForWindow(win);
            
            if (!NSEqualRects(win.frame, s_lastGrabFrame))
                geometryChanged = true;
            
            if (currentDisplay != s_lastGrabDisplay)
                geometryChanged = true;
        }
        
        if (!s_mouseGrabbed)
        {
            IN_SetMouseGrabbed(true, "policy: active+key+game");
        }
        else if (geometryChanged)
        {
            IN_SetMouseGrabbed(true, "policy: geometry changed");
        }
    }
    else
    {
        if (s_mouseGrabbed)
            IN_SetMouseGrabbed(false, "policy: grab conditions lost");
    }
}

//==========================================================================
// Notification observers
//==========================================================================

static void IN_AddObserver(NSMutableArray *list, NSString *name, id object, void (^block)(NSNotification *note))
{
    if (!list || !name || !block)
        return;
    
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                                 object:object
                                                                  queue:[NSOperationQueue mainQueue]
                                                             usingBlock:block];
    if (token)
        [list addObject:token];
}

// Возвращает nil, чтобы вызывающий сделал `list = IN_ClearObserverList(list)`.
// Это обходит запрет ARC на передачу адреса глобальной переменной в __autoreleasing параметр.
static NSMutableArray *IN_ClearObserverList(NSMutableArray *list)
{
    for (id token in list)
        [[NSNotificationCenter defaultCenter] removeObserver:token];
    
    return nil;
}

static void IN_RemoveWindowObservers(void)
{
    s_windowObservers = IN_ClearObserverList(s_windowObservers);
    s_observedWindowPtr = 0;
}

static void IN_AddWindowObservers(NSWindow *win)
{
    if (!win)
        return;
    
    if (!s_windowObservers)
        s_windowObservers = [NSMutableArray array];
    
    IN_AddObserver(s_windowObservers, NSWindowDidBecomeKeyNotification, win, ^(NSNotification *note) {
        (void)note;
        s_windowKey = true;
        IN_LOG_FOCUS("window became key");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidResignKeyNotification, win, ^(NSNotification *note) {
        (void)note;
        s_windowKey = false;
        Key_ClearStates();
        IN_ClearLocalInputState();
        IN_LOG_FOCUS("window resigned key");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidResizeNotification, win, ^(NSNotification *note) {
        (void)note;
        if (s_mouseGrabbed)
            IN_SetMouseGrabbed(true, "window resized");
        else
            IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidMoveNotification, win, ^(NSNotification *note) {
        (void)note;
        if (s_mouseGrabbed)
            IN_SetMouseGrabbed(true, "window moved");
        else
            IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidChangeScreenNotification, win, ^(NSNotification *note) {
        (void)note;
        if (s_mouseGrabbed)
            IN_SetMouseGrabbed(true, "window changed screen");
        else
            IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidMiniaturizeNotification, win, ^(NSNotification *note) {
        (void)note;
        s_windowKey = false;
        IN_LOG_FOCUS("window miniaturized");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowDidDeminiaturizeNotification, win, ^(NSNotification *note) {
        (void)note;
        IN_LOG_FOCUS("window deminiaturized");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_windowObservers, NSWindowWillCloseNotification, win, ^(NSNotification *note) {
        (void)note;
        IN_SetMouseGrabbed(false, "window will close");
        IN_LOG_FOCUS("window will close");
    });
}

static void IN_AddAppObservers(void)
{
    if (s_appObserversInstalled)
        return;
    
    if (!s_appObservers)
        s_appObservers = [NSMutableArray array];
    
    IN_AddObserver(s_appObservers, NSApplicationDidBecomeActiveNotification, nil, ^(NSNotification *note) {
        (void)note;
        s_appActive = true;
        IN_LOG_FOCUS("application became active");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_appObservers, NSApplicationDidResignActiveNotification, nil, ^(NSNotification *note) {
        (void)note;
        s_appActive = false;
        Key_ClearStates();
        IN_ClearLocalInputState();
        IN_LOG_FOCUS("application resigned active");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_appObservers, NSApplicationDidHideNotification, nil, ^(NSNotification *note) {
        (void)note;
        s_appActive = false;
        IN_LOG_FOCUS("application hidden");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_appObservers, NSApplicationDidUnhideNotification, nil, ^(NSNotification *note) {
        (void)note;
        IN_LOG_FOCUS("application unhidden");
        IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_appObservers, NSApplicationDidChangeScreenParametersNotification, nil, ^(NSNotification *note) {
        (void)note;
        IN_LOG_FOCUS("screen parameters changed");
        if (s_mouseGrabbed)
            IN_SetMouseGrabbed(true, "screen parameters changed");
        else
            IN_UpdateMouseGrab();
    });
    
    IN_AddObserver(s_appObservers, NSApplicationWillTerminateNotification, nil, ^(NSNotification *note) {
        (void)note;
        IN_SetMouseGrabbed(false, "application will terminate");
    });
    
    s_appObserversInstalled = true;
}

static void IN_SyncWindowObservers(void)
{
    NSWindow *win = IN_CurrentWindow();
    uintptr_t ptr = (uintptr_t)(__bridge void *)win;
    
    if (ptr == s_observedWindowPtr)
        return;
    
    IN_RemoveWindowObservers();
    
    if (!win)
        return;
    
    s_windowObservers = [NSMutableArray array];
    IN_AddWindowObservers(win);
    s_observedWindowPtr = ptr;
    
    win.acceptsMouseMovedEvents = YES;
    win.ignoresMouseEvents = NO;
    
    IN_LOG_DEV("now observing window #%ld", (long)win.windowNumber);
    IN_LogWindowGeometry(win, "observe-window");
}

//==========================================================================
// Key mapping: macOS virtual key codes -> Quake keys
//==========================================================================

static int IN_NativeKeyCodeToQuakeKey(unsigned short kc)
{
    switch (kc)
    {
        case 0x00: return 'a';
        case 0x01: return 's';
        case 0x02: return 'd';
        case 0x03: return 'f';
        case 0x04: return 'h';
        case 0x05: return 'g';
        case 0x06: return 'z';
        case 0x07: return 'x';
        case 0x08: return 'c';
        case 0x09: return 'v';
        case 0x0A: return '`';    // ISO section
        case 0x0B: return 'b';
        case 0x0C: return 'q';
        case 0x0D: return 'w';
        case 0x0E: return 'e';
        case 0x0F: return 'r';
        case 0x10: return 'y';
        case 0x11: return 't';
        case 0x12: return '1';
        case 0x13: return '2';
        case 0x14: return '3';
        case 0x15: return '4';
        case 0x16: return '6';
        case 0x17: return '5';
        case 0x18: return '=';
        case 0x19: return '9';
        case 0x1A: return '7';
        case 0x1B: return '-';
        case 0x1C: return '8';
        case 0x1D: return '0';
        case 0x1E: return ']';
        case 0x1F: return 'o';
        case 0x20: return 'u';
        case 0x21: return '[';
        case 0x22: return 'i';
        case 0x23: return 'p';
        case 0x24: return K_ENTER;
        case 0x25: return 'l';
        case 0x26: return 'j';
        case 0x27: return '\'';
        case 0x28: return 'k';
        case 0x29: return ';';
        case 0x2A: return '\\';
        case 0x2B: return ',';
        case 0x2C: return '/';
        case 0x2D: return 'n';
        case 0x2E: return 'm';
        case 0x2F: return '.';
        case 0x30: return K_TAB;
        case 0x31: return K_SPACE;
        case 0x32: return '`';
        case 0x33: return K_BACKSPACE;
        case 0x35: return K_ESCAPE;
        case 0x36: return K_COMMAND;
        case 0x37: return K_COMMAND;
        case 0x38: return K_SHIFT;
        case 0x3A: return K_ALT;
        case 0x3B: return K_CTRL;
        case 0x3C: return K_SHIFT;
        case 0x3D: return K_ALT;
        case 0x3E: return K_CTRL;
        case 0x41: return K_KP_DEL;
        case 0x43: return K_KP_STAR;
        case 0x45: return K_KP_PLUS;
        case 0x47: return K_KP_NUMLOCK;
        case 0x4B: return K_KP_SLASH;
        case 0x4C: return K_KP_ENTER;
        case 0x4E: return K_KP_MINUS;
        case 0x52: return K_KP_INS;
        case 0x53: return K_KP_END;
        case 0x54: return K_KP_DOWNARROW;
        case 0x55: return K_KP_PGDN;
        case 0x56: return K_KP_LEFTARROW;
        case 0x57: return K_KP_5;
        case 0x58: return K_KP_RIGHTARROW;
        case 0x59: return K_KP_HOME;
        case 0x5B: return K_KP_UPARROW;
        case 0x5C: return K_KP_PGUP;
        case 0x60: return K_F5;
        case 0x61: return K_F6;
        case 0x62: return K_F7;
        case 0x63: return K_F3;
        case 0x64: return K_F8;
        case 0x65: return K_F9;
        case 0x66: return K_F11;
        case 0x67: return 0;    // F13
        case 0x68: return 0;    // F14
        case 0x69: return K_F10;
        case 0x6A: return K_F12;
        case 0x6B: return 0;    // F15
        case 0x6D: return 0;    // F16
        case 0x72: return K_INS;
        case 0x73: return K_HOME;
        case 0x74: return K_PGUP;
        case 0x75: return K_DEL;
        case 0x76: return K_F4;
        case 0x77: return K_END;
        case 0x78: return K_F2;
        case 0x79: return K_PGDN;
        case 0x7A: return K_F1;
        case 0x7B: return K_LEFTARROW;
        case 0x7C: return K_RIGHTARROW;
        case 0x7D: return K_DOWNARROW;
        case 0x7E: return K_UPARROW;
        default: return 0;
    }
}

//==========================================================================
// Public focus API для vid_macos.m
//==========================================================================

void IN_NativeFocusChanged(qboolean focus)
{
    if (s_windowKey == focus)
        return;
    
    s_windowKey = focus;
    
    if (focus)
    {
        S_UnblockSound();
        IN_LOG_FOCUS("IN_NativeFocusChanged: focus gained");
    }
    else
    {
        S_BlockSound();
        Key_ClearStates();
        IN_ClearLocalInputState();
        IN_LOG_FOCUS("IN_NativeFocusChanged: focus lost");
    }
    
    IN_UpdateMouseGrab();
}

void IN_NativeRequestQuit(void)
{
    s_quitRequested = true;
    IN_LOG_ALWAYS("native quit requested");
}

//==========================================================================
// Mouse motion
//==========================================================================

void IN_MouseMotion(int dx, int dy)
{
    if (!s_windowKey || cl.paused || key_dest != key_game)
    {
        dx = 0;
        dy = 0;
    }
    
    // [MetalQuake] Реальная защита от скачков варпа: 300 пикселей за кадр
    // с запасом хватает даже для резкого флика мышью, но блокирует рывок камеры в небо
    if (dx > 300) dx = 300;
    if (dx < -300) dx = -300;
    if (dy > 300) dy = 300;
    if (dy < -300) dy = -300;
    
    s_totalDX += dx;
    s_totalDY += dy;
}

//==========================================================================
// Commands / modes
//==========================================================================

void IN_Commands(void)
{
    IN_GC_Commands();
}

void IN_JoyMove(usercmd_t *cmd)
{
    IN_GC_Move(cmd);
}

void IN_MouseMove(usercmd_t *cmd)
{
    float dmx, dmy;
    
    dmx = s_totalDX * sensitivity.value;
    dmy = s_totalDY * sensitivity.value;
    
    s_totalDX = 0;
    s_totalDY = 0;
    s_fracDX = 0.0;
    s_fracDY = 0.0;
    
    // паузу проверяем после сброса дельт, чтобы движение во время паузы не накапливалось
    if (cl.paused || key_dest != key_game)
        return;
    
    if ((in_strafe.state & 1) || (lookstrafe.value && (in_mlook.state & 1)))
    {
        cmd->sidemove += m_side.value * dmx;
    }
    else
    {
        cl.viewangles[YAW] -= m_yaw.value * dmx;
    }
    
    // [FIX F1] freelook=1 даёт вертикальный обзор без зажатия +mlook
    if ((in_mlook.state & 1) || freelook.value)
    {
        if (dmx || dmy)
            V_StopPitchDrift();
    }
    
    if (((in_mlook.state & 1) || freelook.value) && !(in_strafe.state & 1))
    {
        cl.viewangles[PITCH] += m_pitch.value * dmy;
        
        // [MetalQuake Smart Clamps]: -85° в небо (зенит), +75° в ноги
        float max_p = (cl_maxpitch.value > 0.0f && cl_maxpitch.value <= 75.0f) ? cl_maxpitch.value : 75.0f;
        float min_p = (cl_minpitch.value < 0.0f && cl_minpitch.value >= -85.0f) ? cl_minpitch.value : -85.0f;
        
        if (cl.viewangles[PITCH] > max_p)
            cl.viewangles[PITCH] = max_p;
        
        if (cl.viewangles[PITCH] < min_p)
            cl.viewangles[PITCH] = min_p;
    }
    else
    {
        if ((in_strafe.state & 1) && noclip_anglehack)
            cmd->upmove -= m_forward.value * dmy;
        else
            cmd->forwardmove -= m_forward.value * dmy;
    }
}

void IN_Move(usercmd_t *cmd)
{
    IN_JoyMove(cmd);
    IN_MouseMove(cmd);
}

void IN_ClearStates(void)
{
    IN_ClearLocalInputState();
}

void IN_UpdateInputMode(void)
{
    s_textMode = Key_TextEntry();
}

//==========================================================================
// Keyboard helpers
//==========================================================================

static void IN_DebugKeyEvent(NSEvent *event, int key, qboolean down)
{
    Con_Printf("%s keyCode: '%hu' quake: '%d' time: %g\n",
               down ? "NSEventKeyDown" : "NSEventKeyUp",
               event.keyCode, key, Sys_DoubleTime());
}

static void IN_HandleModifiers(NSEvent *event)
{
    NSEventModifierFlags m = event.modifierFlags;
    int cur = 0;
    int changed;
    
    if (m & NSEventModifierFlagShift)   cur |= 1;
    if (m & NSEventModifierFlagControl) cur |= 2;
    if (m & NSEventModifierFlagOption)  cur |= 4;
    if (m & NSEventModifierFlagCommand) cur |= 8;
    
    changed = cur ^ s_prevModifiers;
    
    if (!changed)
        return;
    
    static const int keys[4] = { K_SHIFT, K_CTRL, K_ALT, K_COMMAND };
    int i;
    
    for (i = 0; i < 4; i++)
    {
        int bit = 1 << i;
        
        if (changed & bit)
            Key_Event(keys[i], (cur & bit) != 0);
    }
    
    s_prevModifiers = cur;
    
    if (in_debugkeys.value)
        IN_LOG_DEV("modifiers changed -> shift=%d ctrl=%d alt=%d cmd=%d",
                   (cur & 1) != 0, (cur & 2) != 0, (cur & 4) != 0, (cur & 8) != 0);
}

static void IN_HandleKeyEvent(NSEvent *event, qboolean down, BOOL *consume)
{
    int key = IN_NativeKeyCodeToQuakeKey(event.keyCode);
    qboolean gameInput = IN_ShouldConsumeKeyboardEvents();
    NSEventModifierFlags flags = event.modifierFlags;
    
    if (gameInput)
        *consume = YES;
    
    // Cmd-Q: стандартный выход.
    if (down && (flags & NSEventModifierFlagCommand) && key == 'q')
    {
        IN_NativeRequestQuit();
        *consume = YES;
        return;
    }
    
    // В игре съедаем Cmd-комбинации, чтобы не сработали системные/меню-шорткаты.
    if (down && gameInput && (flags & NSEventModifierFlagCommand))
    {
        if (in_debugkeys.value)
            IN_LOG_DEV("consumed Cmd key combo in game: key=%d", key);
        
        *consume = YES;
        return;
    }
    
    if (in_debugkeys.value)
        IN_DebugKeyEvent(event, key, down);
    
    {
        NSString *chars = event.charactersIgnoringModifiers;
        int keycode = key;
        
        if (chars.length > 0)
        {
            unichar c = [chars characterAtIndex:0];
            
            if (c >= 'A' && c <= 'Z')
                c += 32;
            
            if (c < 128)
                keycode = c;
        }
        
        Key_EventWithKeycode(key, down, keycode);
    }
    
    // Текст консоли.
    if (down && s_textMode && !(flags & NSEventModifierFlagCommand))
    {
        NSString *chars = event.characters;
        NSUInteger i;
        
        for (i = 0; i < chars.length; i++)
        {
            unichar c = [chars characterAtIndex:i];
            
            if (c >= 32 && c < 127)
                Char_Event((int)c);
        }
    }
}

//==========================================================================
// Mouse helpers
//==========================================================================

static int IN_ButtonKeyForEvent(NSEvent *event)
{
    int n = -1;
    
    switch (event.type)
    {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
            n = 0;
            break;
            
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
            n = 1;
            break;
            
        case NSEventTypeOtherMouseDown:
        case NSEventTypeOtherMouseUp:
            n = (int)event.buttonNumber;
            break;
            
        default:
            return 0;
    }
    
    if (n < 0 || n > 4)
        return 0;
    
    return buttonremap[n];
}

static void IN_HandleMouseEvent(NSEvent *event, qboolean down, BOOL *consume)
{
    if (IN_ShouldConsumeMouseEvents())
        *consume = YES;
    
    // Кнопки как игровые действия нужны только в игре.
    if (s_noMouse || !s_windowKey || key_dest != key_game || cl.paused)
        return;
    
    int key = IN_ButtonKeyForEvent(event);
    
    if (!key)
        return;
    
    IN_LOG_BTN("%s btn=%d type=%lu", down ? "DOWN" : "UP", key, (unsigned long)event.type);
    Key_Event(key, down);
}

static void IN_HandleMouseMotion(NSEvent *event, BOOL *consume)
{
    if (IN_ShouldConsumeMouseEvents())
        *consume = YES;
    
    if (!s_mouseGrabbed || s_noMouse || !s_windowKey || key_dest != key_game || cl.paused)
        return;
    
    // [MetalQuake] Отсекаем первый спайк дельты после центрирования курсора
    if (s_skipMotionEvents > 0)
    {
        s_skipMotionEvents--;
        s_fracDX = 0.0;
        s_fracDY = 0.0;
        return;
    }
    
    double dx = event.deltaX;
    double dy = event.deltaY;
    
    if (dx == 0.0 && dy == 0.0)
        return;
    
    s_fracDX += dx;
    s_fracDY += dy;
    
    int ix = (int)s_fracDX;
    int iy = (int)s_fracDY;
    
    if (!ix && !iy)
        return;
    
    s_fracDX -= ix;
    s_fracDY -= iy;
    
    IN_MouseMotion(ix, iy);
    
    IN_LOG_MOVE("motion dx=%d dy=%d raw=(%.2f,%.2f)", ix, iy, dx, dy);
}

static void IN_HandleScrollWheel(NSEvent *event, BOOL *consume)
{
    if (IN_ShouldConsumeMouseEvents())
        *consume = YES;
    
    if (s_noMouse || !s_windowKey || cl.paused)
        return;
    
    CGFloat delta = event.scrollingDeltaY;
    
    if (delta == 0.0)
        return;
    
    if (event.hasPreciseScrollingDeltas)
    {
        s_wheelAccum += delta;
        
        while (s_wheelAccum >= 1.0)
        {
            Key_Event(K_MWHEELUP, true);
            Key_Event(K_MWHEELUP, false);
            s_wheelAccum -= 1.0;
        }
        
        while (s_wheelAccum <= -1.0)
        {
            Key_Event(K_MWHEELDOWN, true);
            Key_Event(K_MWHEELDOWN, false);
            s_wheelAccum += 1.0;
        }
    }
    else
    {
        if (delta > 0.0)
        {
            Key_Event(K_MWHEELUP, true);
            Key_Event(K_MWHEELUP, false);
        }
        else if (delta < 0.0)
        {
            Key_Event(K_MWHEELDOWN, true);
            Key_Event(K_MWHEELDOWN, false);
        }
    }
}

//==========================================================================
// Event pump
//==========================================================================

void IN_SendKeyEvents(void)
{
    NSEvent *event;
    
    if (s_quitRequested)
    {
        CL_Disconnect();
        Sys_Quit();
        return;
    }
    
    if (![NSApp isRunning])
        return;
    
    IN_SyncWindowObservers();
    IN_UpdateMouseGrab();
    
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES]) != nil)
    {
        BOOL consume = NO;
        
        switch (event.type)
        {
            case NSEventTypeKeyDown:
                IN_HandleModifiers(event);
                IN_HandleKeyEvent(event, true, &consume);
                break;
                
            case NSEventTypeKeyUp:
                IN_HandleKeyEvent(event, false, &consume);
                break;
                
            case NSEventTypeFlagsChanged:
                IN_HandleModifiers(event);
                if (IN_ShouldConsumeKeyboardEvents())
                    consume = YES;
                break;
                
            case NSEventTypeLeftMouseDown:
            case NSEventTypeRightMouseDown:
            case NSEventTypeOtherMouseDown:
                IN_HandleMouseEvent(event, true, &consume);
                break;
                
            case NSEventTypeLeftMouseUp:
            case NSEventTypeRightMouseUp:
            case NSEventTypeOtherMouseUp:
                IN_HandleMouseEvent(event, false, &consume);
                break;
                
            case NSEventTypeScrollWheel:
                IN_HandleScrollWheel(event, &consume);
                break;
                
            case NSEventTypeMouseMoved:
            case NSEventTypeLeftMouseDragged:
            case NSEventTypeRightMouseDragged:
            case NSEventTypeOtherMouseDragged:
                IN_HandleMouseMotion(event, &consume);
                break;
                
            case NSEventTypeMouseEntered:
            case NSEventTypeMouseExited:
            case NSEventTypeCursorUpdate:
                if (IN_ShouldConsumeMouseEvents())
                    consume = YES;
                break;
                
            default:
                break;
        }
        
        if (!consume)
        {
            [NSApp sendEvent:event];
        }
        else if (in_debugmouse.value && MLog_Budget("INPUT·CONSUME", 200))
        {
            IN_LOG_DEV("consumed AppKit event type=%lu", (unsigned long)event.type);
        }
    }
    
    // key_dest/cl.paused могли измениться после обработки ввода.
    IN_UpdateMouseGrab();
}

//==========================================================================
// Public lifecycle
//==========================================================================

void IN_Activate(void)
{
    IN_LOG_FOCUS("IN_Activate()");
    IN_UpdateMouseGrab();
}

void IN_Deactivate(qboolean free_cursor)
{
    (void)free_cursor;
    
    IN_LOG_FOCUS("IN_Deactivate(free_cursor=%d)", free_cursor ? 1 : 0);
    
    // Всегда освобождаем курсор при деактивации ввода.
    IN_SetMouseGrabbed(false, "IN_Deactivate");
}

void IN_StartupJoystick(void)
{
    IN_GC_Init();
}

void IN_ShutdownJoystick(void)
{
    IN_GC_Shutdown();
}

void IN_Init(void)
{
    s_textMode = Key_TextEntry();
    
    if (COM_CheckParm("-nomouse"))
    {
        s_noMouse = true;
    }
    
    Cvar_RegisterVariable(&in_debugkeys);
    Cvar_RegisterVariable(&in_debugmouse);
    Cvar_RegisterVariable(&in_debugfocus);
    Cvar_RegisterVariable(&freelook);
    
    IN_ClearLocalInputState();
    
    IN_AddAppObservers();
    IN_SyncWindowObservers();
    IN_UpdateMouseGrab();
    IN_StartupJoystick();
    
    IN_LOG_ALWAYS("native input initialized: no_mouse=%d appActive=%d keyWin=%d keyDest=%d",
                  s_noMouse ? 1 : 0,
                  s_appActive ? 1 : 0,
                  s_windowKey ? 1 : 0,
                  key_dest);
}

void IN_Shutdown(void)
{
    IN_LOG_ALWAYS("input shutdown");
    
    IN_ShutdownJoystick();
    
    IN_RemoveWindowObservers();
    s_appObservers = IN_ClearObserverList(s_appObservers);
    s_appObserversInstalled = false;
    
    IN_SetMouseGrabbed(false, "shutdown");
    
    // Дополнительная страховка.
    IN_AssociateCursor(true, "shutdown-final");
    IN_ShowCursor();
}
