//
//  in_gamecontroller.m
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

/*
 * in_gamecontroller.m — GameController.framework implementation for MetalQuake.
 */

#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import "in_gamecontroller.h"
#import "mq_log.h"

extern cvar_t cl_maxpitch;
extern cvar_t cl_minpitch;

static void IN_GC_SetDefaultBindings(void);
static void IN_GC_InitHaptics(void);
static void IN_GC_ShutdownHaptics(void);

//==========================================================================
// Haptic Feedback Engine
//==========================================================================

static CHHapticEngine *s_hapticEngine = nil;
static BOOL s_hapticsAvailable = NO;

static void IN_GC_InitHaptics(void);
static void IN_GC_ShutdownHaptics(void);

static void IN_GC_SetDefaultBindings(void);

//==========================================================================
// C-Variables (Gamepad Configuration)
//==========================================================================

cvar_t joy_enable            = {"joy_enable",            "1",    CVAR_ARCHIVE};
cvar_t joy_deadzone          = {"joy_deadzone",          "0.15", CVAR_ARCHIVE}; // Radial deadzone [0.0 .. 0.9]
cvar_t joy_sensitivity_yaw   = {"joy_sensitivity_yaw",   "240",  CVAR_ARCHIVE}; // Yaw turn speed (degrees/sec)
cvar_t joy_sensitivity_pitch = {"joy_sensitivity_pitch", "180",  CVAR_ARCHIVE}; // Pitch tilt speed (degrees/sec)
cvar_t joy_exponent          = {"joy_exponent",          "2.0",  CVAR_ARCHIVE}; // Response curve: 1.0=linear, 2.0=quadratic
cvar_t joy_inverty           = {"joy_inverty",           "0",    CVAR_ARCHIVE}; // Invert vertical look axis
cvar_t joy_trigger_threshold = {"joy_trigger_threshold", "0.2",  CVAR_ARCHIVE}; // Analog trigger threshold (LT/RT)
cvar_t joy_haptics           = {"joy_haptics",           "1",    CVAR_ARCHIVE}; // Haptic feedback (0 = disabled, 1 = enabled)

cvar_t joy_gyro              = {"joy_gyro",              "1",    CVAR_ARCHIVE}; // Gyro: 0=off, 1=always on, 2=aim-only (LT), 3=ratchet (pause on R3)
cvar_t joy_gyro_sensitivity  = {"joy_gyro_sensitivity",  "1.5",  CVAR_ARCHIVE}; // Gyro sensitivity multiplier
cvar_t joy_gyro_threshold    = {"joy_gyro_threshold",    "0.02", CVAR_ARCHIVE}; // Hand tremor noise gate (rad/sec)
cvar_t joy_gyro_axis         = {"joy_gyro_axis",         "0",    CVAR_ARCHIVE}; // Yaw axis: 0=Yaw, 1=Roll (steering), 2=Combined
cvar_t joy_gyro_inverty      = {"joy_gyro_inverty",      "0",    CVAR_ARCHIVE}; // Invert Gyro Y axis
cvar_t joy_gyro_invertx      = {"joy_gyro_invertx",      "0",    CVAR_ARCHIVE}; // Invert Gyro X axis

//==========================================================================
// Internal Controller State
//==========================================================================

static GCController *s_activeController = nil;
static id s_connectObserver = nil;
static id s_disconnectObserver = nil;

//==========================================================================
// Active Device Selection
//==========================================================================

static void IN_GC_SelectBestController(void)
{
    // Apple automatically prioritizes the controller currently receiving user input
    GCController *best = [GCController current];

    if (!best || !best.extendedGamepad)
    {
        for (GCController *c in [GCController controllers])
        {
            if (c.extendedGamepad)
            {
                best = c;
                break;
            }
        }
    }

    if (best == s_activeController)
        return;

    s_activeController = best;

    if (s_activeController)
    {
        Con_Printf("GameController: active controller '%s'\n", [s_activeController.vendorName UTF8String] ?: "Unknown");

        // Activate GCMotion motion sensors (DualSense, Switch Pro, DualShock)
        if (@available(macOS 11.0, *))
        {
            if (s_activeController.motion)
            {
                if (s_activeController.motion.sensorsRequireManualActivation)
                {
                    s_activeController.motion.sensorsActive = YES;
                }
                Con_Printf("GameController: motion sensors (GCMotion) activated\n");
            }
        }

        IN_GC_InitHaptics();
    }
    else
    {
        Con_Printf("GameController: no connected devices\n");
        IN_GC_ShutdownHaptics();
    }
}

