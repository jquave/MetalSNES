import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @State private var showDebug = false

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
                Toggle("Debug", isOn: $showDebug)
            }
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
            // Run PPU unit tests in background (no ROM test — that's too slow)
            DispatchQueue.global(qos: .userInitiated).async {
                PPUDiagnostic.runAll()
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

struct DebugSidebar: View {
    @ObservedObject var debugState: DebugState
    var onApplySpriteOverrides: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
