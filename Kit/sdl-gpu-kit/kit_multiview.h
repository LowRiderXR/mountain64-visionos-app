/*
 * kit_multiview.h — SDL_GPU-Kit für visionOS, Stufe K2: Baustein P6 (Multiview).
 *
 * Beide Augen in einem Render-Pass und einem Draw: Pipeline mit
 * SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_VIEW_COUNT_NUMBER = 2, Pass über
 * SDL_BeginGPURenderPassWithProperties mit SDL_PROP_GPU_RENDERPASS_CREATE_VIEW_COUNT_NUMBER = 2
 * auf die importierten Drawable-Texturen (P3) des Hosts (P1). View i schreibt Schicht i.
 * Shader aus shaders/multiview.hlsl über die Kit-Werkzeugkette (kit_shaders_generated.h).
 *
 * Regeln (Plattformwissen, Reverse-Z): Clear mit Tiefe > 0 (Standard 0.001), Quad mit
 * Tiefenschreiben und Vergleich greater; der Host präsentiert nach dem SDL-Submit.
 */

#ifndef KIT_MULTIVIEW_H
#define KIT_MULTIVIEW_H

#include <stdbool.h>

#include "kit_testscene.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kit_multiview_session kit_multiview_session;

typedef struct kit_multiview_stats {
    /* Fensterwerte seit dem letzten kit_multiview_take_stats */
    unsigned frames;
    unsigned fails;
    double sum_ms;
    double max_ms;
    /* Gesamtwerte */
    unsigned long frames_total;
    unsigned long fails_total;
    unsigned long passes_total;    /* Render-Pässe über SDL */
    unsigned long draws_total;     /* Draw-Aufrufe über SDL */
    double total_sum_ms;           /* CPU-Zeit des SDL-Teils über alle Frames */
    double total_max_ms;
    unsigned long wrappers_created;
    unsigned long wrappers_released;
} kit_multiview_stats;

/* SDL_GPU-Device auf Device und Queue des Hosts, Shader und Pipeline mit view_count 2.
 * Loggt step=multiview (SDL_GPUSupportsViewCount, Pipeline, Formate). NULL bei Fehler. */
kit_multiview_session *kit_multiview_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user);

/* Ein Frame: Farb- und Tiefentextur importieren, ein Pass mit view_count 2, Clear (rgba,
 * depth_clear), bei draw_quad ein Draw des Quads mit den beiden Matrizen (je 16 float,
 * spaltenweise wie simd_float4x4), center/right/up (je 3 float, Meter), Schachbrett.
 * false, wenn ein Schritt scheitert; der Host löscht dann selbst. */
bool kit_multiview_frame(kit_multiview_session *session, void *color_texture, void *depth_texture,
                         const float rgba[4], float depth_clear, bool draw_quad,
                         const float view_projection[32], const float center[3],
                         const float right[3], const float up[3]);

/* Fensterwerte lesen und nullen; Gesamtwerte bleiben. */
void kit_multiview_take_stats(kit_multiview_session *session, kit_multiview_stats *out);

/* Auf die GPU warten, Pipeline, Shader und Device freigeben, step=multiview-end loggen. */
void kit_multiview_end(kit_multiview_session *session);

/* Mac-Selbsttest: eigenes Device/Queue, 2D-Array-Texturen 64×64×2, ein Pass mit view_count 2
 * und ein Draw, der View 0 rot mit Tiefe 0.25 und View 1 blau mit Tiefe 0.75 schreibt (flache
 * Farbe), Rücklesen beider Schichten; Negativtests: Pipeline mit view_count 1 im Pass mit
 * view_count 2, Pass mit view_count 3 auf 2 Schichten. SDL_Init muss gelaufen sein.
 * 0 = bestanden, sonst Schrittnummer ab 40. */
int kit_multiview_selftest(kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_MULTIVIEW_H */