//==========================================================================
// Public Lifecycle API
//==========================================================================

void IN_GC_Init(void)
{
    Cvar_RegisterVariable(&joy_enable);
    Cvar_RegisterVariable(&joy_deadzone);
    Cvar_RegisterVariable(&joy_sensitivity_yaw);
    Cvar_RegisterVariable(&joy_sensitivity_pitch);
    Cvar_RegisterVariable(&joy_exponent);
    Cvar_RegisterVariable(&joy_inverty);
    Cvar_RegisterVariable(&joy_trigger_threshold);
    Cvar_RegisterVariable(&joy_haptics);
    
    Cvar_RegisterVariable(&joy_gyro);
    Cvar_RegisterVariable(&joy_gyro_sensitivity);
    Cvar_RegisterVariable(&joy_gyro_threshold);
    Cvar_RegisterVariable(&joy_gyro_axis);
    Cvar_RegisterVariable(&joy_gyro_inverty);
    Cvar_RegisterVariable(&joy_gyro_invertx);
    
    IN_GC_SetDefaultBindings();

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    s_connectObserver = [nc addObserverForName:GCControllerDidConnectNotification
                                        object:nil
                                         queue:[NSOperationQueue mainQueue]
                                    usingBlock:^(NSNotification *note) {
        GCController *controller = (GCController *)note.object;
        Con_Printf("GameController connected: %s\n", [controller.vendorName UTF8String] ?: "Unknown");
        IN_GC_SelectBestController();
    }];

    s_disconnectObserver = [nc addObserverForName:GCControllerDidDisconnectNotification
                                           object:nil
                                            queue:[NSOperationQueue mainQueue]
                                       usingBlock:^(NSNotification *note) {
        GCController *controller = (GCController *)note.object;
        Con_Printf("GameController disconnected: %s\n", [controller.vendorName UTF8String] ?: "Unknown");

        if (s_activeController == controller)
        {
            s_activeController = nil;
            // Clear stuck key states in Quake input system
            Key_ClearStates();
            // Re-evaluate controller candidates if another gamepad remains connected
            IN_GC_SelectBestController();
        }
    }];

    // Poll controllers already connected prior to engine launch
    IN_GC_SelectBestController();
}

void IN_GC_Shutdown(void)
{
    IN_GC_ShutdownHaptics();
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    if (s_connectObserver)
    {
        [nc removeObserver:s_connectObserver];
        s_connectObserver = nil;
    }

    if (s_disconnectObserver)
    {
        [nc removeObserver:s_disconnectObserver];
        s_disconnectObserver = nil;
    }

    s_activeController = nil;
}

//==========================================================================
// Button and Trigger Polling
//==========================================================================

enum
{
    GC_BTN_A,
    GC_BTN_B,
    GC_BTN_X,
    GC_BTN_Y,
    GC_BTN_LSHOULDER,
    GC_BTN_RSHOULDER,
    GC_BTN_LTHUMB,
    GC_BTN_RTHUMB,
    GC_BTN_LTRIGGER,
    GC_BTN_RTRIGGER,
    GC_BTN_DPAD_UP,
    GC_BTN_DPAD_DOWN,
    GC_BTN_DPAD_LEFT,
    GC_BTN_DPAD_RIGHT,
    GC_BTN_MENU,
    GC_BTN_OPTIONS,
    GC_BTN_COUNT
};

static qboolean s_gcButtonStates[GC_BTN_COUNT] = {false};

void IN_GC_ClearStates(void)
{
    for (int i = 0; i < GC_BTN_COUNT; i++)
    {
        s_gcButtonStates[i] = false;
    }
}

static inline void IN_GC_ProcessButton(int btnIndex, int quakeKey, qboolean isPressed)
{
    if (s_gcButtonStates[btnIndex] != isPressed)
    {
        s_gcButtonStates[btnIndex] = isPressed;
        Key_Event(quakeKey, isPressed);
    }
}

