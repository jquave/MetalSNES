import Foundation
import os

final class EmulatorCore {
    static var debugLogging = false

    let bus: Bus
    let cpu: CPU
    var renderer: MetalRenderer?
    var debugState: DebugState?
    var debugServer: DebugServer?

    private let _running = OSAllocatedUnfairLock(initialState: false)
    private var frameCount: UInt64 = 0
    private var _diagRequested = OSAllocatedUnfairLock(initialState: false)

    /// Debug pause: when > 0, emulation loop spins (no frames) and decrements.
    var _pauseFrames = OSAllocatedUnfairLock(initialState: 0)

    /// Call from main thread to request a freeze diagnostic on the next scanline.
    func requestDiagnosis() {
        _diagRequested.withLock { $0 = true }
    }

    var isRunning: Bool {
        get { _running.withLock { $0 } }
        set { _running.withLock { $0 = newValue } }
    }

    init(cartridge: Cartridge) {
        self.bus = Bus(cartridge: cartridge)
        self.cpu = CPU(bus: bus)
        cpu.reset()

        // Enable tracing for first 500 instructions
        if EmulatorCore.debugLogging {
            cpu.traceEnabled = true
        }
    }

    /// Start the HTTP debug server on port 8765 for real-time SPC/DSP inspection.
    func startDebugServer() {
        let server = DebugServer()
        server.emulator = self
        server.start()
        debugServer = server
    }

    func run() {
        bus.apu.startAudio()
        var lastFrameTime = mach_absolute_time()

        while isRunning {
            // Debug pause support
            let paused = _pauseFrames.withLock { val -> Bool in
                if val > 0 { val -= 1; return true }
                return false
            }
            if paused {
                usleep(1000) // 1ms spin
                continue
            }

            runOneFrame()
            frameCount += 1

            if EmulatorCore.debugLogging {
                // Disable trace after first few frames
                if frameCount > 2 {
                    if cpu.traceEnabled {
                        cpu.traceEnabled = false
                        print("--- First \(cpu.traceLog.count) instructions: ---")
                        cpu.printTrace()
                    }
                }

                // Dump sprite diagnostic after 60 frames (1 second)
                if frameCount == 60 {
                    bus.ppu.dumpSpriteState()
                }

                // One-time VRAM vs WRAM comparison at frame 1500 (~25 seconds)
                if frameCount == 1500 {
                    print("=== VRAM/WRAM Tile Data Comparison ===")
                    let wramSrc = (0..<64).map { String(format: "%02X", bus.wram[0xE800 + $0]) }.joined(separator: " ")
                    let vramB000 = (0..<64).map { String(format: "%02X", bus.ppu.vram[0xB000 + $0]) }.joined(separator: " ")
                    let vram6000 = (0..<64).map { String(format: "%02X", bus.ppu.vram[0x6000 + $0]) }.joined(separator: " ")
                    print("WRAM $E800: \(wramSrc)")
                    print("VRAM $B000: \(vramB000)")
                    print("VRAM $6000: \(vram6000)")
                    let wramBytes = (0..<64).map { bus.wram[0xE800 + $0] }
                    let b000Bytes = (0..<64).map { bus.ppu.vram[0xB000 + $0] }
                    let v6000Bytes = (0..<64).map { bus.ppu.vram[0x6000 + $0] }
                    let matchB000 = wramBytes == b000Bytes
                    let matchV6000 = wramBytes == v6000Bytes
                    print("WRAM==VRAM$B000: \(matchB000)  WRAM==VRAM$6000: \(matchV6000)")
                    let wramNonZero = wramBytes.filter { $0 != 0 }.count
                    let b000NonZero = b000Bytes.filter { $0 != 0 }.count
                    print("WRAM non-zero: \(wramNonZero)/64  VRAM$B000 non-zero: \(b000NonZero)/64")
                    fflush(stdout)
                }

                // Dump game state variables every 10 frames for first 120 frames
                if frameCount <= 600 && frameCount % 30 == 0 {
                    let dp10 = bus.wram[0x10]
                    let dp11 = bus.wram[0x11]
                    let dp13 = bus.wram[0x13]
                    let dp1C = bus.wram[0x1C]
                    let dpB0 = bus.wram[0xB0]
                    let v012A = bus.wram[0x012A]
                    print("F\(frameCount): st=\(dp10)/\(dp11) bright=$\(String(format:"%02X",dp13)) TM=$\(String(format:"%02X",dp1C)) timer=\(dpB0) $012A=\(v012A) PC=$\(String(format:"%02X:%04X",cpu.regs.PBR,cpu.regs.PC))")
                }
            }

            // Frame pacing (drift-free: advance target by fixed interval)
            let now = mach_absolute_time()
            let target = lastFrameTime + Timing.targetFrameTimeAbsolute
            if now < target {
                let sleepMach = target - now
                let sleepNs = Timing.machAbsoluteToNanoseconds(sleepMach)
                usleep(UInt32(sleepNs) / 1000)
            }
            lastFrameTime += Timing.targetFrameTimeAbsolute
            // If running very late (>2x target), reset to avoid spiral
            if mach_absolute_time() > lastFrameTime + Timing.targetFrameTimeAbsolute * 2 {
                lastFrameTime = mach_absolute_time()
            }

            // Update debug state periodically
            if frameCount % 10 == 0 {
                updateDebugState()
            }
        }
    }

