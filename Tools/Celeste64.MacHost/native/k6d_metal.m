// k6d_metal.m — kleiner Metal-Helfer für Celeste64.MacHost (K6d.1, F3). Stellt dem Host das,
// was auf der Brille CompositorServices liefert: ein Metal-Device und eine Queue (P1) und eine
// vorhandene 2D-Array-Textur, die Foster über die SDL-Property
// SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER importiert (P3). Kein SDL-Bezug; Foster
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
