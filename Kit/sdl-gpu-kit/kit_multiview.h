/*
 * kit_multiview.h — SDL_GPU-Kit für visionOS, Stufen K2 (P6 Multiview), K3 (P4 Rate Map) und
 * K4a (MSAA mit Auflösung von Farbe und Tiefe in die Drawable-Schichten).
 *
 * Beide Augen in einem Render-Pass und einem Draw: Pipeline mit
 * SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_VIEW_COUNT_NUMBER = 2, Pass über
 * SDL_BeginGPURenderPassWithProperties mit SDL_PROP_GPU_RENDERPASS_CREATE_VIEW_COUNT_NUMBER = 2
 * auf die importierten Drawable-Texturen (P3) des Hosts (P1). View i schreibt Schicht i.
 * Shader aus shaders/multiview.hlsl über die Kit-Werkzeugkette (kit_shaders_generated.h).
 *
 * Regeln (reverse-Z depth on visionOS: 0 is far, larger is nearer): Clear mit Tiefe > 0 (Standard 0.001), Quad mit
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
    /* K4a: GPU-Zeit der SDL-Command-Buffer der Frames (GPUEndTime − GPUStartTime, aus dem
     * Completed-Rückruf des Metal-Backends), Fenster und gesamt. Messbild- und Rücklese-Puffer
     * zählen nicht mit; untagged = Abschlüsse ohne bekannte Herkunft, errors = Status ≠ completed. */
    unsigned gpu_frames;
    double gpu_sum_ms;
    double gpu_max_ms;
    unsigned long gpu_frames_total;
    double gpu_total_sum_ms;
    double gpu_total_max_ms;
    unsigned long gpu_untagged;
    unsigned long gpu_errors;
    /* K4a: MSAA-Stand der Sitzung (0 = aus); Grösse der MSAA-Texturen und ihr allocatedSize. */
    unsigned msaa_samples;
    unsigned msaa_width;
    unsigned msaa_height;
    unsigned msaa_layers;
    unsigned long long msaa_bytes;     /* allocatedSize der Host-Texturen, bei memoryless nominal */
    unsigned depth_filter;         /* 0 sample0, 1 min, 2 max */
    /* K4b */
    unsigned memoryless;           /* 1: MSAA-Ziele und Mess-MSAA-Textur memoryless (SDL-Property) */
    unsigned long long msaa_nominal_bytes;      /* Breite × Höhe × Schichten × Samples × Bytes, beide Ziele */
    unsigned long long measure_msaa_nominal_bytes; /* RG32F-MSAA-Textur des Messbilds, nominal */
    /* K4c */
    unsigned depth_store;          /* 1: store_op des MSAA-Tiefenziels STORE (StoreAndMultisampleResolve) */
    unsigned long probes_total;    /* ausgeführte Tiefenproben (step=depth-probe) */
} kit_multiview_stats;

/* K4a: Optionen der Sitzung. msaa_samples 0 oder 1 = ohne Kantenglättung (Stand K3). Mit MSAA legt
 * die Sitzung beim ersten Frame zwei 2D-Multisample-Array-Texturen in Drawable-Grösse an (Farbe,
 * Tiefe), rendert hinein und löst Farbe (store_op RESOLVE) und Tiefe (Pass-Property
 * SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_TEXTURE_POINTER) in die Drawable-Schichten
 * auf. depth_filter: 0 sample0, 1 min, 2 max (Reverse-Z: max = nächste Fläche, Standard).
 * pattern/view_colors: Inhalt des Quads (Standard Schachbrett weiss; der Mac-Test nutzt flache
 * Farben pro View). with_bar (K4b, Standard an): neben dem Brett ein schmaler, schräg gestellter
 * Balken aus Geometrie, an dem MSAA sichtbar wird. memoryless (K4b): MSAA-Ziele und die
 * MSAA-Textur des Messbilds mit SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN anlegen
 * (nur Tile-Speicher, Auflösung am Pass-Ende); ohne memoryless legt der Host die MSAA-Ziele an
 * und importiert sie (allocatedSize messbar).
 * K4c (Gerätetest «Tiefenauflösung mit Multiview bei gespeicherten MSAA-Samples»):
 * depth_store: store_op des MSAA-Tiefenziels STORE statt DONT_CARE, Metal macht daraus
 * StoreAndMultisampleResolve statt MultisampleResolve (verlangt memoryless aus). depth_probe: ab
 * Frame 120 alle 300 Frames denselben Pass ein zweites Mal rendern, Farbe und Tiefe (Filter max)
 * in eigene 1x-Zweischichttexturen auflösen, nicht ins Drawable, und die Tiefe beider Schichten
 * zurücklesen (step=depth-probe: beschriebene Pixel, verschiedene Werte, Minimum, Maximum). Die
 * Probe wartet synchron auf die GPU (ein verspäteter Frame pro Probe). Beides verlangt MSAA. */
