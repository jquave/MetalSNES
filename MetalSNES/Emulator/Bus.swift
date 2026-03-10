import Foundation

final class Bus {
    var cartridge: Cartridge
    var ppu: PPU
    var apu: APU
    var dma: DMA
    var joypad: Joypad

    // 128 KB WRAM
    let wram: UnsafeMutableBufferPointer<UInt8>
    // SRAM (up to 32KB)
    let sram: UnsafeMutableBufferPointer<UInt8>

    var lastDataBusValue: UInt8 = 0

    // CPU I/O registers
    var nmitimen: UInt8 = 0     // $4200 - NMI/IRQ enable
    var htime: UInt16 = 0x1FF   // $4207/$4208
    var vtime: UInt16 = 0x1FF   // $4209/$420A
    var mdmaen: UInt8 = 0       // $420B
    var hdmaen: UInt8 = 0       // $420C
    var memsel: UInt8 = 0       // $420D
    var rdnmi: UInt8 = 0        // $4210
    var timeup: UInt8 = 0       // $4211
    var hvbjoy: UInt8 = 0       // $4212
    var rdio: UInt8 = 0         // $4213
    var wrmpya: UInt8 = 0xFF    // $4202
    var wrmpyb: UInt8 = 0       // $4203
    var wrdiv: UInt16 = 0xFFFF  // $4204/$4205
    var wrdivb: UInt8 = 0       // $4206
    var rddiv: UInt16 = 0       // $4214/$4215
    var rdmpy: UInt16 = 0       // $4216/$4217
    var wramAddress: UInt32 = 0 // $2181-$2183

    // NMI
    var nmiPending = false
    var inVBlank = false

    init(cartridge: Cartridge) {
        self.cartridge = cartridge
        self.ppu = PPU()
        self.apu = APU()
        self.dma = DMA()
        self.joypad = Joypad()

        let wramPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: SNESConstants.wramSize)
        wramPtr.initialize(repeating: 0, count: SNESConstants.wramSize)
        self.wram = UnsafeMutableBufferPointer(start: wramPtr, count: SNESConstants.wramSize)

