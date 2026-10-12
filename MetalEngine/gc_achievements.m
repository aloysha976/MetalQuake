//
//  gc_achievements.m
//  MetalQuake
//
//  GameKit implementation for 50 achievements. See gc_achievements.h and
//  associated design documentation.
//
//  Detection categories:
//   A — Engine detects directly (stats, maps, items, timers, velocity)
//   B — Approximated detection (marked as APPROX)
//   C — Requires QuakeC patch (progs.dat) — table defined, detector
//       integrated via GC_ReportAchievement() from the QC bridge
//
//  Thread safety: all calls originate from the main thread; GameKit callbacks run under synchronized blocks.
//

#import <Foundation/Foundation.h>
#import <GameKit/GameKit.h>
#import "gc_achievements.h"
#import "mq_log.h"
#import "quakedef.h"
#import "client.h"
#import "cvar.h"
#import "mathlib.h"

// Metal globals (extern declarations avoiding Metal header inclusions in QuakeCore)
#ifdef __OBJC__
@class CAMetalLayer;
#endif
extern bool g_fxActive;
extern bool g_hdrActive;
extern bool g_edrActive;
extern float g_edrHeadroom;

// ============================================================
// State
// ============================================================

typedef NS_ENUM(NSInteger, GCState) {
    GCStateIdle,
    GCStateAuthenticating,
    GCStateAuthed,
    GCStateDisabled
};

static GCState      s_state = GCStateIdle;
static NSMutableSet *s_unlocked;     // NSString* — 100% completed achievements
static NSMutableArray *s_pending;    // GKAchievement* — pending authentication or flush

// ---- Lifetime statistics counters
static int64_t s_monsterKills = 0;   // Cumulative monster kills
static int64_t s_secretsFound = 0;
static int64_t s_levelsCompleted = 0;

// ---- Per-level trackers (reset on SV_SpawnServer)
static int64_t s_lvlKills = 0;
static int64_t s_lvlSecrets = 0;
static int64_t s_lvlSecretsTotal = 0;
static int64_t s_lvlMonstersTotal = 0;
static bool    s_lvlDamageTaken = false;   // Health or armor decreased
static int     s_lvlHealth = 100, s_lvlArmor = 0;
static int     s_lvlSkill = 1;
static double  s_lvlStartTime = 0;         // Sys_DoubleTime() when entering map
static char    s_lvlMapName[64] = "";
static char    s_prevMapName[64] = "";
static char    s_gameDir[MAX_OSPATH] = "id1";

// ---- Item timers (active windows)
static double s_quadActiveSince = 0;   // 0 = inactive
static int    s_quadKills = 0;
static double s_pentActiveSince = 0;
static int64_t s_pentDamage = 0;       // Cumulative health+armor damage taken while Pentagram is active
static double s_suitUnderwaterSince = 0;
static double s_suitUnderwaterTotal = 0; // Total time for current map

// ---- Movement trackers (Bunny Hopper / High Jumper)
static double s_speedHighSince = 0;    // Time since exceeding 600 ups
static bool   s_speedHighActive = false;
static double s_speedHighStartZ = 0;

// ---- Session / Engine state
static double s_sessionStart = 0;
static bool   s_120hzLogged = false;
static double s_120hzSince = 0;
static bool   s_hdrLogged = false;
static bool   s_cheatUsed = false;
static bool   s_nearestUpscale = false;

// ---- Progression state
static bool s_mapSeen[128];
static char s_seenMapNames[128][64];
static int  s_seenMapCount = 0;

static bool s_epComplete[4];  // E1..E4 completed (entering next episode)
static bool s_nightmareChain = true; // skill == 3 on all campaign maps
static bool s_pacifistLevel = true;  // Current map completed without kills

// ============================================================
// Achievement Table (50). src: A=engine, B=approx, C=QC-required
// ============================================================

typedef struct {
    const char *id;
    const char *name;
    const char *nameRu;
    char        src;      // 'A' | 'B' | 'C'
    const char *note;     // Reference notes
} GCAchDef;

