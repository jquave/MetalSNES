#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

constant float2 positions[4] = {
    float2(-1, -1),
    float2( 1, -1),
    float2(-1,  1),
    float2( 1,  1)
};

constant float2 texCoords[4] = {
    float2(0, 1),
    float2(1, 1),
    float2(0, 0),
    float2(1, 0)
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler nearestSampler(mag_filter::nearest, min_filter::nearest);
    return tex.sample(nearestSampler, in.texCoord);
}
