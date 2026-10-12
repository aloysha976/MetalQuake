//
//  gc_achievements.h
//  MetalQuake
//
//  Game Center Achievements: C API layered over GameKit.
//  Modular isolation: can be excluded from the build by swapping gc_achievements.m
//  with gc_achievements_stub.c — engine hooks in QuakeCore continue linking cleanly.
//  Graceful degradation: authentication failures transition to a disabled state where all calls act as no-ops.
//

#ifndef gc_achievements_h
#define gc_achievements_h

#include <stdbool.h>

// Initialization: authenticates GKLocalPlayer (main thread) and loads completed achievements.
// Called once during Host_Init. Failed authentication shifts state to Disabled (all operations become no-ops).
void GC_Init(void);

// Shutdown: releases report queues and teardown GameKit state.
void GC_Shutdown(void);

// Reports achievement progress: achievement identifier and percent complete (0.0 to 100.0).
// Enqueued and flushed following authentication. Duplicate 100% completions are suppressed.
void GC_ReportAchievement(const char *achievementId, float percent);

// Local cache lookup: checks whether achievement has already been unlocked (populated via loadAchievements).
bool GC_Unlocked(const char *achievementId);

// Gameplay event notification hooks:
void GC_NotifyMonsterKill(void);         // Monster kill event (STAT_MONSTERS +1)
void GC_NotifySecret(void);              // Secret discovered (STAT_SECRETS +1)
void GC_NotifyMapStart(const char *map); // SV_SpawnServer: map name without path or extension
void GC_Frame(void);                     // Per-frame evaluation trackers (Host_Frame)
void GC_NotifyTimedemo(double fps);      // Timedemo completion hook (CL_FinishTimeDemo)
void GC_NotifyCheat(const char *cmd);    // Cheat activation hook from Cmd_ExecuteString (god/noclip/give/fly)

#endif /* gc_achievements_h */