void IN_GC_Commands(void)
{
    if (!joy_enable.value || !s_activeController)
        return;

    GCExtendedGamepad *gp = s_activeController.extendedGamepad;
    if (!gp)
        return;

    // 1. Primary action buttons (ABXY / Cross, Circle, Square, Triangle)
    IN_GC_ProcessButton(GC_BTN_A, K_ABUTTON, gp.buttonA.isPressed);
    IN_GC_ProcessButton(GC_BTN_B, K_BBUTTON, gp.buttonB.isPressed);
    IN_GC_ProcessButton(GC_BTN_X, K_XBUTTON, gp.buttonX.isPressed);
    IN_GC_ProcessButton(GC_BTN_Y, K_YBUTTON, gp.buttonY.isPressed);

    // 2. Shoulder bumpers (L1 / R1 / LB / RB)
    IN_GC_ProcessButton(GC_BTN_LSHOULDER, K_LSHOULDER, gp.leftShoulder.isPressed);
    IN_GC_ProcessButton(GC_BTN_RSHOULDER, K_RSHOULDER, gp.rightShoulder.isPressed);

    // 3. Stick clicks (L3 / R3 / LS / RS)
    IN_GC_ProcessButton(GC_BTN_LTHUMB, K_LTHUMB, gp.leftThumbstickButton.isPressed);
    IN_GC_ProcessButton(GC_BTN_RTHUMB, K_RTHUMB, gp.rightThumbstickButton.isPressed);

    // 4. Analog triggers with threshold check (LT / RT / L2 / R2)
    float threshold = joy_trigger_threshold.value;
    if (threshold < 0.05f) threshold = 0.05f;
    if (threshold > 0.95f) threshold = 0.95f;

    qboolean ltPressed = (gp.leftTrigger.value >= threshold);
    qboolean rtPressed = (gp.rightTrigger.value >= threshold);
    IN_GC_ProcessButton(GC_BTN_LTRIGGER, K_LTRIGGER, ltPressed);
    IN_GC_ProcessButton(GC_BTN_RTRIGGER, K_RTRIGGER, rtPressed);

    // 5. D-Pad (mapped to standard arrow keys for menu navigation and actions)
    IN_GC_ProcessButton(GC_BTN_DPAD_UP,    K_UPARROW,    gp.dpad.up.isPressed);
    IN_GC_ProcessButton(GC_BTN_DPAD_DOWN,  K_DOWNARROW,  gp.dpad.down.isPressed);
    IN_GC_ProcessButton(GC_BTN_DPAD_LEFT,  K_LEFTARROW,  gp.dpad.left.isPressed);
    IN_GC_ProcessButton(GC_BTN_DPAD_RIGHT, K_RIGHTARROW, gp.dpad.right.isPressed);

    // 6. System buttons (Menu / Start -> ESC for menu toggle; Options / Back / View -> TAB for scoreboard)
    IN_GC_ProcessButton(GC_BTN_MENU, K_ESCAPE, gp.buttonMenu.isPressed);

    if (gp.buttonOptions)
    {
        IN_GC_ProcessButton(GC_BTN_OPTIONS, K_TAB, gp.buttonOptions.isPressed);
    }
}

//==========================================================================
// Analog Input Mathematics (Radial Deadzone + Response Curve)
//==========================================================================

static void IN_GC_ApplyRadialDeadzone(float rawX, float rawY, float deadzone, float exponent, float *outX, float *outY)
{
    float mag = sqrtf(rawX * rawX + rawY * rawY);

    if (mag <= deadzone)
    {
        *outX = 0.0f;
        *outY = 0.0f;
        return;
    }

    // Remap range [deadzone .. 1.0] -> [0.0 .. 1.0]
    float norm = (mag - deadzone) / (1.0f - deadzone);
    if (norm > 1.0f) norm = 1.0f;

    // Polynomial response curve for precise fine-aim adjustments
    if (exponent > 0.1f && exponent != 1.0f)
    {
        norm = powf(norm, exponent);
    }

    *outX = (rawX / mag) * norm;
    *outY = (rawY / mag) * norm;
}

