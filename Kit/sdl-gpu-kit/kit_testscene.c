/*
 * kit_testscene.c — SDL_GPU-Kit für visionOS, Testszene Stufen K0 und K1a.
 *
 * Nur SDL3-API plus die Metal-Hilfen aus kit_testscene_metal.h für den Host-Queue-Test.
 * Jede Zeile beginnt mit "[c64-kit]" und nennt den Schritt; bei einem Fehlschlag folgt der
 * Text von SDL_GetError(). Siehe kit_testscene.h.
 *
 * Belegte Voraussetzungen (SDL main 4cfdb71ee):
 *  - Ein GPU-Device braucht ein initialisiertes Video-Subsystem (src/gpu/SDL_gpu.c:611,
 *    "Video subsystem not initialized" in SDL_GPUSelectBackend).
 *  - Auf iOS/visionOS ist SDL_MAIN_NEEDED gesetzt; SDL_Init scheitert ohne SDL_SetMainReady
 *    (src/SDL.c:200-202, 345-346).
 *  - Der Metal-Treiber verlangt die Property SHADERS_MSL oder SHADERS_METALLIB und einen
 *    Video-Treiber mit Metal_CreateView (src/gpu/metal/SDL_gpu_metal.m:4363-4378).
 *  - K1a: SDL_CreateGPUDevice/SDL_DestroyGPUDevice prüfen keinen Thread (SDL_gpu.c,
 *    SDL_gpu_metal.m ohne SDL_IsMainThread); nur SDL_Init(VIDEO) gehört auf den Hauptthread.
 */

#include "kit_testscene.h"
#include "kit_testscene_metal.h"

#include <SDL3/SDL.h>
/* SDL_SetMainReady steht nur in SDL_main.h; SDL_MAIN_HANDLED verhindert, dass der Header main()
 * umdefiniert (SDL_main.h:570-583). Der Host (SwiftUI-App, CLI) hat sein eigenes main. */
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define KIT_LINE_MAX 1024

typedef struct kit_ctx {
    kit_log_fn log;
    void *user;
    char line[KIT_LINE_MAX];
} kit_ctx;

static void kit_logf(kit_ctx *ctx, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    SDL_vsnprintf(ctx->line, sizeof(ctx->line), fmt, ap);
    va_end(ap);
    if (ctx->log) {
        ctx->log(ctx->line, ctx->user);
    }
}

static void kit_fail(kit_ctx *ctx, const char *step)
{
    const char *err = SDL_GetError();
    kit_logf(ctx, "[c64-kit] FAIL step=%s error=\"%s\"", step, (err && *err) ? err : "(kein SDL-Fehlertext)");
}

static double kit_ms_since(Uint64 start)
{
    return (double)(SDL_GetPerformanceCounter() - start) * 1000.0 / (double)SDL_GetPerformanceFrequency();
}

/* Shader-Formate als Namen, Bitmaske aus SDL_gpu.h (SDL_GPU_SHADERFORMAT_*). */
static void kit_format_names(SDL_GPUShaderFormat formats, char *out, size_t cap)
{
    static const struct { SDL_GPUShaderFormat bit; const char *name; } table[] = {
        { SDL_GPU_SHADERFORMAT_PRIVATE, "private" },
        { SDL_GPU_SHADERFORMAT_SPIRV, "spirv" },
        { SDL_GPU_SHADERFORMAT_DXBC, "dxbc" },
        { SDL_GPU_SHADERFORMAT_DXIL, "dxil" },
        { SDL_GPU_SHADERFORMAT_MSL, "msl" },
        { SDL_GPU_SHADERFORMAT_METALLIB, "metallib" },
    };
    out[0] = '\0';
    for (size_t i = 0; i < SDL_arraysize(table); i++) {
        if (formats & table[i].bit) {
            if (out[0]) {
                SDL_strlcat(out, ",", cap);
            }
            SDL_strlcat(out, table[i].name, cap);
        }
    }
    if (!out[0]) {
        SDL_strlcpy(out, "-", cap);
    }
}

static bool kit_init_sdl(kit_ctx *ctx)
{
    const Uint64 t0 = SDL_GetPerformanceCounter();
    SDL_SetMainReady(); /* SDL_MAIN_NEEDED auf iOS/visionOS, SDL.c:345 */
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        kit_fail(ctx, "init");
        return false;
    }
    const char *video = SDL_GetCurrentVideoDriver();
    kit_logf(ctx, "[c64-kit] step=init subsystems=video videoDriver=%s ms=%.1f",
             video ? video : "(keiner)", kit_ms_since(t0));
    return true;
}

bool kit_testscene_init_sdl(kit_log_fn log, void *user)
{
    kit_ctx ctx;
    SDL_zero(ctx);
    ctx.log = log;
    ctx.user = user;
    return kit_init_sdl(&ctx);
}

