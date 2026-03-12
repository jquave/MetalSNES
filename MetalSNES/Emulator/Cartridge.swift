import Foundation

struct Cartridge {
    enum GSUVariant {
        case starFox
        case standard
    }

    enum Coprocessor: String {
        case dsp = "DSP"
        case gsu = "Super FX (GSU)"
        case obc1 = "OBC1"
        case sa1 = "SA-1"
        case sdd1 = "S-DD1"
        case srtc = "S-RTC"
        case other = "other coprocessor"
        case custom = "custom coprocessor"
    }

    let romData: [UInt8]
    let romMask: Int  // romData.count - 1, valid when count is power of 2
    let title: String
    let mapMode: UInt8
    let romType: UInt8
    let romSizeKB: Int
    let sramSizeKB: Int
    let cartRAMSizeBytes: Int
    let isLoROM: Bool
    let coprocessor: Coprocessor?
    let gsuVariant: GSUVariant?
    var romURL: URL?

    enum CartridgeError: Error, LocalizedError {
        case tooSmall
        case invalidHeader
        case unsupportedHardware(String)
        var errorDescription: String? {
            switch self {
            case .tooSmall: return "ROM file too small"
            case .invalidHeader: return "Invalid ROM header"
            case .unsupportedHardware(let message): return message
            }
        }
    }

    private static func detectCoprocessor(romType: UInt8) -> Coprocessor? {
        let lowNibble = romType & 0x0F
        let highNibble = romType >> 4

        switch highNibble {
        case 0x0:
            return lowNibble >= 0x03 ? .dsp : nil
        case 0x1:
            return .gsu
        case 0x2:
            return .obc1
        case 0x3:
            return .sa1
        case 0x4:
            return .sdd1
        case 0x5:
            return .srtc
        case 0xE:
            return .other
        case 0xF:
            return .custom
        default:
            return nil
        }
    }

    /// Check if a header at the given offset has a valid checksum complement.
    /// Bytes at offset+0x1C/0x1D = complement, offset+0x1E/0x1F = checksum.
    /// Valid when complement + checksum == 0xFFFF.
    private static func headerChecksumValid(rom: Data, headerOffset: Int) -> Bool {
        guard headerOffset + 0x1F < rom.count else { return false }
        let complement = UInt16(rom[headerOffset + 0x1C]) | (UInt16(rom[headerOffset + 0x1D]) << 8)
        let checksum   = UInt16(rom[headerOffset + 0x1E]) | (UInt16(rom[headerOffset + 0x1F]) << 8)
        return (complement &+ checksum) == 0xFFFF
    }

