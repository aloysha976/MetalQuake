/*
 Copyright (C) 1996-2001 Id Software, Inc.
 Copyright (C) 2002-2009 John Fitzgibbons and others
 Copyright (C) 2007-2008 Kristian Duske
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
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307, USA.
 
 */

// [MQ-NATIVE] vid_macos.m — портирован из gl_vidsdl.c. SDL полностью убран.
//
// ЕДИНСТВЕННЫЙ ИНВАРИАНТ РАЗРЕШЕНИЯ (замена зоопарка G3/F3/F-B/E4):
//   рендер = физические пиксели панели, всегда.
//   - Фуллскрин style 1 (новый дефолт): CGDisplaySetDisplayMode в выбранный
//     режим, borderless-окно = дисплей, contentsScale = pixel/points, кадр 1:1.
//   - Фуллскрин style 0: desktop-borderless без смены режима, drawable =
//     пиксели текущего режима.
//   - Окно: стандартное поведение macOS, drawable = points × backingScaleFactor.
//   - Рендерить больше вывода запрещено; снижение внутреннего разрешения —
//     только явно, через MetalFX.
// -renderw/-renderh больше не существуют.

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreGraphics/CGDirectDisplay.h>
#import <CoreGraphics/CGDisplayConfiguration.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "quakedef.h"
#import "cfgfile.h"
#import "bgmusic.h"
#import "vid.h"
#import "MetalBridge.h"
#import "mq_log.h"	// [D6]/[E5] диагностика

#pragma clang diagnostic ignored "-Wdeprecated-declarations"	// CGDisplaySetDisplayMode/Capture

#define MAX_MODE_LIST	600 //johnfitz -- was 30
#define MAX_BPPS_LIST	5
#define MAX_RATES_LIST	20
#define WARP_WIDTH	320
#define WARP_HEIGHT	200
#define MAXWIDTH	10000
#define MAXHEIGHT	10000
#define METAL_MAX_TEXTURE_EDGE 16384
#define DEFAULT_REFRESHRATE	60

typedef struct {
    int			width;
    int			height;
    int			refreshrate;
    int			bpp;
} vmode_t;

static const char *gl_vendor;
static const char *gl_renderer;
static const char *gl_version;

static vmode_t	modelist[MAX_MODE_LIST];
static int		nummodes;

static qboolean	vid_initialized = false;
static qboolean	vid_locked = false;
static qboolean	vid_changed = false;

//==========================================================================
//  GL-легаси: типы нужны glquake.h, значения Metal не использует.
//  Определения жили в gl_vidsdl.c — перенесены сюда (все пустые).
//==========================================================================
qboolean gl_mtexable = false;
qboolean gl_packed_pixels = false;
qboolean gl_texture_env_combine = false; //johnfitz
qboolean gl_texture_env_add = false; //johnfitz
qboolean gl_swap_control = false; //johnfitz
qboolean gl_anisotropy_able = false; //johnfitz
float gl_max_anisotropy = 0; //johnfitz
qboolean gl_texture_NPOT = false; //ericw
qboolean gl_vbo_able = false; //ericw
qboolean gl_glsl_able = false; //ericw
GLint gl_max_texture_units = 0; //ericw
qboolean gl_glsl_gamma_able = false; //ericw
qboolean gl_glsl_alias_able = false; //ericw
int gl_stencilbits = 0;

PFNGLMULTITEXCOORD2FARBPROC GL_MTexCoord2fFunc = NULL; //johnfitz
PFNGLACTIVETEXTUREARBPROC GL_SelectTextureFunc = NULL; //johnfitz
PFNGLCLIENTACTIVETEXTUREARBPROC GL_ClientActiveTextureFunc = NULL; //ericw
PFNGLBINDBUFFERARBPROC GL_BindBufferFunc = NULL; //ericw
PFNGLBUFFERDATAARBPROC GL_BufferDataFunc = NULL; //ericw
PFNGLBUFFERSUBDATAARBPROC GL_BufferSubDataFunc = NULL; //ericw
PFNGLDELETEBUFFERSARBPROC GL_DeleteBuffersFunc = NULL; //ericw
PFNGLGENBUFFERSARBPROC GL_GenBuffersFunc = NULL; //ericw

QS_PFNGLCREATESHADERPROC GL_CreateShaderFunc = NULL; //ericw
QS_PFNGLDELETESHADERPROC GL_DeleteShaderFunc = NULL; //ericw
QS_PFNGLDELETEPROGRAMPROC GL_DeleteProgramFunc = NULL; //ericw
QS_PFNGLSHADERSOURCEPROC GL_ShaderSourceFunc = NULL; //ericw
QS_PFNGLCOMPILESHADERPROC GL_CompileShaderFunc = NULL; //ericw
QS_PFNGLGETSHADERIVPROC GL_GetShaderivFunc = NULL; //ericw
QS_PFNGLGETSHADERINFOLOGPROC GL_GetShaderInfoLogFunc = NULL; //ericw
QS_PFNGLGETPROGRAMIVPROC GL_GetProgramivFunc = NULL; //ericw
QS_PFNGLGETPROGRAMINFOLOGPROC GL_GetProgramInfoLogFunc = NULL; //ericw
QS_PFNGLCREATEPROGRAMPROC GL_CreateProgramFunc = NULL; //ericw
QS_PFNGLATTACHSHADERPROC GL_AttachShaderFunc = NULL; //ericw
QS_PFNGLLINKPROGRAMPROC GL_LinkProgramFunc = NULL; //ericw
QS_PFNGLBINDATTRIBLOCATIONFUNC GL_BindAttribLocationFunc = NULL; //ericw
QS_PFNGLUSEPROGRAMPROC GL_UseProgramFunc = NULL; //ericw
QS_PFNGLGETATTRIBLOCATIONPROC GL_GetAttribLocationFunc = NULL; //ericw
QS_PFNGLVERTEXATTRIBPOINTERPROC GL_VertexAttribPointerFunc = NULL; //ericw
QS_PFNGLENABLEVERTEXATTRIBARRAYPROC GL_EnableVertexAttribArrayFunc = NULL; //ericw
QS_PFNGLDISABLEVERTEXATTRIBARRAYPROC GL_DisableVertexAttribArrayFunc = NULL; //ericw
QS_PFNGLGETUNIFORMLOCATIONPROC GL_GetUniformLocationFunc = NULL; //ericw
QS_PFNGLUNIFORM1IPROC GL_Uniform1iFunc = NULL; //ericw
QS_PFNGLUNIFORM1FPROC GL_Uniform1fFunc = NULL; //ericw
QS_PFNGLUNIFORM3FPROC GL_Uniform3fFunc = NULL; //ericw
QS_PFNGLUNIFORM4FPROC GL_Uniform4fFunc = NULL; //ericw

QS_PFNGENERATEMIPMAP GL_GenerateMipmap = NULL;

//====================================

//johnfitz -- new cvars
static cvar_t	vid_fullscreen = {"vid_fullscreen", "0", CVAR_ARCHIVE};
static cvar_t	vid_width = {"vid_width", "800", CVAR_ARCHIVE};
static cvar_t	vid_height = {"vid_height", "600", CVAR_ARCHIVE};
static cvar_t	vid_bpp = {"vid_bpp", "16", CVAR_ARCHIVE};
static cvar_t	vid_refreshrate = {"vid_refreshrate", "60", CVAR_ARCHIVE};
static cvar_t	vid_vsync = {"vid_vsync", "0", CVAR_ARCHIVE};
cvar_t	vid_fsaa = {"vid_fsaa", "0", CVAR_ARCHIVE}; // [MQ-MSAA] читается рендерером
static cvar_t	vid_desktopfullscreen = {"vid_desktopfullscreen", "0", CVAR_ARCHIVE};
static cvar_t	vid_borderless = {"vid_borderless", "0", CVAR_ARCHIVE};
// [Metal] Стиль фуллскрина: 0 = desktop-borderless (безопасный режим без смены геометрии монитора)
static cvar_t    vid_fullscreen_style = {"vid_fullscreen_style", "0", CVAR_ARCHIVE};
// [Metal] Сохранение пропорций (0 = растянуть на весь экран, 1 = черные полосы по бокам)
static cvar_t    vid_preserve_aspect = {"vid_preserve_aspect", "0", CVAR_ARCHIVE};
// [Metal] Фильтрация апскейла (0 = Linear / гладкая, 1 = Nearest / резкие пиксели)
static cvar_t    vid_scale_filter = {"vid_scale_filter", "0", CVAR_ARCHIVE};

