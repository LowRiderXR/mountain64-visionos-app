/*
 * kit_import.h — SDL_GPU-Kit für visionOS, Stufe K1b: Baustein P3 (externe Texturen).
 *
 * Importiert MTLTexturen des Hosts (Farbe und Tiefe eines Compositor-Drawables) als
 * SDL_GPUTexture über SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER (Fork sdl-visionos) und
 * löscht alle Schichten über SDL_GPU, pro Schicht ein Render-Pass. Die Wrapper entstehen pro
 * Frame und werden nach dem Submit freigegeben (SDL zerstört sie verzögert, sobald der Command
 * Buffer fertig ist; the wrappers are therefore safe to release right after the submit).
 *
 * Reihenfolge mit dem Present: SDL committet seinen Command Buffer synchron auf der geteilten
 * Queue (P1); der Host committet danach seinen Buffer mit encodePresent. MTLCommandQueue ist
 * eine serielle Queue, Ausführung in Commit-Reihenfolge (MTLCommandQueue.h, MTLCommandBuffer.h).
 */

#ifndef KIT_IMPORT_H
#define KIT_IMPORT_H

#include <stdbool.h>

#include "kit_testscene.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kit_import_session kit_import_session;

typedef struct kit_import_stats {
    /* Fensterwerte seit dem letzten kit_import_take_stats */
    unsigned frames;
    unsigned fails;
    double sum_ms;          /* CPU-Zeit des SDL-Teils (Wrapper, Pässe, Submit, Release) */
    double max_ms;
    /* Gesamtwerte seit kit_import_begin */
    unsigned long frames_total;
    unsigned long fails_total;
    unsigned long wrappers_created;
    unsigned long wrappers_released;
    unsigned distinct_color;    /* verschiedene MTLTexture-Zeiger, die der Host bisher übergab */
    unsigned distinct_depth;
} kit_import_stats;

/* SDL_GPU-Device auf dem Device und der Queue des Hosts (P1) anlegen. SDL_Init(VIDEO) muss
 * schon gelaufen sein (kit_testscene_init_sdl im Hauptthread). NULL bei Fehler (Zeile FAIL). */
kit_import_session *kit_import_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user);

/* Diagnose (K1b, Schwarzbild trotz fails=0): wait = nach jedem Submit auf den Fence warten,
 * bevor der Host committet (trennt GPU-Reihenfolge von «Pass schreibt nichts»); verify_every =
 * alle N Frames den Mittelpixel von Schicht 0 der importierten Farbtextur über SDL zurücklesen
 * und loggen (0 = aus; erzwingt für diesen Frame das Warten). */
void kit_import_set_diagnostics(kit_import_session *session, bool wait_for_gpu, unsigned verify_every);

/* Hat kit_import_clear_frame in diesem Frame den Mittelpixel zurückgelesen, liefert das die vier
 * Bytes (Speicherreihenfolge, bei BGRA8 b,g,r,a) und true; der Host liest dann an derselben
 * Stelle unmittelbar vor encodePresent nochmals. Setzt das Kennzeichen zurück. */
bool kit_import_last_verify(kit_import_session *session, unsigned char out[4]);

/* Farb- und Tiefentextur des Frames importieren und alle Schichten löschen (Farbe rgba, Tiefe
 * depth), Command Buffer committen, Wrapper freigeben. false, wenn ein Schritt scheitert; der
 * Host löscht dann selbst. Loggt beim ersten Aufruf step=import und bei neuen Texturzeigern
 * step=import-rotation (erste 600 Frames). Fehler werden höchstens einmal pro Sekunde geloggt. */
bool kit_import_clear_frame(kit_import_session *session, void *color_texture, void *depth_texture,
                            const float rgba[4], float depth);

/* Fensterwerte lesen und nullen; Gesamtwerte bleiben. */
void kit_import_take_stats(kit_import_session *session, kit_import_stats *out);

/* Auf die GPU warten, Device zerstören, Zusammenfassung loggen (step=import-end). */
void kit_import_end(kit_import_session *session);

/* Mac-Selbsttest: eigenes Device und eigene Queue, zwei 2D-Array-Texturen mit 2 Schichten
 * (bgra8Unorm_srgb, depth32Float), Import, pro Schicht ein Clear-Pass mit verschiedener Farbe
 * und Tiefe, beide Schichten zurücklesen und vergleichen, danach Negativtests (falsches Format,
 * falsche Schichtzahl müssen mit Fehlertext scheitern). SDL_Init muss gelaufen sein.
 * 0 = bestanden, sonst Schrittnummer ab 20. */
int kit_import_selftest(kit_log_fn log, void *user, bool debug_mode);

#ifdef __cplusplus
}
#endif

#endif /* KIT_IMPORT_H */
