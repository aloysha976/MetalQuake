//
//  gc_achievements_stub.c
//  MetalQuake
//
//  Stub implementation providing identical symbols with empty function bodies.
//  Used in place of gc_achievements.m when Game Center is excluded from the build
//  (remove .m from target, add this file). QuakeCore hooks continue linking cleanly.
//

#include "gc_achievements.h"

void GC_Init(void) {}
void GC_Shutdown(void) {}
void GC_ReportAchievement(const char *achievementId, float percent) { (void)achievementId; (void)percent; }
bool GC_Unlocked(const char *achievementId) { (void)achievementId; return false; }
void GC_NotifyMonsterKill(void) {}
void GC_NotifySecret(void) {}
void GC_NotifyMapStart(const char *map) { (void)map; }
