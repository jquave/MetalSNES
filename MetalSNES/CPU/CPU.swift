import Foundation

final class CPU {
    struct TraceEntry {
        let pc: UInt32
        let opcode: UInt8
        let a: UInt16
        let x: UInt16
        let y: UInt16
        let s: UInt16
        let d: UInt16
        let p: UInt8
        let emulationMode: Bool
    }

    var regs = CPURegisters()
    private unowned let bus: Bus
    private var ctx: UnsafeMutableRawPointer!
    private var currentInstructionPC: UInt32 = 0
    private var currentOpcode: UInt8 = 0

    // Pre-allocated callbacks (avoid closure allocation per step)
    private let readCb: BusReadFunc = { (ctx, address) -> UInt8 in
        Unmanaged<CPU>.fromOpaque(ctx!).takeUnretainedValue().busRead(address)
    }
    private let writeCb: BusWriteFunc = { (ctx, address, value) in
        Unmanaged<CPU>.fromOpaque(ctx!).takeUnretainedValue().busWrite(address, value: value)
    }

    // Instruction log for debugging
    var traceEnabled = false
    var traceLog: [TraceEntry] = []
    private let maxTraceEntries = 500
    private(set) var recentTrace: [TraceEntry] = []
    private let maxRecentTraceEntries = 65536

    init(bus: Bus) {
        self.bus = bus
        cpu_dispatch_init()
        self.ctx = Unmanaged.passUnretained(self).toOpaque()
    }

    func reset() {
        cpu_reset(&regs, readCb, ctx)

        print(String(format: "CPU Reset: PC=$%04X, P=$%02X, S=$%04X, E=%d",
                      regs.PC, regs.P, regs.S, regs.emulationMode ? 1 : 0))
    }

    @inline(__always)
    @discardableResult
    func step() -> Int {
        currentInstructionPC = (UInt32(regs.PBR) << 16) | UInt32(regs.PC)
        currentOpcode = bus.read(currentInstructionPC)

        let entry = TraceEntry(
            pc: currentInstructionPC,
            opcode: currentOpcode,
            a: regs.A,
            x: regs.X,
            y: regs.Y,
            s: regs.S,
            d: regs.D,
            p: regs.P,
            emulationMode: regs.emulationMode
        )

        recentTrace.append(entry)
        if recentTrace.count > maxRecentTraceEntries {
            recentTrace.removeFirst(maxRecentTraceEntries / 4)
        }

        if traceEnabled && traceLog.count < maxTraceEntries {
            traceLog.append(entry)
        }

        // Check for NMI from bus
        if bus.nmiPending {
            regs.nmiPending = true
            bus.nmiPending = false
        }

        let cycles = Int(cpu_step(&regs, readCb, writeCb, ctx))
        currentInstructionPC = 0
        currentOpcode = 0
        return cycles
    }

    func printTrace() {
        for entry in traceLog {
            print(String(format: "%02X:%04X  op=%02X  A=%04X X=%04X Y=%04X S=%04X D=%04X P=%02X E=%d",
                         (entry.pc >> 16) & 0xFF, entry.pc & 0xFFFF,
                         entry.opcode,
                         entry.a, entry.x, entry.y, entry.s, entry.d, entry.p,
                         entry.emulationMode ? 1 : 0))
        }
    }

    @inline(__always)
    private func busRead(_ address: UInt32) -> UInt8 {
        bus.read(address)
    }

    @inline(__always)
    private func busWrite(_ address: UInt32, value: UInt8) {
        bus.recordCPUWrite(callerPC: currentInstructionPC, opcode: currentOpcode, targetAddress: address, value: value)
        bus.write(address, value: value)
    }
}
