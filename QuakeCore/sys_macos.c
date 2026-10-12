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

// [MQ-NATIVE] sys_macos.c — портирован из sys_sdl_unix.c: SDL заменён на
// clock_gettime/nanosleep. Файловый слой, basedir, консоль — без изменений.

#include "arch_def.h"
#include "quakedef.h"

#include <sys/types.h>
#include <errno.h>
#include <unistd.h>
#include <libgen.h>	/* dirname() and basename() */
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <time.h>
#ifdef DO_USERDIRS
#include <pwd.h>
#endif

#include <setjmp.h>

// [FIX LAUNCHER-QUIT] Буфер безопасного возврата в лаунчер
jmp_buf g_quakeExitJmp;
qboolean g_quakeEngineRunning = false;

qboolean		isDedicated;
cvar_t		sys_throttle = {"sys_throttle", "0.02", CVAR_ARCHIVE};

#define	MAX_HANDLES		32	/* johnfitz -- was 10 */
static FILE		*sys_handles[MAX_HANDLES];
static qboolean		stdinIsATTY;	/* from ioquake3 source */


static int findhandle (void)
{
    int i;
    
    for (i = 1; i < MAX_HANDLES; i++)
    {
        if (!sys_handles[i])
            return i;
    }
    Sys_Error ("out of handles");
    return -1;
}

long Sys_filelength (FILE *f)
{
    long		pos, end;
    
    pos = ftell (f);
    fseek (f, 0, SEEK_END);
    end = ftell (f);
    fseek (f, pos, SEEK_SET);
    
    return end;
}

int Sys_FileOpenRead (const char *path, int *hndl)
{
    FILE	*f;
    int	i, retval;
    
    i = findhandle ();
    f = fopen(path, "rb");
    
    if (!f)
    {
        *hndl = -1;
        retval = -1;
    }
    else
    {
        sys_handles[i] = f;
        *hndl = i;
        retval = Sys_filelength(f);
    }
    
    return retval;
}

int Sys_FileOpenWrite (const char *path)
{
    FILE	*f;
    int		i;
    
    i = findhandle ();
    f = fopen(path, "wb");
    
    if (!f)
        Sys_Error ("Error opening %s: %s", path, strerror(errno));
    
    sys_handles[i] = f;
    return i;
}

void Sys_FileClose (int handle)
{
    fclose (sys_handles[handle]);
    sys_handles[handle] = NULL;
}

void Sys_FileSeek (int handle, int position)
{
    fseek (sys_handles[handle], position, SEEK_SET);
}

int Sys_FileRead (int handle, void *dest, int count)
{
    return (int)fread (dest, 1, count, sys_handles[handle]);
}

int Sys_FileWrite (int handle, const void *data, int count)
{
    return (int)fwrite (data, 1, count, sys_handles[handle]);
}

int Sys_FileType (const char *path)
{
    struct stat	st;
    
    if (stat(path, &st) != 0)
        return FS_ENT_NONE;
    if (S_ISDIR(st.st_mode))
        return FS_ENT_DIRECTORY;
    if (S_ISREG(st.st_mode))
        return FS_ENT_FILE;
    
    return FS_ENT_NONE;
}

static int Sys_NumCPUs (void)
{
    int numcpus;
    int mib[2];
    size_t len;
    
#if defined(_SC_NPROCESSORS_ONLN)	/* needs >= 10.5 */
    numcpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (numcpus != -1)
        return (numcpus < 1) ? 1 : numcpus;
#endif
    len = sizeof(numcpus);
    mib[0] = CTL_HW;
    mib[1] = HW_AVAILCPU;
    sysctl(mib, 2, &numcpus, &len, NULL, 0);
    if (sysctl(mib, 2, &numcpus, &len, NULL, 0) == -1)
    {
        mib[1] = HW_NCPU;
        if (sysctl(mib, 2, &numcpus, &len, NULL, 0) == -1)
            return 1;
    }
    return (numcpus < 1) ? 1 : numcpus;
}

static char	cwd[MAX_OSPATH];
#ifdef DO_USERDIRS
static char	userdir[MAX_OSPATH];
#define SYS_USERDIR "Library/Application Support/MetalQuake"

