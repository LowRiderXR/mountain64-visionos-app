/*
 * kit_testscene_metal.h — Metal-Hilfen für die Kit-Testszene (K1a P1, K1b P3).
 *
 * Für Hosts ohne Objective-C (die C-Kommandozeile auf dem Mac) und für Prüfungen nach
 * SDL_DestroyGPUDevice. Zeiger sind id<MTLDevice> / id<MTLCommandQueue> / id<MTLTexture> als
 * void*. Implementierung in kit_testscene_metal.m (ARC).
 */

#ifndef KIT_TESTSCENE_METAL_H
#define KIT_TESTSCENE_METAL_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Systemstandard-Device und eine Queue darauf anlegen. Beide werden mit +1 zurückgegeben
 * (CFBridgingRetain); Freigabe über kit_metal_release_host_objects. */
bool kit_metal_create_host_objects(void **device_out, void **queue_out);

/* Gibt die mit kit_metal_create_host_objects erzeugten Referenzen frei (NULL erlaubt). */
void kit_metal_release_host_objects(void *device, void *queue);

/* Device einer Queue (unretained), für Zeigervergleich und Logzeilen. */
void *kit_metal_queue_device(void *queue);

/* Name eines Devices in buf (UTF-8), gibt buf zurück. */
const char *kit_metal_device_name(void *device, char *buf, size_t cap);

/* Leerer Command Buffer auf der Queue: commit, waitUntilCompleted. Gibt true zurück, wenn der
 * Status MTLCommandBufferStatusCompleted ist und kein Fehler anliegt; status_out erhält eine
 * kurze Beschreibung (Status, Fehlertext). */
bool kit_metal_hostqueue_check(void *queue, char *status_out, size_t cap);

/* Beschreibung eines MTLTexture für den Import (K1b). sdl_type / sdl_format sind Werte der
 * SDL-Enums SDL_GPUTextureType / SDL_GPUTextureFormat; sdl_type < 0 bzw.
 * sdl_format == SDL_GPU_TEXTUREFORMAT_INVALID (0), wenn es kein Gegenstück gibt. */
typedef struct kit_metal_texture_desc {
    int sdl_type;
    int sdl_format;
    unsigned width;
    unsigned height;
    unsigned layers;      /* arrayLength */
    unsigned levels;      /* mipmapLevelCount */
    unsigned samples;     /* sampleCount */
    unsigned long usage;  /* MTLTextureUsage */
    int mtl_pixel_format; /* Rohwert MTLPixelFormat */
    int mtl_type;         /* Rohwert MTLTextureType */
} kit_metal_texture_desc;

bool kit_metal_texture_info(void *texture, kit_metal_texture_desc *out);

/* 2D-Array-Textur anlegen (StorageMode private, Usage RenderTarget): Farbe bgra8Unorm_srgb oder
 * Tiefe depth32Float. +1 zurückgegeben, Freigabe über kit_metal_release_texture. */
bool kit_metal_create_array_texture(void *device, bool depth, unsigned width, unsigned height,
                                    unsigned layers, void **texture_out);

void kit_metal_release_texture(void *texture);

/* Rasterization Rate Map (K3, Baustein P4). Zeiger ist id<MTLRasterizationRateMap> als void*. */
typedef struct kit_metal_map_desc {
    unsigned screen_width;
    unsigned screen_height;
    unsigned layers;
    unsigned physical_width[8];   /* pro Schicht */
    unsigned physical_height[8];
    unsigned granularity_width;
    unsigned granularity_height;
} kit_metal_map_desc;

bool kit_metal_map_info(void *map, kit_metal_map_desc *out);

/* Physische Fragmentkoordinate → logische Bildschirmkoordinate einer Schicht und zurück. */
void kit_metal_map_physical_to_screen(void *map, unsigned layer, float px, float py, float *sx, float *sy);
void kit_metal_map_screen_to_physical(void *map, unsigned layer, float sx, float sy, float *px, float *py);

/* Eigene Zweischicht-Map für den Mac-Test: screen_width × screen_height logisch, Qualität in
 * einem samples × samples Raster, Mitte 1,0 und Rand edge_quality (Schicht 1 horizontal
 * gespiegelt, damit die Schichten verschieden abbilden). +1 zurückgegeben, Freigabe über
 * kit_metal_release_map. false, wenn das Gerät keine Maps mit so vielen Schichten kann. */
bool kit_metal_create_rate_map(void *device, unsigned screen_width, unsigned screen_height, unsigned layers,
                               unsigned samples, float edge_quality, void **map_out);

void kit_metal_release_map(void *map);

bool kit_metal_supports_rate_map_layers(void *device, unsigned layers);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_METAL_H */
