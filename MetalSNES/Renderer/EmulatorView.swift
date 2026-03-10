import SwiftUI
import MetalKit

// MTKView subclass that captures keyboard events and forwards them to the input manager
class KeyCaptureMTKView: MTKView {
    weak var inputManager: InputManager?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
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
}

struct EmulatorView: NSViewRepresentable {
    @ObservedObject var viewModel: EmulatorViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = KeyCaptureMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false

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
            viewModel.inputManager.attach(joypad: viewModel.emulatorCore?.bus.joypad)
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
