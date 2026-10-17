/*
 * kit_main.c — Kommandozeilenlauf der Kit-Testszene auf macOS (Stufe K0).
 *
 * Gleicher Code wie am Gerät (kit_testscene.c), gegen Frameworks/macos/libSDL3.0.dylib aus
 * scripts/build-sdl3.sh. Ausgabe: die [c64-kit]-Zeilen auf stdout, Exit-Code = gescheiterter
 * Schritt (0 = bestanden). Aufruf über run-mac.sh.
 *
 *   kit-testscene [--debug] [--size N]
 */

#include "../kit_testscene.h"

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
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--debug") == 0) {
            opt.debug_mode = true;
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            opt.width = opt.height = atoi(argv[++i]);
        } else {
            fprintf(stderr, "Unbekanntes Argument: %s\n", argv[i]);
            return 64;
        }
    }
    return kit_testscene_run(&opt, log_stdout, NULL);
}
