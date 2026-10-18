/*
 * kit_multiview.c — SDL_GPU-Kit für visionOS, Stufen K2 (P6), K3 (P4), K4a (MSAA). Siehe kit_multiview.h.
 */

#include "kit_multiview.h"
#include "kit_shaders_generated.h"
#include "kit_testscene_metal.h"

#include <SDL3/SDL.h>

#include <stdarg.h>
#include <string.h>

#define KIT_LINE_MAX 1024
#define KIT_VIEW_COUNT 2
#define KIT_TAG_CAPACITY 256
#define KIT_GPU_SAMPLES 4096
#define KIT_GPU_SKIP_DEFAULT 90

static const char *const kit_depth_filter_names[3] = { "sample0", "min", "max" };

static void kit_logf(kit_multiview_session *s, const char *fmt, ...);

/* Muss dem cbuffer MultiviewUniforms in shaders/multiview.hlsl entsprechen (224 Bytes). */
typedef struct kit_mv_uniforms {
    float view_projection[KIT_VIEW_COUNT][16]; /* spaltenweise wie simd_float4x4 */
    float center[4];
    float right[4];
    float up[4];
    float view_color[KIT_VIEW_COUNT][4];
    float params[4]; /* x: 1 Schachbrett, 0 flache Farbe */
    /* K4b: Balken aus Geometrie (Vertices 6..11) */
    float bar_center[4];
    float bar_right[4];
    float bar_up[4];
} kit_mv_uniforms;

struct kit_multiview_session {
    kit_log_fn log;
    void *user;
    SDL_GPUDevice *device;
    SDL_GPUShader *vertex;
    SDL_GPUShader *fragment;
    SDL_GPUGraphicsPipeline *pipeline;
    SDL_GPUTextureFormat color_format;
    SDL_GPUTextureFormat depth_format;
    bool first_logged;
    Uint64 last_fail_log;
    kit_multiview_stats stats;
    /* K3: Messbild */
    SDL_GPUGraphicsPipeline *measure_pipeline;  /* RG32F, ohne Tiefe, view_count 2 */
    SDL_GPUTexture *measure_texture;            /* 2D-Array RG32F in physischer Grösse */
    SDL_GPUTransferBuffer *measure_transfer;
    unsigned measure_width;
    unsigned measure_height;
    unsigned measure_layers;
    /* K4a: MSAA */
    kit_multiview_options opt;
    SDL_GPUSampleCount msaa_sc;                 /* SDL-Enum zu opt.msaa_samples */
    void *metal_device;                         /* id<MTLDevice> (unretained), für die MSAA-Texturen */
    void *msaa_color_mtl;                       /* Host-Texturen 2DMultisampleArray in Drawable-Grösse */
    void *msaa_depth_mtl;
    SDL_GPUTexture *msaa_color;                 /* Wrapper, leben für die Sitzung */
    SDL_GPUTexture *msaa_depth;
    SDL_GPUTexture *measure_msaa;               /* RG32F MSAA (SDL-eigen) für das Messbild unter MSAA */
    bool msaa_logged;
    /* K4a: GPU-Zeit über den Completed-Rückruf des Metal-Backends. Der Rückruf läuft auf einem
     * Metal-Thread; die Herkunft eines Command Buffers ('F' Frame, 'M' Messbild, 'R' Rücklesen)
     * steht in einer FIFO, die der Submit-Thread vor dem Submit füllt (die Queue arbeitet in
     * Commit-Reihenfolge, die Abschlüsse kommen in derselben Reihenfolge). */
    SDL_Mutex *gpu_lock;
    bool closed;
    char tags[KIT_TAG_CAPACITY];
    unsigned tag_head;
    unsigned tag_tail;
    unsigned gpu_skip;                          /* Aufwärmphase: so viele Frame-Abschlüsse nicht werten */
    unsigned gpu_completed_frames;              /* alle Frame-Abschlüsse, auch die übersprungenen */
    double gpu_samples[KIT_GPU_SAMPLES];        /* Ring der letzten gewerteten GPU-Zeiten */
    unsigned gpu_sample_count;                  /* gesamt, Ring = count % KIT_GPU_SAMPLES */
    char line[KIT_LINE_MAX];
};

static void kit_push_tag(kit_multiview_session *s, char tag)
{
    SDL_LockMutex(s->gpu_lock);
    if (s->tag_head - s->tag_tail < KIT_TAG_CAPACITY) {
        s->tags[s->tag_head % KIT_TAG_CAPACITY] = tag;
        s->tag_head += 1;
    }
    SDL_UnlockMutex(s->gpu_lock);
}

/* Completed-Rückruf (Metal-Thread): GPU-Zeit des SDL-Command-Buffers nach Herkunft verbuchen. */
static void SDLCALL kit_gpu_completed(void *userdata, void *mtl_command_buffer)
{
    kit_multiview_session *s = (kit_multiview_session *)userdata;
    double start = 0, end = 0;
    int status = 0;
    const bool ok = kit_metal_command_buffer_gpu_time(mtl_command_buffer, &start, &end, &status, NULL, 0);
    const double ms = (end - start) * 1000.0;
    SDL_LockMutex(s->gpu_lock);
    if (s->closed) {
        SDL_UnlockMutex(s->gpu_lock);
        return;
    }
    char tag = 0;
    if (s->tag_tail != s->tag_head) {
        tag = s->tags[s->tag_tail % KIT_TAG_CAPACITY];
        s->tag_tail += 1;
    }
    if (!ok) {
        s->stats.gpu_errors += 1;
    }
    if (tag == 'F') {
        /* Fensterwerte: alle Frames; Gesamtwerte und Stichprobe: erst nach der Aufwärmphase. */
        s->stats.gpu_frames += 1;
        s->stats.gpu_sum_ms += ms;
        if (ms > s->stats.gpu_max_ms) s->stats.gpu_max_ms = ms;
        s->gpu_completed_frames += 1;
        if (s->gpu_completed_frames > s->gpu_skip) {
            s->stats.gpu_frames_total += 1;
            s->stats.gpu_total_sum_ms += ms;
            if (ms > s->stats.gpu_total_max_ms) s->stats.gpu_total_max_ms = ms;
            s->gpu_samples[s->gpu_sample_count % KIT_GPU_SAMPLES] = ms;
            s->gpu_sample_count += 1;
        }
    } else if (tag == 0) {
        s->stats.gpu_untagged += 1;
    }
    SDL_UnlockMutex(s->gpu_lock);
}

static SDL_GPUSampleCount kit_sample_count(unsigned samples)
{
    switch (samples) {
    case 2: return SDL_GPU_SAMPLECOUNT_2;
    case 4: return SDL_GPU_SAMPLECOUNT_4;
    case 8: return SDL_GPU_SAMPLECOUNT_8;
    default: return SDL_GPU_SAMPLECOUNT_1;
    }
}

/* K4b: Diagnose-Spiegel des internen MetalTextureContainer (SDL_gpu_metal.m am Pin, Felder bis
 * textureCount). Nur für die Zählung der Texturen pro Container im Test. */
typedef struct kit_container_mirror {
    SDL_GPUTextureCreateInfo info;
    void *activeTexture;
    Uint8 canBeCycled;
    Uint8 memoryless;
    Uint32 textureCapacity;
    Uint32 textureCount;
} kit_container_mirror;

void kit_multiview_log_containers(kit_multiview_session *s)
{
    if (!s) {
        return;
    }
    const kit_container_mirror *c = (const kit_container_mirror *)s->msaa_color;
    const kit_container_mirror *d = (const kit_container_mirror *)s->msaa_depth;
    const kit_container_mirror *m = (const kit_container_mirror *)s->measure_msaa;
    kit_logf(s, "[c64-kit] step=msaa-containers msaaColor{textureCount=%u canBeCycled=%u memoryless=%u} msaaDepth{textureCount=%u canBeCycled=%u memoryless=%u} measureMsaa{textureCount=%u canBeCycled=%u memoryless=%u nominalMB=%.1f} msaaNominalMB=%.1f msaaAllocatedMB=%.1f (Spiegel des Container-Layouts am Pin)",
             c ? c->textureCount : 0, c ? c->canBeCycled : 0, c ? c->memoryless : 0,
             d ? d->textureCount : 0, d ? d->canBeCycled : 0, d ? d->memoryless : 0,
             m ? m->textureCount : 0, m ? m->canBeCycled : 0, m ? m->memoryless : 0,
             (double)s->stats.measure_msaa_nominal_bytes / (1024.0 * 1024.0),
             (double)s->stats.msaa_nominal_bytes / (1024.0 * 1024.0),
             s->opt.memoryless ? 0.0 : (double)s->stats.msaa_bytes / (1024.0 * 1024.0));
}

void kit_multiview_options_default(kit_multiview_options *out)
{
    SDL_zerop(out);
    out->msaa_samples = 0;
    out->depth_filter = 2; /* max: Reverse-Z, nächste Fläche */
    out->with_bar = true;
    out->memoryless = false;
    out->pattern = 1.0f;
    for (int v = 0; v < 2; v++) {
        for (int c = 0; c < 4; c++) {
            out->view_colors[v][c] = 1.0f;
        }
    }
}

static void kit_logf(kit_multiview_session *s, const char *fmt, ...)
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

/* MTLTexture importieren (P3), Create-Info aus der Textur. NULL mit SDL-Fehler. */
static SDL_GPUTexture *kit_wrap(SDL_GPUDevice *device, void *mtl_texture, bool depth, kit_metal_texture_desc *desc_out)
{
    kit_metal_texture_desc desc;
    if (!kit_metal_texture_info(mtl_texture, &desc)) {
        SDL_SetError("MTLTexture-Beschreibung nicht lesbar");
        return NULL;
    }
    if (desc_out) {
        *desc_out = desc;
    }
    if (desc.sdl_type < 0 || desc.sdl_format == SDL_GPU_TEXTUREFORMAT_INVALID) {
        SDL_SetError("MTLTexture ohne SDL-Gegenstück (Typ %d, Format %d)", desc.mtl_type, desc.mtl_pixel_format);
        return NULL;
    }
    if (desc.samples != 1 && desc.samples != 2 && desc.samples != 4 && desc.samples != 8) {
        SDL_SetError("MTLTexture mit %u Samples hat kein SDL-Gegenstück", desc.samples);
        return NULL;
    }
#ifndef SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER
    SDL_SetError("SDL-Header ohne P3");
    return NULL;
#else
    SDL_GPUTextureCreateInfo info;
    SDL_zero(info);
    info.type = (SDL_GPUTextureType)desc.sdl_type;
    info.format = (SDL_GPUTextureFormat)desc.sdl_format;
    info.usage = depth ? SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET : SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
    info.width = desc.width;
    info.height = desc.height;
    info.layer_count_or_depth = desc.layers;
    info.num_levels = desc.levels;
    info.sample_count = kit_sample_count(desc.samples);
    info.props = SDL_CreateProperties();
    SDL_SetPointerProperty(info.props, SDL_PROP_GPU_TEXTURE_CREATE_METAL_TEXTURE_POINTER, mtl_texture);
    SDL_GPUTexture *texture = SDL_CreateGPUTexture(device, &info);
    SDL_DestroyProperties(info.props);
    return texture;
#endif
}

static SDL_GPUShader *kit_create_shader(SDL_GPUDevice *device, const char *msl, size_t size,
                                        SDL_GPUShaderStage stage, Uint32 uniform_buffers)
{
    SDL_GPUShaderCreateInfo info;
    SDL_zero(info);
    info.code = (const Uint8 *)msl;
    info.code_size = size;
    info.entrypoint = (stage == SDL_GPU_SHADERSTAGE_VERTEX) ? "vertex_main" : "fragment_main";
    info.format = SDL_GPU_SHADERFORMAT_MSL;
    info.stage = stage;
    info.num_uniform_buffers = uniform_buffers;
    return SDL_CreateGPUShader(device, &info);
}

/* Pipeline: Dreiecke aus der Vertex-ID (kein Vertex-Puffer), Reverse-Z (greater, Schreiben an),
 * kein Culling, kein Blending. view_count über die P6-Property; sample_count für MSAA (K4a). */
static SDL_GPUGraphicsPipeline *kit_create_pipeline_ex(SDL_GPUDevice *device, SDL_GPUShader *vs, SDL_GPUShader *fs,
                                                       SDL_GPUTextureFormat color, SDL_GPUTextureFormat depth,
                                                       bool with_depth, Uint32 view_count, SDL_GPUSampleCount sample_count)
{
    SDL_GPUColorTargetDescription target;
    SDL_zero(target);
    target.format = color;
    target.blend_state.color_write_mask = 0xF;

    SDL_GPUGraphicsPipelineCreateInfo info;
    SDL_zero(info);
    info.vertex_shader = vs;
    info.fragment_shader = fs;
    info.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    info.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
    info.rasterizer_state.cull_mode = SDL_GPU_CULLMODE_NONE;
    info.rasterizer_state.front_face = SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE;
    info.rasterizer_state.enable_depth_clip = true;
    info.multisample_state.sample_count = sample_count;
    info.depth_stencil_state.enable_depth_test = with_depth;
    info.depth_stencil_state.enable_depth_write = with_depth;
    info.depth_stencil_state.compare_op = SDL_GPU_COMPAREOP_GREATER;
    info.target_info.color_target_descriptions = &target;
    info.target_info.num_color_targets = 1;
    info.target_info.depth_stencil_format = depth;
    info.target_info.has_depth_stencil_target = with_depth;
    info.props = SDL_CreateProperties();
#ifdef SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_VIEW_COUNT_NUMBER
    SDL_SetNumberProperty(info.props, SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_VIEW_COUNT_NUMBER, view_count);
#else
    (void)view_count;
#endif
    SDL_GPUGraphicsPipeline *pipeline = SDL_CreateGPUGraphicsPipeline(device, &info);
    SDL_DestroyProperties(info.props);
    return pipeline;
}

