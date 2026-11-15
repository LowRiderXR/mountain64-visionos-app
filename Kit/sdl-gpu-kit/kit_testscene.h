/*
 * kit_testscene.h — SDL_GPU kit for visionOS, test scene stages basic and inject.
 *
 * First stage of the kit: SDL_GPU without patches in a foreign process (SwiftUI app on
 * visionOS, command line on macOS). The scene creates a device and its own texture, runs a
 * clear pass, reads one pixel back and reports every step as a line "[c64-kit] ..." through
 * the log callback. No window, no swapchain.
 *
 * Inject: the same scene with the host's MTLDevice and/or MTLCommandQueue fed in (properties
 * SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER / ..._COMMAND_QUEUE_POINTER from the fork
 * sdl-visionos). Additional steps: pointer comparison host against SDL (step=inject) and after
 * SDL_DestroyGPUDevice an empty command buffer on the host queue (step=hostqueue-after-destroy),
 * which shows that SDL released no foreign reference.
 *
 * The code is platform neutral (SDL3 API only); the Metal helpers for the host are in
 * kit_testscene_metal.m. The kit is not part of SDL: from the inject stage on the scene hangs
 * on the Swift host.
 */

#ifndef KIT_TESTSCENE_H
#define KIT_TESTSCENE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One log line without line ending. Written by the host into the unified log, the progress
 * file or to stdout. */
typedef void (*kit_log_fn)(const char *line, void *user);

typedef struct kit_testscene_options {
    /* true: the scene calls SDL_SetMainReady and SDL_Init(SDL_INIT_VIDEO) itself.
     * false: the host has already initialised SDL (kit_testscene_init_sdl). */
    bool init_sdl;
    /* true: SDL_Quit at the end. On UIKit platforms only meaningful from the main thread. */
    bool quit_sdl;
    /* Create SDL_GPU in debug mode (validation in the backend, slower). */
    bool debug_mode;
    /* Size of the test texture; 0 = 256. */
    int width;
    int height;
    /* Inject: id<MTLDevice> and/or id<MTLCommandQueue> of the host, passed unretained; NULL =
     * SDL creates them itself. The host stays the owner; the scene releases nothing. */
    void *metal_device;
    void *metal_queue;
} kit_testscene_options;

/* Steps in order; the return value of kit_testscene_run names the step at which it failed
 * (0 = all passed). */
enum kit_testscene_step {
    KIT_STEP_OK = 0,
    KIT_STEP_INIT = 1,        /* SDL_Init(SDL_INIT_VIDEO) */
    KIT_STEP_DEVICE = 2,      /* SDL_CreateGPUDeviceWithProperties */
    KIT_STEP_TEXTURE = 3,     /* SDL_CreateGPUTexture */
    KIT_STEP_TRANSFER = 4,    /* SDL_CreateGPUTransferBuffer */
    KIT_STEP_CMDBUF = 5,      /* SDL_AcquireGPUCommandBuffer */
    KIT_STEP_RENDERPASS = 6,  /* SDL_BeginGPURenderPass (Clear) */
    KIT_STEP_COPYPASS = 7,    /* SDL_BeginGPUCopyPass / SDL_DownloadFromGPUTexture */
    KIT_STEP_SUBMIT = 8,      /* SDL_SubmitGPUCommandBufferAndAcquireFence + SDL_WaitForGPUFences */
    KIT_STEP_READBACK = 9,    /* SDL_MapGPUTransferBuffer, pixel comparison */
    KIT_STEP_INJECT = 10,     /* inject: SDL does not use the injected objects */
    KIT_STEP_HOSTQUEUE = 11   /* inject: host queue unusable after SDL_DestroyGPUDevice */
};

/* SDL_SetMainReady + SDL_Init(SDL_INIT_VIDEO), with log line step=init. Call on the main thread
 * on UIKit platforms. Returns false when SDL_Init fails (error text in the line). */
bool kit_testscene_init_sdl(kit_log_fn log, void *user);

/* SDL_Quit, counterpart of kit_testscene_init_sdl. */
void kit_testscene_quit_sdl(void);

/* Runs the scene once. Thread: any, provided SDL_Init has already run; with init_sdl on UIKit
 * platforms the main thread. Returns KIT_STEP_OK or the failed step; the last line
 * "[c64-kit] result=..." summarises. */
int kit_testscene_run(const kit_testscene_options *options, kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_H */
