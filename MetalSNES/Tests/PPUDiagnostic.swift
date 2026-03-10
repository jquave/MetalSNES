import Foundation

final class PPUDiagnostic {

    static func log(_ msg: String) {
        print(msg)
        fflush(stdout)
    }

    static func runAll() {
        log("=== PPU Diagnostic Tests ===")
        let ppu = PPU()
        var passed = 0
        var failed = 0

        if testBackdropColor(ppu) { passed += 1 } else { failed += 1 }
        if testSingle2bppTile(ppu) { passed += 1 } else { failed += 1 }
        if test4bppTile(ppu) { passed += 1 } else { failed += 1 }
        if testVRAMAddressVariation(ppu) { passed += 1 } else { failed += 1 }

        log("=== PPU Results: \(passed) passed, \(failed) failed ===")
    }

    // MARK: - Test 1: Backdrop Color

    private static func testBackdropColor(_ ppu: PPU) -> Bool {
        log("\n[Test 1] Backdrop Color")
        resetPPU(ppu)

        // Screen on, full brightness, no layers enabled
        ppu.inidisp = 0x0F
        ppu.tm = 0x00

        // Write CGRAM[0] = bright red (BGR555: 0x001F = R=31, G=0, B=0)
        writeCGRAM(ppu, index: 0, bgr555: 0x001F)

        ppu.renderScanline(0)

        let pixel = ppu.readPixel(x: 128, y: 0)
        let expectR: UInt8 = 0xF8  // 31 << 3
        let expectG: UInt8 = 0x00
        let expectB: UInt8 = 0x00

        if pixel.r == expectR && pixel.g == expectG && pixel.b == expectB {
            log("  PASS: backdrop = (\(pixel.r), \(pixel.g), \(pixel.b))")
            return true
        } else {
            log("  FAIL: expected (\(expectR), \(expectG), \(expectB)), got (\(pixel.r), \(pixel.g), \(pixel.b))")
            return false
        }
    }

    // MARK: - Test 2: Single 2bpp Tile (Mode 0)