static SDL_GPUGraphicsPipeline *kit_create_pipeline(SDL_GPUDevice *device, SDL_GPUShader *vs, SDL_GPUShader *fs,
                                                    SDL_GPUTextureFormat color, SDL_GPUTextureFormat depth,
                                                    Uint32 view_count, SDL_GPUSampleCount sample_count)
{
    return kit_create_pipeline_ex(device, vs, fs, color, depth, true, view_count, sample_count);
}

/* Beschreibung eines Passes: Ziele, optional Auflösungsziele (K4a), Clear, Views, Startschicht,
 * Rate Map (K3). Mit color_resolve wird die Farbe mit store_op RESOLVE in dieselbe Schicht
 * (base_layer) der Auflösungstextur geschrieben; mit depth_resolve die Tiefe über die
 * Pass-Property (store_op des MSAA-Ziels DONT_CARE: nur auflösen, Inhalt verwerfen). */
typedef struct kit_pass_desc {
    SDL_GPUTexture *color;
    SDL_GPUTexture *depth;            /* optional */
    SDL_GPUTexture *color_resolve;    /* optional, nur mit MSAA-Farbziel */
    SDL_GPUTexture *depth_resolve;    /* optional, nur mit MSAA-Tiefenziel */
    unsigned depth_filter;            /* 0 sample0, 1 min, 2 max */
    const char *depth_filter_override; /* Testzwecke: Filtername direkt (NULL = aus depth_filter) */
    float rgba[4];
    float depth_clear;
    Uint32 view_count;
    Uint32 base_layer;
    void *rate_map;
} kit_pass_desc;

static SDL_GPURenderPass *kit_begin_pass_ex(SDL_GPUCommandBuffer *cmd, const kit_pass_desc *d)
{
    SDL_GPUColorTargetInfo ct;
    SDL_zero(ct);
    ct.texture = d->color;
    ct.layer_or_depth_plane = d->base_layer;
    ct.clear_color.r = d->rgba[0];
    ct.clear_color.g = d->rgba[1];
    ct.clear_color.b = d->rgba[2];
    ct.clear_color.a = d->rgba[3];
    ct.load_op = SDL_GPU_LOADOP_CLEAR;
    ct.store_op = SDL_GPU_STOREOP_STORE;
    if (d->color_resolve) {
        ct.store_op = SDL_GPU_STOREOP_RESOLVE;
        ct.resolve_texture = d->color_resolve;
        ct.resolve_layer = d->base_layer;
        ct.resolve_mip_level = 0;
        ct.cycle_resolve_texture = false;
    }

    SDL_GPUDepthStencilTargetInfo dt;
    SDL_zero(dt);
    dt.texture = d->depth;
    dt.layer = (Uint8)d->base_layer;
    dt.clear_depth = d->depth_clear;
    dt.load_op = SDL_GPU_LOADOP_CLEAR;
    dt.store_op = d->depth_resolve ? SDL_GPU_STOREOP_DONT_CARE : SDL_GPU_STOREOP_STORE;
    dt.stencil_load_op = SDL_GPU_LOADOP_DONT_CARE;
    dt.stencil_store_op = SDL_GPU_STOREOP_DONT_CARE;

    if (d->view_count == 1 && d->rate_map == NULL && d->depth_resolve == NULL) {
        return SDL_BeginGPURenderPass(cmd, &ct, 1, d->depth ? &dt : NULL);
    }
#ifdef SDL_PROP_GPU_RENDERPASS_CREATE_VIEW_COUNT_NUMBER
    SDL_PropertiesID props = SDL_CreateProperties();
    SDL_SetNumberProperty(props, SDL_PROP_GPU_RENDERPASS_CREATE_VIEW_COUNT_NUMBER, d->view_count);
#ifdef SDL_PROP_GPU_RENDERPASS_CREATE_METAL_RASTERIZATION_RATE_MAP_POINTER
    if (d->rate_map) {
        SDL_SetPointerProperty(props, SDL_PROP_GPU_RENDERPASS_CREATE_METAL_RASTERIZATION_RATE_MAP_POINTER, d->rate_map);
    }
#endif
    if (d->depth_resolve) {
#ifdef SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_TEXTURE_POINTER
        SDL_SetPointerProperty(props, SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_TEXTURE_POINTER, d->depth_resolve);
        SDL_SetNumberProperty(props, SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_LAYER_NUMBER, d->base_layer);
        SDL_SetStringProperty(props, SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_FILTER_STRING,
                              d->depth_filter_override ? d->depth_filter_override
                                                       : kit_depth_filter_names[d->depth_filter < 3 ? d->depth_filter : 0]);
#else
        SDL_DestroyProperties(props);
        SDL_SetError("SDL-Header ohne Tiefen-Aufloesung (K4a)");
        return NULL;
#endif
    }
    SDL_GPURenderPass *pass = SDL_BeginGPURenderPassWithProperties(cmd, &ct, 1, d->depth ? &dt : NULL, props);
    SDL_DestroyProperties(props);
    return pass;
#else
    SDL_SetError("SDL-Header ohne P6");
    return NULL;
#endif
}

/* Pass mit optionaler Rate Map (K3, P4) und optionalem Tiefenziel, ohne Auflösung. */
static SDL_GPURenderPass *kit_begin_pass_map(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *color, SDL_GPUTexture *depth,
                                             const float rgba[4], float depth_clear, Uint32 view_count, Uint32 base_layer,
                                             void *rate_map)
{
    kit_pass_desc d;
    SDL_zero(d);
    d.color = color;
    d.depth = depth;
    SDL_memcpy(d.rgba, rgba, sizeof(d.rgba));
    d.depth_clear = depth_clear;
    d.view_count = view_count;
    d.base_layer = base_layer;
    d.rate_map = rate_map;
    return kit_begin_pass_ex(cmd, &d);
}

static SDL_GPURenderPass *kit_begin_pass_at(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *color, SDL_GPUTexture *depth,
                                            const float rgba[4], float depth_clear, Uint32 view_count, Uint32 base_layer)
{
    return kit_begin_pass_map(cmd, color, depth, rgba, depth_clear, view_count, base_layer, NULL);
}

static SDL_GPURenderPass *kit_begin_pass(SDL_GPUCommandBuffer *cmd, SDL_GPUTexture *color, SDL_GPUTexture *depth,
                                         const float rgba[4], float depth_clear, Uint32 view_count)
{
    return kit_begin_pass_at(cmd, color, depth, rgba, depth_clear, view_count, 0);
}

/* Bind mit Fehlerprüfung: SDL_BindGPUGraphicsPipeline ist void, der Kern meldet einen
 * view_count-Konflikt über SDL_SetError. */
static bool kit_bind_checked(SDL_GPURenderPass *pass, SDL_GPUGraphicsPipeline *pipeline)
{
    SDL_ClearError();
    SDL_BindGPUGraphicsPipeline(pass, pipeline);
    const char *err = SDL_GetError();
    return err == NULL || err[0] == '\0';
}

static void kit_fill_uniforms(kit_mv_uniforms *u, const float view_projection[32], const float center[3],
                              const float right[3], const float up[3], const float colors[2][4], float pattern)
{
    SDL_zero(*u);
    SDL_memcpy(u->view_projection, view_projection, sizeof(u->view_projection));
    for (int i = 0; i < 3; i++) {
        u->center[i] = center[i];
        u->right[i] = right[i];
        u->up[i] = up[i];
    }
    u->center[3] = 1.0f;
    SDL_memcpy(u->view_color, colors, sizeof(u->view_color));
    u->params[0] = pattern;
}

kit_multiview_session *kit_multiview_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user)
{
    return kit_multiview_begin_ex(metal_device, metal_queue, NULL, log, user);
}

void kit_multiview_set_depth_filter(kit_multiview_session *s, unsigned depth_filter)
{
    if (s && depth_filter < 3) {
        s->opt.depth_filter = depth_filter;
        s->stats.depth_filter = depth_filter;
    }
}

void kit_multiview_set_gpu_skip(kit_multiview_session *s, unsigned skip)
{
    if (!s) {
        return;
    }
    SDL_LockMutex(s->gpu_lock);
    s->gpu_skip = skip;
    SDL_UnlockMutex(s->gpu_lock);
}

static int kit_cmp_double(const void *a, const void *b)
{
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

void kit_multiview_gpu_percentiles(kit_multiview_session *s, unsigned *count, double *mean_ms, double *p95_ms, double *max_ms)
{
    double *copy = NULL;
    unsigned n = 0;
    double sum = 0, mx = 0;
    if (count) *count = 0;
    if (mean_ms) *mean_ms = 0;
    if (p95_ms) *p95_ms = 0;
    if (max_ms) *max_ms = 0;
    if (!s) {
        return;
    }
    SDL_LockMutex(s->gpu_lock);
    n = s->gpu_sample_count < KIT_GPU_SAMPLES ? s->gpu_sample_count : KIT_GPU_SAMPLES;
    if (n > 0) {
        copy = (double *)SDL_malloc(sizeof(double) * n);
        SDL_memcpy(copy, s->gpu_samples, sizeof(double) * n);
    }
    SDL_UnlockMutex(s->gpu_lock);
    if (n == 0) {
        return;
    }
    SDL_qsort(copy, n, sizeof(double), kit_cmp_double);
    for (unsigned i = 0; i < n; i++) {
        sum += copy[i];
    }
    mx = copy[n - 1];
    const unsigned p95_index = (unsigned)((double)(n - 1) * 0.95 + 0.5);
    if (count) *count = n;
    if (mean_ms) *mean_ms = sum / n;
    if (p95_ms) *p95_ms = copy[p95_index < n ? p95_index : n - 1];
    if (max_ms) *max_ms = mx;
    SDL_free(copy);
}

kit_multiview_session *kit_multiview_begin_ex(void *metal_device, void *metal_queue, const kit_multiview_options *options,
                                              kit_log_fn log, void *user)
{
    kit_multiview_session *s = (kit_multiview_session *)SDL_calloc(1, sizeof(kit_multiview_session));
    s->log = log;
    s->user = user;
    s->color_format = SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB;
    s->depth_format = SDL_GPU_TEXTUREFORMAT_D32_FLOAT;
    if (options) {
        s->opt = *options;
    } else {
        kit_multiview_options_default(&s->opt);
    }
    if (s->opt.msaa_samples <= 1) {
        s->opt.msaa_samples = 0;
    }
    if (s->opt.depth_filter > 2) {
        s->opt.depth_filter = 2;
    }
    s->msaa_sc = kit_sample_count(s->opt.msaa_samples);
    s->stats.msaa_samples = s->opt.msaa_samples;
    s->stats.depth_filter = s->opt.depth_filter;
    s->stats.memoryless = s->opt.memoryless ? 1 : 0;
    s->gpu_skip = KIT_GPU_SKIP_DEFAULT;
    s->gpu_lock = SDL_CreateMutex();

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
#ifdef SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER
    /* K4a: GPU-Zeit jedes SDL-Command-Buffers aus dem Completed-Rückruf des Backends. */
    SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_CALLBACK_POINTER, (void *)kit_gpu_completed);
    SDL_SetPointerProperty(props, SDL_PROP_GPU_DEVICE_CREATE_METAL_COMMAND_BUFFER_COMPLETED_USERDATA_POINTER, s);
#endif
    s->device = SDL_CreateGPUDeviceWithProperties(props);
    SDL_DestroyProperties(props);
    if (!s->device) {
        kit_logf(s, "[c64-kit] FAIL step=multiview-device error=\"%s\"", SDL_GetError());
        SDL_DestroyMutex(s->gpu_lock);
        SDL_free(s);
        return NULL;
    }
    /* Metal-Device für die MSAA-Texturen: das übergebene oder das von SDL gewählte. */
    s->metal_device = metal_device;
    if (!s->metal_device) {
        s->metal_device = SDL_GetPointerProperty(SDL_GetGPUDeviceProperties(s->device), SDL_PROP_GPU_DEVICE_METAL_DEVICE_POINTER, NULL);
    }
    if (s->opt.msaa_samples > 1) {
        const bool supported = kit_metal_supports_sample_count(s->metal_device, s->opt.msaa_samples);
        kit_logf(s, "[c64-kit] step=multiview-msaa-support samples1=%d samples2=%d samples4=%d samples8=%d requested=%u supported=%d sdlSupports(color)=%d sdlSupports(depth)=%d",
                 kit_metal_supports_sample_count(s->metal_device, 1) ? 1 : 0, kit_metal_supports_sample_count(s->metal_device, 2) ? 1 : 0,
                 kit_metal_supports_sample_count(s->metal_device, 4) ? 1 : 0, kit_metal_supports_sample_count(s->metal_device, 8) ? 1 : 0,
                 s->opt.msaa_samples, supported ? 1 : 0,
                 SDL_GPUTextureSupportsSampleCount(s->device, s->color_format, s->msaa_sc) ? 1 : 0,
                 SDL_GPUTextureSupportsSampleCount(s->device, s->depth_format, s->msaa_sc) ? 1 : 0);
        if (!supported) {
            kit_logf(s, "[c64-kit] FAIL step=multiview-msaa-support error=\"MSAA %ux nicht unterstützt\"", s->opt.msaa_samples);
            kit_multiview_end(s);
            return NULL;
        }
    }

    const bool supports2 = SDL_GPUSupportsViewCount(s->device, KIT_VIEW_COUNT);
    kit_logf(s, "[c64-kit] step=multiview-support view1=%d view2=%d view3=%d view4=%d view8=%d revision=\"%s\"",
             SDL_GPUSupportsViewCount(s->device, 1) ? 1 : 0, supports2 ? 1 : 0,
             SDL_GPUSupportsViewCount(s->device, 3) ? 1 : 0, SDL_GPUSupportsViewCount(s->device, 4) ? 1 : 0,
             SDL_GPUSupportsViewCount(s->device, 8) ? 1 : 0, SDL_GetRevision());
    if (!supports2) {
        kit_logf(s, "[c64-kit] FAIL step=multiview-support error=\"view_count 2 nicht unterstützt\"");
        SDL_DestroyGPUDevice(s->device);
        SDL_free(s);
        return NULL;
    }

    s->vertex = kit_create_shader(s->device, kit_multiview_vertex_msl, sizeof(kit_multiview_vertex_msl) - 1,
                                  SDL_GPU_SHADERSTAGE_VERTEX, 1);
    s->fragment = kit_create_shader(s->device, kit_multiview_fragment_msl, sizeof(kit_multiview_fragment_msl) - 1,
                                    SDL_GPU_SHADERSTAGE_FRAGMENT, 0);
    if (!s->vertex || !s->fragment) {
        kit_logf(s, "[c64-kit] FAIL step=multiview-shader error=\"%s\"", SDL_GetError());
        kit_multiview_end(s);
        return NULL;
    }
    s->pipeline = kit_create_pipeline(s->device, s->vertex, s->fragment, s->color_format, s->depth_format, KIT_VIEW_COUNT, s->msaa_sc);
    if (!s->pipeline) {
        kit_logf(s, "[c64-kit] FAIL step=multiview-pipeline error=\"%s\"", SDL_GetError());
        kit_multiview_end(s);
        return NULL;
    }
    kit_logf(s, "[c64-kit] step=multiview view_count=%d pipeline=%p color=B8G8R8A8_UNORM_SRGB depth=D32_FLOAT depthTest=greater depthWrite=1 cull=none msaa=%u memoryless=%d depthResolveFilter=%s bar=%d vertexMSL=%zu fragmentMSL=%zu uniformBytes=%zu shaders=HLSL/SV_ViewID→DXC→SPIRV-Cross→amplification_id",
             KIT_VIEW_COUNT, (void *)s->pipeline, s->opt.msaa_samples, s->opt.memoryless ? 1 : 0, kit_depth_filter_names[s->opt.depth_filter],
             s->opt.with_bar ? 1 : 0, sizeof(kit_multiview_vertex_msl) - 1, sizeof(kit_multiview_fragment_msl) - 1, sizeof(kit_mv_uniforms));
    return s;
}

