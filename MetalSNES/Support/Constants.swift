import Foundation

enum SNESConstants {
    // Clock
    static let masterClockHz: UInt64 = 21_477_272
    static let cpuDivider: UInt64 = 6  // ~3.58 MHz (fast)
    static let cpuSlowDivider: UInt64 = 8  // ~2.68 MHz (slow)

    // Display
    static let screenWidth = 256
    static let screenHeight = 224
    static let screenHeight240 = 240 // overscan mode
    static let bytesPerPixel = 4 // RGBA8

    // Timing
    static let dotsPerScanline = 341
    static let masterCyclesPerDot = 4
    static let masterCyclesPerScanline = 1364
    static let scanlinesPerFrame = 262
    static let visibleScanlines = 224
    static let vBlankStart = 225
    static let framesPerSecond: Double = 60.0988

    // Memory sizes
    static let wramSize = 0x20000    // 128 KB
    static let vramSize = 0x10000    // 64 KB
    static let oamSize = 544
    static let cgramSize = 512
    static let sramMaxSize = 0x8000  // 32 KB

    // PPU registers
    static let ppuRegStart: Address = 0x2100
    static let ppuRegEnd: Address = 0x213F

    // APU I/O
    static let apuIOStart: Address = 0x2140
    static let apuIOEnd: Address = 0x2143

    // CPU registers
    static let cpuRegStart: Address = 0x4200
    static let cpuRegEnd: Address = 0x43FF

    // DMA registers
    static let dmaRegStart: Address = 0x4300
    static let dmaRegEnd: Address = 0x43FF
}