    init(data: Data) throws {
        // Strip SMC header (512 bytes) if present
        let hasHeader = (data.count % 1024) == 512
        let rom = hasHeader ? data.subdata(in: 512..<data.count) : data

        guard rom.count >= 0x8000 else { throw CartridgeError.tooSmall }
        // Round up to next power of 2 for bitmask addressing
        var romBytes = [UInt8](rom)
        var pow2Size = 1
        while pow2Size < romBytes.count { pow2Size <<= 1 }
        if pow2Size > romBytes.count {
            romBytes.append(contentsOf: [UInt8](repeating: 0, count: pow2Size - romBytes.count))
        }
        self.romData = romBytes
        self.romMask = pow2Size - 1

        // Try both LoROM ($7FC0) and HiROM ($FFC0) header offsets
        let loROMOffset = 0x7FC0
        let hiROMOffset = 0xFFC0

        let loValid = Cartridge.headerChecksumValid(rom: rom, headerOffset: loROMOffset)
        let hiValid = Cartridge.headerChecksumValid(rom: rom, headerOffset: hiROMOffset)

        let headerOffset: Int
        if loValid && !hiValid {
            headerOffset = loROMOffset
        } else if hiValid && !loValid {
            headerOffset = hiROMOffset
        } else if loValid && hiValid {
            // Both valid — use mapMode bit 0 from HiROM header to decide
            let hiMapMode = rom[hiROMOffset + 0x15]
            if (hiMapMode & 0x01) != 0 {
                headerOffset = hiROMOffset
            } else {
                headerOffset = loROMOffset
            }
        } else {
            // Neither validates — fall back to size heuristic
            if rom.count >= 2 * 1024 * 1024 {
                headerOffset = hiROMOffset
            } else {
                headerOffset = loROMOffset
            }
        }

        guard headerOffset + 0x3F < rom.count else { throw CartridgeError.invalidHeader }

        // Parse title (21 bytes at header offset)
        var titleBytes = [UInt8](repeating: 0, count: 21)
        for i in 0..<21 {
            titleBytes[i] = rom[headerOffset + i]
        }
        self.title = String(bytes: titleBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "UNKNOWN"

        self.mapMode = rom[headerOffset + 0x15]
        self.romType = rom[headerOffset + 0x16]
        self.coprocessor = Cartridge.detectCoprocessor(romType: romType)

        let romSizeByte = rom[headerOffset + 0x17]
        self.romSizeKB = (1 << Int(romSizeByte))

        let sramSizeByte = rom[headerOffset + 0x18]
        self.sramSizeKB = sramSizeByte == 0 ? 0 : (1 << Int(sramSizeByte))
        self.cartRAMSizeBytes = max(
            self.sramSizeKB * 1024,
            self.coprocessor == .gsu ? 0x8000 : 0
        )
        self.gsuVariant = self.coprocessor == .gsu
            ? (rom.count <= 0x100000 ? .starFox : .standard)
            : nil

        if let coprocessor, coprocessor != .gsu {
            throw CartridgeError.unsupportedHardware("\(coprocessor.rawValue) cartridges are not supported yet")
        }

        self.isLoROM = (mapMode & 0x01) == 0
    }

    // LoROM address translation: bank:offset -> ROM file offset
    @inline(__always)
    func loromAddress(bank: UInt8, offset: UInt16) -> Int {
        let b = Int(bank & 0x7F)
        let romOffset = (b * 0x8000) + (Int(offset) & 0x7FFF)
        return romOffset & romMask
    }

    // HiROM address translation: bank:offset -> ROM file offset
    @inline(__always)
    func hiromAddress(bank: UInt8, offset: UInt16) -> Int {
        let b = Int(bank & 0x3F)
        let romOffset = b * 0x10000 + Int(offset)
        return romOffset & romMask
    }

    @inline(__always)
    func read(bank: UInt8, offset: UInt16) -> UInt8 {
        let addr = isLoROM ? loromAddress(bank: bank, offset: offset)
                           : hiromAddress(bank: bank, offset: offset)
        return romData[addr]
    }

    func gsuCPUROMAddress(bank: UInt8, offset: UInt16) -> Int? {
        guard let gsuVariant else { return nil }

        switch gsuVariant {
        case .starFox:
            switch bank {
            case 0x00...0x1F, 0x80...0x9F:
                guard offset >= 0x8000 else { return nil }
                let bankIndex = Int(bank & 0x1F)
                return ((bankIndex << 15) | Int(offset & 0x7FFF)) & romMask
            default:
                return nil
            }

        case .standard:
            switch bank {
            case 0x00...0x3F, 0x80...0xBF:
                guard offset >= 0x8000 else { return nil }
                let bankIndex = Int(bank & 0x3F)
                return ((bankIndex << 15) | Int(offset & 0x7FFF)) & romMask
            case 0x40...0x5F, 0xC0...0xDF:
                let bankIndex = Int(bank & 0x1F)
                return ((bankIndex << 16) | Int(offset)) & romMask
            default:
                return nil
            }
        }
    }

    func gsuCPURAMAddress(bank: UInt8, offset: UInt16) -> Int? {
        guard let gsuVariant, cartRAMSizeBytes > 0 else { return nil }
        let ramMask = cartRAMSizeBytes - 1

        switch gsuVariant {
        case .starFox:
            switch bank {
            case 0x60...0x7D, 0xE0...0xFF:
                let bankIndex = Int(bank & 0x1F)
                return ((bankIndex << 16) | Int(offset)) & ramMask
            default:
                return nil
            }

        case .standard:
            switch bank {
            case 0x00...0x3F, 0x80...0xBF:
                guard offset >= 0x6000 && offset <= 0x7FFF else { return nil }
                return Int(offset - 0x6000) & ramMask
            case 0x70...0x71, 0xF0...0xF1:
                let bankIndex = Int(bank & 0x01)
                return ((bankIndex << 16) | Int(offset)) & ramMask
            default:
                return nil
            }
        }
    }
}
