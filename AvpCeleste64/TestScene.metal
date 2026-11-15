//
//  TestScene.metal
//  AvpCeleste64
//
//  Test scene: a quad with a fine checkerboard, anchored in the world, both eyes in one draw
//  through vertex amplification. The matrix per view comes from the uniform array, indexed by
//  the amplification ID. Triangles only (Metal requires that under a rate map).
//

#include <metal_stdlib>
using namespace metal;

struct C64TestUniforms {
    float4x4 viewProjection[2];   // per view: projection * inverse(deviceAnchor * view.transform)
    float4   center;              // centre of the quad in world coordinates (m)
    float4   right;               // right vector * half width (m)
    float4   up;                  // up vector * half height (m)
};

struct C64TestInOut {
    float4 position [[position]];
    float2 uv;
};

// Six vertices, two triangles, corners from the vertex ID; no vertex buffer needed.
vertex C64TestInOut c64_test_vertex(uint vertexID [[vertex_id]],
                                    ushort amplificationID [[amplification_id]],
                                    constant C64TestUniforms &uniforms [[buffer(0)]])
{
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1)
    };
    float2 uv = corners[vertexID];
    float3 world = uniforms.center.xyz
                 + (uv.x * 2.0 - 1.0) * uniforms.right.xyz
                 + (uv.y * 2.0 - 1.0) * uniforms.up.xyz;

    C64TestInOut out;
    out.position = uniforms.viewProjection[amplificationID] * float4(world, 1.0);
    out.uv = uv;
    return out;
}

// Checkerboard of 64 × 64 fields, plus a thin red crosshair in the centre as a fixation point.
fragment float4 c64_test_fragment(C64TestInOut in [[stage_in]])
{
    const float fields = 64.0;
    int2 cell = int2(floor(in.uv * fields));
    bool light = ((cell.x + cell.y) & 1) == 0;
    float3 color = light ? float3(0.9, 0.9, 0.9) : float3(0.08, 0.08, 0.08);

    float2 d = abs(in.uv - 0.5);
    if (d.x < 0.003 || d.y < 0.003) {
        color = float3(0.9, 0.1, 0.1);
    }
    return float4(color, 1.0);
}

// Canvas: the same quad as the test scene, the fragment shader samples the canvas. The texture
// arrives as an sRGB view (linear after sampling), the drawable encodes back when writing.
// uv (0,0) is the bottom-left corner of the quad, texture row 0 is at the top, so v is
// mirrored: the mark at the top left of the texture appears at the top left in the world.
// fade (0 to 1) fades in after anchoring; the canvas stays opaque (alpha 1), only the colour
// is pulled up from the black of the base clear.
fragment float4 c64_canvas_fragment(C64TestInOut in [[stage_in]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler canvasSampler [[sampler(0)]],
                                    constant float &fade [[buffer(0)]])
{
    float3 color = canvas.sample(canvasSampler, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
    return float4(color * fade, 1.0);
}
