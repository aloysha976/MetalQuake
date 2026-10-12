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
 Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 
 */
// gl_vidsdl.c -- SDL GL vid component

#include "quakedef.h"
#include "cfgfile.h"
#include "bgmusic.h"
#include "resource.h"
#include "MetalBridge.h"
#include "r_metal_log.h"	// [E5] DISPMAP-диагностика дисплеев

#if defined(SDL_FRAMEWORK) || defined(NO_SDL_CONFIG)
#if defined(USE_SDL2)
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#else
#include <SDL/SDL.h>
#endif
#else
#include "SDL.h"
#include "SDL_metal.h"
#endif

#define MAX_MODE_LIST    600 //johnfitz -- was 30
#define MAX_BPPS_LIST	5
#define MAX_RATES_LIST	20
#define WARP_WIDTH		320
#define WARP_HEIGHT		200
#define MAXWIDTH		10000
#define MAXHEIGHT		10000

#define DEFAULT_SDL_FLAGS	SDL_OPENGL

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
static int gl_version_major;
static int gl_version_minor;
static const char *gl_extensions;

static vmode_t	modelist[MAX_MODE_LIST];
static int		nummodes;

static qboolean	vid_initialized = false;

#if defined(USE_SDL2)
static SDL_Window	*draw_context;
static SDL_GLContext	gl_context;
#else
static SDL_Surface	*draw_context;
#endif

static qboolean	vid_locked = false; //johnfitz
static qboolean	vid_changed = false;

static void VID_Menu_Init (void); //johnfitz
static void VID_Menu_f (void); //johnfitz
static void VID_MenuDraw (void);
static void VID_MenuKey (int key);

static void ClearAllStates (void);
static void GL_Init (void);
static void GL_SetupState (void); //johnfitz

viddef_t	vid;				// global video state
modestate_t	modestate = MS_UNINIT;
qboolean	scr_skipupdate;

qboolean gl_mtexable = false;
qboolean gl_packed_pixels = false;
qboolean gl_texture_env_combine = false; //johnfitz
qboolean gl_texture_env_add = false; //johnfitz
qboolean gl_swap_control = false; //johnfitz
qboolean gl_anisotropy_able = false; //johnfitz
float gl_max_anisotropy; //johnfitz
qboolean gl_texture_NPOT = false; //ericw
qboolean gl_vbo_able = false; //ericw
qboolean gl_glsl_able = false; //ericw
GLint gl_max_texture_units = 0; //ericw
qboolean gl_glsl_gamma_able = false; //ericw
qboolean gl_glsl_alias_able = false; //ericw
int gl_stencilbits;

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
static cvar_t	vid_fullscreen = {"vid_fullscreen", "0", CVAR_ARCHIVE};	// QuakeSpasm, was "1"
static cvar_t	vid_width = {"vid_width", "800", CVAR_ARCHIVE};		// QuakeSpasm, was 640
static cvar_t	vid_height = {"vid_height", "600", CVAR_ARCHIVE};	// QuakeSpasm, was 480
static cvar_t	vid_bpp = {"vid_bpp", "16", CVAR_ARCHIVE};
static cvar_t	vid_refreshrate = {"vid_refreshrate", "60", CVAR_ARCHIVE};
static cvar_t	vid_vsync = {"vid_vsync", "0", CVAR_ARCHIVE};
static cvar_t	vid_fsaa = {"vid_fsaa", "0", CVAR_ARCHIVE}; // QuakeSpasm
static cvar_t	vid_desktopfullscreen = {"vid_desktopfullscreen", "0", CVAR_ARCHIVE}; // QuakeSpasm
static cvar_t	vid_borderless = {"vid_borderless", "0", CVAR_ARCHIVE}; // QuakeSpasm
// [Metal] Стиль фуллскрина: 0 = десктопный (SDL_WINDOW_FULLSCREEN_DESKTOP —
// надёжный, Retina-корректный, дефолт), 1 = эксклюзивный (смена видеорежима)
static cvar_t	vid_fullscreen_style = {"vid_fullscreen_style", "0", CVAR_ARCHIVE};
//johnfitz

// [Metal] Выбранный дисплей (-display N из лаунчера). Раньше индекс 0 был
// захардкожен в перечислении режимов, из-за чего игра всегда открывалась
// на основном мониторе, а режимы второго дисплея не находились вовсе.
static int	g_vidDisplayIndex = 0;
// Лимит кадра Metal: максимальный размер текстуры на всём Apple Silicon.
#define METAL_MAX_TEXTURE_EDGE 16384

cvar_t		vid_gamma = {"gamma", "1", CVAR_ARCHIVE}; //johnfitz -- moved here from view.c
cvar_t		vid_contrast = {"contrast", "1", CVAR_ARCHIVE}; //QuakeSpasm, MarkV

//==========================================================================
//
//  HARDWARE GAMMA -- johnfitz
//
//==========================================================================

static int fsaa;

/*
 ==========================================================================
 
 GAMMA CORRECTION -- [Metal 3 Stubs]
 
 ==========================================================================
 */

static void VID_Gamma_SetGamma (void)
{
    // [Metal 3] Аппаратная гамма SDL упразднена.
    // Гамма и контраст применяются в реальном времени в шейдере тонемаппинга Metal 3 (r_metal_post.m).
}

static void VID_Gamma_Restore (void)
{
    // [Metal 3] Системная гамма дисплея не затрагивается.
}

static void VID_Gamma_Shutdown (void)
{
}

static void VID_Gamma_f (cvar_t *var)
{
    // Изменение значений vid_gamma и vid_contrast автоматически считывается шейдером кадра
    (void)var;
}

static void VID_Gamma_Init (void)
{
    Cvar_RegisterVariable (&vid_gamma);
    Cvar_RegisterVariable (&vid_contrast);
    Cvar_SetCallback (&vid_gamma, VID_Gamma_f);
    Cvar_SetCallback (&vid_contrast, VID_Gamma_f);
}

/*
 ======================
 VID_GetCurrentWidth
 ======================
 */
static int VID_GetCurrentWidth (void)
{
#if defined(USE_SDL2)
    int w = 0, h = 0;
    SDL_GetWindowSize(draw_context, &w, &h);
    return w;
#else
    return draw_context->w;
#endif
}

/*
 =======================
 VID_GetCurrentHeight
 =======================
 */
static int VID_GetCurrentHeight (void)
{
#if defined(USE_SDL2)
    int w = 0, h = 0;
    SDL_GetWindowSize(draw_context, &w, &h);
    return h;
#else
    return draw_context->h;
#endif
}

/*
 ====================
 VID_GetCurrentRefreshRate
 ====================
 */