static qboolean Sys_GetUserdirArgs (int argc, char **argv, char *dst, size_t dstsize)
{
    int i = 1;
    for (; i < argc - 1; ++i)
    {
        if (strcmp(argv[i], "-userdir") == 0)
        {
            char *p = dst;
            const char * arg = argv[i + 1];
            const int n = (int)strlen(arg);
            if (n < 1) Sys_Error("Bad argument to -userdir");
            if (q_strlcpy(dst, arg, dstsize) >= dstsize)
                Sys_Error ("Insufficient array size for userspace directory");
            if (dst[n - 1] == '/') dst[n - 1] = 0;
            if (*p == '/') p++;
            for (; *p; p++) {
                const char c = *p;
                if (c == '/') {
                    *p = 0;
                    Sys_mkdir (dst);
                    *p = c;
                }
            }
            return true;
        }
    }
    return false;
}

static void Sys_GetUserdir (int argc, char **argv, char *dst, size_t dstsize)
{
    size_t		n;
    const char	*home_dir = NULL;
    struct passwd	*pwent;
    
    if (Sys_GetUserdirArgs(argc, argv, dst, dstsize))
        return;
    
    pwent = getpwuid( getuid() );
    if (pwent == NULL)
        perror("getpwuid");
    else
        home_dir = pwent->pw_dir;
    if (home_dir == NULL)
        home_dir = getenv("HOME");
    if (home_dir == NULL)
        Sys_Error ("Couldn't determine userspace directory");
    
    n = strlen(home_dir) + strlen(SYS_USERDIR) + 50;
    if (n >= dstsize)
        Sys_Error ("Insufficient array size for userspace directory");
    
    q_snprintf (dst, dstsize, "%s/%s", home_dir, SYS_USERDIR);
}
#endif	/* DO_USERDIRS */

static char *OSX_StripAppBundle (char *dir)
{ /* based on the ioquake3 project at icculus.org. */
    static char	osx_path[MAX_OSPATH];
    
    q_strlcpy (osx_path, dir, sizeof(osx_path));
    if (strcmp(basename(osx_path), "MacOS"))
        return dir;
    q_strlcpy (osx_path, dirname(osx_path), sizeof(osx_path));
    if (strcmp(basename(osx_path), "Contents"))
        return dir;
    q_strlcpy (osx_path, dirname(osx_path), sizeof(osx_path));
    if (!strstr(basename(osx_path), ".app"))
        return dir;
    q_strlcpy (osx_path, dirname(osx_path), sizeof(osx_path));
    return osx_path;
}

static void Sys_GetBasedir (char *argv0, char *dst, size_t dstsize)
{
    char	*tmp;
    
    if (realpath(argv0, dst) == NULL)
    {
        perror("realpath");
        if (getcwd(dst, dstsize - 1) == NULL)
            _fail:		Sys_Error ("Couldn't determine current directory");
    }
    else
    {
        /* strip off the binary name */
        if (! (tmp = strdup (dst))) goto _fail;
        q_strlcpy (dst, dirname(tmp), dstsize);
        free (tmp);
    }
    
    tmp = OSX_StripAppBundle(dst);
    if (tmp != dst)
        q_strlcpy (dst, tmp, dstsize);
}

void Sys_Init (void)
{
    const char* term = getenv("TERM");
    stdinIsATTY = isatty(STDIN_FILENO) &&
    !(term && (!strcmp(term, "raw") || !strcmp(term, "dumb")));
    if (!stdinIsATTY)
        Sys_Printf("Terminal input not available.\n");
    
    memset (cwd, 0, sizeof(cwd));
    Sys_GetBasedir(host_parms->argv[0], cwd, sizeof(cwd));
    host_parms->basedir = cwd;
#ifndef DO_USERDIRS
    host_parms->userdir = host_parms->basedir; /* code elsewhere relies on this ! */
#else
    memset (userdir, 0, sizeof(userdir));
    Sys_GetUserdir (host_parms->argc, host_parms->argv, userdir, sizeof(userdir));
    Sys_mkdir (userdir);
    host_parms->userdir = userdir;
#endif
    host_parms->numcpus = Sys_NumCPUs ();
    Sys_Printf("Detected %d CPUs.\n", host_parms->numcpus);
}

