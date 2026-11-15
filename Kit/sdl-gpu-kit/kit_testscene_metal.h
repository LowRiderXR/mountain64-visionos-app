/*
 * kit_testscene_metal.h — Metal helpers for the kit test scene (inject and import stages).
 *
 * For hosts without Objective-C (the C command line on the Mac) and for checks after
 * SDL_DestroyGPUDevice. Pointers are id<MTLDevice> / id<MTLCommandQueue> / id<MTLTexture> as
 * void*. Implementation in kit_testscene_metal.m (ARC).
 */

#ifndef KIT_TESTSCENE_METAL_H
#define KIT_TESTSCENE_METAL_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Create the system default device and a queue on it. Both are returned with +1
 * (CFBridgingRetain); release through kit_metal_release_host_objects. */
bool kit_metal_create_host_objects(void **device_out, void **queue_out);

/* Releases the references created with kit_metal_create_host_objects (NULL allowed). */
void kit_metal_release_host_objects(void *device, void *queue);

/* Device of a queue (unretained), for pointer comparison and log lines. */
void *kit_metal_queue_device(void *queue);

/* Name of a device in buf (UTF-8), returns buf. */
const char *kit_metal_device_name(void *device, char *buf, size_t cap);

/* Empty command buffer on the queue: commit, waitUntilCompleted. Returns true when the status
 * is MTLCommandBufferStatusCompleted and no error is set; status_out receives a short
 * description (status, error text). */
bool kit_metal_hostqueue_check(void *queue, char *status_out, size_t cap);

/* Description of an MTLTexture for the import. sdl_type / sdl_format are values of the SDL
 * enums SDL_GPUTextureType / SDL_GPUTextureFormat; sdl_type < 0 or
 * sdl_format == SDL_GPU_TEXTUREFORMAT_INVALID (0) when there is no counterpart. */
typedef struct kit_metal_texture_desc {
    int sdl_type;
    int sdl_format;
    unsigned width;
    unsigned height;
    unsigned layers;      /* arrayLength */
    unsigned levels;      /* mipmapLevelCount */
    unsigned samples;     /* sampleCount */
    unsigned long usage;  /* MTLTextureUsage */
    int mtl_pixel_format; /* raw value MTLPixelFormat */
    int mtl_type;         /* raw value MTLTextureType */
} kit_metal_texture_desc;

bool kit_metal_texture_info(void *texture, kit_metal_texture_desc *out);

/* Create a 2D array texture (storage mode private, usage RenderTarget): colour bgra8Unorm_srgb
 * or depth depth32Float. Returned with +1, release through kit_metal_release_texture. */
bool kit_metal_create_array_texture(void *device, bool depth, unsigned width, unsigned height,
                                    unsigned layers, void **texture_out);

void kit_metal_release_texture(void *texture);

/* Like kit_metal_create_array_texture, with samples > 1 as MTLTextureType2DMultisampleArray. */
bool kit_metal_create_array_texture_ex(void *device, bool depth, unsigned width, unsigned height,
                                       unsigned layers, unsigned samples, void **texture_out);

/* allocatedSize of an MTLTexture in bytes (0 for NULL). */
unsigned long long kit_metal_texture_allocated_bytes(void *texture);

/* phys_footprint of the process in bytes (task_info TASK_VM_INFO), Mac and visionOS. */
unsigned long long kit_metal_process_footprint_bytes(void);

/* supportsTextureSampleCount: of the device. */
bool kit_metal_supports_sample_count(void *device, unsigned samples);

/* GPU times of a completed MTLCommandBuffer (seconds, Metal's Mach time base); status_out
 * receives MTLCommandBufferStatus, error_out (optional) the error text. */
bool kit_metal_command_buffer_gpu_time(void *command_buffer, double *start_s, double *end_s,
                                       int *status_out, char *error_out, size_t cap);

/* Rasterization rate map. Pointer is id<MTLRasterizationRateMap> as void*. */
typedef struct kit_metal_map_desc {
    unsigned screen_width;
    unsigned screen_height;
    unsigned layers;
    unsigned physical_width[8];   /* per layer */
    unsigned physical_height[8];
    unsigned granularity_width;
    unsigned granularity_height;
} kit_metal_map_desc;

bool kit_metal_map_info(void *map, kit_metal_map_desc *out);

/* Physical fragment coordinate -> logical screen coordinate of a layer and back. */
void kit_metal_map_physical_to_screen(void *map, unsigned layer, float px, float py, float *sx, float *sy);
void kit_metal_map_screen_to_physical(void *map, unsigned layer, float sx, float sy, float *px, float *py);

/* Own two-layer map for the Mac test: screen_width × screen_height logical, quality in a
 * samples × samples grid, 1.0 in the first third and edge_quality after that, the same profile
 * in every layer. Returned with +1, release through kit_metal_release_map. false when the device
 * cannot do maps with that many layers. */
bool kit_metal_create_rate_map(void *device, unsigned screen_width, unsigned screen_height, unsigned layers,
                               unsigned samples, float edge_quality, void **map_out);

void kit_metal_release_map(void *map);

bool kit_metal_supports_rate_map_layers(void *device, unsigned layers);

#ifdef __cplusplus
}
#endif

#endif /* KIT_TESTSCENE_METAL_H */
