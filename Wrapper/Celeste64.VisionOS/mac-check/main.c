/*
 * mac-check/main.c: drives the Celeste64.VisionOS library built for macOS the way the visionOS
 * host will drive the framework: dlopen, celeste_version, capabilities before and after
 * celeste_init, celeste_init with a hidden window on a host Metal device and queue, ticks
 * without presenting, the canvas (the game renders into a host texture, read back on the same
 * queue), back to the window, celeste_end. Built and run by scripts/build-game.sh mac-check,
 * together with Tools/Celeste64.MacHost/native/k6d_metal.m for the Metal objects.
 *
 *   mac-check <path to Celeste64.VisionOS.dylib> <content root> [--dump <base path>]
 *             [--res <W>x<H>] [--line <1..4>|auto]
 *   mac-check <path to Celeste64.VisionOS.dylib> <content root> --bad-options
 *   mac-check <path to Celeste64.VisionOS.dylib> --bad-content
 *
 * --res sets the game's internal resolution (celeste_init_options.internal_width/height) and
 * --line the outline width (edge_line_width; auto = round(height / 360)). The canvas has the
 * same size as the internal resolution, except at 640x360, where it stays 1280x800 (the 16:10
 * canvas letterboxes the 16:9 image, which the run checks); without --res the defaults apply.
 * --bad-options drives celeste_init with invalid resolutions, an invalid line width and a wrong
 * struct size (each must return -1 with a text), then with the struct size of an older host
 * (must succeed with the defaults). --bad-content passes a content root that does not exist:
 * celeste_init must return -1 with a text in celeste_last_error instead of crashing. --dump
 * writes the canvas after the first canvas ticks as <base>.png and <base>.rgba (reference for
 * scripts/compare-canvas.py against the dump the device writes). Before celeste_end the run
 * asks the game to exit (celeste_request_exit); the next tick must return 1. Exit code 0 when
 * every check passes.
 */

#include <dlfcn.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../celeste.h"

/* Tools/Celeste64.MacHost/native/k6d_metal.m */
void *k6d_metal_device(void);
void *k6d_metal_queue(void *device);
void *k6d_metal_texture_2d(void *device, unsigned width, unsigned height, int pixel_format_view);
int k6d_metal_read_pixel(void *queue, void *texture, unsigned x, unsigned y, unsigned char out[4]);
int k6d_metal_write_canvas(void *queue, void *texture, const char *png_path, const char *raw_path, double mean_rgb[3]);
void k6d_metal_release(void *object);

#define TICKS_WINDOW 60     /* ticks into the hidden window: Startup loads in tick 5, title after the wipe */
#define TICKS_CANVAS 548    /* ticks into the canvas before the first read-back and the dump: game frame 608,
                               the same frame at which the device writes its dump (8 main-thread ticks plus
                               600 on the render thread), so the title screen is in the same state */
#define TICKS_CANVAS_2 30   /* more canvas ticks before the second read-back (does the image change?) */
#define TICKS_AFTER 30      /* ticks after celeste_clear_canvas (the canvas must not change any more) */
#define HZ 90.0
/* Default canvas with a 16:10 shape, so the game's 16:9 image is letterboxed: bars of 40 rows top
   and bottom. With --res the canvas takes the internal resolution (640x360 keeps this default). */
#define CANVAS_W 1280
#define CANVAS_H 800
#define TICKS_OLD_SIZE 8    /* ticks of the run with the older struct size (--bad-options) */

typedef const char *(*version_fn)(void);
typedef int32_t (*set_log_fn)(celeste_log_fn, void *);

/* Receives the game's log lines; the prefix shows that they came through the callback. */
static void on_log(int32_t level, const char *utf8, void *userdata)
{
    (void)userdata;
    printf("[log %d] %s\n", level, utf8 ? utf8 : "(null)");
}
typedef int32_t (*capabilities_fn)(celeste_capabilities *);
typedef int32_t (*window_info_fn)(celeste_window_info *);
typedef int32_t (*init_fn)(const celeste_init_options *);
typedef int32_t (*tick_fn)(double, int32_t);
typedef int32_t (*exiting_fn)(void);
typedef int32_t (*end_fn)(void);
typedef int32_t (*set_canvas_fn)(void *, int32_t, int32_t);
typedef int32_t (*clear_canvas_fn)(void);
typedef const char *(*last_error_fn)(void);

