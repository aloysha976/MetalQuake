//
//  MetalBridge.h
//  MetalQuake
//
//  Copyright © 2026 Alexey Chernyak
//  SPDX-License-Identifier: GPL-2.0-or-later
//

#ifndef MetalBridge_h
#define MetalBridge_h

#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
// Map C SIMD types to Metal Shading Language types
typedef float4x4 simd_float4x4;
typedef float4   simd_float4;
typedef float3   simd_float3;
typedef float2   simd_float2;
#else
#include <simd/simd.h>
#include <stdbool.h>
#include <stdint.h>
#endif

// Buffer indices for Metal shaders
typedef enum MetalBufferIndex {
    BufferIndexVertices = 0,
    BufferIndexUniforms = 1
} MetalBufferIndex;

// Texture slot indices
typedef enum MetalTextureIndex {
    TextureIndexBase     = 0,
    TextureIndexLightmap = 1,
    TextureIndexNormal   = 2,
    TextureIndexRMAO     = 3,
    TextureIndexEmission = 4
} MetalTextureIndex;

// Per-frame global uniforms
typedef struct {
    simd_float4x4 projectionMatrix;
    simd_float4x4 modelViewMatrix;
    simd_float4   fogColor;
    float         fogDensity;
    float         time;
    int           useTexture;
    int           useFullbright;
    int           useGlow;        // 1 = additive fullbright mask bound to slot 1
} FrameUniforms;

// 2D UI vertex structure
typedef struct {
    simd_float3 position;
    simd_float2 texCoord;
    simd_float2 lightmapCoord;
    simd_float4 color;
} MetalVertex;

// 3D world vertex with pre-baked plane normal and tangent vector (80 bytes, 16-byte aligned)
typedef struct {
    simd_float3 position;       // 16 bytes (offset 0)
    simd_float3 normal;         // 16 bytes (offset 16)
    simd_float4 tangent;        // 16 bytes (offset 32): xyz = tangent U in world space, w = handedness (+1.0 / -1.0)
    simd_float2 texCoord;       // 8 bytes  (offset 48)
    simd_float2 lightmapCoord;  // 8 bytes  (offset 56)
    simd_float4 color;          // 16 bytes (offset 64)
} MetalWorldVertex;

// Compact particle instance (32 bytes, strictly 16-byte aligned for C and Metal)
typedef struct {
    simd_float4 posAndSize;     // xyz = world position, w = scale / size
    simd_float4 color;          // rgba = particle color
} MetalParticleInstance;

// Billboarding and camera parameters for the particle shader (128 bytes)
typedef struct {
    simd_float4x4 mvpMatrix;    // Frame camera MVP matrix
    simd_float4   cameraOrigin; // xyz = camera position (r_origin)
    simd_float4   cameraVPN;    // xyz = view plane normal (view forward axis)
    simd_float4   cameraRight;  // xyz = camera right vector * 1.5
    simd_float4   cameraUp;     // xyz = camera up vector * 1.5
} ParticleUniforms;

// 3D function prototypes
void R_Metal_Init3DPipeline(void);
simd_float4x4 R_Metal_ComputeMVP(float fovY, float aspect, float zNear, float zFar,
                                 simd_float3 origin, simd_float3 angles);


// =======================================================
// C PROTOTYPES (Ignored during Metal shader compilation)
// =======================================================
#ifndef __METAL_VERSION__

