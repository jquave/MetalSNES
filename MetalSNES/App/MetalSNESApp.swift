import SwiftUI
import MetalKit

@main
struct MetalSNESApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let isBenchmarkMode = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--benchmark") || args.contains("--benchmark-gpu")
    }()

    var body: some Scene {
        WindowGroup {
            if isBenchmarkMode {
                EmptyView()
            } else {
                ContentView()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 800, height: 600)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let isBenchmarkMode = args.contains("--benchmark") || args.contains("--benchmark-gpu")

        if !isBenchmarkMode {
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
    }
}
