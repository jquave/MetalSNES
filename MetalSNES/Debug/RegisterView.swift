import SwiftUI

struct RegisterView: View {
    @ObservedObject var debugState: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU Registers").font(.headline)

            HStack(spacing: 16) {
                regField("A", value: debugState.a, width: 4)
                regField("X", value: debugState.x, width: 4)
                regField("Y", value: debugState.y, width: 4)
            }
            HStack(spacing: 16) {
                regField("S", value: debugState.s, width: 4)
                regField("D", value: debugState.d, width: 4)
                regField16("PC", value: debugState.pc, width: 4)
            }
            HStack(spacing: 16) {
                regField8("PBR", value: debugState.pbr)
                regField8("DBR", value: debugState.dbr)
                regField8("P", value: debugState.p)
            }
            HStack {
                Text("Flags: \(debugState.flagsString)")
                    .font(.system(.body, design: .monospaced))
                Text(debugState.emulationMode ? "[E]" : "[N]")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func regField(_ name: String, value: UInt16, width: Int) -> some View {
        HStack(spacing: 2) {
            Text(name).foregroundColor(.secondary)
            Text(String(format: "%0\(width)X", value))
                .font(.system(.body, design: .monospaced))
        }
    }

    private func regField16(_ name: String, value: UInt16, width: Int) -> some View {
        regField(name, value: value, width: width)
    }

    private func regField8(_ name: String, value: UInt8) -> some View {
        HStack(spacing: 2) {
            Text(name).foregroundColor(.secondary)
            Text(String(format: "%02X", value))
                .font(.system(.body, design: .monospaced))
        }
    }
}