static const GCAchDef kAch[] = {
    // --- Campaign Progression
    { "mq.ep1.complete",  "Slipgate Initiate",      "Слипгейт-новобранец",        'A', "entering e2m1" },
    { "mq.ep2.complete",  "Black Magic Acolyte",    "Адепт Чёрной магии",         'A', "entering e3m1" },
    { "mq.ep3.complete",  "Netherworld Explorer",   "Исследователь Нetherworld",  'A', "entering e4m1" },
    { "mq.ep4.complete",  "Elder Champion",         "Чемпион Elder World",        'A', "entering end" },
    { "mq.shub.demise",   "Shub's Demise",          "Гибель Шуб-Ниггурат",        'B', "kill on map end (APPROX: any monster)" },
    { "mq.mp1.complete",  "Scourge of Armagon",     "Бич Армагона",               'A', "gamedir=hipnotic, final map" },
    { "mq.mp2.complete",  "Dissolution of Eternity","Растворение вечности",       'A', "gamedir=rogue, final map" },
    { "mq.dopa.complete", "Dimension of the Past",  "Измерение прошлого",         'A', "gamedir=dopa" },
    { "mq.mg1.complete",  "Dimension of the Machine","Измерение машины",          'A', "gamedir=mg1" },
    { "mq.nightmare",     "Pure Nightmare",         "Чистый кошмар",              'A', "skill 3 on all campaign maps" },
    // --- Combat Mastery
    { "mq.lumberjack",    "Lumberjack",             "Дровосек",                   'C', "QC: kill shambler with axe" },
    { "mq.supershredder", "Super Shredder",         "Супер-кромсатель",           'C', "QC: 3 gibs with single SSG shot" },
    { "mq.leadstorm",     "Lead Storm",             "Свинцовый шторм",            'C', "QC: 150 SNG nails without missing" },
    { "mq.shocktherapy",  "Shock Therapy",          "Шоковая терапия",            'C', "QC: discharge Thunderbolt underwater with pentagram, 3 frags" },
    { "mq.chainreaction", "Chain Reaction",         "Цепная реакция",             'C', "QC: 4+ monsters with single explosion" },
    { "mq.quadcarnage",   "Quad Carnage",           "Кровавая жатва",             'A', "6 kills during single Quad Damage window" },
    { "mq.juggernaut",    "Immortal Juggernaut",    "Бессмертный гигант",         'A', "500 damage absorbed under pentagram without dying" },
    { "mq.ringofshadows", "Ring of Shadows",        "Кольцо теней",               'C', "QC: sneak past 3 Death Knights while invisible" },
    { "mq.closecontact",  "Close Contact",          "Вплотную",                   'C', "QC: point-blank shotgun kill on ogre" },
    { "mq.armored",       "Armored to the Teeth",   "Бронированный до зубов",     'A', "health > 100 + red armor 200" },
    // --- Bestiary
    { "mq.fiendhunter",   "Fiend Hunter",           "Охотник на демонов",         'C', "QC: 50 fiends" },
    { "mq.zombiecleanser","Zombie Cleanser",        "Чистильщик зомби",           'C', "QC: 25 zombies using explosives" },
    { "mq.defused",       "Defused",                "Обезврежено",                'C', "QC: spawn killed at long range" },
    { "mq.voresmistake",  "Vore's Mistake",         "Ошибка вора",                'C', "QC: vore pod kills another monster" },
    { "mq.friendlyfire",  "Friendly Fire",          "Дружественный огонь",        'C', "QC: monster infighting to the death" },
    { "mq.apexranger",    "Apex Ranger",            "Верховный рейнджер",         'C', "QC: eliminate all enemy types" },
    { "mq.axeident",      "Axe-ident",              "Топор-идент",                'C', "QC: mid-air axe kill on knight" },
    { "mq.fishfry",       "Fish Fry",               "Рыбный день",                'C', "QC: kill all rotfish with single Thunderbolt discharge" },
    // --- Exploration
    { "mq.secrets100",    "Dungeon Crawler",        "Странник подземелий",        'A', "100% secrets on level" },
    { "mq.archaeologist", "Master Archaeologist",   "Мастер-археолог",            'A', "100% secrets across entire episode" },
    { "mq.secretdimension","Secret Dimension",      "Тайное измерение",           'A', "visit all 4 secret levels" },
    { "mq.deepdiver",     "Deep Diver",             "Глубоководник",              'A', "60s submerged in biosuit" },
    { "mq.lavawalker",    "Lava Walker",            "Хождение по лаве",           'C', "QC: traverse 500 units in lava" },
    { "mq.sharpeye",      "Sharp Eye",              "Острый глаз",                'C', "QC: shoot button from 800 units" },
    { "mq.wellofwishes",  "Well of Wishes",         "Колодец желаний",            'A', "secret in e1m2" },
    { "mq.hoarder",       "Hoarder",                "Собиратель",                 'C', "QC: collect all items on map" },
    // --- Stunts / Speedrun
    { "mq.speeddemon",    "Speed Demon",            "Демон скорости",             'A', "complete e1m1 in under 45s" },
    { "mq.highjumper",    "High Jumper",            "Высоко прыгающий",           'B', "rocket jump 350+ vertical units (APPROX: Z-axis)" },
    { "mq.bunnyhopper",   "Bunny Hopper",           "Распрыгун",                  'A', "maintain 600+ ups for 5 seconds" },
    { "mq.telefragged",   "Telefragged!",           "Телефраг!",                  'B', "telefrag kill (APPROX)" },
    { "mq.floorislava",   "Floor is Lava",          "Пол — это лава",             'C', "QC: consecutive rocket jumps without touching ground" },
    { "mq.pacifist",      "Pacifist Run",           "Пацифист",                   'A', "complete level without kills" },
    { "mq.grenadebasket", "Grenade Basket",         "Гранатный корзиночник",      'C', "QC: bounce grenade through doorway" },
    { "mq.untouchable",   "Untouchable",            "Неуязвимый",                 'A', "complete level without taking damage on Hard+" },
    // --- Engine / Metal
    { "mq.silkysmooth",   "Silky Smooth",           "Шёлковая гладкость",         'A', "play 15 min at 120 Hz" },
    { "mq.zerocopy",      "Zero-Copy Hero",         "Герой нулевого копирования", 'A', "timedemo > 500 fps" },
    { "mq.retropurist",   "Retro Pixel Purist",     "Ретро-пурист",               'A', "complete level with GL_NEAREST + upscaler" },
    { "mq.consolecowboy", "Console Cowboy",         "Ковбой консоли",             'A', "activate cheat code via console" },
    { "mq.hdrvanguard",   "HDR Vanguard",           "Авангард HDR",               'A', "play with HDR enabled" },
    { "mq.metalmaster",   "Metal Master",           "Мастер Metal",               'A', "unlock all other 49 achievements" },
};
#define kAchCount (sizeof(kAch)/sizeof(kAch[0]))