    func runOneFrame() {
        for scanline in 0..<SNESConstants.scanlinesPerFrame {
            runScanline(scanline)
        }

        // Upload framebuffer to Metal
        bus.ppu.swapBuffers()
        if let renderer = renderer, let ptr = bus.ppu.frontBuffer.baseAddress {
            renderer.uploadFramebuffer(ptr)
        }
    }

    /// Run a fixed number of frames with no frame pacing and report FPS.
    func benchmark(frames: Int) {
        var cpuTime: UInt64 = 0
        var ppuTime: UInt64 = 0
        var spcTime: UInt64 = 0
        let start = mach_absolute_time()
        for _ in 0..<frames {
            for scanline in 0..<SNESConstants.scanlinesPerFrame {
                if scanline == 0 {
                    bus.exitVBlank()
                    if bus.hdmaen != 0 {
                        bus.dma.initHDMA(channels: bus.hdmaen, bus: bus)
                    }
                }

                // CPU + SPC timing (interleaved)
                let cpuStart = mach_absolute_time()
                var cyclesRemaining = Timing.cpuCyclesPerScanline
                var spcCycleDebt: Double = 0.0
                let spcRatio = APU.spcCyclesPerScanline / Double(Timing.cpuCyclesPerScanline)
                let spc = bus.apu.spc700
                while cyclesRemaining > 0 {
                    let cycles = cpu.step()
                    cyclesRemaining -= cycles
                    spcCycleDebt += Double(cycles) * spcRatio
                    while spcCycleDebt >= 1.0 {
                        let spcCycles = spc.step()
                        spc.tickTimers(cpuCycles: spcCycles)
                        spcCycleDebt -= Double(spcCycles)
                    }
                }
                cpuTime += mach_absolute_time() - cpuStart

                // PPU timing
                let ppuStart = mach_absolute_time()
                if scanline < SNESConstants.visibleScanlines {
                    bus.ppu.renderScanline(scanline)
                    if bus.hdmaen != 0 {
                        bus.dma.doHDMA(channels: bus.hdmaen, bus: bus)
                    }
                }
                ppuTime += mach_absolute_time() - ppuStart

                if scanline == SNESConstants.vBlankStart {
                    bus.enterVBlank()
                }
            }
            bus.ppu.swapBuffers()
        }
        let elapsed = mach_absolute_time() - start
        let elapsedNs = Timing.machAbsoluteToNanoseconds(elapsed)
        let elapsedSec = Double(elapsedNs) / 1_000_000_000
        let fps = Double(frames) / elapsedSec
        let cpuMs = Double(Timing.machAbsoluteToNanoseconds(cpuTime)) / 1_000_000
        let ppuMs = Double(Timing.machAbsoluteToNanoseconds(ppuTime)) / 1_000_000
        let spcMs = Double(Timing.machAbsoluteToNanoseconds(spcTime)) / 1_000_000
        print(String(format: "Benchmark: %d frames in %.3f sec = %.1f FPS (%.1fx realtime)",
                      frames, elapsedSec, fps, fps / 60.0))
        print(String(format: "  CPU+SPC: %.0f ms (%.0f%%), PPU: %.0f ms (%.0f%%), SPC: %.0f ms (%.0f%%)",
                      cpuMs, cpuMs / (elapsedSec * 1000) * 100,
                      ppuMs, ppuMs / (elapsedSec * 1000) * 100,
                      spcMs, spcMs / (elapsedSec * 1000) * 100))
        fflush(stdout)
    }

