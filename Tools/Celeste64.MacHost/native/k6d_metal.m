// k6d_metal.m — small Metal helper for Celeste64.MacHost. Provides the host with what
// CompositorServices delivers on the headset: a Metal device and a queue, an existing 2D array
// texture that Foster imports through the SDL property
// SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, and a rasterization rate map with two
// layers including the coordinate mapping for the measurement image. No SDL involvement; Foster
// knows no Metal. Ownership: the host holds the Metal objects and releases them with
// k6d_metal_release; SDL holds only its own reference. Model: Kit/sdl-gpu-kit/kit_testscene_metal.m
// (kit_metal_create_array_texture_ex), here with the pixel formats that match Foster's
// TextureFormat.Color (RGBA8Unorm) and Depth16 (Depth16Unorm).
//
// Build (scripts/celeste-mac.sh machost):
//   clang -fobjc-arc -dynamiclib -framework Metal -framework Foundation k6d_metal.m -o libk6dmetal.dylib

#import <Metal/Metal.h>

void *k6d_metal_device(void)
{
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device ? (void *)CFBridgingRetain(device) : NULL;
    }
}

void *k6d_metal_queue(void *device)
{
    @autoreleasepool {
        if (!device) {
            return NULL;
        }
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        id<MTLCommandQueue> queue = [d newCommandQueue];
        queue.label = @"k6d-host-queue";
        return queue ? (void *)CFBridgingRetain(queue) : NULL;
    }
}

/* kind 0: RGBA8Unorm, render target and shader read (so that SDL can blit the layer);
   kind 1: Depth16Unorm, kind 2: Depth32Float (like the headset's drawable depth), render target only. */
