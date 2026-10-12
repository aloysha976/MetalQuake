//
//  in_gamecontroller.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

//
//  in_gamecontroller.h — Native gamepad support via GameController.framework
//

#ifndef IN_GAMECONTROLLER_H
#define IN_GAMECONTROLLER_H

#include "quakedef.h"

#ifdef __cplusplus
extern "C" {
#endif

// Subsystem initialization: registers cvars and subscribes to GCController notifications
void IN_GC_Init(void);

// Releases resources and unregisters notification observers
void IN_GC_Shutdown(void);

// Resets internal button press states
void IN_GC_ClearStates(void);

// Polls discrete buttons and analog triggers (translates events to Key_Event)
// Invoked from IN_Commands / frame loop
void IN_GC_Commands(void);

// Reads analog axes (left thumbstick -> locomotion, right thumbstick -> view rotation)
// Invoked from IN_JoyMove / IN_Move
void IN_GC_Move(usercmd_t *cmd);

// High-fidelity haptic feedback profiles
typedef enum {
    // 1. Armament
    GC_HAPTIC_SHOTGUN,        // Crisp, dense single discharge
    GC_HAPTIC_SUPER_SHOTGUN,  // Overpowering double-barrel blast
    GC_HAPTIC_NAIL,           // Sharp metallic bolt cycle click
    GC_HAPTIC_ROCKET,         // Deep reactive exhaust thrust for grenades/rockets
    GC_HAPTIC_LIGHTNING,      // High-frequency electrical discharge hum
    GC_HAPTIC_AXE,            // Swift kinetic melee impact

    // 2. Locomotion & Physics
    GC_HAPTIC_LAND_LIGHT,     // Soft impulse damping on regular landing
    GC_HAPTIC_LAND_HARD,      // Hard kinetic compression shock on high fall
    GC_HAPTIC_TELEPORT,       // Spatial rift impulse upon portal exit

    // 3. Items & Power-ups
    GC_HAPTIC_ITEM_PICKUP,    // Subtle haptic click (ammo, armor, health packs)
    GC_HAPTIC_POWERUP_QUAD,   // Dual adrenaline heartbeat pulse (Quad Damage / Pentagram)

    // 4. Damage Received
    GC_HAPTIC_DAMAGE,         // Kinetic jolt proportional to health loss
    GC_HAPTIC_EXPLOSION       // Deep blast wave resonance (Splash Damage)
} gc_haptic_type_t;

// Triggers haptic feedback event (strength normalized from 0.0 to 1.0)
void IN_GC_PlayHaptic(gc_haptic_type_t type, float strength);

#ifdef __cplusplus
}
#endif

#endif /* IN_GAMECONTROLLER_H */
