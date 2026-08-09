// DMD 5620 framebuffer expansion: the texture is the terminal's packed
// 1-bit VRAM (width/8 bytes x height rows, MSB-first), expanded per-pixel
// in the fragment shader with a phosphor tint. Row 0 is the top of the
// screen; 1 = lit phosphor.
//
// The screen is resizable at runtime, so the size arrives as a uniform
// rather than being baked in here. It must be the size of the frame that
// filled the texture, not whatever the terminal is now: a mismatch of one
// byte of stride skews every row.
#include <metal_stdlib>
using namespace metal;

struct FBVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FBVertexOut fb_vertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle-strip quad.
    const float2 pos[4] = { {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0}, {1.0, 1.0} };
    const float2 uv[4]  = { {0.0, 1.0},  {1.0, 1.0},  {0.0, 0.0},  {1.0, 0.0} };
    FBVertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = uv[vid];
    return out;
}

fragment float4 fb_fragment(FBVertexOut in [[stage_in]],
                            texture2d<uint, access::read> fb [[texture(0)]],
                            constant float3 &phosphor [[buffer(0)]],
                            constant uint2 &screen [[buffer(1)]]) {
    uint x = min(uint(in.uv.x * float(screen.x)), screen.x - 1u);
    uint y = min(uint(in.uv.y * float(screen.y)), screen.y - 1u);
    uint byte = fb.read(uint2(x >> 3, y)).r;
    uint bit = (byte >> (7u - (x & 7u))) & 1u;
    float3 rgb = phosphor * float(bit);
    return float4(rgb, 1.0);
}