#ifdef __cplusplus
extern "C" {
#endif

// 2D UI & Ortho Setup
void R_Metal_SetOrtho(float left, float right, float bottom, float top);
void R_Metal_Flush2D(void);
// Returns true when HUD is deferred to the overlay pass; mid-frame 2D flushes disallowed
bool MQ_Renderer_DeferUIActive(void);
// Overrides the UI pipeline state for the post-FX overlay pass (nil restores default)
void R_Metal_SetUIPipelineOverride(void *pipelineState);

// Core & Window Lifecycle
void R_Metal_Init(void);
void R_Metal_SetLayer(void *layer);
void R_Metal_BeginFrame(void);
void R_Metal_EndFrame(void);

// 2D Canvas & UI
void R_Metal_Draw2DQuad(float x, float y, float w, float h,
                        float s1, float t1, float s2, float t2,
                        simd_float4 color, void *metalTexture);
void R_Metal_SetCanvas(float left, float right, float bottom, float top,
                       float vpX, float vpY, float vpW, float vpH);

// 2D canvas scaling diagnostics: retrieves the state of the active canvas.
// ortho[4] = left, right, bottom, top (units); vp[4] = x, y, width, height (physical pixels).
void R_Metal_GetCanvasState(float *ortho, float *vp);

// Fullscreen unlit alpha-blended quad: screen flash for damage, bonus pickups, and liquid tint (V_PolyBlend).
// Renders immediately, bypassing the 2D batch and resetting encoder canvas state.
void R_Metal_DrawFullscreenColorQuad(float r, float g, float b, float a);

// Texture Management
void *R_Metal_CreateTexture(int width, int height, const void *rgbaData);
// Creates texture with debug label: all-black texture warning is suppressed for valid dark textures (*_glow, 'black')
void *R_Metal_CreateTextureEx(int width, int height, const void *rgbaData, const char *dbgName);
void R_Metal_FreeTexture(void *texHandle);
void *R_GetLightmapTextureHandle(int lightmapnum);
void R_Metal_BindTexture2D(void *metalTexture);

// Subregion update from CPU memory to shared Metal textures (RGBA8): used for dynamic lightmap uploads.
// Direct memory copy on shared storage avoids GPU pipeline stalls and texture reallocations.
void R_Metal_UpdateTextureRegion(void *texHandle, int x, int y, int width, int height,
                                 const void *data, int bytesPerRow);

// 3D Rendering & Matrix Math
simd_float4x4 R_Metal_ComputeMVP(float fovY, float aspect, float zNear, float zFar,
                                 simd_float3 origin, simd_float3 angles);

// Blending modes for 3D geometry and special effects
typedef enum {
    METAL_BLEND_OPAQUE   = 0, // Opaque world geometry and models (depth writes enabled)
    METAL_BLEND_ALPHA    = 1, // Standard alpha blending (water surfaces, decals, sprites)
    METAL_BLEND_ADDITIVE = 2  // Additive blending (explosions, fire, glowing particles)
} MetalBlendMode;

void R_Metal_Draw3DPolygons(MetalWorldVertex *vertices, uint32_t vertexCount,
                            simd_float4x4 mvpMatrix,
                            void *diffuseTexture, void *lightmapTexture,
                            int blendMode, bool isTurbulent,
                            const char *tag);

// Instanced particle rendering: single draw call using a GPU-generated procedural quad
void R_Metal_DrawParticlesInstanced(const MetalParticleInstance *instances,
                                    uint32_t count,
                                    simd_float4x4 mvpMatrix,
                                    simd_float3 camOrigin,
                                    simd_float3 camVPN,
                                    simd_float3 camRight,
                                    simd_float3 camUp,
                                    void *particleTexture);

// Flushes and renders the accumulated world sprite batch (.spr)
void R_Sprite_Flush(void);

// Monolithic static BSP world rendering in a single draw call via bindless textures
void R_Metal_Draw3DWorldBindless(const uint32_t *indices, uint32_t indexCount,
                                 simd_float4x4 mvpMatrix,
                                 void * const *diffuseTextures, uint32_t numDiffuse,
                                 void * const *lightmapTextures, uint32_t numLightmaps,
                                 const char *tag);

// Renders baked world geometry via static VBO and dynamic IBO
void R_Metal_Draw3DWorldIndexed(const uint32_t *indices, uint32_t indexCount,
                                simd_float4x4 mvpMatrix,
                                void *diffuseTexture, void *lightmapTexture,
                                int blendMode, bool isTurbulent,
                                const char *tag);


void R_Metal_SetGunDepthRange(bool gunDepth);
void R_Metal_SetPolygonOffset(int offset);

// Volumetric fog parameters and camera position for world_fragment_main.
// Called once per frame from R_SetupView (gl_rmain.c); density matches glFogf semantics (/64), 0 = disabled.
void R_Metal_SetFogState(float r, float g, float b, float density,
                         float camX, float camY, float camZ);

// Dynamic point lights for per-pixel lighting in world_fragment_main.
// packed: count * 8 floats — x, y, z, radius, r, g, b, 0 (Quake coordinates).
// Called once per frame from R_GatherPerPixelDlights (gl_rmain.c); count is clamped to 32.
// NULL or 0 clears the light array. Resets per-pixel eligibility flag to true.
void R_Metal_SetFrameDlights(const float *packed, int count);

// Controls per-pixel lighting eligibility for subsequent draw calls.
// false = brush model geometry (model space) -> shader receives numDlights = 0, falls back to lightmaps.
// true = static world geometry (world space).
void R_Metal_EnablePerPixelDlights(bool enable);

void R_Metal_GetAppTitle(char *outTitle, size_t maxLen);
// Configures native window properties from NSWindow handle
void R_Metal_ConfigureNativeWindow(void *nativeWindowHandle, const char *title);

// Activates application and game window (makeKeyAndOrderFront)
void R_Metal_ActivateGameWindow(void);


#ifdef __cplusplus
}
#endif

#endif // __METAL_VERSION__

#endif /* MetalBridge_h */
