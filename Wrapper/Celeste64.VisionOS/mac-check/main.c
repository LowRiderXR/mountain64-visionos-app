/*
 * mac-check/main.c: drives the Celeste64.VisionOS library built for macOS the way the visionOS
 * host will drive the framework: dlopen, celeste_version, capabilities before and after
 * celeste_init, celeste_init with a hidden window, 90 ticks without presenting, celeste_end.
 * Built and run by scripts/build-game.sh mac-check.
 *
 *   mac-check <path to Celeste64.VisionOS.dylib> <content root>
 *   mac-check <path to Celeste64.VisionOS.dylib> --bad-content
 *
 * The second form passes a content root that does not exist: celeste_init must return -1 with
 * a text in celeste_last_error instead of crashing. Exit code 0 when every check passes.
 */

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../celeste.h"

#define TICKS 90
#define HZ 90.0

typedef const char *(*version_fn)(void);
typedef int32_t (*set_log_fn)(celeste_log_fn, void *);

/* Receives the game's log lines; the prefix shows that they came through the callback. */
static void on_log(int32_t level, const char *utf8, void *userdata)
{
    (void)userdata;
    printf("[log %d] %s\n", level, utf8 ? utf8 : "(null)");
}
typedef int32_t (*capabilities_fn)(celeste_capabilities *);
typedef int32_t (*init_fn)(const celeste_init_options *);
typedef int32_t (*tick_fn)(double, int32_t);
typedef int32_t (*exiting_fn)(void);
typedef int32_t (*end_fn)(void);
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

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <path to Celeste64.VisionOS.dylib> (<content root> | --bad-content)\n", argv[0]);
        return 64;
    }
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
    init_fn celeste_init = (init_fn)require(handle, "celeste_init");
    tick_fn celeste_tick = (tick_fn)require(handle, "celeste_tick");
    exiting_fn celeste_exiting = (exiting_fn)require(handle, "celeste_exiting");
    end_fn celeste_end = (end_fn)require(handle, "celeste_end");
    last_error_fn celeste_last_error = (last_error_fn)require(handle, "celeste_last_error");
    if (!celeste_version || !celeste_set_log_callback || !celeste_capabilities_get || !celeste_init || !celeste_tick || !celeste_exiting || !celeste_end || !celeste_last_error) {
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

    options.content_root = argv[2];
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

    int ticks_ok = 0, ticks_exit = 0, ticks_failed = 0;
    for (int i = 0; i < TICKS; i++) {
        int32_t t = celeste_tick(1.0 / HZ, 0);
        if (t == 0) ticks_ok++;
        else if (t == 1) ticks_exit++;
        else { ticks_failed++; fprintf(stderr, "celeste_tick %d failed: %s\n", i, celeste_last_error()); break; }
    }
    printf("mac-check: ticks ok=%d exit=%d failed=%d exiting=%d\n", ticks_ok, ticks_exit, ticks_failed, celeste_exiting());

    rc = celeste_end();
    printf("mac-check: celeste_end rc=%d exiting=%d\n", rc, celeste_exiting());
    if (rc != 0 || ticks_failed != 0 || ticks_ok != TICKS) {
        return 8;
    }
    printf("mac-check: run ok\n");
    return 0;
}
