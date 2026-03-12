import Foundation
import MetalKit
import AppKit

final class PPUDiagnostic {
    struct FramebufferSummary {
        var nonBlackSamples = 0
        var uniqueSampleColors = 0
        var uniqueHistogramColors = 0
        var dominantColor: UInt32 = 0
        var dominantColorCount = 0
        var sampleHash: UInt64 = 0
    }

    static func log(_ msg: String) {
        print(msg)
        fflush(stdout)
    }

    static func runAll() {
        log("=== PPU Diagnostic Tests ===")
        var passed = 0
        var failed = 0

        if testBackdropColor(PPU()) { passed += 1 } else { failed += 1 }
        if testSingle2bppTile(PPU()) { passed += 1 } else { failed += 1 }
        if test4bppTile(PPU()) { passed += 1 } else { failed += 1 }
        if testVRAMAddressVariation(PPU()) { passed += 1 } else { failed += 1 }
        if testSubscreenWindowMasking(PPU()) { passed += 1 } else { failed += 1 }
        if testMode2BGPriority(PPU()) { passed += 1 } else { failed += 1 }

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

        // BG1 chr at block 1: bg12nba low nibble = 1 → byte addr 0x2000 (4K words = 8KB)
        ppu.bg12nba = 0x01

        // Backdrop = red
        writeCGRAM(ppu, index: 0, bgr555: 0x001F)

        // BG1 palette 0, color 1 = bright green (BGR555: 0x03E0)
        writeCGRAM(ppu, index: 1, bgr555: 0x03E0)

        // Write tilemap entry 0 at VRAM[0..1]: tile 1, palette 0, no flip
        // (Use tile 1 so tile 0 stays blank — other tilemap entries default to tile 0)
        ppu.vram[0] = 0x01
        ppu.vram[1] = 0x00

        // Write 2bpp tile 1 at chr base 0x2000 + 16 bytes
        // 2bpp: 16 bytes per tile, 2 bytes per row
        // Pixel value 1 for all pixels: bp0=0xFF (all bits set), bp1=0x00
        for row in 0..<8 {
            let addr = 0x2000 + 16 + row * 2  // tile 1 offset
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

        // BG1 chr at block 2: bg12nba low nibble = 2 → byte addr 0x4000 (4K words = 8KB per block)
        ppu.bg12nba = 0x02

        // Backdrop = blue (BGR555: 0x7C00)
        writeCGRAM(ppu, index: 0, bgr555: 0x7C00)

        // BG1 palette 0, color 1 = white (BGR555: 0x7FFF)
        writeCGRAM(ppu, index: 1, bgr555: 0x7FFF)

        // Tilemap entry at byte 0x0800: tile 0, palette 0
        ppu.vram[0x0800] = 0x00
        ppu.vram[0x0801] = 0x00

        // 4bpp tile 0 at chr base 0x4000: 32 bytes per tile
        // Set pixel value 1: bp0=0xFF, bp1=0x00, bp2=0x00, bp3=0x00
        for row in 0..<8 {
            let addr = 0x4000 + row * 2
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

        // BG1 chr at block 3: bg12nba low nibble = 3 → byte addr 0x6000 (4K words = 8KB per block)
        ppu.bg12nba = 0x03

        // Backdrop = black
        writeCGRAM(ppu, index: 0, bgr555: 0x0000)

        // BG1 palette 0, color 2 = magenta (BGR555: R=31, B=31 → 0x7C1F)
        writeCGRAM(ppu, index: 2, bgr555: 0x7C1F)

        // Tilemap entry at 0x1000: tile 1, palette 0
        ppu.vram[0x1000] = 0x01
        ppu.vram[0x1001] = 0x00

        // 2bpp tile 1 at chr base 0x6000 + 16 bytes (tile 1 offset)
        // Pixel value 2: bp0=0x00, bp1=0xFF
        let tileAddr = 0x6000 + 1 * 16
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

    // MARK: - Test 5: Sub-screen Window Masking

    private static func testSubscreenWindowMasking(_ ppu: PPU) -> Bool {
        log("\n[Test 5] Sub-screen Window Masking")
        resetPPU(ppu)

        ppu.inidisp = 0x0F
        ppu.bgmode = 0x00
        ppu.tm = 0x00
        ppu.ts = 0x01
        ppu.cgadsub = 0x20
        ppu.cgwsel = 0x02

        ppu.bg1sc = 0x00
        ppu.bg12nba = 0x01

        ppu.w12sel = 0x02
        ppu.wh0 = 0
        ppu.wh1 = 127
        ppu.wh2 = 0
        ppu.wh3 = 0
        ppu.wbglog = 0x00
        ppu.tmw = 0x00
        ppu.tsw = 0x01

        writeCGRAM(ppu, index: 0, bgr555: 0x0000)
        writeCGRAM(ppu, index: 1, bgr555: 0x03E0)

        for column in 0..<32 {
            let tilemapAddr = column * 2
            ppu.vram[tilemapAddr] = 0x01
            ppu.vram[tilemapAddr + 1] = 0x00
        }
        for row in 0..<8 {
            let addr = 0x2000 + 16 + row * 2
            ppu.vram[addr] = 0xFF
            ppu.vram[addr + 1] = 0x00
        }

        ppu.renderScanline(0)

        let maskedPixel = ppu.readPixel(x: 0, y: 0)
        let visiblePixel = ppu.readPixel(x: 200, y: 0)
        let expectMasked = (r: UInt8(0x00), g: UInt8(0x00), b: UInt8(0x00))
        let expectVisible = (r: UInt8(0x00), g: UInt8(0xF8), b: UInt8(0x00))

        var ok = true
        if maskedPixel.r == expectMasked.r && maskedPixel.g == expectMasked.g && maskedPixel.b == expectMasked.b {
            log("  PASS: masked sub-screen pixel stayed black")
        } else {
            log("  FAIL: masked sub-screen pixel expected black, got (\(maskedPixel.r), \(maskedPixel.g), \(maskedPixel.b))")
            ok = false
        }

        if visiblePixel.r == expectVisible.r && visiblePixel.g == expectVisible.g && visiblePixel.b == expectVisible.b {
            log("  PASS: visible sub-screen pixel blended correctly")
        } else {
            log("  FAIL: visible sub-screen pixel expected (\(expectVisible.r), \(expectVisible.g), \(expectVisible.b)), got (\(visiblePixel.r), \(visiblePixel.g), \(visiblePixel.b))")
            ok = false
        }

        return ok
    }

    // MARK: - Test 6: Mode 2 BG Priority Ordering

    private static func testMode2BGPriority(_ ppu: PPU) -> Bool {
        log("\n[Test 6] Mode 2 BG Priority Ordering")
        resetPPU(ppu)

        ppu.inidisp = 0x0F
        ppu.bgmode = 0x02
        ppu.tm = 0x03
        ppu.bg1sc = 0x00
        ppu.bg2sc = 0x04
        ppu.bg3sc = 0x08
        ppu.bg12nba = 0x21

        writeCGRAM(ppu, index: 0, bgr555: 0x0000)
        writeCGRAM(ppu, index: 1, bgr555: 0x001F)
        writeCGRAM(ppu, index: 2, bgr555: 0x03E0)

        ppu.vram[0x0000] = 0x00
        ppu.vram[0x0001] = 0x00
        ppu.vram[0x0800] = 0x00
        ppu.vram[0x0801] = 0x00

        for row in 0..<8 {
            let bg1Addr = 0x2000 + row * 2
            let bg2Addr = 0x4000 + row * 2

            ppu.vram[bg1Addr] = 0xFF
            ppu.vram[bg1Addr + 1] = 0x00
            ppu.vram[bg1Addr + 16] = 0x00
            ppu.vram[bg1Addr + 17] = 0x00

            ppu.vram[bg2Addr] = 0x00
            ppu.vram[bg2Addr + 1] = 0xFF
            ppu.vram[bg2Addr + 16] = 0x00
            ppu.vram[bg2Addr + 17] = 0x00
        }

        ppu.renderScanline(0)

        let lowPriorityPixel = ppu.readPixel(x: 0, y: 0)
        let expectBG1 = (r: UInt8(0xF8), g: UInt8(0x00), b: UInt8(0x00))

        var ok = true
        if lowPriorityPixel.r == expectBG1.r &&
            lowPriorityPixel.g == expectBG1.g &&
            lowPriorityPixel.b == expectBG1.b {
            log("  PASS: BG1 low priority draws above BG2 low priority")
        } else {
            log("  FAIL: expected BG1 low priority red, got (\(lowPriorityPixel.r), \(lowPriorityPixel.g), \(lowPriorityPixel.b))")
            ok = false
        }

        ppu.vram[0x0801] = 0x20
        ppu.renderScanline(1)

        let bg2HighPixel = ppu.readPixel(x: 0, y: 1)
        let expectBG2 = (r: UInt8(0x00), g: UInt8(0xF8), b: UInt8(0x00))

        if bg2HighPixel.r == expectBG2.r &&
            bg2HighPixel.g == expectBG2.g &&
            bg2HighPixel.b == expectBG2.b {
            log("  PASS: BG2 high priority draws above BG1 low priority")
        } else {
            log("  FAIL: expected BG2 high priority green, got (\(bg2HighPixel.r), \(bg2HighPixel.g), \(bg2HighPixel.b))")
            ok = false
        }

        ppu.vram[0x0001] = 0x20
        ppu.renderScanline(2)

        let bothHighPixel = ppu.readPixel(x: 0, y: 2)

        if bothHighPixel.r == expectBG1.r &&
            bothHighPixel.g == expectBG1.g &&
            bothHighPixel.b == expectBG1.b {
            log("  PASS: BG1 high priority draws above BG2 high priority")
        } else {
            log("  FAIL: expected BG1 high priority red over BG2 high priority, got (\(bothHighPixel.r), \(bothHighPixel.g), \(bothHighPixel.b))")
            ok = false
        }

        return ok
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
        checkRuntimeFramebuffer(core.bus.ppu, usePresentedFrame: true)
    }

    static func runSaveStateTest(romPath: String, statePath: String, frames: Int = 8) {
        let markedX = 127
        let markedY = 65

        log("\n=== Save State Diagnostic ===")
        log("  ROM: \(romPath)")
        log("  State: \(statePath)")

        guard let romData = try? Data(contentsOf: URL(fileURLWithPath: romPath)) else {
            log("  FAIL: Could not load ROM at \(romPath)")
            return
        }
        guard let stateData = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else {
            log("  FAIL: Could not load state at \(statePath)")
            return
        }
        guard let cart = try? Cartridge(data: romData) else {
            log("  FAIL: Could not parse ROM")
            return
        }

        let core = EmulatorCore(cartridge: cart)
        let codec = SaveState()
        do {
            try codec.restore(from: stateData, core: core)
        } catch {
            log("  FAIL: Could not restore state: \(error.localizedDescription)")
            return
        }

        log("  Restored state successfully")
        dumpCoreState(core, label: "Restored")
        dumpDMAState(core, label: "Restored")
        dumpHDMAState(core, label: "Restored")
        compareCPUAndGPUFrame(romData: romData, stateData: stateData)

        var previousHash: UInt64?
        for frame in 0..<frames {
            let startPC = pc(core)
            let startINIDISP = core.bus.ppu.inidisp
            let startTM = core.bus.ppu.tm
            let startTS = core.bus.ppu.ts
            let startHVBJOY = core.bus.hvbjoy
            if frame == 0 {
                core.bus.ppu.configurePixelTrace([
                    .init(x: markedX, y: markedY, label: "marked-pixel"),
                    .init(x: markedX, y: markedY - 1, label: "marked-above"),
                    .init(x: markedX, y: markedY + 1, label: "marked-below"),
                    .init(x: markedX - 1, y: markedY, label: "marked-left"),
                    .init(x: markedX + 1, y: markedY, label: "marked-right"),
                    .init(x: markedX, y: markedY + 7, label: "below-marked")
                ])
            }
            core.runOneFrame()
            let summary = summarizeRuntimeFramebuffer(core.bus.ppu, usePresentedFrame: true)
            let endPC = pc(core)
            let changed = previousHash.map { $0 != summary.sampleHash } ?? true
            previousHash = summary.sampleHash

            log(String(format:
                "  Frame %d: PC $%06X->$%06X INIDISP $%02X->$%02X TM $%02X->$%02X TS=$%02X HVBJOY $%02X->$%02X colors=%d dominant=%06X(%d) nonBlack=%d hash=%016llX changed=%@",
                frame,
                startPC,
                endPC,
                startINIDISP,
                core.bus.ppu.inidisp,
                startTM,
                core.bus.ppu.tm,
                startTS,
                startHVBJOY,
                core.bus.hvbjoy,
                summary.uniqueHistogramColors,
                summary.dominantColor,
                summary.dominantColorCount,
                summary.nonBlackSamples,
                summary.sampleHash,
                changed ? "yes" : "no"
            ))

            if frame == 0 || frame == frames - 1 {
                dumpCoreState(core, label: "After frame \(frame)")
                dumpDMAState(core, label: "After frame \(frame)")
                dumpHDMAState(core, label: "After frame \(frame)")
                checkRuntimeFramebuffer(core.bus.ppu, usePresentedFrame: true)
                dumpVisibleSprites(ppu: core.bus.ppu, xRange: 88...168, yRange: 24...96)
                dumpSpritesOnScanline(ppu: core.bus.ppu, scanline: markedY)
                dumpSpriteSamples(ppu: core.bus.ppu, points: [
                    ("marked-pixel", markedX, markedY),
                    ("marked-above", markedX, markedY - 1),
                    ("below-marked", markedX, markedY + 7)
                ])
                dumpBGSamples(ppu: core.bus.ppu, points: [
                    ("marked-pixel", markedX, markedY),
                    ("marked-above", markedX, markedY - 1),
                    ("marked-below", markedX, markedY + 1),
                    ("marked-left", markedX - 1, markedY),
                    ("marked-right", markedX + 1, markedY),
                    ("below-marked", markedX, markedY + 7)
                ])
                if frame == 0 {
                    dumpPixelTraceLogs(core.bus.ppu.consumePixelTraceLogs())
                    writeFramebufferPNG(ppu: core.bus.ppu, path: "/tmp/metalsnes-zelda-frame0.png")
                }
            }
        }
    }

    // MARK: - Runtime Framebuffer Check

    /// Call after a few seconds of emulation to sample the framebuffer
    /// and report what colors are actually being rendered.
    static func checkRuntimeFramebuffer(_ ppu: PPU, usePresentedFrame: Bool = false) {
        log("\n=== Runtime Framebuffer Check ===")

        let summary = summarizeRuntimeFramebuffer(ppu, usePresentedFrame: usePresentedFrame)

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

        for pt in samplePoints {
            let (r, g, b) = ppu.readPixel(x: pt.x, y: pt.y, presented: usePresentedFrame)
            log("  \(pt.label) (\(pt.x),\(pt.y)): R=\(r) G=\(g) B=\(b)")
        }

        log("\nColor distribution (top 10, sampled every 8px):")
        let colorHistogram = histogram(ppu, usePresentedFrame: usePresentedFrame)
        let sorted = colorHistogram.sorted { $0.value > $1.value }
        for (i, entry) in sorted.prefix(10).enumerated() {
            let r = (entry.key >> 16) & 0xFF
            let g = (entry.key >> 8) & 0xFF
            let b = entry.key & 0xFF
            let pct = Double(entry.value) / Double(colorHistogram.values.reduce(0, +)) * 100
            log("  \(i+1). R=\(r) G=\(g) B=\(b) — \(entry.value) samples (\(String(format: "%.1f", pct))%)")
        }

        log("\nSummary: \(summary.nonBlackSamples)/\(samplePoints.count) sample points non-black, \(summary.uniqueSampleColors) unique colors at sample points, \(summary.uniqueHistogramColors) unique colors total, hash=\(String(format: "%016llX", summary.sampleHash))")

        // Basic sanity checks for Super Mario World
        if summary.nonBlackSamples == 0 {
            log("  WARNING: Screen is entirely black — forced blank may still be on, or no rendering occurred")
        }
        if summary.uniqueHistogramColors < 3 {
            log("  WARNING: Very few unique colors — PPU may not be rendering properly")
        }
        if summary.uniqueHistogramColors > 5 {
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
        log("  objsel=0x\(String(format: "%02X", ppu.objsel)) oamadd=0x\(String(format: "%02X%02X", ppu.oamaddh, ppu.oamaddl)) rotation=\(((ppu.oamaddh & 0x80) != 0) ? "on" : "off")")
        log("  ts=0x\(String(format: "%02X", ppu.ts)) cgwsel=0x\(String(format: "%02X", ppu.cgwsel)) cgadsub=0x\(String(format: "%02X", ppu.cgadsub)) setini=0x\(String(format: "%02X", ppu.setini))")
        log("  window: tmw=0x\(String(format: "%02X", ppu.tmw)) tsw=0x\(String(format: "%02X", ppu.tsw)) w12sel=0x\(String(format: "%02X", ppu.w12sel)) w34sel=0x\(String(format: "%02X", ppu.w34sel)) wobjsel=0x\(String(format: "%02X", ppu.wobjsel))")
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

    private static func pc(_ core: EmulatorCore) -> UInt32 {
        (UInt32(core.cpu.regs.PBR) << 16) | UInt32(core.cpu.regs.PC)
    }

    private static func histogram(_ ppu: PPU, usePresentedFrame: Bool) -> [UInt32: Int] {
        var colorHistogram = [UInt32: Int]()
        for y in stride(from: 0, to: SNESConstants.screenHeight, by: 8) {
            for x in stride(from: 0, to: SNESConstants.screenWidth, by: 8) {
                let (r, g, b) = ppu.readPixel(x: x, y: y, presented: usePresentedFrame)
                let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                colorHistogram[key, default: 0] += 1
            }
        }
        return colorHistogram
    }

    private static func summarizeRuntimeFramebuffer(_ ppu: PPU, usePresentedFrame: Bool) -> FramebufferSummary {
        let samplePoints: [(x: Int, y: Int)] = [
            (16, 16), (128, 16), (240, 16),
            (16, 112), (128, 112), (240, 112),
            (16, 208), (128, 208), (240, 208),
        ]

        var summary = FramebufferSummary()
        var uniqueColors = Set<UInt32>()
        for point in samplePoints {
            let (r, g, b) = ppu.readPixel(x: point.x, y: point.y, presented: usePresentedFrame)
            let key = UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            uniqueColors.insert(key)
            if r != 0 || g != 0 || b != 0 {
                summary.nonBlackSamples += 1
            }
        }
        summary.uniqueSampleColors = uniqueColors.count

        let colorHistogram = histogram(ppu, usePresentedFrame: usePresentedFrame)
        summary.uniqueHistogramColors = colorHistogram.count
        if let dominant = colorHistogram.max(by: { $0.value < $1.value }) {
            summary.dominantColor = dominant.key
            summary.dominantColorCount = dominant.value
        }

        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for y in stride(from: 0, to: SNESConstants.screenHeight, by: 4) {
            for x in stride(from: 0, to: SNESConstants.screenWidth, by: 4) {
                let (r, g, b) = ppu.readPixel(x: x, y: y, presented: usePresentedFrame)
                let key = UInt64(r) << 16 | UInt64(g) << 8 | UInt64(b)
                hash ^= key
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        summary.sampleHash = hash
        return summary
    }

    private static func compareCPUAndGPUFrame(romData: Data, stateData: Data) {
        log("\n=== CPU vs GPU Frame Compare ===")

        guard let cpuCart = try? Cartridge(data: romData),
              let gpuCart = try? Cartridge(data: romData) else {
            log("  SKIP: Could not parse ROM for compare")
            return
        }
        guard let renderer = MetalRenderer(headlessDevice: MTLCreateSystemDefaultDevice()) else {
            log("  SKIP: Could not create headless Metal renderer")
            return
        }

        let codec = SaveState()
        let cpuCore = EmulatorCore(cartridge: cpuCart)
        let gpuCore = EmulatorCore(cartridge: gpuCart)
        gpuCore.renderer = renderer

        do {
            try codec.restore(from: stateData, core: cpuCore)
            try codec.restore(from: stateData, core: gpuCore)
        } catch {
            log("  SKIP: Could not restore compare state: \(error.localizedDescription)")
            return
        }

        cpuCore.runOneFrame()
        gpuCore.runOneFrame()

        let cpuPixels = Array(cpuCore.bus.ppu.frontBuffer)
        guard let gpuPixels = renderer.readbackFramebufferRGBA() else {
            log("  SKIP: Could not read back GPU framebuffer")
            return
        }

        var differingPixels = 0
        var firstDifferences: [String] = []
        var minX = SNESConstants.screenWidth
        var minY = SNESConstants.screenHeight
        var maxX = -1
        var maxY = -1
        var maxChannelDelta = 0

        for y in 0..<SNESConstants.screenHeight {
            for x in 0..<SNESConstants.screenWidth {
                let idx = (y * SNESConstants.screenWidth + x) * 4
                let cpuR = cpuPixels[idx + 0]
                let cpuG = cpuPixels[idx + 1]
                let cpuB = cpuPixels[idx + 2]
                let gpuR = gpuPixels[idx + 0]
                let gpuG = gpuPixels[idx + 1]
                let gpuB = gpuPixels[idx + 2]
                guard cpuR != gpuR || cpuG != gpuG || cpuB != gpuB else {
                    continue
                }

                differingPixels += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                maxChannelDelta = max(
                    maxChannelDelta,
                    abs(Int(cpuR) - Int(gpuR)),
                    abs(Int(cpuG) - Int(gpuG)),
                    abs(Int(cpuB) - Int(gpuB))
                )
                if firstDifferences.count < 16 {
                    firstDifferences.append(String(
                        format: "  (%3d,%3d) CPU=%02X%02X%02X GPU=%02X%02X%02X",
                        x, y, cpuR, cpuG, cpuB, gpuR, gpuG, gpuB
                    ))
                }
            }
        }

        if differingPixels == 0 {
            log("  PASS: CPU and GPU framebuffers match for frame 0")
            return
        }

        log("  FAIL: \(differingPixels) pixels differ between CPU and GPU")
        log("  Diff bounds: x=\(minX)...\(maxX) y=\(minY)...\(maxY) maxChannelDelta=\(maxChannelDelta)")
        for diff in firstDifferences {
            log(diff)
        }
    }

    private static func dumpVisibleSprites(ppu: PPU, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) {
        log("\n=== Visible Sprites x=\(xRange.lowerBound)...\(xRange.upperBound) y=\(yRange.lowerBound)...\(yRange.upperBound) ===")

        let sizeSelect = Int((ppu.objsel >> 5) & 0x07)
        let smallWidths = [8, 8, 8, 16, 16, 32, 16, 16]
        let smallHeights = [8, 8, 8, 16, 16, 32, 32, 32]
        let largeWidths = [16, 32, 64, 32, 64, 64, 32, 32]
        let largeHeights = [16, 32, 64, 32, 64, 64, 64, 32]

        var matches = 0
        for i in 0..<128 {
            let baseAddr = i * 4
            let rawX = Int(ppu.oam[baseAddr])
            let rawY = Int(ppu.oam[baseAddr + 1])
            let tile = Int(ppu.oam[baseAddr + 2])
            let attr = ppu.oam[baseAddr + 3]

            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (ppu.oam[highIdx] >> highShift) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0

            let width = isLarge ? largeWidths[sizeSelect] : smallWidths[sizeSelect]
            let height = isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect]
            let spriteX = xBit9 ? (rawX - 256) : rawX
            let spriteY = (rawY + 1) & 0xFF
            let coversX = spriteX <= xRange.upperBound && spriteX + width > xRange.lowerBound
            let coversY = spriteY <= yRange.upperBound && spriteY + height > yRange.lowerBound
            guard coversX && coversY else { continue }

            matches += 1
            log(String(format:
                "  OAM[%3d] X=%4d Y=%3d W=%2d H=%2d tile=%02X attr=%02X pri=%d pal=%d h=%d v=%d table=%d",
                i,
                spriteX,
                spriteY,
                width,
                height,
                tile,
                attr,
                (attr >> 4) & 0x03,
                (attr >> 1) & 0x07,
                (attr & 0x40) != 0 ? 1 : 0,
                (attr & 0x80) != 0 ? 1 : 0,
                attr & 0x01
            ))
        }

        if matches == 0 {
            log("  None")
        }
    }

    private static func dumpSpritesOnScanline(ppu: PPU, scanline: Int) {
        log("\n=== Sprites On Scanline \(scanline) ===")

        let sizeSelect = Int((ppu.objsel >> 5) & 0x07)
        let smallWidths = [8, 8, 8, 16, 16, 32, 16, 16]
        let smallHeights = [8, 8, 8, 16, 16, 32, 32, 32]
        let largeWidths = [16, 32, 64, 32, 64, 64, 32, 32]
        let largeHeights = [16, 32, 64, 32, 64, 64, 64, 32]

        struct SpriteHit {
            let index: Int
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let tile: Int
            let attr: UInt8
            let priority: Int
            let visible: Bool
            let tileSlivers: Int
        }

        var forwardHits = [SpriteHit]()

        for i in 0..<128 {
            let baseAddr = i * 4
            let rawX = Int(ppu.oam[baseAddr])
            let rawY = Int(ppu.oam[baseAddr + 1])
            let tile = Int(ppu.oam[baseAddr + 2])
            let attr = ppu.oam[baseAddr + 3]

            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (ppu.oam[highIdx] >> highShift) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0

            let width = isLarge ? largeWidths[sizeSelect] : smallWidths[sizeSelect]
            let height = isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect]
            let spriteX = xBit9 ? (rawX - 256) : rawX
            let spriteY = (rawY + 1) & 0xFF

            let hits: Bool
            if spriteY < 224 {
                hits = scanline >= spriteY && scanline < min(spriteY + height, 224)
            } else {
                hits = scanline < (spriteY + height - 256)
            }
            guard hits else { continue }

            let visible = spriteX < SNESConstants.screenWidth && (spriteX + width) > 0
            let tileStart = max(0, spriteX) / 8
            let tileEnd = (min(SNESConstants.screenWidth, spriteX + width) + 7) / 8
            let tileSlivers = max(0, tileEnd - tileStart)

            forwardHits.append(.init(
                index: i,
                x: spriteX,
                y: spriteY,
                width: width,
                height: height,
                tile: tile,
                attr: attr,
                priority: Int((attr >> 4) & 0x03),
                visible: visible,
                tileSlivers: tileSlivers
            ))
        }

        log("  Forward OAM hits: \(forwardHits.count)")
        log("  First 32 that real SNES sprite-per-scanline limit would keep when rotation is off:")
        for hit in forwardHits.prefix(32) {
            log(String(format:
                "    keep OAM[%3d] X=%4d Y=%3d W=%2d H=%2d tile=%02X attr=%02X pri=%d visible=%d slivers=%d",
                hit.index,
                hit.x,
                hit.y,
                hit.width,
                hit.height,
                hit.tile,
                hit.attr,
                hit.priority,
                hit.visible ? 1 : 0,
                hit.tileSlivers
            ))
        }

        if forwardHits.count > 32 {
            log("  Overflow OAM entries that should be dropped:")
            for hit in forwardHits.dropFirst(32) {
                log(String(format:
                    "    drop OAM[%3d] X=%4d Y=%3d W=%2d H=%2d tile=%02X attr=%02X pri=%d visible=%d slivers=%d",
                    hit.index,
                    hit.x,
                    hit.y,
                    hit.width,
                    hit.height,
                    hit.tile,
                    hit.attr,
                    hit.priority,
                    hit.visible ? 1 : 0,
                    hit.tileSlivers
                ))
            }
        }

        let reverseIndices = stride(from: 127, through: 0, by: -1)
        var reverseKept = [Int]()
        for i in reverseIndices {
            let baseAddr = i * 4
            let rawY = Int(ppu.oam[baseAddr + 1])
            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (ppu.oam[highIdx] >> highShift) & 0x03
            let isLarge = (highBits & 0x02) != 0
            let height = isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect]
            let spriteY = (rawY + 1) & 0xFF
            let hits: Bool
            if spriteY < 224 {
                hits = scanline >= spriteY && scanline < min(spriteY + height, 224)
            } else {
                hits = scanline < (spriteY + height - 256)
            }
            guard hits else { continue }
            if reverseKept.count < 32 {
                reverseKept.append(i)
            }
        }

        log("  Current reverse-fill cache keeps indices:")
        let reverseSummary = reverseKept.sorted().map(String.init).joined(separator: ", ")
        log("    \(reverseSummary)")
    }

    private static func dumpPixelTraceLogs(_ logs: [String: [String]]) {
        log("\n=== Pixel Trace ===")
        for label in logs.keys.sorted() {
            log("  \(label):")
            let entries = logs[label] ?? []
            if entries.isEmpty {
                log("    no writes")
                continue
            }
            for entry in entries {
                log("    \(entry)")
            }
        }
    }

    private static func dumpSpriteSamples(ppu: PPU, points: [(String, Int, Int)]) {
        log("\n=== Sprite Samples ===")

        let sizeSelect = Int((ppu.objsel >> 5) & 0x07)
        let smallWidths = [8, 8, 8, 16, 16, 32, 16, 16]
        let smallHeights = [8, 8, 8, 16, 16, 32, 32, 32]
        let largeWidths = [16, 32, 64, 32, 64, 64, 32, 32]
        let largeHeights = [16, 32, 64, 32, 64, 64, 64, 32]
        let nameBase = Int(ppu.objsel & 0x07) << 14
        let nameGap = ((Int(ppu.objsel >> 3) & 0x03) + 1) << 13

        for (label, screenX, screenY) in points {
            log("  \(label) (\(screenX),\(screenY)):")
            var any = false

            for i in 0..<128 {
                let baseAddr = i * 4
                let rawX = Int(ppu.oam[baseAddr])
                let rawY = Int(ppu.oam[baseAddr + 1])
                let tile = Int(ppu.oam[baseAddr + 2])
                let attr = ppu.oam[baseAddr + 3]

                let highIdx = 512 + (i >> 2)
                let highShift = (i & 3) * 2
                let highBits = (ppu.oam[highIdx] >> highShift) & 0x03
                let xBit9 = (highBits & 0x01) != 0
                let isLarge = (highBits & 0x02) != 0
                let width = isLarge ? largeWidths[sizeSelect] : smallWidths[sizeSelect]
                let height = isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect]
                let spriteX = xBit9 ? (rawX - 256) : rawX
                let spriteY = (rawY + 1) & 0xFF
                guard screenX >= spriteX, screenX < spriteX + width else { continue }

                let relY = (screenY - spriteY) & 0xFF
                let relYRaw = (screenY - rawY) & 0xFF
                let wrappedCovers = spriteY >= 224 && screenY < (spriteY + height - 256)
                let normalCovers = spriteY < 224 && screenY >= spriteY && screenY < min(spriteY + height, 224)
                guard normalCovers || wrappedCovers else { continue }

                let hFlip = (attr & 0x40) != 0
                let vFlip = (attr & 0x80) != 0
                let tilesWide = width / 8

                let sampled = sampleSpritePixel(
                    ppu: ppu,
                    tile: tile,
                    attr: attr,
                    width: width,
                    height: height,
                    spriteX: spriteX,
                    relX: screenX - spriteX,
                    relY: relY,
                    tilesWide: tilesWide,
                    hFlip: hFlip,
                    vFlip: vFlip,
                    nameBase: nameBase,
                    nameGap: nameGap
                )
                let sampledRawY = sampleSpritePixel(
                    ppu: ppu,
                    tile: tile,
                    attr: attr,
                    width: width,
                    height: height,
                    spriteX: spriteX,
                    relX: screenX - spriteX,
                    relY: relYRaw,
                    tilesWide: tilesWide,
                    hFlip: hFlip,
                    vFlip: vFlip,
                    nameBase: nameBase,
                    nameGap: nameGap
                )
                any = true
                log(String(format:
                    "    OAM[%3d] pri=%d pal=%d table=%d rel=(%2d,%2d) tile=%02X tileRow=%d tileCol=%d actual=%02X fine=(%d,%d) pixel=%d altRawYPixel=%d chr=%04X",
                    i,
                    (attr >> 4) & 0x03,
                    (attr >> 1) & 0x07,
                    attr & 0x01,
                    screenX - spriteX,
                    relY,
                    tile,
                    sampled.tileRow,
                    sampled.tileCol,
                    sampled.actualTile & 0xFF,
                    sampled.fineX,
                    sampled.fineY,
                    sampled.pixel,
                    sampledRawY.pixel,
                    sampled.chrAddr & 0xFFFF
                ))
            }

            if !any {
                log("    no covering sprites")
            }
        }
    }

    private static func sampleSpritePixel(
        ppu: PPU,
        tile: Int,
        attr: UInt8,
        width: Int,
        height: Int,
        spriteX: Int,
        relX: Int,
        relY: Int,
        tilesWide: Int,
        hFlip: Bool,
        vFlip: Bool,
        nameBase: Int,
        nameGap: Int
    ) -> (pixel: UInt8, fineX: Int, fineY: Int, tileRow: Int, tileCol: Int, actualTile: Int, chrAddr: Int) {
        var adjustedY = relY
        if vFlip {
            if width == height {
                adjustedY = height - 1 - adjustedY
            } else if adjustedY < width {
                adjustedY = width - 1 - adjustedY
            } else {
                adjustedY = width + (width - 1) - (adjustedY - width)
            }
        }

        let tileRow = adjustedY / 8
        let tileCol = relX / 8
        let mirrorCol = hFlip ? (tilesWide - 1 - tileCol) : tileCol
        let actualTile = tile + tileRow * 16 + mirrorCol
        let fineY = adjustedY & 7
        let pxWithinTile = relX & 7
        let fineX = hFlip ? (7 - pxWithinTile) : pxWithinTile
        let chrBase = (attr & 0x01) != 0 ? (nameBase + nameGap) : nameBase
        let chrAddr = chrBase + (actualTile & 0xFF) * 32 + fineY * 2
        let bp0 = ppu.vram[chrAddr & 0xFFFF]
        let bp1 = ppu.vram[(chrAddr + 1) & 0xFFFF]
        let bp2 = ppu.vram[(chrAddr + 16) & 0xFFFF]
        let bp3 = ppu.vram[(chrAddr + 17) & 0xFFFF]
        let rowLow = pixelRow(bp0, bp1)
        let rowHigh = pixelRow(bp2, bp3)
        let merged = zip(rowLow, rowHigh).map { $0 | ($1 << 2) }

        return (merged[fineX], fineX, fineY, tileRow, tileCol, actualTile, chrAddr)
    }

    private static func dumpBGSamples(ppu: PPU, points: [(String, Int, Int)]) {
        log("\n=== BG Samples ===")
        for (label, x, y) in points {
            let bg2 = sampleBG4bpp(ppu: ppu, bg: 1, screenX: x, screenY: y)
            let bg3 = sampleBG2bpp(ppu: ppu, bg: 2, screenX: x, screenY: y, paletteBase: 0)
            log("  \(label) (\(x),\(y)):")
            log("    BG2 \(bg2)")
            log("    BG3 \(bg3)")
        }
    }

    private static func sampleBG4bpp(ppu: PPU, bg: Int, screenX: Int, screenY: Int) -> String {
        let scReg = bg == 0 ? ppu.bg1sc : bg == 1 ? ppu.bg2sc : bg == 2 ? ppu.bg3sc : ppu.bg4sc
        let tilemapBase = Int(scReg & 0xFC) << 9
        let tileSize = (ppu.bgmode & (1 << (4 + bg))) != 0 ? 16 : 8
        let chrBase: Int
        if bg < 2 {
            chrBase = bg == 0 ? (Int(ppu.bg12nba & 0x0F) << 13) : (Int(ppu.bg12nba >> 4) << 13)
        } else {
            chrBase = bg == 2 ? (Int(ppu.bg34nba & 0x0F) << 13) : (Int(ppu.bg34nba >> 4) << 13)
        }

        let hScroll = Int(ppu.bgHScroll[bg]) & 0x3FF
        let vScroll = Int(ppu.bgVScroll[bg]) & 0x3FF
        let px = screenX + hScroll
        let py = screenY + vScroll

        let tileX: Int
        let tileY: Int
        let subTileX: Int
        let subTileY: Int
        if tileSize == 16 {
            tileX = (px / 16) & 0x3F
            tileY = (py / 16) & 0x3F
            subTileX = (px / 8) & 1
            subTileY = (py / 8) & 1
        } else {
            tileX = (px / 8) & 0x3F
            tileY = (py / 8) & 0x3F
            subTileX = 0
            subTileY = 0
        }

        var tmAddr = tilemapBase
        if tileX >= 32 { tmAddr += 0x800 }
        if tileY >= 32 {
            let scSize = scReg & 0x03
            if scSize == 2 {
                tmAddr += 0x800
            } else if scSize == 3 {
                tmAddr += 0x1000
            }
        }
        tmAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

        let tileEntry = UInt16(ppu.vram[tmAddr & 0xFFFF]) | (UInt16(ppu.vram[(tmAddr + 1) & 0xFFFF]) << 8)
        var tileNum = Int(tileEntry & 0x03FF)
        let palette = Int((tileEntry >> 10) & 0x07)
        let priority = Int((tileEntry >> 13) & 0x01)
        let hFlip = (tileEntry & 0x4000) != 0
        let vFlip = (tileEntry & 0x8000) != 0
        if tileSize == 16 {
            let sx = hFlip ? (1 - subTileX) : subTileX
            let sy = vFlip ? (1 - subTileY) : subTileY
            tileNum += sx + sy * 16
        }

        var fineY = py & 7
        if vFlip { fineY = 7 - fineY }
        let chrAddr = chrBase + tileNum * 32 + fineY * 2
        let bp0 = ppu.vram[chrAddr & 0xFFFF]
        let bp1 = ppu.vram[(chrAddr + 1) & 0xFFFF]
        let bp2 = ppu.vram[(chrAddr + 16) & 0xFFFF]
        let bp3 = ppu.vram[(chrAddr + 17) & 0xFFFF]
        let pixelRowLow = pixelRow(bp0, bp1)
        let pixelRowHigh = pixelRow(bp2, bp3)
        let merged = zip(pixelRowLow, pixelRowHigh).map { $0 | ($1 << 2) }
        let fineX = hFlip ? (7 - (px & 7)) : (px & 7)
        let pixel = merged[fineX]
        return String(format: "tile=%03X entry=%04X pal=%d pri=%d pixel=%d chr=%04X", tileNum, tileEntry, palette, priority, pixel, chrAddr & 0xFFFF)
    }

    private static func sampleBG2bpp(ppu: PPU, bg: Int, screenX: Int, screenY: Int, paletteBase: Int) -> String {
        let scReg = bg == 0 ? ppu.bg1sc : bg == 1 ? ppu.bg2sc : bg == 2 ? ppu.bg3sc : ppu.bg4sc
        let tilemapBase = Int(scReg & 0xFC) << 9
        let tileSize = (ppu.bgmode & (1 << (4 + bg))) != 0 ? 16 : 8
        let chrBase: Int
        if bg < 2 {
            chrBase = bg == 0 ? (Int(ppu.bg12nba & 0x0F) << 13) : (Int(ppu.bg12nba >> 4) << 13)
        } else {
            chrBase = bg == 2 ? (Int(ppu.bg34nba & 0x0F) << 13) : (Int(ppu.bg34nba >> 4) << 13)
        }

        let hScroll = Int(ppu.bgHScroll[bg]) & 0x3FF
        let vScroll = Int(ppu.bgVScroll[bg]) & 0x3FF
        let px = screenX + hScroll
        let py = screenY + vScroll

        let tileX: Int
        let tileY: Int
        let subTileX: Int
        let subTileY: Int
        if tileSize == 16 {
            tileX = (px / 16) & 0x3F
            tileY = (py / 16) & 0x3F
            subTileX = (px / 8) & 1
            subTileY = (py / 8) & 1
        } else {
            tileX = (px / 8) & 0x3F
            tileY = (py / 8) & 0x3F
            subTileX = 0
            subTileY = 0
        }

        var tmAddr = tilemapBase
        if tileX >= 32 { tmAddr += 0x800 }
        if tileY >= 32 {
            let scSize = scReg & 0x03
            if scSize == 2 {
                tmAddr += 0x800
            } else if scSize == 3 {
                tmAddr += 0x1000
            }
        }
        tmAddr += ((tileY & 0x1F) * 32 + (tileX & 0x1F)) * 2

        let tileEntry = UInt16(ppu.vram[tmAddr & 0xFFFF]) | (UInt16(ppu.vram[(tmAddr + 1) & 0xFFFF]) << 8)
        var tileNum = Int(tileEntry & 0x03FF)
        let palette = Int((tileEntry >> 10) & 0x07)
        let priority = Int((tileEntry >> 13) & 0x01)
        let hFlip = (tileEntry & 0x4000) != 0
        let vFlip = (tileEntry & 0x8000) != 0
        if tileSize == 16 {
            let sx = hFlip ? (1 - subTileX) : subTileX
            let sy = vFlip ? (1 - subTileY) : subTileY
            tileNum += sx + sy * 16
        }

        var fineY = py & 7
        if vFlip { fineY = 7 - fineY }
        let chrAddr = chrBase + tileNum * 16 + fineY * 2
        let bp0 = ppu.vram[chrAddr & 0xFFFF]
        let bp1 = ppu.vram[(chrAddr + 1) & 0xFFFF]
        let merged = pixelRow(bp0, bp1)
        let fineX = hFlip ? (7 - (px & 7)) : (px & 7)
        let pixel = merged[fineX]
        return String(format: "tile=%03X entry=%04X pal=%d pri=%d pixel=%d palBase=%d chr=%04X", tileNum, tileEntry, palette, priority, pixel, paletteBase, chrAddr & 0xFFFF)
    }

    private static func pixelRow(_ bp0: UInt8, _ bp1: UInt8) -> [UInt8] {
        (0..<8).map { fineX in
            let bit = 7 - fineX
            return UInt8(((bp0 >> bit) & 1) | (((bp1 >> bit) & 1) << 1))
        }
    }

    private static func writeFramebufferPNG(ppu: PPU, path: String) {
        let width = SNESConstants.screenWidth
        let height = SNESConstants.screenHeight
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ),
        let dest = rep.bitmapData else {
            log("  SKIP: Could not allocate PNG bitmap for \(path)")
            return
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let (r, g, b) = ppu.readPixel(x: x, y: y, presented: true)
                dest[idx + 0] = r
                dest[idx + 1] = g
                dest[idx + 2] = b
                dest[idx + 3] = 0xFF
            }
        }

        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("  SKIP: Could not encode PNG for \(path)")
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            log("  Wrote framebuffer PNG to \(path)")
        } catch {
            log("  SKIP: Could not write PNG to \(path): \(error.localizedDescription)")
        }
    }

