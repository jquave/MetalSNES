import Foundation

struct Timing {
    static let masterCyclesPerScanline = 1364
    static let scanlinesPerFrame = 262
    static let masterCyclesPerFrame = masterCyclesPerScanline * scanlinesPerFrame
    static let targetFrameTime: Double = 1.0 / 60.0988 // ~16.639ms

    // CPU cycles consumed per scanline varies, but roughly:
    // Fast cycle: 6 master clocks, Slow cycle: 8 master clocks
    // Average ~6 master clocks per CPU cycle → ~227 CPU cycles per scanline
    static let cpuCyclesPerScanline = 227

    // Target frame time in mach_absolute_time units (for drift-free pacing)
    static let targetFrameTimeAbsolute: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanoseconds = targetFrameTime * 1_000_000_000
        // Convert nanoseconds → mach absolute time: ns * denom / numer
        return UInt64(nanoseconds * Double(info.denom) / Double(info.numer))
    }()

    static func machAbsoluteToNanoseconds(_ mach: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach) * Double(info.numer) / Double(info.denom)
    }
}
