import SwiftUI
import MetalKit

// MTKView subclass that captures keyboard events and forwards them to Joypad
class KeyCaptureMTKView: MTKView {
    weak var joypad: Joypad?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if Joypad.keyMap[event.keyCode] != nil {
            joypad?.keyDown(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Joypad.keyMap[event.keyCode] != nil {
            joypad?.keyUp(event.keyCode)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys (Shift) for L/R triggers
        let code = event.keyCode
        if Joypad.keyMap[code] != nil {
            if event.modifierFlags.contains(.shift) {
                joypad?.keyDown(code)
            } else {
                joypad?.keyUp(code)
            }
        }
        super.flagsChanged(with: event)
    }

    // Prevent beep on key press
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Joypad.keyMap[event.keyCode] != nil {
            if event.type == .keyDown {
                joypad?.keyDown(event.keyCode)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
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

        // Wire up joypad from emulator core if available
        if let joypad = viewModel.emulatorCore?.bus.joypad {
            mtkView.joypad = joypad
        }

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Update joypad reference when emulator core changes
        if let mtkView = nsView as? KeyCaptureMTKView {
            if let joypad = viewModel.emulatorCore?.bus.joypad {
                mtkView.joypad = joypad
            }
            // Ensure the view can receive key events
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