    private static func dumpCoreState(_ core: EmulatorCore, label: String) {
        let bus = core.bus
        let ppu = bus.ppu
        log(String(format:
            "\n=== %@ ===\n  PC=$%06X A=$%04X X=$%04X Y=$%04X P=$%02X S=$%04X\n  NMITIMEN=$%02X RDNMI=$%02X HVBJOY=$%02X TIMEUP=$%02X HDMAEN=$%02X MDMAEN=$%02X\n  INIDISP=$%02X TM=$%02X TS=$%02X BGMODE=$%02X CGWSEL=$%02X CGADSUB=$%02X SETINI=$%02X",
            label,
            pc(core),
            core.cpu.regs.A,
            core.cpu.regs.X,
            core.cpu.regs.Y,
            core.cpu.regs.P,
            core.cpu.regs.S,
            bus.nmitimen,
            bus.rdnmi,
            bus.hvbjoy,
            bus.timeup,
            bus.hdmaen,
            bus.mdmaen,
            ppu.inidisp,
            ppu.tm,
            ppu.ts,
            ppu.bgmode,
            ppu.cgwsel,
            ppu.cgadsub,
            ppu.setini
        ))
    }

    private static func dumpHDMAState(_ core: EmulatorCore, label: String) {
        let dma = core.bus.dma
        let enabledMask = core.bus.hdmaen
        log("\n=== \(label) HDMA ===")
        if enabledMask == 0 {
            log("  HDMA disabled")
            return
        }

        for ch in 0..<8 where (enabledMask & (1 << ch)) != 0 {
            let channel = dma.channels[ch]
            log(String(format:
                "  CH%d: ctl=$%02X dest=$%02X src=$%02X:%04X table=$%06X indirect=%@ active=%@ do=%@ line=$%02X hdmaAddr=$%04X",
                ch,
                channel.control,
                channel.destReg,
                channel.srcBank,
                channel.srcAddr,
                dma.hdmaTableAddr[ch],
                dma.hdmaIndirect[ch] ? "yes" : "no",
                dma.hdmaActive[ch] ? "yes" : "no",
                dma.hdmaDoTransfer[ch] ? "yes" : "no",
                dma.hdmaLineCounter[ch],
                channel.hdmaAddr
            ))
        }
    }