typedef struct kit_multiview_options {
    unsigned msaa_samples;
    unsigned depth_filter;
    float pattern;
    float view_colors[2][4];
    bool with_bar;
    bool memoryless;
    bool depth_store;
    bool depth_probe;
} kit_multiview_options;

/* K4c: Ergebnis einer Tiefenprobe. Die Probetexturen werden vor dem Pass auf den Sentinel 1.0
 * (Tiefe) und Schwarz (Farbe) gelöscht; «written» zählt Pixel, deren Tiefe nicht mehr der Sentinel
 * ist, «distinct» die verschiedenen Bitmuster inklusive Sentinel, min/max nur über beschriebene
 * Pixel, color_nonblack die Pixel der aufgelösten Farbe mit einem Kanal > 0 (Kontrolle, dass die
 * Farbe beider Views ankommt). */
typedef struct kit_depth_probe_layer {
    unsigned total;
    unsigned written;
    unsigned nan;
    unsigned distinct;
    float min_written;
    float max_written;
    unsigned color_nonblack;
} kit_depth_probe_layer;

typedef struct kit_depth_probe_result {
    unsigned long frame;        /* frames_total beim Probe-Pass */
    unsigned width;
    unsigned height;
    unsigned layers;
    unsigned depth_store;
    unsigned filter;            /* immer 2 (max) */
    kit_depth_probe_layer layer[2];
    double ms;                  /* CPU-Zeit inklusive Warten auf die GPU und Auswertung */
} kit_depth_probe_result;

/* K4c: Tiefenprobe sofort ausführen und synchron auswerten. Grösse = Drawable-Grösse (die
 * MSAA-Ziele der Sitzung werden darauf angelegt oder wiederverwendet), Quad und Matrizen wie
 * kit_multiview_frame, rate_map optional. Loggt step=depth-probe pro Schicht und
 * step=depth-probe-summary. false bei Fehler (SDL_GetError). */
bool kit_multiview_depth_probe(kit_multiview_session *session, unsigned width, unsigned height, unsigned layers,
                               const float rgba[4], float depth_clear, const float view_projection[32],
                               const float center[3], const float right[3], const float up[3], void *rate_map,
                               kit_depth_probe_result *out);

/* K4b: Diagnose der SDL-Textur-Container (textureCount, canBeCycled) der MSAA-Ziele; loggt
 * step=msaa-containers. Liest das interne Layout des Metal-Backends am Pin (nur Testzwecke). */
void kit_multiview_log_containers(kit_multiview_session *session);

void kit_multiview_options_default(kit_multiview_options *out);

/* SDL_GPU-Device auf Device und Queue des Hosts, Shader und Pipeline mit view_count 2.
 * Loggt step=multiview (SDL_GPUSupportsViewCount, Pipeline, Formate). NULL bei Fehler. */
kit_multiview_session *kit_multiview_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user);

/* Wie kit_multiview_begin mit Optionen (NULL = Standard). */
kit_multiview_session *kit_multiview_begin_ex(void *metal_device, void *metal_queue, const kit_multiview_options *options,
                                              kit_log_fn log, void *user);

/* K4a: Tiefen-Auflösungsfilter wechseln (0 sample0, 1 min, 2 max); wirkt ab dem nächsten Pass. */
void kit_multiview_set_depth_filter(kit_multiview_session *session, unsigned depth_filter);

/* K4a: GPU-Zeit der Frames ohne Aufwärmphase. Die ersten `skip` abgeschlossenen Frame-Command-
 * Buffer (Standard 90) zählen weder in die Gesamtwerte noch in die Perzentile; die Fensterwerte
 * (gpu_frames, gpu_sum_ms, gpu_max_ms) zählen alle. Die letzten 4096 Zeiten liegen als
 * Stichprobe vor; kit_multiview_gpu_percentiles liefert Anzahl, Mittel, p95 und Maximum darüber. */
void kit_multiview_set_gpu_skip(kit_multiview_session *session, unsigned skip);
void kit_multiview_gpu_percentiles(kit_multiview_session *session, unsigned *count, double *mean_ms,
                                   double *p95_ms, double *max_ms);