static int VID_GetCurrentRefreshRate (void)
{
#if defined(USE_SDL2)
    SDL_DisplayMode mode;
    int current_display;
    
    current_display = SDL_GetWindowDisplayIndex(draw_context);
    
    if (0 != SDL_GetCurrentDisplayMode(current_display, &mode))
        return DEFAULT_REFRESHRATE;
    
    return mode.refresh_rate;
#else
    // SDL1.2 doesn't support refresh rates
    return DEFAULT_REFRESHRATE;
#endif
}


/*
 ====================
 VID_GetCurrentBPP
 ====================
 */
static int VID_GetCurrentBPP (void)
{
#if defined(USE_SDL2)
    const Uint32 pixelFormat = SDL_GetWindowPixelFormat(draw_context);
    return SDL_BITSPERPIXEL(pixelFormat);
#else
    return draw_context->format->BitsPerPixel;
#endif
}

/*
 ====================
 VID_GetFullscreen
 
 returns true if we are in regular fullscreen or "desktop fullscren"
 ====================
 */
static qboolean VID_GetFullscreen (void)
{
#if defined(USE_SDL2)
    return (SDL_GetWindowFlags(draw_context) & SDL_WINDOW_FULLSCREEN) != 0;
#else
    return (draw_context->flags & SDL_FULLSCREEN) != 0;
#endif
}

/*
 ====================
 VID_GetDesktopFullscreen
 
 returns true if we are specifically in "desktop fullscreen" mode
 ====================
 */
static qboolean VID_GetDesktopFullscreen (void)
{
#if defined(USE_SDL2)
    return (SDL_GetWindowFlags(draw_context) & SDL_WINDOW_FULLSCREEN_DESKTOP) == SDL_WINDOW_FULLSCREEN_DESKTOP;
#else
    return false;
#endif
}

/*
 ====================
 VID_GetVSync
 ====================
 */
static qboolean VID_GetVSync (void)
{
#if defined(USE_SDL2)
    return SDL_GL_GetSwapInterval() == 1;
#else
    int swap_control;
    if (SDL_GL_GetAttribute(SDL_GL_SWAP_CONTROL, &swap_control) == 0)
        return swap_control > 0;
    return false;
#endif
}

/*
 ====================
 VID_GetWindow
 
 used by pl_win.c
 ====================
 */
void *VID_GetWindow (void)
{
#if defined(USE_SDL2)
    return draw_context;
#else
    return NULL;
#endif
}

/*
 ====================
 VID_HasMouseOrInputFocus
 ====================
 */
qboolean VID_HasMouseOrInputFocus (void)
{
#if defined(USE_SDL2)
    return (SDL_GetWindowFlags(draw_context) & (SDL_WINDOW_MOUSE_FOCUS | SDL_WINDOW_INPUT_FOCUS)) != 0;
#else
    return (SDL_GetAppState() & (SDL_APPMOUSEFOCUS | SDL_APPINPUTFOCUS)) != 0;
#endif
}

/*
 ====================
 VID_IsMinimized
 ====================
 */
qboolean VID_IsMinimized (void)
{
#if defined(USE_SDL2)
    return !(SDL_GetWindowFlags(draw_context) & SDL_WINDOW_SHOWN);
#else
    /* SDL_APPACTIVE in SDL 1.x means "not minimized" */
    return !(SDL_GetAppState() & SDL_APPACTIVE);
#endif
}

#if defined(USE_SDL2)
/*
 ================
 VID_SDL2_GetDisplayMode
 
 Returns a pointer to a statically allocated SDL_DisplayMode structure
 if there is one with the requested params on the default display.
 Otherwise returns NULL.
 
 This is passed to SDL_SetWindowDisplayMode to specify a pixel format
 with the requested bpp. If we didn't care about bpp we could just pass NULL.
 ================
 */
static SDL_DisplayMode *VID_SDL2_GetDisplayMode(int width, int height, int refreshrate, int bpp)
{
    static SDL_DisplayMode mode;
    // [Metal] Ранее дисплей был захардкожен как 0 — режимы второго монитора
    // не находились и движок откатывался на 800x600
    const int sdlmodes = SDL_GetNumDisplayModes(g_vidDisplayIndex);
    int i;
    
    for (i = 0; i < sdlmodes; i++)
    {
        if (SDL_GetDisplayMode(g_vidDisplayIndex, i, &mode) != 0)
            continue;
        
        if (mode.w == width && mode.h == height
            && SDL_BITSPERPIXEL(mode.format) == bpp
            && mode.refresh_rate == refreshrate)
        {
            return &mode;
        }
    }
    
    // [FIX G4] Ослабляем требования: тот же размер без строгого bpp/refresh.
    for (i = 0; i < sdlmodes; i++)
    {
        if (SDL_GetDisplayMode(g_vidDisplayIndex, i, &mode) != 0)
            continue;
        if (mode.w == width && mode.h == height)
        {
            MLog(MQ_LVL_DEV, "VID", "G4: mode %dx%d matched without bpp/refresh "
                 "(%d bpp, %d Hz)", width, height,
                 SDL_BITSPERPIXEL(mode.format), mode.refresh_rate);
            return &mode;
        }
    }
    
    // [FIX G4] Обход HiDPI-фильтра SDL2 (драйвер Cocoa): когда рабочий стол
    // в масштабированном режиме («выглядит как 2560x1440», плотность 2x),
    // SDL НЕ включает в список низкоплотные нативные режимы панели
    // (3840x2160 @1x) — точный поиск их никогда не находит, и переключаемый
    // фуллскрин (стиль 1) умирал на fallback со сменой дисплея.
    // SDL_SetWindowDisplayMode внутри ищет режим через
    // CGDisplayCopyAllDisplayModes независимо от своего списка, поэтому
    // конструируем дескриптор вручную — панель переключится в натив 4K,
    // а при выходе из игры macOS вернёт прежний режим автоматически.
    memset (&mode, 0, sizeof(mode));
    mode.w = width;
    mode.h = height;
    mode.refresh_rate = refreshrate > 0 ? refreshrate : 60;
    mode.format = SDL_PIXELFORMAT_RGB888;
    MLog(MQ_LVL_DEV, "VID", "G4: constructing display mode %dx%d@%d manually "
         "(HiDPI filter hides native low-DPI modes)",
         width, height, mode.refresh_rate);
    return &mode;
}
#endif /* USE_SDL2 */

/*
 ================
 VID_ValidMode_Unchecked -- [D6] тело проверки без диагностики
 ================
 */
