import Foundation

final class APU {
    let spc700: SPC700
    let dsp: DSP
    let audioOutput: AudioOutput

    // Cycle tracking for running SPC700 in sync with main CPU
    // SPC700 runs at ~1.024 MHz (24.576 MHz / 24)
    // 1024000 / 60.0988 / 262 ≈ 65.1 cycles per scanline
    static let spcCyclesPerScanline = 65

    // DSP generates samples at 32 kHz = 32000/60.0988/262 ≈ 2.035 samples/scanline
    private var dspSampleAccumulator: Double = 0
    static let dspSamplesPerScanline: Double = 32000.0 / 60.0988 / 262.0

    // Fine-grained DSP interleaving: 1 DSP sample every ~32 SPC cycles
    static let spcCyclesPerDSPSample: Double = 1024000.0 / 32000.0  // ~32.0
    var dspCycleAccumulator: Double = 0

    // Debug
    private var totalScanlines = 0
    private var lastPC: UInt16 = 0
    private var bootHandshakeComplete = false

    init() {
        spc700 = SPC700()
        dsp = DSP()
        audioOutput = AudioOutput()

        // Wire DSP to SPC700's RAM
        spc700.dsp = dsp
        dsp.readRAM = { [weak self] addr in
            return self?.spc700.ram[Int(addr)] ?? 0
        }
        dsp.writeRAM = { [weak self] addr, val in
            self?.spc700.ram[Int(addr)] = val
        }

        dsp.triggerSPCTrace = { [weak self] in
            guard let spc = self?.spc700 else { return }
            spc.traceEnabled2 = true
            spc.traceCountdown = 2000
            spc.traceLog2.removeAll()
        }
        spc700.reset()
    }

    // Main CPU reads APU ports ($2140-$2143)
    func read(port: UInt16) -> UInt8 {
        let p = Int(port & 0x03)
        return spc700.portsToCPU[p]
    }

    // Main CPU writes APU ports ($2140-$2143)
    func write(port: UInt16, value: UInt8) {
        let p = Int(port & 0x03)
        let old = spc700.portsFromCPU[p]
        spc700.portsFromCPU[p] = value
        if dsp.diagSampleCount < 5000000 {
            if value != old || p == 0 || p == 2 {
                dsp.diagLog(String(format: "[CPU→SPC] port%d = $%02X (was $%02X) at sample %llu", p, value, old, dsp.diagSampleCount))
            }
        }
    }

    /// Legacy method — SPC execution is now interleaved from EmulatorCore.
    func step(masterCycles: Int) {
        generateDSPSamples()
    }

    /// Fine-grained DSP sample generation interleaved with SPC execution.
    /// Call after each SPC step with the number of SPC cycles consumed.
    func runSPCCycles(_ cycles: Int) {
        // Don't output audio while boot ROM is active (BRR data is garbage)
        guard !spc700.bootRomEnabled else { return }

        dspCycleAccumulator += Double(cycles)
        while dspCycleAccumulator >= APU.spcCyclesPerDSPSample {
            let (l, r) = dsp.generateSample()
            audioOutput.writeSample(left: l, right: r)
            dspCycleAccumulator -= APU.spcCyclesPerDSPSample
        }
    }

    // SPC PC sampling for diagnosis
    private var spcPCHistogram: [UInt16: Int] = [:]
    private var spcDiagFrame = 0
    private var spcCodeDumped = false

    /// Call once per scanline for debug logging and scanline accounting.
    func tickScanline() {
        totalScanlines += 1

        // Sample SPC PC every scanline for histogram
        let pc = spc700.pc
        spcPCHistogram[pc, default: 0] += 1

        // Every 262 scanlines (1 frame), dump stats
        if totalScanlines % 262 == 0 {
            spcDiagFrame += 1
            // Dump every ~60 frames (1 second) for first 10 seconds
            if spcDiagFrame % 60 == 0 && spcDiagFrame <= 600 {
                let top = spcPCHistogram.sorted { $0.value > $1.value }.prefix(10)
                var msg = String(format: "[SPC-DIAG] Frame %d, top PCs:", spcDiagFrame)
                for (addr, count) in top {
                    let opcode = spc700.ram[Int(addr)]
                    msg += String(format: " $%04X(op=$%02X,n=%d)", addr, opcode, count)
                }
                // Also log port state and timer state
                msg += String(format: " | ports in=%02X/%02X/%02X/%02X out=%02X/%02X/%02X/%02X",
                             spc700.portsFromCPU[0], spc700.portsFromCPU[1],
                             spc700.portsFromCPU[2], spc700.portsFromCPU[3],
                             spc700.portsToCPU[0], spc700.portsToCPU[1],
                             spc700.portsToCPU[2], spc700.portsToCPU[3])
                msg += String(format: " | T0=%@(div=%d,cnt=%d) T1=%@(div=%d,cnt=%d)",
                             spc700.timerEnabled[0] ? "ON" : "off", spc700.timerDivisor[0], spc700.timerCounter[0],
                             spc700.timerEnabled[1] ? "ON" : "off", spc700.timerDivisor[1], spc700.timerCounter[1])
                dsp.diagLog(msg)
                // One-time dump of SPC code at top PC addresses
                if !spcCodeDumped && spcDiagFrame >= 120 {
                    spcCodeDumped = true
                    // Dump code around top addresses
                    for (addr, _) in top.prefix(5) {
                        var bytes = ""
                        for b in 0..<16 {
                            bytes += String(format: "%02X ", spc700.ram[Int(addr) + b])
                        }
                        dsp.diagLog(String(format: "[SPC-CODE] $%04X: %@", addr, bytes))
                    }
                    // Dump SPC RAM at key N-SPC locations
                    // N-SPC music pointer area (typically $0200-$02FF)
                    var msg2 = "[SPC-RAM] $0200: "
                    for i in 0..<32 { msg2 += String(format: "%02X ", spc700.ram[0x200 + i]) }
                    dsp.diagLog(msg2)
                    msg2 = "[SPC-RAM] $0100: "
                    for i in 0..<32 { msg2 += String(format: "%02X ", spc700.ram[0x100 + i]) }
                    dsp.diagLog(msg2)
                }
                spcPCHistogram.removeAll()
            }
        }

        logDebug()
    }