/* K4a: MSAA-Texturen in Drawable-Grösse anlegen oder bei neuer Grösse ersetzen (Host-Texturen,
 * importiert mit sample_count; leben für die Sitzung). */
static bool kit_ensure_msaa(kit_multiview_session *s, unsigned width, unsigned height, unsigned layers)
{
    if (s->msaa_color && s->stats.msaa_width == width && s->stats.msaa_height == height && s->stats.msaa_layers == layers) {
        return true;
    }
    if (s->msaa_color || s->msaa_depth) {
        SDL_WaitForGPUIdle(s->device);
        if (s->msaa_color) SDL_ReleaseGPUTexture(s->device, s->msaa_color);
        if (s->msaa_depth) SDL_ReleaseGPUTexture(s->device, s->msaa_depth);
        s->msaa_color = s->msaa_depth = NULL;
        kit_metal_release_texture(s->msaa_color_mtl);
        kit_metal_release_texture(s->msaa_depth_mtl);
        s->msaa_color_mtl = s->msaa_depth_mtl = NULL;
    }
    const unsigned long long nominal_each = (unsigned long long)width * height * layers * s->opt.msaa_samples * 4ull;
    s->stats.msaa_nominal_bytes = nominal_each * 2;
    if (s->opt.memoryless) {
        /* K4b: SDL legt die Ziele memoryless an (nur Tile-Speicher, kein allocatedSize). */
        SDL_GPUTextureCreateInfo info;
        SDL_zero(info);
        info.type = SDL_GPU_TEXTURETYPE_2D_ARRAY;
        info.width = width;
        info.height = height;
        info.layer_count_or_depth = layers;
        info.num_levels = 1;
        info.sample_count = s->msaa_sc;
        info.props = SDL_CreateProperties();
#ifdef SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN
        SDL_SetBooleanProperty(info.props, SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN, true);
#else
        SDL_DestroyProperties(info.props);
        SDL_SetError("SDL-Header ohne memoryless (K4b)");
        return false;
#endif
        info.format = s->color_format;
        info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
        s->msaa_color = SDL_CreateGPUTexture(s->device, &info);
        info.format = s->depth_format;
        info.usage = SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET;
        s->msaa_depth = s->msaa_color ? SDL_CreateGPUTexture(s->device, &info) : NULL;
        SDL_DestroyProperties(info.props);
        if (!s->msaa_color || !s->msaa_depth) {
            return false;
        }
        s->stats.msaa_bytes = s->stats.msaa_nominal_bytes;
    } else {
        if (!kit_metal_create_array_texture_ex(s->metal_device, false, width, height, layers, s->opt.msaa_samples, &s->msaa_color_mtl) ||
            !kit_metal_create_array_texture_ex(s->metal_device, true, width, height, layers, s->opt.msaa_samples, &s->msaa_depth_mtl)) {
            SDL_SetError("MSAA-Texturen %ux%ux%u mit %u Samples nicht erzeugt", width, height, layers, s->opt.msaa_samples);
            return false;
        }
        s->msaa_color = kit_wrap(s->device, s->msaa_color_mtl, false, NULL);
        s->msaa_depth = kit_wrap(s->device, s->msaa_depth_mtl, true, NULL);
        if (!s->msaa_color || !s->msaa_depth) {
            return false;
        }
        s->stats.msaa_bytes = kit_metal_texture_allocated_bytes(s->msaa_color_mtl) + kit_metal_texture_allocated_bytes(s->msaa_depth_mtl);
    }
    s->stats.msaa_width = width;
    s->stats.msaa_height = height;
    s->stats.msaa_layers = layers;
    kit_logf(s, "[c64-kit] step=multiview-msaa samples=%u memoryless=%d color{%ux%ux%u} depth{%ux%ux%u} nominalMB=%.1f allocatedMB=%s depthResolveFilter=%s resolve=color:storeOp=RESOLVE depth:passProperty storeOp=DONT_CARE cycle=0",
             s->opt.msaa_samples, s->opt.memoryless ? 1 : 0, width, height, layers, width, height, layers,
             (double)s->stats.msaa_nominal_bytes / (1024.0 * 1024.0),
             s->opt.memoryless ? "-(memoryless)" : "siehe multiview-msaa-allocated", kit_depth_filter_names[s->opt.depth_filter]);
    if (!s->opt.memoryless) {
        kit_logf(s, "[c64-kit] step=multiview-msaa-allocated color=%llu depth=%llu totalMB=%.1f",
                 kit_metal_texture_allocated_bytes(s->msaa_color_mtl), kit_metal_texture_allocated_bytes(s->msaa_depth_mtl),
                 (double)s->stats.msaa_bytes / (1024.0 * 1024.0));
    }
    return true;
}

