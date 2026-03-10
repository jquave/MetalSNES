import Foundation

/// Headless test runner for PeterLemon's SNES CPU test ROMs.
/// Each test ROM writes "PASS" or "FAIL" (uppercase) ASCII text to VRAM.
/// On failure, the ROM enters a loop re-executing PrintText.
/// On full success, it hits `jmp Loop` (infinite JMP to self).
///
/// Detection strategy:
/// 1. Run CPU with scanline-accurate VBlank timing
/// 2. Detect loops via same-PC counter or JMP-to-self / BRA-to-self
/// 3. Scan VRAM for "PASS" and "FAIL" strings at even byte offsets
final class CPUTestRunner {

    struct TestResult {
        let name: String
        let passCount: Int
        let failCount: Int
        let totalCycles: UInt64
        let stoppedReason: StopReason
        var passed: Bool { failCount == 0 && passCount > 0 }
    }

    enum StopReason: CustomStringConvertible {
        case allTestsPassed
        case failureDetected
        case cycleLimit
        case cpuStopped
        case error(String)

        var description: String {
            switch self {
            case .allTestsPassed: return "All tests passed"
            case .failureDetected: return "Failure detected"
            case .cycleLimit: return "Cycle limit reached"
            case .cpuStopped: return "CPU stopped (STP)"
            case .error(let msg): return "Error: \(msg)"
            }
        }
    }

    // "PASS" and "FAIL" uppercase ASCII as written by PeterLemon's test ROMs
    static let passBytes: [UInt8] = [0x50, 0x41, 0x53, 0x53] // "PASS"
    static let failBytes: [UInt8] = [0x46, 0x41, 0x49, 0x4C] // "FAIL"

    static let maxCycles: UInt64 = 100_000_000 // ~28 seconds of SNES time
    static let loopDetectionThreshold = 200     // iterations at same PC = loop

    /// Run a single test ROM and return results
    static func runTest(romPath: String) -> TestResult {
        let name = (romPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".sfc", with: "")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
            return TestResult(name: name, passCount: 0, failCount: 0,
                            totalCycles: 0, stoppedReason: .error("Cannot load ROM"))
        }

        guard let cartridge = try? Cartridge(data: data) else {
            return TestResult(name: name, passCount: 0, failCount: 0,
                            totalCycles: 0, stoppedReason: .error("Invalid ROM header"))
        }

        let bus = Bus(cartridge: cartridge)
        let cpu = CPU(bus: bus)
        cpu.reset()

        var totalCycles: UInt64 = 0
        var scanlineCycles = 0
        var currentScanline = 0
        var lastPC: UInt16 = 0xFFFF
        var samePCCount = 0
        var stoppedReason: StopReason = .cycleLimit

        while totalCycles < maxCycles {
            let currentPC = cpu.regs.PC

            // Detect tight loops
            if currentPC == lastPC {
                samePCCount += 1
                if samePCCount >= loopDetectionThreshold {
                    let failCount = scanVRAMForString(bus.ppu.vram, pattern: failBytes)
                    if failCount > 0 {
                        stoppedReason = .failureDetected
                    } else {
                        stoppedReason = .allTestsPassed
                    }
                    break
                }
            } else {
                samePCCount = 0
                lastPC = currentPC
            }

            // Detect JMP to self (3 bytes: 4C lo hi where target = current PC)
            let fullPC = (UInt32(cpu.regs.PBR) << 16) | UInt32(currentPC)
            let op = bus.read(fullPC)
            if op == 0x4C { // JMP abs
                let lo = bus.read(fullPC + 1)
                let hi = bus.read(fullPC + 2)
                let target = UInt16(hi) << 8 | UInt16(lo)
                if target == currentPC {
                    let failCount = scanVRAMForString(bus.ppu.vram, pattern: failBytes)
                    if failCount > 0 {
                        stoppedReason = .failureDetected
                    } else {
                        stoppedReason = .allTestsPassed
                    }
                    break
                }
            }

            let cycles = cpu.step()
            totalCycles += UInt64(cycles)
            scanlineCycles += cycles

            if cpu.regs.stopped {
                stoppedReason = .cpuStopped
                break
            }

            // Scanline-accurate VBlank timing
            while scanlineCycles >= Timing.cpuCyclesPerScanline {
                scanlineCycles -= Timing.cpuCyclesPerScanline
                currentScanline += 1

                if currentScanline == SNESConstants.vBlankStart {
                    bus.enterVBlank()
                } else if currentScanline >= SNESConstants.scanlinesPerFrame {
                    currentScanline = 0
                    bus.exitVBlank()
                }
            }
        }

        let passCount = scanVRAMForString(bus.ppu.vram, pattern: passBytes)
        let failCount = scanVRAMForString(bus.ppu.vram, pattern: failBytes)

        return TestResult(name: name, passCount: passCount, failCount: failCount,
                         totalCycles: totalCycles, stoppedReason: stoppedReason)
    }

    /// Scan VRAM for ASCII text pattern.
    /// Test ROMs write with VMAIN=0 (increment on low byte), so each character
    /// goes to the low byte of consecutive VRAM words.
    /// In our byte-array VRAM, characters are at even indices (0, 2, 4, 6...).
    static func scanVRAMForString(_ vram: [UInt8], pattern: [UInt8]) -> Int {
        var count = 0
        let patLen = pattern.count

        // Scan even byte addresses (lo bytes of VRAM words)
        let maxStart = vram.count - (patLen * 2)
        guard maxStart > 0 else { return 0 }

        for i in stride(from: 0, to: maxStart, by: 2) {
            var match = true
            for j in 0..<patLen {
                if vram[i + j * 2] != pattern[j] {
                    match = false
                    break
                }
            }
            if match {
                count += 1
            }
        }
        return count
    }

    /// Run all test ROMs in a directory and print results
    static func runAllTests(directory: String) {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(atPath: directory) else {
            print("Cannot read directory: \(directory)")
            return
        }

        let testDirs = subdirs.sorted()
        var totalPass = 0
        var totalFail = 0
        var results: [TestResult] = []

        print(String(repeating: "=", count: 70))
        print("PeterLemon SNES CPU Test Suite")
        print(String(repeating: "=", count: 70))

        for dir in testDirs {
            let dirPath = (directory as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Find .sfc file in subdirectory
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath),
                  let sfcFile = files.first(where: { $0.hasSuffix(".sfc") }) else {
                continue
            }

            let romPath = (dirPath as NSString).appendingPathComponent(sfcFile)
            let result = runTest(romPath: romPath)
            results.append(result)

            let emoji = result.passed ? "+" : "-"
            let paddedName = result.name.padding(toLength: 10, withPad: " ", startingAt: 0)
            print(" [\(emoji)] \(paddedName)  Pass:\(String(format: "%2d", result.passCount))  Fail:\(String(format: "%2d", result.failCount))  Cycles:\(String(format: "%10llu", result.totalCycles))  \(result.stoppedReason)")

            if result.passed {
                totalPass += 1
            } else {
                totalFail += 1
            }
        }

        print(String(repeating: "=", count: 70))
        print("Results: \(totalPass) passed, \(totalFail) failed, \(results.count) total")
        print(String(repeating: "=", count: 70))
    }
}
