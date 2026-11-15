/*
 * kit_import.c — SDL_GPU kit for visionOS, import stage. See kit_import.h.
 */

#include "kit_import.h"
#include "kit_testscene_metal.h"

#include <SDL3/SDL.h>

#include <stdarg.h>
#include <string.h>

#define KIT_LINE_MAX 1024
#define KIT_DISTINCT_MAX 16
#define KIT_ROTATION_FRAMES 600

struct kit_import_session {
    kit_log_fn log;
    void *user;
    SDL_GPUDevice *device;
    bool first_logged;
    Uint64 last_fail_log;
    void *distinct_color[KIT_DISTINCT_MAX];
    void *distinct_depth[KIT_DISTINCT_MAX];
    kit_import_stats stats;
    /* diagnostics */
    bool wait_for_gpu;
    unsigned verify_every;
    SDL_GPUTransferBuffer *verify_buffer;
    bool verify_pending;
    unsigned char verify_pixel[4];
    char line[KIT_LINE_MAX];
};

bool kit_import_last_verify(kit_import_session *s, unsigned char out[4])
{
    if (!s || !s->verify_pending) {
        return false;
    }
    SDL_memcpy(out, s->verify_pixel, 4);
    s->verify_pending = false;
    return true;
}

static void kit_logf(kit_import_session *s, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    SDL_vsnprintf(s->line, sizeof(s->line), fmt, ap);
    va_end(ap);
    if (s->log) {
        s->log(s->line, s->user);
    }
}

static double kit_ms_since(Uint64 start)
{
    return (double)(SDL_GetPerformanceCounter() - start) * 1000.0 / (double)SDL_GetPerformanceFrequency();
}

static const char *kit_format_name(int sdl_format)
{
    switch (sdl_format) {
    case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB: return "B8G8R8A8_UNORM_SRGB";
    case SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM: return "B8G8R8A8_UNORM";
    case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB: return "R8G8B8A8_UNORM_SRGB";
    case SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM: return "R8G8B8A8_UNORM";
    case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT: return "R16G16B16A16_FLOAT";
    case SDL_GPU_TEXTUREFORMAT_R16G16B16A16_UNORM: return "R16G16B16A16_UNORM";
    case SDL_GPU_TEXTUREFORMAT_D32_FLOAT: return "D32_FLOAT";
    case SDL_GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT: return "D32_FLOAT_S8_UINT";
    case SDL_GPU_TEXTUREFORMAT_D16_UNORM: return "D16_UNORM";
    default: return "unknown";
    }
}

/* Derive the create info from the MTLTexture and import. NULL on error; the SDL error text is
 * in SDL_GetError(). With override_format / override_layers (>= 0) for negative tests. */
static SDL_GPUTexture *kit_wrap(SDL_GPUDevice *device, void *mtl_texture, bool depth,
                                int override_format, int override_layers, kit_metal_texture_desc *desc_out)
{
    kit_metal_texture_desc desc;
    if (!kit_metal_texture_info(mtl_texture, &desc)) {
        SDL_SetError("MTLTexture description not readable");
        return NULL;
    }
    if (desc_out) {
        *desc_out = desc;
    }
    if (desc.sdl_type < 0) {
        SDL_SetError("MTLTexture type %d has no SDL counterpart", desc.mtl_type);
        return NULL;
    }
    if (desc.sdl_format == SDL_GPU_TEXTUREFORMAT_INVALID && override_format < 0) {
        SDL_SetError("MTLPixelFormat %d has no SDL counterpart", desc.mtl_pixel_format);
        return NULL;
    }

    SDL_GPUTextureCreateInfo info;
    SDL_zero(info);
    info.type = (SDL_GPUTextureType)desc.sdl_type;
    info.format = (override_format >= 0) ? (SDL_GPUTextureFormat)override_format : (SDL_GPUTextureFormat)desc.sdl_format;
    info.usage = depth ? SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET : SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    info.width = desc.width;
    info.height = desc.height;
    info.layer_count_or_depth = (override_layers >= 0) ? (Uint32)override_layers : desc.layers;
    info.num_levels = desc.levels;
    info.sample_count = SDL_GPU_SAMPLECOUNT_1;
    info.props = SDL_CreateProperties();
#ifdef SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER
    SDL_SetPointerProperty(info.props, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtl_texture);
#else
    SDL_DestroyProperties(info.props);
    SDL_SetError("SDL headers without external textures (SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER missing)");
    return NULL;
#endif
    SDL_GPUTexture *texture = SDL_CreateGPUTexture(device, &info);
    SDL_DestroyProperties(info.props);
    return texture;
}

