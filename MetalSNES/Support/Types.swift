import Foundation
import simd

typealias Address = UInt32
typealias Byte = UInt8
typealias Word = UInt16

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
