import SwiftUI

struct ContentView: View {
    private enum HeaderLayoutMode {
        case regular
        case medium
        case compact
    }

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
        .frame(width: displayControlPanelWidth)
        .shadow(color: Color.black.opacity(0.28), radius: 20, x: 0, y: 16)
    }

    private var headerPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.romDisplayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("MetalSNES")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(viewModel.statusText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: headerTitleMaxWidth, alignment: .leading)
            .frame(height: 46, alignment: .leading)
            .background(WindowDragHandle())
            .contentShape(Rectangle())

            HStack(spacing: headerLayoutMode == .compact ? 8 : 10) {
                headerStatusCluster
                    .fixedSize(horizontal: true, vertical: false)
                headerActionCluster
                    .fixedSize(horizontal: true, vertical: false)
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

    private var displayControlPanelWidth: CGFloat {
        let windowWidth = trackedWindow?.contentLayoutRect.width ?? 980
        if viewModel.displayConfiguration.filterMode == .phosphorHot {
            return min(max(windowWidth * 0.46, 430), 520)
        }
        return min(max(windowWidth * 0.36, 340), 430)
    }

    private var headerTitleMaxWidth: CGFloat {
        switch headerLayoutMode {
        case .regular:
            return .infinity
        case .medium:
            return 150
        case .compact:
            return 120
        }
    }

    private var headerDisplayVisible: Bool {
        headerVisible || !shouldAutoHideHeader
    }

    private var headerLayoutMode: HeaderLayoutMode {
        let width = trackedWindow?.contentLayoutRect.width ?? 1280
        if width < 980 {
            return .compact
        }
        if width < 1220 {
            return .medium
        }
        return .regular
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
            if headerLayoutMode == .regular {
                HeaderStatusPill(
                    label: "Filter",
                    value: viewModel.displayConfiguration.filterMode.displayName,
                    compact: false
                )
            } else {
                HeaderMenuChip(title: "Filter")
            }
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
            if headerLayoutMode == .regular {
                HeaderStatusPill(
                    label: "Scale",
                    value: viewModel.displayConfiguration.integerScalingEnabled ? "Integer" : "Fit",
                    compact: false
                )
            } else {
                HeaderMenuChip(title: "Scale")
            }
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
            if headerLayoutMode == .regular {
                HeaderStatusPill(
                    label: "Latency",
                    value: viewModel.runAheadFrames == 0 ? "Native" : "1F Run-Ahead",
                    compact: false
                )
            } else {
                HeaderMenuChip(title: "Latency")
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var displaySummaryMenu: some View {
        Menu {
            Section("Filter") {
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
            }

            Divider()

            Section("Scale") {
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
            }

            Divider()

            Button(showDisplaySettings ? "Hide Image Tuner" : "Show Image Tuner") {
                toggleDisplaySettings()
            }
        } label: {
            HeaderMenuChip(title: "Display")
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private var headerStatusCluster: some View {
        switch headerLayoutMode {
        case .regular:
            HStack(spacing: 10) {
                filterMenu
                scaleMenu
                latencyMenu
            }
        case .medium:
            HStack(spacing: 8) {
                displaySummaryMenu
                latencyMenu
            }
        case .compact:
            HStack(spacing: 8) {
                displaySummaryMenu
                latencyMenu
            }
        }
    }

    @ViewBuilder
    private var headerActionCluster: some View {
        switch headerLayoutMode {
        case .regular:
            HStack(spacing: 8) {
                runButton(compact: false)
                openButton(style: .regular)
                saveButton(style: .regular)
                loadButton(style: .regular)
                fullScreenButton
                toolsMenuButton
            }
        case .medium:
            HStack(spacing: 8) {
                runButton(compact: false)
                openButton(style: .medium)
                saveButton(style: .compact)
                loadButton(style: .compact)
                fullScreenButton
                toolsMenuButton
            }
        case .compact:
            HStack(spacing: 6) {
                runButton(compact: true)
                openButton(style: .compact)
                saveButton(style: .compact)
                loadButton(style: .compact)
                fullScreenButton
                toolsMenuButton
            }
        }
    }

    private enum HeaderActionMode {
        case regular
        case medium
        case compact
    }

    private func runButton(compact: Bool) -> some View {
        Button(viewModel.isRunning ? "Pause" : "Run") {
            viewModel.toggleEmulation()
            handlePointerActivity()
        }
        .buttonStyle(HeaderActionButtonStyle(prominent: true, compact: compact))
        .keyboardShortcut(.space, modifiers: [])
    }

    @ViewBuilder
    private func openButton(style: HeaderActionMode) -> some View {
        switch style {
        case .regular:
            Button("Open ROM") {
                openROM()
            }
            .buttonStyle(HeaderActionButtonStyle())
        case .medium:
            Button {
                openROM()
            } label: {
                HeaderActionLabel(title: "Open", systemImage: "folder")
            }
            .buttonStyle(HeaderActionButtonStyle())
        case .compact:
            Button {
                openROM()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(HeaderIconButtonStyle())
            .help("Open ROM")
        }
    }

    @ViewBuilder
    private func saveButton(style: HeaderActionMode) -> some View {
        switch style {
        case .regular:
            Button("Save") {
                viewModel.saveState()
                handlePointerActivity()
            }
            .buttonStyle(HeaderActionButtonStyle())
            .keyboardShortcut("1", modifiers: .command)
        case .medium, .compact:
            Button {
                viewModel.saveState()
                handlePointerActivity()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(HeaderIconButtonStyle())
            .keyboardShortcut("1", modifiers: .command)
            .help("Save state")
        }
    }

    @ViewBuilder
    private func loadButton(style: HeaderActionMode) -> some View {
        switch style {
        case .regular:
            Button("Load") {
                viewModel.loadState()
                handlePointerActivity()
            }
            .buttonStyle(HeaderActionButtonStyle())
            .keyboardShortcut("2", modifiers: .command)
        case .medium, .compact:
            Button {
                viewModel.loadState()
                handlePointerActivity()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
            }
            .buttonStyle(HeaderIconButtonStyle())
            .keyboardShortcut("2", modifiers: .command)
            .help("Load state")
        }
    }

    private var fullScreenButton: some View {
        Button {
            toggleFullScreen()
            handlePointerActivity()
        } label: {
            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(HeaderIconButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .help("Toggle full screen (F or Command-Return)")
    }

    private var toolsMenuButton: some View {
        Menu {
            Button(showDisplaySettings ? "Hide Image Tuner" : "Show Image Tuner") {
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
        window.isMovableByWindowBackground = false
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
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.55))
            Text(value)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 7 : 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
        )
    }
}

struct HeaderMenuChip: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.62))
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
        )
        .fixedSize(horizontal: true, vertical: false)
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
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 8 : 9)
            .background(
                Capsule()
                    .fill(prominent ? Color(red: 0.23, green: 0.52, blue: 0.38) : Color.white.opacity(configuration.isPressed ? 0.20 : 0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct HeaderActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .lineLimit(1)
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

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    final class DragHandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct DisplayConfigurationView: View {
    @ObservedObject var viewModel: EmulatorViewModel
    let onToggleFullScreen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image Tuner")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Per-filter tuning")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.10))
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(DisplayFilterMode.allCases) { mode in
                            Button {
                                viewModel.displayConfiguration.filterMode = mode
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
                    } label: {
                        DisplayTunerChip(
                            title: "Filter",
                            value: viewModel.displayConfiguration.filterMode.displayName,
                            systemImage: "sparkles.tv"
                        )
                    }
                    .menuStyle(.borderlessButton)

                    Button {
                        viewModel.displayConfiguration.integerScalingEnabled.toggle()
                    } label: {
                        DisplayTunerChip(
                            title: "Scale",
                            value: viewModel.displayConfiguration.integerScalingEnabled ? "Integer" : "Fit",
                            systemImage: "rectangle.compress.vertical"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.restoreCurrentDisplayProfile()
                    } label: {
                        DisplayTunerChip(
                            title: "Reset",
                            value: "This Filter",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onToggleFullScreen()
                    } label: {
                        DisplayTunerChip(
                            title: "Window",
                            value: "Fullscreen",
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DisplayDialControl(
                        title: "Brightness",
                        value: binding(for: \.brightness),
                        range: 0.4...2.2,
                        defaultValue: 1.0,
                        accent: Color(red: 0.96, green: 0.73, blue: 0.28),
                        valueLabel: percentageLabel(for: binding(for: \.brightness).wrappedValue)
                    )
                    DisplayDialControl(
                        title: "Contrast",
                        value: binding(for: \.contrast),
                        range: 0.4...2.0,
                        defaultValue: 1.0,
                        accent: Color(red: 0.91, green: 0.46, blue: 0.26),
                        valueLabel: percentageLabel(for: binding(for: \.contrast).wrappedValue)
                    )
                    DisplayDialControl(
                        title: "Sharpness",
                        value: binding(for: \.sharpness),
                        range: 0.5...1.8,
                        defaultValue: 1.0,
                        accent: Color(red: 0.42, green: 0.76, blue: 0.90),
                        valueLabel: percentageLabel(for: binding(for: \.sharpness).wrappedValue)
                    )
                    DisplayDialControl(
                        title: "Saturation",
                        value: binding(for: \.saturation),
                        range: 0.0...2.0,
                        defaultValue: 1.0,
                        accent: Color(red: 0.66, green: 0.54, blue: 0.92),
                        valueLabel: percentageLabel(for: binding(for: \.saturation).wrappedValue)
                    )

                    if viewModel.displayConfiguration.filterMode == .phosphorHot {
                        DisplayDialControl(
                            title: "Glow",
                            value: binding(for: \.glowAmount),
                            range: 0.25...2.0,
                            defaultValue: 1.0,
                            accent: Color(red: 0.68, green: 0.96, blue: 0.78),
                            valueLabel: percentageLabel(for: binding(for: \.glowAmount).wrappedValue)
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.58))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func binding(for keyPath: WritableKeyPath<DisplayAdjustmentProfile, Float>) -> Binding<Double> {
        Binding(
            get: {
                Double(viewModel.displayConfiguration.activeAdjustment[keyPath: keyPath])
            },
            set: { newValue in
                var configuration = viewModel.displayConfiguration
                var profile = configuration.activeAdjustment
                profile[keyPath: keyPath] = Float(newValue)
                configuration.activeAdjustment = profile
                viewModel.displayConfiguration = configuration
            }
        )
    }

    private func percentageLabel(for value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct DisplayTunerChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.88))
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.52))
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(width: 110, alignment: .leading)
        .frame(minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
    }
}

struct DisplayDialControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let accent: Color
    let valueLabel: String

    @State private var dragStartValue: Double?

    private var normalizedValue: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private var indicatorAngle: Angle {
        .degrees(-135 + normalizedValue * 270)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.40)
                            ],
                            center: .topLeading,
                            startRadius: 8,
                            endRadius: 42
                        )
                    )

                Circle()
                    .trim(from: 0.125, to: 0.875)
                    .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))

                Circle()
                    .trim(from: 0.125, to: 0.125 + normalizedValue * 0.75)
                    .stroke(accent.opacity(0.96), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .shadow(color: accent.opacity(0.38), radius: 4, x: 0, y: 0)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.16, blue: 0.17),
                                Color(red: 0.07, green: 0.07, blue: 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .padding(10)

                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: 4, height: 16)
                    .offset(y: -14)
                    .rotationEffect(indicatorAngle)
                    .shadow(color: accent.opacity(0.45), radius: 3, x: 0, y: 0)

                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 8, height: 8)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let span = range.upperBound - range.lowerBound
                        let delta = (-drag.translation.height + drag.translation.width * 0.35) / 180
                        let candidate = (dragStartValue ?? value) + delta * span
                        value = min(max(candidate, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )
            .onTapGesture(count: 2) {
                value = defaultValue
            }

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(valueLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
        .padding(.vertical, 3)
        .frame(width: 78)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
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
