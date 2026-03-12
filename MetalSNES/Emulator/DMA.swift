import Foundation

final class DMA {
    struct Channel {
        var control: UInt8 = 0xFF     // $43x0 - direction, mode
        var destReg: UInt8 = 0xFF     // $43x1 - B-bus address
        var srcAddr: UInt16 = 0xFFFF  // $43x2/$43x3
        var srcBank: UInt8 = 0xFF     // $43x4
        var size: UInt16 = 0xFFFF     // $43x5/$43x6 (also HDMA indirect bank)
        var hdmaBank: UInt8 = 0xFF    // $43x7
        var hdmaAddr: UInt16 = 0xFFFF // $43x8/$43x9
        var hdmaLine: UInt8 = 0xFF    // $43xA
        var unused: UInt8 = 0xFF      // $43xB
    }

    var channels = [Channel](repeating: Channel(), count: 8)

    // HDMA per-channel state
    var hdmaActive = [Bool](repeating: false, count: 8)
    var hdmaDoTransfer = [Bool](repeating: false, count: 8)
    var hdmaLineCounter = [UInt8](repeating: 0, count: 8)
    var hdmaTableAddr = [UInt32](repeating: 0, count: 8)   // current read position in table
    var hdmaIndirect = [Bool](repeating: false, count: 8)

    func read(register: UInt16) -> UInt8 {
        let ch = Int((register >> 4) & 0x07)
        let reg = register & 0x0F

        switch reg {
        case 0x00: return channels[ch].control
        case 0x01: return channels[ch].destReg
        case 0x02: return UInt8(channels[ch].srcAddr & 0xFF)
        case 0x03: return UInt8(channels[ch].srcAddr >> 8)
        case 0x04: return channels[ch].srcBank
        case 0x05: return UInt8(channels[ch].size & 0xFF)
        case 0x06: return UInt8(channels[ch].size >> 8)
        case 0x07: return channels[ch].hdmaBank
        case 0x08: return UInt8(channels[ch].hdmaAddr & 0xFF)
        case 0x09: return UInt8(channels[ch].hdmaAddr >> 8)
        case 0x0A: return channels[ch].hdmaLine
        case 0x0B, 0x0F: return channels[ch].unused
        default: return 0xFF
        }
    }

    func write(register: UInt16, value: UInt8) {
        let ch = Int((register >> 4) & 0x07)
        let reg = register & 0x0F

        switch reg {
        case 0x00: channels[ch].control = value
        case 0x01: channels[ch].destReg = value
        case 0x02: channels[ch].srcAddr = (channels[ch].srcAddr & 0xFF00) | UInt16(value)
        case 0x03: channels[ch].srcAddr = (channels[ch].srcAddr & 0x00FF) | (UInt16(value) << 8)
        case 0x04: channels[ch].srcBank = value
        case 0x05: channels[ch].size = (channels[ch].size & 0xFF00) | UInt16(value)
        case 0x06: channels[ch].size = (channels[ch].size & 0x00FF) | (UInt16(value) << 8)
        case 0x07: channels[ch].hdmaBank = value
        case 0x08: channels[ch].hdmaAddr = (channels[ch].hdmaAddr & 0xFF00) | UInt16(value)
        case 0x09: channels[ch].hdmaAddr = (channels[ch].hdmaAddr & 0x00FF) | (UInt16(value) << 8)
        case 0x0A: channels[ch].hdmaLine = value
        case 0x0B, 0x0F: channels[ch].unused = value
        default: break
        }
    }

    var dmaLogCount = 0

