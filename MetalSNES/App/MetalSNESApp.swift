import SwiftUI
import MetalKit

@main
struct MetalSNESApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let isHeadlessMode = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--benchmark")
            || args.contains("--benchmark-gpu")
            || args.contains("--benchmark-state")
            || args.contains("--benchmark-state-gpu")
            || args.contains("--benchmark-state-live")
            || args.contains("--benchmark-state-live-gpu")
            || args.contains("--ppu-diagnostic")
            || args.contains("--diagnose-rom")
            || args.contains("--diagnose-state")
            || args.contains("--serve-rom")
            || args.contains("--serve-state")
    }()

    var body: some Scene {
        WindowGroup {
            if isHeadlessMode {
                EmptyView()
            } else {
                ContentView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 820)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var headlessDebugCore: EmulatorCore?

    private func usageError(_ message: String, usage: String) -> Never {
        fputs("\(message)\nUsage: \(usage)\n", stderr)
        exit(2)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let isBenchmarkMode = args.contains("--benchmark") || args.contains("--benchmark-gpu")
        let isStateBenchmarkMode = args.contains("--benchmark-state")
            || args.contains("--benchmark-state-gpu")
            || args.contains("--benchmark-state-live")
            || args.contains("--benchmark-state-live-gpu")
        let isPPUDiagnosticMode = args.contains("--ppu-diagnostic")
        let isROMDiagnosticMode = args.contains("--diagnose-rom")
        let isStateDiagnosticMode = args.contains("--diagnose-state")
        let isServeROMMode = args.contains("--serve-rom")
        let isServeStateMode = args.contains("--serve-state")

        if !isBenchmarkMode && !isStateBenchmarkMode && !isPPUDiagnosticMode && !isROMDiagnosticMode && !isStateDiagnosticMode && !isServeROMMode && !isServeStateMode {
            // Bring window to front when launched from CLI/Xcode
            NSApp.activate(ignoringOtherApps: true)
            // Ensure the first window becomes key so emulation can start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }

        // CLI benchmark mode: --benchmark [rom_path]
        let benchmarkFlag: String?
        if args.contains("--benchmark-gpu") {
            benchmarkFlag = "--benchmark-gpu"
        } else if args.contains("--benchmark") {
            benchmarkFlag = "--benchmark"
        } else {
            benchmarkFlag = nil
        }

        if let benchmarkFlag, let idx = args.firstIndex(of: benchmarkFlag) {
            guard idx + 1 < args.count else {
                usageError("BENCHMARK ERROR: Missing ROM path", usage: "MetalSNES \(benchmarkFlag) <rom_path>")
            }
            let romPath = args[idx + 1]
            let useGPUBenchmark = benchmarkFlag == "--benchmark-gpu"
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: romPath))
                    let cart = try Cartridge(data: data)
                    let core = EmulatorCore(cartridge: cart)
                    if useGPUBenchmark {
                        guard let renderer = MetalRenderer(headlessDevice: MTLCreateSystemDefaultDevice()) else {
                            print("BENCHMARK ERROR: Failed to create headless Metal renderer")
                            exit(1)
                        }
                        core.renderer = renderer
                    }
                    core.benchmark(frames: 120)
                    exit(0)
                } catch {
                    print("BENCHMARK ERROR: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        let stateBenchmarkFlag: String?
        if args.contains("--benchmark-state-live-gpu") {
            stateBenchmarkFlag = "--benchmark-state-live-gpu"
        } else if args.contains("--benchmark-state-live") {
            stateBenchmarkFlag = "--benchmark-state-live"
        } else if args.contains("--benchmark-state-gpu") {
            stateBenchmarkFlag = "--benchmark-state-gpu"
        } else if args.contains("--benchmark-state") {
            stateBenchmarkFlag = "--benchmark-state"
        } else {
            stateBenchmarkFlag = nil
        }

        if let stateBenchmarkFlag, let idx = args.firstIndex(of: stateBenchmarkFlag) {
            guard idx + 2 < args.count else {
                usageError("BENCHMARK ERROR: Missing ROM or state path", usage: "MetalSNES \(stateBenchmarkFlag) <rom_path> <state_path> [frames]")
            }
            let romPath = args[idx + 1]
            let statePath = args[idx + 2]
            let frames = idx + 3 < args.count ? (Int(args[idx + 3]) ?? 120) : 120
            let useGPUBenchmark = stateBenchmarkFlag == "--benchmark-state-gpu"
                || stateBenchmarkFlag == "--benchmark-state-live-gpu"
            let useLiveAudio = stateBenchmarkFlag == "--benchmark-state-live"
                || stateBenchmarkFlag == "--benchmark-state-live-gpu"
            DispatchQueue.global(qos: .userInteractive).async {
                do {
                    let romData = try Data(contentsOf: URL(fileURLWithPath: romPath))
                    let stateData = try Data(contentsOf: URL(fileURLWithPath: statePath))
                    let cart = try Cartridge(data: romData)
                    let core = EmulatorCore(cartridge: cart)
                    if useGPUBenchmark {
                        guard let renderer = MetalRenderer(headlessDevice: MTLCreateSystemDefaultDevice()) else {
                            print("BENCHMARK ERROR: Failed to create headless Metal renderer")
                            exit(1)
                        }
                        core.renderer = renderer
                    }
                    let saveState = SaveState()
                    try saveState.restore(from: stateData, core: core)
                    if useLiveAudio {
                        core.bus.apu.startAudio()
                    }

                    let start = mach_absolute_time()
                    core.runBenchmarkFrames(frames, outputAudio: useLiveAudio)
                    let elapsed = mach_absolute_time() - start
                    let elapsedNs = Timing.machAbsoluteToNanoseconds(elapsed)
                    let elapsedSec = elapsedNs / 1_000_000_000
                    let fps = Double(frames) / elapsedSec
                    print(String(format: "State Benchmark: %d frames in %.3f sec = %.1f FPS (%.1fx realtime)",
                                 frames, elapsedSec, fps, fps / 60.0))
                    print(String(format: "  Final PC: $%02X:%04X  INIDISP=$%02X  TM=$%02X TS=$%02X",
                                 core.cpu.regs.PBR, core.cpu.regs.PC, core.bus.ppu.inidisp, core.bus.ppu.tm, core.bus.ppu.ts))
                    if useLiveAudio {
                        print(String(format: "  Audio buffered=%d underruns=%llu overruns=%llu",
                                     core.bus.apu.audioOutput.bufferedSamples,
                                     core.bus.apu.audioOutput.underrunEvents,
                                     core.bus.apu.audioOutput.overrunEvents))
                        core.bus.apu.stopAudio()
                    }
                    exit(0)
                } catch {
                    print("BENCHMARK ERROR: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        if isPPUDiagnosticMode {
            DispatchQueue.global(qos: .userInteractive).async {
                PPUDiagnostic.runAll()
                exit(0)
            }
        }

        if let idx = args.firstIndex(of: "--diagnose-rom") {
            guard idx + 1 < args.count else {
                usageError("ROM DIAGNOSTIC ERROR: Missing ROM path", usage: "MetalSNES --diagnose-rom <rom_path> [frames]")
            }
            let romPath = args[idx + 1]
            let frames = idx + 2 < args.count ? (Int(args[idx + 2]) ?? 300) : 300
            DispatchQueue.global(qos: .userInteractive).async {
                PPUDiagnostic.runROMTest(romPath: romPath, frames: frames)
                exit(0)
            }
        }

        if let idx = args.firstIndex(of: "--diagnose-state") {
            guard idx + 2 < args.count else {
                usageError("STATE DIAGNOSTIC ERROR: Missing ROM or state path", usage: "MetalSNES --diagnose-state <rom_path> <state_path> [frames]")
            }
            let romPath = args[idx + 1]
            let statePath = args[idx + 2]
            let frames = idx + 3 < args.count ? (Int(args[idx + 3]) ?? 8) : 8
            DispatchQueue.global(qos: .userInteractive).async {
                PPUDiagnostic.runSaveStateTest(romPath: romPath, statePath: statePath, frames: frames)
                exit(0)
            }
        }

        if let idx = args.firstIndex(of: "--serve-rom") {
            guard idx + 1 < args.count else {
                usageError("SERVE ERROR: Missing ROM path", usage: "MetalSNES --serve-rom <rom_path>")
            }
            let romPath = args[idx + 1]
            guard let romData = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
                print("SERVE ERROR: Cannot read ROM at \(romPath)")
                exit(1)
            }
            let cart: Cartridge
            do {
                cart = try Cartridge(data: romData)
            } catch {
                print("SERVE ERROR: \(error.localizedDescription)")
                exit(1)
            }

            let core = EmulatorCore(cartridge: cart)
            core.startDebugServer()
            self.headlessDebugCore = core
            print("SERVE READY: \(romPath)")
            fflush(stdout)
            blockHeadlessServeProcess()
        }

        if let idx = args.firstIndex(of: "--serve-state") {
            guard idx + 2 < args.count else {
                usageError("SERVE ERROR: Missing ROM or state path", usage: "MetalSNES --serve-state <rom_path> <state_path>")
            }
            let romPath = args[idx + 1]
            let statePath = args[idx + 2]
            guard let romData = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
                print("SERVE ERROR: Cannot read ROM at \(romPath)")
                exit(1)
            }
            guard let stateData = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
                print("SERVE ERROR: Cannot read state at \(statePath)")
                exit(1)
            }
            let cart: Cartridge
            do {
                cart = try Cartridge(data: romData)
            } catch {
                print("SERVE ERROR: \(error.localizedDescription)")
                exit(1)
            }

            let core = EmulatorCore(cartridge: cart)
            let saveState = SaveState()
            do {
                try saveState.restore(from: stateData, core: core)
            } catch {
                print("SERVE ERROR: Failed to restore state: \(error.localizedDescription)")
                exit(1)
            }

            core.startDebugServer()
            self.headlessDebugCore = core
            print("SERVE READY: \(romPath) @ \(statePath)")
            fflush(stdout)
            blockHeadlessServeProcess()
        }
    }

    private func blockHeadlessServeProcess() -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        semaphore.wait()
        fatalError("unreachable")
    }
}
