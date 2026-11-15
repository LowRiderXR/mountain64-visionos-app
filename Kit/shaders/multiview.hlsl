// multiview.hlsl — kit test scene multiview: a quad with a checkerboard, both eyes in one draw.
// The view index arrives as SV_ViewID (Shader Model 6.1) and indexes the matrix array in the
// uniform; colour and depth per view for the Mac self-test.
//
// Toolchain (tools/compile-kit-shaders.sh): DXC -T vs_6_1 / ps_6_1 -spirv -> SPIRV-Cross
// (shadercross) -> MSL; the vertex shader is rewritten by msl-amplification.sh from
// `const uint gl_ViewIndex = 0;` to `[[amplification_id]]`.
//
// Bindings per SDL_GPU: vertex uniforms in space1 from b0 (Metal: [[buffer(0)]]), fragment
// uniforms in space3 (none here), textures in space2 (none here).

cbuffer MultiviewUniforms : register(b0, space1)
{
    float4x4 u_viewProjection[2];   // per view: projection * inverse(deviceAnchor * view.transform)
    float4   u_center;              // centre of the quad (m)
    float4   u_right;               // right vector * half width (m)
    float4   u_up;                  // up vector * half height (m)
    float4   u_viewColor[2];        // colour factor per view (device: white; self-test: red, blue)
    float4   u_params;              // x: 1 = checkerboard with crosshair, 0 = flat colour,
                                    //    2 = measurement image: logical position in R,G, interpolated
                                    //    from the vertex shader; y,z = logical size (screenSize).
                                    //    SV_Position is physical under a rate map (measured
                                    //    2026-10-17), so it is not usable as a measure.
    float4   u_barCenter;           // second quad from geometry (vertices 6..11), a narrow,
    float4   u_barRight;            //      tilted bar in flat colour, so that MSAA becomes
    float4   u_barUp;               //      visible at triangle edges.
};

struct VertexOutput
{
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
    float  pattern  : TEXCOORD1;
    float2 logical  : TEXCOORD2;    // logical screen coordinate (origin top left)
    float4 position : SV_Position;
};

// Six vertices per quad, two triangles, corners from the vertex ID; no vertex buffer needed.
// Quad 0 (vertices 0..5): board from u_center/u_right/u_up with pattern; quad 1 (6..11): bar
// from u_barCenter/u_barRight/u_barUp in flat colour (only when 12 vertices are drawn).
VertexOutput vertex_main(uint vertexID : SV_VertexID, uint viewID : SV_ViewID)
{
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1)
    };
    const bool bar = vertexID >= 6;
    float2 uv = corners[vertexID % 6];
    float3 qCenter = bar ? u_barCenter.xyz : u_center.xyz;
    float3 qRight = bar ? u_barRight.xyz : u_right.xyz;
    float3 qUp = bar ? u_barUp.xyz : u_up.xyz;
    float3 world = qCenter
                 + (uv.x * 2.0 - 1.0) * qRight
                 + (uv.y * 2.0 - 1.0) * qUp;

    VertexOutput output;
    output.position = mul(u_viewProjection[viewID], float4(world, 1.0));
    output.uv = uv;
    output.color = bar ? float4(1.0, 0.55, 0.1, 1.0) : u_viewColor[viewID];
    output.pattern = bar ? 0.0 : u_params.x;
    // full-screen quad: uv (0,0) bottom left in NDC -> logical x = uv.x·W, y = (1 − uv.y)·H.
    output.logical = float2(uv.x * u_params.y, (1.0 - uv.y) * u_params.z);
    return output;
}

// Checkerboard of 64 × 64 fields with a thin red crosshair (pattern 1), flat colour (0) or
// measurement image (2): the interpolated logical screen coordinate as R,G into a float target;
// the comparison with mapPhysicalToScreenCoordinates of the map measures the rasterizer's
// deviation in physical pixels. (SV_Position would be the physical fragment position here.)
float4 fragment_main(VertexOutput input) : SV_Target0
{
    float3 color = input.color.rgb;
    if (input.pattern > 1.5)
    {
        return float4(input.logical.x, input.logical.y, 0.0, 1.0);
    }
    if (input.pattern > 0.5)
    {
        const float fields = 64.0;
        int2 cell = int2(floor(input.uv * fields));
        bool light = ((cell.x + cell.y) & 1) == 0;
        float3 board = light ? float3(0.9, 0.9, 0.9) : float3(0.08, 0.08, 0.08);
        float2 d = abs(input.uv - 0.5);
        if (d.x < 0.003 || d.y < 0.003)
        {
            board = float3(0.9, 0.1, 0.1);
        }
        color *= board;
    }
    return float4(color, input.color.a);
}
