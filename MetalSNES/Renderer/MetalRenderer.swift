import MetalKit
import QuartzCore
import simd

final class MetalRenderer: NSObject, MTKViewDelegate {
    struct PacingSnapshot {
        var producedFrames: UInt64 = 0
        var presentedFrames: UInt64 = 0
        var repeatedFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        var averageDisplayIntervalMs: Double = 0
        var worstDisplayIntervalMs: Double = 0
        var averageFrameAgeMs: Double = 0
        var worstFrameAgeMs: Double = 0
    }

    private enum PendingFrameSource {
        case uploadedFramebuffer
        case gpuPPU
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    private let ppuComputePipeline: MTLComputePipelineState?
    private(set) var texture: MTLTexture!
    private let textureLock = NSLock()
    private weak var view: MTKView?

    private let vramBuffer: MTLBuffer?
    private let oamBuffer: MTLBuffer?
    private let colorBuffer: MTLBuffer?
    private let lineStateBuffer: MTLBuffer?
    private let spriteCountBuffer: MTLBuffer?
    private let spriteIndexBuffer: MTLBuffer?
    private var pendingFrameSource: PendingFrameSource = .uploadedFramebuffer
    private var displayConfiguration = DisplayConfiguration.default
    private var latestFrameID: UInt64 = 0
    private var latestFrameReadyTime: UInt64 = 0
    private var lastTextureFrameID: UInt64 = 0
    private var lastPresentedFrameID: UInt64 = 0
    private var lastDrawTime: UInt64 = 0
    private var displayIntervalSamples: UInt64 = 0
    private var displayIntervalTotalNs: Double = 0
    private var worstDisplayIntervalNs: UInt64 = 0
    private var frameAgeSamples: UInt64 = 0
    private var frameAgeTotalNs: Double = 0
    private var worstFrameAgeNs: UInt64 = 0
    private var presentedFrames: UInt64 = 0
    private var repeatedFrames: UInt64 = 0
    private var droppedFrames: UInt64 = 0

    private let width = SNESConstants.screenWidth
    private let height = SNESConstants.screenHeight

    private var isHeadless: Bool {
        view == nil
    }

    var supportsPPURendering: Bool {
        ppuComputePipeline != nil &&
        vramBuffer != nil &&
        oamBuffer != nil &&
        colorBuffer != nil &&
        lineStateBuffer != nil &&
        spriteCountBuffer != nil &&
        spriteIndexBuffer != nil
    }

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.view = mtkView
        mtkView.device = device

        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 2
            metalLayer.presentsWithTransaction = false
            metalLayer.displaySyncEnabled = true
        }

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
        if let computeFunc = library.makeFunction(name: "ppuFrameKernel") {
            self.ppuComputePipeline = try? device.makeComputePipelineState(function: computeFunc)
        } else {
            self.ppuComputePipeline = nil
        }

