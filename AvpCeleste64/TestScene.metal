//
//  TestScene.metal
//  AvpCeleste64
//
//  Testszene P0b-2: ein Quad mit feinem Schachbrett, in der Welt verankert, beide Augen in
//  einem Draw per Vertex Amplification. Die Matrix pro View kommt aus dem Uniform-Array,
//  Index über die Amplification-ID. Nur Dreiecke (Metal verlangt das unter einer Rate Map).
//  Vorbild: Compositor-Pass von Vice City (vc_quad_vertex).
//

#include <metal_stdlib>
using namespace metal;

struct C64TestUniforms {
    float4x4 viewProjection[2];   // pro View: Projektion * inverse(deviceAnchor * view.transform)
    float4   center;              // Mittelpunkt des Quads in Weltkoordinaten (m)
    float4   right;               // Rechtsvektor * halbe Breite (m)
    float4   up;                  // Hochvektor * halbe Höhe (m)
};

struct C64TestInOut {
    float4 position [[position]];
    float2 uv;
};

// Sechs Vertices, zwei Dreiecke, Ecken aus der Vertex-ID; kein Vertex-Puffer nötig.
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

// Schachbrett 64 × 64 Felder, dazu ein dünnes rotes Fadenkreuz in der Mitte als Fixpunkt.
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

// M4a.2: Leinwand. Dasselbe Quad wie die Testszene, der Fragment-Shader tastet die Leinwand ab.
// Die Textur kommt als sRGB-Ansicht (linear nach dem Abtasten), das Drawable kodiert beim
// Schreiben zurück. uv (0,0) liegt an der Ecke unten links des Quads, Texturzeile 0 ist oben,
// deshalb v gespiegelt: die Markierung oben links der Textur erscheint oben links in der Welt.
fragment float4 c64_canvas_fragment(C64TestInOut in [[stage_in]],
                                    texture2d<float> canvas [[texture(0)]],
                                    sampler canvasSampler [[sampler(0)]])
{
    float3 color = canvas.sample(canvasSampler, float2(in.uv.x, 1.0 - in.uv.y)).rgb;
    return float4(color, 1.0);
}
