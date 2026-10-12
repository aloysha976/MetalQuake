/*
 Copyright (C) 1996-2001 Id Software, Inc.
 Copyright (C) 2002-2005 John Fitzgibbons and others
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

// [MQ-NATIVE] main_macos.m — портирован из main_sdl.c: SDL полностью убран.
// NSApplication уже существует (лаунчер SwiftUI в том же процессе вызывает
// QuakeEngine_Main на главном потоке; режим -engine приходит из App.init).
// События качает IN_SendKeyEvents (nextEventMatchingMask) внутри Host_Frame.

#import <Cocoa/Cocoa.h>
#import <signal.h>
#import <unistd.h>
#import "quakedef.h"

#define DEFAULT_MEMORY (384 * 1024 * 1024) // ericw -- was 72MB (64-bit) / 64MB (32-bit)

static quakeparms_t	parms;

// [FIX Q4] SIGINT/SIGTERM: SDL больше не мапит их на quit — флаг проверяет
// главный цикл (push-событий больше нет).
static volatile sig_atomic_t g_mqSignalQuit = 0;

static void MQ_SignalToQuit (int sig)
{
    (void)sig;
    g_mqSignalQuit = 1;
}

// [MQ-NATIVE] Гарантируем готовность NSApp к нашему event pump.
// Лаунчер: NSApp уже running — ничего не делаем. Режим -engine: NSApp создан,
// но run loop SwiftUI не стартовал — выполняем finishLaunching сами.
static void MQ_InitAppKit (void)
{
    NSApplication *app = [NSApplication sharedApplication];
    if (!app)
        Sys_Error ("Couldn't initialize NSApplication");
    
    if (app.activationPolicy != NSApplicationActivationPolicyRegular)
        app.activationPolicy = NSApplicationActivationPolicyRegular;
    
    if (![NSApp isRunning])
        [app finishLaunching];
}

int QuakeEngine_Main(int argc, char *argv[])
{
    // [FIX LAUNCHER-QUIT] Перехват выхода из игры без убийства лаунчера
    if (setjmp(g_quakeExitJmp) != 0)
    {
        g_quakeEngineRunning = false;
        return 0;
    }
    g_quakeEngineRunning = true;
    int		t;
    double		time, oldtime, newtime;
    double		bootT0 = Sys_DoubleTime (); // [BOOT] стартап-тайминги [H5]
    
    @autoreleasepool {
        
        host_parms = &parms;
        parms.basedir = ".";
        
        parms.argc = argc;
        parms.argv = argv;
        
        parms.errstate = 0;
        
        COM_InitArgv(parms.argc, parms.argv);
        
        isDedicated = (COM_CheckParm("-dedicated") != 0);
        
        signal (SIGINT,  MQ_SignalToQuit); // [FIX Q4]
        signal (SIGTERM, MQ_SignalToQuit); // [FIX Q4]
        
        if (!isDedicated)
            MQ_InitAppKit ();
        
        Sys_Init();
        
        Sys_Printf("Initializing QuakeSpasm v%s\n", QUAKESPASM_VER_STRING);
        Sys_Printf("Platform: macOS native (no SDL)\n");
        
        parms.memsize = DEFAULT_MEMORY;
        if (COM_CheckParm("-heapsize"))
        {
            t = COM_CheckParm("-heapsize") + 1;
            if (t < com_argc)
                parms.memsize = Q_atoi(com_argv[t]) * 1024;
        }
        
        parms.membase = malloc (parms.memsize);
        
        if (!parms.membase)
            Sys_Error ("Not enough memory free; check disk space\n");
        
        Sys_Printf("Host_Init\n");
        Host_Init();
        Sys_Printf("[BOOT] Host_Init done in %.2fs\n", Sys_DoubleTime() - bootT0);
        
        oldtime = Sys_DoubleTime();
        if (isDedicated)
        {
            while (1)
            {
                newtime = Sys_DoubleTime ();
                time = newtime - oldtime;
                
                while (time < sys_ticrate.value )
                {
                    Sys_Sleep(1);
                    newtime = Sys_DoubleTime ();
                    time = newtime - oldtime;
                }
                
                Host_Frame (time);
                oldtime = newtime;
            }
        }
        else
            while (1)
            {
                @autoreleasepool {
                    
                    if (g_mqSignalQuit)
                    {
                        CL_Disconnect ();
                        Sys_Quit ();
                    }
                    
                    /* If we have no input focus at all, sleep a bit */
                    if (!VID_HasMouseOrInputFocus() || cl.paused)
                    {
                        Sys_Sleep(16);
                    }
                    /* If we're minimised, sleep a bit more */
                    if (VID_IsMinimized())
                    {
                        scr_skipupdate = 1;
                        Sys_Sleep(32);
                    }
                    else
                    {
                        scr_skipupdate = 0;
                    }
                    newtime = Sys_DoubleTime ();
                    time = newtime - oldtime;
                    
                    Host_Frame (time);
                    
                    if (time < sys_throttle.value && !cls.timedemo)
                        Sys_Sleep(1);
                    
                    oldtime = newtime;
                    
                } // autoreleasepool
            }
        
        return 0;
        
    } // autoreleasepool
}
