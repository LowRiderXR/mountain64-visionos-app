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
 * fields you need. Pointers that are NULL are not used. A size that ends after content_root is
 * accepted as well (older hosts); the fields after it then take their defaults. */
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
    /* Internal resolution of the game's world image (0 = 640x360, the original). The game draws
     * its 3D world, HUD and text at this size and scales them with it; the canvas should have the
     * same size, otherwise the image is letterboxed into it. Fixed for the lifetime of the game.
     * At least 640x360, at most 4096x2304, width a multiple of 16, height a multiple of 8;
     * anything else makes celeste_init fail with a text. */
    int32_t internal_width;
    int32_t internal_height;
    /* Width of the outline in the game's edge pass, in pixels of the world image: 1 to 4
     * (0 = 1, the original one-pixel outline). Whole numbers only; a host that offers "auto"
     * resolves it to round(internal_height / 360) itself. */
    int32_t edge_line_width;
    /* 1: reverse-Z depth path for the VR image: Celeste's 3D scenes render with a reverse-Z
     * projection with an infinite far plane (hardware depth = near / distance, as the
     * compositor's drawables expect it), the shader variants without SV_Depth, a float depth
     * target, depth clear 0 and swapped depth compares; the sky dome moves to 3 km. The near
     * plane comes from celeste_set_depth_near. 0: Celeste's own depth convention (reference).
     * Fixed for the lifetime of the game. */
    int32_t reverse_z;
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

/* Foster's window as SDL reports it: logical size (points), size in pixels, pixel density
 * times 1000, and the hidden and fullscreen flags. Valid after celeste_init. */
typedef struct celeste_window_info {
    int32_t size;                 /* sizeof(celeste_window_info) */
    int32_t width;
    int32_t height;
    int32_t pixel_width;
    int32_t pixel_height;
    int32_t pixel_density_x1000;
    int32_t hidden;
    int32_t fullscreen;
} celeste_window_info;

/* Game and runtime version, for example "Celeste 64 v.1.2.0, .NET 10.0.12". */
const char *celeste_version(void);

/* Fills the window info; out->size must match. 0 or -1 (no game: -1). */
int32_t celeste_window_info_get(celeste_window_info *out);

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

/* The same frame in two halves, for a host whose render input (the tracked pose) is only known
 * after the update: celeste_update polls events and runs one update (0, 1 when the game wants to
 * exit, -1); celeste_render_frame renders the state of the last update and submits (present 0)
 * or presents (1) (0 or -1). Call both once per frame, update first, on the same thread. */
int32_t celeste_update(double delta_seconds);
int32_t celeste_render_frame(int32_t present);

/* 1 when the game asked to exit (or no game exists), else 0. */
int32_t celeste_exiting(void);

/* Asks the game to exit as if the player chose Exit: the next celeste_tick returns 1. For a
 * host that wants to exercise its shutdown path without input. 0 or -1. */
int32_t celeste_request_exit(void);

/* Suspends (1) or resumes (0) FMOD's mixer while the app is in the background (the device was
 * taken off): System::mixerSuspend / mixerResume, state and playback position are kept. Call
 * both from the same thread and do not call celeste_tick in between (FMOD requirement). 0 or -1. */
int32_t celeste_audio_suspend(int32_t suspend);

/* Asks the game to pause at its next update (the device was put on again): a running level
 * opens its pause menu, the title and the overworld do nothing. Any thread. 0 or -1. */
int32_t celeste_request_pause(void);

/* Near plane of the reverse-Z projection (reverse_z = 1) in metres: the host reads it from its
 * layer (configuration.defaultDepthRange.y) once the layer exists and passes it here; the game
 * converts it to world units at one place. Until the first call the game uses 0.1 m with one
 * warning line. Call on the ticking thread, before the first update when possible. 0 or -1. */
int32_t celeste_set_depth_near(double near_meters);

