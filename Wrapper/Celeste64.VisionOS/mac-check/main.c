/*
 * mac-check/main.c: loads the Celeste64.VisionOS library built for macOS with dlopen and calls
 * celeste_version(), the same way the visionOS host will use the framework. Built and run by
 * scripts/build-game.sh mac-check.
 *
 *   mac-check <path to Celeste64.VisionOS.dylib>
 *
 * Exit code 0 when the library loads, the symbol is found and the version string is non-empty.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef const char *(*celeste_version_fn)(void);

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path to Celeste64.VisionOS.dylib>\n", argv[0]);
        return 64;
    }
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }
    celeste_version_fn celeste_version = (celeste_version_fn)dlsym(handle, "celeste_version");
    if (celeste_version == NULL) {
        fprintf(stderr, "dlsym(celeste_version) failed: %s\n", dlerror());
        return 2;
    }
    const char *version = celeste_version();
    if (version == NULL || version[0] == '\0') {
        fprintf(stderr, "celeste_version returned an empty string\n");
        return 3;
    }
    printf("celeste_version: %s\n", version);
    /* Call it twice: the string must be stable for the lifetime of the process. */
    const char *again = celeste_version();
    if (again != version || strcmp(again, version) != 0) {
        fprintf(stderr, "celeste_version is not stable across calls\n");
        return 4;
    }
    return 0;
}
