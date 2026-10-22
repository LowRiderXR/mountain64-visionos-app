// k6d_metal.m — kleiner Metal-Helfer für Celeste64.MacHost (K6d.1, F3; K6e.2, F5). Stellt dem Host
// das, was auf der Brille CompositorServices liefert: ein Metal-Device und eine Queue (P1), eine
// vorhandene 2D-Array-Textur, die Foster über die SDL-Property
// SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER importiert (P3), und eine Rasterization Rate
// Map mit zwei Schichten samt Koordinatenabbildung für das Messbild (P4). Kein SDL-Bezug; Foster
// kennt kein Metal. Besitz: Der Host hält die Metal-Objekte und gibt sie mit k6d_metal_release
// frei; SDL hält nur seine eigene Referenz (K1b). Vorlage: Kit/sdl-gpu-kit/kit_testscene_metal.m
// (kit_metal_create_array_texture_ex), hier mit den Pixelformaten, die Fosters TextureFormat.Color
// (RGBA8Unorm) und Depth16 (Depth16Unorm) entsprechen.
//
// Bau (scripts/celeste-mac.sh machost):
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

/* kind 0: RGBA8Unorm, Render-Target und Shader-Read (damit SDL die Schicht blitten kann);
   kind 1: Depth16Unorm, kind 2: Depth32Float (wie die Drawable-Tiefe der Brille), nur Render-Target. */
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

/* ---- K6e.2 (F5): Rasterization Rate Map des Hosts, Vorbild kit_metal_create_rate_map ---- */

int k6d_metal_supports_rate_map(void *device, unsigned layers)
{
    if (!device) {
        return 0;
    }
    id<MTLDevice> d = (__bridge id<MTLDevice>)device;
    return [d supportsRasterizationRateMapWithLayerCount:layers] ? 1 : 0;
}

/* Zweischicht-Map (oder mehr) mit demselben Profil in jeder Schicht und in beiden Achsen:
   1,0 im ersten Drittel, edge_quality danach, samples Stützstellen pro Achse (Metal
   interpoliert). Gleiche vertikale Kurve in allen Schichten ist Pflicht (Plattformwissen K3,
   sonst fällt V stumm aus); die Compositor-Map hat ebenfalls gleich grosse Schichten. */
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

/* Logische Grösse, physische Grösse einer Schicht und Schichtzahl der Map. */
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

/* Logische Bildschirmkoordinate → physische Texturkoordinate einer Schicht (Soll für das Messbild). */
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