// [MQ-STAGE3] Явно запрошенное пользователем разрешение рендера сцены
int g_reqRenderWidth = 0;
int g_reqRenderHeight = 0;

// [Metal] Выбранный дисплей (-display N из лаунчера)
static int	g_vidDisplayIndex = 0;

cvar_t		vid_gamma = {"gamma", "1", CVAR_ARCHIVE}; //johnfitz
cvar_t		vid_contrast = {"contrast", "1", CVAR_ARCHIVE}; //QuakeSpasm, MarkV

viddef_t	vid;				// global video state
modestate_t	modestate = MS_UNINIT;
qboolean	scr_skipupdate;

static int fsaa = 0;

//==========================================================================
//  Нативное окно
//==========================================================================

@interface MQGameWindow : NSWindow
@end
@implementation MQGameWindow
- (BOOL)canBecomeKeyWindow  { return YES; }	// borderless-фуллскрин
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface MQGameView : NSView
@end
@implementation MQGameView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }	// кадр ставит CAMetalLayer, не drawRect
// Глотаем без beep — ввод обрабатывает in_macos.m до responder-цепочки
- (void)keyDown:(NSEvent *)e {}
- (void)keyUp:(NSEvent *)e {}
- (void)flagsChanged:(NSEvent *)e {}
- (void)mouseDown:(NSEvent *)e {}
- (void)mouseUp:(NSEvent *)e {}
- (void)rightMouseDown:(NSEvent *)e {}
- (void)rightMouseUp:(NSEvent *)e {}
- (void)otherMouseDown:(NSEvent *)e {}
- (void)otherMouseUp:(NSEvent *)e {}
@end

static MQGameWindow        *mq_window = nil;
static NSView        *mq_contentView = nil;
static MQGameView        *mq_view = nil;
static CAMetalLayer        *mq_layer = nil;
static CGDirectDisplayID    mq_display = 0;
static qboolean            mq_metalAttached = false;
// текущий «логический» режим для VID_GetCurrent*/SyncCvars/vid-меню:
// FS = пиксели режима, окно = points (без обратной связи drawable->points)
static int	s_curW = 320, s_curH = 200;

// из in_macos.m
extern void IN_NativeFocusChanged (qboolean focus);
extern void IN_NativeRequestQuit (void);

// fwd
static void VID_Menu_Init (void); //johnfitz
static void VID_Menu_f (void); //johnfitz
static void VID_MenuDraw (void);
static void VID_MenuKey (int key);
static void ClearAllStates (void);
static void GL_Init (void);
static void GL_SetupState (void); //johnfitz
static void VID_Restart (void);
static qboolean VID_ValidMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen);
static int VID_GetCurrentRefreshRate (void);
static void VID_Gamma_Init (void);
//==========================================================================
//  Дисплеи и режимы
//==========================================================================

// [MQ-STAGE2] Физическое разрешение матрицы монитора (отсекаем виртуальные 5K-буферы macOS)
static void MQVid_GetTruePhysicalSize (CGDirectDisplayID disp, size_t *outW, size_t *outH)
{
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(disp, NULL);
    size_t bestW = 0, bestH = 0;
    size_t bestArea = 0;
    
    if (modes)
    {
        CFIndex count = CFArrayGetCount(modes);
        for (CFIndex i = 0; i < count; i++)
        {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            size_t pw = CGDisplayModeGetPixelWidth(m);
            size_t ph = CGDisplayModeGetPixelHeight(m);
            size_t w  = CGDisplayModeGetWidth(m);
            size_t h  = CGDisplayModeGetHeight(m);
            
            // Только честные нативные режимы матрицы (точки == пиксели).
            // Виртуальные масштабированные HiDPI режимы (где pixelWidth > width) отсекаются.
            if (pw == w && ph == h)
            {
                size_t area = pw * ph;
                if (area > bestArea && pw <= METAL_MAX_TEXTURE_EDGE && ph <= METAL_MAX_TEXTURE_EDGE)
                {
                    bestArea = area;
                    bestW = pw;
                    bestH = ph;
                }
            }
        }
        CFRelease(modes);
    }
    
    // Fallback на случай нестандартных дисплеев
    if (bestArea == 0)
    {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(disp);
        if (cur)
        {
            bestW = CGDisplayModeGetPixelWidth(cur);
            bestH = CGDisplayModeGetPixelHeight(cur);
            CFRelease(cur);
        }
        else
        {
            bestW = 1920;
            bestH = 1080;
        }
    }
    
    if (outW) *outW = bestW;
    if (outH) *outH = bestH;
}

static CGDirectDisplayID MQVid_DisplayForIndex (int index)
{
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) == kCGErrorSuccess && count > 0)
    {
        if (index < 0) index = 0;
        if ((uint32_t)index >= count) index = (int)count - 1;
        return ids[index];
    }
    return CGMainDisplayID();
}

static NSScreen *MQVid_ScreenForDisplay (CGDirectDisplayID disp)
{
    for (NSScreen *scr in [NSScreen screens])
    {
        id num = [[scr deviceDescription] objectForKey:@"NSScreenNumber"];
        if ([num isKindOfClass:[NSNumber class]] &&
            (CGDirectDisplayID)[num unsignedIntValue] == disp)
            return scr;
    }
    return [NSScreen mainScreen];
}

// [E5] DISPMAP: карта дисплеев для сверки с лаунчером
static void MQVid_LogDisplayMap (void)
{
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, ids, &count) == kCGErrorSuccess)
    {
        uint32_t i;
        for (i = 0; i < count; i++)
        {
            NSScreen *scr = MQVid_ScreenForDisplay(ids[i]);
            NSRect b = scr ? scr.frame : NSZeroRect;
            CGDisplayModeRef m = CGDisplayCopyDisplayMode(ids[i]);
            MLog(MQ_LVL_ALWAYS, "DISPMAP", "CG[%u] '%s' bounds=(%.0f,%.0f %.0fx%.0f) mode=%ux%u@%.0fHz",
                 (unsigned)i, scr ? scr.localizedName.UTF8String : "?",
                 b.origin.x, b.origin.y, b.size.width, b.size.height,
                 (unsigned)(m ? CGDisplayModeGetPixelWidth(m) : 0),
                 (unsigned)(m ? CGDisplayModeGetPixelHeight(m) : 0),
                 m ? CGDisplayModeGetRefreshRate(m) : 0);
            if (m) CFRelease(m);
        }
    }
    MLog(MQ_LVL_ALWAYS, "DISPMAP", "selected -display = %d", g_vidDisplayIndex);
}

// Точный поиск режима по ПИКСЕЛЯМ (+refresh), затем релаксация по пикселям.
static CGDisplayModeRef MQVid_FindMode (int width, int height, int refreshrate)
{
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(mq_display, NULL);
    CGDisplayModeRef relaxed = NULL;
    CGDisplayModeRef result = NULL;
    CFIndex i;
    
    if (!modes)
        return NULL;
    
    for (i = 0; i < CFArrayGetCount(modes); i++)
    {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(m) != (size_t)width ||
            CGDisplayModeGetPixelHeight(m) != (size_t)height)
            continue;
        if (refreshrate > 0 &&
            (int)(CGDisplayModeGetRefreshRate(m) + 0.5) == refreshrate)
        {
            result = m;
            break;
        }
        if (!relaxed)
            relaxed = m;
    }
    
    if (!result && relaxed)
        result = relaxed;
    
    if (result)
        CFRetain(result);
    CFRelease(modes);
    return result;
}