static void kit_frame_fail(kit_multiview_session *s, const char *step, SDL_GPUCommandBuffer *cmd,
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

bool kit_multiview_frame(kit_multiview_session *s, void *color_texture, void *depth_texture,
                         const float rgba[4], float depth_clear, bool draw_quad,
                         const float view_projection[32], const float center[3],
                         const float right[3], const float up[3], void *rate_map)
{
    if (!s || !s->device) {
        return false;
    }
    const Uint64 t0 = SDL_GetPerformanceCounter();
    s->stats.frames += 1;
    s->stats.frames_total += 1;

    kit_metal_texture_desc cdesc, ddesc;
    SDL_GPUTexture *color = kit_wrap(s->device, color_texture, false, &cdesc);
    if (!color) {
        kit_frame_fail(s, "multiview-import-color", NULL, NULL, NULL);
        return false;
    }
    s->stats.wrappers_created += 1;
    SDL_GPUTexture *depth = kit_wrap(s->device, depth_texture, true, &ddesc);
    if (!depth) {
        kit_frame_fail(s, "multiview-import-depth", NULL, color, NULL);
        return false;
    }
    s->stats.wrappers_created += 1;

    if ((SDL_GPUTextureFormat)cdesc.sdl_format != s->color_format || (SDL_GPUTextureFormat)ddesc.sdl_format != s->depth_format) {
        SDL_SetError("Drawable-Formate (%d/%d) passen nicht zur Pipeline (%d/%d)", cdesc.sdl_format, ddesc.sdl_format,
                     (int)s->color_format, (int)s->depth_format);
        kit_frame_fail(s, "multiview-format", NULL, color, depth);
        return false;
    }

    if (!s->first_logged) {
        s->first_logged = true;
        kit_metal_map_desc md;
        const bool has_map = rate_map && kit_metal_map_info(rate_map, &md);
        kit_logf(s, "[c64-kit] step=multiview-frame color{size=%ux%u layers=%u mtl=%p} depth{layers=%u mtl=%p} pass{view_count=%d baseLayer=0 clear=%.2f,%.2f,%.2f,%.2f depth=%.4f} draw=%d rateMap=%p%s",
                 cdesc.width, cdesc.height, cdesc.layers, color_texture, ddesc.layers, depth_texture,
                 KIT_VIEW_COUNT, rgba[0], rgba[1], rgba[2], rgba[3], depth_clear, draw_quad ? 1 : 0, rate_map,
                 has_map ? "" : " (keine Map: Viewport = Texturgroesse)");
        if (has_map) {
            kit_logf(s, "[c64-kit] step=multiview-ratemap layers=%u screen=%ux%u physicalL0=%ux%u physicalL1=%ux%u granularity=%ux%u viewport=logisch",
                     md.layers, md.screen_width, md.screen_height, md.physical_width[0], md.physical_height[0],
                     md.physical_width[1], md.physical_height[1], md.granularity_width, md.granularity_height);
        }
    }

    /* K4a: mit MSAA sind die Pass-Ziele die MSAA-Texturen, die Drawable-Wrapper die Auflösungsziele. */
    kit_pass_desc pd;
    SDL_zero(pd);
    pd.color = color;
    pd.depth = depth;
    SDL_memcpy(pd.rgba, rgba, sizeof(pd.rgba));
    pd.depth_clear = depth_clear;
    pd.view_count = KIT_VIEW_COUNT;
    pd.base_layer = 0;
    pd.rate_map = rate_map;
    if (s->opt.msaa_samples > 1) {
        if (!kit_ensure_msaa(s, cdesc.width, cdesc.height, cdesc.layers)) {
            kit_frame_fail(s, "multiview-msaa-textures", NULL, color, depth);
            return false;
        }
        pd.color = s->msaa_color;
        pd.depth = s->msaa_depth;
        pd.color_resolve = color;
        pd.depth_resolve = depth;
        pd.depth_filter = s->opt.depth_filter;
    }

    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
    if (!cmd) {
        kit_frame_fail(s, "multiview-cmdbuf", NULL, color, depth);
        return false;
    }
    SDL_GPURenderPass *pass = kit_begin_pass_ex(cmd, &pd);
    if (!pass) {
        kit_frame_fail(s, "multiview-renderpass", cmd, color, depth);
        return false;
    }
    s->stats.passes_total += 1;
    if (draw_quad) {
        if (!kit_bind_checked(pass, s->pipeline)) {
            SDL_EndGPURenderPass(pass);
            kit_frame_fail(s, "multiview-bind", cmd, color, depth);
            return false;
        }
        kit_mv_uniforms u;
        kit_fill_uniforms(&u, view_projection, center, right, up, s->opt.view_colors, s->opt.pattern);
        if (s->opt.with_bar) {
            /* K4b: Balken rechts neben dem Brett in der Brettebene, um 20° gekippt, 1,2 m lang,
             * 6 cm breit; Kanten aus Geometrie, an denen MSAA sichtbar wird. */
            const float rl = SDL_sqrtf(right[0] * right[0] + right[1] * right[1] + right[2] * right[2]);
            const float ul = SDL_sqrtf(up[0] * up[0] + up[1] * up[1] + up[2] * up[2]);
            if (rl > 1e-6f && ul > 1e-6f) {
                const float c = 0.9397f, sn = 0.3420f; /* cos 20°, sin 20° */
                for (int i = 0; i < 3; i++) {
                    const float rd = right[i] / rl, ud = up[i] / ul;
                    u.bar_center[i] = center[i] + right[i] * 1.3f;
                    u.bar_up[i] = (ud * c + rd * sn) * 0.6f;
                    u.bar_right[i] = (rd * c - ud * sn) * 0.03f;
                }
                u.bar_center[3] = 1.0f;
            }
        }
        SDL_PushGPUVertexUniformData(cmd, 0, &u, sizeof(u));
        SDL_DrawGPUPrimitives(pass, s->opt.with_bar ? 12 : 6, 1, 0, 0);
        s->stats.draws_total += 1;
    }
    SDL_EndGPURenderPass(pass);
    kit_push_tag(s, 'F');
    if (!SDL_SubmitGPUCommandBuffer(cmd)) {
        kit_frame_fail(s, "multiview-submit", NULL, color, depth);
        return false;
    }
    SDL_ReleaseGPUTexture(s->device, color);
    SDL_ReleaseGPUTexture(s->device, depth);
    s->stats.wrappers_released += 2;

    const double ms = kit_ms_since(t0);
    s->stats.sum_ms += ms;
    s->stats.total_sum_ms += ms;
    if (ms > s->stats.max_ms) s->stats.max_ms = ms;
    if (ms > s->stats.total_max_ms) s->stats.total_max_ms = ms;
    return true;
}

void kit_multiview_take_stats(kit_multiview_session *s, kit_multiview_stats *out)
{
    if (!s || !out) {
        return;
    }
    SDL_LockMutex(s->gpu_lock);
    *out = s->stats;
    s->stats.frames = 0;
    s->stats.fails = 0;
    s->stats.sum_ms = 0;
    s->stats.max_ms = 0;
    s->stats.gpu_frames = 0;
    s->stats.gpu_sum_ms = 0;
    s->stats.gpu_max_ms = 0;
    SDL_UnlockMutex(s->gpu_lock);
}

void kit_multiview_end(kit_multiview_session *s)
{
    if (!s) {
        return;
    }
    if (s->device) {
        SDL_WaitForGPUIdle(s->device);
        if (s->measure_pipeline) SDL_ReleaseGPUGraphicsPipeline(s->device, s->measure_pipeline);
        if (s->measure_texture) SDL_ReleaseGPUTexture(s->device, s->measure_texture);
        if (s->measure_msaa) SDL_ReleaseGPUTexture(s->device, s->measure_msaa);
        if (s->measure_transfer) SDL_ReleaseGPUTransferBuffer(s->device, s->measure_transfer);
        if (s->msaa_color) SDL_ReleaseGPUTexture(s->device, s->msaa_color);
        if (s->msaa_depth) SDL_ReleaseGPUTexture(s->device, s->msaa_depth);
        if (s->pipeline) SDL_ReleaseGPUGraphicsPipeline(s->device, s->pipeline);
        if (s->vertex) SDL_ReleaseGPUShader(s->device, s->vertex);
        if (s->fragment) SDL_ReleaseGPUShader(s->device, s->fragment);
        SDL_DestroyGPUDevice(s->device);
    }
    kit_metal_release_texture(s->msaa_color_mtl);
    kit_metal_release_texture(s->msaa_depth_mtl);
    const double mean = s->stats.frames_total ? s->stats.total_sum_ms / (double)s->stats.frames_total : 0;
    unsigned gpu_n = 0;
    double gpu_mean = 0, gpu_p95 = 0, gpu_max = 0;
    kit_multiview_gpu_percentiles(s, &gpu_n, &gpu_mean, &gpu_p95, &gpu_max);
    kit_logf(s, "[c64-kit] step=multiview-end frames=%lu fails=%lu passes=%lu draws=%lu sdl(ms) mean=%.3f max=%.3f gpu(ms, ab Frame %u) n=%u mean=%.3f p95=%.3f max=%.3f untagged=%lu gpuErr=%lu msaa=%u wrappers created=%lu released=%lu",
             s->stats.frames_total, s->stats.fails_total, s->stats.passes_total, s->stats.draws_total,
             mean, s->stats.total_max_ms, s->gpu_skip + 1, gpu_n, gpu_mean, gpu_p95, gpu_max,
             s->stats.gpu_untagged, s->stats.gpu_errors, s->opt.msaa_samples,
             s->stats.wrappers_created, s->stats.wrappers_released);
    /* Der Completed-Rückruf kann nach dem Warten noch kurz laufen: Sitzung als geschlossen
     * markieren, ihm eine kurze Frist lassen, dann freigeben. */
    if (s->gpu_lock) {
        SDL_LockMutex(s->gpu_lock);
        s->closed = true;
        SDL_UnlockMutex(s->gpu_lock);
        SDL_Delay(10);
        SDL_DestroyMutex(s->gpu_lock);
    }
    SDL_free(s);
}

/* ------------------------------------------------------------------ K3: Messbild gegen die Map */

#define KIT_MEASURE_SAMPLES 9

/* Stichproben als Anteile der physischen Grösse: Mitte, vier Ränder, vier Zwischenlagen. */
static const float kit_measure_points[KIT_MEASURE_SAMPLES][2] = {
    { 0.5f, 0.5f }, { 0.08f, 0.5f }, { 0.92f, 0.5f }, { 0.5f, 0.08f }, { 0.5f, 0.92f },
    { 0.08f, 0.08f }, { 0.92f, 0.92f }, { 0.3f, 0.7f }, { 0.7f, 0.3f }
};

/* Messung; tex_w/tex_h >= physische Grösse der Map (0 = genau die Map-Grösse). Die Stichproben
 * liegen immer in der physischen Grösse der Map, nicht der Textur. */
static bool kit_measure_impl(kit_multiview_session *s, void *rate_map, bool verbose,
                             unsigned tex_w, unsigned tex_h, kit_multiview_measure *out)
{
    if (!s || !s->device || !rate_map || !out) {
        return false;
    }
    const Uint64 t0 = SDL_GetPerformanceCounter();
    SDL_zero(*out);
    kit_metal_map_desc md;
    if (!kit_metal_map_info(rate_map, &md) || md.layers < KIT_VIEW_COUNT) {
        SDL_SetError("Rate Map ohne zwei Schichten");
        return false;
    }
    if (md.physical_width[0] != md.physical_width[1] || md.physical_height[0] != md.physical_height[1]) {
        SDL_SetError("Rate Map: Schichten mit verschiedener physischer Groesse (%ux%u, %ux%u)",
                     md.physical_width[0], md.physical_height[0], md.physical_width[1], md.physical_height[1]);
        return false;
    }
    /* W/H: physische Grösse der Map = Raum der Stichproben; die Textur darf grösser sein. */
    const unsigned W = md.physical_width[0], H = md.physical_height[0];
    if (tex_w < W) tex_w = W;
    if (tex_h < H) tex_h = H;
    out->screen_width = md.screen_width;
    out->screen_height = md.screen_height;
    out->physical_width = W;
    out->physical_height = H;
    out->layers = md.layers;

    /* Mess-Pipeline und -Textur beim ersten Aufruf oder bei neuer Grösse anlegen; unter MSAA (K4a)
     * rendert der Pass in eine SDL-eigene RG32F-Multisample-Array-Textur und löst in die
     * Mess-Textur auf. */
    /* K4b: Das Messbild rendert nur dann multisample, wenn die MSAA-Textur memoryless ist; sonst
     * kostete die RG32F-MSAA-Textur bei Render Quality 1,0 rund 430 MB (M5), mehr als die MSAA-Ziele
     * selbst. Die Messung des Rasterizers gegen die Map ist davon unabhängig (K4a, Mac: 0,002 px). */
    const bool measure_msaa = (s->opt.msaa_samples > 1) && s->opt.memoryless;
    if (!s->measure_pipeline) {
        s->measure_pipeline = kit_create_pipeline_ex(s->device, s->vertex, s->fragment, SDL_GPU_TEXTUREFORMAT_R32G32_FLOAT,
                                                     SDL_GPU_TEXTUREFORMAT_D32_FLOAT, false, KIT_VIEW_COUNT,
                                                     measure_msaa ? s->msaa_sc : SDL_GPU_SAMPLECOUNT_1);
        if (!s->measure_pipeline) {
            return false;
        }
    }
    if (!s->measure_texture || s->measure_width != tex_w || s->measure_height != tex_h) {
        if (s->measure_texture || s->measure_msaa) {
            SDL_WaitForGPUIdle(s->device);
            if (s->measure_texture) SDL_ReleaseGPUTexture(s->device, s->measure_texture);
            if (s->measure_msaa) SDL_ReleaseGPUTexture(s->device, s->measure_msaa);
            s->measure_texture = s->measure_msaa = NULL;
        }
        SDL_GPUTextureCreateInfo info;
        SDL_zero(info);
        info.type = SDL_GPU_TEXTURETYPE_2D_ARRAY;
        info.format = SDL_GPU_TEXTUREFORMAT_R32G32_FLOAT;
        info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET;
        info.width = tex_w;
        info.height = tex_h;
        info.layer_count_or_depth = KIT_VIEW_COUNT;
        info.num_levels = 1;
        info.sample_count = SDL_GPU_SAMPLECOUNT_1;
        s->measure_texture = SDL_CreateGPUTexture(s->device, &info);
        if (!s->measure_texture) {
            return false;
        }
        if (measure_msaa) {
            info.sample_count = s->msaa_sc;
            info.props = 0;
#ifdef SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN
            if (s->opt.memoryless) {
                /* K4b: die MSAA-Textur des Messbilds wird nur aufgelöst, nie gelesen. */
                info.props = SDL_CreateProperties();
                SDL_SetBooleanProperty(info.props, SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN, true);
            }
#endif
            s->measure_msaa = SDL_CreateGPUTexture(s->device, &info);
            if (info.props) SDL_DestroyProperties(info.props);
            if (!s->measure_msaa) {
                return false;
            }
            s->stats.measure_msaa_nominal_bytes = (unsigned long long)tex_w * tex_h * KIT_VIEW_COUNT * s->opt.msaa_samples * 8ull;
        }
        s->measure_width = tex_w;
        s->measure_height = tex_h;
        s->measure_layers = KIT_VIEW_COUNT;
    }
    if (!s->measure_transfer) {
        SDL_GPUTransferBufferCreateInfo tinfo;
        SDL_zero(tinfo);
        tinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        tinfo.size = KIT_MEASURE_SAMPLES * KIT_VIEW_COUNT * 8;
        s->measure_transfer = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
        if (!s->measure_transfer) {
            return false;
        }
    }

    /* Pass mit Map: Vollbild-Quad (Einheitsmatrizen), Muster 2 = Fragmentposition. */
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
    if (!cmd) {
        return false;
    }
    kit_pass_desc pd;
    SDL_zero(pd);
    pd.color = s->measure_msaa ? s->measure_msaa : s->measure_texture;
    pd.color_resolve = s->measure_msaa ? s->measure_texture : NULL;
    pd.rgba[0] = -1; pd.rgba[1] = -1; pd.rgba[2] = 0; pd.rgba[3] = 1;
    pd.view_count = KIT_VIEW_COUNT;
    pd.rate_map = rate_map;
    SDL_GPURenderPass *pass = kit_begin_pass_ex(cmd, &pd);
    if (!pass) {
        SDL_CancelGPUCommandBuffer(cmd);
        return false;
    }
    if (!kit_bind_checked(pass, s->measure_pipeline)) {
        SDL_EndGPURenderPass(pass);
        SDL_CancelGPUCommandBuffer(cmd);
        return false;
    }
    float vp[32] = { 0 };
    for (int v = 0; v < 2; v++) {
        vp[v * 16 + 0] = 1; vp[v * 16 + 5] = 1; vp[v * 16 + 10] = 1; vp[v * 16 + 15] = 1;
        vp[v * 16 + 14] = 0.5f;
    }
    const float center[3] = { 0, 0, 0 }, right[3] = { 1, 0, 0 }, up[3] = { 0, 1, 0 };
    const float white[2][4] = { { 1, 1, 1, 1 }, { 1, 1, 1, 1 } };
    kit_mv_uniforms u;
    kit_fill_uniforms(&u, vp, center, right, up, white, 2.0f);
    u.params[1] = (float)md.screen_width;   /* logische Grösse für die interpolierte Koordinate */
    u.params[2] = (float)md.screen_height;
    SDL_PushGPUVertexUniformData(cmd, 0, &u, sizeof(u));
    SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
    SDL_EndGPURenderPass(pass);

    /* Stichproben zurücklesen: 1×1 pro Punkt und Schicht. */
    unsigned px[KIT_MEASURE_SAMPLES], py[KIT_MEASURE_SAMPLES];
    for (unsigned k = 0; k < KIT_MEASURE_SAMPLES; k++) {
        px[k] = (unsigned)(kit_measure_points[k][0] * (float)(W - 1));
        py[k] = (unsigned)(kit_measure_points[k][1] * (float)(H - 1));
    }
    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (!copy) {
        SDL_CancelGPUCommandBuffer(cmd);
        return false;
    }
    for (unsigned layer = 0; layer < KIT_VIEW_COUNT; layer++) {
        for (unsigned k = 0; k < KIT_MEASURE_SAMPLES; k++) {
            SDL_GPUTextureRegion src;
            SDL_zero(src);
            src.texture = s->measure_texture;
            src.layer = layer;
            src.x = px[k];
            src.y = py[k];
            src.w = 1;
            src.h = 1;
            src.d = 1;
            SDL_GPUTextureTransferInfo dst;
            SDL_zero(dst);
            dst.transfer_buffer = s->measure_transfer;
            dst.offset = (layer * KIT_MEASURE_SAMPLES + k) * 8;
            dst.pixels_per_row = 1;
            dst.rows_per_layer = 1;
            SDL_DownloadFromGPUTexture(copy, &src, &dst);
        }
    }
    SDL_EndGPUCopyPass(copy);
    kit_push_tag(s, 'M');
    SDL_GPUFence *fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (!fence || !SDL_WaitForGPUFences(s->device, true, &fence, 1)) {
        if (fence) SDL_ReleaseGPUFence(s->device, fence);
        return false;
    }
    SDL_ReleaseGPUFence(s->device, fence);

    const float *data = (const float *)SDL_MapGPUTransferBuffer(s->device, s->measure_transfer, false);
    if (!data) {
        return false;
    }
    double sum = 0;
    float maxdev = 0;
    unsigned count = 0;
    for (unsigned layer = 0; layer < KIT_VIEW_COUNT; layer++) {
        for (unsigned k = 0; k < KIT_MEASURE_SAMPLES; k++) {
            const float *v = data + (layer * KIT_MEASURE_SAMPLES + k) * 2;
            const float sx = v[0], sy = v[1];             /* logisch, aus dem Fragment */
            const float cx = (float)px[k] + 0.5f, cy = (float)py[k] + 0.5f;
            float ex, ey, bx, by;
            kit_metal_map_physical_to_screen(rate_map, layer, cx, cy, &ex, &ey); /* Soll logisch */
            kit_metal_map_screen_to_physical(rate_map, layer, sx, sy, &bx, &by); /* Ist zurück physisch */
            const float dev = SDL_sqrtf((bx - cx) * (bx - cx) + (by - cy) * (by - cy));
            if (sx < 0 || sy < 0) {
                /* Clear-Wert: das Fragment wurde nicht geschrieben */
                maxdev = 1e9f;
            }
            sum += dev;
            count += 1;
            if (dev > maxdev) maxdev = dev;
            if (verbose) {
                kit_logf(s, "[c64-kit] step=fov-sample layer=%u physical=%u,%u fragment=%.2f,%.2f expectedScreen=%.2f,%.2f backToPhysical=%.2f,%.2f devPx=%.3f",
                         layer, px[k], py[k], sx, sy, ex, ey, bx, by, dev);
            }
        }
    }
    SDL_UnmapGPUTransferBuffer(s->device, s->measure_transfer);
    if (verbose) {
        kit_logf(s, "[c64-kit] step=fov-sample-space samplesIn=mapPhysical %ux%u measureTexture=%ux%u msaa=%u%s", W, H, tex_w, tex_h,
                 s->opt.msaa_samples, s->measure_msaa ? " (RG32F multisample memoryless, aufgeloest in die Mess-Textur)" : " (Messbild ohne MSAA)");
    }
    out->samples = count;
    out->max_dev_px = maxdev;
    out->mean_dev_px = count ? (float)(sum / count) : 0;
    out->ms = kit_ms_since(t0);
    return true;
}

bool kit_multiview_measure_map(kit_multiview_session *s, void *rate_map, bool verbose, kit_multiview_measure *out)
{
    return kit_measure_impl(s, rate_map, verbose, 0, 0, out);
}

/* ------------------------------------------------------------------ Mac-Selbsttest */

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

int kit_multiview_selftest(kit_log_fn log, void *user)
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
    SDL_GPUGraphicsPipeline *single_view = NULL;
    kit_multiview_session *s = NULL;

    if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-host error=\"Device/Queue nicht erzeugt\"");
        return 40;
    }
    s = kit_multiview_begin(host_device, host_queue, log, user);
    if (!s) {
        result = 41;
        goto done;
    }
    if (!kit_metal_create_array_texture(host_device, false, W, H, LAYERS, &mtl_color) ||
        !kit_metal_create_array_texture(host_device, true, W, H, LAYERS, &mtl_depth)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-textures error=\"MTLTexture nicht erzeugt\"");
        result = 42;
        goto done;
    }
    color = kit_wrap(s->device, mtl_color, false, NULL);
    depth = kit_wrap(s->device, mtl_depth, true, NULL);
    if (!color || !depth) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-import error=\"%s\"", SDL_GetError());
        result = 43;
        goto done;
    }

    /* Matrizen: Einheit mit Verschiebung in z (Spalte 3, Index 14), damit View 0 auf Tiefe 0.25
     * und View 1 auf Tiefe 0.75 landet; Quad füllt mit center 0, right (1,0,0), up (0,1,0) das
     * ganze Ziel. Flache Farbe: View 0 rot, View 1 blau. */
    float vp[32] = { 0 };
    for (int v = 0; v < 2; v++) {
        vp[v * 16 + 0] = 1; vp[v * 16 + 5] = 1; vp[v * 16 + 10] = 1; vp[v * 16 + 15] = 1;
    }
    vp[14] = 0.25f;
    vp[16 + 14] = 0.75f;
    const float center[3] = { 0, 0, 0 }, right[3] = { 1, 0, 0 }, up[3] = { 0, 1, 0 };
    const float colors[2][4] = { { 1, 0, 0, 1 }, { 0, 0, 1, 1 } };
    const float clear[4] = { 0, 0, 0, 1 };
    const float depth_clear = 0.001f;
    const float expected_depth[2] = { 0.25f, 0.75f };
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
        result = 44;
        goto done;
    }

    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
    if (!cmd) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-cmdbuf error=\"%s\"", SDL_GetError());
        result = 45;
        goto done;
    }
    SDL_GPURenderPass *pass = kit_begin_pass(cmd, color, depth, clear, depth_clear, KIT_VIEW_COUNT);
    if (!pass) {
        self_logf(&ctx, "[c64-kit] FAIL step=multiview-renderpass error=\"%s\"", SDL_GetError());
        SDL_CancelGPUCommandBuffer(cmd);
        result = 46;
        goto done;
    }
    if (!kit_bind_checked(pass, s->pipeline)) {
        self_logf(&ctx, "[c64-kit] FAIL step=multiview-bind error=\"%s\"", SDL_GetError());
        SDL_EndGPURenderPass(pass);
        SDL_CancelGPUCommandBuffer(cmd);
        result = 47;
        goto done;
    }
    kit_mv_uniforms u;
    kit_fill_uniforms(&u, vp, center, right, up, colors, 0.0f);
    SDL_PushGPUVertexUniformData(cmd, 0, &u, sizeof(u));
    SDL_DrawGPUPrimitives(pass, 6, 1, 0, 0);
    SDL_EndGPURenderPass(pass);
    self_logf(&ctx, "[c64-kit] step=multiview-draw passes=1 draws=1 view_count=%d view0=rot/0.25 view1=blau/0.75 clear=schwarz/%.3f", KIT_VIEW_COUNT, depth_clear);

    SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
    if (!copy) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-copypass error=\"%s\"", SDL_GetError());
        SDL_CancelGPUCommandBuffer(cmd);
        result = 48;
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
    kit_push_tag(s, 'R');
    fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
    if (!fence || !SDL_WaitForGPUFences(s->device, true, &fence, 1)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-submit error=\"%s\"", SDL_GetError());
        result = 49;
        goto done;
    }

    {
        const Uint8 *cp = (const Uint8 *)SDL_MapGPUTransferBuffer(s->device, tcolor, false);
        const float *dp = (const float *)SDL_MapGPUTransferBuffer(s->device, tdepth, false);
        if (!cp || !dp) {
            self_logf(&ctx, "[c64-kit] FAIL step=selftest-map error=\"%s\"", SDL_GetError());
            result = 50;
            goto done;
        }
        bool all_ok = true;
        for (unsigned layer = 0; layer < LAYERS; layer++) {
            const Uint8 expected[4] = { (Uint8)(colors[layer][2] * 255), (Uint8)(colors[layer][1] * 255),
                                        (Uint8)(colors[layer][0] * 255), (Uint8)(colors[layer][3] * 255) };
            const Uint32 center_px = ((H / 2) * W + (W / 2)) * pixel_bytes;
            const Uint8 *p0 = cp + layer * layer_bytes;
            const Uint8 *pc = p0 + center_px;
            const float d0 = dp[layer * W * H];
            const float dc = dp[layer * W * H + (H / 2) * W + (W / 2)];
            bool ok = true;
            for (int i = 0; i < 4; i++) {
                if (p0[i] != expected[i] || pc[i] != expected[i]) ok = false;
            }
            if (SDL_fabsf(d0 - expected_depth[layer]) > 1e-6f || SDL_fabsf(dc - expected_depth[layer]) > 1e-6f) ok = false;
            self_logf(&ctx, "[c64-kit] step=multiview-readback view=%u layer=%u color(bgra) pixel00=%u,%u,%u,%u center=%u,%u,%u,%u expected=%u,%u,%u,%u depth pixel00=%.4f center=%.4f expected=%.2f ok=%d",
                      layer, layer, p0[0], p0[1], p0[2], p0[3], pc[0], pc[1], pc[2], pc[3],
                      expected[0], expected[1], expected[2], expected[3], d0, dc, expected_depth[layer], ok ? 1 : 0);
            if (!ok) all_ok = false;
        }
        SDL_UnmapGPUTransferBuffer(s->device, tcolor);
        SDL_UnmapGPUTransferBuffer(s->device, tdepth);
        if (!all_ok) {
            result = 51;
            goto done;
        }
    }

    /* Schichtversatz: 2D-Array mit 4 Schichten, Vorab-Clear aller Schichten grün/0.5 (vier
     * Ein-View-Pässe), dann ein Pass mit Basis 2 und view_count 2 (Clear schwarz, Draw rot/0.25
     * und blau/0.75). Erwartet: Schicht 0 und 1 unberührt, 2 rot, 3 blau. */
    {
        const unsigned L4 = 4;
        void *mtl_color4 = NULL, *mtl_depth4 = NULL;
        SDL_GPUTexture *color4 = NULL, *depth4 = NULL;
        SDL_GPUTransferBuffer *tc4 = NULL, *td4 = NULL;
        SDL_GPUFence *fence4 = NULL;
        int step_result = 0;
        const float green[4] = { 0, 1, 0, 1 };
        const float pre_depth = 0.5f;

        if (!kit_metal_create_array_texture(host_device, false, W, H, L4, &mtl_color4) ||
            !kit_metal_create_array_texture(host_device, true, W, H, L4, &mtl_depth4)) {
            self_logf(&ctx, "[c64-kit] FAIL step=offset-textures error=\"MTLTexture nicht erzeugt\"");
            step_result = 54;
            goto offset_done;
        }
        color4 = kit_wrap(s->device, mtl_color4, false, NULL);
        depth4 = kit_wrap(s->device, mtl_depth4, true, NULL);
        tinfo.size = layer_bytes * L4;
        tc4 = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
        td4 = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
        if (!color4 || !depth4 || !tc4 || !td4) {
            self_logf(&ctx, "[c64-kit] FAIL step=offset-setup error=\"%s\"", SDL_GetError());
            step_result = 55;
            goto offset_done;
        }
        SDL_GPUCommandBuffer *cmd4 = SDL_AcquireGPUCommandBuffer(s->device);
        if (!cmd4) {
            step_result = 55;
            goto offset_done;
        }
        for (unsigned layer = 0; layer < L4; layer++) {
            SDL_GPURenderPass *p = kit_begin_pass_at(cmd4, color4, depth4, green, pre_depth, 1, layer);
            if (!p) {
                self_logf(&ctx, "[c64-kit] FAIL step=offset-preclear layer=%u error=\"%s\"", layer, SDL_GetError());
                SDL_CancelGPUCommandBuffer(cmd4);
                step_result = 56;
                goto offset_done;
            }
            SDL_EndGPURenderPass(p);
        }
        SDL_GPURenderPass *p2 = kit_begin_pass_at(cmd4, color4, depth4, clear, depth_clear, KIT_VIEW_COUNT, 2);
        if (!p2) {
            self_logf(&ctx, "[c64-kit] FAIL step=offset-renderpass error=\"%s\"", SDL_GetError());
            SDL_CancelGPUCommandBuffer(cmd4);
            step_result = 57;
            goto offset_done;
        }
        if (!kit_bind_checked(p2, s->pipeline)) {
            self_logf(&ctx, "[c64-kit] FAIL step=offset-bind error=\"%s\"", SDL_GetError());
            SDL_EndGPURenderPass(p2);
            SDL_CancelGPUCommandBuffer(cmd4);
            step_result = 57;
            goto offset_done;
        }
        SDL_PushGPUVertexUniformData(cmd4, 0, &u, sizeof(u));
        SDL_DrawGPUPrimitives(p2, 6, 1, 0, 0);
        SDL_EndGPURenderPass(p2);
        self_logf(&ctx, "[c64-kit] step=multiview-offset layers=%u preclear=gruen/%.2f pass{baseLayer=2 view_count=%d clear=schwarz/%.3f} draw=1", L4, pre_depth, KIT_VIEW_COUNT, depth_clear);

        SDL_GPUCopyPass *copy4 = SDL_BeginGPUCopyPass(cmd4);
        if (!copy4) {
            SDL_CancelGPUCommandBuffer(cmd4);
            step_result = 58;
            goto offset_done;
        }
        for (unsigned layer = 0; layer < L4; layer++) {
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
            src.texture = color4;
            dst.transfer_buffer = tc4;
            SDL_DownloadFromGPUTexture(copy4, &src, &dst);
            src.texture = depth4;
            dst.transfer_buffer = td4;
            SDL_DownloadFromGPUTexture(copy4, &src, &dst);
        }
        SDL_EndGPUCopyPass(copy4);
        kit_push_tag(s, 'R');
        fence4 = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd4);
        if (!fence4 || !SDL_WaitForGPUFences(s->device, true, &fence4, 1)) {
            self_logf(&ctx, "[c64-kit] FAIL step=offset-submit error=\"%s\"", SDL_GetError());
            step_result = 59;
            goto offset_done;
        }
        {
            const Uint8 *cp = (const Uint8 *)SDL_MapGPUTransferBuffer(s->device, tc4, false);
            const float *dp = (const float *)SDL_MapGPUTransferBuffer(s->device, td4, false);
            if (!cp || !dp) {
                step_result = 60;
                goto offset_done;
            }
            /* Erwartung pro Schicht in BGRA und Tiefe. */
            const Uint8 exp_color[4][4] = { { 0, 255, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 }, { 255, 0, 0, 255 } };
            const float exp_depth[4] = { pre_depth, pre_depth, 0.25f, 0.75f };
            const char *exp_name[4] = { "gruen/unberuehrt", "gruen/unberuehrt", "rot/view0", "blau/view1" };
            bool all_ok = true;
            for (unsigned layer = 0; layer < L4; layer++) {
                const Uint32 center_px = ((H / 2) * W + (W / 2)) * pixel_bytes;
                const Uint8 *pc = cp + layer * layer_bytes + center_px;
                const float dc = dp[layer * W * H + (H / 2) * W + (W / 2)];
                bool ok = true;
                for (int i = 0; i < 4; i++) {
                    if (pc[i] != exp_color[layer][i]) ok = false;
                }
                if (SDL_fabsf(dc - exp_depth[layer]) > 1e-6f) ok = false;
                self_logf(&ctx, "[c64-kit] step=multiview-offset-readback layer=%u center(bgra)=%u,%u,%u,%u depth=%.4f expected=%s (%u,%u,%u,%u / %.2f) ok=%d",
                          layer, pc[0], pc[1], pc[2], pc[3], dc, exp_name[layer],
                          exp_color[layer][0], exp_color[layer][1], exp_color[layer][2], exp_color[layer][3], exp_depth[layer], ok ? 1 : 0);
                if (!ok) all_ok = false;
            }
            SDL_UnmapGPUTransferBuffer(s->device, tc4);
            SDL_UnmapGPUTransferBuffer(s->device, td4);
            if (!all_ok) step_result = 61;
        }
    offset_done:
        if (fence4) SDL_ReleaseGPUFence(s->device, fence4);
        if (tc4) SDL_ReleaseGPUTransferBuffer(s->device, tc4);
        if (td4) SDL_ReleaseGPUTransferBuffer(s->device, td4);
        if (color4) SDL_ReleaseGPUTexture(s->device, color4);
        if (depth4) SDL_ReleaseGPUTexture(s->device, depth4);
        SDL_WaitForGPUIdle(s->device);
        kit_metal_release_texture(mtl_color4);
        kit_metal_release_texture(mtl_depth4);
        if (step_result != 0 && result == 0) {
            result = step_result;
            goto done;
        }
    }

    /* Negativtest 1: Pipeline mit view_count 1 in einem Pass mit view_count 2. */
    {
        single_view = kit_create_pipeline(s->device, s->vertex, s->fragment, s->color_format, s->depth_format, 1, SDL_GPU_SAMPLECOUNT_1);
        SDL_GPUCommandBuffer *cmd2 = SDL_AcquireGPUCommandBuffer(s->device);
        SDL_GPURenderPass *pass2 = cmd2 ? kit_begin_pass(cmd2, color, depth, clear, depth_clear, KIT_VIEW_COUNT) : NULL;
        bool failed = false;
        const char *text = "(Pass nicht begonnen)";
        if (pass2) {
            failed = !kit_bind_checked(pass2, single_view);
            text = failed ? SDL_GetError() : "(kein Fehler, Bind gelang)";
            SDL_EndGPURenderPass(pass2);
        }
        if (cmd2) SDL_CancelGPUCommandBuffer(cmd2);
        self_logf(&ctx, "[c64-kit] step=multiview-negative case=pipelineView1InPassView2 failed=%d error=\"%s\"", failed ? 1 : 0, text);
        if (!failed) result = 52;
    }
    /* Negativtest 2: Pass mit view_count 3 auf Texturen mit 2 Schichten. */
    {
        SDL_GPUCommandBuffer *cmd3 = SDL_AcquireGPUCommandBuffer(s->device);
        SDL_GPURenderPass *pass3 = cmd3 ? kit_begin_pass(cmd3, color, depth, clear, depth_clear, 3) : NULL;
        const bool failed = (pass3 == NULL);
        self_logf(&ctx, "[c64-kit] step=multiview-negative case=passView3OnTwoLayers failed=%d error=\"%s\"",
                  failed ? 1 : 0, failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
        if (pass3) SDL_EndGPURenderPass(pass3);
        if (cmd3) SDL_CancelGPUCommandBuffer(cmd3);
        if (!failed && result == 0) result = 53;
    }

done:
    if (s && s->device) {
        if (fence) SDL_ReleaseGPUFence(s->device, fence);
        if (tcolor) SDL_ReleaseGPUTransferBuffer(s->device, tcolor);
        if (tdepth) SDL_ReleaseGPUTransferBuffer(s->device, tdepth);
        if (single_view) SDL_ReleaseGPUGraphicsPipeline(s->device, single_view);
        if (color) SDL_ReleaseGPUTexture(s->device, color);
        if (depth) SDL_ReleaseGPUTexture(s->device, depth);
    }
    if (s) {
        kit_multiview_end(s);
    }
    if (mtl_color || mtl_depth) {
        char status[128];
        const bool queue_ok = kit_metal_hostqueue_check(host_queue, status, sizeof(status));
        self_logf(&ctx, "[c64-kit] step=hostqueue-after-destroy ok=%d %s", queue_ok ? 1 : 0, status);
        kit_metal_release_texture(mtl_color);
        kit_metal_release_texture(mtl_depth);
    }
    kit_metal_release_host_objects(host_device, host_queue);
    self_logf(&ctx, "[c64-kit] result=%s failedStep=%d mode=multiview", result == 0 ? "ok" : "fail", result);
    return result;
}

