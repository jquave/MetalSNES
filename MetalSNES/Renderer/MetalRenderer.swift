import MetalKit
import simd

final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    private(set) var texture: MTLTexture!
    private let textureLock = NSLock()

    private let width = SNESConstants.screenWidth
    private let height = SNESConstants.screenHeight

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        mtkView.device = device

        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "vertexShader"),
              let fragFunc = library.makeFunction(name: "fragmentShader") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        self.pipelineState = pso

        super.init()

        createTexture()
        uploadTestPattern()
    }

    private func createTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)
    }

    func uploadFramebuffer(_ data: UnsafePointer<UInt8>) {
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        textureLock.lock()
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: width * 4)
        textureLock.unlock()
    }

    private func uploadTestPattern() {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let checker = ((x / 8) + (y / 8)) % 2 == 0
                pixels[idx + 0] = checker ? 0x40 : 0x00  // R
                pixels[idx + 1] = checker ? 0x80 : 0x20  // G
                pixels[idx + 2] = checker ? 0xFF : 0x40  // B
                pixels[idx + 3] = 0xFF                     // A
            }
        }
        uploadFramebuffer(pixels)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        textureLock.lock()
        encoder.setFragmentTexture(texture, index: 0)
        textureLock.unlock()
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
