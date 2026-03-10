import SwiftUI
import AppKit

struct VRAMTileViewer: View {
    @ObservedObject var debugState: DebugState
    @State private var bpp: Int = 4          // 2 or 4
    @State private var baseOffset: Int = 0   // in 0x1000 (4KB) steps
    @State private var palette: Int = 0      // CGRAM palette index
    @State private var scale: CGFloat = 2.0

    // 16 tiles per row, show as many rows as fit
    private let tilesPerRow = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VRAM Tiles").font(.headline)

            HStack {
                Picker("Depth", selection: $bpp) {
                    Text("2bpp").tag(2)
                    Text("4bpp").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)

                Picker("Pal", selection: $palette) {
                    if bpp == 2 {
                        ForEach(0..<32, id: \.self) { i in Text("\(i)").tag(i) }
                    } else {
                        ForEach(0..<16, id: \.self) { i in Text("\(i)").tag(i) }
                    }
                }
                .frame(width: 70)
            }

            HStack {
                Text("Base: 0x\(String(format: "%04X", baseOffset * 0x1000))")
                    .font(.system(.caption, design: .monospaced))
                Stepper("", value: $baseOffset, in: 0...15)
                    .labelsHidden()
            }

            // BG chr base readout
            let bg1chr = debugState.bg1ChrBase
            let bg2chr = debugState.bg2ChrBase
            let bg3chr = debugState.bg3ChrBase
            Text("BG chr: 1=0x\(String(format:"%04X", bg1chr)) 2=0x\(String(format:"%04X", bg2chr)) 3=0x\(String(format:"%04X", bg3chr))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            if let image = renderTileGrid() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: CGFloat(tilesPerRow * 8) * scale,
                           height: CGFloat(rowCount * 8) * scale)
            } else {
                Text("No VRAM data")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var bytesPerTile: Int { bpp == 2 ? 16 : 32 }

    private var rowCount: Int {
        let vramRegionSize = 0x1000 // 4KB per step
        let tilesInRegion = vramRegionSize / bytesPerTile
        return max(tilesInRegion / tilesPerRow, 1)
    }

    private func renderTileGrid() -> NSImage? {
        let vram = debugState.vramSnapshot
        guard vram.count == 0x10000 else { return nil }

        let base = baseOffset * 0x1000
        let tilesInRegion = 0x1000 / bytesPerTile
        let rows = tilesInRegion / tilesPerRow
        let cgram = debugState.cgramSnapshot

        let width = tilesPerRow * 8
        let height = rows * 8
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for tileIdx in 0..<tilesInRegion {
            let tileRow = tileIdx / tilesPerRow
            let tileCol = tileIdx % tilesPerRow
            let tileAddr = base + tileIdx * bytesPerTile

            for fineY in 0..<8 {
                let chrAddr = tileAddr + fineY * 2

                for fineX in 0..<8 {
                    let bit = 7 - fineX
                    let pixel: UInt8

                    if bpp == 2 {
                        let bp0 = vram[(chrAddr) & 0xFFFF]
                        let bp1 = vram[(chrAddr + 1) & 0xFFFF]
                        pixel = ((bp0 >> bit) & 1) | (((bp1 >> bit) & 1) << 1)
                    } else {
                        let bp0 = vram[(chrAddr) & 0xFFFF]
                        let bp1 = vram[(chrAddr + 1) & 0xFFFF]
                        let bp2 = vram[(chrAddr + 16) & 0xFFFF]
                        let bp3 = vram[(chrAddr + 17) & 0xFFFF]
                        pixel = ((bp0 >> bit) & 1) |
                                (((bp1 >> bit) & 1) << 1) |
                                (((bp2 >> bit) & 1) << 2) |
                                (((bp3 >> bit) & 1) << 3)
                    }

                    let r: UInt8, g: UInt8, b: UInt8
                    if pixel == 0 {
                        r = 0; g = 0; b = 0
                    } else if cgram.count == 512 {
                        let colorIdx: Int
                        if bpp == 2 {
                            colorIdx = palette * 4 + Int(pixel)
                        } else {
                            colorIdx = palette * 16 + Int(pixel)
                        }
                        let addr = (colorIdx * 2) & 0x1FF
                        let lo = UInt16(cgram[addr])
                        let hi = UInt16(cgram[addr + 1])
                        let bgr = lo | (hi << 8)
                        r = UInt8(((bgr >> 0) & 0x1F) << 3)
                        g = UInt8(((bgr >> 5) & 0x1F) << 3)
                        b = UInt8(((bgr >> 10) & 0x1F) << 3)
                    } else {
                        // Grayscale fallback
                        let gray = bpp == 2 ? pixel * 85 : pixel * 17
                        r = gray; g = gray; b = gray
                    }

                    let px = tileCol * 8 + fineX
                    let py = tileRow * 8 + fineY
                    let idx = (py * width + px) * 4
                    pixels[idx + 0] = r
                    pixels[idx + 1] = g
                    pixels[idx + 2] = b
                    pixels[idx + 3] = 255
                }
            }
        }

        return imageFromRGBA(pixels: pixels, width: width, height: height)
    }

    private func imageFromRGBA(pixels: [UInt8], width: Int, height: Int) -> NSImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var mutablePixels = pixels
        return mutablePixels.withUnsafeMutableBytes { buf -> NSImage? in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = ctx.makeImage() else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
    }
}