    /// Legacy: generate DSP samples for one scanline (kept for backward compat).
    func generateDSPSamples() {
        totalScanlines += 1

        // Debug trace
        logDebug()

        // Don't output audio while boot ROM is active (BRR data is garbage)
        guard !spc700.bootRomEnabled else { return }

        dspSampleAccumulator += APU.dspSamplesPerScanline
        while dspSampleAccumulator >= 1.0 {
            let (l, r) = dsp.generateSample()
            audioOutput.writeSample(left: l, right: r)
            dspSampleAccumulator -= 1.0
        }
    }

    private func logDebug() {
        if EmulatorCore.debugLogging || totalScanlines <= 262 * 300 {
            if totalScanlines % 262 == 0 {
                let frame = totalScanlines / 262
                let pc = spc700.pc
                let p0out = spc700.portsToCPU[0]
                let p1out = spc700.portsToCPU[1]
                let p0in = spc700.portsFromCPU[0]
                let p1in = spc700.portsFromCPU[1]
                let bootRom = spc700.bootRomEnabled
                print(String(format: "[APU] F%d PC=$%04X A=$%02X ports out=%02X/%02X in=%02X/%02X boot=%@",
                             frame, pc, spc700.a, p0out, p1out, p0in, p1in,
                             bootRom ? "Y" : "N"))
                fflush(stdout)
                if !bootHandshakeComplete && !bootRom {
                    bootHandshakeComplete = true
                    print("[APU] Boot ROM disabled — handshake likely complete, executing game audio code")
                    fflush(stdout)
                }
                // Timer diagnostic (every 60 frames)
                if frame % 60 == 0 {
                    let t0en = spc700.timerEnabled[0]
                    let t1en = spc700.timerEnabled[1]
                    let t2en = spc700.timerEnabled[2]
                    let t0div = spc700.timerDivisor[0]
                    let t1div = spc700.timerDivisor[1]
                    let t2div = spc700.timerDivisor[2]
                    let ctrl = spc700.ram[0xF1]
                    print(String(format: "[APU] F%d Timers: T0=%@(div=%d) T1=%@(div=%d) T2=%@(div=%d) CTRL=$%02X ports=%02X/%02X/%02X/%02X",
                                 frame, t0en ? "ON" : "off", t0div, t1en ? "ON" : "off", t1div, t2en ? "ON" : "off", t2div, ctrl,
                                 p0in, p1in, spc700.portsFromCPU[2], spc700.portsFromCPU[3]))
                    fflush(stdout)
                }
                // Log DSP voice activity (read-only — do NOT call generateSample!)
                let kon = dsp.regs[0x4C]
                let activeVoices = (0..<8).filter { dsp.voices[$0].keyedOn }.count
                let buffered = audioOutput.bufferedSamples
                if activeVoices > 0 || kon != 0 {
                    // Find first active voice for diagnostics
                    let av = (0..<8).first { dsp.voices[$0].keyedOn } ?? 0
                    let voff = av * 0x10
                    let vEnv = dsp.voices[av].envLevel
                    let vPitch = UInt16(dsp.regs[voff + 2]) | (UInt16(dsp.regs[voff + 3] & 0x3F) << 8)
                    let vMode = dsp.voices[av].envMode
                    print(String(format: "[APU] F%d DSP: KON=$%02X active=%d v%d env=%d pitch=$%04X mode=%@ buf=%d",
                                 frame, kon, activeVoices, av, vEnv, vPitch, "\(vMode)", buffered))
                    fflush(stdout)
                }
            }
        }
    }

    func startAudio() {
        audioOutput.start()
    }

    func stopAudio() {
        audioOutput.stop()
    }
}