/* Clear all layers of an imported colour and depth texture, one pass per layer.
 * rgba_per_layer/depth_per_layer: one entry per layer or NULL for the uniform value. */
static bool kit_clear_layers(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *color, SDL_GPUTexture *depth,
                             unsigned layers, const float *rgba, float depth_value,
                             const float (*rgba_per_layer)[4], const float *depth_per_layer)
{
    for (unsigned layer = 0; layer < layers; layer++) {
        const float *c = rgba_per_layer ? rgba_per_layer[layer] : rgba;
        SDL_GPUColorTargetInfo ct;
        SDL_zero(ct);
        ct.texture = color;
        ct.layer_or_depth_plane = layer;
        ct.clear_color.r = c[0];
        ct.clear_color.g = c[1];
        ct.clear_color.b = c[2];
        ct.clear_color.a = c[3];
        ct.load_op = SDL_GPU_LOADOP_CLEAR;
        ct.store_op = SDL_GPU_STOREOP_STORE;

        SDL_GPUDepthStencilTargetInfo dt;
        SDL_zero(dt);
        dt.texture = depth;
        dt.clear_depth = depth_per_layer ? depth_per_layer[layer] : depth_value;
        dt.load_op = SDL_GPU_LOADOP_CLEAR;
        dt.store_op = SDL_GPU_STOREOP_STORE;
        dt.stencil_load_op = SDL_GPU_LOADOP_DONT_CARE;
        dt.stencil_store_op = SDL_GPU_STOREOP_DONT_CARE;
        dt.layer = (Uint8)layer;

        SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &ct, 1, depth ? &dt : NULL);
        if (!pass) {
            return false;
        }
        SDL_EndGPURenderPass(pass);
    }
    return true;
}

static unsigned kit_note_distinct(void **list, void *ptr)
{
    unsigned count = 0;
    for (unsigned i = 0; i < KIT_DISTINCT_MAX; i++) {
        if (list[i] == ptr) {
            /* known: count the entries */
            for (unsigned j = 0; j < KIT_DISTINCT_MAX && list[j]; j++) count++;
            return count;
        }
        if (list[i] == NULL) {
            list[i] = ptr;
            return i + 1;
        }
    }
    return KIT_DISTINCT_MAX;
}

kit_import_session *kit_import_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user)
{
    kit_import_session *s = (kit_import_session *)SDL_calloc(1, sizeof(kit_import_session));
    s->log = log;
    s->user = user;

    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_MSL_BOOLEAN, true);
    SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_SHADERS_METALLIB_BOOLEAN, true);
    SDL_SetBooleanProperty(props, SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, false);
#ifdef SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER
    if (metal_device) {
        SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_DEVICE_POINTER, metal_device);
    }
    if (metal_queue) {
        SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_QUEUE_POINTER, metal_queue);
    }
#endif
    s->device = SDL_CreateGPUDeviceWithProperties(props);
    SDL_DestroyProperties(props);
    if (!s->device) {
        kit_logf(s, "[c64-kit] FAIL step=import-begin error=\"%s\"", SDL_GetError());
        SDL_free(s);
        return NULL;
    }
    void *sdl_device = NULL;
    void *sdl_queue = NULL;
#ifdef SDL_PROP_GPU_DEVICE_METAL_DEVICE_POINTER
    const SDL_PropertiesID dp = SDL_GetGPUDeviceProperties(s->device);
    sdl_device = SDL_GetPointerProperty(dp, SDL_PROP_GPU_DEVICE_METAL_DEVICE_POINTER, NULL);
    sdl_queue = SDL_GetPointerProperty(dp, SDL_PROP_GPU_DEVICE_METAL_COMMAND_QUEUE_POINTER, NULL);
