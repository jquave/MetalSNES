import Foundation
import Network

/// Lightweight HTTP debug server for real-time SPC/DSP inspection.
/// Listens on port 8765, responds to GET requests with JSON.
final class DebugServer {
    private var listener: NWListener?
    weak var emulator: EmulatorCore?

    func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 8765)
        } catch {
            print("[DebugServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: DispatchQueue(label: "debugserver"))
        print("[DebugServer] Listening on port 8765")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: DispatchQueue(label: "debugconn"))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                conn.cancel()
                return
            }
            let request = String(data: data, encoding: .utf8) ?? ""
            let response = self.handleRequest(request)
            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n\(response)"
            conn.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func handleRequest(_ raw: String) -> String {
        // Parse "GET /path?query HTTP/1.1"
        let lines = raw.split(separator: "\r\n")
        guard let firstLine = lines.first else { return "{\"error\":\"empty request\"}" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "{\"error\":\"bad request\"}" }
        let fullPath = String(parts[1])

        // Split path and query
        let pathParts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        let queryString = pathParts.count > 1 ? String(pathParts[1]) : ""
        let params = parseQuery(queryString)

        guard let emu = emulator else { return "{\"error\":\"no emulator\"}" }
        let spc = emu.bus.apu.spc700
        let dsp = emu.bus.apu.dsp

        switch path {
        case "/spc/ram":
            let addr = parseHexInt(params["addr"] ?? "0")
            let len = Int(params["len"] ?? "16") ?? 16
            let clampedLen = min(len, 256)
            var bytes = [String]()
            for i in 0..<clampedLen {
                bytes.append(String(format: "%02X", spc.ram[(addr + i) & 0xFFFF]))
            }
            return "{\"addr\":\"\(String(format: "0x%04X", addr))\",\"len\":\(clampedLen),\"data\":[\(bytes.joined(separator: ",").replacingOccurrences(of: "\"", with: ""))]}"
                .replacingOccurrences(of: "[", with: "[\"")
                .replacingOccurrences(of: ",", with: "\",\"")
                .replacingOccurrences(of: "]", with: "\"]")

        case "/spc/ram/write":
            let addr = parseHexInt(params["addr"] ?? "0")
            let val = parseHexInt(params["val"] ?? "0")
            spc.ram[addr & 0xFFFF] = UInt8(val & 0xFF)
            return "{\"ok\":true,\"addr\":\"\(String(format: "0x%04X", addr))\",\"val\":\"\(String(format: "0x%02X", val))\"}"

        case "/spc/ports":
            let from = spc.portsFromCPU.map { String(format: "\"0x%02X\"", $0) }.joined(separator: ",")
            let to = spc.portsToCPU.map { String(format: "\"0x%02X\"", $0) }.joined(separator: ",")
            return "{\"portsFromCPU\":[\(from)],\"portsToCPU\":[\(to)]}"

        case "/spc/ports/write":
            let port = Int(params["port"] ?? "0") ?? 0
            let val = parseHexInt(params["val"] ?? "0")
            if port >= 0 && port < 4 {
                spc.portsFromCPU[port] = UInt8(val & 0xFF)
                return "{\"ok\":true,\"port\":\(port),\"val\":\"\(String(format: "0x%02X", val))\"}"
            }
            return "{\"error\":\"invalid port\"}"

        case "/spc/regs":
            let psw = spc.psw
            return """
            {"a":"\(String(format: "0x%02X", spc.a))","x":"\(String(format: "0x%02X", spc.x))","y":"\(String(format: "0x%02X", spc.y))","sp":"\(String(format: "0x%02X", spc.sp))","pc":"\(String(format: "0x%04X", spc.pc))","psw":"\(String(format: "0x%02X", psw))","flags":{"N":\(spc.flagN),"V":\(spc.flagV),"P":\(spc.flagP),"H":\(spc.flagH),"Z":\(spc.flagZ),"C":\(spc.flagC)}}
            """

        case "/spc/timers":
            var timers = [[String: Any]]()
            for i in 0..<3 {
                timers.append([
                    "enabled": spc.timerEnabled[i],
                    "divisor": spc.timerDivisor[i],
                    "counter": spc.timerCounter[i],
                    "internal": spc.timerInternal[i]
                ])
            }
            let entries = timers.enumerated().map { i, t in
                "{\"id\":\(i),\"enabled\":\(t["enabled"]!),\"divisor\":\(t["divisor"]!),\"counter\":\(t["counter"]!),\"internal\":\(t["internal"]!)}"
            }.joined(separator: ",")
            return "[\(entries)]"

        case "/dsp/regs":
            var entries = [String]()
            for i in 0..<128 {
                entries.append(String(format: "\"0x%02X\"", dsp.regs[i]))
            }
            return "{\"regs\":[\(entries.joined(separator: ","))]}"

        case "/dsp/regs/write":
            let reg = parseHexInt(params["reg"] ?? "0")
            let val = parseHexInt(params["val"] ?? "0")
            if reg >= 0 && reg < 128 {
                dsp.write(register: UInt8(reg), value: UInt8(val & 0xFF))
                return "{\"ok\":true,\"reg\":\"\(String(format: "0x%02X", reg))\",\"val\":\"\(String(format: "0x%02X", val))\"}"
            }
            return "{\"error\":\"invalid register\"}"

        case "/dsp/kon":
            // Key on specified voices with full setup
            // params: voice, srcn, pitch, volL, volR, adsr1, adsr2
            let v = Int(params["voice"] ?? "0") ?? 0
            guard v >= 0 && v < 8 else { return "{\"error\":\"invalid voice\"}" }
            let vo = v * 0x10
            let srcn = parseHexInt(params["srcn"] ?? "0")
            let pitch = parseHexInt(params["pitch"] ?? "0x1000")
            let volL = parseHexInt(params["volL"] ?? "127")
            let volR = parseHexInt(params["volR"] ?? "127")
            let adsr1 = parseHexInt(params["adsr1"] ?? "0xFF")
            let adsr2 = parseHexInt(params["adsr2"] ?? "0xE0")
            dsp.write(register: UInt8(vo), value: UInt8(volL & 0xFF))
            dsp.write(register: UInt8(vo + 1), value: UInt8(volR & 0xFF))
            dsp.write(register: UInt8(vo + 2), value: UInt8(pitch & 0xFF))
            dsp.write(register: UInt8(vo + 3), value: UInt8((pitch >> 8) & 0x3F))
            dsp.write(register: UInt8(vo + 4), value: UInt8(srcn & 0xFF))
            dsp.write(register: UInt8(vo + 5), value: UInt8(adsr1 & 0xFF))
            dsp.write(register: UInt8(vo + 6), value: UInt8(adsr2 & 0xFF))
            dsp.write(register: 0x4C, value: UInt8(1 << v))
            return "{\"ok\":true,\"voice\":\(v),\"srcn\":\"\(String(format: "0x%02X", srcn))\",\"pitch\":\"\(String(format: "0x%04X", pitch))\"}"

        case "/dsp/voices":
            var voiceEntries = [String]()
            for v in 0..<8 {
                let vo = v * 0x10
                let pitch = UInt16(dsp.regs[vo + 2]) | (UInt16(dsp.regs[vo + 3] & 0x3F) << 8)
                let srcn = dsp.regs[vo + 4]
                voiceEntries.append("""
                {"voice":\(v),"keyed":\(dsp.voices[v].keyedOn),"envLevel":\(dsp.voices[v].envLevel),"envMode":"\(dsp.voices[v].envMode)","pitch":"\(String(format: "0x%04X", pitch))","srcn":"\(String(format: "0x%02X", srcn))","brrAddr":"\(String(format: "0x%04X", dsp.voices[v].brrAddr))","volL":\(Int8(bitPattern: dsp.regs[vo])),"volR":\(Int8(bitPattern: dsp.regs[vo + 1]))}
                """.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return "[\(voiceEntries.joined(separator: ","))]"

        case "/ppu/vram":
            let addr = parseHexInt(params["addr"] ?? "0")
            let len = min(Int(params["len"] ?? "16") ?? 16, 512)
            var bytes = [String]()
            for i in 0..<len {
                bytes.append(String(format: "\"%02X\"", emu.bus.ppu.vram[(addr + i) & 0xFFFF]))
            }
            return "{\"addr\":\"\(String(format: "0x%04X", addr))\",\"data\":[\(bytes.joined(separator: ","))]}"

        case "/cpu/wram":
            let addr = parseHexInt(params["addr"] ?? "0")
            let len = min(Int(params["len"] ?? "16") ?? 16, 256)
            var bytes = [String]()
            for i in 0..<len {
                let idx = (addr + i) & 0x1FFFF
                bytes.append(String(format: "\"%02X\"", emu.bus.wram[idx]))
            }
            return "{\"addr\":\"\(String(format: "0x%04X", addr))\",\"data\":[\(bytes.joined(separator: ","))]}"

        case "/cpu/wram/write":
            let addr = parseHexInt(params["addr"] ?? "0")
            let val = parseHexInt(params["val"] ?? "0")
            let idx = addr & 0x1FFFF
            emu.bus.wram[idx] = UInt8(val & 0xFF)
            return "{\"ok\":true,\"addr\":\"\(String(format: "0x%04X", addr))\",\"val\":\"\(String(format: "0x%02X", val))\"}"

        case "/cpu/regs":
            let r = emu.cpu.regs
            return "{\"A\":\"\(String(format: "0x%04X", r.A))\",\"X\":\"\(String(format: "0x%04X", r.X))\",\"Y\":\"\(String(format: "0x%04X", r.Y))\",\"S\":\"\(String(format: "0x%04X", r.S))\",\"D\":\"\(String(format: "0x%04X", r.D))\",\"PC\":\"\(String(format: "0x%04X", r.PC))\",\"PBR\":\"\(String(format: "0x%02X", r.PBR))\",\"DBR\":\"\(String(format: "0x%02X", r.DBR))\",\"P\":\"\(String(format: "0x%02X", r.P))\",\"E\":\(r.emulationMode)}"

        case "/cpu/write-log":
            let entries = emu.bus.cpuWriteLog.suffix(200).map { entry in
                String(format: "{\"pc\":\"0x%06X\",\"opcode\":\"0x%02X\",\"target\":\"0x%06X\",\"value\":\"0x%02X\"}",
                       entry.pc, entry.opcode, entry.target, entry.value)
            }
            return "{\"count\":\(emu.bus.cpuWriteLog.count),\"log\":[\(entries.joined(separator: ","))]}"

        case "/cpu/trace":
            let ms = min(Int(params["ms"] ?? "50") ?? 50, 500)
            emu.cpu.traceLog.removeAll(keepingCapacity: true)
            emu.cpu.traceEnabled = true
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            emu.cpu.traceEnabled = false
            let lines = emu.cpu.traceLog.map {
                String(format: "{\"pc\":\"0x%06X\",\"opcode\":\"0x%02X\",\"a\":\"0x%04X\",\"x\":\"0x%04X\",\"y\":\"0x%04X\",\"s\":\"0x%04X\",\"d\":\"0x%04X\",\"p\":\"0x%02X\",\"e\":%d}",
                       $0.pc, $0.opcode, $0.a, $0.x, $0.y, $0.s, $0.d, $0.p, $0.emulationMode ? 1 : 0)
            }
            return "{\"count\":\(lines.count),\"trace\":[\(lines.joined(separator: ","))]}"

        case "/cpu/recent-trace":
            let count = min(Int(params["count"] ?? "200") ?? 200, emu.cpu.recentTrace.count)
            let lines = emu.cpu.recentTrace.suffix(count).map {
                String(format: "{\"pc\":\"0x%06X\",\"opcode\":\"0x%02X\",\"a\":\"0x%04X\",\"x\":\"0x%04X\",\"y\":\"0x%04X\",\"s\":\"0x%04X\",\"d\":\"0x%04X\",\"p\":\"0x%02X\",\"e\":%d}",
                       $0.pc, $0.opcode, $0.a, $0.x, $0.y, $0.s, $0.d, $0.p, $0.emulationMode ? 1 : 0)
            }
            return "{\"count\":\(count),\"trace\":[\(lines.joined(separator: ","))]}"

        case "/audio/stats":
            let buffered = emu.bus.apu.audioOutput.bufferedSamples
            return "{\"buffered\":\(buffered),\"dspSamples\":\(dsp.diagSampleCount),\"nonZero\":\(dsp.diagNonZeroSamples),\"konCount\":\(dsp.diagKonCount)}"

        case "/bus/regs":
            return """
            {"nmitimen":"\(String(format: "0x%02X", emu.bus.nmitimen))","rdnmi":"\(String(format: "0x%02X", emu.bus.rdnmi))","hvbjoy":"\(String(format: "0x%02X", emu.bus.hvbjoy))","nmiPending":\(emu.bus.nmiPending),"inVBlank":\(emu.bus.inVBlank)}
            """

        case "/spc/trace":
            let count = Int(params["count"] ?? "500") ?? 500
            spc.traceEnabled2 = true
            spc.traceCountdown = count
            spc.traceLog2.removeAll()
            // Wait for trace to complete
            var waited = 0
            while spc.traceEnabled2 && waited < 100 {
                Thread.sleep(forTimeInterval: 0.01)
                waited += 1
            }
            let lines = spc.traceLog2.prefix(count).map { "\"\($0)\"" }
            return "{\"count\":\(lines.count),\"trace\":[\(lines.joined(separator: ","))]}"

        case "/spc/inject":
            // Pause emulation, set all 4 CPU→SPC ports atomically, resume
            // params: p0, p1, p2, p3 (hex values), pause (ms to keep paused, default 100)
            let p0 = parseHexInt(params["p0"] ?? "-1")
            let p1 = parseHexInt(params["p1"] ?? "-1")
            let p2 = parseHexInt(params["p2"] ?? "-1")
            let p3 = parseHexInt(params["p3"] ?? "-1")
            let pauseMs = Int(params["pause"] ?? "100") ?? 100

            // Pause emulation
            emu._pauseFrames.withLock { $0 = max(pauseMs, 10) }
            Thread.sleep(forTimeInterval: 0.005) // let emulation stop

            // Set ports
            if p0 >= 0 { spc.portsFromCPU[0] = UInt8(p0 & 0xFF) }
            if p1 >= 0 { spc.portsFromCPU[1] = UInt8(p1 & 0xFF) }
            if p2 >= 0 { spc.portsFromCPU[2] = UInt8(p2 & 0xFF) }
            if p3 >= 0 { spc.portsFromCPU[3] = UInt8(p3 & 0xFF) }

            // Also write to WRAM mirrors so NMI handler doesn't overwrite
            if p0 >= 0 { emu.bus.wram[0x1DF9] = UInt8(p0 & 0xFF) }
            if p1 >= 0 { emu.bus.wram[0x1DFA] = UInt8(p1 & 0xFF) }
            if p2 >= 0 { emu.bus.wram[0x1DFB] = UInt8(p2 & 0xFF) }
            if p3 >= 0 { emu.bus.wram[0x1DFC] = UInt8(p3 & 0xFF) }

            let portState = String(format: "[%02X,%02X,%02X,%02X]",
                                   spc.portsFromCPU[0], spc.portsFromCPU[1],
                                   spc.portsFromCPU[2], spc.portsFromCPU[3])
            return "{\"ok\":true,\"ports\":\"\(portState)\",\"pauseMs\":\(pauseMs)}"

        case "/wram/range":
            let addr = parseHexInt(params["addr"] ?? "0")
            let len = min(Int(params["len"] ?? "16") ?? 16, 256)
            var bytes = [String]()
            for i in 0..<len {
                let idx = (addr + i) & 0x1FFFF
                bytes.append(String(format: "\"%02X\"", emu.bus.wram[idx]))
            }
            return "{\"addr\":\"\(String(format: "0x%04X", addr))\",\"data\":[\(bytes.joined(separator: ","))]}"

        case "/wram/watch":
            // Set watchpoint: /wram/watch?addr=0x1DFB  Clear: /wram/watch?addr=-1
            let addr = parseHexInt(params["addr"] ?? "-1")
            emu.bus.wramWatchpoint = addr
            emu.bus.wramWatchLog.removeAll()
            return "{\"ok\":true,\"watching\":\"\(String(format: "0x%04X", addr))\"}"

        case "/wram/watch/log":
            let entries = emu.bus.wramWatchLog.prefix(100).map { (caller, val) in
                String(format: "{\"from\":\"0x%06X\",\"val\":\"0x%02X\"}", caller, val)
            }
            return "{\"count\":\(emu.bus.wramWatchLog.count),\"log\":[\(entries.joined(separator: ","))]}"

        default:
            return """
            {"endpoints":["/spc/ram?addr=0x0000&len=16","/spc/ram/write?addr=0x01&val=0x01","/spc/ports","/spc/ports/write?port=2&val=0x01","/spc/regs","/spc/timers","/dsp/regs","/dsp/regs/write?reg=0x4C&val=0x01","/dsp/kon?voice=0&srcn=0&pitch=0x1000","/dsp/voices","/cpu/wram?addr=0x1DFB&len=16","/cpu/wram/write?addr=0x1DFB&val=0x01","/cpu/regs","/cpu/write-log","/cpu/trace?ms=50","/audio/stats","/spc/trace?count=500","/spc/inject?p0=0x01&p2=0x01","/wram/range?addr=0x1DF9&len=8"]}
            """
        }
    }

    private func parseQuery(_ q: String) -> [String: String] {
        var result = [String: String]()
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1])
            }
        }
        return result
    }

    private func parseHexInt(_ s: String) -> Int {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return Int(s.dropFirst(2), radix: 16) ?? 0
        }
        return Int(s) ?? 0
    }
}
