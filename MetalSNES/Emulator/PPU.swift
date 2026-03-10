import Foundation

final class PPU {
    // VRAM - 64KB (32K words)
    var vram = [UInt8](repeating: 0, count: SNESConstants.vramSize)
    // OAM - 544 bytes
    var oam = [UInt8](repeating: 0, count: SNESConstants.oamSize)
    // CGRAM - 512 bytes (256 colors, 15-bit BGR)
    var cgram = [UInt8](repeating: 0, count: SNESConstants.cgramSize)

    // Framebuffer (double-buffered)
    private let fbSize = SNESConstants.screenWidth * SNESConstants.screenHeight * SNESConstants.bytesPerPixel
    var frontBuffer: UnsafeMutableBufferPointer<UInt8>
    var backBuffer: UnsafeMutableBufferPointer<UInt8>

    // Registers
    var inidisp: UInt8 = 0x80   // $2100 - forced blank on
    var objsel: UInt8 = 0       // $2101
    var oamaddl: UInt8 = 0      // $2102
    var oamaddh: UInt8 = 0      // $2103
    var bgmode: UInt8 = 0       // $2105
    var mosaic: UInt8 = 0       // $2106

    var bg1sc: UInt8 = 0        // $2107
    var bg2sc: UInt8 = 0        // $2108
    var bg3sc: UInt8 = 0        // $2109
    var bg4sc: UInt8 = 0        // $210A

    var bg12nba: UInt8 = 0      // $210B
    var bg34nba: UInt8 = 0      // $210C

    // BG scroll (per BG, H and V)
    var bgHScroll = [UInt16](repeating: 0, count: 4)
    var bgVScroll = [UInt16](repeating: 0, count: 4)
    private var scrollLatch: UInt8 = 0

    var vmainc: UInt8 = 0       // $2115
    var vmaddl: UInt8 = 0       // $2116
    var vmaddh: UInt8 = 0       // $2117
    private var vramPrefetch: UInt16 = 0

    var tm: UInt8 = 0           // $212C - main screen designation
    var ts: UInt8 = 0           // $212D - sub screen designation
    var cgwsel: UInt8 = 0       // $2130
    var cgadsub: UInt8 = 0      // $2131
    var coldata: UInt8 = 0      // $2132
    var setini: UInt8 = 0       // $2133

    // Fixed color for color math (parsed from COLDATA writes)
    private var fixedColorR: UInt8 = 0
    private var fixedColorG: UInt8 = 0
    private var fixedColorB: UInt8 = 0

    // Internal state
    private var oamAddr: UInt16 = 0
    private var oamLatch: UInt8 = 0
    private var cgramAddr: UInt16 = 0
    private var cgramLatch: UInt8 = 0
    private var cgramFlipFlop = false

    // Mode 7
    var m7sel: UInt8 = 0
    var m7a: UInt16 = 0
    var m7b: UInt16 = 0
    var m7c: UInt16 = 0
    var m7d: UInt16 = 0
    var m7x: UInt16 = 0
    var m7y: UInt16 = 0
    private var m7Latch: UInt8 = 0
    private var mpyResult: Int32 = 0

    // Window
    var w12sel: UInt8 = 0       // $2123
    var w34sel: UInt8 = 0       // $2124
    var wobjsel: UInt8 = 0      // $2125
    var wh0: UInt8 = 0
    var wh1: UInt8 = 0
    var wh2: UInt8 = 0
    var wh3: UInt8 = 0
    var wbglog: UInt8 = 0       // $212A
    var wobjlog: UInt8 = 0      // $212B
    var tmw: UInt8 = 0          // $212E
    var tsw: UInt8 = 0          // $212F

    // VRAM address helper
    private var vramAddr: UInt16 {
        get { UInt16(vmaddl) | (UInt16(vmaddh) << 8) }
        set {
            vmaddl = UInt8(newValue & 0xFF)
            vmaddh = UInt8(newValue >> 8)
        }
    }

    // Apply VRAM address translation (VMAINC bits 2-3)
    // This remaps addresses for interleaved bitplane tile formats
    private func translateVRAMAddr(_ addr: UInt16) -> UInt16 {
        switch (vmainc >> 2) & 0x03 {
        case 0: return addr  // No remapping
        case 1: // aaaaaaaaBBBccccc → aaaaaaaacccccBBB (8-bit rotate)
            let high = addr & 0xFF00
            let low3 = (addr >> 5) & 0x07
            let mid5 = (addr & 0x1F) << 3
            return high | mid5 | low3
        case 2: // aaaaaaaBBBcccccc → aaaaaaaccccccBBB (9-bit rotate)
            let high = addr & 0xFE00
            let low3 = (addr >> 6) & 0x07
            let mid6 = (addr & 0x3F) << 3
            return high | mid6 | low3
        case 3: // aaaaaaBBBccccccc → aaaaaacccccccBBB (10-bit rotate)
            let high = addr & 0xFC00
            let low3 = (addr >> 7) & 0x07
            let mid7 = (addr & 0x7F) << 3
            return high | mid7 | low3
        default: return addr
        }
    }

    private var vramIncrement: UInt16 {
        switch vmainc & 0x03 {
        case 0: return 1
        case 1: return 32
        default: return 128
        }
    }

    private var vramIncrementOnHigh: Bool {
        return (vmainc & 0x80) != 0
    }

    // Color math / subscreen support
    private var subScreenBuffer: UnsafeMutableBufferPointer<UInt8>
    private var mainLayerLine = [UInt8](repeating: 0, count: 256) // 0=backdrop, 1=BG1..4=BG4, 5=OBJ
    private var pixelZ = [UInt8](repeating: 0, count: 256)  // z-order per pixel for priority compositing
    private var _renderingSubScreen = false
    private var _currentLayer: UInt8 = 0

    init() {
        let frontPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: fbSize)
        frontPtr.initialize(repeating: 0, count: fbSize)
        frontBuffer = UnsafeMutableBufferPointer(start: frontPtr, count: fbSize)

