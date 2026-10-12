//
//  mq_log.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//
//  Unified diagnostic logging system for the rendering pipeline.
//  Pure C99 — accessible from QuakeCore (.c), MetalEngine (.m/.mm), and Swift (via bridging header).
//
//  Line format:  [MQ][F:NNNNNN][TAG] message
//

#ifndef R_METAL_LOG_H
#define R_METAL_LOG_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================
// Logging Profiles (switchable from the Swift launcher)
// ============================================================
enum {
    MQ_LOG_RELEASE = 0, // End-user profile: INIT / ERROR / anomalies / EXIT
    MQ_LOG_DEV     = 1, // Diagnostics: rate-limited by per-tag budgets (default)
    MQ_LOG_FULL    = 2  // Verbose: budgets bypassed (global line cap remains active)
};

// Message levels for MLog()
enum {
    MQ_LVL_ALWAYS = 0, // Anomalies and errors: emitted in ANY profile, bypasses budgets
    MQ_LVL_DEV    = 1, // Diagnostics: active under MQ_LOG_DEV and MQ_LOG_FULL
    MQ_LVL_FULL   = 2  // Verbose: emitted only under MQ_LOG_FULL
};

// Global safeguard against unbounded log file growth under the FULL profile
#define MQ_LOG_TOTAL_CAP 200000

// ------------------------------------------------------------
// Profile Management
// ------------------------------------------------------------
void MLog_SetProfile(int profile);
int  MLog_GetProfile(void);

// Frame counter (incremented from R_Metal_BeginFrame)
void MLog_NextFrame(void);
unsigned int MLog_GetFrame(void);

// Tag budget check: returns true while the tag is permitted to log (limit lines per session).
// Budgets are bypassed under MQ_LOG_FULL. Anomalies (MQ_LVL_ALWAYS) bypass budgets unconditionally.
bool MLog_Budget(const char *tag, int limit);

// Main logging entry point
void MLog(int level, const char *tag, const char *fmt, ...)

#if defined(__GNUC__)
__attribute__((format(printf, 3, 4)))
#endif
;

// Session log file lifecycle management
const char* MLog_InitSession(const char *logsDirectory);
void        MLog_CloseSession(void);
void MLog_WriteString(const char *string);
const char* MLog_GetCurrentLogPath(void);
// Redirects legacy Quake output streams (Con_Printf / Sys_Printf)
void Quake_RedirectLog(const char *text);

#ifdef __cplusplus
}
#endif

#endif /* R_METAL_LOG_H */
