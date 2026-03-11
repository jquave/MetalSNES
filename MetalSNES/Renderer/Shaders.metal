#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct GPULineState {
    uint4 control;
    uint4 bgSC;
    uint4 bgHScroll;
    uint4 bgVScroll;
    uint4 extras;
    uint4 colorMath;
    uint4 windows;
    uint4 windowRanges;
    uint4 windowControl;
    uint4 mode7ABCD;
    uint4 mode7XY;
};

struct DisplayUniforms {
    float2 viewportSize;
    float2 textureSize;
    float2 contentOrigin;
    float2 contentSize;
    uint filterMode;
    uint integerScalingEnabled;
    float scanlineStrength;
    float maskStrength;
    float bloomStrength;
    float curvature;
    float vignetteStrength;
    float sharpness;
    float brightness;
    float contrast;
    float saturation;
    float userSharpness;
    float glowAmount;
};

struct PixelSample {
    uint color;
    uint z;
    uint layer;
};

struct IndexedSample {
    uint colorIndex;
    uint z;
    uint layer;
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

inline float gaussian1D(float distance, float sigma) {
    float safeSigma = max(sigma, 0.001);
    return exp(-0.5 * (distance * distance) / (safeSigma * safeSigma));
}

inline float3 applyDisplayGrade(float3 color,
                                float brightness,
                                float contrast,
                                float saturation) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, saturation);
    color = ((color - 0.5) * contrast) + 0.5;
    color *= brightness;
    return max(color, 0.0);
}

inline float3 sampleNearestRGB(texture2d<float> tex,
                               sampler texSampler,
                               float2 textureSize,
                               float2 texelCoord) {
    if (texelCoord.x < 0.5 || texelCoord.y < 0.5 ||
        texelCoord.x > textureSize.x - 0.5 || texelCoord.y > textureSize.y - 0.5) {
        return float3(0.0);
    }
    return tex.sample(texSampler, texelCoord / textureSize).rgb;
}

inline float3 apertureGrilleMask(float screenX,
                                 float strength,
                                 float pitch,
                                 float softness,
                                 float lift) {
    float phase = fract(screenX / max(pitch, 1.0)) * 3.0;
    float3 lobes = float3(
        exp(-softness * pow(phase - 0.35, 2.0)),
        exp(-softness * pow(phase - 1.50, 2.0)),
        exp(-softness * pow(phase - 2.65, 2.0))
    );
    lobes = clamp(lobes + lift, 0.0, 1.0);
    return mix(float3(1.0 - strength), float3(1.0), lobes);
}

inline float trinitronCellShape(float localTexelX,
                                float localTexelY,
                                float centerX,
                                float width,
                                float height,
                                float exponent) {
    float phaseX = fract(localTexelX) * 3.0;
    float phaseY = fract(localTexelY);
    float dx = abs(phaseX - centerX) / max(width, 0.001);
    float dy = abs(phaseY - 0.5) / max(height, 0.001);
    float shape = pow(dx, exponent) + pow(dy, exponent);
    return clamp(1.0 - shape, 0.0, 1.0);
}

inline float3 trinitronCellMask(float localTexelX,
                                float localTexelY,
                                float strength) {
    float3 cells = float3(
        trinitronCellShape(localTexelX, localTexelY, 0.44, 0.34, 0.92, 4.0),
        trinitronCellShape(localTexelX, localTexelY, 1.50, 0.34, 0.92, 4.0),
        trinitronCellShape(localTexelX, localTexelY, 2.56, 0.34, 0.92, 4.0)
    );
    float3 glow = float3(
        trinitronCellShape(localTexelX, localTexelY, 0.44, 0.68, 1.20, 2.0),
        trinitronCellShape(localTexelX, localTexelY, 1.50, 0.68, 1.20, 2.0),
        trinitronCellShape(localTexelX, localTexelY, 2.56, 0.68, 1.20, 2.0)
    );
    cells = clamp(cells + glow * 0.34, 0.0, 1.0);
    return mix(float3(1.0 - strength * 0.52), float3(1.0), cells);
}

inline float trinitronScanlineMask(float localTexelY, float strength) {
    float phase = fract(localTexelY);
    float beam = exp(-16.0 * pow(phase - 0.5, 2.0));
    return mix(1.0 - strength * 0.55, 1.0, beam);
}

