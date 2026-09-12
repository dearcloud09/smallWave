#include <metal_stdlib>
using namespace metal;

struct LiveFieldVolumeOut {
    float4 position [[position]];
    float3 local;
    uint layer [[render_target_array_index]];
};

constant uint liveFieldWidth = 256;
constant uint liveFieldHeight = 544;
constant uint liveFieldDepth = 48;

float2 liveFieldCorner(uint vertexID) {
    constexpr float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                                    float2(-1,1), float2(1,-1), float2(1,1) };
    return corners[vertexID];
}

vertex LiveFieldVolumeOut liveFieldVolumeVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                                  const device float4 *particles [[buffer(0)]]) {
    uint layer = instance % liveFieldDepth;
    float4 particle = particles[instance / liveFieldDepth];
    float2 local = liveFieldCorner(vertexID);
    LiveFieldVolumeOut out;
    out.position = float4((particle.xy + local * particle.w) / float2(1.0, 2.12), 0, 1);
    float z = 0.18 - (float(layer) + 0.5) * (0.36 / float(liveFieldDepth));
    out.local = float3(local, (z - particle.z) / particle.w);
    out.layer = layer;
    return out;
}

fragment float liveFieldVolumeFragment(LiveFieldVolumeOut in [[stage_in]]) {
    float falloff = max(0.0, 1.0 - dot(in.local, in.local));
    return falloff * falloff * falloff;
}

inline uint liveFieldClamp(int value, uint limit) { return uint(clamp(value, 0, int(limit) - 1)); }

kernel void liveFieldWall(texture2d_array<float, access::read> source [[texture(0)]],
                          texture2d_array<float, access::write> target [[texture(1)]],
                          uint3 id [[thread_position_in_grid]]) {
    if (id.x >= liveFieldWidth || id.y >= liveFieldHeight || id.z >= liveFieldDepth) return;
    float z = 0.18 - (float(id.z) + 0.5) * (0.36 / float(liveFieldDepth));
    float coating = 0.6 + 4.0 * ((0.18 - 0.009) - abs(z));
    target.write(float4(min(source.read(id.xy, id.z).r, coating)), id.xy, id.z);
}

kernel void liveFieldFilterX(texture2d_array<float, access::read> source [[texture(0)]],
                             texture2d_array<float, access::write> target [[texture(1)]],
                             uint3 id [[thread_position_in_grid]]) {
    if (id.x >= liveFieldWidth || id.y >= liveFieldHeight || id.z >= liveFieldDepth) return;
    float a = source.read(uint2(liveFieldClamp(int(id.x)-1, liveFieldWidth), id.y), id.z).r;
    float b = source.read(id.xy, id.z).r;
    float c = source.read(uint2(liveFieldClamp(int(id.x)+1, liveFieldWidth), id.y), id.z).r;
    target.write(float4((a + 4.0*b + c) / 6.0), id.xy, id.z);
}

kernel void liveFieldFilterY(texture2d_array<float, access::read> source [[texture(0)]],
                             texture2d_array<float, access::write> target [[texture(1)]],
                             uint3 id [[thread_position_in_grid]]) {
    if (id.x >= liveFieldWidth || id.y >= liveFieldHeight || id.z >= liveFieldDepth) return;
    float a = source.read(uint2(id.x, liveFieldClamp(int(id.y)-1, liveFieldHeight)), id.z).r;
    float b = source.read(id.xy, id.z).r;
    float c = source.read(uint2(id.x, liveFieldClamp(int(id.y)+1, liveFieldHeight)), id.z).r;
    target.write(float4((a + 4.0*b + c) / 6.0), id.xy, id.z);
}

kernel void liveFieldFilterZ(texture2d_array<float, access::read> source [[texture(0)]],
                             texture2d_array<float, access::write> target [[texture(1)]],
                             uint3 id [[thread_position_in_grid]]) {
    if (id.x >= liveFieldWidth || id.y >= liveFieldHeight || id.z >= liveFieldDepth) return;
    float a = source.read(id.xy, liveFieldClamp(int(id.z)-1, liveFieldDepth)).r;
    float b = source.read(id.xy, id.z).r;
    float c = source.read(id.xy, liveFieldClamp(int(id.z)+1, liveFieldDepth)).r;
    target.write(float4((a + 4.0*b + c) / 6.0), id.xy, id.z);
}

kernel void liveFieldCarve(texture2d_array<float, access::read> source [[texture(0)]],
                           texture3d<float, access::write> target [[texture(1)]],
                           const device float4 *bubbles [[buffer(0)]],
                           constant uint &bubbleCount [[buffer(1)]],
                           uint3 id [[thread_position_in_grid]]) {
    if (id.x >= liveFieldWidth || id.y >= liveFieldHeight || id.z >= liveFieldDepth) return;
    float3 p = float3(-1.0 + (float(id.x)+0.5) * (2.0/float(liveFieldWidth)),
                      2.12 - (float(id.y)+0.5) * (4.24/float(liveFieldHeight)),
                      0.18 - (float(id.z)+0.5) * (0.36/float(liveFieldDepth)));
    float density = source.read(id.xy, id.z).r;
    for (uint i = 0; i < bubbleCount; ++i) {
        float4 bubble = bubbles[i];
        float3 delta = p - bubble.xyz;
        // `0.6 + 4 * (distance - radius)` can lower the current field outside
        // the sphere. It matters exactly while distance < radius+(density-.6)/4.
        // L-infinity distance is a cheap conservative lower bound on distance.
        float influence = max(0.0, bubble.w + (density - 0.6) * 0.25);
        if (max(abs(delta.x), max(abs(delta.y), abs(delta.z))) >= influence) continue;
        density = min(density, 0.6 + 4.0 * (length(delta) - bubble.w));
    }
    target.write(float4(density), id);
}

kernel void liveFieldBounds(texture3d<float, access::read> source [[texture(0)]],
                            texture3d<float, access::write> target [[texture(1)]],
                            uint3 id [[thread_position_in_grid]]) {
    if (id.x >= 64 || id.y >= 136 || id.z >= 12) return;
    float lo = INFINITY, hi = -INFINITY;
    uint3 base = id * 4;
    for (uint z = 0; z < 5; ++z) for (uint y = 0; y < 5; ++y) for (uint x = 0; x < 5; ++x) {
        uint3 sample = min(base + uint3(x,y,z), uint3(liveFieldWidth-1, liveFieldHeight-1, liveFieldDepth-1));
        float value = source.read(sample).r;
        lo = min(lo, value); hi = max(hi, value);
    }
    target.write(float4(lo, hi, 0, 0), id);
}