#endif
    kit_logf(s, "[c64-kit] step=import-begin host.device=%p host.queue=%p sdl.device=%p sdl.queue=%p same=%d revision=\"%s\"",
             metal_device, metal_queue, sdl_device, sdl_queue,
             (sdl_device == metal_device && sdl_queue == metal_queue) ? 1 : 0, SDL_GetRevision());
    return s;
}

void kit_import_set_diagnostics(kit_import_session *s, bool wait_for_gpu, unsigned verify_every)
{
    if (!s) {
        return;
    }
    s->wait_for_gpu = wait_for_gpu;
    s->verify_every = verify_every;
    if (verify_every > 0 && !s->verify_buffer) {
        SDL_GPUTransferBufferCreateInfo info;
        SDL_zero(info);
        info.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        info.size = 64; /* one pixel, generous */
        s->verify_buffer = SDL_CreateGPUTransferBuffer(s->device, &info);
    }
    kit_logf(s, "[c64-kit] step=import-diagnostics wait=%d verifyEvery=%u verifyBuffer=%d",
             wait_for_gpu ? 1 : 0, verify_every, s->verify_buffer ? 1 : 0);
}

static void kit_import_fail(kit_import_session *s, const char *step, SDL_GPUCommandBuffer *cmd,
                            SDL_GPUTexture *color, SDL_GPUTexture *depth)
{
    s->stats.fails += 1;
    s->stats.fails_total += 1;
    const Uint64 now = SDL_GetPerformanceCounter();
    if (s->last_fail_log == 0 || (double)(now - s->last_fail_log) / (double)SDL_GetPerformanceFrequency() >= 1.0) {
        s->last_fail_log = now;
        kit_logf(s, "[c64-kit] FAIL step=%s frame=%lu failsTotal=%lu error=\"%s\"", step,
                 s->stats.frames_total, s->stats.fails_total, SDL_GetError());
    }
    if (cmd) {
        SDL_CancelGPUCommandBuffer(cmd);
    }
    if (color) {
        SDL_ReleaseGPUTexture(s->device, color);
        s->stats.wrappers_released += 1;
    }
    if (depth) {
        SDL_ReleaseGPUTexture(s->device, depth);
        s->stats.wrappers_released += 1;
    }
}

