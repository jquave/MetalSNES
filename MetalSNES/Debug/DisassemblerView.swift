import SwiftUI

struct DisassemblerView: View {
    @ObservedObject var debugState: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Disassembly").font(.headline)

            if !debugState.memoryAroundPC.isEmpty {
                let lines = disassembleLines()
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            } else {
                Text("No data")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func disassembleLines() -> [String] {
        var lines = [String]()
        var offset = 0
        let data = debugState.memoryAroundPC
        var pc = debugState.currentPC

        while offset < data.count - 4 && lines.count < 12 {
            let opcode = data[offset]
            let mnemonic = CPUInstructions.disassemble(opcode: opcode)

            let info = CPUInstructions.opcodeTable[opcode]
            let instrBytes: Int
            if let info = info {
                if info.bytes == 0 {
                    // Variable width based on M/X flags
                    let isM = info.addressingMode == "#immM"
                    if isM {
                        instrBytes = (debugState.p & 0x20) != 0 || debugState.emulationMode ? 2 : 3
                    } else {
                        instrBytes = (debugState.p & 0x10) != 0 || debugState.emulationMode ? 2 : 3
                    }
                } else {
                    instrBytes = info.bytes
                }
            } else {
                instrBytes = 1
            }

            var hexStr = ""
            for i in 0..<min(instrBytes, data.count - offset) {
                hexStr += String(format: "%02X ", data[offset + i])
            }

            let pointer = offset == 0 ? ">" : " "
            let addr = String(format: "%02X:%04X", (pc >> 16) & 0xFF, pc & 0xFFFF)
            let paddedHex = hexStr.padding(toLength: 12, withPad: " ", startingAt: 0)
            let line = "\(pointer)\(addr)  \(paddedHex)\(mnemonic)"
            lines.append(line)

            offset += instrBytes
            pc += UInt32(instrBytes)
        }
        return lines
    }
}