// Нативный режим панели: максимум физических пикселей

// [MQ-STAGE1] Аппаратный mode-switch удален: дисплей всегда остается в системном режиме.

// Масштаб слоя: contentsScale = pixel/points, drawable = пиксели панели
static void MQVid_ApplyLayerScale (size_t pixelW, size_t pixelH, CGFloat pointsW, CGFloat pointsH)
{
    if (!mq_layer || pointsW < 1 || pointsH < 1)
        return;
    mq_layer.contentsScale = (CGFloat)pixelW / pointsW;
    mq_layer.drawableSize = CGSizeMake((CGFloat)pixelW, (CGFloat)pixelH);
}

static void MQVid_SyncVidFromLayer (void)
{
    if (!mq_layer)
        return;
    vid.width  = (int)mq_layer.drawableSize.width;
    vid.height = (int)mq_layer.drawableSize.height;
    vid.conwidth = vid.width & 0xFFFFFFF8;
    vid.conheight = vid.conwidth * vid.height / vid.width;
    vid.numpages = 2;
}

//==========================================================================
//  Окно: события
//==========================================================================

@interface MQGameWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation MQGameWindowDelegate
- (void)windowDidBecomeKey:(NSNotification *)note
{
    (void)note;
    IN_NativeFocusChanged(true);
}
- (void)windowDidResignKey:(NSNotification *)note
{
    (void)note;
    IN_NativeFocusChanged(false);
}
- // [MQ-RESIZE-OWNER] Единый владелец ресайза — R_Metal_HandleWindowResize
// (обсервер в mq_window_macos.m): он делает всё то же самое ПЛЮС ресайз
// depth-текстуры, которую этот делегат не обновлял. Дублирование здесь
// приводило к двум записям drawableSize по разным формулам
// (convertSizeToBacking vs contentsScale) и расхождению в mode-switch FS.
// Делегат намеренно пуст.
(void)windowDidResize:(NSNotification *)note
{
    (void)note;
}
- (BOOL)windowShouldClose:(NSWindow *)sender
{
    (void)sender;
    IN_NativeRequestQuit();
    return NO; // закрываемся сами через Sys_Quit
}
@end

static MQGameWindowDelegate *mq_delegate = nil;

