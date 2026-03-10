import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @State private var showDebug = false
    @State private var showDisplaySettings = false
    @State private var showInputSettings = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.90, blue: 0.84),
                    Color(red: 0.84, green: 0.88, blue: 0.80)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HSplitView {
                VStack(spacing: 18) {
                    headerPanel
                    displayStage
                    controlDeck
                }
                .padding(20)
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showDebug {
                    debugPanel
                        .padding(.vertical, 20)
                        .padding(.trailing, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button("Open ROM") {
                    openROM()
                }
            }
            ToolbarItem {
                Button("Display") {
                    showDisplaySettings = true
                }
            }
            ToolbarItem {
                Button("Input") {
                    showInputSettings = true
                }
            }
            ToolbarItem {
                Menu("Tools") {
                    Button("Run CPU Tests") {
                        runCPUTests()
                    }
                    Button("Run PPU Test") {
                        DispatchQueue.global(qos: .userInitiated).async {
                            PPUDiagnostic.runAll()
                        }
                    }
                    Button("Benchmark") {
                        viewModel.runBenchmark()
                    }
                    Divider()
                    Button("Save State") {
                        viewModel.saveState()
                    }
                    .keyboardShortcut("1", modifiers: .command)
                    Button("Load State") {
                        viewModel.loadState()
                    }
                    .keyboardShortcut("2", modifiers: .command)
                    Button("Diagnose") {
                        viewModel.diagnoseFreeze()
                    }
                }
            }
            ToolbarItem {
                Toggle("Debug", isOn: $showDebug)
            }
        }
        .sheet(isPresented: $showDisplaySettings) {
            DisplayConfigurationView(
                viewModel: viewModel,
                onToggleFullScreen: toggleFullScreen
            )
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

    private var headerPanel: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MetalSNES")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.13, green: 0.18, blue: 0.18))
                Text(viewModel.romDisplayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.28, green: 0.32, blue: 0.28))
                Text(viewModel.statusText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    MetricPill(label: "Filter", value: viewModel.displayConfiguration.filterMode.displayName)
                    MetricPill(label: "Scale", value: viewModel.displayConfiguration.integerScalingEnabled ? "Integer" : "Fit")
                    MetricPill(label: "Latency", value: viewModel.runAheadFrames == 0 ? "Native" : "1F Run-Ahead")
                }
                Text("Display-linked pacing, pixel framing, and low-latency input.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(panelBackground)
        .overlay(panelStroke)
    }

    private var displayStage: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.03, green: 0.03, blue: 0.04))
                .shadow(color: Color.black.opacity(0.18), radius: 28, x: 0, y: 20)

            EmulatorView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(18)

            HStack(spacing: 8) {
                MetricPill(label: "View", value: viewModel.displayConfiguration.filterMode.displayName)
                MetricPill(label: "Pixels", value: viewModel.displayConfiguration.integerScalingEnabled ? "Locked" : "Adaptive")
                if viewModel.isRunning {
                    MetricPill(label: "State", value: "Live")
                } else {
                    MetricPill(label: "State", value: "Paused")
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var controlDeck: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(viewModel.isRunning ? "Pause" : "Run") {
                    viewModel.toggleEmulation()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.22, green: 0.43, blue: 0.32))
                .keyboardShortcut(.space, modifiers: [])

                Button("Step") {
                    viewModel.step()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunning)
                .keyboardShortcut("s", modifiers: .command)

                Button("Full Screen") {
                    toggleFullScreen()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Toggle full screen (F or Command-Return)")
            }

            Spacer()

            HStack(spacing: 10) {
                Button("Display") {
                    showDisplaySettings = true
                }
                .buttonStyle(.bordered)

                Button("Input") {
                    showInputSettings = true
                }
                .buttonStyle(.bordered)

                Menu("State") {
                    Button("Save State") {
                        viewModel.saveState()
                    }
                    .keyboardShortcut("1", modifiers: .command)
                    Button("Load State") {
                        viewModel.loadState()
                    }
                    .keyboardShortcut("2", modifiers: .command)
                }
            }
        }
        .padding(16)
        .background(panelBackground)
        .overlay(panelStroke)
    }

    private var debugPanel: some View {
        DebugSidebar(debugState: viewModel.debugState, onApplySpriteOverrides: viewModel.applySpriteOverrides)
            .frame(minWidth: 320, idealWidth: 360)
            .background(panelBackground)
            .overlay(panelStroke)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.72))
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
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

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.18, green: 0.23, blue: 0.21))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.75))
        )
    }
}

struct DisplayConfigurationView: View {
    @ObservedObject var viewModel: EmulatorViewModel
    let onToggleFullScreen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                    Text("Pixel framing, fullscreen presentation, post-processing, and latency tuning.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Integer Scaling", isOn: $viewModel.displayConfiguration.integerScalingEnabled)
                    Text("Locks the final pass to whole-number pixel multiples and adds clean letterboxing when needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Filter")
                            .font(.headline)
                        ForEach(DisplayFilterMode.allCases) { mode in
                            DisplayFilterModeCard(
                                mode: mode,
                                isSelected: viewModel.displayConfiguration.filterMode == mode
                            ) {
                                viewModel.displayConfiguration.filterMode = mode
                            }
                        }
                    }
                }
            } label: {
                Text("Screen")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Run Ahead", selection: $viewModel.runAheadFrames) {
                        Text("Off").tag(0)
                        Text("1 Frame").tag(1)
                    }
                    .pickerStyle(.segmented)

                    Text("Run-ahead reduces input latency by speculating one frame ahead. It helps responsiveness, not animation smoothness.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("Latency")
            }

            HStack {
                Button("Toggle Full Screen") {
                    onToggleFullScreen()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Restore Display Defaults") {
                    viewModel.restoreDefaultDisplayConfiguration()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.90),
                    Color(red: 0.88, green: 0.91, blue: 0.86)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct DisplayFilterModeCard: View {
    let mode: DisplayFilterMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(mode.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color(red: 0.22, green: 0.43, blue: 0.32) : .secondary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color(red: 0.88, green: 0.94, blue: 0.88) : Color.white.opacity(0.7))
            )
        }
        .buttonStyle(.plain)
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
