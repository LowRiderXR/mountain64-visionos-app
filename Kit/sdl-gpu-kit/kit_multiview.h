/*
 * kit_multiview.h — SDL_GPU kit for visionOS, stages multiview, rate map and MSAA (with resolve
 * of colour and depth into the drawable layers).
 *
 * Both eyes in one render pass and one draw: pipeline with
 * SDL_PROP_GPU_GRAPHICSPIPELINE_CREATE_VIEW_COUNT_NUMBER = 2, pass through
 * SDL_BeginGPURenderPassWithProperties with SDL_PROP_GPU_RENDERPASS_CREATE_VIEW_COUNT_NUMBER = 2
 * onto the host's imported drawable textures. View i writes layer i. Shaders from
 * shaders/multiview.hlsl through the kit toolchain (kit_shaders_generated.h).
 *
 * Rules (reverse-Z depth on visionOS: 0 is far, larger is nearer): clear with depth > 0 (default
 * 0.001), quad with depth writes and compare greater; the host presents after the SDL submit.
 */

#ifndef KIT_MULTIVIEW_H
#define KIT_MULTIVIEW_H

#include <stdbool.h>

#include "kit_testscene.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kit_multiview_session kit_multiview_session;

typedef struct kit_multiview_stats {
    /* window values since the last kit_multiview_take_stats */
    unsigned frames;
    unsigned fails;
    double sum_ms;
    double max_ms;
    /* totals */
    unsigned long frames_total;
    unsigned long fails_total;
    unsigned long passes_total;    /* render passes through SDL */
    unsigned long draws_total;     /* draw calls through SDL */
    double total_sum_ms;           /* CPU time of the SDL part over all frames */
    double total_max_ms;
    unsigned long wrappers_created;
    unsigned long wrappers_released;
    /* GPU time of the frames' SDL command buffers (GPUEndTime − GPUStartTime, from the completion
     * callback of the Metal backend), window and total. Measurement and read-back buffers do not
     * count; untagged = completions of unknown origin, errors = status ≠ completed. */
    unsigned gpu_frames;
    double gpu_sum_ms;
    double gpu_max_ms;
    unsigned long gpu_frames_total;
    double gpu_total_sum_ms;
    double gpu_total_max_ms;
    unsigned long gpu_untagged;
    unsigned long gpu_errors;
    /* MSAA state of the session (0 = off); size of the MSAA textures and their allocatedSize. */
    unsigned msaa_samples;
    unsigned msaa_width;
    unsigned msaa_height;
    unsigned msaa_layers;
    unsigned long long msaa_bytes;     /* allocatedSize of the host textures, nominal with memoryless */
    unsigned depth_filter;         /* 0 sample0, 1 min, 2 max */
    /* memoryless */
    unsigned memoryless;           /* 1: MSAA targets and measurement MSAA texture memoryless (SDL property) */
    unsigned long long msaa_nominal_bytes;      /* width × height × layers × samples × bytes, both targets */
    unsigned long long measure_msaa_nominal_bytes; /* RG32F MSAA texture of the measurement image, nominal */
    /* depth store */
    unsigned depth_store;          /* 1: store_op of the MSAA depth target STORE (StoreAndMultisampleResolve) */
    unsigned long probes_total;    /* depth probes executed (step=depth-probe) */
} kit_multiview_stats;

/* Options of the session. msaa_samples 0 or 1 = without anti-aliasing. With MSAA the session
 * creates two 2D multisample array textures of drawable size (colour, depth) at the first frame,
 * renders into them and resolves colour (store_op RESOLVE) and depth (pass property
 * SDL_PROP_GPU_RENDERPASS_CREATE_METAL_DEPTH_RESOLVE_TEXTURE_POINTER) into the drawable layers.
 * depth_filter: 0 sample0, 1 min, 2 max (reverse-Z: max = nearest surface, default).
 * pattern/view_colors: content of the quad (default white checkerboard; the Mac test uses flat
 * colours per view). with_bar (default on): next to the board a narrow, tilted bar from geometry
 * at which MSAA becomes visible. memoryless: create the MSAA targets and the MSAA texture of the
 * measurement image with SDL_PROP_GPU_TEXTURE_CREATE_METAL_MEMORYLESS_BOOLEAN (tile memory only,
 * resolve at the end of the pass); without memoryless the host creates the MSAA targets and
 * imports them (allocatedSize measurable).
 * Device test "depth resolve with multiview and stored MSAA samples": depth_store: store_op of
 * the MSAA depth target STORE instead of DONT_CARE, Metal turns that into
 * StoreAndMultisampleResolve instead of MultisampleResolve (requires memoryless off). depth_probe:
 * from frame 120 every 300 frames render the same pass a second time, resolve colour and depth
 * (filter max) into its own 1x two-layer textures, not into the drawable, and read the depth of
 * both layers back (step=depth-probe: written pixels, distinct values, minimum, maximum). The
 * probe waits synchronously for the GPU (one late frame per probe). Both require MSAA. */