static qboolean VID_ValidMode_Unchecked (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
    // ignore width / height / bpp if vid_desktopfullscreen is enabled
    if (fullscreen && vid_desktopfullscreen.value)
        return true;
    
    // [Metal FIX] Десктопный фуллскрин (стиль 0 — наш дефолт) принимает любой
    // разумный размер: SDL рисует в буфер рабочего стола и сам масштабирует.
    // Прежняя жёсткая проверка точной четвёрки w/h/bpp/refresh почти всегда
    // проваливалась на macOS и откатывала запрос лаунчера на 800x600.
    if (fullscreen && vid_fullscreen_style.value < 1.0f)
    {
        SDL_Rect bounds;
        if (SDL_GetDisplayBounds(g_vidDisplayIndex, &bounds) != 0)
            bounds.w = bounds.h = METAL_MAX_TEXTURE_EDGE;
        
        return width >= 320 && height >= 200
        && width <= q_min(METAL_MAX_TEXTURE_EDGE, bounds.w * 2)
        && height <= q_min(METAL_MAX_TEXTURE_EDGE, bounds.h * 2);
    }
    
    if (width < 320)
        return false;
    
    if (height < 200)
        return false;
    
#if defined(USE_SDL2)
    if (fullscreen && VID_SDL2_GetDisplayMode(width, height, refreshrate, bpp) == NULL)
        bpp = 0;
#else
    {
        Uint32 flags = DEFAULT_SDL_FLAGS;
        if (fullscreen)
            flags |= SDL_FULLSCREEN;
        
        bpp = SDL_VideoModeOK(width, height, bpp, flags);
    }
#endif
    
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
 VID_ValidMode -- [D6] обёртка с диагностикой: один лог отвечает, какие
 аргументы пришли на валидацию и какой вердикт — снимает вслепую-отладку
 даунгрейда разрешения (3840x2160 -> config.cfg) за один прогон
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
 ================
 VID_SetMode
 ================
 */
static qboolean VID_SetMode (int width, int height, int refreshrate, int bpp, qboolean fullscreen)
{
    int        temp;
    Uint32    flags;
    char    caption[256];
    int        depthbits, stencilbits;
    int        fsaa_obtained;
#if defined(USE_SDL2)
    int        previous_display;
    qboolean   exclusiveFS;   // [FIX P1] стиль 1 без десктоп-фоллбэка
#endif
    
    // so Con_Printfs don't mess us up by forcing vid and snd updates
    temp = scr_disabled_for_loading;
    scr_disabled_for_loading = true;
    
    CDAudio_Pause ();
    BGM_Pause ();
    
    /* z-buffer depth */
    if (bpp == 16)
    {
        depthbits = 16;
        stencilbits = 0;
    }
    else
    {
        depthbits = 24;
        stencilbits = 8;
    }
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, depthbits);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, stencilbits);
    
    /* fsaa */
    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, fsaa > 0 ? 1 : 0);
    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, fsaa);
    
    // Получаем заголовок и версию из Info.plist проекта через MetalBridge
    R_Metal_GetAppTitle(caption, sizeof(caption));
    