/* Ein Frame: Farb- und Tiefentextur importieren, ein Pass mit view_count 2, Clear (rgba,
 * depth_clear), bei draw_quad ein Draw des Quads mit den beiden Matrizen (je 16 float,
 * spaltenweise wie simd_float4x4), center/right/up (je 3 float, Meter), Schachbrett.
 * rate_map (K3, P4): id<MTLRasterizationRateMap> des Compositors oder NULL; mit Map gelten
 * Viewport und Scissor logisch (screenSize), SDL setzt beides aus der Map.
 * false, wenn ein Schritt scheitert; der Host löscht dann selbst. */
bool kit_multiview_frame(kit_multiview_session *session, void *color_texture, void *depth_texture,
                         const float rgba[4], float depth_clear, bool draw_quad,
                         const float view_projection[32], const float center[3],
                         const float right[3], const float up[3], void *rate_map);

/* K3: Messbild gegen eine Rate Map. Rendert in eine eigene Float-Textur in physischer Grösse
 * (zwei Schichten) einen Pass mit view_count 2 und der Map, der die logische Fragmentposition
 * als Farbe schreibt, liest an mehreren physischen Stichproben beider Schichten zurück und
 * vergleicht mit mapPhysicalToScreenCoordinates / mapScreenToPhysicalCoordinates der Map.
 * Abweichung in physischen Pixeln. Textur und Pipeline werden beim ersten Aufruf angelegt. */
typedef struct kit_multiview_measure {
    unsigned samples;
    float max_dev_px;
    float mean_dev_px;
    unsigned screen_width;
    unsigned screen_height;
    unsigned physical_width;
    unsigned physical_height;
    unsigned layers;
    double ms;              /* CPU-Zeit der Messung inklusive Warten auf die GPU */
} kit_multiview_measure;

/* Messbild gegen die Map: eigene RG32F-Array-Textur in der physischen Grösse der Map (nicht
 * der Drawable-Textur), Stichproben in diesem Raum; verbose loggt jede Stichprobe und
 * step=fov-sample-space. */
bool kit_multiview_measure_map(kit_multiview_session *session, void *rate_map, bool verbose, kit_multiview_measure *out);

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

/* Mac-Selbsttest K3 (P4): eigene Zweischicht-Map (1024×1024 logisch, zwei Stufen, Rand 0,5),
 * Messbild wie kit_multiview_measure_map mit Textur = Map-Grösse und mit Textur 32 px grösser
 * als die Map (Compositor-Fall), Abnahme je höchstens 1 physisches Pixel; Negativtests: Textur
 * kleiner als die Map, Map mit Startschicht 1. 0 = bestanden, sonst Schrittnummer ab 70. */
int kit_multiview_foveation_selftest(kit_log_fn log, void *user);

/* Mac-Selbsttest K4a (MSAA): Zweischicht-Map wie K3, Auflösungstexturen 688×688×2 (Farbe, Tiefe)
 * als «Drawable», Sitzung mit MSAA 4x, ein Pass mit view_count 2 und Map, ein gedrehtes Quad mit
 * schrägen Kanten (View 0 rot/0,25, View 1 blau/0,75 über Clear schwarz/0,001), Farbe und Tiefe
 * in die Auflösungstexturen aufgelöst, beide Schichten vollständig zurückgelesen: Kantenpixel mit
 * Zwischenwerten, Flächen exakt, aufgelöste Tiefe an Kantenpixeln nach Filter (max → Quad, min →
 * Clear), kleinste Tiefe > 0; dieselbe Kante ohne MSAA hart; Messbild der Map unter MSAA ≤ 1 px
 * (auch mit Textur grösser als die Map); Negativtests (Auflösungstextur multisample, unbekannter
 * Filter). 0 = bestanden, sonst Schrittnummer ab 90. */
int kit_multiview_msaa_selftest(kit_log_fn log, void *user);

/* Mac-Nachstellung K4c: Auflösungstexturen 688×688×2 wie K4a, je eine Sitzung mit MSAA 4x und
 * depth_store aus (dontcare) und an (store), je eine Tiefenprobe ohne und mit Zweischicht-Map.
 * Abnahme nur für dontcare: beide Schichten vollständig beschrieben, Schicht 0 bis 0,25 und
 * Schicht 1 bis 0,75 (Quad-Tiefen der Views), Farbe in beiden Schichten. Für store wird der
 * Befund nur geloggt (step=depth-probe-summary), er ist kein Fehler des Kits. 0 = bestanden,
 * sonst Schrittnummer ab 130. */
int kit_multiview_depth_store_selftest(kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_MULTIVIEW_H */