bool kit_import_clear_frame(kit_import_session *s, void *color_texture, void *depth_texture,
                            const float rgba[4], float depth_value)
{
    if (!s || !s->device) {
        return false;
    }
    const Uint64 t0 = SDL_GetPerformanceCounter();
    s->stats.frames += 1;
    s->stats.frames_total += 1;

    kit_metal_texture_desc cdesc, ddesc;
    SDL_GPUTexture *color = kit_wrap(s->device, color_texture, false, -1, -1, &cdesc);
    if (!color) {
        kit_import_fail(s, "import-color", NULL, NULL, NULL);
        return false;
    }
    s->stats.wrappers_created += 1;
    SDL_GPUTexture *depth = NULL;
    if (depth_texture) {
        depth = kit_wrap(s->device, depth_texture, true, -1, -1, &ddesc);
        if (!depth) {
            kit_import_fail(s, "import-depth", NULL, color, NULL);
            return false;
        }
        s->stats.wrappers_created += 1;
    } else {
        SDL_zero(ddesc);
    }

    if (!s->first_logged) {
        s->first_logged = true;
        kit_logf(s, "[c64-kit] step=import color{type=%s format=%s size=%ux%u layers=%u levels=%u mtl=%p sdl=%p} depth{type=%s format=%s size=%ux%u layers=%u mtl=%p sdl=%p}",
                 cdesc.sdl_type == SDL_GPU_TEXTURETYPE_2D_ARRAY ? "2D_ARRAY" : "2D", kit_format_name(cdesc.sdl_format),
                 cdesc.width, cdesc.height, cdesc.layers, cdesc.levels, color_texture, (void *)color,
                 depth_texture ? (ddesc.sdl_type == SDL_GPU_TEXTURETYPE_2D_ARRAY ? "2D_ARRAY" : "2D") : "-",
                 depth_texture ? kit_format_name(ddesc.sdl_format) : "-",
                 ddesc.width, ddesc.height, ddesc.layers, depth_texture, (void *)depth);
    }
    if (s->stats.frames_total <= KIT_ROTATION_FRAMES) {
        const unsigned dc = kit_note_distinct(s->distinct_color, color_texture);
        const unsigned dd = depth_texture ? kit_note_distinct(s->distinct_depth, depth_texture) : 0;
        if (dc != s->stats.distinct_color || dd != s->stats.distinct_depth) {
            s->stats.distinct_color = dc;
            s->stats.distinct_depth = dd;
            kit_logf(s, "[c64-kit] step=import-rotation frame=%lu distinctColor=%u distinctDepth=%u color=%p depth=%p",
                     s->stats.frames_total, dc, dd, color_texture, depth_texture);
        }
    }

    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
    if (!cmd) {
        kit_import_fail(s, "import-cmdbuf", NULL, color, depth);
        return false;
    }
    if (!kit_clear_layers(cmd, color, depth, cdesc.layers, rgba, depth_value, NULL, NULL)) {
        kit_import_fail(s, "import-renderpass", cmd, color, depth);
        return false;
    }

    /* Diagnostics: read the centre pixel of layer 0 back after the clear (every verify_every frames). */
    const bool verify_now = (s->verify_every > 0) && s->verify_buffer && (s->stats.frames_total % s->verify_every == 1);
    if (verify_now) {
        SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
        if (copy) {
            SDL_GPUTextureRegion src;
            SDL_zero(src);
            src.texture = color;
            src.layer = 0;
            src.x = cdesc.width / 2;
            src.y = cdesc.height / 2;
            src.w = 1;
            src.h = 1;
            src.d = 1;
            SDL_GPUTextureTransferInfo dst;
            SDL_zero(dst);
            dst.transfer_buffer = s->verify_buffer;
            dst.pixels_per_row = 1;
            dst.rows_per_layer = 1;
            SDL_DownloadFromGPUTexture(copy, &src, &dst);
            SDL_EndGPUCopyPass(copy);
        }
    }

    if (s->wait_for_gpu || verify_now) {
        SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (!fence) {
            kit_import_fail(s, "import-submit", NULL, color, depth);
            return false;
        }
        const bool waited = SDL_WaitForGPUFences(s->device, true, &fence, 1);
        SDL_ReleaseGPUFence(s->device, fence);
        if (!waited) {
            kit_import_fail(s, "import-wait", NULL, color, depth);
            return false;
        }
        if (verify_now) {
            const Uint8 *p = (const Uint8 *)SDL_MapGPUTransferBuffer(s->device, s->verify_buffer, false);
            if (p) {
                /* Bytes in memory order; for BGRA8 that is B,G,R,A. Clear (0, 0.1, 0.3) in sRGB
                 * encoding expects about B=149, G=89, R=0, A=255. */
                kit_logf(s, "[c64-kit] step=import-verify frame=%lu layer=0 afterSDL=%u,%u,%u,%u (memory order, for BGRA8: b,g,r,a) format=%s",
                         s->stats.frames_total, p[0], p[1], p[2], p[3], kit_format_name(cdesc.sdl_format));
                SDL_memcpy(s->verify_pixel, p, 4);
                s->verify_pending = true;
                SDL_UnmapGPUTransferBuffer(s->device, s->verify_buffer);
            } else {
                kit_logf(s, "[c64-kit] step=import-verify frame=%lu map failed error=\"%s\"", s->stats.frames_total, SDL_GetError());
            }
        }
    } else if (!SDL_SubmitGPUCommandBuffer(cmd)) {
        kit_import_fail(s, "import-submit", NULL, color, depth);
        return false;
    }
    /* Release right after the submit: SDL destroys the wrapper only when the command buffer is
     * complete (referenceCount) and releases only its own reference. */
    SDL_ReleaseGPUTexture(s->device, color);
    s->stats.wrappers_released += 1;
    if (depth) {
        SDL_ReleaseGPUTexture(s->device, depth);
        s->stats.wrappers_released += 1;
    }

    const double ms = kit_ms_since(t0);
    s->stats.sum_ms += ms;
    if (ms > s->stats.max_ms) {
        s->stats.max_ms = ms;
    }
    return true;
}