static void MQVid_MakeWindow (const char *caption, NSRect frame, NSWindowStyleMask style)
{
    if (mq_window == nil)
    {
        mq_window = [[MQGameWindow alloc]
                     initWithContentRect:frame
                     styleMask:NSWindowStyleMaskTitled
                     backing:NSBackingStoreBuffered
                     defer:NO];
        mq_delegate = [[MQGameWindowDelegate alloc] init];
        mq_window.delegate = mq_delegate;
        
        // [FIX MQ-NATIVE-L2] Metal-view — ПОДВИЬ обычного contentView,
        // а не сам contentView (как у SDL_Metal). AppKit при смене
        // styleMask/contentLayoutRect может подменить слой contentView —
        // тогда мы рендерим в «осиротевший» слой и экран чёрный при
        // полностью рабочем рендере. Подвью никто не трогает.
        mq_contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        mq_contentView.wantsLayer = YES;
        
        mq_view = [[MQGameView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        CAMetalLayer *metalLayer = [CAMetalLayer layer];
        mq_view.layer = metalLayer;			// setLayer: до layer-backing
        mq_view.wantsLayer = YES;			// AppKit принимает готовый слой
        mq_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [mq_contentView addSubview:mq_view];
        
        mq_window.contentView = mq_contentView;
        
        mq_layer = metalLayer;
        if (![mq_layer isKindOfClass:[CAMetalLayer class]])
        {
            MLog(MQ_LVL_ALWAYS, "VID",
                 "ERROR: MQGameView layer is %s, ожидается CAMetalLayer",
                 mq_layer ? NSStringFromClass(mq_layer.class).UTF8String : "nil");
            mq_layer = nil;
        }
        mq_layer.allowsNextDrawableTimeout = YES;
        mq_layer.maximumDrawableCount = 3;
        mq_layer.displaySyncEnabled = (vid_vsync.value != 0);
    }
    
    mq_window.styleMask = style;
    mq_window.title = [NSString stringWithUTF8String:caption];
    [mq_window setFrame:frame display:NO];
    mq_contentView.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    mq_view.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    mq_layer.frame = mq_view.bounds;
    
    gl_swap_control = true; // vsync живёт в CAMetalLayer (displaySync)
}

//==========================================================================
//  VID_SetMode — нативная реализация
//==========================================================================

static qboolean VID_SetMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
    char caption[256];
    qboolean desktopFS;
    qboolean modeSwitchFS;
    NSScreen *scr;
    NSRect dispBounds;
    CGDisplayModeRef curMode;
    size_t pixW, pixH;
    
    // so Con_Printfs don't mess us up by forcing vid and snd updates
    int temp = scr_disabled_for_loading;
    scr_disabled_for_loading = true;
    
    CDAudio_Pause ();
    BGM_Pause ();
    
    R_Metal_GetAppTitle(caption, sizeof(caption));
    
    mq_display = MQVid_DisplayForIndex(g_vidDisplayIndex);
    scr = MQVid_ScreenForDisplay(mq_display);
    dispBounds = scr ? scr.frame : NSMakeRect(0, 0, width, height);
    
    // Получаем физические пиксели матрицы экрана (для 4K — строго 3840x2160)
    MQVid_GetTruePhysicalSize(mq_display, &pixW, &pixH);
    
    // [MQ-STAGE1] Фуллскрин всегда работает как Desktop Borderless во весь экран выбранного монитора
    desktopFS    = fullscreen;
    modeSwitchFS = false;
    
    // ---------- Геометрия окна ----------
        if (fullscreen)
        {
            MQVid_MakeWindow(caption, dispBounds, NSWindowStyleMaskBorderless);
            [mq_window setFrame:dispBounds display:YES];
            MQVid_ApplyLayerScale(pixW, pixH, dispBounds.size.width, dispBounds.size.height);
            s_curW = (int)pixW;
            s_curH = (int)pixH;

            // Поднимаем окно выше уровня строки меню (NSMainMenuWindowLevel + 1)
            [mq_window setLevel:NSMainMenuWindowLevel + 1];
            [NSApp setPresentationOptions:NSApplicationPresentationHideMenuBar |
                          NSApplicationPresentationHideDock];
            Cvar_SetValueQuick (&vid_fullscreen, 1.0f);
            modestate = MS_FULLSCREEN;
        }
    else
    {
        // [FIX MQ-MENUBAR] возврат системного UI в оконном режиме
        [NSApp setPresentationOptions:NSApplicationPresentationDefault];
        
        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask style = NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskMiniaturizable |
        NSWindowStyleMaskResizable;
        if (vid_borderless.value)
            style = NSWindowStyleMaskBorderless;
        
        // [MQ-STAGE1] Режим дисплея не менялся, откат не требуется
        
        MQVid_MakeWindow(caption, frame, style);
        
        // центрируем на целевом дисплее
        {
            NSRect winF = mq_window.frame;
            NSRect target = NSMakeRect(
                                       dispBounds.origin.x + (dispBounds.size.width  - winF.size.width)  / 2,
                                       dispBounds.origin.y + (dispBounds.size.height - winF.size.height) / 2,
                                       winF.size.width, winF.size.height);
            [mq_window setFrame:target display:YES];
        }
        
        CGFloat scale = scr ? scr.backingScaleFactor : 1.0;
        if (scale <= 0) scale = 1.0;
        mq_layer.contentsScale = scale;
        mq_layer.drawableSize = CGSizeMake(frame.size.width * scale,
                                           frame.size.height * scale);
        s_curW = width;
        s_curH = height;
        // [FIX MQ-NATIVE-L3] возврат на нормальный уровень после захвата
        [mq_window setLevel:NSNormalWindowLevel];
        modestate = MS_WINDOWED;
    }
    
    [mq_window makeKeyAndOrderFront:nil];
    // [FIX MQ-NATIVE-L2] Верификация идентичности слоя: слой на ЭКРАНЕ должен
    // быть тем же, в который рендерим (иначе — чёрный экран при живом рендере)
    MLog(MQ_LVL_ALWAYS, "VID",
         "L1-check: layerOnScreen=%s sameAsRender=%d contentView=%s viewHidden=%d occlusion=%lx level=%ld",
         NSStringFromClass(mq_view.layer.class).UTF8String,
         mq_view.layer == (CALayer *)mq_layer ? 1 : 0,
         NSStringFromClass(mq_window.contentView.class).UTF8String,
         mq_view.isHidden ? 1 : 0,
         (unsigned long)mq_window.occlusionState,
         (long)mq_window.level);
    [NSApp activateIgnoringOtherApps:YES];
    
    // ---------- Metal context (однократно) ----------
    if (!mq_metalAttached)
    {
        R_Metal_Init();
        R_Metal_SetLayer((__bridge void *)mq_layer);
        R_Metal_ConfigureNativeWindow((__bridge void *)mq_window, caption);
        R_Metal_ActivateGameWindow();
        Con_SafePrintf ("Metal 3 rendering context attached to native NSWindow successfully.\n");
        TexMgr_ReloadImages();
        mq_metalAttached = true;
    }
    
    MQVid_SyncVidFromLayer();
    
    // [FIX D7-натив] одна строка: ЧТО реально установлено
    MLog(MQ_LVL_ALWAYS, "VID",
         "native mode: drawable %dx%d @ %s (window %.0fx%.0f pts on display %d, refresh %d)",
         vid.width, vid.height,
         modeSwitchFS ? "switched-mode" : (desktopFS ? "desktop-fs" : "windowed"),
         dispBounds.size.width, dispBounds.size.height, g_vidDisplayIndex,
         VID_GetCurrentRefreshRate());
    
    CDAudio_Resume ();
    BGM_Resume ();
    scr_disabled_for_loading = temp;
    
    ClearAllStates ();
    
    vid.recalc_refdef = 1;
    vid_changed = false;
    
    (void)bpp;
    return true;
}

/*
 =======================
 VID_GetCurrentWidth/Height — «логический» режим (FS: пиксели, окно: points).
 Питает SyncCvars/vid-меню; drawable живёт в vid.width/height.
 =======================
 */
static int VID_GetCurrentWidth (void)
{
    return s_curW;
}

static int VID_GetCurrentHeight (void)
{
    return s_curH;
}

static int VID_GetCurrentRefreshRate (void)
{
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(mq_display);
    int rate = DEFAULT_REFRESHRATE;
    if (m)
    {
        double r = CGDisplayModeGetRefreshRate(m);
        if (r > 0) rate = (int)(r + 0.5);
        CFRelease(m);
    }
    return rate;
}

static int VID_GetCurrentBPP (void)
{
    return 32;
}

/*
 ====================
 VID_GetFullscreen — regular или desktop fullscreen
 ====================
 */
static qboolean VID_GetFullscreen (void)
{
    return modestate == MS_FULLSCREEN;
}

/*
 ====================
 VID_GetDesktopFullscreen — именно "desktop fullscreen" (без смены режима)
 ====================
 */
static qboolean VID_GetDesktopFullscreen (void)
{
    return modestate == MS_FULLSCREEN;
}

/*
 ====================
 VID_GetVSync
 ====================
 */
static qboolean VID_GetVSync (void)
{
    return vid_vsync.value != 0;
}

/*
 ====================
 VID_GetWindow
 ====================
 */
void *VID_GetWindow (void)
{
    return (__bridge void *)mq_window;
}

/*
 ====================
 VID_HasMouseOrInputFocus
 ====================
 */
qboolean VID_HasMouseOrInputFocus (void)
{
    return mq_window != nil && mq_window.isKeyWindow;
}

/*
 ====================
 VID_IsMinimized
 ====================
 */
qboolean VID_IsMinimized (void)
{
    return mq_window == nil || mq_window.isMiniaturized;
}

/*
================
VID_ValidMode_Unchecked — [MQ-STAGE6] Любой Render Target от 320x200 до 16K валиден
================
*/
static qboolean VID_ValidMode_Unchecked (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
    (void)refreshrate;
    (void)fullscreen;

    // Проверяем только границы допустимых текстур Metal
    if (width < 320 || height < 200)
        return false;

    if (width > METAL_MAX_TEXTURE_EDGE || height > METAL_MAX_TEXTURE_EDGE)
        return false;

    switch (bpp)
    {
    case 16:
    case 24:
    case 32:
        break;
    default:
        return false;
    }

    return true;
}

/*
 ================
 VID_ValidMode -- [D6] обёртка с диагностикой
 ================
 */
static qboolean VID_ValidMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
    qboolean ok = VID_ValidMode_Unchecked (width, height, refreshrate, bpp, fullscreen);
    MLog(MQ_LVL_DEV, "VID",
         "ValidMode: req=%dx%d rr=%d bpp=%d fs=%d style=%.0f deskFS=%.0f disp=%d -> %s",
         width, height, refreshrate, bpp,
         fullscreen ? 1 : 0,
         vid_fullscreen_style.value, vid_desktopfullscreen.value,
         g_vidDisplayIndex, ok ? "VALID" : "INVALID");
    return ok;
}

/*
 ===================
 VID_Changed_f
 ===================
 */
static void VID_Changed_f (cvar_t *var)
{
    vid_changed = true;
}

// [FIX VSYNC] vid_vsync должен реально управлять CAMetalLayer.displaySyncEnabled.
// Применяем сразу, без тяжёлого vid_restart.
static void VID_VSync_f (cvar_t *var)
{
    if (mq_layer)
        mq_layer.displaySyncEnabled = (var->value != 0);
}

/*
 ===================
 VID_Restart -- johnfitz -- change video modes on the fly
 ===================
 */
static void VID_Restart (void)
{
    int width, height, refreshrate, bpp;
    qboolean fullscreen;
    
    if (vid_locked || !vid_changed)
        return;
    
    width = (int)vid_width.value;
    height = (int)vid_height.value;
    refreshrate = (int)vid_refreshrate.value;
    bpp = (int)vid_bpp.value;
    fullscreen = vid_fullscreen.value ? true : false;
    
    // validate new mode
    if (!VID_ValidMode (width, height, refreshrate, bpp, fullscreen))
    {
        Con_Printf ("%dx%dx%d %dHz %s is not a valid mode\n",
                    width, height, bpp, refreshrate, fullscreen? "fullscreen" : "windowed");
        return;
    }
    
    TexMgr_DeleteTextureObjects ();
    GLSLGamma_DeleteTexture ();
    R_ScaleView_DeleteTexture ();
    R_DeleteShaders ();
    GL_DeleteBModelVertexBuffer ();
    GLMesh_DeleteVertexBuffers ();
    
    VID_SetMode (width, height, refreshrate, bpp, fullscreen);
    
    GL_Init ();
    TexMgr_ReloadImages ();
    GL_BuildBModelVertexBuffer ();
    GLMesh_LoadVertexBuffers ();
    GL_SetupState ();
    Fog_SetupState ();
    
    //warpimages needs to be recalculated
    TexMgr_RecalcWarpImageSize ();
    
    //conwidth and conheight need to be recalculated
    SCR_UpdateConwidth (vid.width, vid.height);
    
    VID_SyncCvars();
    
    // update mouse grab
    if (key_dest == key_console || key_dest == key_menu)
    {
        if (modestate == MS_WINDOWED)
            IN_Deactivate(true);
        else if (modestate == MS_FULLSCREEN)
            IN_Activate();
    }
}