/* Stereo world pass (M4b.3a): the frame data for celeste_render_frame_vr. Zero the struct, set
 * size, then the fields. The textures are the host's drawable (compositor), 2D arrays with one
 * layer per view, colour BGRA8Unorm_sRGB (color_srgb 1) or RGBA8Unorm (0), depth Depth32Float;
 * usage must include RenderTarget. The host keeps them alive until the call returns and the
 * game's command buffers completed (the game caches the imports by identity and releases an
 * import after 120 frames unseen, see [c64-import]). The rasterization rate map is the
 * compositor's for the drawable or NULL; logical_* is its screen size and physical_* its
 * physical size of layer 0 (the texture size without a map). projection holds one reverse-Z
 * infinite projection per view, 16 floats each, column-major as simd_float4x4 (the game uses
 * them with its own near plane in world units); view_transform and head_transform the eye and
 * head transforms relative to the host's reference O, culling_projection the binocular culling
 * matrix (all 16 floats column-major as simd_float4x4). The game converts them to its world at
 * one place: axes (x, y, z) -> (x, -z, y), scale (10 units per metre), on the base of its game
 * camera (position and yaw). drew_world and flushes are outputs. */
typedef struct celeste_vr_frame {
    int32_t size;                     /* sizeof(celeste_vr_frame) */
    int32_t view_count;               /* 2 */
    void *color_texture;              /* id<MTLTexture> */
    void *depth_texture;              /* id<MTLTexture> */
    int32_t width;                    /* texture size */
    int32_t height;
    int32_t color_srgb;               /* 1: colour texture is sRGB-encoded */
    int32_t reserved;
    void *rasterization_rate_map;     /* id<MTLRasterizationRateMap> or NULL */
    int32_t logical_width;
    int32_t logical_height;
    int32_t physical_width;
    int32_t physical_height;
    float projection[32];             /* view 0: 0..15, view 1: 16..31 */
    float view_transform[32];         /* O-from-eye per view (M4b.4): inverse(O) * anchor * views[i].transform */
    double near_meters;               /* near plane of the layer in metres (as celeste_set_depth_near) */
    /* Head pose (M4b.4), visionOS space (Y up, -Z forward, metres), relative to the host's
     * reference O (position and yaw of the device anchor when the reference was set): */
    float head_transform[16];         /* O-from-anchor */
    float culling_projection[16];     /* binocular culling matrix (device space to clip, reverse-Z, widened tangents) */
    int32_t origin_reset;             /* 1 in the frame the host set O anew (logged by the game) */
    int32_t reserved2;                /* out: microseconds from the call to the commit of the world pass, 0 without one */
    int32_t drew_world;               /* out: 1 when the world was rendered into the drawable */
    int32_t flushes;                  /* out: command buffer submissions the game made for its passes (2 buffers each) */
} celeste_vr_frame;

/* The render half of a frame with the stereo world pass: a running level renders its 3D world
 * into the drawable (both views in one pass, the compositor's map at the pass) and returns 1;
 * every other scene renders into the canvas as with celeste_render_frame and returns 0 (the
 * host then shows the canvas and clears the drawable itself). -1 on failure. Call once per
 * frame after celeste_update, on the same thread. Needs reverse_z = 1 at celeste_init. */
int32_t celeste_render_frame_vr(celeste_vr_frame *frame);

/* Canvas (M4a, variant a): the game renders its final image into a texture the host owns
 * instead of the hidden window. mtl_texture is an id<MTLTexture> on the device the game's
 * SDL_GPU device uses: type 2D, pixel format RGBA8Unorm (the game's output is not sRGB-encoded
 * by Metal; sample it through an sRGB view if you need that), usage RenderTarget | ShaderRead,
 * one mip level, one sample, hazard tracking on (the default). width and height must match the
 * texture; any size up to the device's maximum is accepted, the game letterboxes its 16:9
 * world image into it. The game writes the texture during celeste_tick on the ticking thread;
 * call this and celeste_clear_canvas from that thread or while no tick runs. The host keeps
 * the texture alive until celeste_clear_canvas returns. 0 or -1 (celeste_last_error names the
 * mismatch). Needs the SDL_GPU kit (capability external_textures). */
int32_t celeste_set_canvas(void *mtl_texture, int32_t width, int32_t height);

/* Back to the hidden window; releases the game's reference to the canvas texture. 0 or -1. */
int32_t celeste_clear_canvas(void);

/* Shuts the game down and releases SDL. 0 or -1. */
int32_t celeste_end(void);

/* Text of the last failure (UTF-8), or an empty string. */
const char *celeste_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* CELESTE_VISIONOS_H */