void *k6d_metal_array_texture(void *device, unsigned width, unsigned height, unsigned layers, int kind)
{
    @autoreleasepool {
        if (!device || width == 0 || height == 0 || layers == 0) {
            return NULL;
        }
        const int depth = kind != 0;
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
        desc.textureType = MTLTextureType2DArray;
        desc.pixelFormat = kind == 2 ? MTLPixelFormatDepth32Float : (kind == 1 ? MTLPixelFormatDepth16Unorm : MTLPixelFormatRGBA8Unorm);
        desc.width = width;
        desc.height = height;
        desc.arrayLength = layers;
        desc.mipmapLevelCount = 1;
        desc.sampleCount = 1;
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = depth ? MTLTextureUsageRenderTarget : (MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> t = [d newTextureWithDescriptor:desc];
        if (t == nil) {
            return NULL;
        }
        t.label = depth ? @"k6d-host-depth-array" : @"k6d-host-color-array";
        return (void *)CFBridgingRetain(t);
    }
}

void k6d_metal_release(void *object)
{
    if (object) {
        CFBridgingRelease(object);
    }
}

/* ---- Rasterization rate map of the host, modelled on kit_metal_create_rate_map ---- */

int k6d_metal_supports_rate_map(void *device, unsigned layers)
{
    if (!device) {
        return 0;
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return [d supportsRasterizationRateMapWithLayerCount:layers] ? 1 : 0;
}

/* Two-layer map (or more) with the same profile in every layer and in both axes: 1.0 in the
   first third, edge_quality after that, samples sample points per axis (Metal interpolates).
   The same vertical curve in all layers is mandatory (Metal silently drops the vertical profile
   when the layers differ); the compositor's map has layers of equal size as well. */
void *k6d_metal_rate_map(void *device, unsigned screen_width, unsigned screen_height, unsigned layers,
                         unsigned samples, float edge_quality)
{
    @autoreleasepool {
        if (!device || layers == 0 || samples < 2 || samples > 64) {
            return NULL;
        }
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        if (![d supportsRasterizationRateMapWithLayerCount:layers]) {
            return NULL;
        }
        MTLRasterizationRateMapDescriptor *desc = [MTLRasterizationRateMapDescriptor
            rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(screen_width, screen_height, 1)];
        float profile[64];
        for (unsigned i = 0; i < samples; i++) {
            profile[i] = (i < samples / 3) ? 1.0f : edge_quality;
        }
        for (unsigned layer = 0; layer < layers; layer++) {
            MTLRasterizationRateLayerDescriptor *ld = [[MTLRasterizationRateLayerDescriptor alloc]
                initWithSampleCount:MTLSizeMake(samples, samples, 1) horizontal:profile vertical:profile];
            [desc setLayer:ld atIndex:layer];
        }
        desc.label = @"k6e-host-rate-map";
        id<MTLRasterizationRateMap> map = [d newRasterizationRateMapWithDescriptor:desc];
        return map ? (void *)CFBridgingRetain(map) : NULL;
    }
}

/* Logical size, physical size of one layer and layer count of the map. */
int k6d_metal_rate_map_info(void *map, unsigned layer, unsigned *screen_width, unsigned *screen_height,
                            unsigned *physical_width, unsigned *physical_height, unsigned *layer_count)
{
    if (!map) {
        return 0;
    }
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    if (layer >= m.layerCount) {
        return 0;
    }
    MTLSize p = [m physicalSizeForLayer:layer];
    if (screen_width) *screen_width = (unsigned)m.screenSize.width;
    if (screen_height) *screen_height = (unsigned)m.screenSize.height;
    if (physical_width) *physical_width = (unsigned)p.width;
    if (physical_height) *physical_height = (unsigned)p.height;
    if (layer_count) *layer_count = (unsigned)m.layerCount;
    return 1;
}

/* Logical screen coordinate -> physical texture coordinate of a layer (expected value for the measurement image). */
void k6d_metal_rate_map_screen_to_physical(void *map, unsigned layer, float sx, float sy, float *px, float *py)
{
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    MTLCoordinate2D p = [m mapScreenToPhysicalCoordinates:MTLCoordinate2DMake(sx, sy) forLayer:layer];
    if (px) *px = p.x;
    if (py) *py = p.y;
}

void k6d_metal_rate_map_physical_to_screen(void *map, unsigned layer, float px, float py, float *sx, float *sy)
{
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    MTLCoordinate2D s = [m mapPhysicalToScreenCoordinates:MTLCoordinate2DMake(px, py) forLayer:layer];
    if (sx) *sx = s.x;
    if (sy) *sy = s.y;
}

/* ---- Canvas texture and read-back for the wrapper's mac-check ---- */

/* 2D RGBA8Unorm texture as the host app creates it for the canvas: render target and shader
   read, optionally with PixelFormatView so an sRGB view can be created later. Private
   storage, default (tracked) hazard tracking. */
void *k6d_metal_texture_2d(void *device, unsigned width, unsigned height, int pixel_format_view)
{
    @autoreleasepool {
        if (!device || width == 0 || height == 0) {
            return NULL;
        }
        id<MTLDevice> d = (__bridge id<MTLDevice>)device;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (pixel_format_view ? MTLTextureUsagePixelFormatView : 0);
        id<MTLTexture> t = [d newTextureWithDescriptor:desc];
        if (t == nil) {
            return NULL;
        }
        t.label = @"k6d-canvas";
        return (void *)CFBridgingRetain(t);
    }
}

/* Reads one pixel (RGBA bytes) of a 2D texture: blit into a shared buffer on the given queue
   and wait. On the queue the game renders with, the blit runs after the game's committed
   command buffers, so it sees the finished image. Returns 1 on success. */
int k6d_metal_read_pixel(void *queue, void *texture, unsigned x, unsigned y, unsigned char out[4])
{
    @autoreleasepool {
        if (!queue || !texture || !out) {
            return 0;
        }
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
        if (x >= t.width || y >= t.height) {
            return 0;
        }
        id<MTLBuffer> buffer = [q.device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:buffer destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            return 0;
        }
        memcpy(out, buffer.contents, 4);
        return 1;
    }
}

/* ---- Canvas dump for the colour comparison between Mac and device ---- */

#import <ImageIO/ImageIO.h>

/* Reads the whole 2D RGBA8 texture back (blit on the given queue, wait) and writes it as PNG
   and as raw RGBA bytes (width*height*4, rows top-down); fills mean_rgb (0..255 per channel).
   Returns 1 on success. */
int k6d_metal_write_canvas(void *queue, void *texture, const char *png_path, const char *raw_path, double mean_rgb[3])
{
    @autoreleasepool {
        if (!queue || !texture) {
            return 0;
        }
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
        NSUInteger width = t.width, height = t.height, bytesPerRow = width * 4;
        id<MTLBuffer> buffer = [q.device newBufferWithLength:bytesPerRow * height options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                     toBuffer:buffer destinationOffset:0 destinationBytesPerRow:bytesPerRow destinationBytesPerImage:bytesPerRow * height];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            return 0;
        }
        const unsigned char *p = buffer.contents;
        unsigned long long sum[3] = {0, 0, 0};
        for (NSUInteger i = 0; i < width * height * 4; i += 4) {
            sum[0] += p[i]; sum[1] += p[i + 1]; sum[2] += p[i + 2];
        }
        if (mean_rgb) {
            for (int c = 0; c < 3; c++) mean_rgb[c] = (double)sum[c] / (double)(width * height);
        }
        int ok = 1;
        if (raw_path) {
            NSData *raw = [NSData dataWithBytes:p length:bytesPerRow * height];
            ok = [raw writeToFile:[NSString stringWithUTF8String:raw_path] atomically:YES] ? ok : 0;
        }
        if (png_path) {
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, p, bytesPerRow * height, NULL);
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, space, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                             provider, NULL, false, kCGRenderingIntentDefault);
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:png_path]];
            CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (image && destination) {
                CGImageDestinationAddImage(destination, image, NULL);
                ok = CGImageDestinationFinalize(destination) ? ok : 0;
            } else {
                ok = 0;
            }
            if (destination) CFRelease(destination);
            if (image) CGImageRelease(image);
            if (space) CGColorSpaceRelease(space);
            if (provider) CGDataProviderRelease(provider);
        }
        return ok;
    }
}