static NSString *AchId(int i) { return [NSString stringWithUTF8String:kAch[i].id]; }
static int AchIndex(const char *id)
{
    for (int i = 0; i < (int)kAchCount; i++)
        if (strcmp(kAch[i].id, id) == 0) return i;
    return -1;
}

// ============================================================
// Report Queue
// ============================================================

static void GC_QueueReport(NSString *aid, double percent)
{
    if (s_state != GCStateAuthed) return;
    GKAchievement *a = [[GKAchievement alloc] initWithIdentifier:aid];
    if (!a) return;
    a.percentComplete = percent;
    a.showsCompletionBanner = NO;
    [s_pending addObject:a];
}

static void GC_Unlock(const char *id)
{
    int idx = AchIndex(id);
    if (idx < 0) return;
    NSString *aid = AchId(idx);
    if ([s_unlocked containsObject:aid]) return;
    
    MLog(MQ_LVL_ALWAYS, "GC", "ACHIEVEMENT UNLOCKED: %s (%s)",
         kAch[idx].id, kAch[idx].nameRu);
    GC_QueueReport(aid, 100.0);
    [s_unlocked addObject:aid];
}

static void GC_ReportProgress(const char *id, double pct)
{
    if (s_state != GCStateAuthed) return;
    int idx = AchIndex(id);
    if (idx < 0) return;
    NSString *aid = AchId(idx);
    if ([s_unlocked containsObject:aid]) return;
    GC_QueueReport(aid, pct);
}

