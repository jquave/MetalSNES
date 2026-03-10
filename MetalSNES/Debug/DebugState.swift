import Foundation
import SwiftUI

final class DebugState: ObservableObject {
    // CPU registers
    @Published var a: UInt16 = 0
    @Published var x: UInt16 = 0
    @Published var y: UInt16 = 0
    @Published var s: UInt16 = 0
    @Published var d: UInt16 = 0
    @Published var dbr: UInt8 = 0
    @Published var pbr: UInt8 = 0
    @Published var pc: UInt16 = 0
    @Published var p: UInt8 = 0
    @Published var emulationMode: Bool = true

    // Disassembly
    @Published var currentPC: UInt32 = 0
    @Published var memoryAroundPC: [UInt8] = []

    // Memory viewer
    @Published var memoryPage: [UInt8] = []
    var memoryViewerOffset: Int = 0

    // Sprite debug overrides
    @Published var spriteNameBase: Int = 0      // 0-7, maps to objsel bits 0-2
    @Published var spriteNameGap: Int = 0       // 0-3, maps to objsel bits 3-4
    @Published var spriteSizeSelect: Int = 0    // 0-5, maps to objsel bits 5-7
    @Published var spriteOverrideEnabled: Bool = false

    // VRAM tile viewer
    @Published var vramSnapshot: [UInt8] = []
    @Published var cgramSnapshot: [UInt8] = []
    @Published var bg1ChrBase: Int = 0
    @Published var bg2ChrBase: Int = 0
    @Published var bg3ChrBase: Int = 0

    // Raw PPU registers for debug readout
    @Published var ppuTM: UInt8 = 0
    @Published var ppuBGMode: UInt8 = 0
    @Published var ppuBG12NBA: UInt8 = 0
    @Published var ppuBG34NBA: UInt8 = 0
    @Published var ppuOBJSEL: UInt8 = 0
    @Published var ppuINIDISP: UInt8 = 0
    @Published var ppuOAMSnapshot: [UInt8] = []
    @Published var pacingProducedFrames: UInt64 = 0
    @Published var pacingPresentedFrames: UInt64 = 0
    @Published var pacingRepeatedFrames: UInt64 = 0
    @Published var pacingDroppedFrames: UInt64 = 0
    @Published var pacingAverageDisplayIntervalMs: Double = 0
    @Published var pacingWorstDisplayIntervalMs: Double = 0
    @Published var pacingAverageFrameAgeMs: Double = 0
    @Published var pacingWorstFrameAgeMs: Double = 0
    @Published var pacingAudioBufferedSamples: Int = 0
    @Published var pacingAudioUnderruns: UInt64 = 0
    @Published var pacingAudioOverruns: UInt64 = 0
    @Published var pacingAudioCorrectionMs: Double = 0

    var flagsString: String {
        var s = ""
        s += (p & 0x80) != 0 ? "N" : "n"
        s += (p & 0x40) != 0 ? "V" : "v"
        s += (p & 0x20) != 0 ? "M" : "m"
        s += (p & 0x10) != 0 ? "X" : "x"
        s += (p & 0x08) != 0 ? "D" : "d"
        s += (p & 0x04) != 0 ? "I" : "i"
        s += (p & 0x02) != 0 ? "Z" : "z"
        s += (p & 0x01) != 0 ? "C" : "c"
        return s
    }
}