void kit_testscene_quit_sdl(void)
{
    SDL_Quit();
}

int kit_testscene_run(const kit_testscene_options *options, kit_log_fn log, void *user)
{
    kit_ctx ctx;
    SDL_zero(ctx);
    ctx.log = log;
    ctx.user = user;

    kit_testscene_options opt;
    if (options) {
        opt = *options;
    } else {
        SDL_zero(opt);
        opt.init_sdl = true;
        opt.quit_sdl = true;
    }
    const Uint32 width = (opt.width > 0) ? (Uint32)opt.width : 256;
    const Uint32 height = (opt.height > 0) ? (Uint32)opt.height : 256;
    const bool inject = (opt.metal_device != NULL) || (opt.metal_queue != NULL);

    int result = KIT_STEP_OK;
    bool sdl_initialized = false;
    SDL_GPUDevice *device = NULL;
    SDL_GPUTexture *texture = NULL;
    SDL_GPUTransferBuffer *transfer = NULL;
    SDL_GPUFence *fence = NULL;

    /* ---- Versionen: gelinkte Bibliothek gegen kompilierten Header ---- */
    {
        const int linked = SDL_GetVersion();
        const char *revision = SDL_GetRevision();
        kit_logf(&ctx, "[c64-kit] step=version linked=%d.%d.%d compiled=%d.%d.%d revision=\"%s\" platform=%s mode=%s",
                 SDL_VERSIONNUM_MAJOR(linked), SDL_VERSIONNUM_MINOR(linked), SDL_VERSIONNUM_MICRO(linked),
                 SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_MICRO_VERSION,
                 (revision && *revision) ? revision : "(leer)", SDL_GetPlatform(),
                 inject ? "inject" : "basic");
    }

    /* ---- Schritt 1: SDL_Init(VIDEO), Pflicht für SDL_GPU (SDL_gpu.c:611) ---- */
    if (opt.init_sdl) {
        if (!kit_init_sdl(&ctx)) {
            result = KIT_STEP_INIT;
            goto done;
        }
        sdl_initialized = true;
    } else {
        const char *video = SDL_GetCurrentVideoDriver();
        kit_logf(&ctx, "[c64-kit] step=init skipped videoDriver=%s", video ? video : "(keiner)");
        if (video == NULL) {
            SDL_SetError("Video-Subsystem nicht initialisiert; kit_testscene_init_sdl zuerst rufen");
            kit_fail(&ctx, "init");
            result = KIT_STEP_INIT;
            goto done;
        }
    }

    /* GPU-Treiber, die in dieser SDL-Bibliothek einkompiliert sind. */
    {
        char drivers[256] = "";
        const int n = SDL_GetNumGPUDrivers();
        for (int i = 0; i < n; i++) {
            if (drivers[0]) {
                SDL_strlcat(drivers, ",", sizeof(drivers));
            }
            SDL_strlcat(drivers, SDL_GetGPUDriver(i), sizeof(drivers));
        }
        kit_logf(&ctx, "[c64-kit] step=drivers count=%d names=%s", n, drivers[0] ? drivers : "-");
    }

    /* ---- Schritt 2: Device. MSL+METALLIB erlauben den Metal-Treiber (SDL_gpu_metal.m:4369).
     *      K1a: Host-Device und/oder Host-Queue über die P1-Properties einspeisen. ---- */
    void *sdl_metal_device = NULL;
    void *sdl_metal_queue = NULL;
    {
        const Uint64 t0 = SDL_GetPerformanceCounter();
        SDL_PropertiesID props = SDL_CreateProperties();
        SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true);
        SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_METALLIB_BOOLEAN, true);
        SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
        SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, opt.debug_mode);
#ifdef SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER
        if (opt.metal_device) {
            SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER, opt.metal_device);
        }
        if (opt.metal_queue) {
            SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_QUEUE_POINTER, opt.metal_queue);
        }
#else
        if (inject) {
            kit_logf(&ctx, "[c64-kit] WARN inject angefordert, aber die SDL-Header kennen P1 nicht (ohne Patch gebaut)");
        }
#endif
        device = SDL_CreateGPUDeviceWithProperties(props);
        SDL_DestroyProperties(props);
        if (!device) {
            kit_fail(&ctx, "device");
            result = KIT_STEP_DEVICE;
            goto done;
        }
        char formats[64];
        kit_format_names(SDL_GetGPUShaderFormats(device), formats, sizeof(formats));
        const SDL_PropertiesID dp = SDL_GetGPUDeviceProperties(device);
#ifdef SDL_PROP_GPU_DEVICE_METAL_DEVICE_POINTER
        sdl_metal_device = SDL_GetPointerProperty(dp, SDL_PROP_GPU_DEVICE_METAL_DEVICE_POINTER, NULL);
        sdl_metal_queue = SDL_GetPointerProperty(dp, SDL_PROP_GPU_DEVICE_METAL_COMMAND_QUEUE_POINTER, NULL);