inline float3 samplePhosphorBloom(texture2d<float> tex,
                                  sampler texSampler,
                                  float2 sampleUV,
                                  float2 textureSize,
                                  float sigmaX,
                                  float sigmaY,
                                  float beamMix,
                                  float haloThreshold,
                                  float haloScale,
                                  float sparkScale,
                                  float highlightThreshold,
                                  bool wideSupport) {
    float2 texelSpace = sampleUV * textureSize;
    float2 center = floor(texelSpace) + 0.5;
    int minY = wideSupport ? -2 : -1;
    int maxY = wideSupport ? 2 : 1;
    int minX = wideSupport ? -3 : -2;
    int maxX = wideSupport ? 3 : 2;

    float3 accum = float3(0.0);
    float total = 0.0;
    for (int y = minY; y <= maxY; ++y) {
        for (int x = minX; x <= maxX; ++x) {
            float2 sampleCoord = center + float2(float(x), float(y));
            float2 delta = texelSpace - sampleCoord;
            float weight = gaussian1D(delta.x, sigmaX) * gaussian1D(delta.y, sigmaY);
            accum += sampleNearestRGB(tex, texSampler, textureSize, sampleCoord) * weight;
            total += weight;
        }
    }

    float3 direct = sampleNearestRGB(tex, texSampler, textureSize, center);
    float3 beam = accum / max(total, 0.0001);
    float3 lateral = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(-1.0, 0.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(1.0, 0.0))
    ) * 0.5;
    float3 farLateral = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(-2.0, 0.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(2.0, 0.0))
    ) * 0.5;
    float3 vertical = (
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(0.0, -1.0)) +
        sampleNearestRGB(tex, texSampler, textureSize, center + float2(0.0, 1.0))
    ) * 0.5;
    float highlight = smoothstep(highlightThreshold, 1.0, max(max(direct.r, direct.g), direct.b));
    float3 halo = max(beam - haloThreshold, 0.0) * haloScale * mix(0.65, 1.35, highlight);
    float3 spark = max(lateral - max(haloThreshold - 0.05, 0.02), 0.0) * sparkScale * mix(0.45, 1.15, highlight);
    float3 spill = float3(0.0);
    if (wideSupport) {
        float3 outerRing = farLateral * 0.72 + vertical * 0.42;
        spill = max(outerRing - max(haloThreshold - 0.08, 0.01), 0.0) * (sparkScale * 1.15) * mix(0.45, 1.30, highlight);
        halo *= 1.14;
    }
    return mix(direct, beam, beamMix) + halo + spark + spill;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               constant DisplayUniforms &uniforms [[buffer(0)]],
                               texture2d<float> tex [[texture(0)]]) {
    constexpr sampler nearestSampler(address::clamp_to_zero, mag_filter::nearest, min_filter::nearest);
    constexpr sampler linearSampler(address::clamp_to_zero, mag_filter::linear, min_filter::linear);

    float2 screenPos = in.position.xy;
    float2 rectMin = uniforms.contentOrigin;
    float2 rectMax = uniforms.contentOrigin + uniforms.contentSize;
    if (screenPos.x < rectMin.x || screenPos.y < rectMin.y ||
        screenPos.x >= rectMax.x || screenPos.y >= rectMax.y) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float2 localUV = (screenPos - rectMin) / uniforms.contentSize;
    float2 sampleUV = localUV;
    if (uniforms.filterMode == 2u) {
        float2 centered = localUV * 2.0 - 1.0;
        float radius = dot(centered, centered);
        centered *= 1.0 + uniforms.curvature * radius;
        sampleUV = centered * 0.5 + 0.5;
        if (sampleUV.x < 0.0 || sampleUV.y < 0.0 || sampleUV.x > 1.0 || sampleUV.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float2 texelSize = 1.0 / uniforms.textureSize;
    float2 texelCoord = sampleUV * uniforms.textureSize;
    float2 nearestUV = (floor(texelCoord) + 0.5) * texelSize;
    float4 color = tex.sample(nearestSampler, nearestUV);
    float displayBrightness = clamp(uniforms.brightness, 0.4, 2.2);
    float displayContrast = clamp(uniforms.contrast, 0.4, 2.0);
    float displaySaturation = clamp(uniforms.saturation, 0.0, 2.0);
    float filterSharpness = max(uniforms.sharpness * uniforms.userSharpness, 0.05);

    if (uniforms.filterMode == 0u) {
        color.rgb = applyDisplayGrade(color.rgb, displayBrightness, displayContrast, displaySaturation);
        return float4(min(color.rgb, 1.0), color.a);
    }

    if (uniforms.filterMode == 3u || uniforms.filterMode == 4u) {
        bool hotPhosphor = uniforms.filterMode == 4u;
        float focus = clamp(filterSharpness, 0.0, 1.0);
        float glowBoost = max(displayBrightness - 1.0, 0.0);
        float trinitronGlow = clamp(uniforms.glowAmount, 0.25, 2.0);
        float sigmaX = hotPhosphor
            ? mix(1.92, 1.28, focus) + glowBoost * 0.30 + (trinitronGlow - 1.0) * 0.38
            : mix(1.05, 0.62, focus);
        float sigmaY = hotPhosphor
            ? mix(1.14, 0.72, focus) + glowBoost * 0.18 + (trinitronGlow - 1.0) * 0.20
            : mix(0.78, 0.46, focus);
        float3 phosphor = samplePhosphorBloom(
            tex,
            nearestSampler,
            sampleUV,
            uniforms.textureSize,
            sigmaX,
            sigmaY,
            hotPhosphor ? min(0.95, 0.82 + glowBoost * 0.05 + (trinitronGlow - 1.0) * 0.08) : min(0.88, 0.78 + glowBoost * 0.04),
            hotPhosphor ? 0.08 : 0.18,
            hotPhosphor
                ? (0.40 + uniforms.bloomStrength * 0.52) * (1.0 + glowBoost * 1.05) * mix(0.70, 1.55, clamp(trinitronGlow * 0.5, 0.0, 1.0))
                : (0.30 + uniforms.bloomStrength * 0.45) * (1.0 + glowBoost * 0.75),
            hotPhosphor
                ? uniforms.bloomStrength * 0.30 * (1.0 + glowBoost * 1.10) * mix(0.72, 1.70, clamp(trinitronGlow * 0.5, 0.0, 1.0))
                : uniforms.bloomStrength * 0.22 * (1.0 + glowBoost * 0.80),
            hotPhosphor ? 0.34 : 0.55,
            hotPhosphor
        );
        if (hotPhosphor) {
            float texelScaleX = max(uniforms.contentSize.x / uniforms.textureSize.x, 1.0);
            float texelScaleY = max(uniforms.contentSize.y / uniforms.textureSize.y, 1.0);
            float localTexelX = (screenPos.x - rectMin.x) / texelScaleX;
            float localTexelY = (screenPos.y - rectMin.y) / texelScaleY;
            float3 cellMask = trinitronCellMask(localTexelX, localTexelY, uniforms.maskStrength);
            float lineMask = trinitronScanlineMask(localTexelY, uniforms.scanlineStrength);
            float beamLuma = dot(phosphor, float3(0.2126, 0.7152, 0.0722));
            float highlightGlow = smoothstep(0.40, 1.0, beamLuma);
            float grayPedestal = (0.022 + beamLuma * 0.078) * (1.0 + glowBoost * 0.42 + (trinitronGlow - 1.0) * 0.18);

            phosphor *= mix(float3(1.0), cellMask, 0.58);
            phosphor *= mix(1.0, lineMask, 0.60);
            phosphor += (float3(grayPedestal) * (float3(0.60) + cellMask * 0.50)) * lineMask;
            phosphor += float3(highlightGlow * beamLuma * (0.14 + glowBoost * 0.08 + (trinitronGlow - 1.0) * 0.12));
            phosphor += max(phosphor - 0.12, 0.0) * (0.18 + glowBoost * 0.12 + (trinitronGlow - 1.0) * 0.18);
            phosphor = pow(max(phosphor, 0.0), float3(0.88));
        } else {
            float3 mask = apertureGrilleMask(
                screenPos.x - rectMin.x,
                uniforms.maskStrength,
                3.0,
                5.0,
                0.16
            );
            phosphor *= mask;
            phosphor = pow(max(phosphor, 0.0), float3(0.95));
        }
        phosphor = applyDisplayGrade(phosphor, displayBrightness, displayContrast, displaySaturation);
        return float4(min(phosphor, 1.0), 1.0);
    }

    if (uniforms.bloomStrength > 0.0) {
        float4 bloom = tex.sample(linearSampler, sampleUV + float2(texelSize.x, 0.0));
        bloom += tex.sample(linearSampler, sampleUV - float2(texelSize.x, 0.0));
        bloom += tex.sample(linearSampler, sampleUV + float2(0.0, texelSize.y));
        bloom += tex.sample(linearSampler, sampleUV - float2(0.0, texelSize.y));
        bloom *= 0.25;
        color.rgb = mix(color.rgb, max(color.rgb, bloom.rgb), uniforms.bloomStrength);
    }

    float scaleY = max(uniforms.contentSize.y / uniforms.textureSize.y, 1.0);
    float scanPhase = fract((screenPos.y - rectMin.y) / scaleY);
    float beam = 1.0 - uniforms.scanlineStrength * pow(abs(scanPhase - 0.5) * 2.0, max(filterSharpness, 1.0));
    color.rgb *= beam;

    if (uniforms.maskStrength > 0.0) {
        uint triad = uint(floor(screenPos.x)) % 3u;
        float dim = 1.0 - uniforms.maskStrength;
        float3 mask = float3(dim, dim, dim);
        if (triad == 0u) {
            mask.r = 1.0;
        } else if (triad == 1u) {
            mask.g = 1.0;
        } else {
            mask.b = 1.0;
        }
        color.rgb *= mask;
    }

    if (uniforms.vignetteStrength > 0.0) {
        float2 vignetteUV = sampleUV * (1.0 - sampleUV.yx);
        float vignette = clamp(pow(16.0 * vignetteUV.x * vignetteUV.y, 0.25), 0.0, 1.0);
        color.rgb *= mix(1.0, vignette, uniforms.vignetteStrength);
    }

    color.rgb = applyDisplayGrade(color.rgb, displayBrightness, displayContrast, displaySaturation);
    return float4(min(color.rgb, 1.0), 1.0);
}

inline uchar readVRAM(const device uchar *vram, uint addr) {
    return vram[addr & 0xFFFFu];
}

inline uchar readOAM(const device uchar *oam, uint addr) {
    return oam[addr % 0x220u];
}

inline uint readVRAMWord(const device uchar *vram, uint addr) {
    return uint(readVRAM(vram, addr)) | (uint(readVRAM(vram, addr + 1u)) << 8);
}

inline float4 unpackColor(uint color) {
    return float4(
        float(color & 0xFFu) / 255.0,
        float((color >> 8) & 0xFFu) / 255.0,
        float((color >> 16) & 0xFFu) / 255.0,
        float((color >> 24) & 0xFFu) / 255.0
    );
}

inline uint repackColor(uint r, uint g, uint b) {
    return (r & 0xFFu) | ((g & 0xFFu) << 8) | ((b & 0xFFu) << 16) | 0xFF000000u;
}

inline uint colorMathLayerBit(uint layer) {
    switch (layer) {
        case 0u: return 0x20u;
        case 1u: return 0x01u;
        case 2u: return 0x02u;
        case 3u: return 0x04u;
        case 4u: return 0x08u;
        case 6u: return 0x10u;
        default: return 0u;
    }
}

inline uint applyColorMathToColor(uint mainColor, uint subColor, bool subtract, bool halfColor) {
    int mainR = int(mainColor & 0xFFu);
    int mainG = int((mainColor >> 8) & 0xFFu);
    int mainB = int((mainColor >> 16) & 0xFFu);
    int subR = int(subColor & 0xFFu);
    int subG = int((subColor >> 8) & 0xFFu);
    int subB = int((subColor >> 16) & 0xFFu);

    int r = subtract ? (mainR - subR) : (mainR + subR);
    int g = subtract ? (mainG - subG) : (mainG + subG);
    int b = subtract ? (mainB - subB) : (mainB + subB);

    if (halfColor) {
        r >>= 1;
        g >>= 1;
        b >>= 1;
    }

    return repackColor(
        uint(clamp(r, 0, 255)),
        uint(clamp(g, 0, 255)),
        uint(clamp(b, 0, 255))
    );
}

inline bool evaluateWindow(uint raw,
                           uint wLog,
                           uint screenX,
                           uint wh0,
                           uint wh1,
                           uint wh2,
                           uint wh3) {
    bool w1enabled = (raw & 0x02u) != 0u;
    bool w1invert = (raw & 0x01u) != 0u;
    bool w1inside = false;
    if (w1enabled) {
        w1inside = screenX >= wh0 && screenX <= wh1;
        if (w1invert) { w1inside = !w1inside; }
    }

    bool w2enabled = (raw & 0x08u) != 0u;
    bool w2invert = (raw & 0x04u) != 0u;
    bool w2inside = false;
    if (w2enabled) {
        w2inside = screenX >= wh2 && screenX <= wh3;
        if (w2invert) { w2inside = !w2inside; }
    }

    if (w1enabled && w2enabled) {
        switch (wLog) {
            case 0u: return w1inside || w2inside;
            case 1u: return w1inside && w2inside;
            case 2u: return w1inside != w2inside;
            case 3u: return w1inside == w2inside;
            default: return false;
        }
    } else if (w1enabled) {
        return w1inside;
    } else if (w2enabled) {
        return w2inside;
    }
    return false;
}

inline bool colorWindowInside(const thread GPULineState &line, uint screenX) {
    uint raw = (line.windows.z >> 4u) & 0x0Fu;
    uint wLog = (line.windowRanges.x >> 2u) & 0x03u;
    return evaluateWindow(raw,
                          wLog,
                          screenX,
                          line.windowRanges.y,
                          line.windowRanges.z,
                          line.windowRanges.w,
                          line.windowControl.x);
}

inline bool colorWindowAllows(uint mask, const thread GPULineState &line, uint screenX) {
    switch (mask) {
        case 0u: return true;
        case 1u: return colorWindowInside(line, screenX);
        case 2u: return !colorWindowInside(line, screenX);
        case 3u: return false;
        default: return false;
    }
}

inline bool isWindowMaskedForLayer(uint layer,
                                   const thread GPULineState &line,
                                   uint screenX,
                                   bool subScreen) {
    uint raw;
    uint wLog;
    uint windowBit;
    uint enabledMask = subScreen ? line.windowControl.z : line.windowControl.y;

    switch (layer) {
        case 1u:
            raw = line.windows.x & 0x0Fu;
            wLog = line.windows.w & 0x03u;
            windowBit = 0x01u;
            break;
        case 2u:
            raw = (line.windows.x >> 4u) & 0x0Fu;
            wLog = (line.windows.w >> 2u) & 0x03u;
            windowBit = 0x02u;
            break;
        case 3u:
            raw = line.windows.y & 0x0Fu;
            wLog = (line.windows.w >> 4u) & 0x03u;
            windowBit = 0x04u;
            break;
        case 4u:
            raw = (line.windows.y >> 4u) & 0x0Fu;
            wLog = (line.windows.w >> 6u) & 0x03u;
            windowBit = 0x08u;
            break;
        case 5u:
            raw = line.windows.z & 0x0Fu;
            wLog = line.windowRanges.x & 0x03u;
            windowBit = 0x10u;
            break;
        default:
            return false;
    }

    if ((enabledMask & windowBit) == 0u) {
        return false;
    }

    return evaluateWindow(raw,
                          wLog,
                          screenX,
                          line.windowRanges.y,
                          line.windowRanges.z,
                          line.windowRanges.w,
                          line.windowControl.x);
}

inline void applyIndexedSample(thread PixelSample &best,
                               IndexedSample sample,
                               const device uint *colors) {
    if (sample.colorIndex != 0u && sample.z >= best.z) {
        best.color = colors[sample.colorIndex & 0xFFu];
        best.z = sample.z;
        best.layer = sample.layer;
    }
}

inline void applyDirectColor(thread PixelSample &best, uint color, uint z, uint layer) {
    if (z >= best.z) {
        best.color = color;
        best.z = z;
        best.layer = layer;
    }
}

inline uint chrBaseForBG(const thread GPULineState &line, uint bg) {
    if (bg < 2u) {
        return bg == 0u ? ((line.extras.x & 0x0Fu) << 13) : (((line.extras.x >> 4) & 0x0Fu) << 13);
    }
    return bg == 2u ? ((line.extras.y & 0x0Fu) << 13) : (((line.extras.y >> 4) & 0x0Fu) << 13);
}

inline IndexedSample sampleBG4bpp(const device uchar *vram,
                                  const thread GPULineState &line,
                                  uint bg,
                                  uint screenX,
                                  uint screenY,
                                  uint zOrder0,
                                  uint zOrder1) {
    IndexedSample sample = {0u, 0u, bg + 1u};
    uint scReg = line.bgSC[bg] & 0xFFu;
    uint tilemapBase = (scReg & 0xFCu) << 9;
    uint tileSize = (line.control.y & (1u << (4u + bg))) != 0u ? 16u : 8u;
    uint chrBase = chrBaseForBG(line, bg);
    uint hScroll = line.bgHScroll[bg] & 0x3FFu;
    uint vScroll = line.bgVScroll[bg] & 0x3FFu;
    uint px = screenX + hScroll;
    uint sy = screenY + vScroll;

    uint tileX;
    uint tileY;
    uint subTileX;
    uint subTileY;
    if (tileSize == 16u) {
        tileX = (px / 16u) & 0x3Fu;
        tileY = (sy / 16u) & 0x3Fu;
        subTileX = (px / 8u) & 1u;
        subTileY = (sy / 8u) & 1u;
    } else {
        tileX = (px / 8u) & 0x3Fu;
        tileY = (sy / 8u) & 0x3Fu;
        subTileX = 0u;
        subTileY = 0u;
    }

    uint tmAddr = tilemapBase;
    if (tileX >= 32u) { tmAddr += 0x800u; }
    if (tileY >= 32u) {
        uint scSize = scReg & 0x03u;
        if (scSize == 2u) { tmAddr += 0x800u; }
        else if (scSize == 3u) { tmAddr += 0x1000u; }
    }
    tmAddr += ((tileY & 0x1Fu) * 32u + (tileX & 0x1Fu)) * 2u;

    uint tileEntry = readVRAMWord(vram, tmAddr);
    uint tileNum = tileEntry & 0x03FFu;
    uint palette = (tileEntry >> 10) & 0x07u;
    uint tileZ = ((tileEntry >> 13) & 0x01u) != 0u ? zOrder1 : zOrder0;
    bool hFlip = (tileEntry & 0x4000u) != 0u;
    bool vFlip = (tileEntry & 0x8000u) != 0u;

    if (tileSize == 16u) {
        uint sx = hFlip ? (1u - subTileX) : subTileX;
        uint syTile = vFlip ? (1u - subTileY) : subTileY;
        tileNum += sx + syTile * 16u;
    }

    uint fineY = sy & 7u;
    if (vFlip) { fineY = 7u - fineY; }

    uint chrAddr = chrBase + tileNum * 32u + fineY * 2u;
    uint bp0 = readVRAM(vram, chrAddr);
    uint bp1 = readVRAM(vram, chrAddr + 1u);
    uint bp2 = readVRAM(vram, chrAddr + 16u);
    uint bp3 = readVRAM(vram, chrAddr + 17u);

    uint fineX = px & 7u;
    if (hFlip) { fineX = 7u - fineX; }
    uint bit = 7u - fineX;
    uint pixel = ((bp0 >> bit) & 1u) |
                 (((bp1 >> bit) & 1u) << 1) |
                 (((bp2 >> bit) & 1u) << 2) |
                 (((bp3 >> bit) & 1u) << 3);

    if (pixel != 0u) {
        sample.colorIndex = palette * 16u + pixel;
        sample.z = tileZ;
    }
    return sample;
}

inline IndexedSample sampleBG8bpp(const device uchar *vram,
                                  const thread GPULineState &line,
                                  uint bg,
                                  uint screenX,
                                  uint screenY,
                                  uint zOrder0,
                                  uint zOrder1) {
    IndexedSample sample = {0u, 0u, bg + 1u};
    uint scReg = line.bgSC[bg] & 0xFFu;
    uint tilemapBase = (scReg & 0xFCu) << 9;
    uint tileSize = (line.control.y & (1u << (4u + bg))) != 0u ? 16u : 8u;
    uint chrBase = chrBaseForBG(line, bg);
    uint hScroll = line.bgHScroll[bg] & 0x3FFu;
    uint vScroll = line.bgVScroll[bg] & 0x3FFu;
    uint px = screenX + hScroll;
    uint sy = screenY + vScroll;

    uint tileX;
    uint tileY;
    uint subTileX;
    uint subTileY;
    if (tileSize == 16u) {
        tileX = (px / 16u) & 0x3Fu;
        tileY = (sy / 16u) & 0x3Fu;
        subTileX = (px / 8u) & 1u;
        subTileY = (sy / 8u) & 1u;
    } else {
        tileX = (px / 8u) & 0x3Fu;
        tileY = (sy / 8u) & 0x3Fu;
        subTileX = 0u;
        subTileY = 0u;
    }

    uint tmAddr = tilemapBase;
    if (tileX >= 32u) { tmAddr += 0x800u; }
    if (tileY >= 32u) {
        uint scSize = scReg & 0x03u;
        if (scSize == 2u) { tmAddr += 0x800u; }
        else if (scSize == 3u) { tmAddr += 0x1000u; }
    }
    tmAddr += ((tileY & 0x1Fu) * 32u + (tileX & 0x1Fu)) * 2u;

    uint tileEntry = readVRAMWord(vram, tmAddr);
    uint tileNum = tileEntry & 0x03FFu;
    uint tileZ = ((tileEntry >> 13) & 0x01u) != 0u ? zOrder1 : zOrder0;
    bool hFlip = (tileEntry & 0x4000u) != 0u;
    bool vFlip = (tileEntry & 0x8000u) != 0u;

    if (tileSize == 16u) {
        uint sx = hFlip ? (1u - subTileX) : subTileX;
        uint syTile = vFlip ? (1u - subTileY) : subTileY;
        tileNum += sx + syTile * 16u;
    }

    uint fineY = sy & 7u;
    if (vFlip) { fineY = 7u - fineY; }

    uint chrAddr = chrBase + tileNum * 64u + fineY * 2u;
    uint bp0 = readVRAM(vram, chrAddr);
    uint bp1 = readVRAM(vram, chrAddr + 1u);
    uint bp2 = readVRAM(vram, chrAddr + 16u);
    uint bp3 = readVRAM(vram, chrAddr + 17u);
    uint bp4 = readVRAM(vram, chrAddr + 32u);
    uint bp5 = readVRAM(vram, chrAddr + 33u);
    uint bp6 = readVRAM(vram, chrAddr + 48u);
    uint bp7 = readVRAM(vram, chrAddr + 49u);

    uint fineX = px & 7u;
    if (hFlip) { fineX = 7u - fineX; }
    uint bit = 7u - fineX;
    uint pixel = ((bp0 >> bit) & 1u) |
                 (((bp1 >> bit) & 1u) << 1) |
                 (((bp2 >> bit) & 1u) << 2) |
                 (((bp3 >> bit) & 1u) << 3) |
                 (((bp4 >> bit) & 1u) << 4) |
                 (((bp5 >> bit) & 1u) << 5) |
                 (((bp6 >> bit) & 1u) << 6) |
                 (((bp7 >> bit) & 1u) << 7);

    if (pixel != 0u) {
        sample.colorIndex = pixel;
        sample.z = tileZ;
    }
    return sample;
}

inline IndexedSample sampleBG2bpp(const device uchar *vram,
                                  const thread GPULineState &line,
                                  uint bg,
                                  uint screenX,
                                  uint screenY,
                                  uint paletteBase,
                                  uint zOrder0,
                                  uint zOrder1) {
    IndexedSample sample = {0u, 0u, bg + 1u};
    uint scReg = line.bgSC[bg] & 0xFFu;
    uint tilemapBase = (scReg & 0xFCu) << 9;
    uint tileSize = (line.control.y & (1u << (4u + bg))) != 0u ? 16u : 8u;
    uint chrBase = chrBaseForBG(line, bg);
    uint hScroll = line.bgHScroll[bg] & 0x3FFu;
    uint vScroll = line.bgVScroll[bg] & 0x3FFu;
    uint px = screenX + hScroll;
    uint sy = screenY + vScroll;

    uint tileX;
    uint tileY;
    uint subTileX;
    uint subTileY;
    if (tileSize == 16u) {
        tileX = (px / 16u) & 0x3Fu;
        tileY = (sy / 16u) & 0x3Fu;
        subTileX = (px / 8u) & 1u;
        subTileY = (sy / 8u) & 1u;
    } else {
        tileX = (px / 8u) & 0x3Fu;
        tileY = (sy / 8u) & 0x3Fu;
        subTileX = 0u;
        subTileY = 0u;
    }

    uint tmAddr = tilemapBase;
    if (tileX >= 32u) { tmAddr += 0x800u; }
    if (tileY >= 32u) {
        uint scSize = scReg & 0x03u;
        if (scSize == 2u) { tmAddr += 0x800u; }
        else if (scSize == 3u) { tmAddr += 0x1000u; }
    }
    tmAddr += ((tileY & 0x1Fu) * 32u + (tileX & 0x1Fu)) * 2u;

    uint tileEntry = readVRAMWord(vram, tmAddr);
    uint tileNum = tileEntry & 0x03FFu;
    uint palette = (tileEntry >> 10) & 0x07u;
    uint tileZ = ((tileEntry >> 13) & 0x01u) != 0u ? zOrder1 : zOrder0;
    bool hFlip = (tileEntry & 0x4000u) != 0u;
    bool vFlip = (tileEntry & 0x8000u) != 0u;

    if (tileSize == 16u) {
        uint sx = hFlip ? (1u - subTileX) : subTileX;
        uint syTile = vFlip ? (1u - subTileY) : subTileY;
        tileNum += sx + syTile * 16u;
    }

    uint fineY = sy & 7u;
    if (vFlip) { fineY = 7u - fineY; }

    uint chrAddr = chrBase + tileNum * 16u + fineY * 2u;
    uint bp0 = readVRAM(vram, chrAddr);
    uint bp1 = readVRAM(vram, chrAddr + 1u);

    uint fineX = px & 7u;
    if (hFlip) { fineX = 7u - fineX; }
    uint bit = 7u - fineX;
    uint pixel = ((bp0 >> bit) & 1u) | (((bp1 >> bit) & 1u) << 1);

    if (pixel != 0u) {
        sample.colorIndex = paletteBase + palette * 4u + pixel;
        sample.z = tileZ;
    }
    return sample;
}

inline int signExtend13(uint value) {
    return int(short((value & 0x1FFFu) << 3)) >> 3;
}

inline int signExtend16(uint value) {
    return int(short(value & 0xFFFFu));
}

inline IndexedSample sampleMode7(const device uchar *vram,
                                 const thread GPULineState &line,
                                 uint screenX,
                                 uint screenY,
                                 uint zOrder) {
    IndexedSample sample = {0u, 0u, 1u};
    int a = signExtend16(line.mode7ABCD.x);
    int b = signExtend16(line.mode7ABCD.y);
    int c = signExtend16(line.mode7ABCD.z);
    int d = signExtend16(line.mode7ABCD.w);
    int cx = signExtend13(line.mode7XY.x);
    int cy = signExtend13(line.mode7XY.y);
    int hOfs = signExtend13(line.bgHScroll.x);
    int vOfs = signExtend13(line.bgVScroll.x);

    bool hFlip = (line.extras.z & 0x01u) != 0u;
    bool vFlip = (line.extras.z & 0x02u) != 0u;
    uint wrapMode = (line.extras.z >> 6) & 0x03u;

    int effectiveY = vFlip ? (255 - int(screenY)) : int(screenY);
    int xBase = a * (hOfs - cx) + b * (vOfs + effectiveY - cy) + (cx << 8);
    int yBase = c * (hOfs - cx) + d * (vOfs + effectiveY - cy) + (cy << 8);
    int sx = hFlip ? (255 - int(screenX)) : int(screenX);
    int vramX = xBase + a * sx;
    int vramY = yBase + c * sx;
    int pixelX = vramX >> 8;
    int pixelY = vramY >> 8;
    bool outOfBounds = pixelX < 0 || pixelX >= 1024 || pixelY < 0 || pixelY >= 1024;

    if (outOfBounds) {
        if (wrapMode == 2u) {
            return sample;
        }
        if (wrapMode == 3u) {
            int fx = ((pixelX % 8) + 8) % 8;
            int fy = ((pixelY % 8) + 8) % 8;
            uint tileDataAddr = uint((fy * 8 + fx) * 2 + 1);
            uint colorIdx = uint(readVRAM(vram, tileDataAddr));
            if (colorIdx != 0u) {
                sample.colorIndex = colorIdx;
                sample.z = zOrder;
            }
            return sample;
        }
        pixelX &= 1023;
        pixelY &= 1023;
    }

    uint tileMapX = uint(pixelX >> 3);
    uint tileMapY = uint(pixelY >> 3);
    uint tileMapAddr = (tileMapY * 128u + tileMapX) * 2u;
    uint tileNum = uint(readVRAM(vram, tileMapAddr));
    uint fineX = uint(pixelX) & 7u;
    uint fineY = uint(pixelY) & 7u;
    uint tileDataAddr = (tileNum * 64u + fineY * 8u + fineX) * 2u + 1u;
    uint colorIdx = uint(readVRAM(vram, tileDataAddr));
    if (colorIdx != 0u) {
        sample.colorIndex = colorIdx;
        sample.z = zOrder;
    }
    return sample;
}

inline uint spriteBaseSize(uint objsel) {
    switch ((objsel >> 5) & 0x07u) {
        case 0u: return 8u;
        case 1u: return 8u;
        case 2u: return 8u;
        case 3u: return 16u;
        case 4u: return 16u;
        case 5u: return 32u;
        default: return 8u;
    }
}

inline uint spriteWidth(uint objsel, bool isLarge) {
    const uint smallWidths[8] = {8u, 8u, 8u, 16u, 16u, 32u, 16u, 16u};
    const uint largeWidths[8] = {16u, 32u, 64u, 32u, 64u, 64u, 32u, 32u};
    uint sizeSelect = (objsel >> 5) & 0x07u;
    return isLarge ? largeWidths[sizeSelect] : smallWidths[sizeSelect];
}

inline uint spriteHeight(uint objsel, bool isLarge) {
    const uint smallHeights[8] = {8u, 8u, 8u, 16u, 16u, 32u, 32u, 32u};
    const uint largeHeights[8] = {16u, 32u, 64u, 32u, 64u, 64u, 64u, 32u};
    uint sizeSelect = (objsel >> 5) & 0x07u;
    return isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect];
}

inline uint flippedSpriteY(uint width, uint height, uint y) {
    if (width == height) {
        return height - 1u - y;
    }
    if (y < width) {
        return width - 1u - y;
    }
    return width + (width - 1u) - (y - width);
}

inline IndexedSample sampleSprites(const device uchar *vram,
                                   const device uchar *oam,
                                   const device uint *spriteCounts,
                                   const device ushort *spriteIndices,
                                   const thread GPULineState &line,
                                   uint screenX,
                                   uint screenY,
                                   uint z0,
                                   uint z1,
                                   uint z2,
                                   uint z3) {
    IndexedSample sample = {0u, 0u, 0u};
    uint nameBase = (line.control.w & 0x07u) << 14;
    uint nameGap = (((line.control.w >> 3) & 0x03u) + 1u) << 13;
    uint count = min(spriteCounts[screenY], 32u);

    for (uint spriteSlot = 0; spriteSlot < count; spriteSlot++) {
        uint i = uint(spriteIndices[screenY * 32u + spriteSlot]);
        uint baseAddr = i * 4u;
        int x = int(readOAM(oam, baseAddr));
        uint y = uint(readOAM(oam, baseAddr + 1u));
        uint tile = uint(readOAM(oam, baseAddr + 2u));
        uint attr = uint(readOAM(oam, baseAddr + 3u));

        uint highIdx = 512u + (i >> 2u);
        uint highShift = (i & 3u) * 2u;
        uint highBits = (uint(readOAM(oam, highIdx)) >> highShift) & 0x03u;
        bool xBit9 = (highBits & 0x01u) != 0u;
        bool isLarge = (highBits & 0x02u) != 0u;
        int spriteX = xBit9 ? (x - 256) : x;
        uint spriteW = spriteWidth(line.control.w, isLarge);
        uint spriteH = spriteHeight(line.control.w, isLarge);
        uint spriteY = (y + 1u) & 0xFFu;
        int relY = (int(screenY) - int(spriteY)) & 0xFF;
        if (relY < 0 || uint(relY) >= spriteH) { continue; }

        int localX = int(screenX) - spriteX;
        if (localX < 0 || uint(localX) >= spriteW) { continue; }

        uint palette = ((attr >> 1u) & 0x07u) + 8u;
        uint objPriority = (attr >> 4u) & 0x03u;
        bool hFlip = (attr & 0x40u) != 0u;
        bool vFlip = (attr & 0x80u) != 0u;
        uint spriteZ = objPriority == 0u ? z0 : (objPriority == 1u ? z1 : (objPriority == 2u ? z2 : z3));
        uint nameTable = attr & 0x01u;

        uint fineY = uint(relY);
        if (vFlip) { fineY = flippedSpriteY(spriteW, spriteH, fineY); }

        uint tileRow = fineY / 8u;
        uint tileCol = uint(localX) / 8u;
        uint tilesWide = spriteW / 8u;
        uint mirrorCol = hFlip ? (tilesWide - 1u - tileCol) : tileCol;
        uint actualTile = tile + tileRow * 16u + mirrorCol;
        uint chrBase = nameTable == 0u ? nameBase : (nameBase + nameGap);
        uint chrAddr = chrBase + (actualTile & 0xFFu) * 32u + (fineY & 7u) * 2u;

        uint bp0 = readVRAM(vram, chrAddr);
        uint bp1 = readVRAM(vram, chrAddr + 1u);
        uint bp2 = readVRAM(vram, chrAddr + 16u);
        uint bp3 = readVRAM(vram, chrAddr + 17u);
        uint pxInTile = uint(localX) & 7u;
        uint bit = hFlip ? pxInTile : (7u - pxInTile);
        uint pixel = ((bp0 >> bit) & 1u) |
                     (((bp1 >> bit) & 1u) << 1) |
                     (((bp2 >> bit) & 1u) << 2) |
                     (((bp3 >> bit) & 1u) << 3);

        if (pixel != 0u) {
            sample.colorIndex = (128u + (palette - 8u) * 16u + pixel) & 0xFFu;
            sample.z = spriteZ;
            sample.layer = palette >= 12u ? 6u : 5u;
        }
    }

    return sample;
}

inline void composeScreen(thread PixelSample &best,
                          const device uchar *vram,
                          const device uchar *oam,
                          const device uint *colors,
                          const device uint *spriteCounts,
                          const device ushort *spriteIndices,
                          const thread GPULineState &line,
                          uint screenX,
                          uint screenY,
                          uint layerMask,
                          bool subScreen) {
    uint mode = line.control.y & 0x07u;

    switch (mode) {
    case 0u:
        if ((layerMask & 0x08u) != 0u && !isWindowMaskedForLayer(4u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 3u, screenX, screenY, 96u, 1u, 4u), colors); }
        if ((layerMask & 0x04u) != 0u && !isWindowMaskedForLayer(3u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 2u, screenX, screenY, 64u, 2u, 5u), colors); }
        if ((layerMask & 0x02u) != 0u && !isWindowMaskedForLayer(2u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 1u, screenX, screenY, 32u, 7u, 10u), colors); }
        if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 0u, screenX, screenY, 0u, 8u, 11u), colors); }
        if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 3u, 6u, 9u, 12u), colors); }
        break;
    case 1u: {
        bool bgPriority = (line.control.y & 0x08u) != 0u;
        if (bgPriority) {
            if ((layerMask & 0x04u) != 0u && !isWindowMaskedForLayer(3u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 2u, screenX, screenY, 0u, 1u, 10u), colors); }
            if ((layerMask & 0x02u) != 0u && !isWindowMaskedForLayer(2u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 1u, screenX, screenY, 4u, 7u), colors); }
            if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 0u, screenX, screenY, 5u, 8u), colors); }
            if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 2u, 3u, 6u, 9u), colors); }
        } else {
            if ((layerMask & 0x04u) != 0u && !isWindowMaskedForLayer(3u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG2bpp(vram, line, 2u, screenX, screenY, 0u, 1u, 3u), colors); }
            if ((layerMask & 0x02u) != 0u && !isWindowMaskedForLayer(2u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 1u, screenX, screenY, 5u, 8u), colors); }
            if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 0u, screenX, screenY, 6u, 9u), colors); }
            if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 2u, 4u, 7u, 10u), colors); }
        }
        break;
    }
    case 3u:
        if ((layerMask & 0x02u) != 0u && !isWindowMaskedForLayer(2u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 1u, screenX, screenY, 1u, 5u), colors); }
        if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG8bpp(vram, line, 0u, screenX, screenY, 2u, 6u), colors); }
        if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 3u, 4u, 7u, 8u), colors); }
        break;
    case 7u:
        if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleMode7(vram, line, screenX, screenY, 1u), colors); }
        if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 1u, 2u, 3u, 4u), colors); }
        break;
    default:
        if ((layerMask & 0x02u) != 0u && !isWindowMaskedForLayer(2u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 1u, screenX, screenY, 1u, 5u), colors); }
        if ((layerMask & 0x01u) != 0u && !isWindowMaskedForLayer(1u, line, screenX, subScreen)) { applyIndexedSample(best, sampleBG4bpp(vram, line, 0u, screenX, screenY, 2u, 6u), colors); }
        if ((layerMask & 0x10u) != 0u && !isWindowMaskedForLayer(5u, line, screenX, subScreen)) { applyIndexedSample(best, sampleSprites(vram, oam, spriteCounts, spriteIndices, line, screenX, screenY, 3u, 4u, 7u, 8u), colors); }
        break;
    }
}

