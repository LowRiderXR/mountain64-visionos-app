/*
 * kit_main.c — command line run of the kit test scene on macOS (basic, inject, import and the
 * multiview self-tests).
 *
 * Same code as on the device (kit_testscene.c, kit_import.c, kit_multiview.c), against
 * Frameworks/macos/libSDL3.0.dylib from scripts/build-sdl3.sh. Output: the [c64-kit] lines on
 * stdout, exit code = failed step (0 = passed). Invoked through run-mac.sh.
 *
 *   kit-testscene [--debug] [--size N] [--inject | --inject-device | --inject-queue | --import | --multiview | --foveation | --msaa | --depth-store]
 *
 *   --inject         give the runner's device and queue to SDL (both properties)
 *   --inject-device  only the device; SDL creates its own queue on it
 *   --inject-queue   only the queue; SDL takes over its device
 *   --import         import own 2D array textures, clear per layer, read back, negative tests
 *   --multiview      one pass with view_count 2
 *   --foveation      own rate map on the pass
 *   --msaa           MSAA 4x with resolve of colour and depth under multiview and map
 *   --depth-store    depth resolve with view_count 2 with stored MSAA samples
 *                    (store_op STORE against DONT_CARE), depth probe of both layers
 */

#include "../kit_testscene.h"
#include "../kit_testscene_metal.h"
#include "../kit_import.h"
#include "../kit_multiview.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void log_stdout(const char *line, void *user)
{
    (void)user;
    puts(line);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    kit_testscene_options opt;
    memset(&opt, 0, sizeof(opt));
    opt.init_sdl = true;
    opt.quit_sdl = true;
    bool want_device = false;
    bool want_queue = false;
    bool want_import = false;
    bool want_multiview = false;
    bool want_foveation = false;
    bool want_msaa = false;
    bool want_depth_store = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0) {
            opt.debug_mode = true;
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            opt.width = opt.height = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--inject") == 0) {
            want_device = want_queue = true;
        } else if (strcmp(argv[i], "--inject-device") == 0) {
            want_device = true;
        } else if (strcmp(argv[i], "--inject-queue") == 0) {
            want_queue = true;
        } else if (strcmp(argv[i], "--import") == 0) {
            want_import = true;
        } else if (strcmp(argv[i], "--multiview") == 0) {
            want_multiview = true;
        } else if (strcmp(argv[i], "--foveation") == 0) {
            want_foveation = true;
        } else if (strcmp(argv[i], "--msaa") == 0) {
            want_msaa = true;
        } else if (strcmp(argv[i], "--depth-store") == 0) {
            want_depth_store = true;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (want_import || want_multiview || want_foveation || want_msaa || want_depth_store) {
        /* Self-tests: SDL_Init here as on the device on the main thread, then the test with its own objects. */
        if (!kit_testscene_init_sdl(log_stdout, NULL)) {
            return 1;
        }
        const int rc = want_depth_store ? kit_multiview_depth_store_selftest(log_stdout, NULL)
                     : want_msaa ? kit_multiview_msaa_selftest(log_stdout, NULL)
                     : want_foveation ? kit_multiview_foveation_selftest(log_stdout, NULL)
                     : want_multiview ? kit_multiview_selftest(log_stdout, NULL)
                                      : kit_import_selftest(log_stdout, NULL, opt.debug_mode);
        kit_testscene_quit_sdl();
        return rc;
    }

    void *host_device = NULL;
    void *host_queue = NULL;
    if (want_device || want_queue) {
        if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
            fprintf(stderr, "Host device or queue could not be created\n");
            return 65;
        }
        char name[128];
        printf("[c64-kit] host device=%p queue=%p name=\"%s\" give=%s\n", host_device, host_queue,
               kit_metal_device_name(host_device, name, sizeof(name)),
               (want_device && want_queue) ? "device+queue" : (want_device ? "device" : "queue"));
        opt.metal_device = want_device ? host_device : NULL;
        opt.metal_queue = want_queue ? host_queue : NULL;
    }

    const int rc = kit_testscene_run(&opt, log_stdout, NULL);

    if (host_device || host_queue) {
        /* After SDL_DestroyGPUDevice the host references must still be valid; the release here
         * is the last one. A crash at this point would mean: SDL released too much. */
        kit_metal_release_host_objects(host_device, host_queue);
        printf("[c64-kit] host objects released ok=1\n");
    }
    return rc;
}
