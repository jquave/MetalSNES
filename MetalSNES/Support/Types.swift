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

    static let `default` = DisplayConfiguration(
        integerScalingEnabled: true,
        filterMode: .crt
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
}
