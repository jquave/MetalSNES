import SwiftUI

struct MemoryViewer: View {
    @ObservedObject var debugState: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory").font(.headline)

            if debugState.memoryPage.count >= 256 {
                ForEach(0..<16, id: \.self) { row in
                    HStack(spacing: 4) {
                        Text(String(format: "%04X:", debugState.memoryViewerOffset + row * 16))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        ForEach(0..<16, id: \.self) { col in
                            let idx = row * 16 + col
                            Text(String(format: "%02X", debugState.memoryPage[idx]))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            } else {
                Text("No data")
                    .foregroundColor(.secondary)
            }
        }
    }
}