void Sys_mkdir (const char *path)
{
    int rc = mkdir (path, 0777);
    if (rc != 0 && errno == EEXIST)
    {
        struct stat st;
        if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
            rc = 0;
    }
    if (rc != 0)
    {
        rc = errno;
        Sys_Error("Unable to create directory %s: %s", path, strerror(rc));
    }
}

static const char errortxt1[] = "\nERROR-OUT BEGIN\n\n";
static const char errortxt2[] = "\nQUAKE ERROR: ";

void Sys_Error (const char *error, ...)
{
    va_list		argptr;
    char		text[1024];
    
    host_parms->errstate++;
    
    va_start (argptr, error);
    q_vsnprintf (text, sizeof(text), error, argptr);
    va_end (argptr);
    
    fputs (errortxt1, stderr);
    Host_Shutdown ();
    fputs (errortxt2, stderr);
    fputs (text, stderr);
    fputs ("\n\n", stderr);
    if (!isDedicated)
        PL_ErrorDialog(text);
    
    exit (1);
}

void Sys_Printf (const char *fmt, ...)
{
    va_list argptr;
    
    va_start(argptr, fmt);
    vprintf(fmt, argptr);
    va_end(argptr);
}

void Sys_Quit (void)
{
    // [FIX Q3] повторный вызов во время шатдауна не должен перезапускать Host_Shutdown
    static qboolean s_already = false;
    if (s_already)
    {
        if (g_quakeEngineRunning)
        {
            s_already = false;
            g_quakeEngineRunning = false;
            longjmp (g_quakeExitJmp, 1);
        }
        exit (0);
    }
    s_already = true;
    
    Host_Shutdown ();
    
    s_already = false;
    
    // [FIX LAUNCHER-QUIT] Вместо убийства процесса отдаем управление назад в Swift-лаунчер
    if (g_quakeEngineRunning)
    {
        g_quakeEngineRunning = false;
        longjmp (g_quakeExitJmp, 1);
    }
    
    exit (0);
}

// [MQ-NATIVE] монотонные часы вместо SDL_GetTicks
double Sys_DoubleTime (void)
{
    struct timespec ts;
    clock_gettime (CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

const char *Sys_ConsoleInput (void)
{
    static qboolean	con_eof = false;
    static char	con_text[256];
    static int	textlen;
    char		c;
    fd_set		set;
    struct timeval	timeout;
    
    if (!stdinIsATTY || con_eof)
        return NULL;
    
    FD_ZERO (&set);
    FD_SET (0, &set);	// stdin
    timeout.tv_sec = 0;
    timeout.tv_usec = 0;
    
    while (select (1, &set, NULL, NULL, &timeout))
    {
        if (read(0, &c, 1) <= 0)
        {
            // Finish processing whatever is already in the
            // buffer (if anything), then stop reading
            con_eof = true;
            c = '\n';
        }
        if (c == '\n' || c == '\r')
        {
            con_text[textlen] = '\0';
            textlen = 0;
            return con_text;
        }
        else if (c == 8)
        {
            if (textlen)
            {
                textlen--;
                con_text[textlen] = '\0';
            }
            continue;
        }
        con_text[textlen] = c;
        textlen++;
        if (textlen < (int) sizeof(con_text))
            con_text[textlen] = '\0';
        else
        {
            // buffer is full
            textlen = 0;
            con_text[0] = '\0';
            Sys_Printf("\nConsole input too long!\n");
            break;
        }
    }
    
    return NULL;
}

// [MQ-NATIVE] nanosleep вместо SDL_Delay
void Sys_Sleep (unsigned long msecs)
{
    struct timespec ts;
    ts.tv_sec = (time_t)(msecs / 1000);
    ts.tv_nsec = (long)((msecs % 1000) * 1000000);
    nanosleep (&ts, NULL);
}

void Sys_SendKeyEvents (void)
{
    IN_Commands();		//ericw -- allow joysticks to add keys so they can be used to confirm SCR_ModalMessage
    IN_SendKeyEvents();
}
