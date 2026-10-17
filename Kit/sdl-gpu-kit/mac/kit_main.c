/*
 * kit_main.c — Kommandozeilenlauf der Kit-Testszene auf macOS (Stufen K0, K1a, K1b).
 *
 * Gleicher Code wie am Gerät (kit_testscene.c, kit_import.c), gegen
 * Frameworks/macos/libSDL3.0.dylib aus scripts/build-sdl3.sh. Ausgabe: die [c64-kit]-Zeilen
 * auf stdout, Exit-Code = gescheiterter Schritt (0 = bestanden). Aufruf über run-mac.sh.
 *
 *   kit-testscene [--debug] [--size N] [--inject | --inject-device | --inject-queue | --import | --multiview | --foveation]
 *
 *   --inject         K1a: Device und Queue des Runners an SDL geben (P1, beide Properties)
 *   --inject-device  nur das Device; SDL legt eine eigene Queue darauf an
 *   --inject-queue   nur die Queue; SDL übernimmt deren Device
 *   --import         K1b: eigene 2D-Array-Texturen importieren (P3), pro Schicht löschen,
 *                    zurücklesen, Negativtests
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
        } else {
            fprintf(stderr, "Unbekanntes Argument: %s\n", argv[i]);
            return 64;
        }
    }

    if (want_import || want_multiview || want_foveation) {
        /* K1b/K2/K3: SDL_Init hier wie am Gerät im Hauptthread, Selbsttest mit eigenen Objekten. */
        if (!kit_testscene_init_sdl(log_stdout, NULL)) {
            return 1;
        }
        const int rc = want_foveation ? kit_multiview_foveation_selftest(log_stdout, NULL)
                     : want_multiview ? kit_multiview_selftest(log_stdout, NULL)
                                      : kit_import_selftest(log_stdout, NULL, opt.debug_mode);
        kit_testscene_quit_sdl();
        return rc;
    }

    void *host_device = NULL;
    void *host_queue = NULL;
    if (want_device || want_queue) {
        if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
            fprintf(stderr, "Host-Device oder -Queue konnte nicht erzeugt werden\n");
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
        /* Nach SDL_DestroyGPUDevice müssen die Host-Referenzen noch gültig sein; die Freigabe
         * hier ist die letzte. Ein Absturz an dieser Stelle hiesse: SDL hat zu viel freigegeben. */
        kit_metal_release_host_objects(host_device, host_queue);
        printf("[c64-kit] host objects released ok=1\n");
    }
    return rc;
}