/*
 ================
 VID_Test -- johnfitz -- like vid_restart, but asks for confirmation after switching modes
 ================
 */
static void VID_Test (void)
{
    int old_width, old_height, old_refreshrate, old_bpp, old_fullscreen;
    
    if (vid_locked || !vid_changed)
        return;
    
    old_width = VID_GetCurrentWidth();
    old_height = VID_GetCurrentHeight();
    old_refreshrate = VID_GetCurrentRefreshRate();
    old_bpp = VID_GetCurrentBPP();
    old_fullscreen = VID_GetFullscreen() ? true : false;
    
    VID_Restart ();
    
    //pop up confirmation dialoge
    if (!SCR_ModalMessage("Would you like to keep this\nvideo mode? (y/n)\n", 5.0f))
    {
        //revert cvars and mode
        Cvar_SetValueQuick (&vid_width, old_width);
        Cvar_SetValueQuick (&vid_height, old_height);
        Cvar_SetValueQuick (&vid_refreshrate, old_refreshrate);
        Cvar_SetValueQuick (&vid_bpp, old_bpp);
        Cvar_SetQuick (&vid_fullscreen, old_fullscreen ? "1" : "0");
        VID_Restart ();
    }
}

/*
 ================
 VID_Unlock -- johnfitz
 ================
 */
static void VID_Unlock (void)
{
    vid_locked = false;
    VID_SyncCvars();
}

/*
 ================
 VID_Lock -- ericw
 ================
 */
void VID_Lock (void)
{
    vid_locked = true;
}

//==============================================================================
//	OPENGL STUFF (Metal-стабы)
//==============================================================================

static void GL_Info_f (void)
{
    Con_SafePrintf ("GL_VENDOR: %s\n", gl_vendor);
    Con_SafePrintf ("GL_RENDERER: %s\n", gl_renderer);
    Con_SafePrintf ("GL_VERSION: %s\n", gl_version);
}

static void GL_Init (void)
{
    gl_vendor = "Apple";
    gl_renderer = "Apple Silicon Metal 3 Engine";
    gl_version = "2.1 Metal Wrapper (native window)";
    
    Con_SafePrintf ("GL_VENDOR: %s\n", gl_vendor);
    Con_SafePrintf ("GL_RENDERER: %s\n", gl_renderer);
    Con_SafePrintf ("GL_VERSION: %s\n", gl_version);
    
    GL_ClearBufferBindings ();
}

static void GL_SetupState (void)
{
}

/*
 =================
 GL_BeginRendering -- sets values of glx, gly, glwidth, glheight
 =================
 */
void GL_BeginRendering (int *x, int *y, int *width, int *height)
{
    *x = *y = 0;
    *width = vid.width;
    *height = vid.height;
    
    if (!scr_skipupdate)
    {
        // [Metal] Открываем команду кадра
        R_Metal_BeginFrame();
    }
}

/*
 =================
 GL_EndRendering
 =================
 */
void GL_EndRendering (void)
{
    if (!scr_skipupdate)
    {
        // [Metal] Завершаем кадр и отправляем на дисплей
        R_Metal_EndFrame();
    }
}

void VID_Shutdown (void)
{
    if (vid_initialized)
    {
        [NSApp setPresentationOptions:NSApplicationPresentationDefault];
        
        if (mq_window)
        {
            [mq_window setDelegate:nil];
            [mq_window orderOut:nil];
            [mq_window close];
            mq_window = nil;
            mq_contentView = nil;
            mq_view = nil;
            mq_layer = nil;
        }
    }
}

/*
 ================
 ClearAllStates
 ================
 */
static void ClearAllStates (void)
{
    Key_ClearStates ();
    IN_ClearStates ();
}

//==========================================================================
//  COMMANDS
//==========================================================================

static void VID_DescribeCurrentMode_f (void)
{
    Con_Printf("%dx%dx%d %dHz %s\n",
               VID_GetCurrentWidth(),
               VID_GetCurrentHeight(),
               VID_GetCurrentBPP(),
               VID_GetCurrentRefreshRate(),
               VID_GetFullscreen() ? "fullscreen" : "windowed");
}

static void VID_DescribeModes_f (void)
{
    int	i;
    int	lastwidth, lastheight, lastbpp, count;
    
    lastwidth = lastheight = lastbpp = count = 0;
    
    for (i = 0; i < nummodes; i++)
    {
        if (lastwidth != modelist[i].width || lastheight != modelist[i].height || lastbpp != modelist[i].bpp)
        {
            if (count > 0)
                Con_SafePrintf ("\n");
            Con_SafePrintf ("   %4i x %4i x %i : %i", modelist[i].width, modelist[i].height, modelist[i].bpp, modelist[i].refreshrate);
            lastwidth = modelist[i].width;
            lastheight = modelist[i].height;
            lastbpp = modelist[i].bpp;
            count++;
        }
    }
    Con_Printf ("\n%i modes\n", count);
}

static void VID_FSAA_f (cvar_t *var)
{
    // don't print the warning if vid_fsaa is set during startup
    if (vid_initialized)
        Con_Printf("%s %d requires engine restart to take effect\n", var->name, (int)var->value);
}

//==========================================================================
//  INIT
//==========================================================================

/*
 ================
 VID_InitModelist — пиксельные размеры уникальных режимов целевого дисплея
 ================
 */
static void VID_InitModelist (void)
{
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(mq_display, NULL);
    CFIndex i;
    
    nummodes = 0;
    if (!modes)
        return;
    
    for (i = 0; i < CFArrayGetCount(modes) && nummodes < MAX_MODE_LIST; i++)
    {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        int w = (int)CGDisplayModeGetPixelWidth(m);
        int h = (int)CGDisplayModeGetPixelHeight(m);
        int r = (int)(CGDisplayModeGetRefreshRate(m) + 0.5);
        int j, existing = 0;
        
        if (w > MAXWIDTH || h > MAXHEIGHT || w < 320 || h < 200)
            continue;
        
        for (j = 0; j < nummodes; j++)
        {
            if (modelist[j].width == w && modelist[j].height == h &&
                modelist[j].refreshrate == r)
            {
                existing = 1;
                break;
            }
        }
        if (!existing)
        {
            modelist[nummodes].width = w;
            modelist[nummodes].height = h;
            modelist[nummodes].bpp = 32;
            modelist[nummodes].refreshrate = r > 0 ? r : DEFAULT_REFRESHRATE;
            nummodes++;
        }
    }
    CFRelease(modes);
}