static void *require(void *handle, const char *name)
{
    void *symbol = dlsym(handle, name);
    if (symbol == NULL) {
        fprintf(stderr, "dlsym(%s) failed: %s\n", name, dlerror());
    }
    return symbol;
}

static void print_capabilities(const char *when, const celeste_capabilities *c)
{
    printf("mac-check: capabilities %s: kitSdlLoaded=%d kitExports=%d multiView=%d passProperties=%d externalTextures=%d memoryless=%d depthResolve=%d\n",
           when, c->kit_sdl_loaded, c->kit_exports, c->multi_view, c->pass_properties, c->external_textures, c->memoryless, c->depth_resolve);
}

/* Runs count ticks; returns the number of ticks with rc 0 or 1, -1 on the first failure. */
static int run_ticks(tick_fn celeste_tick, last_error_fn celeste_last_error, int count, const char *label, int *exit_count)
{
    int ok = 0;
    for (int i = 0; i < count; i++) {
        int32_t t = celeste_tick(1.0 / HZ, 0);
        if (t == -1) {
            fprintf(stderr, "celeste_tick %s %d failed: %s\n", label, i, celeste_last_error());
            return -1;
        }
        if (t == 1) (*exit_count)++;
        ok++;
    }
    return ok;
}

static int nonblack(const unsigned char p[4])
{
    return p[0] != 0 || p[1] != 0 || p[2] != 0;
}

/* One celeste_init that must fail: rc -1 and a text. Returns 1 when it behaved. */
static int expect_init_failure(init_fn celeste_init, last_error_fn celeste_last_error, const celeste_init_options *options, const char *label)
{
    int32_t rc = celeste_init(options);
    const char *error = celeste_last_error();
    printf("mac-check: celeste_init %s: rc=%d last_error=\"%s\"\n", label, rc, error ? error : "(null)");
    if (rc != -1 || error == NULL || error[0] == '\0') {
        fprintf(stderr, "expected rc=-1 and an error text for %s\n", label);
        return 0;
    }
    return 1;
}