    /// Tracks whether the H/V timer IRQ already fired on the current scanline.
    private var irqFiredThisScanline = false

    private func runScanline(_ scanline: Int) {
        if scanline == 0 {
            bus.exitVBlank()

            // Initialize HDMA at the start of each frame
            if bus.hdmaen != 0 {
                bus.dma.initHDMA(channels: bus.hdmaen, bus: bus)
            }
        }

        // Reset per-scanline IRQ flag
        irqFiredThisScanline = false

        // Auto-joypad read completes ~3 scanlines after VBlank start
        if scanline == SNESConstants.vBlankStart + 3 {
            bus.hvbjoy &= ~0x01
        }

        // Run CPU for approximately one scanline worth of cycles
        // SPC700 runs interleaved: ~65 SPC cycles per ~228 CPU cycles
        var cyclesRemaining = Timing.cpuCyclesPerScanline
        let irqMode = (bus.nmitimen >> 4) & 0x03
        var hDot = 0
        let dotsPerCycle = 4
        var spcCycleDebt: Double = 0.0
        let spcRatio = APU.spcCyclesPerScanline / Double(Timing.cpuCyclesPerScanline)
        let spc = bus.apu.spc700

        // Start of scanline: clear HBlank
        bus.hvbjoy &= ~0x40

        // On-demand freeze diagnostic (triggered by Diagnose button)
        let tracing = _diagRequested.withLock { val -> Bool in
            if val { val = false; return true }; return false
        }
        var traceBuffer: [(UInt32, UInt8)] = []

        while cyclesRemaining > 0 {
            if tracing {
                let pc = (UInt32(cpu.regs.PBR) << 16) | UInt32(cpu.regs.PC)
                let opcode = bus.read(pc)
                traceBuffer.append((pc, opcode))
            }

            let cycles = cpu.step()
            cyclesRemaining -= cycles
            hDot += cycles * dotsPerCycle

            // HBlank flag (bit 6 of $4212): set when H >= 274, clear when H < 274
            if hDot >= 274 {
                bus.hvbjoy |= 0x40
            }

            // Run proportional SPC cycles interleaved with CPU
            spcCycleDebt += Double(cycles) * spcRatio
            while spcCycleDebt >= 1.0 {
                let spcCycles = spc.step()
                spc.tickTimers(cpuCycles: spcCycles)
                bus.apu.runSPCCycles(spcCycles)
                spcCycleDebt -= Double(spcCycles)
            }

            // Check H-IRQ mid-scanline (only when IRQ enabled)
            if irqMode != 0 && !irqFiredThisScanline {
                checkTimerIRQ(scanline: scanline, hDot: hDot)
            }

            if cpu.regs.stopped {
                isRunning = false
                print("CPU stopped (STP instruction)")
                return
            }
        }

        if tracing && !traceBuffer.isEmpty {
            print("=== FREEZE DIAGNOSTIC (frame \(frameCount), scanline \(scanline)) ===")
            print("NMITIMEN=$\(String(format: "%02X", bus.nmitimen)) NMI=\(bus.nmiPending) WAI=\(cpu.regs.waiting)")
            print("A=$\(String(format: "%04X", cpu.regs.A)) X=$\(String(format: "%04X", cpu.regs.X)) Y=$\(String(format: "%04X", cpu.regs.Y)) S=$\(String(format: "%04X", cpu.regs.S)) P=$\(String(format: "%02X", cpu.regs.P))")
            var pcCounts: [UInt32: Int] = [:]
            for (pc, _) in traceBuffer { pcCounts[pc, default: 0] += 1 }
            let sorted = pcCounts.sorted { $0.value > $1.value }
            print("Top PCs (total \(traceBuffer.count) steps, \(pcCounts.count) unique):")
            for (pc, count) in sorted.prefix(20) {
                let opcode = bus.read(pc)
                print(String(format: "  $%06X: op=$%02X  count=%d", pc, opcode, count))
            }
            print("First 50 instructions:")
            for (pc, op) in traceBuffer.prefix(50) {
                print(String(format: "  $%06X: $%02X", pc, op))
            }
            fflush(stdout)
        }

        // Debug logging for this scanline (DSP samples now generated inline via runSPCCycles)
        bus.apu.tickScanline()

        // Render visible scanlines
        if scanline < SNESConstants.visibleScanlines {
            bus.ppu.renderScanline(scanline)

            // Execute HDMA after rendering each visible scanline
            if bus.hdmaen != 0 {
                bus.dma.doHDMA(channels: bus.hdmaen, bus: bus)
            }
        }

        // VBlank
        if scanline == SNESConstants.vBlankStart {
            bus.enterVBlank()
        }
    }