//==========================================================================
//  [MQ-DISPLAY] Обработка смены дисплея на лету (hot-plug, переезд окна)
//  Инвариант: мы НЕ вызываем vid_restart. Мы адаптируем геометрию и режим
//  на лету. Если эксклюзивный режим недоступен — тихая деградация в Desktop-FS.
//==========================================================================
void VID_WindowDidChangeScreen(void)
{
    if (!mq_window) return;
    
    NSScreen *newScr = mq_window.screen;
    if (!newScr) newScr = [NSScreen mainScreen];
    if (!newScr) return;
    
    NSNumber *screenNum = [newScr.deviceDescription objectForKey:@"NSScreenNumber"];
    if (![screenNum isKindOfClass:[NSNumber class]]) return;
    CGDirectDisplayID newDisplayID = (CGDirectDisplayID)[screenNum unsignedIntValue];
    
    // 1. Дисплей не изменился, но могли измениться параметры (например, в Системных настройках)
    if (newDisplayID == mq_display) {
        if (modestate == MS_WINDOWED && mq_layer) {
            CGFloat newScale = newScr.backingScaleFactor;
            if (newScale > 0 && mq_layer.contentsScale != newScale) {
                mq_layer.contentsScale = newScale;
                MLog(MQ_LVL_DEV, "VID", "same display, backingScaleFactor updated to %.1f", newScale);
            }
        }
        return;
    }
    
    MLog(MQ_LVL_ALWAYS, "VID", "window moved to new display: %u -> %u", (unsigned)mq_display, (unsigned)newDisplayID);
    mq_display = newDisplayID;
    VID_InitModelist(); // Перечитываем режимы для нового дисплея
    
    // 2. Адаптация под текущий тип полноэкранного режима
    if (modestate == MS_FULLSCREEN) {
        NSRect newBounds = newScr.frame;
        [mq_window setFrame:newBounds display:YES];
        
        size_t pixW, pixH;
        MQVid_GetTruePhysicalSize(mq_display, &pixW, &pixH);
        
        MQVid_ApplyLayerScale(pixW, pixH, newBounds.size.width, newBounds.size.height);
        s_curW = (int)pixW;
        s_curH = (int)pixH;
        MLog(MQ_LVL_DEV, "VID", "Desktop-FS adapted to new screen %zux%zu", pixW, pixH);
    }
    else if (modestate == MS_WINDOWED) {
        // --- Оконный режим ---
        // Просто обновляем масштаб, если экран Retina/Non-Retina
        CGFloat newScale = newScr.backingScaleFactor;
        if (newScale <= 0) newScale = 1.0;
        mq_layer.contentsScale = newScale;
    }
}

/*
 ==================
 VID_Init
 ==================
 */
void	VID_Init (void)
{
    int		p, width, height, refreshrate, bpp;
    int		display_width, display_height, display_refreshrate, display_bpp;
    qboolean	fullscreen;
    const char    *read_vars[] = { "vid_fullscreen",
        "vid_width",
        "vid_height",
        "vid_refreshrate",
        "vid_bpp",
        "vid_vsync",
        "vid_fsaa",
        "vid_desktopfullscreen",
        "vid_borderless",
                             "vid_fullscreen_style",
                             "vid_preserve_aspect",
                             "vid_scale_filter"};
#define num_readvars	Q_COUNTOF(read_vars)
    
    Cvar_RegisterVariable (&vid_fullscreen);
    Cvar_RegisterVariable (&vid_width);
    Cvar_RegisterVariable (&vid_height);
    Cvar_RegisterVariable (&vid_refreshrate);
    Cvar_RegisterVariable (&vid_bpp);
    Cvar_RegisterVariable (&vid_vsync);
    Cvar_RegisterVariable (&vid_fsaa);
    Cvar_RegisterVariable (&vid_desktopfullscreen);
    Cvar_RegisterVariable (&vid_borderless);
    Cvar_RegisterVariable (&vid_fullscreen_style);
        Cvar_RegisterVariable (&vid_preserve_aspect);
        Cvar_RegisterVariable (&vid_scale_filter);
    Cvar_SetCallback (&vid_fullscreen, VID_Changed_f);
    Cvar_SetCallback (&vid_width, VID_Changed_f);
    Cvar_SetCallback (&vid_height, VID_Changed_f);
    Cvar_SetCallback (&vid_refreshrate, VID_Changed_f);
    Cvar_SetCallback (&vid_bpp, VID_Changed_f);
    Cvar_SetCallback (&vid_vsync, VID_VSync_f);
    Cvar_SetCallback (&vid_fsaa, VID_FSAA_f);
    Cvar_SetCallback (&vid_desktopfullscreen, VID_Changed_f);
    Cvar_SetCallback (&vid_borderless, VID_Changed_f);
    
    Cmd_AddCommand ("vid_unlock", VID_Unlock);
    Cmd_AddCommand ("vid_restart", VID_Restart);
    Cmd_AddCommand ("vid_test", VID_Test);
    Cmd_AddCommand ("vid_describecurrentmode", VID_DescribeCurrentMode_f);
    Cmd_AddCommand ("vid_describemodes", VID_DescribeModes_f);
    
    // [FIX G4b] -display ДО чтения десктопного режима
    p = COM_CheckParm("-display");
    if (p && p < com_argc-1)
    {
        CGDirectDisplayID ids[16];
        uint32_t count = 0;
        CGGetActiveDisplayList(16, ids, &count);
        g_vidDisplayIndex = CLAMP(0, Q_atoi(com_argv[p+1]), count > 0 ? (int)count - 1 : 0);
    }
    
    // [MQ-NATIVE] -renderw/-renderh удалены: рендер всегда = пиксели вывода.
    
    // Десктопный режим ЦЕЛЕВОГО дисплея
    {
        mq_display = MQVid_DisplayForIndex(g_vidDisplayIndex);
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mq_display);
        NSScreen *scr = MQVid_ScreenForDisplay(mq_display);
        if (!mode)
            Sys_Error("Could not get desktop display mode");
        // «Логический» десктопный размер = точки (как SDL mode.w),
        // refresh и bpp — из режима
        display_width  = scr ? (int)scr.frame.size.width  : (int)CGDisplayModeGetWidth(mode);
        display_height = scr ? (int)scr.frame.size.height : (int)CGDisplayModeGetHeight(mode);
        double rr = CGDisplayModeGetRefreshRate(mode);
        display_refreshrate = rr > 0 ? (int)(rr + 0.5) : DEFAULT_REFRESHRATE;
        display_bpp = 32;
        CFRelease(mode);
    }
    
    Cvar_SetValueQuick (&vid_bpp, (float)display_bpp);
    
    if (CFG_OpenConfig("config.cfg") == 0)
    {
        CFG_ReadCvars(read_vars, num_readvars);
        CFG_CloseConfig();
    }
    CFG_ReadCvarOverrides(read_vars, num_readvars);
    
    MQVid_LogDisplayMap();
    
    VID_InitModelist();
    
    width = (int)vid_width.value;
    height = (int)vid_height.value;
    refreshrate = (int)vid_refreshrate.value;
    bpp = (int)vid_bpp.value;
    fullscreen = (int)vid_fullscreen.value;
    fsaa = (int)vid_fsaa.value;
    
    if (COM_CheckParm("-current"))
    {
        width = display_width;
        height = display_height;
        refreshrate = display_refreshrate;
        bpp = display_bpp;
        fullscreen = true;
    }
    else
    {
        p = COM_CheckParm("-width");
        if (p && p < com_argc-1)
        {
            width = Q_atoi(com_argv[p+1]);
            
            if(!COM_CheckParm("-height"))
                height = width * 3 / 4;
        }
        
        p = COM_CheckParm("-height");
        if (p && p < com_argc-1)
        {
            height = Q_atoi(com_argv[p+1]);
            
            if(!COM_CheckParm("-width"))
                width = height * 4 / 3;
        }
        
        p = COM_CheckParm("-refreshrate");
        if (p && p < com_argc-1)
            refreshrate = Q_atoi(com_argv[p+1]);
        
        p = COM_CheckParm("-bpp");
        if (p && p < com_argc-1)
            bpp = Q_atoi(com_argv[p+1]);
        
        if (COM_CheckParm("-window") || COM_CheckParm("-w"))
                {
                    fullscreen = false;
                    Cvar_SetValueQuick (&vid_fullscreen, 0.0f);
                }
                else if (COM_CheckParm("-fullscreen") || COM_CheckParm("-f"))
                {
                    fullscreen = true;
                    Cvar_SetValueQuick (&vid_fullscreen, 1.0f);
                }
    }
    
    p = COM_CheckParm ("-fsaa");
    if (p && p < com_argc-1)
        fsaa = atoi(com_argv[p+1]);
    
    // [MQ-STAGE3] Сохраняем запрошенное разрешение для Metal-рендерера
        if (fullscreen)
        {
            qboolean customRes = COM_CheckParm("-width") || COM_CheckParm("-height");
            if (!customRes)
            {
                width = display_width;
                height = display_height;
            }
            refreshrate = display_refreshrate;
            g_reqRenderWidth = width;
            g_reqRenderHeight = height;
            Cvar_SetValueQuick (&vid_width, (float)width);
            Cvar_SetValueQuick (&vid_height, (float)height);
            MLog(MQ_LVL_ALWAYS, "VID",
                 "STAGE3: Render Target = %dx%d (Display Panel = %dx%d@%d)",
                 width, height, display_width, display_height, refreshrate);
        }
    
    if (!VID_ValidMode(width, height, refreshrate, bpp, fullscreen))
    {
        width = (int)vid_width.value;
        height = (int)vid_height.value;
        refreshrate = (int)vid_refreshrate.value;
        bpp = (int)vid_bpp.value;
        fullscreen = (int)vid_fullscreen.value;
    }
    
    if (!VID_ValidMode(width, height, refreshrate, bpp, fullscreen))
    {
        width = 640;
        height = 480;
        refreshrate = display_refreshrate;
        bpp = display_bpp;
        fullscreen = false;
    }
    
    vid_initialized = true;
    
    vid.maxwarpwidth = WARP_WIDTH;
    vid.maxwarpheight = WARP_HEIGHT;
    vid.colormap = host_colormap;
    vid.fullbright = 256 - LittleLong (*((int *)vid.colormap + 2048));
    
    // [D6] итог цепочки переопределений
    MLog(MQ_LVL_DEV, "VID", "FINAL mode: %dx%d rr=%d bpp=%d fs=%d",
         width, height, refreshrate, bpp, fullscreen ? 1 : 0);
    
    VID_SetMode (width, height, refreshrate, bpp, fullscreen);
    
    GL_Init ();
    GL_SetupState ();
    Cmd_AddCommand ("gl_info", GL_Info_f); //johnfitz
    
    vid_menucmdfn = VID_Menu_f; //johnfitz
    vid_menudrawfn = VID_MenuDraw;
    vid_menukeyfn = VID_MenuKey;
    
    VID_Gamma_Init(); //johnfitz
    VID_Menu_Init(); //johnfitz
    
    //QuakeSpasm: current vid settings should override config file settings.
    vid_locked = true;
}