#if defined(USE_SDL2)
    /* Create the window if needed, hidden */
    if (!draw_context)
    {
        // Включаем Metal, масштабируемость (Resizable) и Retina (HighDPI)
        flags = SDL_WINDOW_METAL | SDL_WINDOW_HIDDEN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI;
        
        if (vid_borderless.value)
            flags |= SDL_WINDOW_BORDERLESS;
        
        // [Metal] Окно создаётся на ВЫБРАННОМ дисплее (-display N), а не всегда
        // на основном; раньше стоял безадресный SDL_WINDOWPOS_CENTERED
        //
        // [FIX D2] Размер при создании клампим к ЛОГИЧЕСКИМ границам целевого
        // дисплея: окно 3840x2160 точек в пространстве «выглядит как 2560x1440»
        // физически не помещается, и macOS смещает его на соседний экран
        // (чёрный экран на встроенном до переключения режима).
        {
            SDL_Rect dispBounds;
            int winW = width, winH = height;
            
            if (SDL_GetDisplayBounds(g_vidDisplayIndex, &dispBounds) == 0 &&
                dispBounds.w > 0 && dispBounds.h > 0)
            {
                if (winW > dispBounds.w) winW = dispBounds.w;
                if (winH > dispBounds.h) winH = dispBounds.h;
                MLog(MQ_LVL_DEV, "VID", "D2: create size %dx%d clamped to %dx%d "
                     "(display %d logical %dx%d)",
                     width, height, winW, winH,
                     g_vidDisplayIndex, dispBounds.w, dispBounds.h);
            }
            
            draw_context = SDL_CreateWindow (caption,
                                             SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex),
                                             SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex),
                                             winW, winH, flags);
        }
        if (!draw_context)
            Sys_Error ("Couldn't create SDL2 Metal window");
        
        // [FIX D1] Явная АБСОЛЮТНАЯ привязка к целевому дисплею:
        // SDL_WINDOWPOS_CENTERED_DISPLAY рассчитывается по списку дисплеев SDL
        // и в мультидисплейных конфигурациях периодически даёт окно не на том
        // экране (drawable с Retina-масштабом чужого монитора в логе f1).
        {
            SDL_Rect b;
            int ww = 0, wh = 0, placed = -1;
            
            SDL_GetWindowSize(draw_context, &ww, &wh);
            if (SDL_GetDisplayBounds(g_vidDisplayIndex, &b) == 0)
                SDL_SetWindowPosition(draw_context,
                                      b.x + (b.w - ww) / 2,
                                      b.y + (b.h - wh) / 2);
            
            placed = SDL_GetWindowDisplayIndex(draw_context);
            if (placed != g_vidDisplayIndex)
            {
                // Промах размещения = корень чёрного экрана на чужом дисплее:
                // повтор через позиентинг SDL и диагностика уровня ALWAYS
                SDL_RaiseWindow(draw_context);
                SDL_SetWindowPosition(draw_context,
                                      SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex),
                                      SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex));
                placed = SDL_GetWindowDisplayIndex(draw_context);
            }
            
            MLog(placed == g_vidDisplayIndex ? MQ_LVL_DEV : MQ_LVL_ALWAYS, "VID",
                 "D1: window placed on display %d (target %d)", placed, g_vidDisplayIndex);
        }
        
        // Включаем зеленую кнопку (Spaces Fullscreen) через нативный Cocoa NSWindow
        R_Metal_ConfigureNativeWindow(draw_context, caption);
        
        previous_display = -1;
    }
    else
    {
        previous_display = SDL_GetWindowDisplayIndex(draw_context);
    }
    
    /* Ensure the window is not fullscreen */
    if (VID_GetFullscreen ())
    {
        if (SDL_SetWindowFullscreen (draw_context, 0) != 0)
            Sys_Error("Couldn't set fullscreen state mode");
    }
    
    // [FIX P1] Эксклюзивный фуллскрин: геометрию окна задаёт ОС после захвата
    // дисплея. SetWindowSize запрошенным размером ДО захвата раздувал окно
    // в точках поверх логического пространства масштабированного режима —
    // macOS вытесняла не помещающееся окно на встроенный экран (чёрный экран
    // + звук при холодном старте, окно приходилось убивать процессом)
    //
    // [FIX F-C] Эксклюзив разрешаем ТОЛЬКО если точный режим физически есть
    // в списке дисплея: запрос «4K при рабочем 2560x1440» раньше принимался
    // релаксацией, клэмпился SDL'ем и рушил переход в чёрный экран.
    exclusiveFS = fullscreen &&
    vid_fullscreen_style.value >= 1.0f &&
    !vid_desktopfullscreen.value;
    
    if (exclusiveFS &&
        VID_SDL2_GetDisplayMode (width, height, refreshrate, bpp) == NULL)
    {
        MLog(MQ_LVL_ALWAYS, "VID",
             "F-C: exclusive %dx%d@%d недоступен на дисплее %d — "
             "автооткат в десктопный фуллскрин",
             width, height, refreshrate, g_vidDisplayIndex);
        exclusiveFS = false;
    }
    
    /* Set window size and display mode */
    if (!exclusiveFS)
        SDL_SetWindowSize (draw_context, width, height);
    if (previous_display >= 0)
        SDL_SetWindowPosition (draw_context, SDL_WINDOWPOS_CENTERED_DISPLAY(previous_display), SDL_WINDOWPOS_CENTERED_DISPLAY(previous_display));
    else
        SDL_SetWindowPosition(draw_context, SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex), SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex));
    
    /* [Metal] Эксклюзивный режим требует точного видеорежима; для десктопного
     фуллскрина (дефолт) передача NULL — рабочий стол остаётся нативным */
    /* [FIX D8] Режим дисплея задаём ТОЛЬКО для фуллскрина. Оконному окну
     SDL хранит «режим не задан» и при будущем переходе в фуллскрин берёт
     текущий режим рабочего стола — иначе G4-конструирование фабриковало
     фиктивные режимы и для windowed-запросов (640x480@120 из лога) */
    if (fullscreen && exclusiveFS)
        SDL_SetWindowDisplayMode (draw_context, VID_SDL2_GetDisplayMode(width, height, refreshrate, bpp));
    else
        SDL_SetWindowDisplayMode (draw_context, NULL);
    
    SDL_SetWindowBordered (draw_context, vid_borderless.value ? SDL_FALSE : SDL_TRUE);
    
    /* Make window fullscreen if needed, and show the window */
    if (fullscreen) {
        const Uint32 flag = exclusiveFS ?
        SDL_WINDOW_FULLSCREEN : SDL_WINDOW_FULLSCREEN_DESKTOP;
        if (SDL_SetWindowFullscreen (draw_context, flag) != 0)
        {
            // [FIX G4] Эксклюзивный режим не взят (режим отвергнут системой) —
            // деградируем в десктопный фуллскрин вместо смерти движка
            MLog(MQ_LVL_ALWAYS, "VID", "G4: exclusive fullscreen rejected (%s) — "
                 "falling back to desktop fullscreen", SDL_GetError ());
            if (SDL_SetWindowFullscreen (draw_context, SDL_WINDOW_FULLSCREEN_DESKTOP) != 0)
                Sys_Error ("Couldn't set fullscreen state mode");
        }
    }
    
    // [FIX P2] Верификация дисплея окна после входа в фуллскрин: гонки
    // компоновщика экранов на холодном старте могли смещать окно на другой
    // дисплей. Ограниченная коррекция (максимум 2 попытки): выход из FS ->
    // повторная привязка к целевому -> повторный вход. Каждая попытка — лог.
    if (fullscreen)
    {
        int attempt;
        
        for (attempt = 0; attempt < 2; attempt++)
        {
            int actual = SDL_GetWindowDisplayIndex (draw_context);
            if (actual == g_vidDisplayIndex)
                break;
            
            MLog(MQ_LVL_ALWAYS, "VID",
                 "P2: window on display %d, target %d — correcting (attempt %d)",
                 actual, g_vidDisplayIndex, attempt + 1);
            
            SDL_SetWindowFullscreen (draw_context, 0);
            SDL_SetWindowPosition (draw_context,
                                   SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex),
                                   SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex));
            
            {
                const Uint32 retryFlag = exclusiveFS ?
                SDL_WINDOW_FULLSCREEN : SDL_WINDOW_FULLSCREEN_DESKTOP;
                if (SDL_SetWindowFullscreen (draw_context, retryFlag) != 0)
                    break; // не смогли вернуть фуллскрин — выходим без зацикливания
            }        }
        
        {
            int finalDisp = SDL_GetWindowDisplayIndex (draw_context);
            MLog(finalDisp == g_vidDisplayIndex ? MQ_LVL_DEV : MQ_LVL_ALWAYS, "VID",
                 "P2: fullscreen display settled on %d (target %d)",
                 finalDisp, g_vidDisplayIndex);
        }
    }
    
    SDL_ShowWindow (draw_context);
    SDL_RaiseWindow (draw_context);
    // [FIX G5/D2] Повторная привязка ТОЛЬКО вне эксклюзивного фуллскрина:
    // в стиле 1 геометрией владеет ОС после захвата дисплея, явный
    // SetWindowPosition по захваченному окну ломает состояние SDL
    if (!fullscreen || !exclusiveFS)
        SDL_SetWindowPosition (draw_context,
                               SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex),
                               SDL_WINDOWPOS_CENTERED_DISPLAY(g_vidDisplayIndex));
    // [FIX E2] Активируем приложение и окно: без этого после orderOut лаунчера
    // окно на ВНЕШНЕМ дисплее не становится key и ввод полностью мёртв
    R_Metal_ActivateGameWindow ();
    
    /* Create Metal context wrapper */
    if (!gl_context) {
        if (!draw_context) {
            Sys_Error ("Metal_Init: Couldn't acquire SDL window handle for Metal layer");
        }
        
        // Привязываем CAMetalLayer к окну SDL
        R_Metal_AttachToWindow(draw_context);
        
        gl_context = (SDL_GLContext)1;
        Con_SafePrintf ("Metal 3 rendering context attached to SDL_Window successfully.\n");
        
        TexMgr_ReloadImages();
    }
    
    gl_swap_control = true;
    if (SDL_GL_SetSwapInterval ((vid_vsync.value) ? 1 : 0) == -1)
        gl_swap_control = false;
    
#else /* !defined(USE_SDL2) */
    
    flags = DEFAULT_SDL_FLAGS;
    if (fullscreen)
        flags |= SDL_FULLSCREEN;
    if (vid_borderless.value)
        flags |= SDL_NOFRAME;
    
    gl_swap_control = true;
    if (SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, (vid_vsync.value) ? 1 : 0) == -1)
        gl_swap_control = false;
    
    bpp = SDL_VideoModeOK(width, height, bpp, flags);
    
    draw_context = SDL_SetVideoMode(width, height, bpp, flags);
    if (!draw_context) {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 0);
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 0);
        draw_context = SDL_SetVideoMode(width, height, bpp, flags);
    }
    if (!draw_context) {
        SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 16);
        draw_context = SDL_SetVideoMode(width, height, bpp, flags);
    }
    if (!draw_context) {
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 0);
        draw_context = SDL_SetVideoMode(width, height, bpp, flags);
        if (!draw_context)
            Sys_Error ("Couldn't set video mode");
    }
    
    SDL_WM_SetCaption(caption, caption);