        let backPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: fbSize)
        backPtr.initialize(repeating: 0, count: fbSize)
        backBuffer = UnsafeMutableBufferPointer(start: backPtr, count: fbSize)

        let subPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: fbSize)
        subPtr.initialize(repeating: 0, count: fbSize)
        subScreenBuffer = UnsafeMutableBufferPointer(start: subPtr, count: fbSize)
    }

    deinit {
        frontBuffer.baseAddress?.deallocate()
        backBuffer.baseAddress?.deallocate()
        subScreenBuffer.baseAddress?.deallocate()
    }

    // MARK: - Register access

    func read(register: UInt16) -> UInt8 {
        switch register {
        case 0x2134: // MPYL - multiplication result low byte
            return UInt8(truncatingIfNeeded: mpyResult)
        case 0x2135: // MPYM - multiplication result mid byte
            return UInt8(truncatingIfNeeded: mpyResult >> 8)
        case 0x2136: // MPYH - multiplication result high byte
            return UInt8(truncatingIfNeeded: mpyResult >> 16)
        case 0x2137: return 0 // SLHV - latch H/V counter
        case 0x2138:          // OAM data read
            let addr = Int(oamAddr)
            let val = addr < oam.count ? oam[addr] : 0
            oamAddr = (oamAddr + 1) % UInt16(oam.count)
            return val
        case 0x2139:          // VRAM data read low
            let val = UInt8(vramPrefetch & 0xFF)
            if !vramIncrementOnHigh {
                let translated = translateVRAMAddr(vramAddr)
                let a = Int(translated &* 2)
                vramPrefetch = UInt16(vram[a & 0xFFFF]) | (UInt16(vram[(a + 1) & 0xFFFF]) << 8)
                vramAddr &+= vramIncrement
            }
            return val
        case 0x213A:          // VRAM data read high
            let val = UInt8(vramPrefetch >> 8)
            if vramIncrementOnHigh {
                let translated = translateVRAMAddr(vramAddr)
                let a = Int(translated &* 2)
                vramPrefetch = UInt16(vram[a & 0xFFFF]) | (UInt16(vram[(a + 1) & 0xFFFF]) << 8)
                vramAddr &+= vramIncrement
            }
            return val
        case 0x213B:          // CGRAM data read
            let addr = Int(cgramAddr)
            let val: UInt8
            if !cgramFlipFlop {
                val = cgram[addr & 0x1FF]
            } else {
                val = cgram[(addr | 1) & 0x1FF]
                cgramAddr += 2
            }
            cgramFlipFlop.toggle()
            return val
        case 0x213C: return 0 // OPHCT
        case 0x213D: return 0 // OPVCT
        case 0x213E: return 0x01 // STAT77 - PPU1 version
        case 0x213F: return 0x01 // STAT78 - PPU2 version
        default: return 0
        }
    }

    func write(register: UInt16, value: UInt8) {
        switch register {
        case 0x2100: inidisp = value
        case 0x2101: objsel = value
        case 0x2102:
            oamaddl = value
            oamAddr = (UInt16(oamaddh & 0x01) << 8 | UInt16(value)) << 1
        case 0x2103:
            oamaddh = value
            oamAddr = (UInt16(value & 0x01) << 8 | UInt16(oamaddl)) << 1
        case 0x2104: // OAM data write
            if oamAddr >= 0x200 {
                oam[0x200 + (Int(oamAddr) & 0x1F)] = value
                oamAddr = (oamAddr + 1) % 0x220
            } else if (oamAddr & 1) == 0 {
                oamLatch = value
                oamAddr += 1
            } else {
                oam[Int(oamAddr - 1) & 0x1FF] = oamLatch
                oam[Int(oamAddr) & 0x1FF] = value
                oamAddr += 1
            }
        case 0x2105: bgmode = value
        case 0x2106: mosaic = value
        case 0x2107: bg1sc = value
        case 0x2108: bg2sc = value
        case 0x2109: bg3sc = value
        case 0x210A: bg4sc = value
        case 0x210B: bg12nba = value
        case 0x210C: bg34nba = value

        // BG scroll registers (write-twice)
        // Each write: scroll = (new_value << 8) | previous_latch
        // After two writes: high byte = second write, low byte = first write
        case 0x210D:
            bgHScroll[0] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x210E:
            bgVScroll[0] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x210F:
            bgHScroll[1] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x2110:
            bgVScroll[1] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x2111:
            bgHScroll[2] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x2112:
            bgVScroll[2] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x2113:
            bgHScroll[3] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value
        case 0x2114:
            bgVScroll[3] = (UInt16(value) << 8) | UInt16(scrollLatch)
            scrollLatch = value

        case 0x2115: vmainc = value
        case 0x2116:
            vmaddl = value
            let translated0 = translateVRAMAddr(vramAddr)
            let a0 = Int(translated0 &* 2)
            vramPrefetch = UInt16(vram[a0 & 0xFFFF]) | (UInt16(vram[(a0+1) & 0xFFFF]) << 8)
        case 0x2117:
            vmaddh = value
            let translated1 = translateVRAMAddr(vramAddr)
            let a1 = Int(translated1 &* 2)
            vramPrefetch = UInt16(vram[a1 & 0xFFFF]) | (UInt16(vram[(a1+1) & 0xFFFF]) << 8)

        case 0x2118: // VRAM data write low
            let translated = translateVRAMAddr(vramAddr)
            let a = Int(translated &* 2) & 0xFFFF
            vram[a] = value
            if !vramIncrementOnHigh {
                vramAddr &+= vramIncrement
            }
        case 0x2119: // VRAM data write high
            let translated = translateVRAMAddr(vramAddr)
            let a = (Int(translated &* 2) + 1) & 0xFFFF
            vram[a] = value
            if vramIncrementOnHigh {
                vramAddr &+= vramIncrement
            }

        case 0x211A: m7sel = value
        case 0x211B:
            m7a = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value
        case 0x211C:
            m7b = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value
            // Compute MPY result: signed 16-bit M7A × signed 8-bit (M7B high byte)
            mpyResult = Int32(Int16(bitPattern: m7a)) &* Int32(Int8(bitPattern: UInt8(m7b >> 8)))
        case 0x211D:
            m7c = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value
        case 0x211E:
            m7d = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value
        case 0x211F:
            m7x = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value
        case 0x2120:
            m7y = UInt16(value) << 8 | UInt16(m7Latch)
            m7Latch = value

        case 0x2121: // CGRAM address
            cgramAddr = UInt16(value) * 2
            cgramFlipFlop = false
        case 0x2122: // CGRAM data write
            if !cgramFlipFlop {
                cgramLatch = value
            } else {
                cgram[Int(cgramAddr) & 0x1FE] = cgramLatch
                cgram[Int(cgramAddr | 1) & 0x1FF] = value & 0x7F
                cgramAddr += 2
            }
            cgramFlipFlop.toggle()

        case 0x2123: w12sel = value
        case 0x2124: w34sel = value
        case 0x2125: wobjsel = value
        case 0x2126: wh0 = value
        case 0x2127: wh1 = value
        case 0x2128: wh2 = value
        case 0x2129: wh3 = value
        case 0x212A: wbglog = value
        case 0x212B: wobjlog = value
        case 0x212C: tm = value
        case 0x212D: ts = value
        case 0x212E: tmw = value
        case 0x212F: tsw = value
        case 0x2130: cgwsel = value
        case 0x2131: cgadsub = value
        case 0x2132:
            coldata = value
            let intensity = value & 0x1F
            if (value & 0x20) != 0 { fixedColorR = intensity }
            if (value & 0x40) != 0 { fixedColorG = intensity }
            if (value & 0x80) != 0 { fixedColorB = intensity }
        case 0x2133: setini = value

        default: break
        }
    }

    // MARK: - Scanline rendering

    func renderScanline(_ y: Int) {
        // Build sprite cache once at the start of each frame
        if y == 0 {
            buildSpriteScanlineCache()
        }

        // Forced blank - render black
        if (inidisp & 0x80) != 0 {
            let offset = y * SNESConstants.screenWidth * 4
            for x in 0..<SNESConstants.screenWidth {
                let idx = offset + x * 4
                backBuffer[idx + 0] = 0
                backBuffer[idx + 1] = 0
                backBuffer[idx + 2] = 0
                backBuffer[idx + 3] = 255
            }
            return
        }

        let mode = bgmode & 0x07

        // Clear scanline to backdrop color
        let backdropR: UInt8
        let backdropG: UInt8
        let backdropB: UInt8
        (backdropR, backdropG, backdropB) = colorFromCGRAM(index: 0)

        let offset = y * SNESConstants.screenWidth * 4
        for x in 0..<SNESConstants.screenWidth {
            let idx = offset + x * 4
            backBuffer[idx + 0] = backdropR
            backBuffer[idx + 1] = backdropG
            backBuffer[idx + 2] = backdropB
            backBuffer[idx + 3] = 255
            mainLayerLine[x] = 0  // backdrop
        }

        // Render main screen layers
        _renderingSubScreen = false
        _currentLayer = 0
        for i in 0..<256 { pixelZ[i] = 0 }
        let hasOBJ = (tm & 0x10) != 0
        renderLayers(mode: mode, layerMask: tm, hasOBJ: hasOBJ, scanline: y)

        // Color math: render subscreen and blend
        let colorMathEnable = (cgwsel >> 4) & 0x03  // 0=always, 1=inside window, 2=outside window, 3=never
        if colorMathEnable != 3 && cgadsub != 0 {
            let subSource = (cgwsel >> 6) & 0x03  // 0,1=subscreen, 2,3=fixed color

            if subSource <= 1 && ts != 0 {
                // Render subscreen layers to subScreenBuffer
                for x in 0..<256 {
                    let idx = offset + x * 4
                    subScreenBuffer[idx + 0] = backdropR
                    subScreenBuffer[idx + 1] = backdropG
                    subScreenBuffer[idx + 2] = backdropB
                    subScreenBuffer[idx + 3] = 255
                }
                _renderingSubScreen = true
                for i in 0..<256 { pixelZ[i] = 0 }
                let subHasOBJ = (ts & 0x10) != 0
                renderLayers(mode: mode, layerMask: ts, hasOBJ: subHasOBJ, scanline: y)
                _renderingSubScreen = false
            }

            applyColorMath(offset: offset, subSource: subSource)
        }
    }

    // Z-order tables: (pri0, pri1) for each layer, sprite z-orders (pri0..3)
    // Mode 0: BG4p0=1 BG3p0=2 OBJp0=3 BG4p1=4 BG3p1=5 OBJp1=6 BG2p0=7 BG1p0=8 OBJp2=9 BG2p1=10 BG1p1=11 OBJp3=12
    // Mode 1: BG3p0=1 OBJp0=2 BG3p1=3 OBJp1=4 BG2p0=5 BG1p0=6 OBJp2=7 BG2p1=8 BG1p1=9 OBJp3=10 (BG3p1=11 if bg3top)
    // Mode 3+: BG2p0=1 BG1p0=2 OBJp0=3 OBJp1=4 BG2p1=5 BG1p1=6 OBJp2=7 OBJp3=8

    private func renderLayers(mode: UInt8, layerMask: UInt8, hasOBJ: Bool, scanline y: Int) {
        switch mode {
        case 0:
            // Each layer renders ONCE with z-order values for tile pri 0 and 1
            if (layerMask & 0x08) != 0 { _currentLayer = 4; renderBG2bpp(bg: 3, scanline: y, paletteBase: 96, zOrder0: 1, zOrder1: 4) }
            if (layerMask & 0x04) != 0 { _currentLayer = 3; renderBG2bpp(bg: 2, scanline: y, paletteBase: 64, zOrder0: 2, zOrder1: 5) }
            if (layerMask & 0x02) != 0 { _currentLayer = 2; renderBG2bpp(bg: 1, scanline: y, paletteBase: 32, zOrder0: 7, zOrder1: 10) }
            if (layerMask & 0x01) != 0 { _currentLayer = 1; renderBG2bpp(bg: 0, scanline: y, paletteBase: 0, zOrder0: 8, zOrder1: 11) }
            if hasOBJ { _currentLayer = 5; renderSprites(scanline: y, zOrders: (3, 6, 9, 12)) }
        case 1:
            let bg3top = (bgmode & 0x08) != 0
            if (layerMask & 0x04) != 0 { _currentLayer = 3; renderBG2bpp(bg: 2, scanline: y, paletteBase: 0, zOrder0: 1, zOrder1: bg3top ? 11 : 3) }
            if (layerMask & 0x02) != 0 { _currentLayer = 2; renderBG4bpp(bg: 1, scanline: y, zOrder0: 5, zOrder1: 8) }
            if (layerMask & 0x01) != 0 { _currentLayer = 1; renderBG4bpp(bg: 0, scanline: y, zOrder0: 6, zOrder1: 9) }
            if hasOBJ { _currentLayer = 5; renderSprites(scanline: y, zOrders: (2, 4, 7, 10)) }
        case 3:
            if (layerMask & 0x02) != 0 { _currentLayer = 2; renderBG4bpp(bg: 1, scanline: y, zOrder0: 1, zOrder1: 5) }
            if (layerMask & 0x01) != 0 { _currentLayer = 1; renderBG8bpp(bg: 0, scanline: y, zOrder0: 2, zOrder1: 6) }
            if hasOBJ { _currentLayer = 5; renderSprites(scanline: y, zOrders: (3, 4, 7, 8)) }
        case 2, 4, 5, 6:
            if (layerMask & 0x02) != 0 { _currentLayer = 2; renderBG4bpp(bg: 1, scanline: y, zOrder0: 1, zOrder1: 5) }
            if (layerMask & 0x01) != 0 { _currentLayer = 1; renderBG4bpp(bg: 0, scanline: y, zOrder0: 2, zOrder1: 6) }
            if hasOBJ { _currentLayer = 5; renderSprites(scanline: y, zOrders: (3, 4, 7, 8)) }
        case 7:
            if (layerMask & 0x01) != 0 { _currentLayer = 1; renderMode7(scanline: y) }
            if hasOBJ { _currentLayer = 5; renderSprites(scanline: y, zOrders: (1, 2, 3, 4)) }
        default:
            break
        }
    }

    private func applyColorMath(offset: Int, subSource: UInt8) {
        let subtract = (cgadsub & 0x80) != 0
        let half = (cgadsub & 0x40) != 0

        // Fixed color from COLDATA ($2132)
        let fixedR = (coldata & 0x20) != 0 ? Int(coldata & 0x1F) << 3 : 0
        let fixedG = (coldata & 0x40) != 0 ? Int(coldata & 0x1F) << 3 : 0
        let fixedB = (coldata & 0x80) != 0 ? Int(coldata & 0x1F) << 3 : 0

        for x in 0..<256 {
            let layer = mainLayerLine[x]

            // cgadsub bits: 0=BG1, 1=BG2, 2=BG3, 3=BG4, 4=OBJ, 5=backdrop
            let layerBit: UInt8
            switch layer {
            case 0: layerBit = 0x20  // backdrop
            case 1: layerBit = 0x01  // BG1
            case 2: layerBit = 0x02  // BG2
            case 3: layerBit = 0x04  // BG3
            case 4: layerBit = 0x08  // BG4
            case 5: layerBit = 0x10  // OBJ
            default: continue
            }

            guard (cgadsub & layerBit) != 0 else { continue }

            let idx = offset + x * 4
            let mainR = Int(backBuffer[idx + 0])
            let mainG = Int(backBuffer[idx + 1])
            let mainB = Int(backBuffer[idx + 2])

            let subR: Int, subG: Int, subB: Int
            if subSource >= 2 {
                subR = fixedR; subG = fixedG; subB = fixedB
            } else {
                let si = offset + x * 4
                subR = Int(subScreenBuffer[si + 0])
                subG = Int(subScreenBuffer[si + 1])
                subB = Int(subScreenBuffer[si + 2])
            }

            var r: Int, g: Int, b: Int
            if subtract {
                r = mainR - subR; g = mainG - subG; b = mainB - subB
            } else {
                r = mainR + subR; g = mainG + subG; b = mainB + subB
            }

            if half { r >>= 1; g >>= 1; b >>= 1 }

            backBuffer[idx + 0] = UInt8(max(0, min(255, r)))
            backBuffer[idx + 1] = UInt8(max(0, min(255, g)))
            backBuffer[idx + 2] = UInt8(max(0, min(255, b)))
        }
    }

    private func renderBG4bpp(bg: Int, scanline: Int, tilePriority: Int? = nil, zOrder0: UInt8 = 1, zOrder1: UInt8 = 2) {
        let scReg: UInt8
        switch bg {
        case 0: scReg = bg1sc
        case 1: scReg = bg2sc
        case 2: scReg = bg3sc
        case 3: scReg = bg4sc
        default: return
        }

        let tilemapBase = Int(scReg & 0xFC) << 9  // word→byte: SC gives word addr, vram[] is byte-indexed
        let tileSize = (bgmode & (1 << (4 + bg))) != 0 ? 16 : 8

        // Chr base: each nibble = 4K words = 8KB bytes
        let chrBase: Int
        if bg < 2 {
            chrBase = bg == 0 ? (Int(bg12nba & 0x0F) << 13) : (Int(bg12nba >> 4) << 13)
        } else {
            chrBase = bg == 2 ? (Int(bg34nba & 0x0F) << 13) : (Int(bg34nba >> 4) << 13)
        }

        let hScroll = Int(bgHScroll[bg]) & 0x3FF
        let vScroll = Int(bgVScroll[bg]) & 0x3FF

        let screenY = scanline + vScroll

        let offset = scanline * SNESConstants.screenWidth * 4

        // Tile-first loop: compute tilemap + chr reads once per 8px tile column
        var screenX = 0
        while screenX < 256 {
            let px = screenX + hScroll

            // Determine tile coordinates and sub-tile for 16x16
            let tileX: Int
            let tileY: Int
            let subTileX: Int
            let subTileY: Int

            if tileSize == 16 {
                tileX = (px / 16) & 0x3F
                tileY = (screenY / 16) & 0x3F
                subTileX = (px / 8) & 1
                subTileY = (screenY / 8) & 1
            } else {
                tileX = (px / 8) & 0x3F
                tileY = (screenY / 8) & 0x3F
                subTileX = 0
                subTileY = 0
            }

            // Calculate tilemap address with screen mirroring (ONCE per tile)
            var tmAddr = tilemapBase
            if tileX >= 32 { tmAddr += 0x800 }
            if tileY >= 32 {
                let scSize = scReg & 0x03
                if scSize == 1 { // 64x32 - no vertical mirroring
                } else if scSize == 2 { // 32x64
                    tmAddr += 0x800
                } else if scSize == 3 { // 64x64
                    tmAddr += 0x1000
                }
            }
            tmAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

            // Read tile entry ONCE per tile
            let tileEntry = UInt16(vram[tmAddr & 0xFFFF]) | (UInt16(vram[(tmAddr + 1) & 0xFFFF]) << 8)
            var tileNum = Int(tileEntry & 0x03FF)
            let palette = Int((tileEntry >> 10) & 0x07)
            let tileZ = ((tileEntry >> 13) & 0x01) != 0 ? zOrder1 : zOrder0
            let hFlip = (tileEntry & 0x4000) != 0
            let vFlip = (tileEntry & 0x8000) != 0

            // For 16x16 tiles, adjust tile number for sub-tile position
            if tileSize == 16 {
                let sx = hFlip ? (1 - subTileX) : subTileX
                let sy = vFlip ? (1 - subTileY) : subTileY
                tileNum += sx + sy * 16
            }

            var fineY = screenY & 7
            if vFlip { fineY = 7 - fineY }

            // Read chr bitplane bytes ONCE per tile
            let chrAddr = chrBase + tileNum * 32 + fineY * 2
            let bp0 = vram[chrAddr & 0xFFFF]
            let bp1 = vram[(chrAddr + 1) & 0xFFFF]
            let bp2 = vram[(chrAddr + 16) & 0xFFFF]
            let bp3 = vram[(chrAddr + 17) & 0xFFFF]

            // How many pixels of this 8px tile are visible starting from screenX
            let firstFine = px & 7
            let pixelsInTile = min(8 - firstFine, 256 - screenX)

            // Inner loop: extract bits for each pixel in this tile slice
            for i in 0..<pixelsInTile {
                let fineX = hFlip ? (7 - (firstFine + i)) : (firstFine + i)
                let bit = 7 - fineX
                let pixel = ((bp0 >> bit) & 1) |
                            (((bp1 >> bit) & 1) << 1) |
                            (((bp2 >> bit) & 1) << 2) |
                            (((bp3 >> bit) & 1) << 3)

                if pixel != 0 {
                    let colorIdx = palette * 16 + Int(pixel)
                    let (r, g, b) = colorFromCGRAM(index: colorIdx)
                    let idx = offset + (screenX + i) * 4
                    writePixel(idx, screenX + i, r: r, g: g, b: b, z: tileZ)
                }
            }

            screenX += pixelsInTile
        }
    }

    private func renderBG8bpp(bg: Int, scanline: Int, tilePriority: Int? = nil, zOrder0: UInt8 = 1, zOrder1: UInt8 = 2) {
        let scReg: UInt8
        switch bg {
        case 0: scReg = bg1sc
        case 1: scReg = bg2sc
        case 2: scReg = bg3sc
        case 3: scReg = bg4sc
        default: return
        }

        let tilemapBase = Int(scReg & 0xFC) << 9
        let tileSize = (bgmode & (1 << (4 + bg))) != 0 ? 16 : 8

        let chrBase: Int
        if bg < 2 {
            chrBase = bg == 0 ? (Int(bg12nba & 0x0F) << 13) : (Int(bg12nba >> 4) << 13)
        } else {
            chrBase = bg == 2 ? (Int(bg34nba & 0x0F) << 13) : (Int(bg34nba >> 4) << 13)
        }

        let hScroll = Int(bgHScroll[bg]) & 0x3FF
        let vScroll = Int(bgVScroll[bg]) & 0x3FF
        let screenY = scanline + vScroll
        let offset = scanline * SNESConstants.screenWidth * 4

        var screenX = 0
        while screenX < 256 {
            let px = screenX + hScroll

            let tileX: Int, tileY: Int, subTileX: Int, subTileY: Int
            if tileSize == 16 {
                tileX = (px / 16) & 0x3F; tileY = (screenY / 16) & 0x3F
                subTileX = (px / 8) & 1; subTileY = (screenY / 8) & 1
            } else {
                tileX = (px / 8) & 0x3F; tileY = (screenY / 8) & 0x3F
                subTileX = 0; subTileY = 0
            }

            var tmAddr = tilemapBase
            if tileX >= 32 { tmAddr += 0x800 }
            if tileY >= 32 {
                let scSize = scReg & 0x03
                if scSize == 1 { }
                else if scSize == 2 { tmAddr += 0x800 }
                else if scSize == 3 { tmAddr += 0x1000 }
            }
            tmAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

            let tileEntry = UInt16(vram[tmAddr & 0xFFFF]) | (UInt16(vram[(tmAddr + 1) & 0xFFFF]) << 8)
            var tileNum = Int(tileEntry & 0x03FF)
            let tileZ = ((tileEntry >> 13) & 0x01) != 0 ? zOrder1 : zOrder0
            let hFlip = (tileEntry & 0x4000) != 0
            let vFlip = (tileEntry & 0x8000) != 0

            if tileSize == 16 {
                let sx = hFlip ? (1 - subTileX) : subTileX
                let sy = vFlip ? (1 - subTileY) : subTileY
                tileNum += sx + sy * 16
            }

            var fineY = screenY & 7
            if vFlip { fineY = 7 - fineY }

            // 8bpp: 64 bytes per tile
            let chrAddr = chrBase + tileNum * 64 + fineY * 2
            let bp0 = vram[chrAddr & 0xFFFF]
            let bp1 = vram[(chrAddr + 1) & 0xFFFF]
            let bp2 = vram[(chrAddr + 16) & 0xFFFF]
            let bp3 = vram[(chrAddr + 17) & 0xFFFF]
            let bp4 = vram[(chrAddr + 32) & 0xFFFF]
            let bp5 = vram[(chrAddr + 33) & 0xFFFF]
            let bp6 = vram[(chrAddr + 48) & 0xFFFF]
            let bp7 = vram[(chrAddr + 49) & 0xFFFF]

            let firstFine = px & 7
            let pixelsInTile = min(8 - firstFine, 256 - screenX)

            for i in 0..<pixelsInTile {
                let fineX = hFlip ? (7 - (firstFine + i)) : (firstFine + i)
                let bit = 7 - fineX
                let pixel = ((bp0 >> bit) & 1) |
                            (((bp1 >> bit) & 1) << 1) |
                            (((bp2 >> bit) & 1) << 2) |
                            (((bp3 >> bit) & 1) << 3) |
                            (((bp4 >> bit) & 1) << 4) |
                            (((bp5 >> bit) & 1) << 5) |
                            (((bp6 >> bit) & 1) << 6) |
                            (((bp7 >> bit) & 1) << 7)

                if pixel != 0 {
                    let colorIdx = Int(pixel)
                    let (r, g, b) = colorFromCGRAM(index: colorIdx)
                    let idx = offset + (screenX + i) * 4
                    writePixel(idx, screenX + i, r: r, g: g, b: b, z: tileZ)
                }
            }

            screenX += pixelsInTile
        }
    }

    private func renderBG2bpp(bg: Int, scanline: Int, paletteBase: Int, tilePriority: Int? = nil, zOrder0: UInt8 = 1, zOrder1: UInt8 = 2) {
        let scReg: UInt8
        switch bg {
        case 0: scReg = bg1sc
        case 1: scReg = bg2sc
        case 2: scReg = bg3sc
        case 3: scReg = bg4sc
        default: return
        }

        let tilemapBase = Int(scReg & 0xFC) << 9  // word→byte: SC gives word addr, vram[] is byte-indexed
        let tileSize = (bgmode & (1 << (4 + bg))) != 0 ? 16 : 8

        // Chr base: each nibble = 4K words = 8KB bytes
        let chrBase: Int
        if bg < 2 {
            chrBase = bg == 0 ? (Int(bg12nba & 0x0F) << 13) : (Int(bg12nba >> 4) << 13)
        } else {
            chrBase = bg == 2 ? (Int(bg34nba & 0x0F) << 13) : (Int(bg34nba >> 4) << 13)
        }

        let hScroll = Int(bgHScroll[bg]) & 0x3FF
        let vScroll = Int(bgVScroll[bg]) & 0x3FF

        let screenY = scanline + vScroll

        let offset = scanline * SNESConstants.screenWidth * 4

        // Tile-first loop: compute tilemap + chr reads once per 8px tile column
        var screenX = 0
        while screenX < 256 {
            let px = screenX + hScroll

            // Determine tile coordinates and sub-tile for 16x16
            let tileX: Int
            let tileY: Int
            let subTileX: Int
            let subTileY: Int

            if tileSize == 16 {
                tileX = (px / 16) & 0x3F
                tileY = (screenY / 16) & 0x3F
                subTileX = (px / 8) & 1
                subTileY = (screenY / 8) & 1
            } else {
                tileX = (px / 8) & 0x3F
                tileY = (screenY / 8) & 0x3F
                subTileX = 0
                subTileY = 0
            }

            // Calculate tilemap address with screen mirroring (ONCE per tile)
            var tmAddr = tilemapBase
            if tileX >= 32 { tmAddr += 0x800 }
            if tileY >= 32 {
                let scSize = scReg & 0x03
                if scSize == 2 { // 32x64
                    tmAddr += 0x800
                } else if scSize == 3 { // 64x64
                    tmAddr += 0x1000
                }
            }
            tmAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

            // Read tile entry ONCE per tile
            let tileEntry = UInt16(vram[tmAddr & 0xFFFF]) | (UInt16(vram[(tmAddr + 1) & 0xFFFF]) << 8)
            var tileNum = Int(tileEntry & 0x03FF)
            let palette = Int((tileEntry >> 10) & 0x07)
            let tileZ = ((tileEntry >> 13) & 0x01) != 0 ? zOrder1 : zOrder0
            let hFlip = (tileEntry & 0x4000) != 0
            let vFlip = (tileEntry & 0x8000) != 0

            // For 16x16 tiles, adjust tile number for sub-tile position
            if tileSize == 16 {
                let sx = hFlip ? (1 - subTileX) : subTileX
                let sy = vFlip ? (1 - subTileY) : subTileY
                tileNum += sx + sy * 16
            }

            var fineY = screenY & 7
            if vFlip { fineY = 7 - fineY }

            // Read chr bitplane bytes ONCE per tile (2bpp: 16 bytes per tile)
            let chrAddr = chrBase + tileNum * 16 + fineY * 2
            let bp0 = vram[chrAddr & 0xFFFF]
            let bp1 = vram[(chrAddr + 1) & 0xFFFF]

            // How many pixels of this 8px tile are visible starting from screenX
            let firstFine = px & 7
            let pixelsInTile = min(8 - firstFine, 256 - screenX)

            // Inner loop: extract bits for each pixel in this tile slice
            for i in 0..<pixelsInTile {
                let fineX = hFlip ? (7 - (firstFine + i)) : (firstFine + i)
                let bit = 7 - fineX
                let pixel = ((bp0 >> bit) & 1) | (((bp1 >> bit) & 1) << 1)

                if pixel != 0 {
                    let colorIdx = paletteBase + palette * 4 + Int(pixel)
                    let (r, g, b) = colorFromCGRAM(index: colorIdx)
                    let idx = offset + (screenX + i) * 4
                    writePixel(idx, screenX + i, r: r, g: g, b: b, z: tileZ)
                }
            }

            screenX += pixelsInTile
        }
    }

    private func buildSpriteScanlineCache() {
        // Clear all scanline lists
        for i in 0..<224 {
            spriteScanlineCache[i].removeAll(keepingCapacity: true)
        }

        let baseSize: Int
        let largeSize: Int
        switch (objsel >> 5) & 0x07 {
        case 0: baseSize = 8; largeSize = 16
        case 1: baseSize = 8; largeSize = 32
        case 2: baseSize = 8; largeSize = 64
        case 3: baseSize = 16; largeSize = 32
        case 4: baseSize = 16; largeSize = 64
        case 5: baseSize = 32; largeSize = 64
        default: baseSize = 8; largeSize = 16
        }

        // Iterate in reverse so that lower-index sprites (higher priority) are appended last,
        // matching the existing reverse draw order in renderSprites
        for i in stride(from: 127, through: 0, by: -1) {
            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (oam[highIdx] >> highShift) & 0x03
            let isLarge = (highBits & 0x02) != 0

            let spriteSize = isLarge ? largeSize : baseSize
            let spriteY = (Int(oam[i * 4 + 1]) + 1) & 0xFF

            for scanline in 0..<224 {
                let relY = (scanline - spriteY) & 0xFF
                if relY < spriteSize && spriteScanlineCache[scanline].count < 32 {
                    spriteScanlineCache[scanline].append(i)
                }
            }
        }
    }

    private func renderMode7(scanline: Int, zOrder: UInt8 = 1) {
        // Mode 7: affine-transformed 128x128 tilemap, 8x8 256-color tiles
        // VRAM layout: interleaved - even bytes = tilemap, odd bytes = pixel data
        // Tilemap: 128x128 entries at even byte addresses (byte 0, 2, 4, ...)
        // Tile data: 8x8 256-color pixels at odd byte addresses

        let offset = scanline * SNESConstants.screenWidth * 4

        // Sign-extend Mode 7 parameters (13-bit signed values for center, 16-bit signed for matrix)
        let a = Int32(Int16(bitPattern: m7a))
        let b = Int32(Int16(bitPattern: m7b))
        let c = Int32(Int16(bitPattern: m7c))
        let d = Int32(Int16(bitPattern: m7d))

        // Center coordinates are 13-bit signed
        let cx = Int32((Int16(bitPattern: m7x) << 3)) >> 3
        let cy = Int32((Int16(bitPattern: m7y) << 3)) >> 3

        // Scroll values reuse BG1 scroll registers for Mode 7
        let hOfs = Int32((Int16(bitPattern: bgHScroll[0]) << 3)) >> 3
        let vOfs = Int32((Int16(bitPattern: bgVScroll[0]) << 3)) >> 3

        let screenY = Int32(scanline)

        let hFlip = (m7sel & 0x01) != 0
        let vFlip = (m7sel & 0x02) != 0
        let wrapMode = (m7sel >> 6) & 0x03  // 0=wrap, 1=wrap, 2=transparent, 3=fill with tile 0

        // Apply vertical flip to the effective scanline
        let effectiveY = vFlip ? Int32(255 - scanline) : screenY

        // Affine transform base coordinates
        let xBase = a &* (hOfs &- cx) &+ b &* (vOfs &+ effectiveY &- cy) &+ (cx << 8)
        let yBase = c &* (hOfs &- cx) &+ d &* (vOfs &+ effectiveY &- cy) &+ (cy << 8)

        for screenX in 0..<256 {
            let sx = Int32(hFlip ? (255 - screenX) : screenX)
            // Fixed-point 8.8 coordinates
            let vramX = xBase &+ a &* sx
            let vramY = yBase &+ c &* sx

            // Convert from 8.8 fixed point to pixel coordinates
            var pixelX = Int(vramX >> 8)
            var pixelY = Int(vramY >> 8)

            // Mode 7 playfield is 1024x1024 pixels (128 tiles × 8 pixels)
            let outOfBounds = pixelX < 0 || pixelX >= 1024 || pixelY < 0 || pixelY >= 1024

            if outOfBounds {
                switch wrapMode {
                case 2: continue  // transparent outside
                case 3:
                    // Use tile 0 for out-of-bounds (safe modulo for negative values)
                    let fx = ((pixelX % 8) + 8) % 8
                    let fy = ((pixelY % 8) + 8) % 8
                    let tileDataAddr = (fy * 8 + fx) * 2 + 1
                    let colorIdx = Int(vram[tileDataAddr & 0xFFFF])
                    if colorIdx != 0 {
                        let (r, g, bb) = colorFromCGRAM(index: colorIdx)
                        let idx = offset + screenX * 4
                        writePixel(idx, screenX, r: r, g: g, b: bb, z: zOrder)
                    }
                    continue
                default:
                    // Wrap around
                    pixelX = pixelX & 1023
                    pixelY = pixelY & 1023
                }
            }

            // Get tile number from tilemap (even bytes in VRAM)
            let tileMapX = pixelX >> 3
            let tileMapY = pixelY >> 3
            let tileMapAddr = (tileMapY * 128 + tileMapX) * 2  // even byte addresses
            let tileNum = Int(vram[tileMapAddr & 0xFFFF])

            // Get pixel from tile data (odd bytes, 8x8 256-color)
            let fineX = pixelX & 7
            let fineY = pixelY & 7
            let tileDataAddr = (tileNum * 64 + fineY * 8 + fineX) * 2 + 1
            let colorIdx = Int(vram[tileDataAddr & 0xFFFF])

            if colorIdx != 0 {
                let (r, g, bb) = colorFromCGRAM(index: colorIdx)
                let idx = offset + screenX * 4
                writePixel(idx, screenX, r: r, g: g, b: bb, z: zOrder)
            }
        }
    }

    private func renderSprites(scanline: Int, spritePriority: Int? = nil, zOrders: (UInt8, UInt8, UInt8, UInt8) = (1, 2, 3, 4)) {
        let baseSize: Int
        let largeSize: Int
        switch (objsel >> 5) & 0x07 {
        case 0: baseSize = 8; largeSize = 16
        case 1: baseSize = 8; largeSize = 32
        case 2: baseSize = 8; largeSize = 64
        case 3: baseSize = 16; largeSize = 32
        case 4: baseSize = 16; largeSize = 64
        case 5: baseSize = 32; largeSize = 64
        default: baseSize = 8; largeSize = 16
        }

        let nameBase = Int(objsel & 0x07) << 14
        let nameGap = ((Int(objsel >> 3) & 0x03) + 1) << 13

        let offset = scanline * SNESConstants.screenWidth * 4

        // Process only sprites cached for this scanline
        guard scanline < 224 else { return }
        let cachedSprites = spriteScanlineCache[scanline]

        for i in cachedSprites {
            let baseAddr = i * 4
            let x = Int(oam[baseAddr])
            let y = Int(oam[baseAddr + 1])
            let tile = Int(oam[baseAddr + 2])
            let attr = oam[baseAddr + 3]

            // Extra bits from high OAM table
            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (oam[highIdx] >> highShift) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0

            var spriteX = x
            if xBit9 { spriteX = x - 256 }

            let spriteSize = isLarge ? largeSize : baseSize
            let spriteY = (y + 1) & 0xFF

            let relY = (scanline - Int(spriteY)) & 0xFF

            let palette = Int((attr >> 1) & 0x07) + 8 // sprite palettes 8-15
            let objPriority = Int((attr >> 4) & 0x03)
            let hFlip = (attr & 0x40) != 0
            let vFlip = (attr & 0x80) != 0

            // Z-order based on OAM priority
            let spriteZ: UInt8
            switch objPriority {
            case 0: spriteZ = zOrders.0
            case 1: spriteZ = zOrders.1
            case 2: spriteZ = zOrders.2
            default: spriteZ = zOrders.3
            }
            let nameTable = (attr & 0x01) != 0 ? 1 : 0

            var fineY = relY
            if vFlip { fineY = spriteSize - 1 - fineY }

            let tilesWide = spriteSize / 8

            for tileCol in 0..<tilesWide {
                let drawX = spriteX + tileCol * 8

                let tileRow = fineY / 8
                let mirrorCol = hFlip ? (tilesWide - 1 - tileCol) : tileCol
                let tileNumOffset = tileRow * 16 + mirrorCol
                let actualTile = tile + tileNumOffset

                let chrBase = nameTable == 0 ? nameBase : (nameBase + nameGap)
                let chrAddr = chrBase + (actualTile & 0xFF) * 32 + (fineY & 7) * 2

                let bp0 = vram[chrAddr & 0xFFFF]
                let bp1 = vram[(chrAddr + 1) & 0xFFFF]
                let bp2 = vram[(chrAddr + 16) & 0xFFFF]
                let bp3 = vram[(chrAddr + 17) & 0xFFFF]

                for px in 0..<8 {
                    let screenX = drawX + px
                    guard screenX >= 0, screenX < SNESConstants.screenWidth else { continue }

                    let bit = hFlip ? px : (7 - px)
                    let pixel = ((bp0 >> bit) & 1) |
                                (((bp1 >> bit) & 1) << 1) |
                                (((bp2 >> bit) & 1) << 2) |
                                (((bp3 >> bit) & 1) << 3)

                    if pixel != 0 {
                        let colorIdx = 128 + (palette - 8) * 16 + Int(pixel)
                        let (r, g, b) = colorFromCGRAM(index: colorIdx)
                        let idx = offset + screenX * 4
                        writePixel(idx, screenX, r: r, g: g, b: b, z: spriteZ)
                    }
                }
            }
        }
    }

    // Convert 15-bit BGR from CGRAM to RGB8
    @inline(__always)
    private func colorFromCGRAM(index: Int) -> (UInt8, UInt8, UInt8) {
        let addr = (index * 2) & 0x1FF
        let lo = UInt16(cgram[addr])
        let hi = UInt16(cgram[addr + 1])
        let bgr = lo | (hi << 8)
        let r = UInt8(((bgr >> 0) & 0x1F) << 3)
        let g = UInt8(((bgr >> 5) & 0x1F) << 3)
        let b = UInt8(((bgr >> 10) & 0x1F) << 3)
        return (r, g, b)
    }

    /// Write a pixel to the active render target with z-order priority check
    @inline(__always)
    private func writePixel(_ idx: Int, _ screenX: Int, r: UInt8, g: UInt8, b: UInt8, z: UInt8 = 255) {
        guard z >= pixelZ[screenX] else { return }
        pixelZ[screenX] = z
        if !_renderingSubScreen {
            if isWindowMasked(layer: Int(_currentLayer), screenX: screenX) { return }
            backBuffer[idx + 0] = r
            backBuffer[idx + 1] = g
            backBuffer[idx + 2] = b
            mainLayerLine[screenX] = _currentLayer
        } else {
            subScreenBuffer[idx + 0] = r
            subScreenBuffer[idx + 1] = g
            subScreenBuffer[idx + 2] = b
        }
    }

    // MARK: - Window clipping

    /// Returns true if the pixel at screenX should be masked (hidden) for the given layer.
    /// layer: 1-4 = BG1-BG4, 5 = OBJ (matches _currentLayer values)
    private func isWindowMasked(layer: Int, screenX: Int) -> Bool {
        let w12raw: UInt8
        let wLog: UInt8
        let tmwBit: Bool

        switch layer {
        case 1: // BG1
            w12raw = w12sel
            wLog = wbglog & 0x03
            tmwBit = (tmw & 0x01) != 0
        case 2: // BG2
            w12raw = w12sel >> 4
            wLog = (wbglog >> 2) & 0x03
            tmwBit = (tmw & 0x02) != 0
        case 3: // BG3
            w12raw = w34sel
            wLog = (wbglog >> 4) & 0x03
            tmwBit = (tmw & 0x04) != 0
        case 4: // BG4
            w12raw = w34sel >> 4
            wLog = (wbglog >> 6) & 0x03
            tmwBit = (tmw & 0x08) != 0
        case 5: // OBJ
            w12raw = wobjsel
            wLog = wobjlog & 0x03
            tmwBit = (tmw & 0x10) != 0
        default: return false
        }

        guard tmwBit else { return false }

        let x = screenX

        // Window 1
        let w1enabled = (w12raw & 0x02) != 0
        let w1invert = (w12raw & 0x01) != 0
        var w1inside = false
        if w1enabled {
            w1inside = x >= Int(wh0) && x <= Int(wh1)
            if w1invert { w1inside = !w1inside }
        }

        // Window 2
        let w2enabled = (w12raw & 0x08) != 0
        let w2invert = (w12raw & 0x04) != 0
        var w2inside = false
        if w2enabled {
            w2inside = x >= Int(wh2) && x <= Int(wh3)
            if w2invert { w2inside = !w2inside }
        }

        // Combine
        if w1enabled && w2enabled {
            switch wLog {
            case 0: return w1inside || w2inside
            case 1: return w1inside && w2inside
            case 2: return w1inside != w2inside
            case 3: return w1inside == w2inside
            default: return false
            }
        } else if w1enabled {
            return w1inside
        } else if w2enabled {
            return w2inside
        }
        return false
    }

    // MARK: - Diagnostic dump

    // Per-scanline sprite cache: lists of sprite indices visible on each scanline
    private var spriteScanlineCache: [[Int]] = Array(repeating: [], count: 224)

    var spriteDumpDone = false

    func dumpSpriteState() {
        guard !spriteDumpDone else { return }
        spriteDumpDone = true

        let nameBase = Int(objsel & 0x07) << 14
        let nameGap = ((Int(objsel >> 3) & 0x03) + 1) << 13
        let sizeType = (objsel >> 5) & 0x07
        print(String(format: "[SPRITE DUMP] objsel=0x%02X sizeType=%d nameBase=0x%05X nameGap=0x%04X table1=0x%05X tm=0x%02X",
                      objsel, sizeType, nameBase, nameGap, nameBase + nameGap, tm))

        // Dump OAM entries that use name table 1
        print("[SPRITE DUMP] Name table 1 sprites:")
        for i in 0..<128 {
            let baseAddr = i * 4
            let attr = oam[baseAddr + 3]
            let nameTable = attr & 0x01
            guard nameTable == 1 else { continue }

            let x = Int(oam[baseAddr])
            let y = Int(oam[baseAddr + 1])
            let tile = Int(oam[baseAddr + 2])
            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (oam[highIdx] >> highShift) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0
            var spriteX = x
            if xBit9 { spriteX = x - 256 }
            print(String(format: "  OAM[%3d]: X=%4d Y=%3d tile=0x%02X attr=0x%02X large=%d pal=%d",
                         i, spriteX, y, tile, attr, isLarge ? 1 : 0, (attr >> 1) & 0x07))
        }

        // Dump first 64 bytes of VRAM at name table 1 base
        let t1base = nameBase + nameGap
        print(String(format: "[SPRITE DUMP] VRAM at table1 base (0x%05X):", t1base))
        var hex = "  "
        for j in 0..<64 {
            hex += String(format: "%02X ", vram[(t1base + j) & 0xFFFF])
            if (j + 1) % 32 == 0 { print(hex); hex = "  " }
        }

        // Check how much non-zero data at table1
        var nonZero = 0
        for j in 0..<0x4000 {
            if vram[(t1base + j) & 0xFFFF] != 0 { nonZero += 1 }
        }
        print(String(format: "[SPRITE DUMP] Table1 region non-zero bytes: %d/16384", nonZero))

        // Dump CGRAM colors 128-143 (sprite palette 0)
        print("[SPRITE DUMP] CGRAM sprite pal 0 (128-143):")
        hex = "  "
        for c in 128..<144 {
            let lo = cgram[(c * 2) & 0x1FF]
            let hi = cgram[(c * 2 + 1) & 0x1FF]
            hex += String(format: "%02X%02X ", hi, lo)
        }
        print(hex)
        fflush(stdout)
    }

    // MARK: - Pixel readback

    func readPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let idx = (y * SNESConstants.screenWidth + x) * 4
        return (backBuffer[idx], backBuffer[idx + 1], backBuffer[idx + 2])
    }

    // MARK: - Frame management

    func swapBuffers() {
        swap(&frontBuffer, &backBuffer)
    }
}
