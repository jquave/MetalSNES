import SwiftUI
import MetalKit

// MTKView subclass that captures keyboard events and forwards them to the input manager
class KeyCaptureMTKView: MTKView {
    weak var inputManager: InputManager?
    var onToggleFullScreen: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handleFullscreenShortcut(event) {
            return
        }
        if inputManager?.handleKeyDown(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if inputManager?.handleKeyUp(event) == true {
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if inputManager?.handleFlagsChanged(event) == true {
            return
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        inputManager?.resetKeyboardState()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            inputManager?.resetKeyboardState()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func handleFullscreenShortcut(_ event: NSEvent) -> Bool {
        guard inputManager?.captureRequest == nil else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty, event.keyCode == 3, !event.isARepeat {
            onToggleFullScreen?()
            return true
        }

        if modifiers == [.command], (event.keyCode == 36 || event.keyCode == 76) {
            onToggleFullScreen?()
            return true
        }

        return false
    }
}

struct EmulatorView: NSViewRepresentable {
    @ObservedObject var viewModel: EmulatorViewModel
    var onToggleFullScreen: (() -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = KeyCaptureMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1.0)
        mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = !viewModel.isRunning
        mtkView.onToggleFullScreen = onToggleFullScreen ?? {
            (mtkView.window ?? NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
        }

        if let renderer = MetalRenderer(mtkView: mtkView) {
            mtkView.delegate = renderer
            viewModel.renderer = renderer
        }

        mtkView.inputManager = viewModel.inputManager
        viewModel.inputManager.attach(joypad: viewModel.emulatorCore?.bus.joypad)

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let mtkView = nsView as? KeyCaptureMTKView {
            mtkView.inputManager = viewModel.inputManager
            mtkView.onToggleFullScreen = onToggleFullScreen ?? {
                (mtkView.window ?? NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
            }
            viewModel.inputManager.attach(joypad: viewModel.emulatorCore?.bus.joypad)
            mtkView.preferredFramesPerSecond = nsView.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            mtkView.isPaused = !viewModel.isRunning
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