    func executeGeneralDMA(channels mask: UInt8, bus: Bus) -> Int {
        var activeChannelCount = 0
        var transferredBytes = 0

        for ch in 0..<8 {
            guard (mask & (1 << ch)) != 0 else { continue }
            activeChannelCount += 1

            let channel = channels[ch]
            let direction = (channel.control & 0x80) != 0 // true = B→A (PPU to CPU)
            let mode = channel.control & 0x07
            transferredBytes += channel.size == 0 ? 0x10000 : Int(channel.size)

            if EmulatorCore.debugLogging && dmaLogCount < 80 {
                let dest = 0x2100 + Int(channel.destReg)
                let src = (UInt32(channel.srcBank) << 16) | UInt32(channel.srcAddr)
                let vmainc = bus.ppu.vmainc
                let vramWord = UInt16(bus.ppu.vmaddl) | (UInt16(bus.ppu.vmaddh) << 8)
                let vramByte = Int(vramWord) * 2
                let xferSize = channel.size == 0 ? 0x10000 : Int(channel.size)
                let isVRAM = channel.destReg == 0x18 || channel.destReg == 0x19
                print(String(format: "[DMA] ch%d: %@ $%06X → $%04X  size=%-5d mode=%d vmainc=$%02X vramW=$%04X byte=$%04X%@",
                             ch, direction ? "B→A" : "A→B", src, dest,
                             xferSize, mode, vmainc, vramWord, vramByte,
                             isVRAM ? " ←VRAM" : ""))
                if isVRAM && !direction {
                    let wordsWritten = mode == 1 ? xferSize / 2 : xferSize
                    let inc: Int
                    switch vmainc & 0x03 {
                    case 0: inc = 1; case 1: inc = 32; default: inc = 128
                    }
                    print(String(format: "       VRAM byte: $%04X → $%04X  (%d words, inc=%d)",
                                 vramByte, vramByte + wordsWritten * inc * 2, wordsWritten, inc))
                }
                fflush(stdout)
                dmaLogCount += 1
            }
            let fixedSource = (channel.control & 0x08) != 0
            let decrement = (channel.control & 0x10) != 0

            let bAddr = UInt16(0x2100) + UInt16(channel.destReg)

            var aAddr = channel.srcAddr
            let aBank = channel.srcBank
            var remaining: UInt32 = UInt32(channel.size)
            if remaining == 0 { remaining = 0x10000 }

            // Pre-compute offsets once per channel (avoid per-iteration heap alloc)
            let offsets: (UInt16, UInt16, UInt16, UInt16)
            let offsetCount: Int
            switch mode {
            case 0:     offsets = (0, 0, 0, 0); offsetCount = 1
            case 1:     offsets = (0, 1, 0, 0); offsetCount = 2
            case 2, 6:  offsets = (0, 0, 0, 0); offsetCount = 2
            case 3, 7:  offsets = (0, 0, 1, 1); offsetCount = 4
            case 4:     offsets = (0, 1, 2, 3); offsetCount = 4
            case 5:     offsets = (0, 1, 0, 1); offsetCount = 4
            default:    offsets = (0, 0, 0, 0); offsetCount = 1
            }

            while remaining > 0 {
                for oi in 0..<offsetCount {
                    let off: UInt16
                    switch oi {
                    case 0: off = offsets.0
                    case 1: off = offsets.1
                    case 2: off = offsets.2
                    default: off = offsets.3
                    }
                    guard remaining > 0 else { break }

                    let aFullAddr = (UInt32(aBank) << 16) | UInt32(aAddr)
                    let bFullAddr = UInt32(bAddr + off)

                    if direction {
                        // B→A: read from PPU reg, write to CPU memory
                        let val = bus.read(bFullAddr)
                        bus.write(aFullAddr, value: val)
                    } else {
                        // A→B: read from CPU memory, write to PPU reg
                        let val = bus.read(aFullAddr)
                        bus.write(bFullAddr, value: val)
                    }

                    if !fixedSource {
                        if decrement {
                            aAddr &-= 1
                        } else {
                            aAddr &+= 1
                        }
                    }
                    remaining -= 1
                }
            }

            channels[ch].srcAddr = aAddr
            channels[ch].size = 0
        }

        guard activeChannelCount > 0 else { return 0 }
        return 8 + activeChannelCount * 8 + transferredBytes * 8
    }

    // MARK: - HDMA

    /// Returns the number of bytes transferred per HDMA unit for a given transfer mode.
    private func hdmaTransferSize(mode: UInt8) -> Int {
        switch mode & 0x07 {
        case 0:    return 1   // 1 reg, 1 byte
        case 1:    return 2   // 2 regs (reg, reg+1)
        case 2, 6: return 2   // 1 reg written twice
        case 3, 7: return 4   // 2 regs each written twice
        case 4:    return 4   // 4 regs
        case 5:    return 4   // 2 regs each written twice (alt pattern)
        default:   return 1
        }
    }

    /// B-bus offset table for a given transfer mode (same logic as general DMA).
    private func hdmaOffsets(mode: UInt8) -> (offsets: (UInt16, UInt16, UInt16, UInt16), count: Int) {
        switch mode & 0x07 {
        case 0:     return ((0, 0, 0, 0), 1)
        case 1:     return ((0, 1, 0, 0), 2)
        case 2, 6:  return ((0, 0, 0, 0), 2)
        case 3, 7:  return ((0, 0, 1, 1), 4)
        case 4:     return ((0, 1, 2, 3), 4)
        case 5:     return ((0, 1, 0, 1), 4)
        default:    return ((0, 0, 0, 0), 1)
        }
    }