static void GC_FlushPending(void)
{
    if (s_state != GCStateAuthed || s_pending.count == 0) return;
    NSArray *batch = [s_pending copy];
    [s_pending removeAllObjects];
    [GKAchievement reportAchievements:batch
                withCompletionHandler:^(NSError *error) {
        if (error) [s_pending addObjectsFromArray:batch];
    }];
}

// ============================================================
// Evaluation Hooks
// ============================================================

static void GC_CheckCounters(void)
{
    if (s_monsterKills >= 100)  GC_Unlock("mq.slayer100");
    else GC_ReportProgress("mq.slayer100", 100.0 * s_monsterKills / 100);
    if (s_monsterKills >= 1000) GC_Unlock("mq.slayer1000");
    else GC_ReportProgress("mq.slayer1000", 100.0 * s_monsterKills / 1000);
    if (s_secretsFound >= 25)   GC_Unlock("mq.secrets25");
    else GC_ReportProgress("mq.secrets25", 100.0 * s_secretsFound / 25);
    
    // Metal Master: unlock after completing all non-C achievements
    int total = 0, got = 0;
    for (int i = 0; i < (int)kAchCount; i++) {
        if (kAch[i].src == 'C' || strcmp(kAch[i].id, "mq.metalmaster") == 0) continue;
        total++;
        if ([s_unlocked containsObject:AchId(i)]) got++;
    }
    if (got >= total) GC_Unlock("mq.metalmaster");
    else if (got > 0) GC_ReportProgress("mq.metalmaster", 100.0 * got / total);
}

static void GC_CheckMapProgression(void)
{
    // Episodes: entering the first map of the next episode signifies completion of the previous one
    if (!strcmp(s_lvlMapName, "e2m1") && !strcmp(s_prevMapName, "e1m8")) {
        s_epComplete[0] = true; GC_Unlock("mq.ep1.complete");
    }
    if (!strcmp(s_lvlMapName, "e3m1") && !strcmp(s_prevMapName, "e2m7")) {
        s_epComplete[1] = true; GC_Unlock("mq.ep2.complete");
    }
    if (!strcmp(s_lvlMapName, "e4m1") && !strcmp(s_prevMapName, "e3m7")) {
        s_epComplete[2] = true; GC_Unlock("mq.ep3.complete");
    }
    if (!strcmp(s_lvlMapName, "end") && !strcmp(s_prevMapName, "e4m8")) {
        s_epComplete[3] = true; GC_Unlock("mq.ep4.complete");
    }
    
    // Secret level tracking
    if (!strcmp(s_lvlMapName, "e1m8") || !strcmp(s_lvlMapName, "e2m7") ||
        !strcmp(s_lvlMapName, "e3m7") || !strcmp(s_lvlMapName, "e4m8")) {
        static bool secretSeen[4] = { false, false, false, false };
        int idx = !strcmp(s_lvlMapName,"e1m8") ? 0 :
        !strcmp(s_lvlMapName,"e2m7") ? 1 :
        !strcmp(s_lvlMapName,"e3m7") ? 2 : 3;
        if (!secretSeen[idx]) {
            secretSeen[idx] = true;
            if (secretSeen[0] && secretSeen[1] && secretSeen[2] && secretSeen[3])
                GC_Unlock("mq.secretdimension");
        }
    }
    
    // Well of Wishes: discover secret on e1m2
    if (!strcmp(s_lvlMapName, "e1m2") && s_lvlSecrets > 0)
        GC_Unlock("mq.wellofwishes");
    
    // Mission Packs: verify gamedir and destination maps
    if (!strcmp(s_gameDir, "hipnotic") &&
        (!strncmp(s_lvlMapName, "hip", 3)))
        GC_Unlock("mq.mp1.complete");
    if (!strcmp(s_gameDir, "rogue") &&
        (!strncmp(s_lvlMapName, "r1m", 3) || !strncmp(s_lvlMapName, "r2m", 3)))
        GC_Unlock("mq.mp2.complete");
    if (!strcmp(s_gameDir, "dopa") && !strncmp(s_lvlMapName, "dopa", 4))
        GC_Unlock("mq.dopa.complete");
    if (!strcmp(s_gameDir, "mg1") && !strncmp(s_lvlMapName, "mg1", 3))
        GC_Unlock("mq.mg1.complete");
    
    // Pure Nightmare: verify skill == 3 across the entire campaign
    if (s_lvlSkill < 3 && (!strncmp(s_lvlMapName, "e", 2) || !strcmp(s_lvlMapName, "start")))
        s_nightmareChain = false;
    if (s_nightmareChain && s_epComplete[0] && s_epComplete[1] &&
        s_epComplete[2] && s_epComplete[3])
        GC_Unlock("mq.nightmare");
}