void kit_import_take_stats(kit_import_session *s, kit_import_stats *out)
{
    if (!s || !out) {
        return;
    }
    *out = s->stats;
    s->stats.frames = 0;
    s->stats.fails = 0;
    s->stats.sum_ms = 0;
    s->stats.max_ms = 0;
}

void kit_import_end(kit_import_session *s)
{
    if (!s) {
        return;
    }
    if (s->device) {
        SDL_WaitForGPUIdle(s->device);
        if (s->verify_buffer) {
            SDL_ReleaseGPUTransferBuffer(s->device, s->verify_buffer);
        }
        SDL_DestroyGPUDevice(s->device);
    }
    kit_logf(s, "[c64-kit] step=import-end frames=%lu fails=%lu wrappers created=%lu released=%lu distinctColor=%u distinctDepth=%u",
             s->stats.frames_total, s->stats.fails_total, s->stats.wrappers_created, s->stats.wrappers_released,
             s->stats.distinct_color, s->stats.distinct_depth);
    SDL_free(s);
}

/* ------------------------------------------------------------------ Mac self-test */

typedef struct kit_self_ctx {
    kit_log_fn log;
    void *user;
    char line[KIT_LINE_MAX];
} kit_self_ctx;

static void self_logf(kit_self_ctx *ctx, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    SDL_vsnprintf(ctx->line, sizeof(ctx->line), fmt, ap);
    va_end(ap);
    if (ctx->log) {
        ctx->log(ctx->line, ctx->user);
    }
}

