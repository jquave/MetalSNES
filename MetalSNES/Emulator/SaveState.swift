import Foundation

/// Binary save state for the entire emulator.
/// Format: "MSNS" magic + version u32 + sequential component data.
final class SaveState {
    static let magic: UInt32 = 0x534E534D  // "MSNS"
    static let version: UInt32 = 8

    // MARK: - Writer

    private var data = Data()

    private func write8(_ v: UInt8) { data.append(v) }
    private func write16(_ v: UInt16) { var v = v; data.append(Data(bytes: &v, count: 2)) }
    private func write32(_ v: UInt32) { var v = v; data.append(Data(bytes: &v, count: 4)) }
    private func write64(_ v: UInt64) { var v = v; data.append(Data(bytes: &v, count: 8)) }
    private func writeS32(_ v: Int32) { write32(UInt32(bitPattern: v)) }
    private func writeDouble(_ v: Double) { write64(v.bitPattern) }
    private func writeBool(_ v: Bool) { data.append(v ? 1 : 0) }
    private func writeData(_ d: [UInt8]) {
        write32(UInt32(d.count))
        data.append(contentsOf: d)
    }
    private func writeBuffer(_ buf: UnsafeMutableBufferPointer<UInt8>) {
        write32(UInt32(buf.count))
        data.append(UnsafeBufferPointer(buf))
    }
    private func writeS16Array(_ arr: [Int16]) {
        write32(UInt32(arr.count))
        for v in arr { write16(UInt16(bitPattern: v)) }
    }
    private func writeU16Array(_ arr: [UInt16]) {
        write32(UInt32(arr.count))
        for v in arr { write16(v) }
    }

    // MARK: - Reader

    private var readData: Data = Data()
    private var readOffset = 0
    private var loadedVersion: UInt32 = SaveState.version