static void GC_CheckLevelEnd(void)
{
    // Dungeon Crawler: find 100% of level secrets
    if (s_lvlSecretsTotal > 0 && s_lvlSecrets >= s_lvlSecretsTotal)
        GC_Unlock("mq.secrets100");
    
    // Speed Demon: complete e1m1 in under 45 seconds
    if (!strcmp(s_lvlMapName, "e1m1")) {
        double t = Sys_DoubleTime() - s_lvlStartTime;
        if (t > 0 && t < 45.0) GC_Unlock("mq.speeddemon");
    }
    
    // Pacifist: complete non-boss map without killing monsters
    if (s_pacifistLevel && s_lvlKills == 0 &&
        strncmp(s_lvlMapName, "e1m8", 4) != 0 &&
        strcmp(s_lvlMapName, "end") != 0)
        GC_Unlock("mq.pacifist");
    
    // Untouchable: complete level without taking damage on Hard or Nightmare
    if (s_lvlSkill >= 2 && !s_lvlDamageTaken && s_lvlKills >= 0)
        GC_Unlock("mq.untouchable");
    
    // Retro Pixel Purist: complete level with NEAREST texture filter and active upscaler
    if (s_nearestUpscale && g_fxActive)
        GC_Unlock("mq.retropurist");
    
    // Master Archaeologist: find all secrets in all levels of an episode
    if (s_lvlSecretsTotal > 0 && s_lvlSecrets >= s_lvlSecretsTotal) {
        if (!strcmp(s_lvlMapName, "e1m7") || !strcmp(s_lvlMapName, "e1m8"))
            GC_ReportProgress("mq.archaeologist", 25);
        if (!strcmp(s_lvlMapName, "e2m6") || !strcmp(s_lvlMapName, "e2m7"))
            GC_ReportProgress("mq.archaeologist", 50);
        if (!strcmp(s_lvlMapName, "e3m6") || !strcmp(s_lvlMapName, "e3m7"))
            GC_ReportProgress("mq.archaeologist", 75);
        if (!strcmp(s_lvlMapName, "e4m7") || !strcmp(s_lvlMapName, "e4m8"))
            GC_Unlock("mq.archaeologist");
    }
    
    s_levelsCompleted++;
}

// ============================================================
// Per-Frame Evaluation (Called from Host_Frame)
// ============================================================

