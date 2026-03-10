import SwiftUI

struct PPURegisterView: View {
    @ObservedObject var debugState: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PPU Registers").font(.headline)

            let tm = debugState.ppuTM
            let layers = [
                tm & 0x01 != 0 ? "BG1" : nil,
                tm & 0x02 != 0 ? "BG2" : nil,
                tm & 0x04 != 0 ? "BG3" : nil,
                tm & 0x08 != 0 ? "BG4" : nil,
                tm & 0x10 != 0 ? "OBJ" : nil,
            ].compactMap { $0 }.joined(separator: "+")

            monoLine("INIDISP", hex8: debugState.ppuINIDISP,
                     note: debugState.ppuINIDISP & 0x80 != 0 ? "FBLANK" : "bright=\(debugState.ppuINIDISP & 0x0F)")
            monoLine("BGMODE", hex8: debugState.ppuBGMode,
                     note: "mode \(debugState.ppuBGMode & 0x07)")
            monoLine("TM", hex8: tm, note: layers.isEmpty ? "none" : layers)
            monoLine("OBJSEL", hex8: debugState.ppuOBJSEL, note: "")
            monoLine("BG12NBA", hex8: debugState.ppuBG12NBA, note: "")
            monoLine("BG34NBA", hex8: debugState.ppuBG34NBA, note: "")

            // Sprite tables computed
            let nb = Int(debugState.ppuOBJSEL & 0x07)
            let ng = Int((debugState.ppuOBJSEL >> 3) & 0x03)
            let t0 = nb << 14
            let t1 = t0 + ((ng + 1) << 13)
            Text("OBJ T0=0x\(String(format:"%04X",t0)) T1=0x\(String(format:"%04X",t1))")
                .font(.system(.caption, design: .monospaced))

            Divider()
            Text("Active Sprites").font(.subheadline)
            spriteList()
        }
    }

    private func monoLine(_ label: String, hex8 val: UInt8, note: String) -> some View {
        Text("\(label.padding(toLength: 8, withPad: " ", startingAt: 0))$\(String(format:"%02X", val))  \(note)")
            .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func spriteList() -> some View {
        let oam = debugState.ppuOAMSnapshot
        if oam.count < 544 {
            Text("No OAM data").foregroundColor(.secondary)
        } else {
            spriteEntries(oam: oam)
        }
    }

    private struct SpriteEntry: Identifiable {
        let id: Int  // OAM index
        let x: Int
        let y: Int
        let tile: Int
        let nt: Int
        let large: Bool
        let vramAddr: Int
    }

    private func collectVisibleSprites(oam: [UInt8]) -> [SpriteEntry] {
        let objsel = debugState.ppuOBJSEL
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

        let nb = Int(objsel & 0x07)
        let ng = Int((objsel >> 3) & 0x03)
        let nameBase = nb << 14
        let nameGap = (ng + 1) << 13

        var entries = [SpriteEntry]()
        for i in 0..<128 {
            let ba = i * 4
            let y = Int(oam[ba + 1])
            let spriteY = (y + 1) & 0xFF
            guard spriteY < 224 || spriteY > 240 else { continue }

            let x = Int(oam[ba])
            let tile = Int(oam[ba + 2])
            let attr = oam[ba + 3]
            let highIdx = 512 + (i >> 2)
            let highShift = (i & 3) * 2
            let highBits = (oam[highIdx] >> highShift) & 0x03
            let xBit9 = (highBits & 0x01) != 0
            let isLarge = (highBits & 0x02) != 0

            var sx = x
            if xBit9 { sx = x - 256 }
            let sz = isLarge ? largeSize : baseSize
            guard sx + sz > 0, sx < 256 else { continue }

            let nt = Int(attr & 0x01)
            let chrBase = nt == 0 ? nameBase : (nameBase + nameGap)
            let vramAddr = chrBase + (tile & 0xFF) * 32

            entries.append(SpriteEntry(id: i, x: sx, y: spriteY, tile: tile, nt: nt, large: isLarge, vramAddr: vramAddr))
            if entries.count >= 20 { break }
        }
        return entries
    }

    @ViewBuilder
    private func spriteEntries(oam: [UInt8]) -> some View {
        let entries = collectVisibleSprites(oam: oam)
        if entries.isEmpty {
            Text("No visible sprites").font(.caption).foregroundColor(.secondary)
        } else {
            ForEach(entries) { e in
                Text(String(format: "#%3d X=%4d Y=%3d T=$%02X NT%d %@ @%04X",
                            e.id, e.x, e.y, e.tile, e.nt,
                            e.large ? "L" : "S",
                            e.vramAddr))
                    .font(.system(.caption2, design: .monospaced))
            }
        }
    }
}