#endif /* !defined(USE_SDL2) */
    
#if defined(USE_SDL2)
    int drawW = 0, drawH = 0;
    SDL_Metal_GetDrawableSize(draw_context, &drawW, &drawH);
    if (drawW > 0 && drawH > 0) {
        vid.width = drawW;
        vid.height = drawH;
    } else {
        vid.width = VID_GetCurrentWidth();
        vid.height = VID_GetCurrentHeight();
    }
#else
    vid.width = VID_GetCurrentWidth();
    vid.height = VID_GetCurrentHeight();
#endif
    
    vid.conwidth = vid.width & 0xFFFFFFF8;
    vid.conheight = vid.conwidth * vid.height / vid.width;
    vid.numpages = 2;
    
    // read the obtained z-buffer depth
    if (SDL_GL_GetAttribute(SDL_GL_DEPTH_SIZE, &depthbits) == -1)
        depthbits = 0;
    
    // read obtained fsaa samples
    if (SDL_GL_GetAttribute(SDL_GL_MULTISAMPLESAMPLES, &fsaa_obtained) == -1)
        fsaa_obtained = 0;
    
    // read stencil bits
    if (SDL_GL_GetAttribute(SDL_GL_STENCIL_SIZE, &gl_stencilbits) == -1)
        gl_stencilbits = 0;
    
    modestate = VID_GetFullscreen() ? MS_FULLSCREEN : MS_WINDOWED;
    
    CDAudio_Resume ();
    BGM_Resume ();
    scr_disabled_for_loading = temp;
    
    ClearAllStates ();
    
    // [FIX D7] Легаси-принт вводил в заблуждение (показывал размер ОКНА
    // до фуллскрина и десктопный рефреш как «режим»). Реальный render-target
    // и drawable видны в [INIT] "Render target forced…" и [GFX·FRAME] G3.
    Con_DPrintf ("legacy: video mode %dx%dx%d %dHz (%d-bit z-buffer, %dx FSAA) initialized\n",
                 VID_GetCurrentWidth(),
                 VID_GetCurrentHeight(),
                 VID_GetCurrentBPP(),
                 VID_GetCurrentRefreshRate(),
                 depthbits,
                 fsaa_obtained);
    
    vid.recalc_refdef = 1;
    vid_changed = false;
    
    return true;
}

/*
 ===================
 VID_Changed_f -- kristian -- notify us that a value has changed that requires a vid_restart
 ===================
 */
static void VID_Changed_f (cvar_t *var)
{
    vid_changed = true;
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
    
    //
    // validate new mode
    //
    if (!VID_ValidMode (width, height, refreshrate, bpp, fullscreen))
    {
        Con_Printf ("%dx%dx%d %dHz %s is not a valid mode\n",
                    width, height, bpp, refreshrate, fullscreen? "fullscreen" : "windowed");
        return;
    }
    
    // ericw -- OS X, SDL1: textures, VBO's invalid after mode change
    //          OS X, SDL2: still valid after mode change
    // To handle both cases, delete all GL objects (textures, VBO, GLSL) now.
    // We must not interleave deleting the old objects with creating new ones, because
    // one of the new objects could be given the same ID as an invalid handle
    // which is later deleted.
    
    TexMgr_DeleteTextureObjects ();
    GLSLGamma_DeleteTexture ();
    R_ScaleView_DeleteTexture ();
    R_DeleteShaders ();
    GL_DeleteBModelVertexBuffer ();
    GLMesh_DeleteVertexBuffers ();
    
    //
    // set new mode
    //
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
    // [Metal] Единый расчёт: авто-масштаб по референсу 320x200 (0 = авто)
    SCR_UpdateConwidth (vid.width, vid.height);
    //
    // keep cvars in line with actual mode
    //
    VID_SyncCvars();
    //
    // update mouse grab
    //
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
    //
    // now try the switch
    //
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
 
 Subsequent changes to vid_* mode settings, and vid_restart commands, will
 be ignored until the "vid_unlock" command is run.
 
 Used when changing gamedirs so the current settings override what was saved
 in the config.cfg.
 ================
 */
void VID_Lock (void)
{
    vid_locked = true;
}

//==============================================================================
//
//	OPENGL STUFF
//
//==============================================================================

/*
 ===============
 GL_Info_f -- [Metal 3]
 ===============
 */
static void GL_Info_f (void)
{
    Con_SafePrintf ("GRAPHICS_BACKEND: Metal 3 (Apple Silicon)\n");
    Con_SafePrintf ("DEVICE: %s\n", gl_renderer);
    Con_SafePrintf ("VERSION: %s\n", gl_version);
    Con_Printf ("EXTENSIONS: MetalRT, Bindless, TileShading, SIMD-Wave, HDR-EDR\n");
}

/*
 ===============
 GL_SetupState -- johnfitz
 
 does all the stuff from GL_Init that needs to be done every time a new GL render context is created
 ===============
 */
static void GL_SetupState (void)
{
    // Заглушка: настройки стейта теперь выполняются внутри Metal 3
}

/*
 ===============
 GL_Init
 ===============
 */
static void GL_Init (void)
{
    gl_vendor = "Apple";
    gl_renderer = "Apple Silicon Metal 3 Engine";
    gl_version = "2.1 Metal Wrapper";
    gl_extensions = "";
    
    Con_SafePrintf ("GL_VENDOR: %s\n", gl_vendor);
    Con_SafePrintf ("GL_RENDERER: %s\n", gl_renderer);
    Con_SafePrintf ("GL_VERSION: %s\n", gl_version);
    
    GL_ClearBufferBindings ();
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
        VID_Gamma_Shutdown (); //johnfitz
#if defined(USE_SDL2)
        // [Metal] Не вызываем SDL_GL_DeleteContext, так как gl_context был фейковым указателем
        gl_context = NULL;
        
        if (draw_context)
        {
            // [FIX G4] Гарантированный выход из фуллскрина ДО уничтожения окна:
            // macOS вернёт панели прежний видеорежим (страховка к автоматике —
            // лаунчер в том же процессе не должен остаться в 4K)
            SDL_SetWindowFullscreen (draw_context, 0);
            SDL_DestroyWindow(draw_context);
            draw_context = NULL;
        }
#endif
        SDL_QuitSubSystem(SDL_INIT_VIDEO);
        PL_VID_Shutdown();
    }
}