//==========================================================================
// Default Gamepad Bindings
//==========================================================================

static void IN_GC_SetDefaultBindings(void)
{
    // If button A is unbound, assume default gamepad profile is missing
    if (keybindings[K_ABUTTON] && keybindings[K_ABUTTON][0] != '\0')
        return;

    Key_SetBinding(K_ABUTTON,   "+jump");
    Key_SetBinding(K_BBUTTON,   "+jump");
    Key_SetBinding(K_XBUTTON,   "impulse 10"); // Next weapon
    Key_SetBinding(K_YBUTTON,   "impulse 12"); // Prev weapon

    Key_SetBinding(K_LSHOULDER, "impulse 12"); // Prev weapon
    Key_SetBinding(K_RSHOULDER, "impulse 10"); // Next weapon

    Key_SetBinding(K_LTRIGGER,  "+jump");
    Key_SetBinding(K_RTRIGGER,  "+attack");

    Key_SetBinding(K_LTHUMB,    "+speed");
}

//==========================================================================
// Analog Movement and Look Processing
//==========================================================================

void IN_GC_Move(usercmd_t *cmd)
{
    if (!joy_enable.value || !s_activeController)
        return;

    if (cl.paused || key_dest != key_game)
        return;

    GCExtendedGamepad *gp = s_activeController.extendedGamepad;
    if (!gp)
        return;

    float deadzone = joy_deadzone.value;
    if (deadzone < 0.0f) deadzone = 0.0f;
    if (deadzone > 0.9f) deadzone = 0.9f;

    // ----------------------------------------------------------------------
    // 1. Left Stick: Locomotion (cmd->forwardmove, cmd->sidemove)
    // ----------------------------------------------------------------------
    float moveX = 0.0f, moveY = 0.0f;
    IN_GC_ApplyRadialDeadzone(gp.leftThumbstick.xAxis.value,
                              gp.leftThumbstick.yAxis.value,
                              deadzone,
                              1.0f, // Linear response for locomotion
                              &moveX, &moveY);

    if (moveX != 0.0f || moveY != 0.0f)
    {
        cmd->sidemove    += moveX * cl_sidespeed.value;
        cmd->forwardmove += moveY * cl_forwardspeed.value;
    }

    // ----------------------------------------------------------------------
    // 2. Right Stick: Camera Look (cl.viewangles PITCH / YAW)
    // ----------------------------------------------------------------------
    float lookX = 0.0f, lookY = 0.0f;
    float exponent = joy_exponent.value;
    if (exponent < 1.0f) exponent = 1.0f;
    if (exponent > 4.0f) exponent = 4.0f;

    IN_GC_ApplyRadialDeadzone(gp.rightThumbstick.xAxis.value,
                              gp.rightThumbstick.yAxis.value,
                              deadzone,
                              exponent,
                              &lookX, &lookY);

    if (lookX != 0.0f || lookY != 0.0f)
    {
        // Clamp delta time to prevent abrupt view snaps across frame rate drops
        float dt = (float)host_frametime;
        if (dt <= 0.0f) dt = 0.001f;
        if (dt > 0.1f)  dt = 0.1f;

        V_StopPitchDrift();

        // Yaw (left / right)
        float d_yaw = lookX * joy_sensitivity_yaw.value * dt;
        cl.viewangles[YAW] -= d_yaw;

        // Pitch (up / down)
        float pitch_sign = (joy_inverty.value != 0.0f) ? 1.0f : -1.0f;
        float d_pitch = lookY * joy_sensitivity_pitch.value * dt * pitch_sign;
        cl.viewangles[PITCH] += d_pitch;

        // View pitch smart clamps
        float max_p = (cl_maxpitch.value > 0.0f && cl_maxpitch.value <= 75.0f) ? cl_maxpitch.value : 75.0f;
        float min_p = (cl_minpitch.value < 0.0f && cl_minpitch.value >= -85.0f) ? cl_minpitch.value : -85.0f;

        if (cl.viewangles[PITCH] > max_p)
            cl.viewangles[PITCH] = max_p;
        if (cl.viewangles[PITCH] < min_p)
            cl.viewangles[PITCH] = min_p;
    }
    
    // ----------------------------------------------------------------------
    // 3. Gyroscope Aiming (GCMotion Gyro Aiming)
    // ----------------------------------------------------------------------
    if (joy_gyro.value > 0.0f && s_activeController.motion)
    {
        qboolean gyroActive = true;
        
        // Activation modes
        if ((int)joy_gyro.value == 2)
        {
            // Mode 2: Active only while holding Left Trigger
            float threshold = joy_trigger_threshold.value;
            gyroActive = (gp.leftTrigger.value >= threshold);
        }
        else if ((int)joy_gyro.value == 3)
        {
            // Mode 3: Ratchet (pause gyro when pressing R3/Right Stick to reset hand posture)
            gyroActive = !gp.rightThumbstickButton.isPressed;
        }
        
        if (gyroActive)
        {
            GCRotationRate rate = s_activeController.motion.rotationRate;
            
            float rawPitch = (float)rate.x;
            float rawYaw   = 0.0f;
            
            int axisMode = (int)joy_gyro_axis.value;
            if (axisMode == 1)
            {
                // Roll (steering wheel mode)
                rawYaw = -(float)rate.z;
            }
            else if (axisMode == 2)
            {
                // Combined (Yaw + Roll for 45-degree controller grip)
                rawYaw = (float)rate.y - (float)rate.z * 0.7f;
            }
            else
            {
                // Local Yaw (horizontal panning)
                rawYaw = (float)rate.y;
            }
            
            // Hand tremor noise gate
            float thresh = joy_gyro_threshold.value;
            if (fabsf(rawPitch) < thresh) rawPitch = 0.0f;
            if (fabsf(rawYaw)   < thresh) rawYaw   = 0.0f;
            
            if (rawPitch != 0.0f || rawYaw != 0.0f)
            {
                float dt = (float)host_frametime;
                if (dt <= 0.0f) dt = 0.001f;
                if (dt > 0.1f)  dt = 0.1f;
                
                V_StopPitchDrift();
                
                // Convert rad/sec to degrees: rad * (180 / PI) ≈ rad * 57.29578
                const float radToDeg = 57.2957795f;
                float sens = joy_gyro_sensitivity.value;
                
                float pitchSign = (joy_gyro_inverty.value != 0.0f) ? -1.0f : 1.0f;
                float yawSign   = (joy_gyro_invertx.value != 0.0f) ? -1.0f : 1.0f;
                
                float d_gyro_pitch = rawPitch * radToDeg * sens * dt * pitchSign;
                float d_gyro_yaw   = rawYaw   * radToDeg * sens * dt * yawSign;
                
                cl.viewangles[PITCH] -= d_gyro_pitch;
                cl.viewangles[YAW]   -= d_gyro_yaw;
                
                // Reapply view pitch clamping after gyro adjustment
                float max_p = (cl_maxpitch.value > 0.0f && cl_maxpitch.value <= 75.0f) ? cl_maxpitch.value : 75.0f;
                float min_p = (cl_minpitch.value < 0.0f && cl_minpitch.value >= -85.0f) ? cl_minpitch.value : -85.0f;
                
                if (cl.viewangles[PITCH] > max_p)
                    cl.viewangles[PITCH] = max_p;
                if (cl.viewangles[PITCH] < min_p)
                    cl.viewangles[PITCH] = min_p;
            }
        }
    }
}