/* ---- Performance analysis: command buffer GPU times and a Metal capture ---- */

/* GPU start and end time of a completed command buffer (seconds, Metal GPU clock). */
int k6d_metal_command_buffer_times(void *command_buffer, double *start, double *end)
{
    if (!command_buffer) {
        return 0;
    }
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    if (start) *start = cb.GPUStartTime;
    if (end) *end = cb.GPUEndTime;
    return 1;
}

/* Starts a Metal capture of everything on the device into a .gputrace package at path (the
   process needs METAL_CAPTURE_ENABLED=1); open the result in Xcode. Returns 1 on success. */
int k6d_metal_capture_start(void *device, const char *path)
{
    @autoreleasepool {
        if (!device || !path) {
            return 0;
        }
        MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
        if (![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
            fprintf(stderr, "k6d: GPU trace documents are not supported (METAL_CAPTURE_ENABLED=1 missing?)\n");
            return 0;
        }
        MTLCaptureDescriptor *desc = [MTLCaptureDescriptor new];
        desc.captureObject = (__bridge id<MTLDevice>)device;
        desc.destination = MTLCaptureDestinationGPUTraceDocument;
        desc.outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        NSError *error = nil;
        if (![manager startCaptureWithDescriptor:desc error:&error]) {
            fprintf(stderr, "k6d: capture failed: %s\n", error.localizedDescription.UTF8String);
            return 0;
        }
        return 1;
    }
}

void k6d_metal_capture_stop(void)
{
    [[MTLCaptureManager sharedCaptureManager] stopCapture];
}