kernel void ppuFrameKernel(texture2d<float, access::write> outTexture [[texture(0)]],
                           const device uchar *vram [[buffer(0)]],
                           const device uchar *oam [[buffer(1)]],
                           const device uint *colors [[buffer(2)]],
                           const device GPULineState *lineStates [[buffer(3)]],
                           const device uint *spriteCounts [[buffer(4)]],
                           const device ushort *spriteIndices [[buffer(5)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 256u || gid.y >= 224u) {
        return;
    }

    GPULineState line = lineStates[gid.y];
    if ((line.control.x & 0x80u) != 0u) {
        outTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    PixelSample best = {colors[0], 0u, 0u};
    composeScreen(best, vram, oam, colors, spriteCounts, spriteIndices, line, gid.x, gid.y, line.control.z & 0x1Fu, false);

    uint cgwsel = line.colorMath.x & 0xFFu;
    uint cgadsub = line.colorMath.y & 0xFFu;
    bool blendWithSubScreen = (cgwsel & 0x02u) != 0u;
    PixelSample sub = {colors[0], 0u, 0u};
    if (blendWithSubScreen && (line.colorMath.w & 0x1Fu) != 0u) {
        composeScreen(sub, vram, oam, colors, spriteCounts, spriteIndices, line, gid.x, gid.y, line.colorMath.w & 0x1Fu, true);
    }

    if (cgadsub != 0u) {
        uint aboveMask = (cgwsel >> 6u) & 0x03u;
        uint belowMask = (cgwsel >> 4u) & 0x03u;
        if (!colorWindowAllows(aboveMask, line, gid.x) ||
            !colorWindowAllows(belowMask, line, gid.x)) {
            outTexture.write(unpackColor(best.color), gid);
            return;
        }
        uint layerBit = colorMathLayerBit(best.layer);
        if (layerBit != 0u && (cgadsub & layerBit) != 0u) {
            bool subtract = (cgadsub & 0x80u) != 0u;
            bool halfColor = (cgadsub & 0x40u) != 0u;
            uint subColor = blendWithSubScreen ? sub.color : line.colorMath.z;
            bool shouldHalf = blendWithSubScreen ? (halfColor && sub.layer != 0u) : halfColor;
            best.color = applyColorMathToColor(best.color, subColor, subtract, shouldHalf);
        }
    }

    outTexture.write(unpackColor(best.color), gid);
}