//==========================================================================
// CoreHaptics Engine Control
//==========================================================================

static void IN_GC_ShutdownHaptics(void)
{
    if (@available(macOS 11.0, *))
    {
        if (s_hapticEngine)
        {
            [s_hapticEngine stopWithCompletionHandler:nil];
            s_hapticEngine = nil;
        }
    }
    s_hapticsAvailable = NO;
}

static void IN_GC_InitHaptics(void)
{
    IN_GC_ShutdownHaptics();

    if (!s_activeController)
        return;

    if (@available(macOS 11.0, *))
    {
        GCDeviceHaptics *haptics = s_activeController.haptics;
        if (!haptics)
            return;

        s_hapticEngine = [haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!s_hapticEngine)
            return;

        s_hapticEngine.resetHandler = ^{
            NSError *startError = nil;
            [s_hapticEngine startAndReturnError:&startError];
        };

        s_hapticEngine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            (void)reason;
            s_hapticsAvailable = NO;
        };

        NSError *err = nil;
        if ([s_hapticEngine startAndReturnError:&err])
        {
            s_hapticsAvailable = YES;
            Con_Printf("GameController: haptic feedback initialized\n");
        }
        else
        {
            s_hapticEngine = nil;
            s_hapticsAvailable = NO;
        }
    }
}

