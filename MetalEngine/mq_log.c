//
//  mq_log.c
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Unified logger implementation. See mq_log.h.
//
//  Thread safety: the render loop is single-threaded, so plain
//  static variables are sufficient (minor budget counter race conditions
//  are negligible as they are diagnostic-only).
//

#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#include "mq_log.h"

// ------------------------------------------------------------
// State
// ------------------------------------------------------------

static int          s_profile   = MQ_LOG_DEV; // Default: development / diagnostics
static unsigned int s_frame     = 0;
static long         s_totalLines = 0;
static bool         s_capWarned = false;

#include <time.h>

// Active session file handle
static FILE *s_logFile = NULL;
static char  s_currentLogPath[1024] = {0};

// Tag budget registry
typedef struct {
    const char *tag;
    int remaining;
} mq_budget_entry_t;

#define MQ_MAX_BUDGETS 96
static mq_budget_entry_t s_budgets[MQ_MAX_BUDGETS];
static int s_budgetCount = 0;

// ------------------------------------------------------------
// Public API
// ------------------------------------------------------------

void MLog_SetProfile(int profile)
{
    if (profile < MQ_LOG_RELEASE || profile > MQ_LOG_FULL)
        profile = MQ_LOG_DEV;
    if (s_profile == profile)
        return;
    
    s_profile = profile;
    
    // Profile change is always emitted to the console
    const char *name = (profile == MQ_LOG_RELEASE) ? "RELEASE" :
    (profile == MQ_LOG_FULL)    ? "FULL"    : "DEV";
    char line[128];
    snprintf(line, sizeof(line), "[MQ][LOG] Profile switched to %s\n", name);
    // Emit to stdout (Xcode / Terminal) and disk session file
    fputs(line, stdout);
    if (s_logFile)
        fputs(line, s_logFile);
}

int MLog_GetProfile(void)
{
    return s_profile;
}

void MLog_NextFrame(void)
{
    s_frame++;
}

unsigned int MLog_GetFrame(void)
{
    return s_frame;
}

const char* MLog_InitSession(const char *logsDirectory)
{
    if (s_logFile) {
        fclose(s_logFile);
        s_logFile = NULL;
    }
    
    time_t rawtime;
    time(&rawtime);
    struct tm *timeinfo = localtime(&rawtime);
    
    char filename[128];
    strftime(filename, sizeof(filename), "metalquake_%Y-%m-%d_%H-%M-%S.log", timeinfo);
    snprintf(s_currentLogPath, sizeof(s_currentLogPath), "%s/%s", logsDirectory, filename);
    
    s_logFile = fopen(s_currentLogPath, "w");
    if (s_logFile) {
        // Line-buffered mode: automatically flush to disk on each newline
        setvbuf(s_logFile, NULL, _IOLBF, 0);
        char header[256];
        snprintf(header, sizeof(header), "[MQ][LOG] Session started: %s\n", s_currentLogPath);
        fputs(header, s_logFile);
    }
    return s_currentLogPath;
}

void MLog_CloseSession(void)
{
    if (s_logFile) {
        fputs("[MQ][LOG] Session closed normally.\n", s_logFile);
        fclose(s_logFile);
        s_logFile = NULL;
    }
}

const char* MLog_GetCurrentLogPath(void)
{
    return s_currentLogPath;
}

bool MLog_Budget(const char *tag, int limit)
{
    // Budgets are bypassed in FULL profile
    if (s_profile >= MQ_LOG_FULL)
        return true;
    
    for (int i = 0; i < s_budgetCount; i++) {
        if (strcmp(s_budgets[i].tag, tag) == 0)
            return s_budgets[i].remaining-- > 0;
    }
    
    if (s_budgetCount < MQ_MAX_BUDGETS) {
        s_budgets[s_budgetCount].tag = tag;
        s_budgets[s_budgetCount].remaining = limit - 1;
        s_budgetCount++;
        return true;
    }
    
    // Registry capacity reached — disallow to avoid unmonitored growth
    return false;
}

void MLog(int level, const char *tag, const char *fmt, ...)
{
    // 1. Filter by log level and profile
    bool allowed;
    switch (level) {
        case MQ_LVL_ALWAYS: allowed = true;                       break;
        case MQ_LVL_DEV:    allowed = (s_profile >= MQ_LOG_DEV);  break;
        case MQ_LVL_FULL:   allowed = (s_profile >= MQ_LOG_FULL); break;
        default:            allowed = false;                      break;
    }
    if (!allowed)
        return;
    
    // 2. Global line cap safeguard (does not apply to critical anomalies)
    if (level != MQ_LVL_ALWAYS && s_totalLines >= MQ_LOG_TOTAL_CAP) {
        if (!s_capWarned) {
            s_capWarned = true;
            printf("[MQ][LOG] Total cap %d reached — verbose logging suspended\n", MQ_LOG_TOTAL_CAP);
        }
        return;
    }
    s_totalLines++;
    
    // 3. Format message payload
    char body[900];
    va_list args;
    va_start(args, fmt);
    vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);
    
    // 4. Composite line format: [MQ][F:NNNNNN][TAG] message
    char line[1024];
    snprintf(line, sizeof(line), "[MQ][F:%06u][%-9s] %s\n", s_frame, tag, body);
    
    // 5. Output: stdout and session log file
    fputs(line, stdout);
    if (s_logFile)
        fputs(line, s_logFile);
}

void MLog_WriteString(const char *string)
{
    if (!string)
        return;
    
    fputs(string, stdout);
    if (s_logFile) {
        fputs(string, s_logFile);
    }
}

void Quake_RedirectLog(const char *text)
{
    if (text) {
        MLog_WriteString(text);
    }
}
