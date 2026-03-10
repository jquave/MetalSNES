import Darwin
import Foundation

struct Timing {
    static let masterCyclesPerScanline = 1364
    static let scanlinesPerFrame = 262
    static let masterCyclesPerFrame = masterCyclesPerScanline * scanlinesPerFrame
    static let targetFrameTime: Double = 1.0 / 60.0988 // ~16.639ms
    static let targetFrameTimeNanoseconds = UInt64(targetFrameTime * 1_000_000_000)

    // CPU cycles consumed per scanline varies, but roughly:
    // Fast cycle: 6 master clocks, Slow cycle: 8 master clocks
    // Average ~6 master clocks per CPU cycle → ~227 CPU cycles per scanline
    static let cpuCyclesPerScanline = 227

    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static let framePacingSpinThresholdNs: UInt64 = 500_000
    static let framePacingSpinThresholdAbsolute = nanosecondsToMachAbsolute(framePacingSpinThresholdNs)

    // Target frame time in mach_absolute_time units (for drift-free pacing)
    static let targetFrameTimeAbsolute: UInt64 = {
        nanosecondsToMachAbsolute(targetFrameTimeNanoseconds)
    }()

    static func machAbsoluteToNanoseconds(_ mach: UInt64) -> Double {
        Double(mach) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
    }

    static func nanosecondsToMachAbsolute(_ nanoseconds: UInt64) -> UInt64 {
        UInt64(Double(nanoseconds) * Double(timebaseInfo.denom) / Double(timebaseInfo.numer))
    }

    static func waitUntil(_ target: UInt64) {
        let now = mach_absolute_time()
        guard now < target else { return }

        if target - now > framePacingSpinThresholdAbsolute {
            mach_wait_until(target - framePacingSpinThresholdAbsolute)
        }

        while mach_absolute_time() < target {}
    }
}