typedef struct kit_multiview_options {
    unsigned msaa_samples;
    unsigned depth_filter;
    float pattern;
    float view_colors[2][4];
    bool with_bar;
    bool memoryless;
    bool depth_store;
    bool depth_probe;
} kit_multiview_options;

/* Result of a depth probe. The probe textures are cleared before the pass to the sentinel 1.0
 * (depth) and black (colour); "written" counts pixels whose depth is no longer the sentinel,
 * "distinct" the distinct bit patterns including the sentinel, min/max only over written pixels,
 * color_nonblack the pixels of the resolved colour with one channel > 0 (check that the colour of
 * both views arrives). */
typedef struct kit_depth_probe_layer {
    unsigned total;
    unsigned written;
    unsigned nan;
    unsigned distinct;
    float min_written;
    float max_written;
    unsigned color_nonblack;
} kit_depth_probe_layer;

typedef struct kit_depth_probe_result {
    unsigned long frame;        /* frames_total at the probe pass */
    unsigned width;
    unsigned height;
    unsigned layers;
    unsigned depth_store;
    unsigned filter;            /* always 2 (max) */
    kit_depth_probe_layer layer[2];
    double ms;                  /* CPU time including waiting for the GPU and the analysis */
} kit_depth_probe_result;

/* Run the depth probe at once and evaluate it synchronously. Size = drawable size (the session's
 * MSAA targets are created or reused for it), quad and matrices like kit_multiview_frame,
 * rate_map optional. Logs step=depth-probe per layer and step=depth-probe-summary. false on
 * error (SDL_GetError). */
bool kit_multiview_depth_probe(kit_multiview_session *session, unsigned width, unsigned height, unsigned layers,
                               const float rgba[4], float depth_clear, const float view_projection[32],
                               const float center[3], const float right[3], const float up[3], void *rate_map,
                               kit_depth_probe_result *out);

/* Diagnostics of the SDL texture containers (textureCount, canBeCycled) of the MSAA targets;
 * logs step=msaa-containers. Reads the internal layout of the Metal backend at the pinned
 * revision (test use only). */
void kit_multiview_log_containers(kit_multiview_session *session);

void kit_multiview_options_default(kit_multiview_options *out);

/* SDL_GPU device on the host's device and queue, shaders and pipeline with view_count 2.
 * Logs step=multiview (SDL_GPUSupportsViewCount, pipeline, formats). NULL on error. */
kit_multiview_session *kit_multiview_begin(void *metal_device, void *metal_queue, kit_log_fn log, void *user);

/* Like kit_multiview_begin with options (NULL = default). */
kit_multiview_session *kit_multiview_begin_ex(void *metal_device, void *metal_queue, const kit_multiview_options *options,
                                              kit_log_fn log, void *user);

/* Switch the depth resolve filter (0 sample0, 1 min, 2 max); applies from the next pass. */
void kit_multiview_set_depth_filter(kit_multiview_session *session, unsigned depth_filter);

/* GPU time of the frames without the warm-up phase. The first `skip` completed frame command
 * buffers (default 90) count neither in the totals nor in the percentiles; the window values
 * (gpu_frames, gpu_sum_ms, gpu_max_ms) count all. The last 4096 times are kept as a sample;
 * kit_multiview_gpu_percentiles returns count, mean, p95 and maximum over them. */
void kit_multiview_set_gpu_skip(kit_multiview_session *session, unsigned skip);
void kit_multiview_gpu_percentiles(kit_multiview_session *session, unsigned *count, double *mean_ms,
                                   double *p95_ms, double *max_ms);

