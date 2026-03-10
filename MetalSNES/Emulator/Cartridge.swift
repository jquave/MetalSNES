import Foundation

struct Cartridge {
    let romData: [UInt8]
    let romMask: Int  // romData.count - 1, valid when count is power of 2
    let title: String
    let mapMode: UInt8
    let romType: UInt8
    let romSizeKB: Int
    let sramSizeKB: Int
    let isLoROM: Bool
    var romURL: URL?

    enum CartridgeError: Error, LocalizedError {
        case tooSmall
        case invalidHeader
        var errorDescription: String? {
            switch self {
            case .tooSmall: return "ROM file too small"
            case .invalidHeader: return "Invalid ROM header"
            }
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

        let romSizeByte = rom[headerOffset + 0x17]
        self.romSizeKB = (1 << Int(romSizeByte))

        let sramSizeByte = rom[headerOffset + 0x18]
        self.sramSizeKB = sramSizeByte == 0 ? 0 : (1 << Int(sramSizeByte))

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
}
