/*
 * kit_import.h — SDL_GPU kit for visionOS, import stage: external textures.
 *
 * Imports MTLTextures of the host (colour and depth of a compositor drawable) as
 * SDL_GPUTexture through SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER (fork sdl-visionos)
 * and clears all layers through SDL_GPU, one render pass per layer. The wrappers are created
 * per frame and released after the submit (SDL destroys them deferred once the command buffer
 * is complete; the wrappers are therefore safe to release right after the submit).
 *
 * Order with the present: SDL commits its command buffer synchronously on the shared queue;
 * the host commits its buffer with encodePresent afterwards. MTLCommandQueue is a serial queue,
 * execution in commit order (MTLCommandQueue.h, MTLCommandBuffer.h).
 */

#ifndef KIT_IMPORT_H
#define KIT_IMPORT_H

#include <stdbool.h>

#include "kit_testscene.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kit_import_session kit_import_session;

typedef struct kit_import_stats {
    /* window values since the last kit_import_take_stats */
    unsigned frames;
    unsigned fails;
    double sum_ms;          /* CPU time of the SDL part (wrappers, passes, submit, release) */
    double max_ms;
    /* totals since kit_import_begin */
    unsigned long frames_total;
    unsigned long fails_total;
    unsigned long wrappers_created;
    unsigned long wrappers_released;
    unsigned distinct_color;    /* distinct MTLTexture pointers the host has passed so far */
    unsigned distinct_depth;
} kit_import_stats;

/* Create the SDL_GPU device on the host's device and queue. SDL_Init(VIDEO) must already have
 * run (kit_testscene_init_sdl on the main thread). NULL on error (FAIL line). */
kit_import_session *kit_import_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user);

/* Diagnostics (black image despite fails=0): wait = wait for the fence after every submit
 * before the host commits (separates GPU order from "the pass writes nothing"); verify_every =
 * every N frames read the centre pixel of layer 0 of the imported colour texture back through
 * SDL and log it (0 = off; forces the wait for that frame). */
void kit_import_set_diagnostics(kit_import_session *session, bool wait_for_gpu, unsigned verify_every);

/* If kit_import_clear_frame read the centre pixel back in this frame, returns the four bytes
 * (memory order, for BGRA8 b,g,r,a) and true; the host then reads the same spot again right
 * before encodePresent. Resets the flag. */
bool kit_import_last_verify(kit_import_session *session, unsigned char out[4]);

/* Import the frame's colour and depth texture and clear all layers (colour rgba, depth depth),
 * commit the command buffer, release the wrappers. false when a step fails; the host then
 * clears itself. Logs step=import on the first call and step=import-rotation on new texture
 * pointers (first 600 frames). Errors are logged at most once per second. */
bool kit_import_clear_frame(kit_import_session *session, void *color_texture, void *depth_texture,
                            const float rgba[4], float depth);

/* Read and reset the window values; totals stay. */
void kit_import_take_stats(kit_import_session *session, kit_import_stats *out);

/* Wait for the GPU, destroy the device, log the summary (step=import-end). */
void kit_import_end(kit_import_session *session);

/* Mac self-test: own device and queue, two 2D array textures with 2 layers (bgra8Unorm_srgb,
 * depth32Float), import, one clear pass per layer with different colour and depth, read both
 * layers back and compare, then negative tests (wrong format, wrong layer count must fail with
 * an error text). SDL_Init must have run. 0 = passed, otherwise step number from 20. */
int kit_import_selftest(kit_log_fn log, void *user, bool debug_mode);

#ifdef __cplusplus
}
#endif

#endif /* KIT_IMPORT_H */
