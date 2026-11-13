/*
 * kit_testscene.h — SDL_GPU-Kit für visionOS, Testszene Stufen K0 und K1a.
 *
 * First stage of the kit: SDL_GPU ohne Patches in einem fremden
 * Prozess (SwiftUI-App auf visionOS, Kommandozeile auf macOS). Die Szene legt ein Device und
 * eine eigene Textur an, führt einen Clear-Pass aus, liest einen Pixel zurück und meldet jeden
 * Schritt als Zeile "[c64-kit] ..." über den Log-Callback. Kein Fenster, kein Swapchain.
 *
 * K1a (Baustein P1): dieselbe Szene mit eingespeistem MTLDevice und/oder MTLCommandQueue des
 * Hosts (Properties SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER / ..._COMMAND_QUEUE_POINTER
 * aus dem Fork sdl-visionos). Zusätzliche Schritte: Zeigervergleich Host gegen SDL
 * (step=inject) und nach SDL_DestroyGPUDevice ein leerer Command Buffer auf der Host-Queue
 * (step=hostqueue-after-destroy), der zeigt, dass SDL keine fremde Referenz freigegeben hat.
 *
 * Der Code ist plattformneutral (nur SDL3-API); die Metal-Hilfen für den Host liegen in
 * kit_testscene_metal.m. Das Kit gehört nicht zu SDL: ab K1 hängt die Szene am Swift-Host.
 */

#ifndef KIT_TESTSCENE_H
#define KIT_TESTSCENE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Eine Logzeile ohne Zeilenende. Wird vom Host ins Unified Log, in die Fortschrittsdatei oder
 * auf stdout geschrieben. */
typedef void (*kit_log_fn)(const char *line, void *user);

typedef struct kit_testscene_options {
    /* true: die Szene ruft SDL_SetMainReady und SDL_Init(SDL_INIT_VIDEO) selbst.
     * false: der Host hat SDL schon initialisiert (kit_testscene_init_sdl). */
    bool init_sdl;
    /* true: am Ende SDL_Quit. Auf UIKit-Plattformen nur vom Hauptthread sinnvoll. */
    bool quit_sdl;
    /* SDL_GPU im Debug-Modus anlegen (Validierung im Backend, langsamer). */
    bool debug_mode;
    /* Grösse der Testtextur; 0 = 256. */
    int width;
    int height;
    /* K1a: id<MTLDevice> und/oder id<MTLCommandQueue> des Hosts, unretained übergeben; NULL =
     * SDL erzeugt selbst. Der Host bleibt Besitzer; die Szene gibt nichts frei. */
    void *metal_device;
    void *metal_queue;
} kit_testscene_options;

/* Schritte in Reihenfolge; der Rückgabewert von kit_testscene_run nennt den Schritt, an dem es
 * scheiterte (0 = alles bestanden). */
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
    KIT_STEP_READBACK = 9,    /* SDL_MapGPUTransferBuffer, Pixelvergleich */
    KIT_STEP_INJECT = 10,     /* K1a: SDL nutzt nicht die eingespeisten Objekte */
    KIT_STEP_HOSTQUEUE = 11   /* K1a: Host-Queue nach SDL_DestroyGPUDevice unbrauchbar */
};

/* SDL_SetMainReady + SDL_Init(SDL_INIT_VIDEO), mit Logzeile step=init. Auf UIKit-Plattformen
 * im Hauptthread rufen. Gibt false zurück, wenn SDL_Init scheitert (Fehlertext in der Zeile). */
bool kit_testscene_init_sdl(kit_log_fn log, void *user);

/* SDL_Quit, Gegenstück zu kit_testscene_init_sdl. */
void kit_testscene_quit_sdl(void);

/* Führt die Szene einmal aus. Thread: beliebig, sofern SDL_Init schon lief; mit init_sdl auf
 * UIKit-Plattformen der Hauptthread. Gibt KIT_STEP_OK oder den gescheiterten Schritt zurück;
 * die letzte Zeile "[c64-kit] result=..." fasst zusammen. */
int kit_testscene_run(const kit_testscene_options *options, kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_H */