    private static func dumpDMAState(_ core: EmulatorCore, label: String) {
        let dma = core.bus.dma
        let enabledMask = core.bus.mdmaen
        log("\n=== \(label) DMA ===")
        if enabledMask == 0 {
            log("  General DMA disabled")
            return
        }

        for ch in 0..<8 where (enabledMask & (1 << ch)) != 0 {
            let channel = dma.channels[ch]
            let direction = (channel.control & 0x80) != 0 ? "B->A" : "A->B"
            let fixed = (channel.control & 0x08) != 0 ? "fixed" : "inc"
            let decrement = (channel.control & 0x10) != 0 ? "dec" : "fwd"
            log(String(format:
                "  CH%d: ctl=$%02X dir=%@ mode=%d dest=$%02X src=$%02X:%04X size=$%04X %@ %@",
                ch,
                channel.control,
                direction,
                channel.control & 0x07,
                channel.destReg,
                channel.srcBank,
                channel.srcAddr,
                channel.size,
                fixed,
                decrement
            ))
        }
    }

    private static func resetPPU(_ ppu: PPU) {
        ppu.inidisp = 0x80
        ppu.bgmode = 0
        ppu.mosaic = 0
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
        ppu.w12sel = 0
        ppu.w34sel = 0
        ppu.wobjsel = 0
        ppu.wh0 = 0
        ppu.wh1 = 0
        ppu.wh2 = 0
        ppu.wh3 = 0
        ppu.wbglog = 0
        ppu.wobjlog = 0
        ppu.tmw = 0
        ppu.tsw = 0
        for i in 0..<ppu.vram.count { ppu.vram[i] = 0 }
        for i in 0..<ppu.cgram.count { ppu.cgram[i] = 0 }
        for i in 0..<ppu.oam.count { ppu.oam[i] = 0 }
        ppu.restoreSnapshot(PPU.Snapshot())
    }

    private static func writeCGRAM(_ ppu: PPU, index: Int, bgr555: UInt16) {
        ppu.write(register: 0x2121, value: UInt8(index & 0xFF))
        ppu.write(register: 0x2122, value: UInt8(bgr555 & 0xFF))
        ppu.write(register: 0x2122, value: UInt8((bgr555 >> 8) & 0x7F))
    }
}