/*
 ================
 VID_Gamma — аппаратной гаммы на macOS нет (как и в SDL-версии: gammaworks=false)
 ================
 */
static void VID_Gamma_f (cvar_t *var) { (void)var; }

static void VID_Gamma_Init (void)
{
    Cvar_RegisterVariable (&vid_gamma);
    Cvar_RegisterVariable (&vid_contrast);
    Cvar_SetCallback (&vid_gamma, VID_Gamma_f);
    Cvar_SetCallback (&vid_contrast, VID_Gamma_f);
    
    Con_SafePrintf("gamma adjustment not available\n");
}

// new proc by S.A., called by alt-return key binding.
void	VID_Toggle (void)
{
    // [MQ-NATIVE] быстрого пути нет — всегда через vid_restart
    S_ClearBuffer ();
    Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "0" : "1");
    Cbuf_AddText ("vid_restart\n");
}

/*
 ================
 VID_SyncCvars -- johnfitz -- set vid cvars to match current video mode
 ================
 */
void VID_SyncCvars (void)
{
    if (mq_window)
    {
        if (!VID_GetDesktopFullscreen())
        {
            Cvar_SetValueQuick (&vid_width, VID_GetCurrentWidth());
            Cvar_SetValueQuick (&vid_height, VID_GetCurrentHeight());
        }
        Cvar_SetValueQuick (&vid_refreshrate, VID_GetCurrentRefreshRate());
        Cvar_SetValueQuick (&vid_bpp, VID_GetCurrentBPP());
        Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "1" : "0");
        // don't sync vid_desktopfullscreen, it's a user preference
        Cvar_SetQuick (&vid_vsync, VID_GetVSync() ? "1" : "0");
    }
    
    vid_changed = false;
}

//==========================================================================
//  NEW VIDEO MENU -- johnfitz (порт без изменений)
//==========================================================================

enum {
    VID_OPT_MODE,
    VID_OPT_BPP,
    VID_OPT_REFRESHRATE,
    VID_OPT_FULLSCREEN,
    VID_OPT_VSYNC,
    VID_OPT_TEST,
    VID_OPT_APPLY,
    VIDEO_OPTIONS_ITEMS
};

static int	video_options_cursor = 0;

typedef struct {
    int width,height;
} vid_menu_mode;

static vid_menu_mode vid_menu_modes[MAX_MODE_LIST];
static int vid_menu_nummodes = 0;

static int vid_menu_bpps[MAX_BPPS_LIST];
static int vid_menu_numbpps = 0;

static int vid_menu_rates[MAX_RATES_LIST];
static int vid_menu_numrates=0;

static void VID_Menu_Init (void)
{
    int i, j, h, w;
    
    for (i = 0; i < nummodes; i++)
    {
        w = modelist[i].width;
        h = modelist[i].height;
        
        for (j = 0; j < vid_menu_nummodes; j++)
        {
            if (vid_menu_modes[j].width == w &&
                vid_menu_modes[j].height == h)
                break;
        }
        
        if (j == vid_menu_nummodes)
        {
            vid_menu_modes[j].width = w;
            vid_menu_modes[j].height = h;
            vid_menu_nummodes++;
        }
    }
}

static void VID_Menu_RebuildBppList (void)
{
    int i, j, b;
    
    vid_menu_numbpps = 0;
    
    for (i = 0; i < nummodes; i++)
    {
        if (vid_menu_numbpps >= MAX_BPPS_LIST)
            break;
        
        if (modelist[i].width != vid_width.value ||
            modelist[i].height != vid_height.value)
            continue;
        
        b = modelist[i].bpp;
        
        for (j = 0; j < vid_menu_numbpps; j++)
        {
            if (vid_menu_bpps[j] == b)
                break;
        }
        
        if (j == vid_menu_numbpps)
        {
            vid_menu_bpps[j] = b;
            vid_menu_numbpps++;
        }
    }
    
    if (vid_menu_numbpps == 0)
    {
        Cvar_SetValueQuick (&vid_bpp, (float)modelist[0].bpp);
        return;
    }
    
    for (i = 0; i < vid_menu_numbpps; i++)
        if (vid_menu_bpps[i] == (int)(vid_bpp.value))
            break;
    
    if (i == vid_menu_numbpps)
        Cvar_SetValueQuick (&vid_bpp, (float)vid_menu_bpps[0]);
}

static void VID_Menu_RebuildRateList (void)
{
    int i, j, r;
    
    vid_menu_numrates = 0;
    
    for (i = 0; i < nummodes; i++)
    {
        if (modelist[i].width != vid_width.value ||
            modelist[i].height != vid_height.value ||
            modelist[i].bpp != vid_bpp.value)
            continue;
        
        r = modelist[i].refreshrate;
        
        for (j = 0; j < vid_menu_numrates; j++)
        {
            if (vid_menu_rates[j] == r)
                break;
        }
        
        if (j == vid_menu_numrates)
        {
            vid_menu_rates[j] = r;
            vid_menu_numrates++;
        }
    }
    
    if (vid_menu_numrates == 0)
    {
        Cvar_SetValue ("vid_refreshrate",(float)modelist[0].refreshrate);
        return;
    }
    
    for (i = 0; i < vid_menu_numrates; i++)
        if (vid_menu_rates[i] == (int)(vid_refreshrate.value))
            break;
    
    if (i == vid_menu_numrates)
        Cvar_SetValue ("vid_refreshrate",(float)vid_menu_rates[0]);
}