/* ------------------------------------------------------------------ Mac-Selbsttest K3 (P4) */

int kit_multiview_foveation_selftest(kit_log_fn log, void *user)
{
    kit_self_ctx ctx;
    SDL_zero(ctx);
    ctx.log = log;
    ctx.user = user;

    int result = 0;
    void *host_device = NULL, *host_queue = NULL;
    void *map = NULL;
    void *mtl_color_small = NULL;
    SDL_GPUTexture *color_small = NULL;
    kit_multiview_session *s = NULL;

    if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-host error=\"Device/Queue nicht erzeugt\"");
        return 70;
    }
    self_logf(&ctx, "[c64-kit] step=fov-support layers1=%d layers2=%d layers4=%d",
              kit_metal_supports_rate_map_layers(host_device, 1) ? 1 : 0,
              kit_metal_supports_rate_map_layers(host_device, 2) ? 1 : 0,
              kit_metal_supports_rate_map_layers(host_device, 4) ? 1 : 0);
    s = kit_multiview_begin(host_device, host_queue, log, user);
    if (!s) {
        result = 71;
        goto done;
    }

    /* Eigene Map: 1024×1024 logisch, 2 Schichten, 16×16 Stützstellen, asymmetrisches
     * Zweistufen-Profil (erstes Drittel 1,0, Rest 0,5), beide Schichten gleich. */
    if (!kit_metal_create_rate_map(host_device, 1024, 1024, KIT_VIEW_COUNT, 16, 0.5f, &map)) {
        self_logf(&ctx, "[c64-kit] FAIL step=fov-map error=\"Rate Map nicht erzeugt (Gerät ohne Unterstützung?)\"");
        result = 72;
        goto done;
    }
    kit_metal_map_desc md;
    kit_metal_map_info(map, &md);
    self_logf(&ctx, "[c64-kit] step=fov-map layers=%u screen=%ux%u physicalL0=%ux%u physicalL1=%ux%u granularity=%ux%u profile=firstThird1.0/rest0.5 layersEqual=1",
              md.layers, md.screen_width, md.screen_height, md.physical_width[0], md.physical_height[0],
              md.physical_width[1], md.physical_height[1], md.granularity_width, md.granularity_height);
    {
        /* Zur Anschauung: Mitte und Rand der logischen Fläche in physischen Koordinaten, Schicht 0. */
        float cx, cy, lx, ly, rx, ry;
        kit_metal_map_screen_to_physical(map, 0, 512, 512, &cx, &cy);
        kit_metal_map_screen_to_physical(map, 0, 64, 512, &lx, &ly);
        kit_metal_map_screen_to_physical(map, 0, 960, 512, &rx, &ry);
        self_logf(&ctx, "[c64-kit] step=fov-map-shape L0 screen(64,512)->physical(%.1f,%.1f) screen(512,512)->physical(%.1f,%.1f) screen(960,512)->physical(%.1f,%.1f)",
                  lx, ly, cx, cy, rx, ry);
    }

    /* Messbild gegen die Map. */
    kit_multiview_measure m;
    if (!kit_multiview_measure_map(s, map, true, &m)) {
        self_logf(&ctx, "[c64-kit] FAIL step=fov-measure error=\"%s\"", SDL_GetError());
        result = 73;
        goto done;
    }
    const bool within = m.max_dev_px <= 1.0f;
    self_logf(&ctx, "[c64-kit] step=fov-measure case=textureEqualsMap samples=%u maxDevPx=%.3f meanDevPx=%.3f screen=%ux%u physical=%ux%u layers=%u ms=%.2f ok=%d",
              m.samples, m.max_dev_px, m.mean_dev_px, m.screen_width, m.screen_height,
              m.physical_width, m.physical_height, m.layers, m.ms, within ? 1 : 0);
    if (!within) {
        result = 74;
        goto done;
    }

    /* Positivtest: Textur grösser als die physische Grösse der Map (wie der Compositor auf der
     * M2: Map 1856×1792, Textur 1888×1792). Stichproben bleiben im Raum der Map. */
    {
        kit_multiview_measure m2;
        const unsigned bigger_w = m.physical_width + 32, bigger_h = m.physical_height + 32;
        if (!kit_measure_impl(s, map, false, bigger_w, bigger_h, &m2)) {
            self_logf(&ctx, "[c64-kit] FAIL step=fov-measure case=textureLargerThanMap error=\"%s\"", SDL_GetError());
            result = 77;
            goto done;
        }
        const bool within2 = m2.max_dev_px <= 1.0f;
        self_logf(&ctx, "[c64-kit] step=fov-measure case=textureLargerThanMap texture=%ux%u mapPhysical=%ux%u samples=%u maxDevPx=%.3f meanDevPx=%.3f ok=%d",
                  bigger_w, bigger_h, m2.physical_width, m2.physical_height, m2.samples, m2.max_dev_px, m2.mean_dev_px, within2 ? 1 : 0);
        if (!within2) {
            result = 78;
            goto done;
        }
    }

    /* Negativtest 1: Textur kleiner als die physische Grösse der Map (64×64×2 gegen die Map). */
    {
        if (!kit_metal_create_array_texture(host_device, false, 64, 64, KIT_VIEW_COUNT, &mtl_color_small)) {
            result = 75;
            goto done;
        }
        color_small = kit_wrap(s->device, mtl_color_small, false, NULL);
        SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
        const float clear[4] = { 0, 0, 0, 1 };
        SDL_GPURenderPass *pass = (cmd && color_small) ? kit_begin_pass_map(cmd, color_small, NULL, clear, 0.0f, KIT_VIEW_COUNT, 0, map) : NULL;
        const bool failed = (pass == NULL);
        self_logf(&ctx, "[c64-kit] step=fov-negative case=textureSmallerThanMap failed=%d error=\"%s\"",
                  failed ? 1 : 0, failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
        if (pass) SDL_EndGPURenderPass(pass);
        if (cmd) SDL_CancelGPUCommandBuffer(cmd);
        if (!failed) result = 76;
    }

    /* Negativtest 2: Map mit Startschicht 1 (Ein-View-Pass auf Schicht 1 der Mess-Textur). */
    {
        SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
        const float clear[4] = { 0, 0, 0, 1 };
        SDL_GPURenderPass *pass = (cmd && s->measure_texture) ? kit_begin_pass_map(cmd, s->measure_texture, NULL, clear, 0.0f, 1, 1, map) : NULL;
        const bool failed = (pass == NULL);
        self_logf(&ctx, "[c64-kit] step=fov-negative case=mapWithBaseLayer1 failed=%d error=\"%s\"",
                  failed ? 1 : 0, failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
        if (pass) SDL_EndGPURenderPass(pass);
        if (cmd) SDL_CancelGPUCommandBuffer(cmd);
        if (!failed && result == 0) result = 79;
    }

done:
    if (s && s->device && color_small) {
        SDL_ReleaseGPUTexture(s->device, color_small);
    }
    if (s) {
        kit_multiview_end(s);
    }
    if (mtl_color_small) {
        kit_metal_release_texture(mtl_color_small);
    }
    if (map) {
        kit_metal_release_map(map);
    }
    kit_metal_release_host_objects(host_device, host_queue);
    self_logf(&ctx, "[c64-kit] result=%s failedStep=%d mode=foveation", result == 0 ? "ok" : "fail", result);
    return result;
}

/* ------------------------------------------------------------------ Mac-Selbsttest K4a (MSAA) */

/* Beide Schichten von Farbe (BGRA8) und Tiefe (D32F) zweier Host-Texturen vollständig lesen;
 * die Puffer gehören dem Aufrufer (SDL_free). */
static bool kit_read_layers(kit_multiview_session *s, void *mtl_color, void *mtl_depth, unsigned W, unsigned H,
                            unsigned layers, Uint8 **color_out, float **depth_out)
{
    bool ok = false;
    SDL_GPUTexture *color = kit_wrap(s->device, mtl_color, false, NULL);
    SDL_GPUTexture *depth = kit_wrap(s->device, mtl_depth, true, NULL);
    SDL_GPUTransferBuffer *tc = NULL, *td = NULL;
    SDL_GPUFence *fence = NULL;
    const Uint32 layer_bytes = W * H * 4;
    *color_out = NULL;
    *depth_out = NULL;
    if (!color || !depth) {
        goto done;
    }
    {
        SDL_GPUTransferBufferCreateInfo tinfo;
        SDL_zero(tinfo);
        tinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        tinfo.size = layer_bytes * layers;
        tc = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
        td = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
        if (!tc || !td) {
            goto done;
        }
        SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
        if (!cmd) {
            goto done;
        }
        SDL_GPUCopyPass *copy = SDL_BeginGPUCopyPass(cmd);
        if (!copy) {
            SDL_CancelGPUCommandBuffer(cmd);
            goto done;
        }
        for (unsigned layer = 0; layer < layers; layer++) {
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
            dst.transfer_buffer = tc;
            SDL_DownloadFromGPUTexture(copy, &src, &dst);
            src.texture = depth;
            dst.transfer_buffer = td;
            SDL_DownloadFromGPUTexture(copy, &src, &dst);
        }
        SDL_EndGPUCopyPass(copy);
        kit_push_tag(s, 'R');
        fence = SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (!fence || !SDL_WaitForGPUFences(s->device, true, &fence, 1)) {
            goto done;
        }
        const Uint8 *cp = (const Uint8 *)SDL_MapGPUTransferBuffer(s->device, tc, false);
        const float *dp = (const float *)SDL_MapGPUTransferBuffer(s->device, td, false);
        if (!cp || !dp) {
            goto done;
        }
        *color_out = (Uint8 *)SDL_malloc(layer_bytes * layers);
        *depth_out = (float *)SDL_malloc(layer_bytes * layers);
        SDL_memcpy(*color_out, cp, layer_bytes * layers);
        SDL_memcpy(*depth_out, dp, layer_bytes * layers);
        SDL_UnmapGPUTransferBuffer(s->device, tc);
        SDL_UnmapGPUTransferBuffer(s->device, td);
        ok = true;
    }
done:
    if (fence) SDL_ReleaseGPUFence(s->device, fence);
    if (tc) SDL_ReleaseGPUTransferBuffer(s->device, tc);
    if (td) SDL_ReleaseGPUTransferBuffer(s->device, td);
    if (color) SDL_ReleaseGPUTexture(s->device, color);
    if (depth) SDL_ReleaseGPUTexture(s->device, depth);
    return ok;
}

typedef struct kit_edge_result {
    unsigned full;            /* Kanal exakt 255 (Quad) */
    unsigned clear;           /* Kanal exakt 0 (Clear) */
    unsigned intermediate;    /* Zwischenwert: geglättete Kante */
    unsigned depth_match;     /* Kantenpixel, deren aufgelöste Tiefe zum Filter passt */
    unsigned depth_mismatch;
    float min_depth;
    bool center_ok;
    bool corner_ok;
    bool alpha_ok;
} kit_edge_result;

/* Eine Schicht auswerten: channel = BGRA-Index des Quad-Kanals (2 rot, 0 blau), filter 0/1/2. */
static void kit_edge_analyze(const Uint8 *c, const float *d, unsigned W, unsigned H, int channel,
                             float quad_depth, float clear_depth, unsigned filter, kit_edge_result *r)
{
    SDL_zerop(r);
    r->min_depth = 1e9f;
    r->alpha_ok = true;
    for (unsigned y = 0; y < H; y++) {
        for (unsigned x = 0; x < W; x++) {
            const unsigned idx = y * W + x;
            const Uint8 v = c[idx * 4 + channel];
            const float depth = d[idx];
            if (c[idx * 4 + 3] != 255) r->alpha_ok = false;
            if (depth < r->min_depth) r->min_depth = depth;
            if (v == 255) {
                r->full += 1;
            } else if (v == 0) {
                r->clear += 1;
            } else {
                r->intermediate += 1;
                bool match;
                if (filter == 2) {
                    match = SDL_fabsf(depth - quad_depth) < 1e-6f;
                } else if (filter == 1) {
                    match = SDL_fabsf(depth - clear_depth) < 1e-6f;
                } else {
                    match = SDL_fabsf(depth - quad_depth) < 1e-6f || SDL_fabsf(depth - clear_depth) < 1e-6f;
                }
                if (match) r->depth_match += 1; else r->depth_mismatch += 1;
            }
        }
    }
    const unsigned ci = (H / 2) * W + (W / 2);
    r->center_ok = (c[ci * 4 + channel] == 255) && SDL_fabsf(d[ci] - quad_depth) < 1e-6f;
    const unsigned ki = 4 * W + 4;
    r->corner_ok = (c[ki * 4 + channel] == 0) && SDL_fabsf(d[ki] - clear_depth) < 1e-6f;
}

/* Gedrehtes Quad mit schrägen Kanten rendern (View 0 rot/0,25, View 1 blau/0,75 über Clear
 * schwarz/0,001), beide Schichten lesen und auswerten. Loggt step=msaa-edge pro Schicht. */
static int kit_edge_round(kit_self_ctx *ctx, kit_multiview_session *s, void *mtl_color, void *mtl_depth,
                          unsigned W, unsigned H, void *map, const char *label, bool expect_smooth, int fail_code)
{
    float vp[32] = { 0 };
    for (int v = 0; v < 2; v++) {
        vp[v * 16 + 0] = 1; vp[v * 16 + 5] = 1; vp[v * 16 + 10] = 1; vp[v * 16 + 15] = 1;
    }
    vp[14] = 0.25f;
    vp[16 + 14] = 0.75f;
    const float center[3] = { 0, 0, 0 }, right[3] = { 0.6f, 0.15f, 0 }, up[3] = { -0.15f, 0.6f, 0 };
    const float clear[4] = { 0, 0, 0, 1 };
    const float clear_depth = 0.001f;
    const float quad_depth[2] = { 0.25f, 0.75f };
    const int channel[2] = { 2, 0 }; /* rot, blau in BGRA */
    kit_multiview_stats before, after;
    kit_multiview_take_stats(s, &before);
    if (!kit_multiview_frame(s, mtl_color, mtl_depth, clear, clear_depth, true, vp, center, right, up, map)) {
        self_logf(ctx, "[c64-kit] FAIL step=msaa-edge case=%s error=\"%s\"", label, SDL_GetError());
        return fail_code;
    }
    Uint8 *c = NULL;
    float *d = NULL;
    if (!kit_read_layers(s, mtl_color, mtl_depth, W, H, KIT_VIEW_COUNT, &c, &d)) {
        self_logf(ctx, "[c64-kit] FAIL step=msaa-edge-read case=%s error=\"%s\"", label, SDL_GetError());
        return fail_code;
    }
    int result = 0;
    for (unsigned layer = 0; layer < KIT_VIEW_COUNT; layer++) {
        kit_edge_result r;
        kit_edge_analyze(c + layer * W * H * 4, d + layer * W * H, W, H, channel[layer], quad_depth[layer], clear_depth,
                         s->opt.depth_filter, &r);
        const bool smooth_ok = expect_smooth ? (r.intermediate > 0) : (r.intermediate == 0);
        const bool depth_ok = (r.depth_mismatch == 0);
        const bool ok = smooth_ok && depth_ok && r.full > 0 && r.clear > 0 && r.center_ok && r.corner_ok && r.alpha_ok && r.min_depth > 0;
        self_logf(ctx, "[c64-kit] step=msaa-edge case=%s samples=%u filter=%s layer=%u color=%s full=%u clear=%u intermediate=%u depthAtEdges{match=%u mismatch=%u} minDepth=%.4f center=%d corner=%d alpha255=%d ok=%d",
                  label, s->opt.msaa_samples, kit_depth_filter_names[s->opt.depth_filter], layer, layer == 0 ? "rot" : "blau",
                  r.full, r.clear, r.intermediate, r.depth_match, r.depth_mismatch, r.min_depth,
                  r.center_ok ? 1 : 0, r.corner_ok ? 1 : 0, r.alpha_ok ? 1 : 0, ok ? 1 : 0);
        if (!ok) result = fail_code + 1;
    }
    SDL_free(c);
    SDL_free(d);
    /* GPU-Zeit dieses einen Frames aus dem Rückruf (nach dem Rücklesen ist der Frame sicher fertig);
     * erster Frame einer Sitzung, also mit Aufwärmen. Der Vergleich steht in step=msaa-gpu-bench. */
    kit_multiview_take_stats(s, &after);
    self_logf(ctx, "[c64-kit] step=msaa-gpu case=%s gpuFrames=%u gpu(ms) mean=%.3f max=%.3f untagged=%lu gpuErr=%lu (einzelner Frame, mit Aufwaermen)",
              label, after.gpu_frames, after.gpu_frames ? after.gpu_sum_ms / after.gpu_frames : 0.0, after.gpu_max_ms,
              after.gpu_untagged, after.gpu_errors);
    (void)before;
    return result;
}

/* GPU-Zeit über viele gleiche Frames ohne Aufwärmphase: `frames` Frames rendern, die ersten `skip`
 * Abschlüsse nicht werten, dann Mittel, p95 und Maximum aus dem Rückruf. */
static bool kit_gpu_bench(kit_self_ctx *ctx, kit_multiview_session *s, void *mtl_color, void *mtl_depth, void *map,
                          const char *label, unsigned frames, unsigned skip)
{
    float vp[32] = { 0 };
    for (int v = 0; v < 2; v++) {
        vp[v * 16 + 0] = 1; vp[v * 16 + 5] = 1; vp[v * 16 + 10] = 1; vp[v * 16 + 15] = 1;
    }
    vp[14] = 0.25f;
    vp[16 + 14] = 0.75f;
    const float center[3] = { 0, 0, 0 }, right[3] = { 0.6f, 0.15f, 0 }, up[3] = { -0.15f, 0.6f, 0 };
    const float clear[4] = { 0, 0, 0, 1 };
    kit_multiview_stats drop;
    /* Zähler auf Null: Aufwärmphase neu ab hier. */
    SDL_LockMutex(s->gpu_lock);
    s->gpu_completed_frames = 0;
    s->gpu_sample_count = 0;
    s->gpu_skip = skip;
    s->stats.gpu_frames_total = 0;
    s->stats.gpu_total_sum_ms = 0;
    s->stats.gpu_total_max_ms = 0;
    SDL_UnlockMutex(s->gpu_lock);
    kit_multiview_take_stats(s, &drop);
    for (unsigned i = 0; i < frames; i++) {
        if (!kit_multiview_frame(s, mtl_color, mtl_depth, clear, 0.001f, true, vp, center, right, up, map)) {
            self_logf(ctx, "[c64-kit] FAIL step=msaa-gpu-bench case=%s frame=%u error=\"%s\"", label, i, SDL_GetError());
            return false;
        }
    }
    SDL_WaitForGPUIdle(s->device);
    SDL_Delay(5); /* Rückrufe der letzten Buffer */
    unsigned n = 0;
    double mean = 0, p95 = 0, mx = 0;
    kit_multiview_gpu_percentiles(s, &n, &mean, &p95, &mx);
    kit_multiview_stats st;
    kit_multiview_take_stats(s, &st);
    self_logf(ctx, "[c64-kit] step=msaa-gpu-bench case=%s samples=%u frames=%u skipped=%u counted=%u gpu(ms) mean=%.3f p95=%.3f max=%.3f untagged=%lu gpuErr=%lu",
              label, s->opt.msaa_samples, frames, skip, n, mean, p95, mx, st.gpu_untagged, st.gpu_errors);
    return n > 0;
}

int kit_multiview_msaa_selftest(kit_log_fn log, void *user)
{
    kit_self_ctx ctx;
    SDL_zero(ctx);
    ctx.log = log;
    ctx.user = user;

    int result = 0;
    void *host_device = NULL, *host_queue = NULL;
    void *map = NULL;
    void *mtl_color = NULL, *mtl_depth = NULL;
    kit_multiview_session *s = NULL;
    kit_multiview_options opt;
    unsigned W = 0, H = 0;

    if (!kit_metal_create_host_objects(&host_device, &host_queue)) {
        self_logf(&ctx, "[c64-kit] FAIL step=selftest-host error=\"Device/Queue nicht erzeugt\"");
        return 90;
    }
    kit_multiview_options_default(&opt);
    opt.msaa_samples = 4;
    opt.depth_filter = 2;
    opt.pattern = 0.0f;
    opt.with_bar = false;
    const float colors[2][4] = { { 1, 0, 0, 1 }, { 0, 0, 1, 1 } };
    SDL_memcpy(opt.view_colors, colors, sizeof(colors));
    s = kit_multiview_begin_ex(host_device, host_queue, &opt, log, user);
    if (!s) {
        result = 91;
        goto done;
    }

    /* Map wie K3: 1024×1024 logisch, physisch 688×688; «Drawable» in dieser Grösse. */
    if (!kit_metal_create_rate_map(host_device, 1024, 1024, KIT_VIEW_COUNT, 16, 0.5f, &map)) {
        self_logf(&ctx, "[c64-kit] FAIL step=msaa-map error=\"Rate Map nicht erzeugt\"");
        result = 92;
        goto done;
    }
    {
        kit_metal_map_desc md;
        kit_metal_map_info(map, &md);
        W = md.physical_width[0];
        H = md.physical_height[0];
    }
    if (!kit_metal_create_array_texture(host_device, false, W, H, KIT_VIEW_COUNT, &mtl_color) ||
        !kit_metal_create_array_texture(host_device, true, W, H, KIT_VIEW_COUNT, &mtl_depth)) {
        self_logf(&ctx, "[c64-kit] FAIL step=msaa-textures error=\"Aufloesungstexturen nicht erzeugt\"");
        result = 93;
        goto done;
    }
    self_logf(&ctx, "[c64-kit] step=msaa-setup resolve{%ux%ux%u bgra8_srgb+d32f samples=1} msaa=%u map{screen=1024x1024 physical=%ux%u} quad=gedreht(right=0.6,0.15 up=-0.15,0.6) view0=rot/0.25 view1=blau/0.75 clear=schwarz/0.001",
              W, H, KIT_VIEW_COUNT, opt.msaa_samples, W, H);

    /* Kante mit MSAA 4x, Filter max: Zwischenwerte, Tiefe an Kanten = Quad. */
    result = kit_edge_round(&ctx, s, mtl_color, mtl_depth, W, H, map, "msaa4-max", true, 94);
    if (result) goto done;

    /* Filter min: Tiefe an Kanten = Clear. */
    kit_multiview_set_depth_filter(s, 1);
    result = kit_edge_round(&ctx, s, mtl_color, mtl_depth, W, H, map, "msaa4-min", true, 96);
    if (result) goto done;
    kit_multiview_set_depth_filter(s, 2);

    /* Messbild der Map unter MSAA (Mess-Textur = Map-Grösse und 32 px grösser). */
    {
        kit_multiview_measure m;
        if (!kit_multiview_measure_map(s, map, false, &m)) {
            self_logf(&ctx, "[c64-kit] FAIL step=msaa-measure error=\"%s\"", SDL_GetError());
            result = 99;
            goto done;
        }
        const bool within = m.max_dev_px <= 1.0f;
        self_logf(&ctx, "[c64-kit] step=msaa-measure case=textureEqualsMap samples=%u maxDevPx=%.3f meanDevPx=%.3f physical=%ux%u ms=%.2f ok=%d",
                  opt.msaa_samples, m.max_dev_px, m.mean_dev_px, m.physical_width, m.physical_height, m.ms, within ? 1 : 0);
        if (!within) { result = 100; goto done; }
        kit_multiview_measure m2;
        if (!kit_measure_impl(s, map, false, W + 32, H + 32, &m2)) {
            self_logf(&ctx, "[c64-kit] FAIL step=msaa-measure case=textureLargerThanMap error=\"%s\"", SDL_GetError());
            result = 101;
            goto done;
        }
        const bool within2 = m2.max_dev_px <= 1.0f;
        self_logf(&ctx, "[c64-kit] step=msaa-measure case=textureLargerThanMap texture=%ux%u mapPhysical=%ux%u samples=%u maxDevPx=%.3f meanDevPx=%.3f ok=%d",
                  W + 32, H + 32, m2.physical_width, m2.physical_height, opt.msaa_samples, m2.max_dev_px, m2.mean_dev_px, within2 ? 1 : 0);
        if (!within2) { result = 102; goto done; }
    }

    /* Negativtests am Pass. */
    {
        SDL_GPUTexture *color_res = kit_wrap(s->device, mtl_color, false, NULL);
        SDL_GPUTexture *depth_res = kit_wrap(s->device, mtl_depth, true, NULL);
        const float clear[4] = { 0, 0, 0, 1 };
        kit_pass_desc d;
        SDL_zero(d);
        d.color = s->msaa_color;
        d.depth = s->msaa_depth;
        d.color_resolve = color_res;
        SDL_memcpy(d.rgba, clear, sizeof(clear));
        d.depth_clear = 0.001f;
        d.view_count = KIT_VIEW_COUNT;
        d.rate_map = map;
        /* A: Auflösungstextur der Tiefe ist selbst multisample. */
        d.depth_resolve = s->msaa_depth;
        d.depth_filter = 2;
        {
            SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
            SDL_GPURenderPass *pass = cmd ? kit_begin_pass_ex(cmd, &d) : NULL;
            const bool failed = (pass == NULL);
            self_logf(&ctx, "[c64-kit] step=msaa-negative case=depthResolveTextureMultisample failed=%d error=\"%s\"",
                      failed ? 1 : 0, failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
            if (pass) SDL_EndGPURenderPass(pass);
            if (cmd) SDL_CancelGPUCommandBuffer(cmd);
            if (!failed) result = 103;
        }
        /* B: unbekannter Filter. */
        d.depth_resolve = depth_res;
        d.depth_filter_override = "median";
        {
            SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
            SDL_GPURenderPass *pass = cmd ? kit_begin_pass_ex(cmd, &d) : NULL;
            const bool failed = (pass == NULL);
            self_logf(&ctx, "[c64-kit] step=msaa-negative case=unknownDepthFilter failed=%d error=\"%s\"",
                      failed ? 1 : 0, failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
            if (pass) SDL_EndGPURenderPass(pass);
            if (cmd) SDL_CancelGPUCommandBuffer(cmd);
            if (!failed && result == 0) result = 104;
        }
        if (color_res) SDL_ReleaseGPUTexture(s->device, color_res);
        if (depth_res) SDL_ReleaseGPUTexture(s->device, depth_res);
        if (result) goto done;
    }

    /* K4b, Schritt 1 und 2: Speicher der MSAA-Ziele. Pro Variante (memoryless aus, an) eine frische
     * Sitzung, fünf Frames und eine Messung (legt die Mess-Texturen an), dann phys_footprint-Delta,
     * Container-Zählung und Negativtests der memoryless-Regeln. */
    kit_multiview_end(s);
    s = NULL;
    for (unsigned variant = 0; variant < 2 && result == 0; variant++) {
        const unsigned long long f0 = kit_metal_process_footprint_bytes();
        opt.msaa_samples = 4;
        opt.memoryless = (variant == 1);
        s = kit_multiview_begin_ex(host_device, host_queue, &opt, log, user);
        if (!s) {
            result = 112;
            break;
        }
        float vp[32] = { 0 };
        for (int v = 0; v < 2; v++) {
            vp[v * 16 + 0] = 1; vp[v * 16 + 5] = 1; vp[v * 16 + 10] = 1; vp[v * 16 + 15] = 1;
        }
        vp[14] = 0.25f;
        vp[16 + 14] = 0.75f;
        const float center[3] = { 0, 0, 0 }, right[3] = { 0.6f, 0.15f, 0 }, up[3] = { -0.15f, 0.6f, 0 };
        const float clear[4] = { 0, 0, 0, 1 };
        bool ok = true;
        for (unsigned i = 0; i < 5 && ok; i++) {
            ok = kit_multiview_frame(s, mtl_color, mtl_depth, clear, 0.001f, true, vp, center, right, up, map);
        }
        kit_multiview_measure m;
        if (!ok || !kit_multiview_measure_map(s, map, false, &m)) {
            self_logf(&ctx, "[c64-kit] FAIL step=msaa-memory memoryless=%u error=\"%s\"", variant, SDL_GetError());
            result = 113;
            break;
        }
        SDL_WaitForGPUIdle(s->device);
        const unsigned long long f1 = kit_metal_process_footprint_bytes();
        kit_multiview_log_containers(s);
        kit_multiview_stats st;
        kit_multiview_take_stats(s, &st);
        self_logf(&ctx, "[c64-kit] step=msaa-memory memoryless=%u footprintMB before=%.1f after=%.1f delta=%+.1f msaaNominalMB=%.1f measureMsaaNominalMB=%.1f measureResolveMB=%.1f maxDevPx=%.3f",
                  variant, (double)f0 / (1024.0 * 1024.0), (double)f1 / (1024.0 * 1024.0), ((double)f1 - (double)f0) / (1024.0 * 1024.0),
                  (double)st.msaa_nominal_bytes / (1024.0 * 1024.0), (double)st.measure_msaa_nominal_bytes / (1024.0 * 1024.0),
                  (double)W * H * KIT_VIEW_COUNT * 8 / (1024.0 * 1024.0), m.max_dev_px);
        if (m.max_dev_px > 1.0f) {
            result = 114;
            break;
        }
        /* Kante mit memoryless-Zielen muss gleich aussehen wie ohne. */
        if (variant == 1) {
            result = kit_edge_round(&ctx, s, mtl_color, mtl_depth, W, H, map, "msaa4-memoryless", true, 115);
            if (result) break;
            /* Negativtests der memoryless-Regeln. */
            SDL_GPUTexture *color_res = kit_wrap(s->device, mtl_color, false, NULL);
            SDL_GPUTexture *depth_res = kit_wrap(s->device, mtl_depth, true, NULL);
            {
                /* A: LOAD auf memoryless Farbziel. */
                SDL_GPUColorTargetInfo ct;
                SDL_zero(ct);
                ct.texture = s->msaa_color;
                ct.load_op = SDL_GPU_LOADOP_LOAD;
                ct.store_op = SDL_GPU_STOREOP_RESOLVE;
                ct.resolve_texture = color_res;
                SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
                SDL_GPURenderPass *pass = cmd ? SDL_BeginGPURenderPass(cmd, &ct, 1, NULL) : NULL;
                const bool failed = (pass == NULL);
                self_logf(&ctx, "[c64-kit] step=msaa-negative case=memorylessLoad failed=%d error=\"%s\"", failed ? 1 : 0,
                          failed ? SDL_GetError() : "(kein Fehler, Pass begann)");
                if (pass) SDL_EndGPURenderPass(pass);
                if (cmd) SDL_CancelGPUCommandBuffer(cmd);
                if (!failed) result = 116;
                /* B: STORE auf memoryless Farbziel. */
                ct.load_op = SDL_GPU_LOADOP_CLEAR;
                ct.store_op = SDL_GPU_STOREOP_STORE;
                ct.resolve_texture = NULL;
                cmd = SDL_AcquireGPUCommandBuffer(s->device);
                pass = cmd ? SDL_BeginGPURenderPass(cmd, &ct, 1, NULL) : NULL;
                const bool failed2 = (pass == NULL);
                self_logf(&ctx, "[c64-kit] step=msaa-negative case=memorylessStore failed=%d error=\"%s\"", failed2 ? 1 : 0,
                          failed2 ? SDL_GetError() : "(kein Fehler, Pass begann)");
                if (pass) SDL_EndGPURenderPass(pass);
                if (cmd) SDL_CancelGPUCommandBuffer(cmd);
                if (!failed2 && result == 0) result = 117;
            }
            {
                /* C: memoryless mit SAMPLER-Usage. */
                SDL_GPUTextureCreateInfo info;
                SDL_zero(info);
                info.type = SDL_GPU_TEXTURETYPE_2D;
                info.format = s->color_format;
                info.usage = SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | SDL_GPU_TEXTUREUSAGE_SAMPLER;
                info.width = 64;
                info.height = 64;
                info.layer_count_or_depth = 1;
                info.num_levels = 1;
                info.sample_count = SDL_GPU_SAMPLECOUNT_4;
                info.props = SDL_CreateProperties();
                SDL_SetBooleanProperty(info.props, SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN, true);
                SDL_GPUTexture *t = SDL_CreateGPUTexture(s->device, &info);
                SDL_DestroyProperties(info.props);
                const bool failed = (t == NULL);
                self_logf(&ctx, "[c64-kit] step=msaa-negative case=memorylessWithSamplerUsage failed=%d error=\"%s\"", failed ? 1 : 0,
                          failed ? SDL_GetError() : "(kein Fehler, Textur erzeugt)");
                if (t) SDL_ReleaseGPUTexture(s->device, t);
                if (!failed && result == 0) result = 118;
            }
            {
                /* D: Download aus memoryless Textur (Kopierpass; die Funktion ist void, der
                 * Fehlertext steht in SDL_GetError). */
                SDL_GPUTransferBufferCreateInfo tinfo;
                SDL_zero(tinfo);
                tinfo.usage = SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
                tinfo.size = 64;
                SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(s->device, &tinfo);
                SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(s->device);
                SDL_GPUCopyPass *copy = cmd ? SDL_BeginGPUCopyPass(cmd) : NULL;
                bool failed = false;
                if (copy && tb) {
                    SDL_GPUTextureRegion src;
                    SDL_zero(src);
                    src.texture = s->msaa_color;
                    src.w = 1; src.h = 1; src.d = 1;
                    SDL_GPUTextureTransferInfo dst;
                    SDL_zero(dst);
                    dst.transfer_buffer = tb;
                    SDL_ClearError();
                    SDL_DownloadFromGPUTexture(copy, &src, &dst);
                    failed = SDL_GetError()[0] != '\0';
                    self_logf(&ctx, "[c64-kit] step=msaa-negative case=downloadFromMemoryless failed=%d error=\"%s\"", failed ? 1 : 0,
                              failed ? SDL_GetError() : "(kein Fehler gemeldet)");
                    SDL_EndGPUCopyPass(copy);
                }
                if (cmd) SDL_CancelGPUCommandBuffer(cmd);
                if (tb) SDL_ReleaseGPUTransferBuffer(s->device, tb);
                if (!failed && result == 0) result = 119;
            }
            if (color_res) SDL_ReleaseGPUTexture(s->device, color_res);
            if (depth_res) SDL_ReleaseGPUTexture(s->device, depth_res);
        }
        kit_multiview_end(s);
        s = NULL;
    }
    if (result) goto done;

    /* GPU-Zeit im Wechsel: vier frische Sitzungen (4x, ohne, 4x, ohne), je 240 gleiche Frames,
     * die ersten 120 nicht gewertet. Der Wechsel zeigt, ob die Reihenfolge (GPU-Takt des Mac
     * ohne Vsync-Taktung) die Zahlen bestimmt; in der ersten Sitzung ohne MSAA zusätzlich
     * dieselbe Kante hart (keine Zwischenwerte). */
    kit_multiview_end(s);
    s = NULL;
    for (unsigned round = 0; round < 4 && result == 0; round++) {
        const unsigned samples = (round % 2 == 0) ? 4 : 0;
        opt.memoryless = false;
        char label[32];
        SDL_snprintf(label, sizeof(label), "%s-r%u", samples ? "msaa4" : "noMsaa", round + 1);
        opt.msaa_samples = samples;
        s = kit_multiview_begin_ex(host_device, host_queue, &opt, log, user);
        if (!s) {
            result = 105;
            break;
        }
        if (round == 1) {
            result = kit_edge_round(&ctx, s, mtl_color, mtl_depth, W, H, map, "noMsaa", false, 106);
            if (result) break;
        }
        if (!kit_gpu_bench(&ctx, s, mtl_color, mtl_depth, map, label, 240, 120)) {
            result = 108 + round;
            break;
        }
        kit_multiview_end(s);
        s = NULL;
    }

done:
    if (s) {
        kit_multiview_end(s);
    }
    kit_metal_release_texture(mtl_color);
    kit_metal_release_texture(mtl_depth);
    if (map) {
        kit_metal_release_map(map);
    }
    kit_metal_release_host_objects(host_device, host_queue);
    self_logf(&ctx, "[c64-kit] result=%s failedStep=%d mode=msaa", result == 0 ? "ok" : "fail", result);
    return result;
}
