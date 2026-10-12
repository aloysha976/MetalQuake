//
//  MetalQuake-Bridging-Header.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#ifndef MetalQuake_Bridging_Header_h
#define MetalQuake_Bridging_Header_h

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// Entry point for the underlying C engine runtime
int QuakeEngine_Main(int argc, char **argv);

// Log session file lifecycle management
const char* MLog_InitSession(const char *logsDirectory);
void        MLog_CloseSession(void);
void MLog_WriteString(const char *string);
const char* MLog_GetCurrentLogPath(void);

// Logging profile configuration (0 = Release, 1 = Dev, 2 = Full)
void MLog_SetProfile(int profile);
int  MLog_GetProfile(void);

#ifdef __cplusplus
}
#endif

#endif /* MetalQuake_Bridging_Header_h */