int kit_import_selftest(kit_log_fn log, void *user, bool debug_mode)
{
    kit_self_ctx ctx;
    SDL_zero(ctx);
    ctx.log = log;
    ctx.user = user;

    const unsigned W = 64, H = 64, LAYERS = 2;
    int result = 0;
    void *host_device = NULL, *host_queue = NULL;
    void *mtl_color = NULL, *mtl_depth = NULL;
    SDL_GPUTexture *color = NULL, *depth = NULL;
    SDL_GPUTransferBuffer *tcolor = NULL, *tdepth = NULL;
    SDL_GPUFence *fence = NULL;
    kit_import_session *s = NULL;

    if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-host error=\"device/queue not created\"");
        return 20;
    }
    s = kit_import_begin(host_device, host_queue, log, user);
    if (!s) {
        result = 21;
        goto done;
    }
    (void)debug_mode;

    if (!kit_metal_create_array_texture(host_device, false, W, H, LAYERS, &mtl_color) ||
        !kit_metal_create_array_texture(host_device, true, W, H, LAYERS, &mtl_depth)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-textures error=\"MTLTexture not created\"");
        result = 22;
        goto done;
    }

    /* import */
    kit_metal_texture_desc cdesc, ddesc;
    color = kit_wrap(s->device, mtl_color, false, -1, -1, &cdesc);
    if (!color) {
        self_logf(&ctx, "[c64-kit] FAIL step=import-color error=\"%s\"", SDL_GetError());
        result = 23;
        goto done;
    }
    depth = kit_wrap(s->device, mtl_depth, true, -1, -1, &ddesc);
    if (!depth) {
        self_logf(&ctx, "[c64-kit] FAIL step=import-depth error=\"%s\"", SDL_GetError());
        result = 23;
        goto done;
    }
    self_logf(&ctx, "[c64-kit] step=import color{type=%s format=%s size=%ux%u layers=%u mtl=%p sdl=%p} depth{type=%s format=%s size=%ux%u layers=%u mtl=%p sdl=%p}",
              cdesc.sdl_type == SDL_GPU_TEXTURETYPE_2D_ARRAY ? "2D_ARRAY" : "2D", kit_format_name(cdesc.sdl_format),
              cdesc.width, cdesc.height, cdesc.layers, mtl_color, (void *)color,
              ddesc.sdl_type == SDL_GPU_TEXTURETYPE_2D_ARRAY ? "2D_ARRAY" : "2D", kit_format_name(ddesc.sdl_format),
              ddesc.width, ddesc.height, ddesc.layers, mtl_depth, (void *)depth);

    /* One pass per layer: layer 0 red, depth 0.25; layer 1 blue, depth 0.75. Only 0 and 1 in
     * the colour, so the sRGB encoding plays no role in the read-back. */
    const float rgba[2][4] = { { 1.0f, 0.0f, 0.0f, 1.0f }, { 0.0f, 0.0f, 1.0f, 1.0f } };
    const float depths[2] = { 0.25f, 0.75f };
    const Uint32 pixel_bytes = 4;
    const Uint32 layer_bytes = W * H * pixel_bytes;

    SDL_GPUTransferBufferCreateInfo tinfo;
    SDL_zero(tinfo);
    tinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
    tinfo.size = layer_bytes * LAYERS;
    tcolor = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
    tdepth = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
    if (!tcolor || !tdepth) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-transfer error=\"%s\"", SDL_GetError());
        result = 24;
        goto done;
    }

    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
    if (!cmd) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-cmdbuf error=\"%s\"", SDL_GetError());
        result = 25;
        goto done;
    }
    if (!kit_clear_layers(cmd, color, depth, LAYERS, NULL, 0.0f, rgba, depths)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-renderpass error=\"%s\"", SDL_GetError());
        SDL_CancelGPUCommandBuffer(cmd);
        result = 26;
        goto done;
    }
    self_logf(&ctx, "[c64-kit] step=import-clear layers=%u layer0=%.2f,%.2f,%.2f,%.2f/%.2f layer1=%.2f,%.2f,%.2f,%.2f/%.2f",
              LAYERS, rgba[0][0], rgba[0][1], rgba[0][2], rgba[0][3], depths[0],
              rgba[1][0], rgba[1][1], rgba[1][2], rgba[1][3], depths[1]);

    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (!copy) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-copypass error=\"%s\"", SDL_GetError());
        SDL_CancelGPUCommandBuffer(cmd);
        result = 27;
        goto done;
    }
    for (unsigned layer = 0; layer < LAYERS; layer++) {
        SDL_GPUTextureRegion src;
        SDL_zero(src);
        src.layer = layer;
        src.w = W;
        src.h = H;
        src.d = 1;
        SDL_GPUTextureTransferInfo dst;
        SDL_zero(dst);
        dst.offset = layer * layer_bytes;
        dst.pixels_per_row = W;
        dst.rows_per_layer = H;

        src.texture = color;
        dst.transfer_buffer = tcolor;
        SDL_DownloadFromGPUTexture(copy, &src, &dst);
        src.texture = depth;
        dst.transfer_buffer = tdepth;
        SDL_DownloadFromGPUTexture(copy, &src, &dst);
    }
    SDL_EndGPUCopyPass(copy);

    fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (!fence || !SDL_WaitForGPUFences(s->device, true, &fence, 1)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-submit error=\"%s\"", SDL_GetError());
        result = 28;
        goto done;
    }

    /* Read-back: colour as BGRA bytes, depth as float. */
    {
        const Uint8 *cp = (const Uint8 *)SDL_MapGPUTransferBuffer(s->device, tcolor, false);
        const float *dpf = (const float *)SDL_MapGPUTransferBuffer(s->device, tdepth, false);
        if (!cp || !dpf) {
            self_logf(&ctx, "[c64-kit] FAIL step=selftest-map error=\"%s\"", SDL_GetError());
            result = 29;
            goto done;
        }
        bool all_ok = true;
        for (unsigned layer = 0; layer < LAYERS; layer++) {
            const Uint8 expected[4] = { (Uint8)(rgba[layer][2] * 255), (Uint8)(rgba[layer][1] * 255),
                                        (Uint8)(rgba[layer][0] * 255), (Uint8)(rgba[layer][3] * 255) }; /* B,G,R,A */
            const Uint32 center = ((H / 2) * W + (W / 2)) * pixel_bytes;
            const Uint8 *p0 = cp + layer * layer_bytes;
            const Uint8 *pc = p0 + center;
            const float d0 = dpf[layer * W * H];
            const float dc = dpf[layer * W * H + (H / 2) * W + (W / 2)];
            bool ok = true;
            for (int i = 0; i < 4; i++) {
                if (p0[i] != expected[i] || pc[i] != expected[i]) ok = false;
            }
            if (SDL_fabsf(d0 - depths[layer]) > 1e-6f || SDL_fabsf(dc - depths[layer]) > 1e-6f) ok = false;
            self_logf(&ctx, "[c64-kit] step=import-readback layer=%u color(bgra) pixel00=%u,%u,%u,%u center=%u,%u,%u,%u expected=%u,%u,%u,%u depth pixel00=%.4f center=%.4f expected=%.2f ok=%d",
                      layer, p0[0], p0[1], p0[2], p0[3], pc[0], pc[1], pc[2], pc[3],
                      expected[0], expected[1], expected[2], expected[3], d0, dc, depths[layer], ok ? 1 : 0);
            if (!ok) all_ok = false;
        }
        SDL_UnmapGPUTransferBuffer(s->device, tcolor);
        SDL_UnmapGPUTransferBuffer(s->device, tdepth);
        if (!all_ok) {
            result = 30;
            goto done;
        }
    }

    /* Negative tests: must fail, with error text. */
    {
        SDL_GPUTexture *bad = kit_wrap(s->device, mtl_color, false, SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, -1, NULL);
        const bool failed_format = (bad == NULL);
        self_logf(&ctx, "[c64-kit] step=import-negative case=wrongFormat(R8G8B8A8_UNORM) failed=%d error=\"%s\"",
                  failed_format ? 1 : 0, failed_format ? SDL_GetError() : "(no error, import succeeded)");
        if (bad) SDL_ReleaseGPUTexture(s->device, bad);

        bad = kit_wrap(s->device, mtl_color, false, -1, 1, NULL);
        const bool failed_layers = (bad == NULL);
        self_logf(&ctx, "[c64-kit] step=import-negative case=wrongLayers(1) failed=%d error=\"%s\"",
                  failed_layers ? 1 : 0, failed_layers ? SDL_GetError() : "(no error, import succeeded)");
        if (bad) SDL_ReleaseGPUTexture(s->device, bad);

        if (!failed_format || !failed_layers) {
            result = 31;
        }
    }

done:
    if (s && s->device) {
        if (fence) SDL_ReleaseGPUFence(s->device, fence);
        if (tcolor) SDL_ReleaseGPUTransferBuffer(s->device, tcolor);
        if (tdepth) SDL_ReleaseGPUTransferBuffer(s->device, tdepth);
        if (color) SDL_ReleaseGPUTexture(s->device, color);
        if (depth) SDL_ReleaseGPUTexture(s->device, depth);
    }
    if (s) {
        kit_import_end(s);
    }
    /* After destroying the SDL device the host textures must still be valid. */
    if (mtl_color || mtl_depth) {
        char status[128];
        const bool queue_ok = kit_metal_hostqueue_check(host_queue, status, sizeof(status));
        self_logf(&ctx, "[c64-kit] step=hostqueue-after-destroy ok=%d %s", queue_ok ? 1 : 0, status);
        kit_metal_release_texture(mtl_color);
        kit_metal_release_texture(mtl_depth);
        self_logf(&ctx, "[c64-kit] step=host-textures-released ok=1");
    }
    kit_metal_release_host_objects(host_device, host_queue);
    self_logf(&ctx, "[c64-kit] result=%s failedStep=%d mode=import", result == 0 ? "ok" : "fail", result);
    return result;
}