        self.vramBuffer = device.makeBuffer(length: SNESConstants.vramSize, options: .storageModeShared)
        self.oamBuffer = device.makeBuffer(length: SNESConstants.oamSize, options: .storageModeShared)
        self.colorBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 256, options: .storageModeShared)
        self.lineStateBuffer = device.makeBuffer(length: MemoryLayout<GPULineState>.stride * SNESConstants.screenHeight, options: .storageModeShared)
        self.spriteCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * SNESConstants.screenHeight, options: .storageModeShared)
        self.spriteIndexBuffer = device.makeBuffer(length: MemoryLayout<UInt16>.stride * SNESConstants.screenHeight * 32, options: .storageModeShared)

        super.init()

        createTexture()
        uploadTestPattern()
    }

    init?(headlessDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device = headlessDevice,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.view = nil

        guard let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "vertexShader"),
              let fragFunc = library.makeFunction(name: "fragmentShader") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        self.pipelineState = pso
        if let computeFunc = library.makeFunction(name: "ppuFrameKernel") {
            self.ppuComputePipeline = try? device.makeComputePipelineState(function: computeFunc)
        } else {
            self.ppuComputePipeline = nil
        }

        self.vramBuffer = device.makeBuffer(length: SNESConstants.vramSize, options: .storageModeShared)
        self.oamBuffer = device.makeBuffer(length: SNESConstants.oamSize, options: .storageModeShared)
        self.colorBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 256, options: .storageModeShared)
        self.lineStateBuffer = device.makeBuffer(length: MemoryLayout<GPULineState>.stride * SNESConstants.screenHeight, options: .storageModeShared)
        self.spriteCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * SNESConstants.screenHeight, options: .storageModeShared)
        self.spriteIndexBuffer = device.makeBuffer(length: MemoryLayout<UInt16>.stride * SNESConstants.screenHeight * 32, options: .storageModeShared)

        super.init()

        createTexture()
    }

    private func createTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        texture = device.makeTexture(descriptor: desc)
    }

    private func copyBytes<T>(from values: [T], to buffer: MTLBuffer) {
        values.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                memcpy(buffer.contents(), baseAddress, bytes.count)
            }
        }
    }

    func applyDisplayConfiguration(_ configuration: DisplayConfiguration) {
        textureLock.lock()
        displayConfiguration = configuration
        textureLock.unlock()
    }

    func clearToBlack() {
        let pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            )
            let readyTime = mach_absolute_time()
            textureLock.lock()
            let frameID = latestFrameID &+ 1
            texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: width * 4)
            pendingFrameSource = .uploadedFramebuffer
            latestFrameID = frameID
            latestFrameReadyTime = readyTime
            lastTextureFrameID = frameID
            textureLock.unlock()
        }
    }

    func uploadFramebuffer(_ data: UnsafeRawPointer) {
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        let readyTime = mach_absolute_time()
        textureLock.lock()
        let frameID = latestFrameID &+ 1
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: data, bytesPerRow: width * 4)
        pendingFrameSource = .uploadedFramebuffer
        latestFrameID = frameID
        latestFrameReadyTime = readyTime
        lastTextureFrameID = frameID
        textureLock.unlock()
    }

    func present(ppu: PPU) {
        guard supportsPPURendering, ppu.usesGPURenderingThisFrame,
              let vramBuffer, let oamBuffer, let colorBuffer,
              let lineStateBuffer, let spriteCountBuffer, let spriteIndexBuffer else {
            if let ptr = ppu.frontBuffer.baseAddress {
                uploadFramebuffer(ptr)
            }
            return
        }

        let readyTime = mach_absolute_time()
        textureLock.lock()
        let frameID = latestFrameID &+ 1
        copyBytes(from: ppu.vram, to: vramBuffer)
        copyBytes(from: ppu.oam, to: oamBuffer)
        copyBytes(from: ppu.cgramColorCache, to: colorBuffer)
        copyBytes(from: ppu.gpuLineStates, to: lineStateBuffer)
        copyBytes(from: ppu.gpuSpriteCounts, to: spriteCountBuffer)
        copyBytes(from: ppu.gpuSpriteIndices, to: spriteIndexBuffer)
        pendingFrameSource = .gpuPPU
        latestFrameID = frameID
        latestFrameReadyTime = readyTime
        textureLock.unlock()
        if isHeadless {
            renderPendingFrameOffscreen()
        }
    }

    private func uploadTestPattern() {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let checker = ((x / 8) + (y / 8)) % 2 == 0
                pixels[idx + 0] = checker ? 0x40 : 0x00
                pixels[idx + 1] = checker ? 0x80 : 0x20
                pixels[idx + 2] = checker ? 0xFF : 0x40
                pixels[idx + 3] = 0xFF
            }
        }
        pixels.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                uploadFramebuffer(baseAddress)
            }
        }
    }

    func pacingSnapshot() -> PacingSnapshot {
        textureLock.lock()
        defer { textureLock.unlock() }
        let averageDisplayIntervalMs = displayIntervalSamples == 0 ? 0 : (displayIntervalTotalNs / Double(displayIntervalSamples)) / 1_000_000
        let averageFrameAgeMs = frameAgeSamples == 0 ? 0 : (frameAgeTotalNs / Double(frameAgeSamples)) / 1_000_000
        return PacingSnapshot(
            producedFrames: latestFrameID,
            presentedFrames: presentedFrames,
            repeatedFrames: repeatedFrames,
            droppedFrames: droppedFrames,
            averageDisplayIntervalMs: averageDisplayIntervalMs,
            worstDisplayIntervalMs: Timing.machAbsoluteToNanoseconds(worstDisplayIntervalNs) / 1_000_000,
            averageFrameAgeMs: averageFrameAgeMs,
            worstFrameAgeMs: Timing.machAbsoluteToNanoseconds(worstFrameAgeNs) / 1_000_000
        )
    }

    private func makeDisplayUniforms(for view: MTKView) -> DisplayUniforms {
        let drawableWidth = max(Float(view.drawableSize.width), 1)
        let drawableHeight = max(Float(view.drawableSize.height), 1)
        let textureWidth = Float(width)
        let textureHeight = Float(height)
        let scaleX = drawableWidth / textureWidth
        let scaleY = drawableHeight / textureHeight
        let fittedScale = min(scaleX, scaleY)
        let chosenScale: Float
        if displayConfiguration.integerScalingEnabled {
            chosenScale = fittedScale >= 1 ? floor(fittedScale) : fittedScale
        } else {
            chosenScale = fittedScale
        }
        let contentWidth = min(textureWidth * chosenScale, drawableWidth)
        let contentHeight = min(textureHeight * chosenScale, drawableHeight)
        let contentOriginX = floor((drawableWidth - contentWidth) * 0.5)
        let contentOriginY = floor((drawableHeight - contentHeight) * 0.5)

        var uniforms = DisplayUniforms()
        uniforms.viewportSize = SIMD2(drawableWidth, drawableHeight)
        uniforms.textureSize = SIMD2(textureWidth, textureHeight)
        uniforms.contentOrigin = SIMD2(contentOriginX, contentOriginY)
        uniforms.contentSize = SIMD2(contentWidth, contentHeight)
        uniforms.integerScalingEnabled = displayConfiguration.integerScalingEnabled ? 1 : 0
        uniforms.brightness = min(max(displayConfiguration.brightness, 0.4), 2.2)
        uniforms.contrast = min(max(displayConfiguration.contrast, 0.4), 2.0)
        uniforms.saturation = min(max(displayConfiguration.saturation, 0.0), 2.0)
        uniforms.userSharpness = min(max(displayConfiguration.sharpness, 0.5), 1.8)

        switch displayConfiguration.filterMode {
        case .clean:
            uniforms.filterMode = 0
            uniforms.scanlineStrength = 0
            uniforms.maskStrength = 0
            uniforms.bloomStrength = 0
            uniforms.curvature = 0
            uniforms.vignetteStrength = 0
            uniforms.sharpness = 1
        case .scanlines:
            uniforms.filterMode = 1
            uniforms.scanlineStrength = 0.16
            uniforms.maskStrength = 0.04
            uniforms.bloomStrength = 0.06
            uniforms.curvature = 0
            uniforms.vignetteStrength = 0.05
            uniforms.sharpness = 1.35
        case .crt:
            uniforms.filterMode = 2
            uniforms.scanlineStrength = 0.26
            uniforms.maskStrength = 0.11
            uniforms.bloomStrength = 0.18
            uniforms.curvature = 0.08
            uniforms.vignetteStrength = 0.2
            uniforms.sharpness = 1.75
        case .phosphor:
            uniforms.filterMode = 3
            uniforms.scanlineStrength = 0
            uniforms.maskStrength = 0.2
            uniforms.bloomStrength = 0.52
            uniforms.curvature = 0
            uniforms.vignetteStrength = 0
            uniforms.sharpness = 0.72
        case .phosphorHot:
            uniforms.filterMode = 4
            uniforms.scanlineStrength = 0.27
            uniforms.maskStrength = 0.38
            uniforms.bloomStrength = 0.86
            uniforms.curvature = 0
            uniforms.vignetteStrength = 0
            uniforms.sharpness = 0.56
        }

        return uniforms
    }

    private func encodePendingComputePass(into commandBuffer: MTLCommandBuffer) {
        guard pendingFrameSource == .gpuPPU,
              let ppuComputePipeline,
              let vramBuffer,
              let oamBuffer,
              let colorBuffer,
              let lineStateBuffer,
              let spriteCountBuffer,
              let spriteIndexBuffer,
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        computeEncoder.setComputePipelineState(ppuComputePipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBuffer(vramBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(oamBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(colorBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(lineStateBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(spriteCountBuffer, offset: 0, index: 4)
        computeEncoder.setBuffer(spriteIndexBuffer, offset: 0, index: 5)

        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroupCount = MTLSize(
            width: (width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
    }

    private func renderPendingFrameOffscreen() {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        textureLock.lock()
        encodePendingComputePass(into: commandBuffer)
        textureLock.unlock()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let statsGapResetThreshold = Timing.nanosecondsToMachAbsolute(100_000_000)
        textureLock.lock()
        let now = mach_absolute_time()
        if pendingFrameSource == .gpuPPU, lastTextureFrameID != latestFrameID {
            encodePendingComputePass(into: commandBuffer)
            lastTextureFrameID = latestFrameID
        }
        let displayTexture = texture
        let displayUniforms = makeDisplayUniforms(for: view)
        if lastDrawTime != 0, now - lastDrawTime <= statsGapResetThreshold {
            let drawInterval = now - lastDrawTime
            displayIntervalSamples &+= 1
            displayIntervalTotalNs += Timing.machAbsoluteToNanoseconds(drawInterval)
            worstDisplayIntervalNs = max(worstDisplayIntervalNs, drawInterval)
        }
        if latestFrameID != 0 {
            presentedFrames &+= 1
            if latestFrameID == lastPresentedFrameID {
                repeatedFrames &+= 1
            } else if lastPresentedFrameID != 0, latestFrameID > lastPresentedFrameID + 1 {
                droppedFrames &+= latestFrameID - lastPresentedFrameID - 1
            }

            let frameAge = now >= latestFrameReadyTime ? now - latestFrameReadyTime : 0
            frameAgeSamples &+= 1
            frameAgeTotalNs += Timing.machAbsoluteToNanoseconds(frameAge)
            worstFrameAgeNs = max(worstFrameAgeNs, frameAge)
            lastPresentedFrameID = latestFrameID
        }
        lastDrawTime = now
        textureLock.unlock()

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes([displayUniforms], length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(displayTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
