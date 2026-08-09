// DMD 5620 framebuffer expansion: the texture is the terminal's packed
// 1-bit VRAM (width/8 bytes x height rows, MSB-first), expanded per-pixel
// in the fragment shader with a phosphor tint. Row 0 is the top of the
// screen; 1 = lit phosphor.
//
// The screen is one of two fixed sizes, so its dimensions arrive as a
// uniform rather than being baked in here. It must be the size of the frame
// that filled the texture, not whatever the terminal is now: a mismatch of
// one byte of stride skews every row.
#include <metal_stdlib>
using namespace metal;

struct FBVertexOut {
    float4 position [[position]];
    float2 uv;
};

/// `texels` is how many 5620 pixels one *device* pixel covers — the whole
/// Retina story in two floats. On a 2x panel showing an 800-wide screen in
/// 642 points, one device pixel is 800 / 1284 = 0.62 of a 5620 pixel, so
/// there is real detail to render into and the filter below has something
/// to do. Computed from the drawable, never from the layout size.
struct FBUniforms {
    uint2 screen;
    float2 texels;
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
                            constant FBUniforms &u [[buffer(1)]]) {
    // Area-average this device pixel's footprint over the 5620 raster.
    //
    // Point sampling — read the one texel under the fragment centre — is what
    // this used to do, and at any non-integral scale it is wrong in a way you
    // can see: some source rows land in two device pixels and their
    // neighbours in one, so a stipple pattern beats against the sampling grid
    // and mux's grey background crawls. Integer ("Crisp") scaling exists to
    // dodge exactly that, at the cost of a smaller picture.
    //
    // Averaging over the real footprint removes the beat instead of avoiding
    // it, and costs nothing where it does not apply: when the screen is
    // magnified, the box is smaller than a source pixel and only fragments
    // that straddle an edge blend at all — everything else still resolves to
    // a hard 0 or 1. At an exact integer scale no fragment straddles anything
    // and the result is bit-identical to point sampling. So "Crisp" stays
    // honest and "Fill" stops shimmering.
    float2 centre = in.uv * float2(u.screen);
    float2 half_footprint = 0.5 * max(u.texels, float2(1.0e-4));
    float2 lo = centre - half_footprint;
    float2 hi = centre + half_footprint;

    int maxX = int(u.screen.x) - 1;
    int maxY = int(u.screen.y) - 1;
    int x0 = clamp(int(floor(lo.x)), 0, maxX);
    int y0 = clamp(int(floor(lo.y)), 0, maxY);
    // The epsilon keeps a footprint that ends exactly on a boundary from
    // pulling in the next pixel. The +7 cap bounds the loop: minifying past
    // 8:1 is not a thing this app can reach, and an unbounded loop here would
    // be a cliff rather than a graceful blur.
    int x1 = clamp(int(floor(hi.x - 1.0e-6)), x0, min(x0 + 7, maxX));
    int y1 = clamp(int(floor(hi.y - 1.0e-6)), y0, min(y0 + 7, maxY));

    float lit = 0.0;
    float total = 0.0;
    for (int y = y0; y <= y1; ++y) {
        float wy = min(float(y + 1), hi.y) - max(float(y), lo.y);
        for (int x = x0; x <= x1; ++x) {
            float wx = min(float(x + 1), hi.x) - max(float(x), lo.x);
            uint byte = fb.read(uint2(uint(x) >> 3, uint(y))).r;
            float bit = float((byte >> (7u - (uint(x) & 7u))) & 1u);
            float w = wx * wy;
            lit += bit * w;
            total += w;
        }
    }
    float coverage = total > 0.0 ? lit / total : 0.0;
    return float4(phosphor * coverage, 1.0);
}