/* Invalid options one by one, then the struct size of an older host with the defaults. */
static int run_bad_options(init_fn celeste_init, tick_fn celeste_tick, end_fn celeste_end, last_error_fn celeste_last_error, const celeste_init_options *base)
{
    celeste_init_options o = *base;
    int ok = 1;

    o = *base; o.internal_width = 641; o.internal_height = 360;
    ok &= expect_init_failure(celeste_init, celeste_last_error, &o, "with 641x360 (width not a multiple of 16)");
    o = *base; o.internal_width = 1920; o.internal_height = 1080; o.edge_line_width = 5;
    ok &= expect_init_failure(celeste_init, celeste_last_error, &o, "with line width 5");
    o = *base; o.internal_width = 4112; o.internal_height = 2304;
    ok &= expect_init_failure(celeste_init, celeste_last_error, &o, "with 4112x2304 (above the maximum)");
    o = *base; o.internal_width = 640; o.internal_height = 352;
    ok &= expect_init_failure(celeste_init, celeste_last_error, &o, "with 640x352 (below the minimum)");
    o = *base; o.size = 40;
    ok &= expect_init_failure(celeste_init, celeste_last_error, &o, "with size 40");
    if (!ok) {
        return 0;
    }

    /* Older host: the struct ends after content_root; the game must start with 640x360 and line 1. */
    o = *base;
    o.size = (int32_t)offsetof(celeste_init_options, internal_width);
    o.internal_width = 1920; o.internal_height = 1080; o.edge_line_width = 4;   /* beyond size: must be ignored */
    int32_t rc = celeste_init(&o);
    printf("mac-check: celeste_init with the older size %d: rc=%d%s%s\n", o.size, rc, rc ? " " : "", rc ? celeste_last_error() : "");
    if (rc != 0) {
        return 0;
    }
    int exits = 0;
    int n = run_ticks(celeste_tick, celeste_last_error, TICKS_OLD_SIZE, "older size", &exits);
    rc = celeste_end();
    printf("mac-check: older size: ticks ok=%d of %d, celeste_end rc=%d\n", n, TICKS_OLD_SIZE, rc);
    return n == TICKS_OLD_SIZE && rc == 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <path to Celeste64.VisionOS.dylib> (<content root> [--dump <base>] [--res <W>x<H>] [--line <N>|auto] [--bad-options] | --bad-content)\n", argv[0]);
        return 64;
    }
    /* Options after the content root. */
    const char *dump_base = NULL;
    int res_w = 0, res_h = 0, line = 0, bad_options = 0, line_auto = 0;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--dump") == 0 && i + 1 < argc) {
            dump_base = argv[++i];
        } else if (strcmp(argv[i], "--res") == 0 && i + 1 < argc) {
            if (sscanf(argv[++i], "%dx%d", &res_w, &res_h) != 2) {
                fprintf(stderr, "--res expects <W>x<H>\n");
                return 64;
            }
        } else if (strcmp(argv[i], "--line") == 0 && i + 1 < argc) {
            i++;
            if (strcmp(argv[i], "auto") == 0) line_auto = 1; else line = atoi(argv[i]);
        } else if (strcmp(argv[i], "--bad-options") == 0) {
            bad_options = 1;
        } else {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            return 64;
        }
    }
    if (line_auto) {
        line = res_h > 0 ? (int)lround(res_h / 360.0) : 1;
    }
    /* Canvas: the internal resolution, except for the default 640x360 (letterboxed 1280x800). */
    int canvas_w = CANVAS_W, canvas_h = CANVAS_H;
    if (res_w > 0 && !(res_w == 640 && res_h == 360)) {
        canvas_w = res_w;
        canvas_h = res_h;
    }
    int letterboxed = canvas_w * 9 != canvas_h * 16;
    /* Line buffering keeps this program's lines in order with the game's log when stdout is a file. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }
    version_fn celeste_version = (version_fn)require(handle, "celeste_version");
    set_log_fn celeste_set_log_callback = (set_log_fn)require(handle, "celeste_set_log_callback");
    capabilities_fn celeste_capabilities_get = (capabilities_fn)require(handle, "celeste_capabilities_get");
    window_info_fn celeste_window_info_get = (window_info_fn)require(handle, "celeste_window_info_get");
    init_fn celeste_init = (init_fn)require(handle, "celeste_init");
    tick_fn celeste_tick = (tick_fn)require(handle, "celeste_tick");
    exiting_fn celeste_exiting = (exiting_fn)require(handle, "celeste_exiting");
    exiting_fn celeste_request_exit = (exiting_fn)require(handle, "celeste_request_exit");
    end_fn celeste_end = (end_fn)require(handle, "celeste_end");
    set_canvas_fn celeste_set_canvas = (set_canvas_fn)require(handle, "celeste_set_canvas");
    clear_canvas_fn celeste_clear_canvas = (clear_canvas_fn)require(handle, "celeste_clear_canvas");
    last_error_fn celeste_last_error = (last_error_fn)require(handle, "celeste_last_error");
    if (!celeste_version || !celeste_set_log_callback || !celeste_capabilities_get || !celeste_window_info_get || !celeste_init || !celeste_tick || !celeste_exiting || !celeste_request_exit || !celeste_end || !celeste_set_canvas || !celeste_clear_canvas || !celeste_last_error) {
        return 2;
    }
    if (celeste_set_log_callback(on_log, NULL) != 0) {
        fprintf(stderr, "celeste_set_log_callback failed: %s\n", celeste_last_error());
        return 9;
    }

    const char *version = celeste_version();
    if (version == NULL || version[0] == '\0') {
        fprintf(stderr, "celeste_version returned an empty string\n");
        return 3;
    }
    printf("mac-check: celeste_version: %s\n", version);
    if (celeste_version() != version) {
        fprintf(stderr, "celeste_version is not stable across calls\n");
        return 4;
    }

    celeste_capabilities caps;
    memset(&caps, 0, sizeof(caps));
    caps.size = sizeof(caps);
    if (celeste_capabilities_get(&caps) != 0) {
        fprintf(stderr, "celeste_capabilities_get failed: %s\n", celeste_last_error());
        return 5;
    }
    print_capabilities("before init", &caps);

    celeste_init_options options;
    memset(&options, 0, sizeof(options));
    options.size = sizeof(options);
    options.hidden_window = 1;

    if (strcmp(argv[2], "--bad-content") == 0) {
        options.content_root = "/nonexistent/celeste-content-root";
        int32_t rc = celeste_init(&options);
        const char *error = celeste_last_error();
        printf("mac-check: celeste_init with bad content root: rc=%d last_error=\"%s\"\n", rc, error ? error : "(null)");
        if (rc != -1 || error == NULL || error[0] == '\0') {
            fprintf(stderr, "expected rc=-1 and an error text\n");
            return 6;
        }
        printf("mac-check: error case ok\n");
        return 0;
    }

    /* Host device and queue, as the visionOS host hands them to celeste_init (M1a.4). The canvas
       is created on the same device, and the read-back runs on the same queue. */
    void *device = k6d_metal_device();
    void *queue = device ? k6d_metal_queue(device) : NULL;
    if (!device || !queue) {
        fprintf(stderr, "no Metal device or queue\n");
        return 11;
    }
    options.metal_device = device;
    options.metal_command_queue = queue;
    options.content_root = argv[2];
    if (bad_options) {
        int ok = run_bad_options(celeste_init, celeste_tick, celeste_end, celeste_last_error, &options);
        k6d_metal_release(queue);
        k6d_metal_release(device);
        printf("mac-check: bad options %s\n", ok ? "ok" : "FAILED");
        return ok ? 0 : 18;
    }
    options.internal_width = res_w;
    options.internal_height = res_h;
    options.edge_line_width = line;
    printf("mac-check: requested internal=%dx%d line=%d (0 = default), canvas=%dx%d%s\n", res_w, res_h, line, canvas_w, canvas_h, letterboxed ? " (letterboxed)" : "");
    int32_t rc = celeste_init(&options);
    if (rc != 0) {
        fprintf(stderr, "celeste_init failed: rc=%d %s\n", rc, celeste_last_error());
        return 7;
    }
    if (celeste_capabilities_get(&caps) != 0) {
        fprintf(stderr, "celeste_capabilities_get after init failed: %s\n", celeste_last_error());
        return 5;
    }
    print_capabilities("after init", &caps);

    celeste_window_info win;
    memset(&win, 0, sizeof(win));
    win.size = sizeof(win);
    if (celeste_window_info_get(&win) != 0) {
        fprintf(stderr, "celeste_window_info_get failed: %s\n", celeste_last_error());
        return 5;
    }
    printf("mac-check: window after init: %dx%d pixels=%dx%d density=%d/1000 hidden=%d fullscreen=%d\n",
           win.width, win.height, win.pixel_width, win.pixel_height, win.pixel_density_x1000, win.hidden, win.fullscreen);
    if (win.hidden != 1) {
        fprintf(stderr, "expected a hidden window\n");
        return 10;
    }

    int ticks_ok = 0, ticks_exit = 0, failed = 0;
    int n = run_ticks(celeste_tick, celeste_last_error, TICKS_WINDOW, "window", &ticks_exit);
    if (n < 0) failed = 1; else ticks_ok += n;

    /* Canvas: the game renders its output into the host texture instead of the window. */
    void *canvas = k6d_metal_texture_2d(device, (unsigned)canvas_w, (unsigned)canvas_h, 1);
    if (!canvas) {
        fprintf(stderr, "canvas texture could not be created\n");
        return 11;
    }
    /* Error case first: wrong size must be refused with a text. */
    rc = celeste_set_canvas(canvas, canvas_w, canvas_h + 1);
    printf("mac-check: celeste_set_canvas with wrong size: rc=%d last_error=\"%s\"\n", rc, celeste_last_error());
    if (rc != -1) {
        fprintf(stderr, "expected rc=-1 for a wrong size\n");
        return 12;
    }
    rc = celeste_set_canvas(canvas, canvas_w, canvas_h);
    printf("mac-check: celeste_set_canvas %dx%d: rc=%d%s%s\n", canvas_w, canvas_h, rc, rc ? " " : "", rc ? celeste_last_error() : "");
    if (rc != 0) {
        return 12;
    }
    unsigned char center1[4] = {0}, edge[4] = {0}, center2[4] = {0}, center3[4] = {0};
    if (!failed) {
        n = run_ticks(celeste_tick, celeste_last_error, TICKS_CANVAS, "canvas", &ticks_exit);
        if (n < 0) failed = 1; else ticks_ok += n;
    }
    if (!k6d_metal_read_pixel(queue, canvas, (unsigned)canvas_w / 2, (unsigned)canvas_h / 2, center1) ||
        !k6d_metal_read_pixel(queue, canvas, (unsigned)canvas_w / 2, 10, edge)) {
        fprintf(stderr, "read-back failed\n");
        return 13;
    }
    printf("mac-check: canvas after %d ticks: center=(%u,%u,%u,%u) row10=(%u,%u,%u,%u)%s\n", TICKS_CANVAS,
           center1[0], center1[1], center1[2], center1[3], edge[0], edge[1], edge[2], edge[3],
           letterboxed ? " (row 10 is in the letterbox bar)" : " (no letterbox: canvas has the image's shape)");
    /* The letterbox bar must be opaque black; without a bar only the centre is checked. */
    int canvas_ok = nonblack(center1) && (!letterboxed || (!nonblack(edge) && edge[3] == 255));
    /* Reference image for the colour comparison with the device (scripts/compare-canvas.py). */
    if (dump_base != NULL) {
        char png[1024], raw[1024];
        snprintf(png, sizeof png, "%s.png", dump_base);
        snprintf(raw, sizeof raw, "%s.rgba", dump_base);
        double mean[3] = {0, 0, 0};
        int ok = k6d_metal_write_canvas(queue, canvas, png, raw, mean);
        printf("mac-check: canvas dump ok=%d %dx%d mean(rgb)=%.1f,%.1f,%.1f -> %s / %s\n", ok, canvas_w, canvas_h, mean[0], mean[1], mean[2], png, raw);
        if (!ok) {
            return 17;
        }
    }
    if (!failed) {
        n = run_ticks(celeste_tick, celeste_last_error, TICKS_CANVAS_2, "canvas", &ticks_exit);
        if (n < 0) failed = 1; else ticks_ok += n;
    }
    k6d_metal_read_pixel(queue, canvas, (unsigned)canvas_w / 2, (unsigned)canvas_h / 2, center2);
    printf("mac-check: canvas after %d more ticks: center=(%u,%u,%u,%u) %s\n", TICKS_CANVAS_2,
           center2[0], center2[1], center2[2], center2[3],
           memcmp(center1, center2, 4) ? "(changed: the game keeps rendering into the canvas)" : "(unchanged: static image or no further writes, not conclusive)");

    /* Back to the window: the canvas must not change any more. */
    rc = celeste_clear_canvas();
    printf("mac-check: celeste_clear_canvas: rc=%d\n", rc);
    if (rc != 0) {
        return 14;
    }
    if (!failed) {
        n = run_ticks(celeste_tick, celeste_last_error, TICKS_AFTER, "window again", &ticks_exit);
        if (n < 0) failed = 1; else ticks_ok += n;
    }
    k6d_metal_read_pixel(queue, canvas, (unsigned)canvas_w / 2, (unsigned)canvas_h / 2, center3);
    int detached = memcmp(center2, center3, 4) == 0;
    printf("mac-check: canvas after clear and %d ticks: center=(%u,%u,%u,%u) %s\n", TICKS_AFTER,
           center3[0], center3[1], center3[2], center3[3], detached ? "(unchanged: the game renders into the window again)" : "(CHANGED: the game still writes the canvas)");

    int total = TICKS_WINDOW + TICKS_CANVAS + TICKS_CANVAS_2 + TICKS_AFTER;
    printf("mac-check: ticks ok=%d of %d exit=%d failed=%d exiting=%d\n", ticks_ok, total, ticks_exit, failed, celeste_exiting());

    /* Exit probe: the game asks to exit (as if the player chose Exit), the next tick must return
       1 and celeste_exiting 1; celeste_end must still succeed afterwards. This is the wrapper half
       of the host's shutdown path (the host stops ticking on rc 1, then calls celeste_end). */
    rc = celeste_request_exit();
    int32_t exit_tick = celeste_tick(1.0 / HZ, 0);
    int exit_probe_ok = rc == 0 && exit_tick == 1 && celeste_exiting() == 1;
    printf("mac-check: exit probe: celeste_request_exit rc=%d, next tick rc=%d, exiting=%d %s\n", rc, exit_tick, celeste_exiting(), exit_probe_ok ? "(ok)" : "(FAILED)");

    rc = celeste_end();
    printf("mac-check: celeste_end rc=%d exiting=%d\n", rc, celeste_exiting());
    if (!exit_probe_ok) {
        return 19;
    }
    k6d_metal_release(canvas);
    k6d_metal_release(queue);
    k6d_metal_release(device);
    if (rc != 0 || failed || ticks_ok != total) {
        return 8;
    }
    if (!canvas_ok) {
        fprintf(stderr, "canvas check failed: center must be non-black%s\n", letterboxed ? ", letterbox row must be opaque black" : "");
        return 15;
    }
    if (!detached) {
        fprintf(stderr, "canvas still changed after celeste_clear_canvas\n");
        return 16;
    }
    printf("mac-check: run ok\n");
    return 0;
}