        let sramSize = max(cartridge.sramSizeKB * 1024, 0x2000)
        let sramPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: sramSize)
        sramPtr.initialize(repeating: 0, count: sramSize)
        self.sram = UnsafeMutableBufferPointer(start: sramPtr, count: sramSize)
    }

    deinit {
        wram.baseAddress?.deallocate()
        sram.baseAddress?.deallocate()
    }

    @inline(__always)
    func read(_ fullAddress: UInt32) -> UInt8 {
        let bank = UInt8((fullAddress >> 16) & 0xFF)
        let offset = UInt16(fullAddress & 0xFFFF)
        let value = readBankOffset(bank: bank, offset: offset)
        lastDataBusValue = value
        return value
    }

    /// WRAM watchpoint: set to a WRAM address to log writes. -1 = disabled.
    var wramWatchpoint: Int = -1
    var wramWatchLog: [(UInt32, UInt8)] = []  // (caller fullAddress, value)
    var cpuWriteLog: [(pc: UInt32, opcode: UInt8, target: UInt32, value: UInt8)] = []

    @inline(__always)
    func write(_ fullAddress: UInt32, value: UInt8) {
        let bank = UInt8((fullAddress >> 16) & 0xFF)
        let offset = UInt16(fullAddress & 0xFFFF)
        lastDataBusValue = value

        writeBankOffset(bank: bank, offset: offset, value: value)
    }

    func recordCPUWrite(callerPC: UInt32, opcode: UInt8, targetAddress: UInt32, value: UInt8) {
        guard callerPC != 0 else { return }

        let bank = UInt8((targetAddress >> 16) & 0xFF)
        let offset = UInt16(targetAddress & 0xFFFF)
        var targetWRAM = -1

        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            if offset < 0x2000 { targetWRAM = Int(offset) }
        case 0x7E:
            targetWRAM = Int(offset)
        case 0x7F:
            targetWRAM = 0x10000 + Int(offset)
        default:
            break
        }

        if wramWatchpoint >= 0, targetWRAM == wramWatchpoint {
            wramWatchLog.append((callerPC, value))
            if wramWatchLog.count <= 100 {
                print(String(format: "[WATCH] WRAM $%04X = $%02X from CPU $%06X op=$%02X",
                             wramWatchpoint, value, callerPC, opcode))
                fflush(stdout)
            }
        }

        let isAPUPort = offset >= 0x2140 && offset <= 0x217F &&
            ((bank <= 0x3F) || (bank >= 0x80 && bank <= 0xBF))
        let isNMITimen = offset == 0x4200 &&
            ((bank <= 0x3F) || (bank >= 0x80 && bank <= 0xBF))

        let isSoundMirror: Bool = {
            switch bank {
            case 0x00...0x3F, 0x80...0xBF:
                return (0x1DF9...0x1DFC).contains(offset)
            case 0x7E:
                return (0x1DF9...0x1DFC).contains(offset)
            default:
                return false
            }
        }()

        guard isAPUPort || isSoundMirror || isNMITimen else { return }

        cpuWriteLog.append((callerPC, opcode, targetAddress, value))
        if cpuWriteLog.count > 512 {
            cpuWriteLog.removeFirst(cpuWriteLog.count - 512)
        }

        if cpuWriteLog.count <= 120 {
            print(String(format: "[CPU-WRITE] pc=$%06X op=$%02X target=$%06X value=$%02X",
                         callerPC, opcode, targetAddress, value))
            fflush(stdout)
        }
    }

    func readWord(_ fullAddress: UInt32) -> UInt16 {
        let lo = UInt16(read(fullAddress))
        let hi = UInt16(read(fullAddress &+ 1))
        return (hi << 8) | lo
    }

    func readWord(bank: UInt8, offset: UInt16) -> UInt16 {
        let addr = (UInt32(bank) << 16) | UInt32(offset)
        return readWord(addr)
    }

    // MARK: - Bank/Offset routing

    @inline(__always)
    private func readBankOffset(bank: UInt8, offset: UInt16) -> UInt8 {
        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            return readSystemBank(bank: bank, offset: offset)

        case 0x40...0x6F, 0xC0...0xFF:
            // Cartridge ROM (HiROM area, but for LoROM we mirror)
            return cartridge.read(bank: bank, offset: offset)

        case 0x70...0x7D:
            if !cartridge.isLoROM && offset < 0x8000 {
                // HiROM: banks $70-$7D lower half maps to ROM
                return cartridge.read(bank: bank, offset: offset)
            }
            // SRAM
            let addr = Int(offset) & (sram.count - 1)
            return sram[addr]

        case 0x7E:
            // WRAM first 64KB
            return wram[Int(offset)]

        case 0x7F:
            // WRAM second 64KB
            return wram[0x10000 + Int(offset)]

        default:
            return lastDataBusValue
        }
    }

    @inline(__always)
    private func readSystemBank(bank: UInt8, offset: UInt16) -> UInt8 {
        switch offset {
        case 0x0000...0x1FFF:
            // WRAM mirror
            return wram[Int(offset)]

        case 0x2100...0x213F:
            // PPU registers
            return ppu.read(register: offset)

        case 0x2140...0x217F:
            // APU I/O (mirrored every 4 bytes)
            return apu.read(port: UInt16(offset & 0x03))

        case 0x2180:
            // WRAM data read
            let val = wram[Int(wramAddress) & 0x1FFFF]
            wramAddress = (wramAddress + 1) & 0x1FFFF
            return val

        case 0x4016:
            return joypad.readJoy1()

        case 0x4017:
            return joypad.readJoy2()

        case 0x4200...0x42FF:
            return readCPUReg(offset)

        case 0x4300...0x43FF:
            return dma.read(register: offset)

        case 0x6000...0x7FFF:
            if !cartridge.isLoROM && (bank & 0x7F) >= 0x20 && (bank & 0x7F) <= 0x3F {
                // HiROM SRAM at $20-$3F:$6000-$7FFF (and mirrors $A0-$BF)
                let sramBank = Int((bank & 0x7F) - 0x20)
                let addr = (sramBank * 0x2000 + Int(offset - 0x6000)) % max(sram.count, 1)
                return sram[addr]
            }
            return lastDataBusValue // open bus

        case 0x8000...0xFFFF:
            // Cartridge ROM
            return cartridge.read(bank: bank, offset: offset)

        default:
            return lastDataBusValue // open bus
        }
    }

    private func readCPUReg(_ offset: UInt16) -> UInt8 {
        switch offset {
        case 0x4210:
            let val = rdnmi | 0x01 // CPU version
            rdnmi &= 0x7F // clear NMI flag on read
            return val
        case 0x4211:
            let val = timeup
            timeup = 0
            return val
        case 0x4212:
            return hvbjoy
        case 0x4213:
            return rdio
        case 0x4214:
            return UInt8(rddiv & 0xFF)
        case 0x4215:
            return UInt8(rddiv >> 8)
        case 0x4216:
            return UInt8(rdmpy & 0xFF)
        case 0x4217:
            return UInt8(rdmpy >> 8)
        case 0x4218:
            return UInt8(joypad.joy1Auto & 0xFF)
        case 0x4219:
            return UInt8(joypad.joy1Auto >> 8)
        case 0x421A:
            return UInt8(joypad.joy2Auto & 0xFF)
        case 0x421B:
            return UInt8(joypad.joy2Auto >> 8)
        default:
            return lastDataBusValue
        }
    }

    @inline(__always)
    private func writeBankOffset(bank: UInt8, offset: UInt16, value: UInt8) {
        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            writeSystemBank(bank: bank, offset: offset, value: value)

        case 0x70...0x7D:
            let addr = Int(offset) & (sram.count - 1)
            sram[addr] = value

        case 0x7E:
            wram[Int(offset)] = value

        case 0x7F:
            wram[0x10000 + Int(offset)] = value

        default:
            break // ROM writes ignored
        }
    }

    @inline(__always)
    private func writeSystemBank(bank: UInt8, offset: UInt16, value: UInt8) {
        switch offset {
        case 0x0000...0x1FFF:
            wram[Int(offset)] = value

        case 0x6000...0x7FFF:
            if !cartridge.isLoROM && (bank & 0x7F) >= 0x20 && (bank & 0x7F) <= 0x3F {
                // HiROM SRAM write at $20-$3F:$6000-$7FFF (and mirrors $A0-$BF)
                let sramBank = Int((bank & 0x7F) - 0x20)
                let addr = (sramBank * 0x2000 + Int(offset - 0x6000)) % max(sram.count, 1)
                sram[addr] = value
            }

        case 0x2100...0x213F:
            ppu.write(register: offset, value: value)

        case 0x2140...0x217F:
            apu.write(port: UInt16(offset & 0x03), value: value)

        case 0x2180:
            wram[Int(wramAddress) & 0x1FFFF] = value
            wramAddress = (wramAddress + 1) & 0x1FFFF

        case 0x2181:
            wramAddress = (wramAddress & 0x1FF00) | UInt32(value)

        case 0x2182:
            wramAddress = (wramAddress & 0x100FF) | (UInt32(value) << 8)

        case 0x2183:
            wramAddress = (wramAddress & 0x0FFFF) | (UInt32(value & 0x01) << 16)

        case 0x4016:
            joypad.writeStrobe(value)

        case 0x4200:
            let oldNMIEnabled = (nmitimen & 0x80) != 0
            nmitimen = value
            let newNMIEnabled = (value & 0x80) != 0
            // Enabling NMI during active VBlank can trigger an immediate NMI edge.
            if newNMIEnabled && !oldNMIEnabled && inVBlank {
                nmiPending = true
                rdnmi |= 0x80
            }

        case 0x4202:
            wrmpya = value

        case 0x4203:
            wrmpyb = value
            rdmpy = UInt16(wrmpya) &* UInt16(wrmpyb)

        case 0x4204:
            wrdiv = (wrdiv & 0xFF00) | UInt16(value)

        case 0x4205:
            wrdiv = (wrdiv & 0x00FF) | (UInt16(value) << 8)

        case 0x4206:
            wrdivb = value
            if wrdivb != 0 {
                rddiv = wrdiv / UInt16(wrdivb)
                rdmpy = wrdiv % UInt16(wrdivb)
            } else {
                rddiv = 0xFFFF
                rdmpy = wrdiv
            }

        case 0x4207:
            htime = (htime & 0x100) | UInt16(value)

        case 0x4208:
            htime = (htime & 0x0FF) | (UInt16(value & 0x01) << 8)

        case 0x4209:
            vtime = (vtime & 0x100) | UInt16(value)

        case 0x420A:
            vtime = (vtime & 0x0FF) | (UInt16(value & 0x01) << 8)

        case 0x420B:
            mdmaen = value
            if value != 0 {
                dma.executeGeneralDMA(channels: value, bus: self)
            }

        case 0x420C:
            hdmaen = value

        case 0x420D:
            memsel = value

        case 0x4300...0x43FF:
            dma.write(register: offset, value: value)

        default:
            break
        }
    }

    // MARK: - VBlank / NMI

    func enterVBlank() {
        inVBlank = true
        hvbjoy |= 0x80
        rdnmi |= 0x80
        if (nmitimen & 0x80) != 0 {
            nmiPending = true
        }
        // Auto-joypad read
        if (nmitimen & 0x01) != 0 {
            joypad.autoRead()
            hvbjoy |= 0x01
        }
    }

    func exitVBlank() {
        inVBlank = false
        hvbjoy &= ~0x80
        rdnmi &= ~0x80
        hvbjoy &= ~0x01
    }

    // MARK: - SRAM Persistence

    func sramURL(for romURL: URL) -> URL {
        romURL.deletingPathExtension().appendingPathExtension("srm")
    }

    func saveSRAM(to url: URL) {
        guard let base = sram.baseAddress else { return }
        let data = Data(bytes: base, count: sram.count)
        do {
            try data.write(to: url, options: .atomic)
            print("SRAM saved to \(url.path) (\(sram.count) bytes)")
        } catch {
            print("Failed to save SRAM: \(error)")
        }
    }

    func loadSRAM(from url: URL) {
        guard let base = sram.baseAddress else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let count = min(data.count, sram.count)
            data.withUnsafeBytes { ptr in
                if let src = ptr.baseAddress {
                    base.initialize(from: src.assumingMemoryBound(to: UInt8.self), count: count)
                }
            }
            print("SRAM loaded from \(url.path) (\(count) bytes)")
        } catch {
            print("Failed to load SRAM: \(error)")
        }
    }
}