/* One frame: import colour and depth texture, one pass with view_count 2, clear (rgba,
 * depth_clear), with draw_quad one draw of the quad with the two matrices (16 float each, column
 * major like simd_float4x4), center/right/up (3 float each, metres), checkerboard.
 * rate_map: id<MTLRasterizationRateMap> of the compositor or NULL; with a map viewport and
 * scissor are logical (screenSize), SDL sets both from the map.
 * false when a step fails; the host then clears itself. */
bool kit_multiview_frame(kit_multiview_session *session, void *color_texture, void *depth_texture,
                         const float rgba[4], float depth_clear, bool draw_quad,
                         const float view_projection[32], const float center[3],
                         const float right[3], const float up[3], void *rate_map);

/* Measurement image against a rate map. Renders into its own float texture of physical size (two
 * layers) one pass with view_count 2 and the map that writes the logical fragment position as
 * colour, reads back at several physical sample points of both layers and compares with
 * mapPhysicalToScreenCoordinates / mapScreenToPhysicalCoordinates of the map. Deviation in
 * physical pixels. Texture and pipeline are created at the first call. */
typedef struct kit_multiview_measure {
    unsigned samples;
    float max_dev_px;
    float mean_dev_px;
    unsigned screen_width;
    unsigned screen_height;
    unsigned physical_width;
    unsigned physical_height;
    unsigned layers;
    double ms;              /* CPU time of the measurement including waiting for the GPU */
} kit_multiview_measure;

/* Measurement image against the map: own RG32F array texture of the map's physical size (not
 * the drawable texture's), sample points in that space; verbose logs every sample point and
 * step=fov-sample-space. */
bool kit_multiview_measure_map(kit_multiview_session *session, void *rate_map, bool verbose, kit_multiview_measure *out);

/* Read and reset the window values; totals stay. */
void kit_multiview_take_stats(kit_multiview_session *session, kit_multiview_stats *out);

/* Wait for the GPU, release pipeline, shaders and device, log step=multiview-end. */
void kit_multiview_end(kit_multiview_session *session);

/* Mac self-test: own device/queue, 2D array textures 64×64×2, one pass with view_count 2 and one
 * draw that writes view 0 red with depth 0.25 and view 1 blue with depth 0.75 (flat colour),
 * read-back of both layers; negative tests: pipeline with view_count 1 in a pass with view_count
 * 2, pass with view_count 3 on 2 layers. SDL_Init must have run. 0 = passed, otherwise step
 * number from 40. */
int kit_multiview_selftest(kit_log_fn log, void *user);

/* Mac self-test of the rate map: own two-layer map (1024×1024 logical, two steps, edge 0.5),
 * measurement image like kit_multiview_measure_map with texture = map size and with texture 32 px
 * larger than the map (compositor case), acceptance at most 1 physical pixel each; negative
 * tests: texture smaller than the map, map with base layer 1. 0 = passed, otherwise step number
 * from 70. */
int kit_multiview_foveation_selftest(kit_log_fn log, void *user);

/* Mac self-test MSAA: two-layer map as above, resolve textures 688×688×2 (colour, depth) as
 * "drawable", session with MSAA 4x, one pass with view_count 2 and map, a rotated quad with
 * slanted edges (view 0 red/0.25, view 1 blue/0.75 over clear black/0.001), colour and depth
 * resolved into the resolve textures, both layers read back completely: edge pixels with
 * intermediate values, surfaces exact, resolved depth at edge pixels per filter (max -> quad,
 * min -> clear), smallest depth > 0; the same edge hard without MSAA; measurement image of the
 * map under MSAA ≤ 1 px (also with texture larger than the map); negative tests (resolve texture
 * multisample, unknown filter). 0 = passed, otherwise step number from 90. */
int kit_multiview_msaa_selftest(kit_log_fn log, void *user);

/* Mac reproduction of the depth store case: resolve textures 688×688×2 as in the MSAA test, one
 * session each with MSAA 4x and depth_store off (dontcare) and on (store), one depth probe each
 * without and with the two-layer map. Acceptance only for dontcare: both layers completely
 * written, layer 0 up to 0.25 and layer 1 up to 0.75 (quad depths of the views), colour in both
 * layers. For store the finding is only logged (step=depth-probe-summary), it is no error of the
 * kit. 0 = passed, otherwise step number from 130. */
int kit_multiview_depth_store_selftest(kit_log_fn log, void *user);

#ifdef __cplusplus
}
#endif

#endif /* KIT_MULTIVIEW_H */
