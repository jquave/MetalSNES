import SwiftUI

struct SpriteDebugView: View {
    @ObservedObject var debugState: DebugState
    var onApply: () -> Void

    private let sizeLabels = [
        "0: 8×8 / 16×16",
        "1: 8×8 / 32×32",
        "2: 8×8 / 64×64",
        "3: 16×16 / 32×32",
        "4: 16×16 / 64×64",
        "5: 32×32 / 64×64",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sprite Tileset").font(.headline)

            Toggle("Override", isOn: $debugState.spriteOverrideEnabled)
                .toggleStyle(.checkbox)

            HStack {
                Text("Name Base")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $debugState.spriteNameBase) {
                    ForEach(0..<8, id: \.self) { i in
                        Text("\(i) (0x\(String(format: "%05X", i << 14)))").tag(i)
                    }
                }
                .labelsHidden()
                .onChange(of: debugState.spriteNameBase) { _ in applyIfEnabled() }
            }

            HStack {
                Text("Name Gap")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $debugState.spriteNameGap) {
                    ForEach(0..<4, id: \.self) { i in
                        Text("\(i) (+0x\(String(format: "%04X", (i + 1) << 13)))").tag(i)
                    }
                }
                .labelsHidden()
                .onChange(of: debugState.spriteNameGap) { _ in applyIfEnabled() }
            }

            HStack {
                Text("Size")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $debugState.spriteSizeSelect) {
                    ForEach(0..<6, id: \.self) { i in
                        Text(sizeLabels[i]).tag(i)
                    }
                }
                .labelsHidden()
                .onChange(of: debugState.spriteSizeSelect) { _ in applyIfEnabled() }
            }

            let nb = debugState.spriteNameBase
            let ng = debugState.spriteNameGap
            let t0 = nb << 14
            let t1 = t0 + ((ng + 1) << 13)
            Text("Table 0: 0x\(String(format: "%05X", t0))  Table 1: 0x\(String(format: "%05X", t1))")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func applyIfEnabled() {
        if debugState.spriteOverrideEnabled {
            onApply()
        }
    }
}
