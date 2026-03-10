import Foundation
import simd

typealias Address = UInt32
typealias Byte = UInt8
typealias Word = UInt16

enum DisplayFilterMode: String, CaseIterable, Codable, Identifiable {
    case clean
    case scanlines
    case crt
    case phosphor
    case phosphorHot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clean: return "Clean"
        case .scanlines: return "Scanlines"
        case .crt: return "CRT Glass"
        case .phosphor: return "Aperture Bloom"
        case .phosphorHot: return "Trinitron"
        }
    }

    var subtitle: String {
        switch self {
        case .clean: return "Nearest-neighbor pixels with no post-processing."
        case .scanlines: return "Sharp pixels with subtle scanline contrast."
        case .crt: return "Curvature, mask, glow, and vignette for a CRT-like look."
        case .phosphor: return "Aperture-grille RGB glow with localized phosphor bleed and no scanline warp."
        case .phosphorHot: return "Tall rounded RGB phosphor bars with slot-mask gaps and stronger Trinitron-style glow."
        }
    }
}

struct DisplayConfiguration: Codable, Equatable {
    var integerScalingEnabled: Bool
    var filterMode: DisplayFilterMode
    var brightness: Float
    var contrast: Float
    var sharpness: Float
    var saturation: Float

    init(
        integerScalingEnabled: Bool,
        filterMode: DisplayFilterMode,
        brightness: Float = 1.0,
        contrast: Float = 1.0,
        sharpness: Float = 1.0,
        saturation: Float = 1.0
    ) {
        self.integerScalingEnabled = integerScalingEnabled
        self.filterMode = filterMode
        self.brightness = brightness
        self.contrast = contrast
        self.sharpness = sharpness
        self.saturation = saturation
    }

    private enum CodingKeys: String, CodingKey {
        case integerScalingEnabled
        case filterMode
        case brightness
        case contrast
        case sharpness
        case saturation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        integerScalingEnabled = try container.decode(Bool.self, forKey: .integerScalingEnabled)
        filterMode = try container.decode(DisplayFilterMode.self, forKey: .filterMode)
        brightness = try container.decodeIfPresent(Float.self, forKey: .brightness) ?? 1.0
        contrast = try container.decodeIfPresent(Float.self, forKey: .contrast) ?? 1.0
        sharpness = try container.decodeIfPresent(Float.self, forKey: .sharpness) ?? 1.0
        saturation = try container.decodeIfPresent(Float.self, forKey: .saturation) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(integerScalingEnabled, forKey: .integerScalingEnabled)
        try container.encode(filterMode, forKey: .filterMode)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(sharpness, forKey: .sharpness)
        try container.encode(saturation, forKey: .saturation)
    }

    static let `default` = DisplayConfiguration(
        integerScalingEnabled: true,
        filterMode: .crt,
        brightness: 1.0,
        contrast: 1.0,
        sharpness: 1.0,
        saturation: 1.0
    )
}

struct GPULineState {
    var control = SIMD4<UInt32>(repeating: 0)
    var bgSC = SIMD4<UInt32>(repeating: 0)
    var bgHScroll = SIMD4<UInt32>(repeating: 0)
    var bgVScroll = SIMD4<UInt32>(repeating: 0)
    var extras = SIMD4<UInt32>(repeating: 0)
    var colorMath = SIMD4<UInt32>(repeating: 0)
    var windows = SIMD4<UInt32>(repeating: 0)
    var windowRanges = SIMD4<UInt32>(repeating: 0)
    var windowControl = SIMD4<UInt32>(repeating: 0)
    var mode7ABCD = SIMD4<UInt32>(repeating: 0)
    var mode7XY = SIMD4<UInt32>(repeating: 0)
}

struct DisplayUniforms {
    var viewportSize = SIMD2<Float>(repeating: 0)
    var textureSize = SIMD2<Float>(repeating: 0)
    var contentOrigin = SIMD2<Float>(repeating: 0)
    var contentSize = SIMD2<Float>(repeating: 0)
    var filterMode: UInt32 = 0
    var integerScalingEnabled: UInt32 = 0
    var scanlineStrength: Float = 0
    var maskStrength: Float = 0
    var bloomStrength: Float = 0
    var curvature: Float = 0
    var vignetteStrength: Float = 0
    var sharpness: Float = 0
    var brightness: Float = 1
    var contrast: Float = 1
    var saturation: Float = 1
    var userSharpness: Float = 1
}