    /// Check NMITIMEN bits 4-5 for H/V timer IRQ and fire if conditions match.
    private func checkTimerIRQ(scanline: Int, hDot: Int) {
        guard !irqFiredThisScanline else { return }

        let irqMode = (bus.nmitimen >> 4) & 0x03
        guard irqMode != 0 else { return }

        let hTarget = Int(bus.htime)   // 0-339
        let vTarget = Int(bus.vtime)
        var shouldFire = false

        switch irqMode {
        case 1:
            // H-IRQ: fire when H counter >= HTIME
            shouldFire = hDot >= hTarget
        case 2:
            // V-IRQ: fire when scanline matches VTIME
            shouldFire = (scanline == vTarget)
        case 3:
            // HV-IRQ: fire when both scanline matches VTIME and H counter >= HTIME
            shouldFire = (scanline == vTarget) && (hDot >= hTarget)
        default:
            break
        }

        if shouldFire {
            bus.timeup = 0x80
            cpu.regs.irqPending = true
            irqFiredThisScanline = true
        }
    }

    func step() {
        _ = cpu.step()
    }

    func stop() {
        isRunning = false
        bus.apu.stopAudio()
    }

    func updateDebugState() {
        guard let debugState = debugState else { return }

        // Snapshot all data on the emulation thread to avoid races
        let regA = cpu.regs.A
        let regX = cpu.regs.X
        let regY = cpu.regs.Y
        let regS = cpu.regs.S
        let regD = cpu.regs.D
        let regDBR = cpu.regs.DBR
        let regPBR = cpu.regs.PBR
        let regPC = cpu.regs.PC
        let regP = cpu.regs.P
        let regEmu = cpu.regs.emulationMode

        let pc = (UInt32(regPBR) << 16) | UInt32(regPC)
        let memPC: [UInt8] = (0..<32).map { bus.read(pc &+ UInt32($0)) }

        let offset = debugState.memoryViewerOffset
        let clampedOffset = min(offset, bus.wram.count - 256)
        let memPage = Array(bus.wram[clampedOffset..<(clampedOffset + 256)])

        let obj = bus.ppu.objsel
        let sprOverride = debugState.spriteOverrideEnabled

        // Snapshot VRAM, CGRAM, OAM and PPU registers for tile viewer
        let vramCopy = bus.ppu.vram
        let cgramCopy = bus.ppu.cgram
        let oamCopy = bus.ppu.oam
        let bg12 = bus.ppu.bg12nba
        let bg34 = bus.ppu.bg34nba
        let chrBase1 = Int(bg12 & 0x0F) << 13
        let chrBase2 = Int(bg12 >> 4) << 13
        let chrBase3 = Int(bg34 & 0x0F) << 13
        let tm = bus.ppu.tm
        let bgmode = bus.ppu.bgmode
        let inidisp = bus.ppu.inidisp

        DispatchQueue.main.async {
            debugState.a = regA
            debugState.x = regX
            debugState.y = regY
            debugState.s = regS
            debugState.d = regD
            debugState.dbr = regDBR
            debugState.pbr = regPBR
            debugState.pc = regPC
            debugState.p = regP
            debugState.emulationMode = regEmu
            debugState.memoryAroundPC = memPC
            debugState.currentPC = pc
            debugState.memoryPage = memPage

            if !sprOverride {
                debugState.spriteNameBase = Int(obj & 0x07)
                debugState.spriteNameGap = Int((obj >> 3) & 0x03)
                debugState.spriteSizeSelect = min(Int((obj >> 5) & 0x07), 5)
            }

            debugState.vramSnapshot = vramCopy
            debugState.cgramSnapshot = cgramCopy
            debugState.bg1ChrBase = chrBase1
            debugState.bg2ChrBase = chrBase2
            debugState.bg3ChrBase = chrBase3
            debugState.ppuTM = tm
            debugState.ppuBGMode = bgmode
            debugState.ppuBG12NBA = bg12
            debugState.ppuBG34NBA = bg34
            debugState.ppuOBJSEL = obj
            debugState.ppuINIDISP = inidisp
            debugState.ppuOAMSnapshot = oamCopy
        }
    }
}