//==========================================================================
// Smart Gameplay Event Tracker
//==========================================================================

static void IN_GC_UpdateHapticEvents(void)
{
    if (!joy_enable.value || !joy_haptics.value || !s_hapticsAvailable)
        return;

    // Static event edge tracking state
    static int s_prevWeaponFrame = 0;
    static int s_prevHealth = 0;
    static int s_prevItems = 0;
    static int s_prevBonus = 0;
    static qboolean s_wasInAir = false;
    static float s_maxFallVelocity = 0.0f;
    static vec3_t s_prevOrigin = {0};
    static qboolean s_hasPrevOrigin = false;

    // Reset trackers when disconnected from server or paused
    if (cls.state != ca_connected || cl.paused)
    {
        s_prevWeaponFrame = 0;
        s_prevHealth = 0;
        s_prevItems = 0;
        s_prevBonus = 0;
        s_wasInAir = false;
        s_maxFallVelocity = 0.0f;
        s_hasPrevOrigin = false;
        return;
    }

    // ----------------------------------------------------------------------
    // 1. Weapons: Differentiated recoil profiles per armament type
    // ----------------------------------------------------------------------
    int curWeaponFrame = cl.stats[STAT_WEAPONFRAME];

    if (curWeaponFrame != 0 && curWeaponFrame != s_prevWeaponFrame)
    {
        int activeWep = cl.stats[STAT_ACTIVEWEAPON];
        gc_haptic_type_t wepHaptic = GC_HAPTIC_SHOTGUN;
        float strength = 0.85f;

        if (activeWep & IT_AXE)
        {
            wepHaptic = GC_HAPTIC_AXE;
            strength = 0.70f;
        }
        else if (activeWep & IT_SUPER_SHOTGUN)
        {
            wepHaptic = GC_HAPTIC_SUPER_SHOTGUN;
            strength = 1.0f;
        }
        else if (activeWep & IT_SHOTGUN)
        {
            wepHaptic = GC_HAPTIC_SHOTGUN;
            strength = 0.85f;
        }
        else if (activeWep & (IT_NAILGUN | IT_SUPER_NAILGUN))
        {
            wepHaptic = GC_HAPTIC_NAIL;
            strength = (activeWep & IT_SUPER_NAILGUN) ? 0.75f : 0.60f;
        }
        else if (activeWep & (IT_ROCKET_LAUNCHER | IT_GRENADE_LAUNCHER))
        {
            wepHaptic = GC_HAPTIC_ROCKET;
            strength = 0.95f;
        }
        else if (activeWep & IT_LIGHTNING)
        {
            wepHaptic = GC_HAPTIC_LIGHTNING;
            strength = 0.70f;
        }

        IN_GC_PlayHaptic(wepHaptic, strength);
    }
    s_prevWeaponFrame = curWeaponFrame;

    // ----------------------------------------------------------------------
    // 2. Fall Physics: Step damping and hard ground impact haptics
    // ----------------------------------------------------------------------
    if (!cl.onground)
    {
        s_wasInAir = true;
        // Track peak downward vertical fall velocity (negative)
        if (cl.velocity[2] < s_maxFallVelocity)
        {
            s_maxFallVelocity = cl.velocity[2];
        }
    }
    else
    {
        if (s_wasInAir)
        {
            // Ignore minor bunny-hops: trigger only for fall velocities exceeding -250 units/s
            if (s_maxFallVelocity < -600.0f)
            {
                // Hard fall impact from significant height
                IN_GC_PlayHaptic(GC_HAPTIC_LAND_HARD, 1.0f);
            }
            else if (s_maxFallVelocity < -250.0f)
            {
                // Soft landing
                float norm = (-s_maxFallVelocity - 250.0f) / 350.0f;
                if (norm > 1.0f) norm = 1.0f;
                IN_GC_PlayHaptic(GC_HAPTIC_LAND_LIGHT, norm);
            }

            s_wasInAir = false;
            s_maxFallVelocity = 0.0f;
        }
    }

    // ----------------------------------------------------------------------
    // 3. Teleportation: Sudden spatial displacement
    // ----------------------------------------------------------------------
    if (cl.viewentity > 0 && cl_entities)
    {
        vec3_t curOrigin;
        VectorCopy(cl_entities[cl.viewentity].origin, curOrigin);

        if (s_hasPrevOrigin && cl.stats[STAT_HEALTH] > 0)
        {
            float dx = curOrigin[0] - s_prevOrigin[0];
            float dy = curOrigin[1] - s_prevOrigin[1];
            float dz = curOrigin[2] - s_prevOrigin[2];
            float distSq = dx * dx + dy * dy + dz * dz;

            // Displacement exceeding 400 units in a single frame indicates teleportation
            if (distSq > (400.0f * 400.0f))
            {
                IN_GC_PlayHaptic(GC_HAPTIC_TELEPORT, 1.0f);
            }
        }

        VectorCopy(curOrigin, s_prevOrigin);
        s_hasPrevOrigin = true;
    }

    // ----------------------------------------------------------------------
    // 4. Power-ups (Quad Damage / Pentagram of Protection)
    // ----------------------------------------------------------------------
    int curItems = cl.items;
    qboolean gainedQuad = (!(s_prevItems & IT_QUAD) && (curItems & IT_QUAD));
    qboolean gainedPenta = (!(s_prevItems & IT_INVULNERABILITY) && (curItems & IT_INVULNERABILITY));

    if (gainedQuad || gainedPenta)
    {
        IN_GC_PlayHaptic(GC_HAPTIC_POWERUP_QUAD, 1.0f);
    }
    s_prevItems = curItems;

    // ----------------------------------------------------------------------
    // 5. Item Pickups: Subtle haptic click on acquisition
    // ----------------------------------------------------------------------
    int curBonus = cl.cshifts[CSHIFT_BONUS].percent;
    if (curBonus > s_prevBonus && curBonus >= 20 && !gainedQuad && !gainedPenta)
    {
        IN_GC_PlayHaptic(GC_HAPTIC_ITEM_PICKUP, 0.40f);
    }
    s_prevBonus = curBonus;

    // ----------------------------------------------------------------------
    // 6. Player Damage and Death
    // ----------------------------------------------------------------------
    int curHealth = cl.stats[STAT_HEALTH];

    if (s_prevHealth > 0 && curHealth < s_prevHealth)
    {
        int damage = s_prevHealth - curHealth;

        if (curHealth <= 0)
        {
            // Player death: maximum haptic collapse
            IN_GC_PlayHaptic(GC_HAPTIC_EXPLOSION, 1.0f);
        }
        else if (damage >= 25)
        {
            // Heavy damage (rocket, grenade, or lava damage)
            float strength = (float)damage / 50.0f;
            if (strength > 1.0f) strength = 1.0f;
            IN_GC_PlayHaptic(GC_HAPTIC_EXPLOSION, strength);
        }
        else
        {
            // Kinetic jolt
            float strength = (float)damage / 25.0f;
            if (strength < 0.25f) strength = 0.25f;
            if (strength > 1.0f)  strength = 1.0f;
            IN_GC_PlayHaptic(GC_HAPTIC_DAMAGE, strength);
        }
    }

    s_prevHealth = (curHealth <= 0) ? 0 : curHealth;
}