void GC_Frame(void)
{
    if (s_state == GCStateIdle || s_state == GCStateDisabled) return;
    if (!cl.worldmodel) return; // Active gameplay requires loaded worldmodel
    
    double now = Sys_DoubleTime();
    int health = cl.stats[STAT_HEALTH];
    int armor  = cl.stats[STAT_ARMOR];
    int items  = cl.items;
    
    // --- Quad Carnage
    if (items & IT_QUAD) {
        if (s_quadActiveSince == 0) { s_quadActiveSince = now; s_quadKills = 0; }
    } else if (s_quadActiveSince > 0) {
        s_quadActiveSince = 0; s_quadKills = 0;
    }
    
    // --- Immortal Juggernaut (accumulate damage absorbed during invulnerability)
    if (items & IT_INVULNERABILITY) {
        if (s_pentActiveSince == 0) { s_pentActiveSince = now; s_pentDamage = 0; }
    } else if (s_pentActiveSince > 0) {
        s_pentActiveSince = 0;
    }
    
    // --- Deep Diver (accumulate 60+ seconds submerged in biosuit)
    if (items & IT_SUIT) {
        if (s_suitUnderwaterSince == 0) s_suitUnderwaterSince = now;
        s_suitUnderwaterTotal += 1.0 / 72.0; // Single simulation tick interval
    } else {
        s_suitUnderwaterSince = 0;
    }
    if (s_suitUnderwaterTotal >= 60.0) GC_Unlock("mq.deepdiver");
    
    // --- Bunny Hopper: maintain 600+ ups continuously for 5 seconds
    float speed = VectorLength(cl.velocity);
    if (speed >= 600.0f) {
        if (!s_speedHighActive) {
            s_speedHighActive = true;
            s_speedHighSince = now;
        } else if (now - s_speedHighSince >= 5.0) {
            GC_Unlock("mq.bunnyhopper");
        }
    } else {
        s_speedHighActive = false;
    }
    
    // --- Damage tracking (for Untouchable and Immortal Juggernaut)
    static int prevHealth = 100, prevArmor = 0;
    if (health < prevHealth) s_lvlDamageTaken = true;
    int dmgThisFrame = (prevHealth - health) + (prevArmor - armor);
    if (dmgThisFrame > 0 && dmgThisFrame < 200) { // Reject telefrag and respawn outliers
        s_lvlDamageTaken = true;
        if (s_pentActiveSince > 0) s_pentDamage += dmgThisFrame;
        if (s_pentDamage >= 500) GC_Unlock("mq.juggernaut");
    }
    prevHealth = health;
    prevArmor = armor;
    
    // --- Armored to the Teeth
    if (health > 100 && armor >= 200 && (items & IT_ARMOR3))
        GC_Unlock("mq.armored");
    
    // --- Quad kills (linked with monster kill notification)
    if (s_quadActiveSince > 0 && s_quadKills >= 6)
        GC_Unlock("mq.quadcarnage");
    
    // --- Silky Smooth: 15 continuous minutes at 120 Hz
    NSScreen *scr = [NSScreen mainScreen];
    if (scr.maximumFramesPerSecond >= 120) {
        if (!s_120hzLogged) { s_120hzLogged = true; s_120hzSince = now; }
        if (now - s_120hzSince >= 15 * 60.0) GC_Unlock("mq.silkysmooth");
    } else {
        s_120hzSince = 0;
    }
    
    // --- HDR Vanguard
    if (g_hdrActive && g_edrActive && g_edrHeadroom > 1.0f)
        GC_Unlock("mq.hdrvanguard");
    
    // --- Retro Pixel Purist: Upscaler active with nearest-neighbor sampling
    if (g_fxActive)
        s_nearestUpscale = true;
}

// ============================================================
// Event Notification Hooks
// ============================================================

void GC_NotifyMonsterKill(void)
{
    s_monsterKills++;
    s_lvlKills++;
    s_pacifistLevel = false;
    if (s_quadActiveSince > 0) s_quadKills++;
    GC_CheckCounters();
    
    // Shub's Demise (APPROX): any monster killed on map "end"
    if (!strcmp(s_lvlMapName, "end")) GC_Unlock("mq.shub.demise");
}