static void VID_Menu_ChooseNextMode (int dir)
{
    int i;
    
    if (vid_menu_nummodes)
    {
        for (i = 0; i < vid_menu_nummodes; i++)
        {
            if (vid_menu_modes[i].width == vid_width.value &&
                vid_menu_modes[i].height == vid_height.value)
                break;
        }
        
        if (i == vid_menu_nummodes) //can't find it in list, so it must be a custom windowed res
        {
            i = 0;
        }
        else
        {
            i += dir;
            if (i >= vid_menu_nummodes)
                i = 0;
            else if (i < 0)
                i = vid_menu_nummodes-1;
        }
        
        Cvar_SetValueQuick (&vid_width, (float)vid_menu_modes[i].width);
        Cvar_SetValueQuick (&vid_height, (float)vid_menu_modes[i].height);
        VID_Menu_RebuildBppList ();
        VID_Menu_RebuildRateList ();
    }
}

static void VID_Menu_ChooseNextBpp (int dir)
{
    int i;
    
    if (vid_menu_numbpps)
    {
        for (i = 0; i < vid_menu_numbpps; i++)
        {
            if (vid_menu_bpps[i] == vid_bpp.value)
                break;
        }
        
        if (i == vid_menu_numbpps) //can't find it in list
        {
            i = 0;
        }
        else
        {
            i += dir;
            if (i >= vid_menu_numbpps)
                i = 0;
            else if (i < 0)
                i = vid_menu_numbpps-1;
        }
        
        Cvar_SetValueQuick (&vid_bpp, (float)vid_menu_bpps[i]);
    }
}

static void VID_Menu_ChooseNextRate (int dir)
{
    int i;
    
    for (i = 0; i < vid_menu_numrates; i++)
    {
        if (vid_menu_rates[i] == vid_refreshrate.value)
            break;
    }
    
    if (i == vid_menu_numrates) //can't find it in list
    {
        i = 0;
    }
    else
    {
        i += dir;
        if (i >= vid_menu_numrates)
            i = 0;
        else if (i < 0)
            i = vid_menu_numrates-1;
    }
    
    Cvar_SetValue ("vid_refreshrate",(float)vid_menu_rates[i]);
}

static void VID_MenuKey (int key)
{
    switch (key)
    {
        case K_ESCAPE:
        case K_BBUTTON:
            VID_SyncCvars ();
            S_LocalSound ("misc/menu1.wav");
            M_Menu_Options_f ();
            break;
            
        case K_UPARROW:
            S_LocalSound ("misc/menu1.wav");
            video_options_cursor--;
            if (video_options_cursor < 0)
                video_options_cursor = VIDEO_OPTIONS_ITEMS-1;
            break;
            
        case K_DOWNARROW:
            S_LocalSound ("misc/menu1.wav");
            video_options_cursor++;
            if (video_options_cursor >= VIDEO_OPTIONS_ITEMS)
                video_options_cursor = 0;
            break;
            
        case K_LEFTARROW:
            S_LocalSound ("misc/menu3.wav");
            switch (video_options_cursor)
            {
                case VID_OPT_MODE:
                    VID_Menu_ChooseNextMode (1);
                    break;
                case VID_OPT_BPP:
                    VID_Menu_ChooseNextBpp (1);
                    break;
                case VID_OPT_REFRESHRATE:
                    VID_Menu_ChooseNextRate (1);
                    break;
                case VID_OPT_FULLSCREEN:
                    Cbuf_AddText ("toggle vid_fullscreen\n");
                    break;
                case VID_OPT_VSYNC:
                    Cbuf_AddText ("toggle vid_vsync\n");
                    break;
                default:
                    break;
            }
            break;
            
        case K_RIGHTARROW:
            S_LocalSound ("misc/menu3.wav");
            switch (video_options_cursor)
            {
                case VID_OPT_MODE:
                    VID_Menu_ChooseNextMode (-1);
                    break;
                case VID_OPT_BPP:
                    VID_Menu_ChooseNextBpp (-1);
                    break;
                case VID_OPT_REFRESHRATE:
                    VID_Menu_ChooseNextRate (-1);
                    break;
                case VID_OPT_FULLSCREEN:
                    Cbuf_AddText ("toggle vid_fullscreen\n");
                    break;
                case VID_OPT_VSYNC:
                    Cbuf_AddText ("toggle vid_vsync\n");
                    break;
                default:
                    break;
            }
            break;
            
        case K_ENTER:
        case K_KP_ENTER:
        case K_ABUTTON:
            m_entersound = true;
            switch (video_options_cursor)
            {
                case VID_OPT_MODE:
                    VID_Menu_ChooseNextMode (1);
                    break;
                case VID_OPT_BPP:
                    VID_Menu_ChooseNextBpp (1);
                    break;
                case VID_OPT_REFRESHRATE:
                    VID_Menu_ChooseNextRate (1);
                    break;
                case VID_OPT_FULLSCREEN:
                    Cbuf_AddText ("toggle vid_fullscreen\n");
                    break;
                case VID_OPT_VSYNC:
                    Cbuf_AddText ("toggle vid_vsync\n");
                    break;
                case VID_OPT_TEST:
                    Cbuf_AddText ("vid_test\n");
                    break;
                case VID_OPT_APPLY:
                    Cbuf_AddText ("vid_restart\n");
                    key_dest = key_game;
                    m_state = m_none;
                    IN_Activate();
                    break;
                default:
                    break;
            }
            break;
            
        default:
            break;
    }
}

static void VID_MenuDraw (void)
{
    int i, y;
    qpic_t *p;
    const char *title;
    
    y = 4;
    
    // plaque
    p = Draw_CachePic ("gfx/qplaque.lmp");
    M_DrawTransPic (16, y, p);
    
    p = Draw_CachePic ("gfx/p_option.lmp");
    M_DrawPic ( (320-p->width)/2, y, p);
    
    y += 28;
    
    // title
    title = "Video Options";
    M_PrintWhite ((320 - 8 * (int)strlen(title)) / 2, y, title);
    
    y += 16;
    
    // options
    for (i = 0; i < VIDEO_OPTIONS_ITEMS; i++)
    {
        switch (i)
        {
            case VID_OPT_MODE:
                M_Print (16, y, "        Video mode");
                M_Print (184, y, va("%ix%i", (int)vid_width.value, (int)vid_height.value));
                break;
            case VID_OPT_BPP:
                M_Print (16, y, "       Color depth");
                M_Print (184, y, va("%i", (int)vid_bpp.value));
                break;
            case VID_OPT_REFRESHRATE:
                M_Print (16, y, "      Refresh rate");
                M_Print (184, y, va("%i", (int)vid_refreshrate.value));
                break;
            case VID_OPT_FULLSCREEN:
                M_Print (16, y, "        Fullscreen");
                M_DrawCheckbox (184, y, (int)vid_fullscreen.value);
                break;
            case VID_OPT_VSYNC:
                M_Print (16, y, "     Vertical sync");
                if (gl_swap_control)
                    M_DrawCheckbox (184, y, (int)vid_vsync.value);
                else
                    M_Print (184, y, "N/A");
                break;
            case VID_OPT_TEST:
                y += 8; //separate the test and apply items
                M_Print (16, y, "      Test changes");
                break;
            case VID_OPT_APPLY:
                M_Print (16, y, "     Apply changes");
                break;
        }
        
        if (video_options_cursor == i)
            M_DrawCharacter (168, y, 12+((int)(realtime*4)&1));
        
        y += 8;
    }
}

static void VID_Menu_f (void)
{
    IN_Deactivate(modestate == MS_WINDOWED);
    key_dest = key_menu;
    m_state = m_video;
    m_entersound = true;
    
    VID_SyncCvars ();
    
    VID_Menu_RebuildBppList ();
    VID_Menu_RebuildRateList ();
}