    /// Called once at the start of each frame (scanline 0) to initialize HDMA channels.
    func initHDMA(channels mask: UInt8, bus: Bus) {
        for ch in 0..<8 {
            guard (mask & (1 << ch)) != 0 else {
                hdmaActive[ch] = false
                continue
            }

            let indirect = (channels[ch].control & 0x40) != 0
            hdmaIndirect[ch] = indirect

            // Set table address from srcBank:srcAddr
            let tableAddr = (UInt32(channels[ch].srcBank) << 16) | UInt32(channels[ch].srcAddr)
            hdmaTableAddr[ch] = tableAddr

            // Read the first line-counter byte
            let counter = bus.read(hdmaTableAddr[ch])
            hdmaTableAddr[ch] &+= 1

            if counter == 0 {
                hdmaActive[ch] = false
                continue
            }

            // In indirect mode, read 2-byte pointer from table
            if indirect {
                let lo = UInt16(bus.read(hdmaTableAddr[ch]))
                hdmaTableAddr[ch] &+= 1
                let hi = UInt16(bus.read(hdmaTableAddr[ch]))
                hdmaTableAddr[ch] &+= 1
                channels[ch].hdmaAddr = lo | (hi << 8)
            }

            hdmaActive[ch] = true
            hdmaLineCounter[ch] = counter
            hdmaDoTransfer[ch] = true
        }
    }

    /// Called once per visible scanline (0..<224) to execute HDMA transfers.
    func doHDMA(channels mask: UInt8, bus: Bus) {
        for ch in 0..<8 {
            guard (mask & (1 << ch)) != 0, hdmaActive[ch] else { continue }

            let channel = channels[ch]
            let mode = channel.control & 0x07
            let bAddr = UInt16(0x2100) + UInt16(channel.destReg)
            let indirect = hdmaIndirect[ch]

            // Transfer data if flagged
            if hdmaDoTransfer[ch] {
                let (offsets, count) = hdmaOffsets(mode: mode)
                for oi in 0..<count {
                    let off: UInt16
                    switch oi {
                    case 0: off = offsets.0
                    case 1: off = offsets.1
                    case 2: off = offsets.2
                    default: off = offsets.3
                    }

                    let srcVal: UInt8
                    if indirect {
                        // Read from hdmaBank:hdmaAddr
                        let indirectAddr = (UInt32(channels[ch].hdmaBank) << 16) | UInt32(channels[ch].hdmaAddr)
                        srcVal = bus.read(indirectAddr)
                        channels[ch].hdmaAddr &+= 1
                    } else {
                        srcVal = bus.read(hdmaTableAddr[ch])
                        hdmaTableAddr[ch] &+= 1
                    }

                    let bFullAddr = UInt32(bAddr + off)
                    bus.write(bFullAddr, value: srcVal)
                }
            }

            // Decrement line counter (bits 0-6 only)
            let repeat_ = (hdmaLineCounter[ch] & 0x80) != 0
            var count = hdmaLineCounter[ch] & 0x7F
            count &-= 1

            if count == 0 {
                // Read next entry's line counter from the table
                let nextCounter = bus.read(hdmaTableAddr[ch])
                hdmaTableAddr[ch] &+= 1

                if nextCounter == 0 {
                    // HDMA terminates for this channel
                    hdmaActive[ch] = false
                    continue
                }

                // In indirect mode, read 2-byte pointer for the new entry
                if indirect {
                    let lo = UInt16(bus.read(hdmaTableAddr[ch]))
                    hdmaTableAddr[ch] &+= 1
                    let hi = UInt16(bus.read(hdmaTableAddr[ch]))
                    hdmaTableAddr[ch] &+= 1
                    channels[ch].hdmaAddr = lo | (hi << 8)
                }

                hdmaLineCounter[ch] = nextCounter
                hdmaDoTransfer[ch] = true
            } else {
                hdmaLineCounter[ch] = (hdmaLineCounter[ch] & 0x80) | count
                // Transfer next scanline only if repeat flag is set
                hdmaDoTransfer[ch] = repeat_
            }
        }
    }
}
