/*
 * kit_testscene.h — SDL_GPU-Kit für visionOS, Testszene Stufe K0.
 *
 * Stufe K0 (Docs/celeste64/sdl-gpu-kit-analyse.md, Stufenplan): SDL_GPU ohne Patches in einem
 * fremden Prozess (SwiftUI-App auf visionOS, Kommandozeile auf macOS) zum Laufen bringen.
 * Die Szene legt ein Device und eine eigene Textur an, führt einen Clear-Pass aus, liest einen
 * Pixel zurück und meldet jeden Schritt als Zeile "[c64-kit] ..." über den Log-Callback.
 * Kein Fenster, kein Swapchain, keine Shader.
 *
 * Der Code ist plattformneutral (nur SDL3-API) und gehört zum Kit, nicht zu SDL: ab K1 hängt die
 * Szene am Swift-Host (Drawable-Import), was in SDLs test/ keinen Platz hat.
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
    /* true: die Szene ruft SDL_SetMainReady und SDL_Init(SDL_INIT_VIDEO) selbst und am Ende
     * SDL_Quit. false: der Host hat SDL schon initialisiert. */
    bool init_sdl;
    /* SDL_GPU im Debug-Modus anlegen (Validierung im Backend, langsamer). */
    bool debug_mode;
    /* Grösse der Testtextur; 0 = 256. */
    int width;
    int height;
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
    KIT_STEP_READBACK = 9     /* SDL_MapGPUTransferBuffer, Pixelvergleich */
};

/* Führt die Szene einmal aus. Thread: wie SDL_Init es verlangt (auf UIKit-Plattformen der
 * Hauptthread). Gibt KIT_STEP_OK oder den gescheiterten Schritt zurück; die letzte Zeile
 * "[c64-kit] result=..." fasst zusammen. */
int kit_testscene_run(const kit_testscene_options *options, kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_H */