#endif
        kit_logf(&ctx, "[c64-kit] step=device driver=%s shaderFormats=%s debug=%d name=\"%s\" metalDevice=%p metalQueue=%p ms=%.1f",
                 SDL_GetGPUDeviceDriver(device), formats, opt.debug_mode ? 1 : 0,
                 SDL_GetStringProperty(dp, SDL_PROP_GPU_DEVICE_NAME_STRING, "-"),
                 sdl_metal_device, sdl_metal_queue, kit_ms_since(t0));
    }

    /* ---- K1a: Zeigervergleich Host gegen SDL ---- */
    if (inject) {
        /* Erwartung je nach Modus: Device gesetzt → gleiches Device; Queue gesetzt → gleiche
         * Queue und SDLs Device = Device der Queue; nur Device → SDL hat eine eigene Queue
         * auf diesem Device. */
        void *expected_device = opt.metal_device ? opt.metal_device : kit_metal_queue_device(opt.metal_queue);
        const bool same_device = (sdl_metal_device != NULL) && (sdl_metal_device == expected_device);
        const bool same_queue = (opt.metal_queue != NULL) && (sdl_metal_queue == opt.metal_queue);
        const bool queue_on_device = (sdl_metal_queue != NULL) && (kit_metal_queue_device(sdl_metal_queue) == expected_device);
        const bool ok = same_device && queue_on_device && (opt.metal_queue == NULL || same_queue);
        char name[128];
        kit_logf(&ctx, "[c64-kit] step=inject host.device=%p host.queue=%p sdl.device=%p sdl.queue=%p sameDevice=%d sameQueue=%d queueOnDevice=%d ok=%d name=\"%s\"",
                 opt.metal_device, opt.metal_queue, sdl_metal_device, sdl_metal_queue,
                 same_device ? 1 : 0, same_queue ? 1 : 0, queue_on_device ? 1 : 0, ok ? 1 : 0,
                 kit_metal_device_name(expected_device, name, sizeof(name)));
        if (!ok) {
            SDL_SetError("SDL nutzt nicht die eingespeisten Metal-Objekte");
            kit_fail(&ctx, "inject");
            result = KIT_STEP_INJECT;
            goto done;
        }
    }

    /* ---- Schritt 3: eigene Textur als Farbziel ---- */
    const SDL_GPUTextureFormat format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    {
        const bool supported = SDL_GPUTextureSupportsFormat(device, format, SDL_GPU_TEXTURETYPE_2D,
                                                            SDL_GPU_TEXTUREUSAGE_COLOR_TARGET);
        SDL_GPUTextureCreateInfo info;
        SDL_zero(info);
        info.type = SDL_GPU_TEXTURETYPE_2D;
        info.format = format;
        info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
        info.width = width;
        info.height = height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = SDL_GPU_SAMPLECOUNT_1;
        texture = SDL_CreateGPUTexture(device, &info);
        if (!texture) {
            kit_fail(&ctx, "texture");
            result = KIT_STEP_TEXTURE;
            goto done;
        }
        kit_logf(&ctx, "[c64-kit] step=texture format=R8G8B8A8_UNORM size=%ux%u colorTargetSupported=%d",
                 width, height, supported ? 1 : 0);
    }

    /* ---- Schritt 4: Transfer-Puffer für das Rücklesen ---- */
    const Uint32 pixel_bytes = 4;
    const Uint32 download_bytes = width * height * pixel_bytes;
    {
        SDL_GPUTransferBufferCreateInfo info;
        SDL_zero(info);
        info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        info.size = download_bytes;
        transfer = SDL_CreateGPUTransferBuffer(device, &info);
        if (!transfer) {
            kit_fail(&ctx, "transfer");
            result = KIT_STEP_TRANSFER;
            goto done;
        }
    }

    /* ---- Schritt 5: Command Buffer ---- */
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(device);
    if (!cmd) {
        kit_fail(&ctx, "cmdbuf");
        result = KIT_STEP_CMDBUF;
        goto done;
    }

    /* ---- Schritt 6: Clear-Pass (0.25, 0.5, 0.75, 1.0) ---- */
    const SDL_FColor clear = { 0.25f, 0.5f, 0.75f, 1.0f };
    {
        SDL_GPUColorTargetInfo target;
        SDL_zero(target);
        target.texture = texture;
        target.clear_color = clear;
        target.load_op = SDL_GPU_LOADOP_CLEAR;
        target.store_op = SDL_GPU_STOREOP_STORE;
        SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &target, 1, NULL);
        if (!pass) {
            kit_fail(&ctx, "renderpass");
            SDL_CancelGPUCommandBuffer(cmd);
            result = KIT_STEP_RENDERPASS;
            goto done;
        }
        SDL_EndGPURenderPass(pass);
        kit_logf(&ctx, "[c64-kit] step=renderpass clear=%.2f,%.2f,%.2f,%.2f draws=0",
                 clear.r, clear.g, clear.b, clear.a);
    }

    /* ---- Schritt 7: Textur in den Transfer-Puffer kopieren ---- */
    {
        SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
        if (!copy) {
            kit_fail(&ctx, "copypass");
            SDL_CancelGPUCommandBuffer(cmd);
            result = KIT_STEP_COPYPASS;
            goto done;
        }
        SDL_GPUTextureRegion src;
        SDL_zero(src);
        src.texture = texture;
        src.w = width;
        src.h = height;
        src.d = 1;
        SDL_GPUTextureTransferInfo dst;
        SDL_zero(dst);
        dst.transfer_buffer = transfer;
        dst.pixels_per_row = width;
        dst.rows_per_layer = height;
        SDL_DownloadFromGPUTexture(copy, &src, &dst);
        SDL_EndGPUCopyPass(copy);
    }

    /* ---- Schritt 8: Abschicken und auf den Fence warten ---- */
    {
        const Uint64 t0 = SDL_GetPerformanceCounter();
        fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (!fence) {
            kit_fail(&ctx, "submit");
            result = KIT_STEP_SUBMIT;
            goto done;
        }
        if (!SDL_WaitForGPUFences(device, true, &fence, 1)) {
            kit_fail(&ctx, "wait");
            result = KIT_STEP_SUBMIT;
            goto done;
        }
        kit_logf(&ctx, "[c64-kit] step=submit fenceSignaled=%d ms=%.1f",
                 SDL_QueryGPUFence(device, fence) ? 1 : 0, kit_ms_since(t0));
    }

    /* ---- Schritt 9: Pixel lesen und mit der Clear-Farbe vergleichen ---- */
    {
        const Uint8 *pixels = (const Uint8 *)SDL_MapGPUTransferBuffer(device, transfer, false);
        if (!pixels) {
            kit_fail(&ctx, "map");
            result = KIT_STEP_READBACK;
            goto done;
        }
        const Uint8 expected[4] = {
            (Uint8)(clear.r * 255.0f + 0.5f), (Uint8)(clear.g * 255.0f + 0.5f),
            (Uint8)(clear.b * 255.0f + 0.5f), (Uint8)(clear.a * 255.0f + 0.5f)
        };
        const Uint32 center = ((height / 2) * width + (width / 2)) * pixel_bytes;
        const Uint8 *p0 = pixels;
        const Uint8 *pc = pixels + center;
        bool ok = true;
        for (int i = 0; i < 4; i++) {
            /* Toleranz 1 für die Rundung 0.75*255 = 191.25 im Backend. */
            if (SDL_abs((int)p0[i] - (int)expected[i]) > 1 || SDL_abs((int)pc[i] - (int)expected[i]) > 1) {
                ok = false;
            }
        }
        kit_logf(&ctx, "[c64-kit] step=readback pixel00=%u,%u,%u,%u center=%u,%u,%u,%u expected=%u,%u,%u,%u ok=%d",
                 p0[0], p0[1], p0[2], p0[3], pc[0], pc[1], pc[2], pc[3],
                 expected[0], expected[1], expected[2], expected[3], ok ? 1 : 0);
        SDL_UnmapGPUTransferBuffer(device, transfer);
        if (!ok) {
            SDL_SetError("Pixel weicht von der Clear-Farbe ab");
            kit_fail(&ctx, "readback");
            result = KIT_STEP_READBACK;
            goto done;
        }
    }

done:
    if (fence) {
        SDL_ReleaseGPUFence(device, fence);
    }
    if (transfer) {
        SDL_ReleaseGPUTransferBuffer(device, transfer);
    }
    if (texture) {
        SDL_ReleaseGPUTexture(device, texture);
    }
    if (device) {
        SDL_DestroyGPUDevice(device);
        device = NULL;
    }

    /* ---- K1a: Host-Queue nach SDL_DestroyGPUDevice weiter brauchbar? ---- */
    if (opt.metal_queue && result == KIT_STEP_OK) {
        char status[256];
        const bool ok = kit_metal_hostqueue_check(opt.metal_queue, status, sizeof(status));
        kit_logf(&ctx, "[c64-kit] step=hostqueue-after-destroy ok=%d %s", ok ? 1 : 0, status);
        if (!ok) {
            result = KIT_STEP_HOSTQUEUE;
        }
    }

    if (sdl_initialized && opt.quit_sdl) {
        SDL_Quit();
    }
    kit_logf(&ctx, "[c64-kit] result=%s failedStep=%d mode=%s", (result == KIT_STEP_OK) ? "ok" : "fail", result,
             inject ? "inject" : "basic");
    return result;
}
