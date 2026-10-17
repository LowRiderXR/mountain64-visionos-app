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
    case MTLTextureType2DArray: out->sdl_type = SDL_GPU_TEXTURETYPE_2D_ARRAY; break;
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

bool kit_metal_create_array_texture(void *device, bool depth, unsigned width, unsigned height,
                                    unsigned layers, void **texture_out)
{
    @autoreleasepool {
        if (!device || !texture_out) {
            return false;
        }
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
        desc.textureType = MTLTextureType2DArray;
        desc.pixelFormat = depth ? MTLPixelFormatDepth32Float : MTLPixelFormatBGRA8Unorm_sRGB;
        desc.width = width;
        desc.height = height;
        desc.arrayLength = layers;
        desc.mipmapLevelCount = 1;
        desc.sampleCount = 1;
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> t = [d newTextureWithDescriptor:desc];
        if (t == nil) {
            return false;
        }
        t.label = depth ? @"kit-host-depth-array" : @"kit-host-color-array";
        *texture_out = (void *)CFBridgingRetain(t);
        return true;
    }
}

void kit_metal_release_texture(void *texture)
{
    if (texture) {
        CFBridgingRelease(texture);
    }
}
