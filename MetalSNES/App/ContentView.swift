import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @State private var showDebug = false
    @State private var showInputSettings = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                EmulatorView(viewModel: viewModel)
                    .aspectRatio(CGFloat(SNESConstants.screenWidth) / CGFloat(SNESConstants.screenHeight), contentMode: .fit)
                    .frame(minWidth: 512, minHeight: 448)

                HStack {
                    Text(viewModel.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(viewModel.isRunning ? "Pause" : "Run") {
                        viewModel.toggleEmulation()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Button("Step") {
                        viewModel.step()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(viewModel.isRunning)
                }
                .padding(8)
            }

            if showDebug {
                DebugSidebar(debugState: viewModel.debugState, onApplySpriteOverrides: viewModel.applySpriteOverrides)
                    .frame(minWidth: 300, idealWidth: 350)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Open ROM") {
                    openROM()
                }
            }
            ToolbarItem {
                Button("Run CPU Tests") {
                    runCPUTests()
                }
            }
            ToolbarItem {
                Button("Run PPU Test") {
                    DispatchQueue.global(qos: .userInitiated).async {
                        PPUDiagnostic.runAll()
                    }
                }
            }
            ToolbarItem {
                Button("Benchmark") {
                    viewModel.runBenchmark()
                }
            }
            ToolbarItem {
                Button("Save State") {
                    viewModel.saveState()
                }
                .keyboardShortcut("1", modifiers: .command)
            }
            ToolbarItem {
                Button("Load State") {
                    viewModel.loadState()
                }
                .keyboardShortcut("2", modifiers: .command)
            }
            ToolbarItem {
                Button("Diagnose") {
                    viewModel.diagnoseFreeze()
                }
            }
            ToolbarItem {
                Button("Input") {
                    showInputSettings = true
                }
            }
            ToolbarItem {
                Menu("Latency") {
                    Picker("Run Ahead", selection: $viewModel.runAheadFrames) {
                        Text("Off").tag(0)
                        Text("1 Frame").tag(1)
                    }
                    Text("Run-ahead cuts input latency, not frame pacing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            ToolbarItem {
                Toggle("Debug", isOn: $showDebug)
            }
        }
        .sheet(isPresented: $showInputSettings) {
            InputConfigurationView(inputManager: viewModel.inputManager)
        }
        .onChange(of: showDebug) { _, isShown in
            viewModel.setDebugUIEnabled(isShown)
        }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let romIdx = args.firstIndex(of: "--rom"), romIdx + 1 < args.count {
                let romPath = args[romIdx + 1]
                viewModel.loadROM(at: URL(fileURLWithPath: romPath))
            } else {
                loadDefaultROM()
            }

            // Check for --state argument
            if let stateIdx = args.firstIndex(of: "--state"), stateIdx + 1 < args.count {
                let statePath = args[stateIdx + 1]
                let stateURL = URL(fileURLWithPath: statePath)
                // Load state after a short delay to ensure ROM is loaded
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if viewModel.emulatorCore != nil {
                        viewModel.loadState(from: stateURL)
                        if !viewModel.isRunning {
                            viewModel.toggleEmulation()
                        }
                    }
                }
            } else {
                // Auto-start emulation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if viewModel.emulatorCore != nil && !viewModel.isRunning {
                        viewModel.toggleEmulation()
                    }
                }
            }
        }
    }

    private func openROM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadROM(at: url)
        }
    }

    private func runCPUTests() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Look for test ROMs
            let candidates = [
                "\(NSHomeDirectory())/src/MetalSNES/TestROMs/PeterLemon/CPUTest/CPU",
                "\(FileManager.default.currentDirectoryPath)/TestROMs/PeterLemon/CPUTest/CPU",
            ]
            for path in candidates {
                if FileManager.default.fileExists(atPath: path) {
                    CPUTestRunner.runAllTests(directory: path)
                    return
                }
            }
            print("Test ROMs not found. Clone PeterLemon/SNES into TestROMs/PeterLemon/")
        }
    }

    private func loadDefaultROM() {
        let bundlePath = Bundle.main.bundlePath
        let projectDir = (bundlePath as NSString)
            .deletingLastPathComponent
            .replacingOccurrences(of: "/Build/Products/Debug", with: "")
        // Try to load game.sfc from the project root
        let candidates = [
            "\(projectDir)/game.sfc",
            "\(NSHomeDirectory())/src/MetalSNES/game.sfc",
            "\(FileManager.default.currentDirectoryPath)/game.sfc",
            "\(projectDir)/mario.sfc",
            "\(NSHomeDirectory())/src/MetalSNES/mario.sfc",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                viewModel.loadROM(at: URL(fileURLWithPath: path))
                return
            }
        }
    }
}

