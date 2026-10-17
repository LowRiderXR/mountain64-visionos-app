// multiview.hlsl — Kit-Testszene K2 (Baustein P6): ein Quad mit Schachbrett, beide Augen in
// einem Draw. Der View-Index kommt als SV_ViewID (Shader Model 6.1) und indiziert das
// Matrizen-Array im Uniform; Farbe und Tiefe pro View für den Mac-Selbsttest.
//
// Werkzeugkette (tools/compile-kit-shaders.sh): DXC -T vs_6_1 / ps_6_1 -spirv → SPIRV-Cross
// (shadercross) → MSL; der Vertex-Shader wird mit msl-amplification.sh von
// `const uint gl_ViewIndex = 0;` auf `[[amplification_id]]` umgebogen.
//
// Bindungen nach SDL_GPU: Vertex-Uniforms in space1 ab b0 (Metal: [[buffer(0)]]),
// Fragment-Uniforms in space3 (hier keine), Texturen in space2 (hier keine).

cbuffer MultiviewUniforms : register(b0, space1)
{
    float4x4 u_viewProjection[2];   // pro View: Projektion * inverse(deviceAnchor * view.transform)
    float4   u_center;              // Mittelpunkt des Quads (m)
    float4   u_right;               // Rechtsvektor * halbe Breite (m)
    float4   u_up;                  // Hochvektor * halbe Höhe (m)
    float4   u_viewColor[2];        // Farbfaktor pro View (Gerät: weiss; Selbsttest: rot, blau)
    float4   u_params;              // x: 1 = Schachbrett mit Fadenkreuz, 0 = flache Farbe,
                                    //    2 = Messbild (K3): logische Position in R,G, interpoliert
                                    //    aus dem Vertex-Shader; y,z = logische Grösse (screenSize).
                                    //    SV_Position ist unter einer Rate Map physisch (Messung
                                    //    2026-10-17), deshalb nicht als Mass brauchbar.
};

struct VertexOutput
{
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
    float  pattern  : TEXCOORD1;
    float2 logical  : TEXCOORD2;    // logische Bildschirmkoordinate (Ursprung oben links)
    float4 position : SV_Position;
};

// Sechs Vertices, zwei Dreiecke, Ecken aus der Vertex-ID; kein Vertex-Puffer nötig.
VertexOutput vertex_main(uint vertexID : SV_VertexID, uint viewID : SV_ViewID)
{
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1)
    };
    float2 uv = corners[vertexID];
    float3 world = u_center.xyz
                 + (uv.x * 2.0 - 1.0) * u_right.xyz
                 + (uv.y * 2.0 - 1.0) * u_up.xyz;

    VertexOutput output;
    output.position = mul(u_viewProjection[viewID], float4(world, 1.0));
    output.uv = uv;
    output.color = u_viewColor[viewID];
    output.pattern = u_params.x;
    // Vollbild-Quad: uv (0,0) unten links in NDC → logisch x = uv.x·W, y = (1 − uv.y)·H.
    output.logical = float2(uv.x * u_params.y, (1.0 - uv.y) * u_params.z);
    return output;
}

// Schachbrett 64 × 64 Felder mit dünnem rotem Fadenkreuz (pattern 1), flache Farbe (0) oder
// Messbild (2): die interpolierte logische Bildschirmkoordinate als R,G in ein Float-Ziel; der
// Vergleich mit mapPhysicalToScreenCoordinates der Map misst die Abweichung des Rasterizers in
// physischen Pixeln. (SV_Position wäre hier die physische Fragmentposition.)
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