/*
 ===================================================================
 
 MAIN WINDOW
 
 ===================================================================
 */

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
//
//  COMMANDS
//
//==========================================================================

/*
 =================
 VID_DescribeCurrentMode_f
 =================
 */
static void VID_DescribeCurrentMode_f (void)
{
    if (draw_context)
        Con_Printf("%dx%dx%d %dHz %s\n",
                   VID_GetCurrentWidth(),
                   VID_GetCurrentHeight(),
                   VID_GetCurrentBPP(),
                   VID_GetCurrentRefreshRate(),
                   VID_GetFullscreen() ? "fullscreen" : "windowed");
}

/*
 =================
 VID_DescribeModes_f -- johnfitz -- changed formatting, and added refresh rates after each mode.
 =================
 */
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

/*
 ===================
 VID_FSAA_f -- ericw -- warn that vid_fsaa requires engine restart
 ===================
 */
static void VID_FSAA_f (cvar_t *var)
{
    // don't print the warning if vid_fsaa is set during startup
    if (vid_initialized)
        Con_Printf("%s %d requires engine restart to take effect\n", var->name, (int)var->value);
}

//==========================================================================
//
//  INIT
//
//==========================================================================

/*
 =================
 VID_InitModelist
 =================
 */
static void VID_InitModelist (void)
{
#if defined(USE_SDL2)
    // [Metal] Режимы перечисляем на ВЫБРАННОМ дисплее, а не только на основном
    const int sdlmodes = SDL_GetNumDisplayModes(g_vidDisplayIndex);
    int i;
    
    nummodes = 0;
    for (i = 0; i < sdlmodes; i++)
    {
        SDL_DisplayMode mode;
        
        if (nummodes >= MAX_MODE_LIST)
            break;
        if (SDL_GetDisplayMode(g_vidDisplayIndex, i, &mode) == 0)
        {
            modelist[nummodes].width = mode.w;
            modelist[nummodes].height = mode.h;
            modelist[nummodes].bpp = SDL_BITSPERPIXEL(mode.format);
            modelist[nummodes].refreshrate = mode.refresh_rate;
            nummodes++;
        }
    }
#else /* !defined(USE_SDL2) */
    SDL_PixelFormat	format;
    SDL_Rect	**modes;
    Uint32		flags;
    int		i, j, k, originalnummodes, existingmode;
    int		bpps[] = {16, 24, 32}; // enumerate >8 bpp modes
    
    originalnummodes = nummodes = 0;
    memset(&format, 0, sizeof(format));
    
    // enumerate fullscreen modes
    flags = DEFAULT_SDL_FLAGS | SDL_FULLSCREEN;
    for (i = 0; i < (int)Q_COUNTOF(bpps); i++)
    {
        if (nummodes >= MAX_MODE_LIST)
            break;
        
        format.BitsPerPixel = bpps[i];
        modes = SDL_ListModes(&format, flags);
        
        if (modes == (SDL_Rect **)0 || modes == (SDL_Rect **)-1)
            continue;
        
        for (j = 0; modes[j]; j++)
        {
            if (modes[j]->w > MAXWIDTH || modes[j]->h > MAXHEIGHT || nummodes >= MAX_MODE_LIST)
                continue;
            
            modelist[nummodes].width = modes[j]->w;
            modelist[nummodes].height = modes[j]->h;
            modelist[nummodes].bpp = bpps[i];
            modelist[nummodes].refreshrate = DEFAULT_REFRESHRATE;
            
            for (k=originalnummodes, existingmode = 0 ; k < nummodes ; k++)
            {
                if ((modelist[nummodes].width == modelist[k].width)   &&
                    (modelist[nummodes].height == modelist[k].height) &&
                    (modelist[nummodes].bpp == modelist[k].bpp))
                {
                    existingmode = 1;
                    break;
                }
            }
            
            if (!existingmode)
            {
                nummodes++;
            }
        }
    }
    
    if (nummodes == originalnummodes)
        Con_SafePrintf ("No fullscreen DIB modes found\n");
#endif /* !defined(USE_SDL2) */
}

/*
 ===================
 VID_Init
 ===================
 */
void	VID_Init (void)
{
    static char vid_center[] = "SDL_VIDEO_CENTERED=center";
    int		p, width, height, refreshrate, bpp;
    int		display_width, display_height, display_refreshrate, display_bpp;
    qboolean	fullscreen;
    const char	*read_vars[] = { "vid_fullscreen",
        "vid_width",
        "vid_height",
        "vid_refreshrate",
        "vid_bpp",
        "vid_vsync",
        "vid_fsaa",
        "vid_desktopfullscreen",
        "vid_borderless",
        "vid_fullscreen_style"}; // [FIX F2] +стиль фуллскрина: лаунчер должен бить старый config.cfg
#define num_readvars	Q_COUNTOF(read_vars)
    
    Cvar_RegisterVariable (&vid_fullscreen); //johnfitz
    Cvar_RegisterVariable (&vid_width); //johnfitz
    Cvar_RegisterVariable (&vid_height); //johnfitz
    Cvar_RegisterVariable (&vid_refreshrate); //johnfitz
    Cvar_RegisterVariable (&vid_bpp); //johnfitz
    Cvar_RegisterVariable (&vid_vsync); //johnfitz
    Cvar_RegisterVariable (&vid_fsaa); //QuakeSpasm
    Cvar_RegisterVariable (&vid_desktopfullscreen); //QuakeSpasm
    Cvar_RegisterVariable (&vid_borderless); //QuakeSpasm
    Cvar_RegisterVariable (&vid_fullscreen_style); // [Metal] 0=desktop (дефолт), 1=exclusive
    Cvar_SetCallback (&vid_fullscreen, VID_Changed_f);
    Cvar_SetCallback (&vid_width, VID_Changed_f);
    Cvar_SetCallback (&vid_height, VID_Changed_f);
    Cvar_SetCallback (&vid_refreshrate, VID_Changed_f);
    Cvar_SetCallback (&vid_bpp, VID_Changed_f);
    Cvar_SetCallback (&vid_vsync, VID_Changed_f);
    Cvar_SetCallback (&vid_fsaa, VID_FSAA_f);
    Cvar_SetCallback (&vid_desktopfullscreen, VID_Changed_f);
    Cvar_SetCallback (&vid_borderless, VID_Changed_f);
    
    Cmd_AddCommand ("vid_unlock", VID_Unlock); //johnfitz
    Cmd_AddCommand ("vid_restart", VID_Restart); //johnfitz
    Cmd_AddCommand ("vid_test", VID_Test); //johnfitz
    Cmd_AddCommand ("vid_describecurrentmode", VID_DescribeCurrentMode_f);
    Cmd_AddCommand ("vid_describemodes", VID_DescribeModes_f);
    
    putenv (vid_center);	/* SDL_putenv is problematic in versions <= 1.2.9 */
    
    if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0)
        Sys_Error("Couldn't init SDL video: %s", SDL_GetError());
    
    // [FIX G4b] Парсим -display ДО чтения десктопного режима: раньше
    // display_width/height всегда брались с дисплея 0 (встроенного),
    // что сбивало дефолтные параметры и fallback при старте на внешнем мониторе
    p = COM_CheckParm("-display");
    if (p && p < com_argc-1)
        g_vidDisplayIndex = CLAMP(0, Q_atoi(com_argv[p+1]), SDL_GetNumVideoDisplays()-1);
    
    // [FIX F-B «как в RE7»] Рендер-таргет (-renderw/-renderh) от лаунчера:
    // в фуллскрине окно занимает весь выбранный дисплей в его СИСТЕМНОМ
    // режиме, а выбранное разрешение становится размером Metal-drawable —
    // композитор сам масштабирует на вывод (Apple: «Managing your game
    // window for Metal»). 0 = следовать за размером дисплея/окна.
    p = COM_CheckParm("-renderw");
    if (p && p < com_argc-1)
    {
        int rw = Q_atoi(com_argv[p+1]);
        int rh = 0;
        p = COM_CheckParm("-renderh");
        if (p && p < com_argc-1)
            rh = Q_atoi(com_argv[p+1]);
        if (rw > 0 && rh > 0)
            R_Metal_SetRenderTargetSize(rw, rh);
    }
    
