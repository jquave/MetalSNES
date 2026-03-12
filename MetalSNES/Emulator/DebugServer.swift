import Foundation
import Network
import AppKit

/// Lightweight HTTP debug server for real-time emulator inspection.
/// Listens on port 8765, responds to GET requests with JSON.
final class DebugServer {
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "debugserver.listener")
    private let connectionQueue = DispatchQueue(label: "debugserver.connection", attributes: .concurrent)
    weak var emulator: EmulatorCore?

    func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 8765)
        } catch {
            print("[DebugServer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[DebugServer] Listening on port 8765")
                fflush(stdout)
            case .failed(let error):
                print("[DebugServer] Listener failed: \(error)")
                fflush(stdout)
                self?.listener?.cancel()
                self?.listener = nil
            default:
                break
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: listenerQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: connectionQueue)
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
        case "/emu/run":
            guard !emu.isRunning else {
                return "{\"error\":\"emulator is already running\"}"
            }
            let frames = max(1, min(600, Int(params["frames"] ?? "1") ?? 1))
            emu.runDebugFrames(frames)
            let pc = (UInt32(emu.cpu.regs.PBR) << 16) | UInt32(emu.cpu.regs.PC)
            return String(format:
                "{\"ok\":true,\"frames\":%d,\"frameCount\":%llu,\"pc\":\"0x%06X\",\"inidisp\":\"0x%02X\",\"tm\":\"0x%02X\",\"ts\":\"0x%02X\",\"hvbjoy\":\"0x%02X\"}",
                frames,
                emu.completedFrames,
                pc,
                emu.bus.ppu.inidisp,
                emu.bus.ppu.tm,
                emu.bus.ppu.ts,
                emu.bus.hvbjoy
            )

        case "/emu/save-state":
            guard !emu.isRunning else {
                return "{\"error\":\"emulator is already running\"}"
            }
            guard let statePath = params["path"], !statePath.isEmpty else {
                return "{\"error\":\"missing path\"}"
            }
            let codec = SaveState()
            let data = codec.save(core: emu)
            do {
                try data.write(to: URL(fileURLWithPath: statePath))
                return "{\"ok\":true,\"path\":\"\(jsonEscaped(statePath))\",\"bytes\":\(data.count)}"
            } catch {
                return "{\"error\":\"\(jsonEscaped(error.localizedDescription))\"}"
            }

        case "/emu/load-state":
            guard !emu.isRunning else {
                return "{\"error\":\"emulator is already running\"}"
            }
            guard let statePath = params["path"], !statePath.isEmpty else {
                return "{\"error\":\"missing path\"}"
            }
            let codec = SaveState()
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
                try codec.restore(from: data, core: emu)
                let pc = (UInt32(emu.cpu.regs.PBR) << 16) | UInt32(emu.cpu.regs.PC)
                return String(
                    format: "{\"ok\":true,\"path\":\"%@\",\"bytes\":%d,\"pc\":\"0x%06X\",\"inidisp\":\"0x%02X\"}",
                    jsonEscaped(statePath),
                    data.count,
                    pc,
                    emu.bus.ppu.inidisp
                )
            } catch {
                return "{\"error\":\"\(jsonEscaped(error.localizedDescription))\"}"
            }

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

        case "/ppu/regs":
            let ppu = emu.bus.ppu
            let hScroll = ppu.bgHScroll.enumerated().map { index, value in
                String(format: "\"bg%d\":\"0x%04X\"", index + 1, value)
            }.joined(separator: ",")
            let vScroll = ppu.bgVScroll.enumerated().map { index, value in
                String(format: "\"bg%d\":\"0x%04X\"", index + 1, value)
            }.joined(separator: ",")
            return """
            {"inidisp":"\(String(format: "0x%02X", ppu.inidisp))","bgmode":"\(String(format: "0x%02X", ppu.bgmode))","tm":"\(String(format: "0x%02X", ppu.tm))","ts":"\(String(format: "0x%02X", ppu.ts))","cgwsel":"\(String(format: "0x%02X", ppu.cgwsel))","cgadsub":"\(String(format: "0x%02X", ppu.cgadsub))","setini":"\(String(format: "0x%02X", ppu.setini))","bg1sc":"\(String(format: "0x%02X", ppu.bg1sc))","bg2sc":"\(String(format: "0x%02X", ppu.bg2sc))","bg3sc":"\(String(format: "0x%02X", ppu.bg3sc))","bg4sc":"\(String(format: "0x%02X", ppu.bg4sc))","bg12nba":"\(String(format: "0x%02X", ppu.bg12nba))","bg34nba":"\(String(format: "0x%02X", ppu.bg34nba))","bgHScroll":{\(hScroll)},"bgVScroll":{\(vScroll)}}
            """

        case "/ppu/bg-sample":
            let bg = max(1, min(4, Int(params["bg"] ?? "1") ?? 1)) - 1
            let x = max(0, min(255, Int(params["x"] ?? "0") ?? 0))
            let y = max(0, min(223, Int(params["y"] ?? "0") ?? 0))
            guard let sample = emu.bus.ppu.debugSampleBG4bpp(bg: bg, screenX: x, screenY: y) else {
                return "{\"error\":\"unsupported bg\"}"
            }
            return """
            {"bg":\(sample.bg + 1),"x":\(sample.screenX),"y":\(sample.screenY),"sampleX":\(sample.sampleX),"sampleY":\(sample.sampleY),"hScroll":"\(String(format: "0x%04X", sample.hScroll))","vScroll":"\(String(format: "0x%04X", sample.vScroll))","hOffsetEntry":"\(String(format: "0x%04X", sample.horizontalOffsetEntry))","vOffsetEntry":"\(String(format: "0x%04X", sample.verticalOffsetEntry))","hOffsetApplied":\(sample.horizontalOffsetApplied),"vOffsetApplied":\(sample.verticalOffsetApplied),"tileEntry":"\(String(format: "0x%04X", sample.tileEntry))","tile":"\(String(format: "0x%03X", sample.tileNumber))","palette":\(sample.palette),"priority":\(sample.highPriority ? 1 : 0),"hFlip":\(sample.hFlip),"vFlip":\(sample.vFlip),"pixel":\(sample.pixel),"colorIndex":"\(String(format: "0x%02X", sample.colorIndex))","chrAddr":"\(String(format: "0x%04X", sample.chrAddr))"}
            """

        case "/ppu/frame-summary":
            return frameSummary(ppu: emu.bus.ppu, presented: params["presented"] != "0")

        case "/ppu/frame-dump":
            let path = params["path"] ?? "/tmp/metalsnes-frame.png"
            return dumpFrame(ppu: emu.bus.ppu, presented: params["presented"] != "0", path: path)

        case "/ppu/frame-dump-layer":
            let path = params["path"] ?? "/tmp/metalsnes-layer-frame.png"
            let mask = UInt8(parseHexInt(params["mask"] ?? "0") & 0x1F)
            let subScreen = params["sub"] == "1"
            let pixels = emu.bus.ppu.debugRenderLayerFrame(layerMask: mask, subScreen: subScreen)
            return dumpFrame(pixels: pixels, path: path)

        case "/ppu/oam":
            let start = max(0, min(127, Int(params["index"] ?? "0") ?? 0))
            let count = max(1, min(128 - start, Int(params["count"] ?? "1") ?? 1))
            let entries = (start..<(start + count)).map { spriteDescription(ppu: emu.bus.ppu, index: $0) }
            return "{\"start\":\(start),\"count\":\(count),\"entries\":[\(entries.joined(separator: ","))]}"

        case "/ppu/sprites":
            let scanline = max(0, min(223, Int(params["scanline"] ?? "0") ?? 0))
            let entries = sprites(on: scanline, ppu: emu.bus.ppu).map { spriteDescription(ppu: emu.bus.ppu, index: $0.index, details: $0) }
            return "{\"scanline\":\(scanline),\"count\":\(entries.count),\"entries\":[\(entries.joined(separator: ","))]}"

        case "/ppu/sprite-sample":
            let x = max(0, min(255, Int(params["x"] ?? "0") ?? 0))
            let y = max(0, min(223, Int(params["y"] ?? "0") ?? 0))
            let samples = spriteSamples(atX: x, y: y, ppu: emu.bus.ppu)
            return "{\"x\":\(x),\"y\":\(y),\"count\":\(samples.count),\"samples\":[\(samples.joined(separator: ","))]}"

        case "/superfx/regs":
            guard let superFX = emu.bus.superFX else {
                return "{\"error\":\"no superfx\"}"
            }
            let snapshot = superFX.debugSnapshot()
            let regs = snapshot.regs.map { String(format: "\"0x%04X\"", $0) }.joined(separator: ",")
            let flags = """
            {"z":\(snapshot.sfr & 0x0002 != 0),"cy":\(snapshot.sfr & 0x0004 != 0),"s":\(snapshot.sfr & 0x0008 != 0),"ov":\(snapshot.sfr & 0x0010 != 0),"g":\(snapshot.sfr & 0x0020 != 0),"r":\(snapshot.sfr & 0x0040 != 0),"alt1":\(snapshot.sfr & 0x0100 != 0),"alt2":\(snapshot.sfr & 0x0200 != 0),"il":\(snapshot.sfr & 0x0400 != 0),"ih":\(snapshot.sfr & 0x0800 != 0),"b":\(snapshot.sfr & 0x1000 != 0),"irq":\(snapshot.sfr & 0x8000 != 0)}
            """
            return """
            {"r":[\(regs)],"sfr":"\(String(format: "0x%04X", snapshot.sfr))","flags":\(flags),"pbr":"\(String(format: "0x%02X", snapshot.pbr))","rombr":"\(String(format: "0x%02X", snapshot.rombr))","rambr":"\(String(format: "0x%02X", snapshot.rambr))","cbr":"\(String(format: "0x%04X", snapshot.cbr))","scbr":"\(String(format: "0x%02X", snapshot.scbr))","scmr":"\(String(format: "0x%02X", snapshot.scmr))","colr":"\(String(format: "0x%02X", snapshot.colr))","por":"\(String(format: "0x%02X", snapshot.por))","vcr":"\(String(format: "0x%02X", snapshot.vcr))","cfgr":"\(String(format: "0x%02X", snapshot.cfgr))","clsr":"\(String(format: "0x%02X", snapshot.clsr))","pipeline":"\(String(format: "0x%02X", snapshot.pipeline))","ramaddr":"\(String(format: "0x%04X", snapshot.ramaddr))","romcl":"\(String(format: "0x%08X", snapshot.romcl))","romdr":"\(String(format: "0x%02X", snapshot.romdr))","ramcl":"\(String(format: "0x%08X", snapshot.ramcl))","ramar":"\(String(format: "0x%04X", snapshot.ramar))","ramdr":"\(String(format: "0x%02X", snapshot.ramdr))","irqLine":\(snapshot.irqActive)}
            """

        case "/superfx/recent-trace":
            guard let superFX = emu.bus.superFX else {
                return "{\"error\":\"no superfx\"}"
            }
            let count = min(Int(params["count"] ?? "64") ?? 64, 512)
            let entries = superFX.recentTrace(limit: count).map { entry in
                String(
                    format: "{\"pbr\":\"0x%02X\",\"rombr\":\"0x%02X\",\"opcode\":\"0x%02X\",\"r12\":\"0x%04X\",\"r13\":\"0x%04X\",\"r14\":\"0x%04X\",\"r15\":\"0x%04X\",\"sfr\":\"0x%04X\"}",
                    entry.pbr,
                    entry.rombr,
                    entry.opcode,
                    entry.r12,
                    entry.r13,
                    entry.r14,
                    entry.r15,
                    entry.sfr
                )
            }
            return "{\"count\":\(entries.count),\"trace\":[\(entries.joined(separator: ","))]}"

        case "/superfx/ram":
            guard emu.bus.superFX != nil else {
                return "{\"error\":\"no superfx\"}"
            }
            let start = min(max(parseHexInt(params["addr"] ?? "0"), 0), emu.bus.sram.count - 1)
            let requestedLen = Int(params["len"] ?? "16") ?? 16
            let len = max(1, min(requestedLen, min(512, emu.bus.sram.count - start)))
            let bytes = (0..<len).map { String(format: "\"%02X\"", emu.bus.sram[start + $0]) }
            return "{\"addr\":\"\(String(format: "0x%04X", start))\",\"len\":\(len),\"size\":\(emu.bus.sram.count),\"data\":[\(bytes.joined(separator: ","))]}"

        case "/dma/state":
            let dma = emu.bus.dma
            let channels = (0..<8).map { ch in
                let channel = dma.channels[ch]
                return String(format:
                    "{\"channel\":%d,\"mdma\":%d,\"hdma\":%d,\"control\":\"0x%02X\",\"mode\":%d,\"destReg\":\"0x%02X\",\"srcBank\":\"0x%02X\",\"srcAddr\":\"0x%04X\",\"size\":\"0x%04X\",\"hdmaBank\":\"0x%02X\",\"hdmaAddr\":\"0x%04X\",\"active\":%d,\"doTransfer\":%d,\"lineCounter\":\"0x%02X\"}",
                    ch,
                    (emu.bus.mdmaen & (1 << ch)) != 0 ? 1 : 0,
                    (emu.bus.hdmaen & (1 << ch)) != 0 ? 1 : 0,
                    channel.control,
                    channel.control & 0x07,
                    channel.destReg,
                    channel.srcBank,
                    channel.srcAddr,
                    channel.size,
                    channel.hdmaBank,
                    channel.hdmaAddr,
                    dma.hdmaActive[ch] ? 1 : 0,
                    dma.hdmaDoTransfer[ch] ? 1 : 0,
                    dma.hdmaLineCounter[ch]
                )
            }
            return "{\"mdmaen\":\"\(String(format: "0x%02X", emu.bus.mdmaen))\",\"hdmaen\":\"\(String(format: "0x%02X", emu.bus.hdmaen))\",\"channels\":[\(channels.joined(separator: ","))]}"

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
            return "{\"A\":\"\(String(format: "0x%04X", r.A))\",\"X\":\"\(String(format: "0x%04X", r.X))\",\"Y\":\"\(String(format: "0x%04X", r.Y))\",\"S\":\"\(String(format: "0x%04X", r.S))\",\"D\":\"\(String(format: "0x%04X", r.D))\",\"PC\":\"\(String(format: "0x%04X", r.PC))\",\"PBR\":\"\(String(format: "0x%02X", r.PBR))\",\"DBR\":\"\(String(format: "0x%02X", r.DBR))\",\"P\":\"\(String(format: "0x%02X", r.P))\",\"E\":\(r.emulationMode),\"stopped\":\(r.stopped),\"waiting\":\(r.waiting),\"nmiPending\":\(r.nmiPending),\"irqPending\":\(r.irqPending),\"masterCarry\":\(emu.cpuMasterCycleCarry)}"

        case "/cpu/write-log":
            let count = min(Int(params["count"] ?? "200") ?? 200, 2000)
            let targetFilter = params["target"].map(parseHexInt)
            let entries = emu.bus.cpuWriteLog.filter { entry in
                guard let targetFilter else { return true }
                return Int(entry.target & 0xFFFF) == targetFilter
            }.suffix(count).map { entry in
                String(format: "{\"pc\":\"0x%06X\",\"opcode\":\"0x%02X\",\"target\":\"0x%06X\",\"value\":\"0x%02X\"}",
                       entry.pc, entry.opcode, entry.target, entry.value)
            }
            return "{\"count\":\(entries.count),\"total\":\(emu.bus.cpuWriteLog.count),\"log\":[\(entries.joined(separator: ","))]}"

        case "/cpu/write-log/clear":
            emu.bus.cpuWriteLog.removeAll(keepingCapacity: true)
            return "{\"ok\":true}"

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
            let underruns = emu.bus.apu.audioOutput.underrunEvents
            let overruns = emu.bus.apu.audioOutput.overrunEvents
            return "{\"buffered\":\(buffered),\"dspSamples\":\(dsp.diagSampleCount),\"nonZero\":\(dsp.diagNonZeroSamples),\"konCount\":\(dsp.diagKonCount),\"underruns\":\(underruns),\"overruns\":\(overruns)}"

        case "/bus/regs":
            return """
            {"nmitimen":"\(String(format: "0x%02X", emu.bus.nmitimen))","htime":"0x\(String(format: "%03X", emu.bus.htime))","vtime":"0x\(String(format: "%03X", emu.bus.vtime))","mdmaen":"\(String(format: "0x%02X", emu.bus.mdmaen))","hdmaen":"\(String(format: "0x%02X", emu.bus.hdmaen))","rdnmi":"\(String(format: "0x%02X", emu.bus.rdnmi))","timeup":"\(String(format: "0x%02X", emu.bus.timeup))","hvbjoy":"\(String(format: "0x%02X", emu.bus.hvbjoy))","nmiPending":\(emu.bus.nmiPending),"inVBlank":\(emu.bus.inVBlank)}
            """

        case "/joypad/state":
            if let maskParam = params["mask"] {
                let mask = UInt16(parseHexInt(maskParam) & 0xFFFF)
                emu.bus.joypad.setSourceState(mask, for: .keyboard)
            }
            return String(
                format: "{\"joy1State\":\"0x%04X\",\"joy1Auto\":\"0x%04X\",\"joy2Auto\":\"0x%04X\"}",
                emu.bus.joypad.joy1State,
                emu.bus.joypad.joy1Auto,
                emu.bus.joypad.joy2Auto
            )

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
            {"endpoints":["/emu/run?frames=1","/emu/save-state?path=/tmp/game.state","/emu/load-state?path=/tmp/game.state","/cpu/regs","/cpu/wram?addr=0x1DFB&len=16","/cpu/wram/write?addr=0x1DFB&val=0x01","/cpu/write-log","/cpu/trace?ms=50","/spc/ram?addr=0x0000&len=16","/spc/ram/write?addr=0x01&val=0x01","/spc/ports","/spc/ports/write?port=2&val=0x01","/spc/regs","/spc/timers","/spc/trace?count=500","/spc/inject?p0=0x01&p2=0x01","/dsp/regs","/dsp/regs/write?reg=0x4C&val=0x01","/dsp/kon?voice=0&srcn=0&pitch=0x1000","/dsp/voices","/ppu/vram?addr=0x0000&len=16","/ppu/oam?index=116&count=6","/ppu/sprites?scanline=65","/ppu/sprite-sample?x=127&y=65","/ppu/frame-dump-layer?mask=0x01&path=/tmp/bg1.png","/superfx/regs","/superfx/ram?addr=0x0000&len=32","/dma/state","/audio/stats","/wram/range?addr=0x1DF9&len=8","/wram/watch?addr=0x1DFB","/wram/watch/log"]}
            """
        }
    }

    private struct SpriteDetails {
        var index: Int
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var tile: Int
        var attr: UInt8
        var xBit9: Bool
        var isLarge: Bool
    }

    private func spriteDescription(ppu: PPU, index: Int, details override: SpriteDetails? = nil) -> String {
        let details = override ?? spriteDetails(ppu: ppu, index: index)
        let priority = (details.attr >> 4) & 0x03
        let palette = (details.attr >> 1) & 0x07
        let baseAddr = index * 4
        let rawX = ppu.oam[baseAddr]
        let rawY = ppu.oam[baseAddr + 1]
        return String(format:
            "{\"index\":%d,\"rawX\":\"0x%02X\",\"rawY\":\"0x%02X\",\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d,\"tile\":\"0x%02X\",\"attr\":\"0x%02X\",\"priority\":%d,\"palette\":%d,\"hFlip\":%d,\"vFlip\":%d,\"table\":%d,\"xBit9\":%d,\"large\":%d}",
            details.index,
            rawX,
            rawY,
            details.x,
            details.y,
            details.width,
            details.height,
            details.tile,
            details.attr,
            priority,
            palette,
            (details.attr & 0x40) != 0 ? 1 : 0,
            (details.attr & 0x80) != 0 ? 1 : 0,
            details.attr & 0x01,
            details.xBit9 ? 1 : 0,
            details.isLarge ? 1 : 0
        )
    }

    private func spriteDetails(ppu: PPU, index: Int) -> SpriteDetails {
        let sizeSelect = Int((ppu.objsel >> 5) & 0x07)
        let smallWidths = [8, 8, 8, 16, 16, 32, 16, 16]
        let smallHeights = [8, 8, 8, 16, 16, 32, 32, 32]
        let largeWidths = [16, 32, 64, 32, 64, 64, 32, 32]
        let largeHeights = [16, 32, 64, 32, 64, 64, 64, 32]

        let baseAddr = index * 4
        let rawX = Int(ppu.oam[baseAddr])
        let rawY = Int(ppu.oam[baseAddr + 1])
        let tile = Int(ppu.oam[baseAddr + 2])
        let attr = ppu.oam[baseAddr + 3]
        let highIdx = 512 + (index >> 2)
        let highShift = (index & 3) * 2
        let highBits = (ppu.oam[highIdx] >> highShift) & 0x03
        let xBit9 = (highBits & 0x01) != 0
        let isLarge = (highBits & 0x02) != 0
        let width = isLarge ? largeWidths[sizeSelect] : smallWidths[sizeSelect]
        let height = isLarge ? largeHeights[sizeSelect] : smallHeights[sizeSelect]
        let x = xBit9 ? (rawX - 256) : rawX
        let y = (rawY + 1) & 0xFF

        return SpriteDetails(index: index, x: x, y: y, width: width, height: height, tile: tile, attr: attr, xBit9: xBit9, isLarge: isLarge)
    }

    private func sprites(on scanline: Int, ppu: PPU) -> [SpriteDetails] {
        var hits = [SpriteDetails]()
        for index in 0..<128 {
            let details = spriteDetails(ppu: ppu, index: index)
            if details.y < 224 {
                if scanline >= details.y && scanline < min(details.y + details.height, 224) {
                    hits.append(details)
                }
            } else if scanline < details.y + details.height - 256 {
                hits.append(details)
            }
        }
        return hits
    }

    private func spriteSamples(atX x: Int, y: Int, ppu: PPU) -> [String] {
        let nameBase = Int(ppu.objsel & 0x07) << 14
        let nameGap = ((Int(ppu.objsel >> 3) & 0x03) + 1) << 13
        var results = [String]()

        for details in sprites(on: y, ppu: ppu) {
            guard x >= details.x && x < details.x + details.width else { continue }

            let hFlip = (details.attr & 0x40) != 0
            let vFlip = (details.attr & 0x80) != 0
            let relX = x - details.x
            let relY = (y - details.y) & 0xFF
            let tilesWide = details.width / 8

            var adjustedY = relY
            if vFlip {
                if details.width == details.height {
                    adjustedY = details.height - 1 - adjustedY
                } else if adjustedY < details.width {
                    adjustedY = details.width - 1 - adjustedY
                } else {
                    adjustedY = details.width + (details.width - 1) - (adjustedY - details.width)
                }
            }

            let tileRow = adjustedY / 8
            let tileCol = relX / 8
            let mirrorCol = hFlip ? (tilesWide - 1 - tileCol) : tileCol
            let actualTile = details.tile + tileRow * 16 + mirrorCol
            let fineY = adjustedY & 7
            let fineX = hFlip ? (7 - (relX & 7)) : (relX & 7)
            let chrBase = (details.attr & 0x01) != 0 ? (nameBase + nameGap) : nameBase
            let chrAddr = chrBase + (actualTile & 0xFF) * 32 + fineY * 2
            let bp0 = ppu.vram[chrAddr & 0xFFFF]
            let bp1 = ppu.vram[(chrAddr + 1) & 0xFFFF]
            let bp2 = ppu.vram[(chrAddr + 16) & 0xFFFF]
            let bp3 = ppu.vram[(chrAddr + 17) & 0xFFFF]
            let pixel = spritePixel(bp0: bp0, bp1: bp1, bp2: bp2, bp3: bp3, fineX: fineX)

            results.append(String(format:
                "{\"index\":%d,\"priority\":%d,\"palette\":%d,\"table\":%d,\"relX\":%d,\"relY\":%d,\"tileRow\":%d,\"tileCol\":%d,\"actualTile\":\"0x%02X\",\"fineX\":%d,\"fineY\":%d,\"chrAddr\":\"0x%04X\",\"pixel\":%d}",
                details.index,
                (details.attr >> 4) & 0x03,
                (details.attr >> 1) & 0x07,
                details.attr & 0x01,
                relX,
                relY,
                tileRow,
                tileCol,
                actualTile & 0xFF,
                fineX,
                fineY,
                chrAddr & 0xFFFF,
                pixel
            ))
        }

        return results
    }

    private func spritePixel(bp0: UInt8, bp1: UInt8, bp2: UInt8, bp3: UInt8, fineX: Int) -> UInt8 {
        let bit = 7 - fineX
        return ((bp0 >> bit) & 1)
            | (((bp1 >> bit) & 1) << 1)
            | (((bp2 >> bit) & 1) << 2)
            | (((bp3 >> bit) & 1) << 3)
    }

    private func frameSummary(ppu: PPU, presented: Bool) -> String {
        var nonBlackPixels = 0
        var minX = SNESConstants.screenWidth
        var minY = SNESConstants.screenHeight
        var maxX = -1
        var maxY = -1
        var uniqueColors = Set<UInt32>()
        var samples = [String]()

        for y in 0..<SNESConstants.screenHeight {
            for x in 0..<SNESConstants.screenWidth {
                let pixel = ppu.readPixel(x: x, y: y, presented: presented)
                let color = UInt32(pixel.r) | (UInt32(pixel.g) << 8) | (UInt32(pixel.b) << 16)
                uniqueColors.insert(color)
                guard color != 0 else { continue }

                nonBlackPixels += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                if samples.count < 8 {
                    samples.append(
                        String(
                            format: "{\"x\":%d,\"y\":%d,\"color\":\"%06X\"}",
                            x,
                            y,
                            color
                        )
                    )
                }
            }
        }

        let totalPixels = SNESConstants.screenWidth * SNESConstants.screenHeight
        let coverage = Double(nonBlackPixels) / Double(totalPixels)
        let bbox: String
        if maxX >= 0, maxY >= 0 {
            bbox = String(
                format: "{\"minX\":%d,\"minY\":%d,\"maxX\":%d,\"maxY\":%d,\"width\":%d,\"height\":%d}",
                minX,
                minY,
                maxX,
                maxY,
                maxX - minX + 1,
                maxY - minY + 1
            )
        } else {
            bbox = "null"
        }

        return String(
            format: "{\"presented\":%@,\"nonBlackPixels\":%d,\"totalPixels\":%d,\"coverage\":%.6f,\"uniqueColors\":%d,\"bbox\":%@,\"samples\":[%@]}",
            presented ? "true" : "false",
            nonBlackPixels,
            totalPixels,
            coverage,
            uniqueColors.count,
            bbox,
            samples.joined(separator: ",")
        )
    }

    private func dumpFrame(ppu: PPU, presented: Bool, path: String) -> String {
        var pixels = [UInt32](repeating: 0, count: SNESConstants.screenWidth * SNESConstants.screenHeight)
        for y in 0..<SNESConstants.screenHeight {
            for x in 0..<SNESConstants.screenWidth {
                let pixel = ppu.readPixel(x: x, y: y, presented: presented)
                pixels[y * SNESConstants.screenWidth + x] =
                    UInt32(pixel.r) |
                    (UInt32(pixel.g) << 8) |
                    (UInt32(pixel.b) << 16) |
                    0xFF00_0000
            }
        }
        return dumpFrame(pixels: pixels, path: path)
    }

    private func dumpFrame(pixels: [UInt32], path: String) -> String {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: SNESConstants.screenWidth,
            pixelsHigh: SNESConstants.screenHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: SNESConstants.screenWidth * 4,
            bitsPerPixel: 32
        ) else {
            return "{\"error\":\"failed to allocate bitmap\"}"
        }

        for y in 0..<SNESConstants.screenHeight {
            for x in 0..<SNESConstants.screenWidth {
                let color = pixels[y * SNESConstants.screenWidth + x]
                rep.setColor(
                    NSColor(
                        calibratedRed: CGFloat(color & 0xFF) / 255.0,
                        green: CGFloat((color >> 8) & 0xFF) / 255.0,
                        blue: CGFloat((color >> 16) & 0xFF) / 255.0,
                        alpha: 1.0
                    ),
                    atX: x,
                    y: SNESConstants.screenHeight - 1 - y
                )
            }
        }

        guard let png = rep.representation(using: .png, properties: [:]) else {
            return "{\"error\":\"failed to encode png\"}"
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            return "{\"ok\":true,\"path\":\"\(path)\"}"
        } catch {
            return "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
        }
    }

    private func parseQuery(_ q: String) -> [String: String] {
        var result = [String: String]()
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let rawKey = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                let rawValue = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                let key = rawKey.removingPercentEncoding ?? rawKey
                let value = rawValue.removingPercentEncoding ?? rawValue
                result[key] = value
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

    private func jsonEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
