import SwiftUI
import MetalKit

@main
struct MetalSNESApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let isHeadlessMode = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--benchmark")
            || args.contains("--benchmark-gpu")
            || args.contains("--diagnose-state")
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let isBenchmarkMode = args.contains("--benchmark") || args.contains("--benchmark-gpu")
        let isStateDiagnosticMode = args.contains("--diagnose-state")
        let isServeStateMode = args.contains("--serve-state")

        if !isBenchmarkMode && !isStateDiagnosticMode && !isServeStateMode {
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
            let romPath: String
            if idx + 1 < args.count {
                romPath = args[idx + 1]
            } else {
                romPath = NSHomeDirectory() + "/src/MetalSNES/mario.sfc"
            }
            let useGPUBenchmark = benchmarkFlag == "--benchmark-gpu"
            DispatchQueue.global(qos: .userInteractive).async {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
                    print("BENCHMARK ERROR: Cannot read ROM at \(romPath)")
                    exit(1)
                }
                let cart = try! Cartridge(data: data)
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
            }
        }

        if let idx = args.firstIndex(of: "--diagnose-state") {
            let romPath = idx + 1 < args.count ? args[idx + 1] : NSHomeDirectory() + "/src/MetalSNES/zelda.sfc"
            let statePath = idx + 2 < args.count ? args[idx + 2] : NSHomeDirectory() + "/src/MetalSNES/zelda.state"
            let frames = idx + 3 < args.count ? (Int(args[idx + 3]) ?? 8) : 8
            DispatchQueue.global(qos: .userInteractive).async {
                PPUDiagnostic.runSaveStateTest(romPath: romPath, statePath: statePath, frames: frames)
                exit(0)
            }
        }

        if let idx = args.firstIndex(of: "--serve-state") {
            let romPath = idx + 1 < args.count ? args[idx + 1] : NSHomeDirectory() + "/src/MetalSNES/zelda.sfc"
            let statePath = idx + 2 < args.count ? args[idx + 2] : NSHomeDirectory() + "/src/MetalSNES/zelda.state"
            guard let romData = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
                print("SERVE ERROR: Cannot read ROM at \(romPath)")
                exit(1)
            }
            guard let stateData = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
                print("SERVE ERROR: Cannot read state at \(statePath)")
                exit(1)
            }
            guard let cart = try? Cartridge(data: romData) else {
                print("SERVE ERROR: Cannot parse ROM")
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
        }
    }
}