#if defined(USE_SDL2)
    {
        SDL_DisplayMode mode;
        // [FIX G4b] Десктопный режим ЦЕЛЕВОГО дисплея, а не дисплея 0
        if (SDL_GetDesktopDisplayMode(g_vidDisplayIndex, &mode) != 0)
            Sys_Error("Could not get desktop display mode");
        
        display_width = mode.w;
        display_height = mode.h;
        display_refreshrate = mode.refresh_rate;
        display_bpp = SDL_BITSPERPIXEL(mode.format);
    }
#else
    {
        const SDL_VideoInfo *info = SDL_GetVideoInfo();
        display_width = info->current_w;
        display_height = info->current_h;
        display_refreshrate = DEFAULT_REFRESHRATE;
        display_bpp = info->vfmt->BitsPerPixel;
    }
#endif
    
    Cvar_SetValueQuick (&vid_bpp, (float)display_bpp);
    
    if (CFG_OpenConfig("config.cfg") == 0)
    {
        CFG_ReadCvars(read_vars, num_readvars);
        CFG_CloseConfig();
    }
    CFG_ReadCvarOverrides(read_vars, num_readvars);
    
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
        // [FIX G4b] -display уже распарсен выше (до чтения десктопного режима)
        // Выбранный дисплей из лаунчера (пикер мониторов)
        // [E5] Карта SDL-дисплеев: сверить с "[Display] Найдено мониторов…"
        // из лаунчера — порядок должен совпасть (гипотеза M1 о рассинхроне)
        {
            int nd = SDL_GetNumVideoDisplays();
            for (int i = 0; i < nd; i++) {
                SDL_Rect b;
                SDL_GetDisplayBounds(i, &b);
                MLog(MQ_LVL_ALWAYS, "DISPMAP", "SDL[%d] '%s' bounds=(%d,%d %dx%d)",
                     i, SDL_GetDisplayName(i), b.x, b.y, b.w, b.h);
            }
            MLog(MQ_LVL_ALWAYS, "DISPMAP", "selected -display = %d", g_vidDisplayIndex);
        }
        
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
            fullscreen = false;
        else if (COM_CheckParm("-fullscreen") || COM_CheckParm("-f"))
            fullscreen = true;
    }
    
    p = COM_CheckParm ("-fsaa");
    if (p && p < com_argc-1)
        fsaa = atoi(com_argv[p+1]);
    
    // [FIX D7] Десктопный фуллскрин (стиль 0): окно всегда размером
    // ЦЕЛЕВОГО дисплея. Архивные vid_width/vid_height/vid_refreshrate —
    // мусор от прошлых запусков на других дисплеях (кейс: 960x540 в
    // config.cfg после ночных прогонов уезжал окном на LG 4K).
    // -renderw/-renderh остаётся render-target'ом и на окно не влияет.
    // Эксклюзивный стиль 1 сохраняет выбор режима пользователем.
    if (fullscreen && (int)vid_fullscreen_style.value == 0)
    {
        MLog(MQ_LVL_ALWAYS, "VID",
             "D7: desktop FS -> window = target display %dx%d@%d "
             "(archived %dx%d@%d ignored)",
             display_width, display_height, display_refreshrate,
             width, height, refreshrate);
        width = display_width;
        height = display_height;
        refreshrate = display_refreshrate;
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
    
#if !defined(USE_SDL2)
    // set window icon
    PL_SetWindowIcon();
#endif
    
    // [D6] Итог всей цепочки переопределений (config -> -width/-height ->
    // fallback'и): одна строка показывает, ЧТО реально ушло в VID_SetMode
    MLog(MQ_LVL_DEV, "VID", "FINAL mode: %dx%d rr=%d bpp=%d fs=%d",
         width, height, refreshrate, bpp, fullscreen ? 1 : 0);
    
    VID_SetMode (width, height, refreshrate, bpp, fullscreen);
    
#if defined(USE_SDL2)
    // set window icon
    PL_SetWindowIcon();
#endif
    
    GL_Init ();
    GL_SetupState ();
    Cmd_AddCommand ("gl_info", GL_Info_f); //johnfitz
    
    //johnfitz -- removed code creating "glquake" subdirectory
    
    vid_menucmdfn = VID_Menu_f; //johnfitz
    vid_menudrawfn = VID_MenuDraw;
    vid_menukeyfn = VID_MenuKey;
    
    VID_Gamma_Init(); //johnfitz
    VID_Menu_Init(); //johnfitz
    
    //QuakeSpasm: current vid settings should override config file settings.
    //so we have to lock the vid mode from now until after all config files are read.
    vid_locked = true;
}

