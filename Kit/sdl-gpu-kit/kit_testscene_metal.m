/*
 * kit_testscene_metal.m — Metal-Hilfen für die Kit-Testszene (K1a, K1b). Siehe kit_testscene_metal.h.
 */

#import <Metal/Metal.h>

#include <SDL3/SDL_gpu.h>

#include "kit_testscene_metal.h"

#include <stdio.h>

bool kit_metal_create_host_objects(void **device_out, void **queue_out)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            return false;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (queue == nil) {
            return false;
        }
        queue.label = @"kit-host-queue";
        *device_out = (void *)CFBridgingRetain(device);
        *queue_out = (void *)CFBridgingRetain(queue);
        return true;
    }
}

void kit_metal_release_host_objects(void *device, void *queue)
{
    if (queue) {
        CFBridgingRelease(queue);
    }
    if (device) {
        CFBridgingRelease(device);
    }
}

void *kit_metal_queue_device(void *queue)
{
    if (!queue) {
        return NULL;
    }
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    return (__bridge void *)q.device;
}

const char *kit_metal_device_name(void *device, char *buf, size_t cap)
{
    if (!device || cap == 0) {
        return "-";
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    snprintf(buf, cap, "%s", d.name.UTF8String ? d.name.UTF8String : "?");
    return buf;
}

bool kit_metal_hostqueue_check(void *queue, char *status_out, size_t cap)
{
    @autoreleasepool {
        if (!queue) {
            snprintf(status_out, cap, "queue=NULL");
            return false;
        }
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        if (cb == nil) {
            snprintf(status_out, cap, "commandBuffer=nil");
            return false;
        }
        cb.label = @"kit-hostqueue-after-destroy";
        [cb commit];
        [cb waitUntilCompleted];
        const bool ok = (cb.status == MTLCommandBufferStatusCompleted) && (cb.error == nil);
        snprintf(status_out, cap, "status=%ld error=%s", (long)cb.status,
                 cb.error ? (cb.error.localizedDescription.UTF8String ?: "?") : "-");
        return ok;
    }
}

/* MTLPixelFormat → SDL_GPUTextureFormat für die gängigen Compositor- und Spielformate; die
 * Zuordnung entspricht SDLToMetal_TextureFormat im Metal-Backend (SDL_gpu_metal.m:92-170). */
static int kit_sdl_format(MTLPixelFormat format)
{
    switch (format) {
    case MTLPixelFormatBGRA8Unorm_sRGB: return SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
    case MTLPixelFormatBGRA8Unorm: return SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM;
    case MTLPixelFormatRGBA8Unorm_sRGB: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB;
    case MTLPixelFormatRGBA8Unorm: return SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    case MTLPixelFormatRGBA16Float: return SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
    case MTLPixelFormatRGBA16Unorm: return SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UNORM;
    case MTLPixelFormatDepth32Float: return SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    case MTLPixelFormatDepth32Float_Stencil8: return SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT;
    case MTLPixelFormatDepth16Unorm: return SDL_GPU_TEXTUREFORMAT_D16_UNORM;
    default: return SDL_GPU_TEXTUREFORMAT_INVALID; /* etwa bgr10a2Unorm: kein SDL-Format */
    }
}

bool kit_metal_texture_info(void *texture, kit_metal_texture_desc *out)
{
    if (!texture || !out) {
        return false;
    }
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    out->mtl_type = (int)t.textureType;
    switch (t.textureType) {
    case MTLTextureType2D: out->sdl_type = SDL_GPU_TEXTURETYPE_2D; break;
    case MTLTextureType2DMultisample: out->sdl_type = SDL_GPU_TEXTURETYPE_2D; break;
    case MTLTextureType2DArray: out->sdl_type = SDL_GPU_TEXTURETYPE_2D_ARRAY; break;
    case MTLTextureType2DMultisampleArray: out->sdl_type = SDL_GPU_TEXTURETYPE_2D_ARRAY; break; /* K4a: Samples aus sampleCount */
    default: out->sdl_type = -1; break;
    }
    out->mtl_pixel_format = (int)t.pixelFormat;
    out->sdl_format = kit_sdl_format(t.pixelFormat);
    out->width = (unsigned)t.width;
    out->height = (unsigned)t.height;
    out->layers = (unsigned)t.arrayLength;
    out->levels = (unsigned)t.mipmapLevelCount;
    out->samples = (unsigned)t.sampleCount;
    out->usage = (unsigned long)t.usage;
    return true;
}

bool kit_metal_create_array_texture_ex(void *device, bool depth, unsigned width, unsigned height,
                                       unsigned layers, unsigned samples, void **texture_out)
{
    @autoreleasepool {
        if (!device || !texture_out || samples == 0) {
            return false;
        }
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
        desc.textureType = (samples > 1) ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray;
        desc.pixelFormat = depth ? MTLPixelFormatDepth32Float : MTLPixelFormatBGRA8Unorm_sRGB;
        desc.width = width;
        desc.height = height;
        desc.arrayLength = layers;
        desc.mipmapLevelCount = 1;
        desc.sampleCount = samples;
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> t = [d newTextureWithDescriptor:desc];
        if (t == nil) {
            return false;
        }
        if (samples > 1) {
            t.label = depth ? @"kit-host-depth-msaa-array" : @"kit-host-color-msaa-array";
        } else {
            t.label = depth ? @"kit-host-depth-array" : @"kit-host-color-array";
        }
        *texture_out = (void *)CFBridgingRetain(t);
        return true;
    }
}

bool kit_metal_create_array_texture(void *device, bool depth, unsigned width, unsigned height,
                                    unsigned layers, void **texture_out)
{
    return kit_metal_create_array_texture_ex(device, depth, width, height, layers, 1, texture_out);
}

unsigned long long kit_metal_texture_allocated_bytes(void *texture)
{
    if (!texture) {
        return 0;
    }
    id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
    return (unsigned long long)t.allocatedSize;
}

bool kit_metal_supports_sample_count(void *device, unsigned samples)
{
    if (!device) {
        return false;
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return [d supportsTextureSampleCount:samples];
}

bool kit_metal_command_buffer_gpu_time(void *command_buffer, double *start_s, double *end_s,
                                       int *status_out, char *error_out, size_t cap)
{
    if (!command_buffer) {
        return false;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    if (start_s) *start_s = cb.GPUStartTime;
    if (end_s) *end_s = cb.GPUEndTime;
    if (status_out) *status_out = (int)cb.status;
    if (error_out && cap > 0) {
        snprintf(error_out, cap, "%s", cb.error ? (cb.error.localizedDescription.UTF8String ?: "?") : "-");
    }
    return cb.status == MTLCommandBufferStatusCompleted && cb.error == nil;
}

void kit_metal_release_texture(void *texture)
{
    if (texture) {
        CFBridgingRelease(texture);
    }
}

/* ------------------------------------------------------------------ Rate Maps (K3) */

bool kit_metal_map_info(void *map, kit_metal_map_desc *out)
{
    if (!map || !out) {
        return false;
    }
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    out->screen_width = (unsigned)m.screenSize.width;
    out->screen_height = (unsigned)m.screenSize.height;
    out->layers = (unsigned)m.layerCount;
    for (unsigned i = 0; i < 8; i++) {
        if (i < out->layers) {
            MTLSize p = [m physicalSizeForLayer:i];
            out->physical_width[i] = (unsigned)p.width;
            out->physical_height[i] = (unsigned)p.height;
        } else {
            out->physical_width[i] = out->physical_height[i] = 0;
        }
    }
    out->granularity_width = (unsigned)m.physicalGranularity.width;
    out->granularity_height = (unsigned)m.physicalGranularity.height;
    return true;
}

void kit_metal_map_physical_to_screen(void *map, unsigned layer, float px, float py, float *sx, float *sy)
{
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    MTLCoordinate2D s = [m mapPhysicalToScreenCoordinates:MTLCoordinate2DMake(px, py) forLayer:layer];
    *sx = s.x;
    *sy = s.y;
}

void kit_metal_map_screen_to_physical(void *map, unsigned layer, float sx, float sy, float *px, float *py)
{
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    MTLCoordinate2D p = [m mapScreenToPhysicalCoordinates:MTLCoordinate2DMake(sx, sy) forLayer:layer];
    *px = p.x;
    *py = p.y;
}

bool kit_metal_supports_rate_map_layers(void *device, unsigned layers)
{
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return [d supportsRasterizationRateMapWithLayerCount:layers];
}

bool kit_metal_create_rate_map(void *device, unsigned screen_width, unsigned screen_height, unsigned layers,
                               unsigned samples, float edge_quality, void **map_out)
{
    @autoreleasepool {
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        if (![d supportsRasterizationRateMapWithLayerCount:layers] || samples < 2 || samples > 64) {
            return false;
        }
        MTLRasterizationRateMapDescriptor *desc = [MTLRasterizationRateMapDescriptor
            rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(screen_width, screen_height, 1)];
        float profile[64];
        for (unsigned i = 0; i < samples; i++) {
            /* Asymmetrisches Zweistufen-Profil: 1,0 im ersten Drittel, edge_quality danach.
             * Metal interpoliert zwischen den Stützstellen und rundet die physische Grösse auf
             * die Granularität; weder Permutation noch Spiegelung desselben Profils ergaben
             * gleiche physische Breiten (Messungen 2026-10-17: 712/688, 816/784, 688/682).
             * Deshalb bekommen alle Schichten dasselbe Profil (wie die Compositor-Map, deren
             * Schichten gleich gross sind); die Schichtwahl der Map prüft der Gerätelauf. */
            profile[i] = (i < samples / 3) ? 1.0f : edge_quality;
        }
        for (unsigned layer = 0; layer < layers; layer++) {
            float horizontal[64];
            for (unsigned i = 0; i < samples; i++) {
                horizontal[i] = profile[i];
            }
            MTLRasterizationRateLayerDescriptor *ld = [[MTLRasterizationRateLayerDescriptor alloc]
                initWithSampleCount:MTLSizeMake(samples, samples, 1) horizontal:horizontal vertical:profile];
            [desc setLayer:ld atIndex:layer];
        }
        desc.label = @"kit-host-rate-map";
        id<MTLRasterizationRateMap> map = [d newRasterizationRateMapWithDescriptor:desc];
        if (map == nil) {
            return false;
        }
        *map_out = (void *)CFBridgingRetain(map);
        return true;
    }
}

void kit_metal_release_map(void *map)
{
    if (map) {
        CFBridgingRelease(map);
    }
}
