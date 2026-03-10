import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @State private var showDebug = false
    @State private var showDisplaySettings = false
    @State private var showInputSettings = false
    @State private var trackedWindow: NSWindow?
    @State private var isFullScreen = false
    @State private var headerVisible = true
    @State private var headerHovering = false
    @State private var headerHideWorkItem: DispatchWorkItem?

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
                mainStage
                    .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)

                if showDebug {
                    debugPanel
                        .padding(.vertical, outerPadding)
                        .padding(.trailing, outerPadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            WindowObserver(
                window: $trackedWindow,
                isFullScreen: $isFullScreen,
                onWindowReady: configureWindow
            )
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showInputSettings) {
            InputConfigurationView(inputManager: viewModel.inputManager)
        }
        .onChange(of: showDebug) { _, isShown in
            viewModel.setDebugUIEnabled(isShown)
            if isShown {
                revealHeader()
            }
            refreshHeaderVisibility()
        }
        .onChange(of: viewModel.isRunning) { _, _ in
            refreshHeaderVisibility()
        }
        .onChange(of: showDisplaySettings) { _, isShown in
            if isShown {
                revealHeader()
            }
            refreshHeaderVisibility()
        }
        .onChange(of: showInputSettings) { _, isShown in
            if isShown {
                revealHeader()
            }
            refreshHeaderVisibility()
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

            refreshHeaderVisibility()
        }
    }

    private var mainStage: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous)
                .fill(Color.black)
                .shadow(color: Color.black.opacity(isFullScreen ? 0 : 0.22), radius: 32, x: 0, y: 24)

            EmulatorView(viewModel: viewModel, onToggleFullScreen: toggleFullScreen)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: max(stageCornerRadius - stageInset, 0), style: .continuous))
                .padding(stageInset)

            headerPanel
                .padding(stageHeaderPadding)
                .opacity(headerDisplayVisible ? 1 : 0)
                .offset(y: headerDisplayVisible ? 0 : -30)
                .allowsHitTesting(headerDisplayVisible)

            if showDisplaySettings {
                displayControlPanel
                    .padding(.top, headerDisplayVisible ? 108 : stageHeaderPadding)
                    .padding(.trailing, stageHeaderPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: stageCornerRadius, style: .continuous))
        .padding(outerPadding)
        .frame(maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: headerDisplayVisible)
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                handlePointerActivity()
            case .ended:
                scheduleHeaderHideIfNeeded()
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                handlePointerActivity()
            }
        )
    }

    private var displayControlPanel: some View {
        DisplayConfigurationView(
            viewModel: viewModel,
            onToggleFullScreen: toggleFullScreen,
            onClose: {
                showDisplaySettings = false
                refreshHeaderVisibility()
            }
        )
        .frame(width: min(trackedWindow?.contentLayoutRect.width ?? 420, 440))
        .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 16)
    }

    private var headerPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.romDisplayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                HStack(spacing: 8) {
                    Text("MetalSNES")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(viewModel.statusText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            HStack(spacing: 10) {
                filterMenu
                scaleMenu
                latencyMenu
            }

            HStack(spacing: 8) {
                Button(viewModel.isRunning ? "Pause" : "Run") {
                    viewModel.toggleEmulation()
                    handlePointerActivity()
                }
                .buttonStyle(HeaderActionButtonStyle(prominent: true))
                .keyboardShortcut(.space, modifiers: [])

                Button("Open ROM") {
                    openROM()
                }
                .buttonStyle(HeaderActionButtonStyle())

                Button("Save") {
                    viewModel.saveState()
                    handlePointerActivity()
                }
                .buttonStyle(HeaderActionButtonStyle())
                .keyboardShortcut("1", modifiers: .command)

                Button("Load") {
                    viewModel.loadState()
                    handlePointerActivity()
                }
                .buttonStyle(HeaderActionButtonStyle())
                .keyboardShortcut("2", modifiers: .command)

                Button {
                    toggleFullScreen()
                    handlePointerActivity()
                } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(HeaderIconButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help("Toggle full screen (F or Command-Return)")

                Menu {
                    Button(showDisplaySettings ? "Hide Display Controls" : "Show Display Controls") {
                        toggleDisplaySettings()
                    }
                    Button("Input Settings") {
                        showDisplaySettings = false
                        showInputSettings = true
                    }
                    Divider()
                    Button(showDebug ? "Hide Debug Panel" : "Show Debug Panel") {
                        showDebug.toggle()
                    }
                    Divider()
                    Button("Step") {
                        viewModel.step()
                    }
                    .disabled(viewModel.isRunning)
                    .keyboardShortcut("s", modifiers: .command)
                    Button("Run CPU Tests") {
                        runCPUTests()
                    }
                    Button("Run PPU Test") {
                        runPPUTests()
                    }
                    Button("Benchmark") {
                        viewModel.runBenchmark()
                    }
                    Button("Diagnose") {
                        viewModel.diagnoseFreeze()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(HeaderIconButtonStyle())
                .help("Tools")
            }
        }
        .padding(16)
        .background(HeaderGlassBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 22, x: 0, y: 18)
        .onHover { isHovering in
            headerHovering = isHovering
            if isHovering {
                revealHeader()
            } else {
                scheduleHeaderHideIfNeeded()
            }
        }
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

    private var outerPadding: CGFloat {
        isFullScreen ? 0 : 20
    }

    private var stageInset: CGFloat {
        isFullScreen ? 0 : 16
    }

    private var stageCornerRadius: CGFloat {
        isFullScreen ? 0 : 30
    }

    private var stageHeaderPadding: CGFloat {
        isFullScreen ? 18 : 20
    }

    private var headerDisplayVisible: Bool {
        headerVisible || !shouldAutoHideHeader
    }

    private var shouldAutoHideHeader: Bool {
        viewModel.isRunning && !showDisplaySettings && !showInputSettings
    }

    private var filterMenu: some View {
        Menu {
            ForEach(DisplayFilterMode.allCases) { mode in
                Button {
                    viewModel.displayConfiguration.filterMode = mode
                    handlePointerActivity()
                } label: {
                    HStack {
                        Text(mode.displayName)
                        if viewModel.displayConfiguration.filterMode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button(showDisplaySettings ? "Hide Display Controls" : "Show Display Controls") {
                toggleDisplaySettings()
            }
        } label: {
            HeaderStatusPill(label: "Filter", value: viewModel.displayConfiguration.filterMode.displayName)
        }
        .menuStyle(.borderlessButton)
    }

    private var scaleMenu: some View {
        Menu {
            Button {
                viewModel.displayConfiguration.integerScalingEnabled = true
                handlePointerActivity()
            } label: {
                HStack {
                    Text("Integer")
                    if viewModel.displayConfiguration.integerScalingEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                viewModel.displayConfiguration.integerScalingEnabled = false
                handlePointerActivity()
            } label: {
                HStack {
                    Text("Fit")
                    if !viewModel.displayConfiguration.integerScalingEnabled {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HeaderStatusPill(label: "Scale", value: viewModel.displayConfiguration.integerScalingEnabled ? "Integer" : "Fit")
        }
        .menuStyle(.borderlessButton)
    }

    private var latencyMenu: some View {
        Menu {
            Button {
                viewModel.runAheadFrames = 0
                handlePointerActivity()
            } label: {
                HStack {
                    Text("Native")
                    if viewModel.runAheadFrames == 0 {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                viewModel.runAheadFrames = 1
                handlePointerActivity()
            } label: {
                HStack {
                    Text("1F Run-Ahead")
                    if viewModel.runAheadFrames == 1 {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HeaderStatusPill(label: "Latency", value: viewModel.runAheadFrames == 0 ? "Native" : "1F Run-Ahead")
        }
        .menuStyle(.borderlessButton)
    }

    private func openROM() {
        let shouldResume = viewModel.pauseEmulation()
        let shouldAutoStart = shouldResume || viewModel.emulatorCore == nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false

        let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                viewModel.loadROM(at: url, autoStart: shouldAutoStart)
            } else if shouldResume {
                viewModel.resumeEmulation()
            }
            refreshHeaderVisibility()
        }

        if let trackedWindow {
            panel.beginSheetModal(for: trackedWindow, completionHandler: handleSelection)
        } else {
            handleSelection(panel.runModal())
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

    private func runPPUTests() {
        DispatchQueue.global(qos: .userInitiated).async {
            PPUDiagnostic.runAll()
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
        (trackedWindow ?? NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }

    private func toggleDisplaySettings() {
        if showDisplaySettings {
            showDisplaySettings = false
        } else {
            showDisplaySettings = true
            revealHeader()
        }
        refreshHeaderVisibility()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
    }

    private func handlePointerActivity() {
        revealHeader()
        scheduleHeaderHideIfNeeded()
    }

    private func revealHeader() {
        cancelHeaderHide()
        if !headerVisible {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                headerVisible = true
            }
        }
    }

    private func refreshHeaderVisibility() {
        if shouldAutoHideHeader {
            scheduleHeaderHideIfNeeded()
        } else {
            revealHeader()
        }
    }

    private func scheduleHeaderHideIfNeeded() {
        cancelHeaderHide()
        guard shouldAutoHideHeader, !headerHovering else {
            return
        }

        let workItem = DispatchWorkItem {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                headerVisible = false
            }
        }
        headerHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: workItem)
    }

    private func cancelHeaderHide() {
        headerHideWorkItem?.cancel()
        headerHideWorkItem = nil
    }
}

struct HeaderStatusPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
        )
    }
}

struct HeaderGlassBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.34))
            )
    }
}

struct HeaderActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(prominent ? Color(red: 0.23, green: 0.52, blue: 0.38) : Color.white.opacity(configuration.isPressed ? 0.20 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct HeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.20 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct WindowObserver: NSViewRepresentable {
    @Binding var window: NSWindow?
    @Binding var isFullScreen: Bool
    let onWindowReady: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    final class Coordinator {
        var parent: WindowObserver
        private weak var observedWindow: NSWindow?
        private var observers: [Any] = []

        init(_ parent: WindowObserver) {
            self.parent = parent
        }

        deinit {
            removeObservers()
        }

        func attach(to window: NSWindow?) {
            guard let window else {
                return
            }

            if observedWindow === window {
                updateBindings(for: window)
                return
            }

            removeObservers()
            observedWindow = window
            observe(window)
            updateBindings(for: window)
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.updateBindings(for: window)
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.updateBindings(for: window)
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.updateBindings(for: window)
                }
            ]
        }

        private func updateBindings(for window: NSWindow) {
            parent.window = window
            parent.isFullScreen = window.styleMask.contains(.fullScreen)
            parent.onWindowReady(window)
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }
    }
}

struct DisplayConfigurationView: View {
    @ObservedObject var viewModel: EmulatorViewModel
    let onToggleFullScreen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display Controls")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                    Text("Tune the live image without covering the game.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.bordered)
                .help("Close display controls")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle("Integer Scaling", isOn: $viewModel.displayConfiguration.integerScalingEnabled)
                            Text("Locks the final pass to whole-number pixel multiples and adds clean letterboxing when needed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("Screen")
                    }

                    GroupBox {
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
                    } label: {
                        Text("Filter")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            DisplayAdjustmentSlider(
                                title: "Brightness",
                                value: binding(for: \.brightness),
                                range: 0.4...2.2,
                                valueLabel: percentageLabel(for: binding(for: \.brightness).wrappedValue),
                                detail: "Global luminance. On Aperture Bloom and Trinitron, higher brightness also drives more glow and bloom."
                            )

                            DisplayAdjustmentSlider(
                                title: "Contrast",
                                value: binding(for: \.contrast),
                                range: 0.4...2.0,
                                valueLabel: percentageLabel(for: binding(for: \.contrast).wrappedValue),
                                detail: "Expands or compresses the light-dark separation after filtering."
                            )

                            DisplayAdjustmentSlider(
                                title: "Sharpness",
                                value: binding(for: \.sharpness),
                                range: 0.5...1.8,
                                valueLabel: percentageLabel(for: binding(for: \.sharpness).wrappedValue),
                                detail: "Adjusts beam focus and edge crispness across the post-processing filters."
                            )

                            DisplayAdjustmentSlider(
                                title: "Saturation",
                                value: binding(for: \.saturation),
                                range: 0.0...2.0,
                                valueLabel: percentageLabel(for: binding(for: \.saturation).wrappedValue),
                                detail: "Controls color intensity from grayscale to heavily boosted phosphor color."
                            )
                        }
                    } label: {
                        Text("Image")
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
                }
            }
            .frame(maxHeight: 520)

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
        .padding(18)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.38))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private func binding(for keyPath: WritableKeyPath<DisplayConfiguration, Float>) -> Binding<Double> {
        Binding(
            get: {
                Double(viewModel.displayConfiguration[keyPath: keyPath])
            },
            set: { newValue in
                viewModel.displayConfiguration[keyPath: keyPath] = Float(newValue)
            }
        )
    }

    private func percentageLabel(for value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
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

struct DisplayAdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.58))
        )
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
