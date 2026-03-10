import SwiftUI
import Combine

final class EmulatorViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var statusText = "Ready"
    @Published var debugState = DebugState()

    lazy var inputManager = InputManager()

    var renderer: MetalRenderer?
    var emulatorCore: EmulatorCore?
    private(set) var romURL: URL?

    private var emulationThread: Thread?
    private var terminationObserver: Any?

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadROM(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var cartridge = try Cartridge(data: data)
            cartridge.romURL = url
            self.romURL = url
            statusText = "Loaded: \(cartridge.title) (\(cartridge.romSizeKB)KB)"
            print("ROM loaded: \(cartridge.title)")
            print("Map mode: \(String(format: "0x%02X", cartridge.mapMode))")
            print("ROM size: \(cartridge.romSizeKB) KB")
            print("SRAM size: \(cartridge.sramSizeKB) KB")

            let core = EmulatorCore(cartridge: cartridge)
            self.emulatorCore = core
            core.renderer = renderer
            core.debugState = debugState
            inputManager.attach(joypad: core.bus.joypad)

            // Load SRAM if a .srm file exists next to the ROM
            let srmURL = core.bus.sramURL(for: url)
            core.bus.loadSRAM(from: srmURL)

            // Save SRAM on app termination
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.saveSRAM()
            }

            let resetVector = core.bus.readWord(bank: 0x00, offset: 0xFFFC)
            print(String(format: "Reset vector: $%04X", resetVector))

        } catch {
            statusText = "Error: \(error.localizedDescription)"
            print("ROM load error: \(error)")
        }
    }

    func saveSRAM() {
        guard let core = emulatorCore, let url = romURL else { return }
        let srmURL = core.bus.sramURL(for: url)
        core.bus.saveSRAM(to: srmURL)
    }

    func toggleEmulation() {
        guard let core = emulatorCore else { return }

        if core.isRunning {
            core.stop()
            isRunning = false
            statusText = "Paused"
            saveSRAM()
        } else {
            core.startDebugServer()
            core.isRunning = true
            isRunning = true
            statusText = "Running"
            emulationThread = Thread {
                core.run()
                DispatchQueue.main.async {
                    self.isRunning = core.isRunning
                    self.statusText = core.isRunning ? "Running" : "Stopped"
                }
            }
            emulationThread?.name = "EmulatorCore"
            emulationThread?.qualityOfService = .userInteractive
            emulationThread?.start()
        }
    }

    func step() {
        guard let core = emulatorCore else { return }
        core.step()
        updateDebugState()
    }

    func updateDebugState() {
        guard let core = emulatorCore else { return }
        core.updateDebugState()
    }

    func runBenchmark() {
        guard let core = emulatorCore else { return }
        if core.isRunning {
            core.stop()
            isRunning = false
        }
        statusText = "Benchmarking..."
        DispatchQueue.global(qos: .userInteractive).async {
            core.benchmark(frames: 120) // 2 seconds worth
            DispatchQueue.main.async {
                self.statusText = "Benchmark complete"
            }
        }
    }

    func applySpriteOverrides() {
        guard let core = emulatorCore else { return }
        let ds = debugState
        let objsel = UInt8((ds.spriteSizeSelect << 5) | (ds.spriteNameGap << 3) | ds.spriteNameBase)
        core.bus.ppu.objsel = objsel
    }

    func diagnoseFreeze() {
        guard let core = emulatorCore else { return }
        core.requestDiagnosis()
    }

    func saveState() {
        guard let core = emulatorCore, let romURL = romURL else {
            statusText = "No ROM loaded"
            return
        }
        let wasRunning = core.isRunning
        if wasRunning {
            core.stop()
            // Wait for emulation thread to finish
            while emulationThread?.isExecuting == true {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        let ss = SaveState()
        let data = ss.save(core: core)
        let stateURL = romURL.deletingPathExtension().appendingPathExtension("state")
        do {
            try data.write(to: stateURL)
            statusText = "State saved (\(data.count / 1024) KB)"
            print("Save state written to \(stateURL.path) (\(data.count) bytes)")
        } catch {
            statusText = "Save failed: \(error.localizedDescription)"
        }

        if wasRunning {
            core.isRunning = true
            isRunning = true
            emulationThread = Thread {
                core.run()
                DispatchQueue.main.async {
                    self.isRunning = core.isRunning
                    self.statusText = core.isRunning ? "Running" : "Stopped"
                }
            }
            emulationThread?.name = "EmulatorCore"
            emulationThread?.qualityOfService = .userInteractive
            emulationThread?.start()
        }
    }

    func loadState(from url: URL? = nil) {
        guard let core = emulatorCore, let romURL = romURL else {
            statusText = "No ROM loaded"
            return
        }
        let wasRunning = core.isRunning
        if wasRunning {
            core.stop()
            while emulationThread?.isExecuting == true {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        let stateURL = url ?? romURL.deletingPathExtension().appendingPathExtension("state")
        do {
            let data = try Data(contentsOf: stateURL)
            let ss = SaveState()
            try ss.restore(from: data, core: core)
            statusText = "State loaded"
            print("Save state loaded from \(stateURL.path)")
            updateDebugState()
        } catch {
            statusText = "Load failed: \(error.localizedDescription)"
        }

        if wasRunning {
            core.isRunning = true
            isRunning = true
            emulationThread = Thread {
                core.run()
                DispatchQueue.main.async {
                    self.isRunning = core.isRunning
                    self.statusText = core.isRunning ? "Running" : "Stopped"
                }
            }
            emulationThread?.name = "EmulatorCore"
            emulationThread?.qualityOfService = .userInteractive
            emulationThread?.start()
        }
    }
}