struct InputConfigurationView: View {
    @ObservedObject var inputManager: InputManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Settings")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Configure one keyboard key and one controller input for each SNES button.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") {
                    inputManager.cancelCapture()
                    dismiss()
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if inputManager.connectedControllers.isEmpty {
                        Text("No controllers connected.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(inputManager.connectedControllers) { controller in
                            HStack {
                                Text(controller.name)
                                Spacer()
                                Text(controller.profileName)
                                    .foregroundColor(controller.isSupported ? .secondary : .red)
                            }
                        }
                    }

                    HStack {
                        Button("Discover Controllers") {
                            inputManager.discoverControllers()
                        }
                        Spacer()
                        if let captureRequest = inputManager.captureRequest {
                            Text(captureRequest.prompt)
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } label: {
                Text("Controllers")
            }

            HStack(spacing: 12) {
                Text("Button")
                    .frame(width: 90, alignment: .leading)
                Text("Keyboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Gamepad")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SNESButton.allCases) { button in
                        InputBindingRow(button: button, inputManager: inputManager)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Restore Defaults") {
                    inputManager.restoreDefaults()
                }
                Spacer()
                if inputManager.captureRequest != nil {
                    Button("Cancel Capture") {
                        inputManager.cancelCapture()
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .background(
            KeyboardCaptureMonitor(
                isActive: inputManager.captureRequest?.mode == .keyboard,
                onKeyDown: { _ = inputManager.handleKeyDown($0) },
                onFlagsChanged: { _ = inputManager.handleFlagsChanged($0) }
            )
            .frame(width: 0, height: 0)
        )
        .onDisappear {
            inputManager.cancelCapture()
        }
    }
}

struct InputBindingRow: View {
    let button: SNESButton
    @ObservedObject var inputManager: InputManager

    var body: some View {
        HStack(spacing: 12) {
            Text(button.displayName)
                .frame(width: 90, alignment: .leading)

            HStack(spacing: 8) {
                Text(inputManager.keyboardBindingLabel(for: button))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(inputManager.isCapturing(button, mode: .keyboard) ? "Press Key..." : "Bind Key") {
                    inputManager.beginKeyboardCapture(for: button)
                }
                Button("Clear") {
                    inputManager.clearKeyboardBinding(for: button)
                }
                .disabled(inputManager.configuration.keyboardBinding(for: button) == nil)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Text(inputManager.gamepadBindingLabel(for: button))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(inputManager.isCapturing(button, mode: .gamepad) ? "Press Button..." : "Bind Pad") {
                    inputManager.beginGamepadCapture(for: button)
                }
                Button("Clear") {
                    inputManager.clearGamepadBinding(for: button)
                }
                .disabled(inputManager.configuration.gamepadBinding(for: button) == nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 2)
    }
}

struct KeyboardCaptureMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Void
    let onFlagsChanged: (NSEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyDown: onKeyDown, onFlagsChanged: onFlagsChanged)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isActive: isActive)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.update(isActive: false)
    }

    final class Coordinator {
        private let onKeyDown: (NSEvent) -> Void
        private let onFlagsChanged: (NSEvent) -> Void
        private var monitor: Any?

        init(onKeyDown: @escaping (NSEvent) -> Void, onFlagsChanged: @escaping (NSEvent) -> Void) {
            self.onKeyDown = onKeyDown
            self.onFlagsChanged = onFlagsChanged
        }

        func update(isActive: Bool) {
            if isActive {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    guard let self else { return event }
                    switch event.type {
                    case .keyDown:
                        self.onKeyDown(event)
                        return nil
                    case .flagsChanged:
                        self.onFlagsChanged(event)
                        return nil
                    default:
                        return event
                    }
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct DebugSidebar: View {
    @ObservedObject var debugState: DebugState
    var onApplySpriteOverrides: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PacingDebugView(debugState: debugState)
                Divider()
                RegisterView(debugState: debugState)
                Divider()
                PPURegisterView(debugState: debugState)
                Divider()
                SpriteDebugView(debugState: debugState, onApply: onApplySpriteOverrides)
                Divider()
                VRAMTileViewer(debugState: debugState)
                Divider()
                DisassemblerView(debugState: debugState)
                Divider()
                MemoryViewer(debugState: debugState)
            }
            .padding()
        }
    }
}

struct PacingDebugView: View {
    @ObservedObject var debugState: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pacing")
                .font(.headline)
            Text(String(format: "Display avg %.3f ms, worst %.3f ms",
                        debugState.pacingAverageDisplayIntervalMs,
                        debugState.pacingWorstDisplayIntervalMs))
            Text(String(format: "Frame age avg %.3f ms, worst %.3f ms",
                        debugState.pacingAverageFrameAgeMs,
                        debugState.pacingWorstFrameAgeMs))
            Text("Frames produced/presented: \(debugState.pacingProducedFrames)/\(debugState.pacingPresentedFrames)")
            Text("Repeated/dropped presents: \(debugState.pacingRepeatedFrames)/\(debugState.pacingDroppedFrames)")
            Text(String(format: "Audio buffered %d, correction %.3f ms",
                        debugState.pacingAudioBufferedSamples,
                        debugState.pacingAudioCorrectionMs))
            Text("Audio underruns/overruns: \(debugState.pacingAudioUnderruns)/\(debugState.pacingAudioOverruns)")
        }
    }
}