void IN_GC_PlayHaptic(gc_haptic_type_t type, float strength)
{
    if (!joy_enable.value || !joy_haptics.value || !s_hapticsAvailable)
        return;

    if (@available(macOS 11.0, *))
    {
        if (!s_hapticEngine)
            return;

        if (strength < 0.05f) strength = 0.05f;
        if (strength > 1.0f)  strength = 1.0f;

        NSMutableArray<CHHapticEvent *> *events = [NSMutableArray arrayWithCapacity:3];

        switch (type)
        {
        // -------------------------------------------------------------
        // WEAPONS
        // -------------------------------------------------------------
        case GC_HAPTIC_SHOTGUN:
        {
            // Crisp transient impulse followed by short low-frequency continuous tail
            CHHapticEventParameter *i1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.90f];
            CHHapticEventParameter *s1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.45f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i1, s1] relativeTime:0]];

            CHHapticEventParameter *i2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.40f];
            CHHapticEventParameter *s2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.15f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i2, s2] relativeTime:0.02 duration:0.06]];
            break;
        }

        case GC_HAPTIC_SUPER_SHOTGUN:
        {
            // Double discharge: maximum actuator impulse
            CHHapticEventParameter *i1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f];
            CHHapticEventParameter *s1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.30f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i1, s1] relativeTime:0]];

            CHHapticEventParameter *i2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.75f];
            CHHapticEventParameter *s2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.10f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i2, s2] relativeTime:0.015 duration:0.10]];
            break;
        }

        case GC_HAPTIC_NAIL:
        {
            // Mechanical micro-click (Transient, ultra-sharp 0.95)
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.60f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.95f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i, s] relativeTime:0]];
            break;
        }

        case GC_HAPTIC_ROCKET:
        {
            // Heavy rocket backblast (deep low-frequency continuous rumble)
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.95f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.15f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i, s] relativeTime:0 duration:0.12]];
            break;
        }

        case GC_HAPTIC_LIGHTNING:
        {
            // High-frequency electrical crackle
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.65f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.90f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i, s] relativeTime:0 duration:0.07]];
            break;
        }

        case GC_HAPTIC_AXE:
        {
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.70f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.75f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i, s] relativeTime:0]];
            break;
        }

        // -------------------------------------------------------------
        // LOCOMOTION AND PHYSICS
        // -------------------------------------------------------------
        case GC_HAPTIC_LAND_LIGHT:
        {
            // Soft footstep ground contact
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.35f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.10f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i, s] relativeTime:0]];
            break;
        }

        case GC_HAPTIC_LAND_HARD:
        {
            // Hard kinetic joint compression impact
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength * 0.85f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.55f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i, s] relativeTime:0 duration:0.09]];
            break;
        }

        case GC_HAPTIC_TELEPORT:
        {
            // Spatial rift: sharp transient flash followed by vacuum-like decay
            CHHapticEventParameter *i1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.80f];
            CHHapticEventParameter *s1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.85f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i1, s1] relativeTime:0]];

            CHHapticEventParameter *i2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.60f];
            CHHapticEventParameter *s2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.10f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i2, s2] relativeTime:0.02 duration:0.10]];
            break;
        }

        // -------------------------------------------------------------
        // ITEMS AND POWER-UPS
        // -------------------------------------------------------------
        case GC_HAPTIC_ITEM_PICKUP:
        {
            // Delicate system click (similar to iOS Taptic feedback)
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.35f];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.90f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i, s] relativeTime:0]];
            break;
        }

        case GC_HAPTIC_POWERUP_QUAD:
        {
            // Berserk heartbeat rhythm: double-pulse (lub-dub)
            // 1. Initial pulse
            CHHapticEventParameter *i1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.75f];
            CHHapticEventParameter *s1 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.25f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                                            parameters:@[i1, s1] relativeTime:0]];

            // 2. Secondary powerful systolic thrust after 110 ms
            CHHapticEventParameter *i2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f];
            CHHapticEventParameter *s2 = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.35f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i2, s2] relativeTime:0.11 duration:0.14]];
            break;
        }

        // -------------------------------------------------------------
        // DAMAGE AND EXPLOSIONS
        // -------------------------------------------------------------
        case GC_HAPTIC_DAMAGE:
        {
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.45f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i, s] relativeTime:0 duration:0.08]];
            break;
        }

        case GC_HAPTIC_EXPLOSION:
        {
            // Deep sub-bass blast wave rumble
            CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:strength];
            CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.10f];
            [events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                            parameters:@[i, s] relativeTime:0 duration:0.22]];
            break;
        }
        }

        if (events.count == 0)
            return;

        NSError *err = nil;
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:&err];
        if (pattern)
        {
            id<CHHapticPatternPlayer> player = [s_hapticEngine createPlayerWithPattern:pattern error:&err];
            [player startAtTime:CHHapticTimeImmediate error:&err];
        }
    }
}
