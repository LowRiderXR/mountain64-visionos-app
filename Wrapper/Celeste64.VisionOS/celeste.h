/*
 * celeste.h: C interface of Celeste64.VisionOS, the Native AOT library that wraps Celeste 64 for
 * a visionOS host. The host embeds Celeste64.VisionOS.framework together with SDL3.framework
 * (SDL_GPU kit for visionOS) and FMOD.framework and drives the game with its own clock:
 *
 *   celeste_version();                        // smoke test, no SDL yet
 *   celeste_init(&options);                   // main thread: SDL, window (hidden), game, Startup
 *   while (!celeste_exiting())
 *       celeste_tick(delta_seconds, 0);       // one update and one render per call
 *   celeste_end();
 *
 * Every function returns 0 on success, 1 when the game asked to exit (celeste_tick), and -1 on
 * failure; celeste_last_error() then describes the failure. No exception crosses this boundary.
 * Strings returned by the library stay valid until the next call of the same function (version:
 * for the lifetime of the process).
 */

#ifndef CELESTE_VISIONOS_H
#define CELESTE_VISIONOS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Options for celeste_init. Zero the struct, set size to sizeof(celeste_init_options), then the
 * fields you need. Pointers that are NULL are not used. */
typedef struct celeste_init_options {
    int32_t size;                 /* sizeof(celeste_init_options), for versioning */
    int32_t hidden_window;        /* 1: SDL window stays hidden (the host shows the image) */
    int32_t depth_clip;           /* 1: depth clip instead of clamp (on visionOS always on) */
    int32_t reserved;
    void *metal_device;           /* id<MTLDevice> the SDL_GPU device is created on, or NULL */
    void *metal_command_queue;    /* id<MTLCommandQueue> for SDL's command buffers, or NULL */
    void *completed_callback;     /* void (*)(void *userdata, void *mtl_command_buffer), or NULL */
    void *completed_userdata;
    const char *content_root;     /* UTF-8 directory that contains "Content/"; required */
} celeste_init_options;

/* Capabilities of the loaded SDL as Foster reports them. kit_sdl_loaded is probed by export name
 * and is available before celeste_init; the other fields are 0 until the device exists. */
typedef struct celeste_capabilities {
    int32_t size;                 /* sizeof(celeste_capabilities) */
    int32_t kit_sdl_loaded;
    int32_t kit_exports;
    int32_t multi_view;
    int32_t pass_properties;
    int32_t external_textures;
    int32_t memoryless;
    int32_t depth_resolve;
} celeste_capabilities;

/* Game and runtime version, for example "Celeste 64 v.1.2.0, .NET 10.0.12". */
const char *celeste_version(void);

/* Log line from the game, Foster or SDL: level 0 info, 1 warning, 2 error; utf8 is
 * NUL-terminated and valid only during the call. May be called from any thread. */
typedef void (*celeste_log_fn)(int32_t level, const char *utf8, void *userdata);

/* Routes the game's log to the host. Call before celeste_init to see the startup lines; NULL
 * restores the default output (stdout). 0 or -1. */
int32_t celeste_set_log_callback(celeste_log_fn fn, void *userdata);

/* Fills the capabilities; options->size must match. 0 or -1. */
int32_t celeste_capabilities_get(celeste_capabilities *out);

/* Creates the game: SDL_SetMainReady, SDL_Init, the (hidden) window, the SDL_GPU device on the
 * given Metal objects, Celeste's Startup. Call on the main thread. 0 or -1. */
int32_t celeste_init(const celeste_init_options *options);

/* One frame: polls events, runs one update with delta_seconds, renders; present 0 only submits
 * the GPU work, 1 also presents to the window. 0, 1 when the game wants to exit, -1 on failure. */
int32_t celeste_tick(double delta_seconds, int32_t present);

/* 1 when the game asked to exit (or no game exists), else 0. */
int32_t celeste_exiting(void);

/* Shuts the game down and releases SDL. 0 or -1. */
int32_t celeste_end(void);

/* Text of the last failure (UTF-8), or an empty string. */
const char *celeste_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* CELESTE_VISIONOS_H */
