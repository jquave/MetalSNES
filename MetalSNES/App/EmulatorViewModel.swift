import SwiftUI
import Combine

final class EmulatorViewModel: ObservableObject {
    private static let runAheadFramesKey = "MetalSNES.runAheadFrames"
    private static let defaultRunAheadFrames = 1
    private static let displayConfigurationKey = "MetalSNES.displayConfiguration"

    @Published var isRunning = false
    @Published var statusText = "Ready"
    @Published var debugState = DebugState()
    @Published var displayConfiguration: DisplayConfiguration {
        didSet {
            persistDisplayConfiguration()
            renderer?.applyDisplayConfiguration(displayConfiguration)
        }
    }
    @Published var runAheadFrames: Int {
        didSet {
            let clamped = Self.clampRunAheadFrames(runAheadFrames)
            guard clamped == runAheadFrames else {
                runAheadFrames = clamped
                return
            }
            userDefaults.set(clamped, forKey: Self.runAheadFramesKey)
            emulatorCore?.runAheadFrames = clamped
        }
    }

    lazy var inputManager = InputManager()

    var renderer: MetalRenderer? {
        didSet {
            renderer?.applyDisplayConfiguration(displayConfiguration)
        }
    }
    var emulatorCore: EmulatorCore?
    private(set) var romURL: URL?
    private var debugUIEnabled = false
    private let userDefaults: UserDefaults

    private var emulationThread: Thread?
    private var terminationObserver: Any?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.displayConfiguration = Self.loadDisplayConfiguration(from: userDefaults)
        let initialRunAheadFrames = Self.initialRunAheadFrames(from: userDefaults)
        self.runAheadFrames = initialRunAheadFrames
        if Self.commandLineRunAheadFrames() == nil,
           userDefaults.object(forKey: Self.runAheadFramesKey) == nil {
            userDefaults.set(initialRunAheadFrames, forKey: Self.runAheadFramesKey)
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadROM(at url: URL, autoStart: Bool? = nil) {
        let shouldAutoStart = autoStart ?? (isRunning || emulatorCore == nil)
        shutdownCurrentSession()
        renderer?.clearToBlack()

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
            core.debugSnapshotsEnabled = debugUIEnabled
            core.runAheadFrames = runAheadFrames
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

            if shouldAutoStart {
                resumeEmulation()
            }
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
            _ = pauseEmulation()
        } else {
            resumeEmulation()
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

    func setDebugUIEnabled(_ enabled: Bool) {
        debugUIEnabled = enabled
        emulatorCore?.debugSnapshotsEnabled = enabled
        if enabled {
            updateDebugState()
        }
    }

    func runBenchmark() {
        guard let core = emulatorCore else { return }
        _ = pauseEmulation()
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

    @discardableResult
    func pauseEmulation() -> Bool {
        guard emulatorCore != nil else {
            return false
        }

        let wasRunning = emulatorCore?.isRunning ?? false
        if wasRunning {
            emulatorCore?.stop()
        }
        waitForEmulationThreadToFinish()

        if wasRunning {
            isRunning = false
            statusText = "Paused"
            saveSRAM()
        } else {
            isRunning = false
        }

        return wasRunning
    }

    func resumeEmulation() {
        guard let core = emulatorCore, !core.isRunning else { return }
        startEmulationThread(for: core)
    }

    func saveState() {
        guard let core = emulatorCore, let romURL = romURL else {
            statusText = "No ROM loaded"
            return
        }
        let wasRunning = pauseEmulation()

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
            resumeEmulation()
        }
    }

    func loadState(from url: URL? = nil) {
        guard let core = emulatorCore, let romURL = romURL else {
            statusText = "No ROM loaded"
            return
        }
        let wasRunning = pauseEmulation()

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
            resumeEmulation()
        }
    }

    var romDisplayName: String {
        if let romURL {
            return romURL.deletingPathExtension().lastPathComponent
        }
        return "No ROM Loaded"
    }

    func restoreDefaultDisplayConfiguration() {
        displayConfiguration = .default
    }

    private static func clampRunAheadFrames(_ value: Int) -> Int {
        min(max(value, 0), 1)
    }

    private func shutdownCurrentSession() {
        guard emulatorCore != nil else {
            return
        }

        emulatorCore?.stop()
        waitForEmulationThreadToFinish()
        if romURL != nil {
            saveSRAM()
        }
        emulatorCore?.renderer = nil
        emulatorCore = nil
        romURL = nil
        isRunning = false
        inputManager.attach(joypad: nil)

        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
    }

    private func waitForEmulationThreadToFinish() {
        while emulationThread?.isExecuting == true {
            Thread.sleep(forTimeInterval: 0.001)
        }
        emulationThread = nil
    }

    private func startEmulationThread(for core: EmulatorCore) {
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

    private func persistDisplayConfiguration() {
        guard let data = try? JSONEncoder().encode(displayConfiguration) else {
            return
        }
        userDefaults.set(data, forKey: Self.displayConfigurationKey)
    }

    private static func initialRunAheadFrames(from userDefaults: UserDefaults) -> Int {
        if let override = commandLineRunAheadFrames() {
            return override
        }
        guard let storedValue = userDefaults.object(forKey: runAheadFramesKey) as? Int else {
            return defaultRunAheadFrames
        }
        return clampRunAheadFrames(storedValue)
    }

    private static func commandLineRunAheadFrames() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--run-ahead"), index + 1 < args.count else {
            return nil
        }
        guard let value = Int(args[index + 1]) else {
            return nil
        }
        return clampRunAheadFrames(value)
    }

    private static func loadDisplayConfiguration(from userDefaults: UserDefaults) -> DisplayConfiguration {
        guard
            let data = userDefaults.data(forKey: displayConfigurationKey),
            let configuration = try? JSONDecoder().decode(DisplayConfiguration.self, from: data)
        else {
            return .default
        }
        return configuration
    }
}