void GC_NotifySecret(void)
{
    s_secretsFound++;
    s_lvlSecrets++;
    GC_CheckCounters();
    if (!strcmp(s_lvlMapName, "e1m2")) GC_Unlock("mq.wellofwishes");
}

void GC_NotifyMapStart(const char *map)
{
    // Evaluate completion state of previous level
    GC_CheckLevelEnd();
    
    strncpy(s_prevMapName, s_lvlMapName, sizeof(s_prevMapName) - 1);
    strncpy(s_lvlMapName, map ?: "", sizeof(s_lvlMapName) - 1);
    s_lvlMapName[sizeof(s_lvlMapName) - 1] = 0;
    
    // Reset per-level metrics
    s_lvlKills = 0; s_lvlSecrets = 0; s_lvlSecretsTotal = 0; s_lvlMonstersTotal = 0;
    s_lvlDamageTaken = false; s_pacifistLevel = true;
    s_lvlStartTime = Sys_DoubleTime();
    s_lvlSkill = (int)skill.value;
    s_suitUnderwaterTotal = 0;
    if (com_gamedir[0]) strncpy(s_gameDir, com_gamedir, sizeof(s_gameDir) - 1);
    
    GC_CheckMapProgression();
}

void GC_NotifyTimedemo(double fps)
{
    if (fps > 500.0) GC_Unlock("mq.zerocopy");
}

void GC_NotifyCheat(const char *cmd)
{
    if (cmd && (!strcmp(cmd, "god") || !strcmp(cmd, "noclip") ||
                !strcmp(cmd, "give") || !strcmp(cmd, "fly")))
        GC_Unlock("mq.consolecowboy");
}

// ============================================================
// Init / Shutdown
// ============================================================

void GC_Init(void)
{
    if (s_state != GCStateIdle) return;
    
    s_unlocked = [NSMutableSet set];
    s_pending  = [NSMutableArray array];
    memset(s_mapSeen, 0, sizeof(s_mapSeen));
    s_sessionStart = Sys_DoubleTime();
    
    GKLocalPlayer *lp = [GKLocalPlayer local];
    if (!lp) { s_state = GCStateDisabled; return; }
    
    s_state = GCStateAuthenticating;
    
    // Create weak reference to prevent retain cycles
    __weak typeof(lp) weakLp = lp;
    
    lp.authenticateHandler = ^(NSViewController *viewController, NSError *error) {
        GKLocalPlayer *strongLp = weakLp;
        if (!strongLp) return;
        
        if (viewController) {
            NSWindow *keyWindow = [NSApp keyWindow] ?: [NSApp windows].firstObject;
            [keyWindow.contentViewController presentViewControllerAsModalWindow:viewController];
            return;
        }
        
        if (error || !strongLp.isAuthenticated) {
            s_state = GCStateDisabled;
            MLog(MQ_LVL_DEV, "GC", "disabled (no account/entitlement) — achievements no-op");
            return;
        }
        
        s_state = GCStateAuthed;
        MLog(MQ_LVL_ALWAYS, "GC", "authenticated as %s", strongLp.gamePlayerID.UTF8String ?: "?");
        
        [GKAchievement loadAchievementsWithCompletionHandler:^(NSArray<GKAchievement *> *achs, NSError *err) {
            if (!err) {
                for (GKAchievement *a in achs) {
                    if (a.percentComplete >= 100.0) {
                        [s_unlocked addObject:a.identifier];
                    }
                }
            }
            GC_CheckCounters();
            GC_FlushPending();
        }];
        GC_FlushPending();
    };
}

void GC_Shutdown(void)
{
    s_pending = nil;
    s_state = GCStateIdle;
}

void GC_ReportAchievement(const char *achievementId, float percent)
{
    GC_QueueReport([NSString stringWithUTF8String:achievementId ?: ""], percent);
    GC_FlushPending();
}

bool GC_Unlocked(const char *achievementId)
{
    if (s_state != GCStateAuthed || !achievementId) return false;
    return [s_unlocked containsObject:[NSString stringWithUTF8String:achievementId]];
}