// new proc by S.A., called by alt-return key binding.
void	VID_Toggle (void)
{
    // disabling the fast path completely because SDL_SetWindowFullscreen was changing
    // the window size on SDL2/WinXP and we weren't set up to handle it. --ericw
    //
    // TODO: Clear out the dead code, reinstate the fast path using SDL_SetWindowFullscreen
    // inside VID_SetMode, check window size to fix WinXP issue. This will
    // keep all the mode changing code in one place.
    static qboolean vid_toggle_works = false;
    qboolean toggleWorked;
#if defined(USE_SDL2)
    Uint32 flags = 0;
#endif
    
    S_ClearBuffer ();
    
    if (!vid_toggle_works)
        goto vrestart;
    else if (gl_vbo_able)
    {
        // disabling the fast path because with SDL 1.2 it invalidates VBOs (using them
        // causes a crash, sugesting that the fullscreen toggle created a new GL context,
        // although texture objects remain valid for some reason).
        //
        // SDL2 does promise window resizes / fullscreen changes preserve the GL context,
        // so we could use the fast path with SDL2. --ericw
        vid_toggle_works = false;
        goto vrestart;
    }
    
#if defined(USE_SDL2)
    if (!VID_GetFullscreen()) {
        flags = vid_desktopfullscreen.value ? SDL_WINDOW_FULLSCREEN_DESKTOP : SDL_WINDOW_FULLSCREEN;
    }
    
    toggleWorked = SDL_SetWindowFullscreen(draw_context, flags) == 0;
#else
    toggleWorked = SDL_WM_ToggleFullScreen(draw_context) == 1;
#endif
    
    if (toggleWorked)
    {
        Sbar_Changed ();	// Sbar seems to need refreshing
        
        modestate = VID_GetFullscreen() ? MS_FULLSCREEN : MS_WINDOWED;
        
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
    else
    {
        vid_toggle_works = false;
        Con_DPrintf ("SDL_WM_ToggleFullScreen failed, attempting VID_Restart\n");
    vrestart:
        Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "0" : "1");
        Cbuf_AddText ("vid_restart\n");
    }
}

/*
 ================
 VID_SyncCvars -- johnfitz -- set vid cvars to match current video mode
 ================
 */
void VID_SyncCvars (void)
{
    if (draw_context)
    {
        if (!VID_GetDesktopFullscreen())
        {
            Cvar_SetValueQuick (&vid_width, VID_GetCurrentWidth());
            Cvar_SetValueQuick (&vid_height, VID_GetCurrentHeight());
        }
        Cvar_SetValueQuick (&vid_refreshrate, VID_GetCurrentRefreshRate());
        Cvar_SetValueQuick (&vid_bpp, VID_GetCurrentBPP());
        Cvar_SetQuick (&vid_fullscreen, VID_GetFullscreen() ? "1" : "0");
        // don't sync vid_desktopfullscreen, it's a user preference that
        // should persist even if we are in windowed mode.
        Cvar_SetQuick (&vid_vsync, VID_GetVSync() ? "1" : "0");
    }
    
    vid_changed = false;
}

//==========================================================================
//
//  NEW VIDEO MENU -- johnfitz
//
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

//TODO: replace these fixed-length arrays with hunk_allocated buffers
static vid_menu_mode vid_menu_modes[MAX_MODE_LIST];
static int vid_menu_nummodes = 0;

static int vid_menu_bpps[MAX_BPPS_LIST];
static int vid_menu_numbpps = 0;

static int vid_menu_rates[MAX_RATES_LIST];
static int vid_menu_numrates=0;

/*
 ================
 VID_Menu_Init
 ================
 */
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

/*
 ================
 VID_Menu_RebuildBppList
 
 regenerates bpp list based on current vid_width and vid_height
 ================
 */
static void VID_Menu_RebuildBppList (void)
{
    int i, j, b;
    
    vid_menu_numbpps = 0;
    
    for (i = 0; i < nummodes; i++)
    {
        if (vid_menu_numbpps >= MAX_BPPS_LIST)
            break;
        
        //bpp list is limited to bpps available with current width/height
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
    
    //if there are no valid fullscreen bpps for this width/height, just pick one
    if (vid_menu_numbpps == 0)
    {
        Cvar_SetValueQuick (&vid_bpp, (float)modelist[0].bpp);
        return;
    }
    
    //if vid_bpp is not in the new list, change vid_bpp
    for (i = 0; i < vid_menu_numbpps; i++)
        if (vid_menu_bpps[i] == (int)(vid_bpp.value))
            break;
    
    if (i == vid_menu_numbpps)
        Cvar_SetValueQuick (&vid_bpp, (float)vid_menu_bpps[0]);
}

/*
 ================
 VID_Menu_RebuildRateList
 
 regenerates rate list based on current vid_width, vid_height and vid_bpp
 ================
 */
static void VID_Menu_RebuildRateList (void)
{
    int i, j, r;
    
    vid_menu_numrates = 0;
    
    for (i = 0; i < nummodes; i++)
    {
        //rate list is limited to rates available with current width/height/bpp
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
    
    //if there are no valid fullscreen refreshrates for this width/height, just pick one
    if (vid_menu_numrates == 0)
    {
        Cvar_SetValue ("vid_refreshrate",(float)modelist[0].refreshrate);
        return;
    }
    
    //if vid_refreshrate is not in the new list, change vid_refreshrate
    for (i = 0; i < vid_menu_numrates; i++)
        if (vid_menu_rates[i] == (int)(vid_refreshrate.value))
            break;
    
    if (i == vid_menu_numrates)
        Cvar_SetValue ("vid_refreshrate",(float)vid_menu_rates[0]);
}

/*
 ================
 VID_Menu_ChooseNextMode
 
 chooses next resolution in order, then updates vid_width and
 vid_height cvars, then updates bpp and refreshrate lists
 ================
 */
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

/*
 ================
 VID_Menu_ChooseNextBpp
 
 chooses next bpp in order, then updates vid_bpp cvar
 ================
 */
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

/*
 ================
 VID_Menu_ChooseNextRate
 
 chooses next refresh rate in order, then updates vid_refreshrate cvar
 ================
 */
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

/*
 ================
 VID_MenuKey
 ================
 */
static void VID_MenuKey (int key)
{
    switch (key)
    {
        case K_ESCAPE:
        case K_BBUTTON:
            VID_SyncCvars (); //sync cvars before leaving menu. FIXME: there are other ways to leave menu
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
                    Cbuf_AddText ("toggle vid_vsync\n"); // kristian
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

/*
 ================
 VID_MenuDraw
 ================
 */
static void VID_MenuDraw (void)
{
    int i, y;
    qpic_t *p;
    const char *title;
    
    y = 4;
    
    // plaque
    p = Draw_CachePic ("gfx/qplaque.lmp");
    M_DrawTransPic (16, y, p);
    
    //p = Draw_CachePic ("gfx/vidmodes.lmp");
    p = Draw_CachePic ("gfx/p_option.lmp");
    M_DrawPic ( (320-p->width)/2, y, p);
    
    y += 28;
    
    // title
    title = "Video Options";
    M_PrintWhite ((320-8*strlen(title))/2, y, title);
    
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

/*
 ================
 VID_Menu_f
 ================
 */
static void VID_Menu_f (void)
{
    IN_Deactivate(modestate == MS_WINDOWED);
    key_dest = key_menu;
    m_state = m_video;
    m_entersound = true;
    
    //set all the cvars to match the current mode when entering the menu
    VID_SyncCvars ();
    
    //set up bpp and rate lists based on current cvars
    VID_Menu_RebuildBppList ();
    VID_Menu_RebuildRateList ();
}