    private static func testSingle2bppTile(_ ppu: PPU) -> Bool {
        log("\n[Test 2] Single 2bpp Tile (Mode 0)")
        resetPPU(ppu)

        ppu.inidisp = 0x0F
        ppu.bgmode = 0x00  // Mode 0
        ppu.tm = 0x01       // BG1 enabled

        // BG1 tilemap at VRAM word addr 0 → byte addr 0
        ppu.bg1sc = 0x00    // base = 0, 32x32

        // BG1 chr at block 1: bg12nba low nibble = 1 → byte addr 0x4000 (8K words = 16KB)
        ppu.bg12nba = 0x01

        // Backdrop = red
        writeCGRAM(ppu, index: 0, bgr555: 0x001F)

        // BG1 palette 0, color 1 = bright green (BGR555: 0x03E0)
        writeCGRAM(ppu, index: 1, bgr555: 0x03E0)

        // Write tilemap entry 0 at VRAM[0..1]: tile 1, palette 0, no flip
        // (Use tile 1 so tile 0 stays blank — other tilemap entries default to tile 0)
        ppu.vram[0] = 0x01
        ppu.vram[1] = 0x00

        // Write 2bpp tile 1 at chr base 0x4000 + 16 bytes
        // 2bpp: 16 bytes per tile, 2 bytes per row
        // Pixel value 1 for all pixels: bp0=0xFF (all bits set), bp1=0x00
        for row in 0..<8 {
            let addr = 0x4000 + 16 + row * 2  // tile 1 offset
            ppu.vram[addr] = 0xFF     // bitplane 0: all 1s
            ppu.vram[addr + 1] = 0x00 // bitplane 1: all 0s
        }

        ppu.renderScanline(0)

        let tilePixel = ppu.readPixel(x: 0, y: 0)
        let backdropPixel = ppu.readPixel(x: 8, y: 0)

        // Green: BGR555 0x03E0 → R=0, G=31<<3=0xF8, B=0
        let expectTile = (r: UInt8(0x00), g: UInt8(0xF8), b: UInt8(0x00))
        let expectBackdrop = (r: UInt8(0xF8), g: UInt8(0x00), b: UInt8(0x00))

        var ok = true
        if tilePixel.r == expectTile.r && tilePixel.g == expectTile.g && tilePixel.b == expectTile.b {
            log("  PASS: tile pixel (0,0) = (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
        } else {
            log("  FAIL: tile pixel (0,0) expected (\(expectTile.r), \(expectTile.g), \(expectTile.b)), got (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
            ok = false
        }

        if backdropPixel.r == expectBackdrop.r && backdropPixel.g == expectBackdrop.g && backdropPixel.b == expectBackdrop.b {
            log("  PASS: backdrop pixel (8,0) = (\(backdropPixel.r), \(backdropPixel.g), \(backdropPixel.b))")
        } else {
            log("  FAIL: backdrop pixel (8,0) expected (\(expectBackdrop.r), \(expectBackdrop.g), \(expectBackdrop.b)), got (\(backdropPixel.r), \(backdropPixel.g), \(backdropPixel.b))")
            ok = false
        }

        return ok
    }

    // MARK: - Test 3: 4bpp Tile (Mode 1)

    private static func test4bppTile(_ ppu: PPU) -> Bool {
        log("\n[Test 3] 4bpp Tile (Mode 1)")
        resetPPU(ppu)

        ppu.inidisp = 0x0F
        ppu.bgmode = 0x01  // Mode 1
        ppu.tm = 0x01       // BG1 enabled

        // BG1 tilemap at VRAM word addr 0x04 (byte addr 0x0800)
        // bg1sc upper 6 bits = word addr >> 10 → 0x04 << 2 = 0x10
        // Actually: tilemapBase = (scReg & 0xFC) << 9
        // We want byte addr 0x0800 → (scReg & 0xFC) << 9 = 0x0800
        // 0x0800 >> 9 = 4, and 4 must be in bits 7..2: scReg = 0x04 << 2 = 0x10? No.
        // (scReg & 0xFC) << 9 = 0x0800 → scReg & 0xFC = 0x04 → scReg = 0x04
        ppu.bg1sc = 0x04    // tilemap base = byte 0x0800, 32x32

        // BG1 chr at block 2: bg12nba low nibble = 2 → byte addr 0x8000 (8K words = 16KB per block)
        ppu.bg12nba = 0x02

        // Backdrop = blue (BGR555: 0x7C00)
        writeCGRAM(ppu, index: 0, bgr555: 0x7C00)

        // BG1 palette 0, color 1 = white (BGR555: 0x7FFF)
        writeCGRAM(ppu, index: 1, bgr555: 0x7FFF)

        // Tilemap entry at byte 0x0800: tile 0, palette 0
        ppu.vram[0x0800] = 0x00
        ppu.vram[0x0801] = 0x00

        // 4bpp tile 0 at chr base 0x8000: 32 bytes per tile
        // Set pixel value 1: bp0=0xFF, bp1=0x00, bp2=0x00, bp3=0x00
        for row in 0..<8 {
            let addr = 0x8000 + row * 2
            ppu.vram[addr] = 0xFF       // bitplane 0
            ppu.vram[addr + 1] = 0x00   // bitplane 1
            ppu.vram[addr + 16] = 0x00  // bitplane 2
            ppu.vram[addr + 17] = 0x00  // bitplane 3
        }

        ppu.renderScanline(0)

        let tilePixel = ppu.readPixel(x: 0, y: 0)
        // White: 0x7FFF → R=31<<3=0xF8, G=31<<3=0xF8, B=31<<3=0xF8
        let expectTile = (r: UInt8(0xF8), g: UInt8(0xF8), b: UInt8(0xF8))

        if tilePixel.r == expectTile.r && tilePixel.g == expectTile.g && tilePixel.b == expectTile.b {
            log("  PASS: 4bpp tile pixel (0,0) = (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
            return true
        } else {
            log("  FAIL: 4bpp tile pixel (0,0) expected (\(expectTile.r), \(expectTile.g), \(expectTile.b)), got (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
            return false
        }
    }

    // MARK: - Test 4: VRAM Address Verification

    private static func testVRAMAddressVariation(_ ppu: PPU) -> Bool {
        log("\n[Test 4] VRAM Address Verification")
        resetPPU(ppu)

        ppu.inidisp = 0x0F
        ppu.bgmode = 0x00  // Mode 0
        ppu.tm = 0x01       // BG1 enabled

        // BG1 tilemap at word addr giving byte addr 0x1000
        // (scReg & 0xFC) << 9 = 0x1000 → scReg & 0xFC = 0x08 → scReg = 0x08
        ppu.bg1sc = 0x08

        // BG1 chr at block 3: bg12nba low nibble = 3 → byte addr 0xC000 (8K words = 16KB per block)
        ppu.bg12nba = 0x03

        // Backdrop = black
        writeCGRAM(ppu, index: 0, bgr555: 0x0000)

        // BG1 palette 0, color 2 = magenta (BGR555: R=31, B=31 → 0x7C1F)
        writeCGRAM(ppu, index: 2, bgr555: 0x7C1F)

        // Tilemap entry at 0x1000: tile 1, palette 0
        ppu.vram[0x1000] = 0x01
        ppu.vram[0x1001] = 0x00

        // 2bpp tile 1 at chr base 0xC000 + 16 bytes (tile 1 offset)
        // Pixel value 2: bp0=0x00, bp1=0xFF
        let tileAddr = 0xC000 + 1 * 16
        for row in 0..<8 {
            let addr = tileAddr + row * 2
            ppu.vram[addr] = 0x00     // bitplane 0: all 0s
            ppu.vram[addr + 1] = 0xFF // bitplane 1: all 1s → pixel value 2
        }

        ppu.renderScanline(0)

        let tilePixel = ppu.readPixel(x: 0, y: 0)
        // Magenta: 0x7C1F → R=31<<3=0xF8, G=0, B=31<<3=0xF8
        let expectTile = (r: UInt8(0xF8), g: UInt8(0x00), b: UInt8(0xF8))

        if tilePixel.r == expectTile.r && tilePixel.g == expectTile.g && tilePixel.b == expectTile.b {
            log("  PASS: tile at different base = (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
            return true
        } else {
            log("  FAIL: expected (\(expectTile.r), \(expectTile.g), \(expectTile.b)), got (\(tilePixel.r), \(tilePixel.g), \(tilePixel.b))")
            return false
        }
    }

    // MARK: - ROM Runtime Test

    /// Load a ROM, run it for a number of frames, then check the framebuffer.
    static func runROMTest(romPath: String, frames: Int = 300) {
        log("\n=== ROM Runtime Test: \(romPath) ===")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
            log("  FAIL: Could not load ROM at \(romPath)")
            return
        }
        guard let cart = try? Cartridge(data: data) else {
            log("  FAIL: Could not parse ROM")
            return
        }
        log("  ROM: \(cart.title), \(cart.romSizeKB)KB")

        let core = EmulatorCore(cartridge: cart)
        core.cpu.traceEnabled = false  // don't need trace for this

        // Run N frames
        log("  Running \(frames) frames...")
        for f in 0..<frames {
            core.runOneFrame()
            if f % 100 == 0 {
                let pc = (UInt32(core.cpu.regs.PBR) << 16) | UInt32(core.cpu.regs.PC)
                let inidisp = core.bus.ppu.inidisp
                log(String(format: "  Frame %d/%d — PC=$%06X inidisp=0x%02X tm=0x%02X", f, frames, pc, inidisp, core.bus.ppu.tm))
            }
        }
        let pc = (UInt32(core.cpu.regs.PBR) << 16) | UInt32(core.cpu.regs.PC)
        log(String(format: "  Done at PC=$%06X inidisp=0x%02X", pc, core.bus.ppu.inidisp))
        log("  Checking framebuffer...")
        checkRuntimeFramebuffer(core.bus.ppu)
    }

    // MARK: - Runtime Framebuffer Check

    /// Call after a few seconds of emulation to sample the framebuffer
    /// and report what colors are actually being rendered.
    static func checkRuntimeFramebuffer(_ ppu: PPU) {
        log("\n=== Runtime Framebuffer Check ===")

        // Sample a grid of pixels across the screen
        let samplePoints: [(x: Int, y: Int, label: String)] = [
            (16, 16, "top-left"),
            (128, 16, "top-center"),
            (240, 16, "top-right"),
            (16, 112, "mid-left"),
            (128, 112, "center"),
            (240, 112, "mid-right"),
            (16, 208, "bot-left"),
            (128, 208, "bot-center"),
            (240, 208, "bot-right"),
        ]

        var nonBlackCount = 0
        var uniqueColors = Set<UInt32>()

        for pt in samplePoints {
            let (r, g, b) = ppu.readPixel(x: pt.x, y: pt.y)
            let colorKey = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            uniqueColors.insert(colorKey)
            if r != 0 || g != 0 || b != 0 { nonBlackCount += 1 }
            log("  \(pt.label) (\(pt.x),\(pt.y)): R=\(r) G=\(g) B=\(b)")
        }

        // Scan for color distribution across full screen
        var colorHistogram = [UInt32: Int]()
        for y in stride(from: 0, to: SNESConstants.screenHeight, by: 8) {
            for x in stride(from: 0, to: SNESConstants.screenWidth, by: 8) {
                let (r, g, b) = ppu.readPixel(x: x, y: y)
                let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                colorHistogram[key, default: 0] += 1
            }
        }

        log("\nColor distribution (top 10, sampled every 8px):")
        let sorted = colorHistogram.sorted { $0.value > $1.value }
        for (i, entry) in sorted.prefix(10).enumerated() {
            let r = (entry.key >> 16) & 0xFF
            let g = (entry.key >> 8) & 0xFF
            let b = entry.key & 0xFF
            let pct = Double(entry.value) / Double(colorHistogram.values.reduce(0, +)) * 100
            log("  \(i+1). R=\(r) G=\(g) B=\(b) — \(entry.value) samples (\(String(format: "%.1f", pct))%)")
        }

        log("\nSummary: \(nonBlackCount)/\(samplePoints.count) sample points non-black, \(uniqueColors.count) unique colors at sample points, \(colorHistogram.count) unique colors total")

        // Basic sanity checks for Super Mario World
        if nonBlackCount == 0 {
            log("  WARNING: Screen is entirely black — forced blank may still be on, or no rendering occurred")
        }
        if colorHistogram.count < 3 {
            log("  WARNING: Very few unique colors — PPU may not be rendering properly")
        }
        if colorHistogram.count > 5 {
            log("  OK: Multiple colors detected — PPU is rendering something")
        }

        // Also dump PPU state
        dumpState(ppu)
    }

    // MARK: - VRAM/CGRAM Dump

    static var ppu_wram: UnsafeMutableBufferPointer<UInt8>?

    static func dumpState(_ ppu: PPU) {
        log("\n=== PPU State Dump ===")

        log("Registers: inidisp=0x\(String(format: "%02X", ppu.inidisp)) bgmode=\(ppu.bgmode & 0x07) tm=0x\(String(format: "%02X", ppu.tm))")
        log("  bg1sc=0x\(String(format: "%02X", ppu.bg1sc)) bg2sc=0x\(String(format: "%02X", ppu.bg2sc)) bg3sc=0x\(String(format: "%02X", ppu.bg3sc))")
        log("  bg12nba=0x\(String(format: "%02X", ppu.bg12nba)) bg34nba=0x\(String(format: "%02X", ppu.bg34nba))")
        log("  scroll: BG1 H=\(ppu.bgHScroll[0]) V=\(ppu.bgVScroll[0]) BG2 H=\(ppu.bgHScroll[1]) V=\(ppu.bgVScroll[1])")

        // CGRAM - show all 256 colors, only non-zero
        var nonZeroCgram = 0
        for i in 0..<256 {
            let lo = ppu.cgram[i * 2]
            let hi = ppu.cgram[(i * 2 + 1) & 0x1FF]
            let bgr = UInt16(lo) | (UInt16(hi) << 8)
            if bgr != 0 { nonZeroCgram += 1 }
        }
        log("CGRAM: \(nonZeroCgram)/256 non-zero colors")
        // Show first 16 non-zero
        var shown = 0
        for i in 0..<256 {
            guard shown < 16 else { break }
            let lo = ppu.cgram[i * 2]
            let hi = ppu.cgram[(i * 2 + 1) & 0x1FF]
            let bgr = UInt16(lo) | (UInt16(hi) << 8)
            if bgr != 0 {
                let r = (bgr >> 0) & 0x1F
                let g = (bgr >> 5) & 0x1F
                let b = (bgr >> 10) & 0x1F
                log("  [\(i)] = 0x\(String(format: "%04X", bgr)) (R=\(r) G=\(g) B=\(b))")
                shown += 1
            }
        }

        // Check VRAM for non-zero data ranges
        var firstNonZero = -1
        var lastNonZero = -1
        var nonZeroCount = 0
        for i in 0..<ppu.vram.count {
            if ppu.vram[i] != 0 {
                nonZeroCount += 1
                if firstNonZero == -1 { firstNonZero = i }
                lastNonZero = i
            }
        }
        log("VRAM: \(nonZeroCount) non-zero bytes, range 0x\(String(format: "%04X", max(firstNonZero, 0)))–0x\(String(format: "%04X", max(lastNonZero, 0)))")

        // Tilemap entries at BG1 base — scan for first non-zero
        let bg1TmBase = Int(ppu.bg1sc & 0xFC) << 9
        let bg1Size = Int(ppu.bg1sc & 0x03)
        log("\nBG1 tilemap: base=0x\(String(format: "%04X", bg1TmBase)) size=\(bg1Size) (0=32x32,1=64x32,2=32x64,3=64x64)")
        var tmNonZero = 0
        var firstTmEntry = ""
        for i in 0..<1024 {
            let addr = bg1TmBase + i * 2
            let lo = ppu.vram[addr & 0xFFFF]
            let hi = ppu.vram[(addr + 1) & 0xFFFF]
            if lo != 0 || hi != 0 {
                tmNonZero += 1
                if firstTmEntry.isEmpty {
                    let entry = UInt16(lo) | (UInt16(hi) << 8)
                    firstTmEntry = "  first non-zero at [\(i)] (row=\(i/32),col=\(i%32)): tile=\(entry & 0x3FF) pal=\((entry>>10)&7)"
                }
            }
        }
        log("  \(tmNonZero)/1024 non-zero tilemap entries")
        if !firstTmEntry.isEmpty { log(firstTmEntry) }

        // BG1 chr base - check tile 0 and first non-zero tile
        let chrBase = Int(ppu.bg12nba & 0x0F) << 14
        log("\nBG1 chr: base=0x\(String(format: "%04X", chrBase))")
        // Find first tile with non-zero data
        for t in 0..<64 {
            let tAddr = chrBase + t * 32
            var hasData = false
            for b in 0..<32 {
                if ppu.vram[(tAddr + b) & 0xFFFF] != 0 { hasData = true; break }
            }
            if hasData {
                var hex = ""
                for b in 0..<32 { hex += String(format: "%02X", ppu.vram[(tAddr + b) & 0xFFFF]) }
                log("  tile \(t) @ 0x\(String(format: "%04X", tAddr)): \(hex)")
                break
            }
        }

        // Check WRAM at 7E:C500 (CGRAM DMA source for Zelda)
        log("\nWRAM at 0xC500 (CGRAM source, first 64 bytes):")
        var wramHex = "  "
        var wramNonZero = 0
        for i in 0..<512 {
            if ppu_wram != nil && ppu_wram![0xC500 + i] != 0 { wramNonZero += 1 }
        }
        if let wram = ppu_wram {
            for i in 0..<64 {
                wramHex += String(format: "%02X", wram[0xC500 + i])
                if i % 16 == 15 { wramHex += "\n  " }
            }
            log(wramHex)
            log("  \(wramNonZero)/512 non-zero bytes in CGRAM source region")
        }

        log("=== End PPU Dump ===\n")
    }

    // MARK: - Helpers

    private static func resetPPU(_ ppu: PPU) {
        ppu.inidisp = 0x80
        ppu.bgmode = 0
        ppu.tm = 0
        ppu.ts = 0
        ppu.bg1sc = 0
        ppu.bg2sc = 0
        ppu.bg3sc = 0
        ppu.bg4sc = 0
        ppu.bg12nba = 0
        ppu.bg34nba = 0
        ppu.bgHScroll = [0, 0, 0, 0]
        ppu.bgVScroll = [0, 0, 0, 0]
        ppu.objsel = 0
        ppu.cgwsel = 0
        ppu.cgadsub = 0
        ppu.coldata = 0
        for i in 0..<ppu.vram.count { ppu.vram[i] = 0 }
        for i in 0..<ppu.cgram.count { ppu.cgram[i] = 0 }
        for i in 0..<ppu.oam.count { ppu.oam[i] = 0 }
    }

    private static func writeCGRAM(_ ppu: PPU, index: Int, bgr555: UInt16) {
        let addr = index * 2
        ppu.cgram[addr] = UInt8(bgr555 & 0xFF)
        ppu.cgram[addr + 1] = UInt8((bgr555 >> 8) & 0x7F)
    }
}