    private func read8() -> UInt8 {
        let v = readData[readOffset]; readOffset += 1; return v
    }
    private func read16() -> UInt16 {
        let v = readData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: readOffset, as: UInt16.self) }
        readOffset += 2; return v
    }
    private func read32() -> UInt32 {
        let v = readData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: readOffset, as: UInt32.self) }
        readOffset += 4; return v
    }
    private func read64() -> UInt64 {
        let v = readData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: readOffset, as: UInt64.self) }
        readOffset += 8; return v
    }
    private func readS32() -> Int32 { Int32(bitPattern: read32()) }
    private func readDouble() -> Double { Double(bitPattern: read64()) }
    private func readBool() -> Bool { read8() != 0 }
    private func readDataChunk() -> [UInt8] {
        let count = Int(read32())
        let chunk = [UInt8](readData[readOffset..<(readOffset + count)])
        readOffset += count
        return chunk
    }
    private func readIntoBuffer(_ buf: UnsafeMutableBufferPointer<UInt8>) {
        let count = Int(read32())
        let toCopy = min(count, buf.count)
        readData.copyBytes(to: buf.baseAddress!, from: readOffset..<(readOffset + toCopy))
        readOffset += count
    }
    private func readS16Array() -> [Int16] {
        let count = Int(read32())
        return (0..<count).map { _ in Int16(bitPattern: read16()) }
    }
    private func readU16Array() -> [UInt16] {
        let count = Int(read32())
        return (0..<count).map { _ in read16() }
    }

    // MARK: - Save

    func save(core: EmulatorCore) -> Data {
        data.removeAll(keepingCapacity: true)
        data.reserveCapacity(700_000)
        write32(SaveState.magic)
        write32(SaveState.version)

        saveCPU(core.cpu)
        saveBus(core.bus)
        savePPU(core.bus.ppu)
        saveSPC(core.bus.apu.spc700)
        saveDSP(core.bus.apu.dsp)
        saveDMA(core.bus.dma)
        saveAPU(core.bus.apu)
        saveJoypad(core.bus.joypad)
        saveSuperFX(core.bus.superFX)
        saveRuntimeState(core)

        return data
    }

    private func saveCPU(_ cpu: CPU) {
        let r = cpu.regs
        write16(r.A); write16(r.X); write16(r.Y); write16(r.S)
        write16(r.D); write8(r.DBR); write8(r.PBR); write16(r.PC)
        write8(r.P)
        writeBool(r.emulationMode)
        writeBool(r.stopped); writeBool(r.waiting)
        writeBool(r.nmiPending); writeBool(r.irqPending)
    }

    private func saveBus(_ bus: Bus) {
        // Large memory
        writeBuffer(bus.wram)
        writeBuffer(bus.sram)

        // Registers
        write8(bus.nmitimen); write16(bus.htime); write16(bus.vtime)
        write8(bus.mdmaen); write8(bus.hdmaen); write8(bus.memsel)
        write8(bus.rdnmi); write8(bus.timeup); write8(bus.hvbjoy)
        write8(bus.rdio)
        write8(bus.wrmpya); write8(bus.wrmpyb)
        write16(bus.wrdiv); write8(bus.wrdivb)
        write16(bus.rddiv); write16(bus.rdmpy)
        write32(bus.wramAddress)
        write8(bus.lastDataBusValue)
        writeBool(bus.nmiPending); writeBool(bus.inVBlank)
    }

    private func savePPU(_ ppu: PPU) {
        writeData(ppu.vram); writeData(ppu.oam); writeData(ppu.cgram)

        write8(ppu.inidisp); write8(ppu.objsel)
        write8(ppu.oamaddl); write8(ppu.oamaddh)
        write8(ppu.bgmode); write8(ppu.mosaic)
        write8(ppu.bg1sc); write8(ppu.bg2sc); write8(ppu.bg3sc); write8(ppu.bg4sc)
        write8(ppu.bg12nba); write8(ppu.bg34nba)

        for i in 0..<4 { write16(ppu.bgHScroll[i]) }
        for i in 0..<4 { write16(ppu.bgVScroll[i]) }

        write8(ppu.vmainc); write8(ppu.vmaddl); write8(ppu.vmaddh)

        write8(ppu.tm); write8(ppu.ts)
        write8(ppu.cgwsel); write8(ppu.cgadsub); write8(ppu.coldata)
        write8(ppu.setini)

        // Mode 7
        write8(ppu.m7sel)
        write16(ppu.m7a); write16(ppu.m7b); write16(ppu.m7c); write16(ppu.m7d)
        write16(ppu.m7x); write16(ppu.m7y)

        // Window
        write8(ppu.w12sel); write8(ppu.w34sel); write8(ppu.wobjsel)
        write8(ppu.wh0); write8(ppu.wh1); write8(ppu.wh2); write8(ppu.wh3)
        write8(ppu.wbglog); write8(ppu.wobjlog)
        write8(ppu.tmw); write8(ppu.tsw)

        let snapshot = ppu.captureSnapshot()
        write8(snapshot.scrollLatch)
        write8(snapshot.bghofsLatch)
        write16(snapshot.vramPrefetch)
        write8(snapshot.fixedColorR); write8(snapshot.fixedColorG); write8(snapshot.fixedColorB)
        write16(snapshot.oamAddr); write8(snapshot.oamLatch)
        write16(snapshot.cgramAddr); write8(snapshot.cgramLatch); writeBool(snapshot.cgramFlipFlop)
        write8(snapshot.m7Latch)
        writeS32(snapshot.mpyResult)
        writeData(ppu.capturePresentedFramebuffer())
    }

    private func saveSPC(_ spc: SPC700) {
        write8(spc.a); write8(spc.x); write8(spc.y)
        write8(spc.sp); write16(spc.pc)
        writeBool(spc.flagN); writeBool(spc.flagV); writeBool(spc.flagP)
        writeBool(spc.flagH); writeBool(spc.flagZ); writeBool(spc.flagC)
        writeBool(spc.flagB); writeBool(spc.flagI)
        writeData(spc.ram)
        writeData(spc.portsFromCPU); writeData(spc.portsToCPU)
        write8(spc.dspAddr)
        for i in 0..<3 {
            writeBool(spc.timerEnabled[i])
            write8(spc.timerDivisor[i])
            write8(spc.timerCounter[i])
            write16(spc.timerInternal[i])
        }
        writeBool(spc.bootRomEnabled)
        writeBool(spc.stopped); writeBool(spc.sleeping)
        for i in 0..<3 { write32(UInt32(spc.timerStage2[i])) }
        for i in 0..<3 { writeBool(spc.timerStage1[i]) }
        for i in 0..<3 { writeBool(spc.timerLine[i]) }
        writeBool(spc.timersDisable)
        writeBool(spc.timersEnable)
    }

    private func saveDSP(_ dsp: DSP) {
        writeData(dsp.regs)
        write32(dsp.sampleCounter)
        for v in dsp.voices {
            write16(v.brrAddr)
            write32(UInt32(v.brrOffset))
            writeS16Array(v.brrBuffer)
            write8(v.brrHeader)
            write16(v.pitchCounter)
            write32(UInt32(v.envLevel))
            // EnvMode as UInt8
            let modeVal: UInt8
            switch v.envMode {
            case .attack: modeVal = 0; case .decay: modeVal = 1
            case .sustain: modeVal = 2; case .release: modeVal = 3
            }
            write8(modeVal)
            writeBool(v.keyedOn); writeBool(v.ended)
            write32(0) // envCounter removed (now using global counter)
            writeS16Array(v.prev)
        }

        let snapshot = dsp.captureSnapshot()
        write32(UInt32(snapshot.globalCounter))
        write16(UInt16(bitPattern: snapshot.noiseLevel))
        write32(UInt32(snapshot.echoPos))
        writeS16Array(snapshot.echoHistL)
        writeS16Array(snapshot.echoHistR)
        write32(UInt32(snapshot.echoHistPos))
        write8(snapshot.konLatch)
        write8(snapshot.koffLatch)
        for voice in snapshot.voices {
            writeS32(Int32(voice.hiddenEnv))
            write32(UInt32(voice.konDelay))
            writeS32(Int32(voice.output))
        }
    }

    private func saveDMA(_ dma: DMA) {
        for ch in dma.channels {
            write8(ch.control); write8(ch.destReg)
            write16(ch.srcAddr); write8(ch.srcBank)
            write16(ch.size); write8(ch.hdmaBank)
            write16(ch.hdmaAddr); write8(ch.hdmaLine); write8(ch.unused)
        }
        for i in 0..<8 {
            writeBool(dma.hdmaActive[i])
            writeBool(dma.hdmaDoTransfer[i])
            write8(dma.hdmaLineCounter[i])
            write32(dma.hdmaTableAddr[i])
            writeBool(dma.hdmaIndirect[i])
        }
    }

    private func saveAPU(_ apu: APU) {
        let snapshot = apu.captureSnapshot()
        writeDouble(snapshot.dspSampleAccumulator)
        writeDouble(snapshot.dspCycleAccumulator)
    }

    private func saveJoypad(_ joypad: Joypad) {
        let snapshot = joypad.captureSnapshot()
        write16(snapshot.joy1Auto)
        write16(snapshot.joy2Auto)
        writeBool(snapshot.strobeOn)
        write16(snapshot.joy1Shift)
        write32(UInt32(snapshot.joy1ReadCount))
    }

    private func saveSuperFX(_ superFX: SuperFXChip?) {
        guard let superFX else {
            writeBool(false)
            return
        }
        writeBool(true)
        writeData(superFX.saveState())
    }

    private func saveRuntimeState(_ core: EmulatorCore) {
        write32(UInt32(core.cpuMasterCycleCarry))
    }

    // MARK: - Restore

    func restore(from fileData: Data, core: EmulatorCore) throws {
        readData = fileData
        readOffset = 0

        let magic = read32()
        guard magic == SaveState.magic else {
            throw SaveStateError.invalidMagic
        }
        let ver = read32()
        guard ver >= 2 && ver <= SaveState.version else {
            throw SaveStateError.versionMismatch
        }
        loadedVersion = ver

        restoreCPU(core.cpu)
        restoreBus(core.bus)
        restorePPU(core.bus.ppu)
        restoreSPC(core.bus.apu.spc700)
        restoreDSP(core.bus.apu.dsp)
        restoreDMA(core.bus.dma)
        if loadedVersion >= 4 {
            restoreAPU(core.bus.apu)
            restoreJoypad(core.bus.joypad)
        } else {
            core.bus.apu.restoreSnapshot(.init())
            core.bus.joypad.restoreSnapshot(.init())
        }
        if loadedVersion >= 5 {
            try restoreSuperFX(core.bus.superFX)
        } else if core.bus.superFX != nil {
            throw SaveStateError.missingCoprocessorState("Super FX")
        }
        if loadedVersion >= 7 {
            restoreRuntimeState(core)
        } else {
            core.cpuMasterCycleCarry = 0
        }
    }

    private func restoreCPU(_ cpu: CPU) {
        cpu.regs.A = read16(); cpu.regs.X = read16(); cpu.regs.Y = read16(); cpu.regs.S = read16()
        cpu.regs.D = read16(); cpu.regs.DBR = read8(); cpu.regs.PBR = read8(); cpu.regs.PC = read16()
        cpu.regs.P = read8()
        cpu.regs.emulationMode = readBool()
        cpu.regs.stopped = readBool(); cpu.regs.waiting = readBool()
        cpu.regs.nmiPending = readBool(); cpu.regs.irqPending = readBool()
    }

    private func restoreBus(_ bus: Bus) {
        readIntoBuffer(bus.wram)
        readIntoBuffer(bus.sram)

        bus.nmitimen = read8(); bus.htime = read16(); bus.vtime = read16()
        bus.mdmaen = read8(); bus.hdmaen = read8(); bus.memsel = read8()
        bus.rdnmi = read8(); bus.timeup = read8(); bus.hvbjoy = read8()
        bus.rdio = read8()
        bus.wrmpya = read8(); bus.wrmpyb = read8()
        bus.wrdiv = read16(); bus.wrdivb = read8()
        bus.rddiv = read16(); bus.rdmpy = read16()
        bus.wramAddress = read32()
        bus.lastDataBusValue = read8()
        bus.nmiPending = readBool(); bus.inVBlank = readBool()
    }

    private func restorePPU(_ ppu: PPU) {
        ppu.vram = readDataChunk(); ppu.oam = readDataChunk(); ppu.cgram = readDataChunk()

        ppu.inidisp = read8(); ppu.objsel = read8()
        ppu.oamaddl = read8(); ppu.oamaddh = read8()
        ppu.bgmode = read8(); ppu.mosaic = read8()
        ppu.bg1sc = read8(); ppu.bg2sc = read8(); ppu.bg3sc = read8(); ppu.bg4sc = read8()
        ppu.bg12nba = read8(); ppu.bg34nba = read8()

        for i in 0..<4 { ppu.bgHScroll[i] = read16() }
        for i in 0..<4 { ppu.bgVScroll[i] = read16() }

        ppu.vmainc = read8(); ppu.vmaddl = read8(); ppu.vmaddh = read8()

        ppu.tm = read8(); ppu.ts = read8()
        ppu.cgwsel = read8(); ppu.cgadsub = read8(); ppu.coldata = read8()
        ppu.setini = read8()

        ppu.m7sel = read8()
        ppu.m7a = read16(); ppu.m7b = read16(); ppu.m7c = read16(); ppu.m7d = read16()
        ppu.m7x = read16(); ppu.m7y = read16()

        ppu.w12sel = read8(); ppu.w34sel = read8(); ppu.wobjsel = read8()
        ppu.wh0 = read8(); ppu.wh1 = read8(); ppu.wh2 = read8(); ppu.wh3 = read8()
        ppu.wbglog = read8(); ppu.wobjlog = read8()
        ppu.tmw = read8(); ppu.tsw = read8()

        if loadedVersion >= 4 {
            let scrollLatch = read8()
            let bghofsLatch = loadedVersion >= 8 ? read8() : scrollLatch
            ppu.restoreSnapshot(.init(
                scrollLatch: scrollLatch,
                bghofsLatch: bghofsLatch,
                vramPrefetch: read16(),
                fixedColorR: read8(),
                fixedColorG: read8(),
                fixedColorB: read8(),
                oamAddr: read16(),
                oamLatch: read8(),
                cgramAddr: read16(),
                cgramLatch: read8(),
                cgramFlipFlop: readBool(),
                m7Latch: read8(),
                mpyResult: readS32()
            ))
        } else {
            ppu.restoreSnapshot(.init())
        }
        if loadedVersion >= 6 {
            _ = ppu.restorePresentedFramebuffer(readDataChunk())
        }
    }

    private func restoreSPC(_ spc: SPC700) {
        spc.a = read8(); spc.x = read8(); spc.y = read8()
        spc.sp = read8(); spc.pc = read16()
        spc.flagN = readBool(); spc.flagV = readBool(); spc.flagP = readBool()
        spc.flagH = readBool(); spc.flagZ = readBool(); spc.flagC = readBool()
        spc.flagB = readBool(); spc.flagI = readBool()
        spc.ram = readDataChunk()
        spc.portsFromCPU = readDataChunk(); spc.portsToCPU = readDataChunk()
        spc.dspAddr = read8()
        for i in 0..<3 {
            spc.timerEnabled[i] = readBool()
            spc.timerDivisor[i] = read8()
            spc.timerCounter[i] = read8()
            spc.timerInternal[i] = read16()
        }
        spc.bootRomEnabled = readBool()
        spc.stopped = readBool(); spc.sleeping = readBool()
        for i in 0..<3 { spc.timerStage2[i] = Int(read32()) }
        if loadedVersion >= 3 {
            for i in 0..<3 { spc.timerStage1[i] = readBool() }
            for i in 0..<3 { spc.timerLine[i] = readBool() }
            spc.timersDisable = readBool()
            spc.timersEnable = readBool()
        } else {
            for i in 0..<3 {
                spc.timerStage1[i] = false
                spc.timerLine[i] = false
            }
            spc.timersDisable = false
            spc.timersEnable = true
        }
    }

    private func restoreDSP(_ dsp: DSP) {
        dsp.regs = readDataChunk()
        dsp.sampleCounter = read32()
        for i in 0..<8 {
            dsp.voices[i].brrAddr = read16()
            dsp.voices[i].brrOffset = Int(read32())
            dsp.voices[i].brrBuffer = readS16Array()
            dsp.voices[i].brrHeader = read8()
            dsp.voices[i].pitchCounter = read16()
            dsp.voices[i].envLevel = Int(read32())
            let modeVal = read8()
            switch modeVal {
            case 0: dsp.voices[i].envMode = .attack
            case 1: dsp.voices[i].envMode = .decay
            case 2: dsp.voices[i].envMode = .sustain
            default: dsp.voices[i].envMode = .release
            }
            dsp.voices[i].keyedOn = readBool(); dsp.voices[i].ended = readBool()
            _ = read32() // envCounter removed (now using global counter)
            dsp.voices[i].prev = readS16Array()
        }

        if loadedVersion >= 4 {
            var snapshot = DSP.Snapshot()
            snapshot.globalCounter = Int(read32())
            snapshot.noiseLevel = Int16(bitPattern: read16())
            snapshot.echoPos = Int(read32())
            snapshot.echoHistL = readS16Array()
            snapshot.echoHistR = readS16Array()
            snapshot.echoHistPos = Int(read32())
            snapshot.konLatch = read8()
            snapshot.koffLatch = read8()
            snapshot.voices = (0..<8).map { _ in
                DSP.VoiceSnapshot(
                    hiddenEnv: Int(readS32()),
                    konDelay: Int(read32()),
                    output: Int(readS32())
                )
            }
            dsp.restoreSnapshot(snapshot)
        } else {
            dsp.restoreSnapshot(.init())
        }
    }

    private func restoreRuntimeState(_ core: EmulatorCore) {
        core.cpuMasterCycleCarry = Int(read32())
    }

    private func restoreDMA(_ dma: DMA) {
        for i in 0..<8 {
            dma.channels[i].control = read8(); dma.channels[i].destReg = read8()
            dma.channels[i].srcAddr = read16(); dma.channels[i].srcBank = read8()
            dma.channels[i].size = read16(); dma.channels[i].hdmaBank = read8()
            dma.channels[i].hdmaAddr = read16(); dma.channels[i].hdmaLine = read8()
            dma.channels[i].unused = read8()
        }
        for i in 0..<8 {
            dma.hdmaActive[i] = readBool()
            dma.hdmaDoTransfer[i] = readBool()
            dma.hdmaLineCounter[i] = read8()
            dma.hdmaTableAddr[i] = read32()
            dma.hdmaIndirect[i] = readBool()
        }
    }

    private func restoreAPU(_ apu: APU) {
        apu.restoreSnapshot(.init(
            dspSampleAccumulator: readDouble(),
            dspCycleAccumulator: readDouble()
        ))
    }

    private func restoreJoypad(_ joypad: Joypad) {
        joypad.restoreSnapshot(.init(
            joy1Auto: read16(),
            joy2Auto: read16(),
            strobeOn: readBool(),
            joy1Shift: read16(),
            joy1ReadCount: Int(read32())
        ))
    }

    private func restoreSuperFX(_ superFX: SuperFXChip?) throws {
        let hasSuperFXState = readBool()
        guard hasSuperFXState else {
            if superFX != nil {
                throw SaveStateError.coprocessorMismatch("Super FX")
            }
            return
        }
        guard let superFX else {
            throw SaveStateError.coprocessorMismatch("Super FX")
        }
        let state = readDataChunk()
        guard superFX.restoreState(state) else {
            throw SaveStateError.invalidCoprocessorState("Super FX")
        }
    }

    enum SaveStateError: Error, LocalizedError {
        case invalidMagic
        case versionMismatch
        case missingCoprocessorState(String)
        case coprocessorMismatch(String)
        case invalidCoprocessorState(String)
        var errorDescription: String? {
            switch self {
            case .invalidMagic: return "Not a valid save state file"
            case .versionMismatch: return "Save state version mismatch"
            case .missingCoprocessorState(let name): return "Save state is missing \(name) data"
            case .coprocessorMismatch(let name): return "Save state \(name) data does not match the loaded ROM"
            case .invalidCoprocessorState(let name): return "Failed to restore \(name) state"
            }
        }
    }
}
