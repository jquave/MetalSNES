import Foundation

struct SuperFXSnapshot {
    let regs: [UInt16]
    let sfr: UInt16
    let pbr: UInt8
    let rombr: UInt8
    let rambr: UInt8
    let cbr: UInt16
    let scbr: UInt8
    let scmr: UInt8
    let colr: UInt8
    let por: UInt8
    let vcr: UInt8
    let cfgr: UInt8
    let clsr: UInt8
    let pipeline: UInt8
    let ramaddr: UInt16
    let romcl: UInt32
    let romdr: UInt8
    let ramcl: UInt32
    let ramar: UInt16
    let ramdr: UInt8
    let irqActive: Bool
}

struct SuperFXTraceEntry {
    let pbr: UInt8
    let rombr: UInt8
    let opcode: UInt8
    let r12: UInt16
    let r13: UInt16
    let r14: UInt16
    let r15: UInt16
    let sfr: UInt16
}

final class SuperFXChip {
    private let handle: UnsafeMutableRawPointer

    init?(cartridge: Cartridge, ram: UnsafeMutableBufferPointer<UInt8>) {
        var created: UnsafeMutableRawPointer?
        cartridge.romData.withUnsafeBufferPointer { rom in
            guard let romBase = rom.baseAddress, let ramBase = ram.baseAddress else { return }
            created = ms_superfx_create(romBase, rom.count, ramBase, ram.count)
        }
        guard let created else { return nil }
        self.handle = created
    }

    deinit {
        ms_superfx_destroy(handle)
    }

    @inline(__always)
    func run(masterCycles: Int) {
        guard masterCycles > 0 else { return }
        ms_superfx_run(handle, UInt32(masterCycles))
    }

    @inline(__always)
    func readIO(_ addr: UInt16, defaultData: UInt8) -> UInt8 {
        ms_superfx_read_io(handle, addr, defaultData)
    }

    @inline(__always)
    func writeIO(_ addr: UInt16, value: UInt8) {
        ms_superfx_write_io(handle, addr, value)
    }

    @inline(__always)
    func cpuReadROM(_ addr: UInt32, defaultData: UInt8) -> UInt8 {
        ms_superfx_cpu_read_rom(handle, addr, defaultData)
    }

    @inline(__always)
    func cpuReadRAM(_ addr: UInt32, defaultData: UInt8) -> UInt8 {
        ms_superfx_cpu_read_ram(handle, addr, defaultData)
    }

    @inline(__always)
    func cpuWriteRAM(_ addr: UInt32, value: UInt8) {
        ms_superfx_cpu_write_ram(handle, addr, value)
    }

    var irqActive: Bool {
        ms_superfx_irq_active(handle)
    }

    func saveState() -> [UInt8] {
        let size = Int(ms_superfx_state_size())
        guard size > 0 else { return [] }
        var state = [UInt8](repeating: 0, count: size)
        let ok = state.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return ms_superfx_save_state(handle, base, UInt32(buffer.count))
        }
        return ok ? state : []
    }

    func restoreState(_ state: [UInt8]) -> Bool {
        state.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return ms_superfx_load_state(handle, base, UInt32(buffer.count))
        }
    }

    func debugSnapshot() -> SuperFXSnapshot {
        let regs = (0..<16).map { ms_superfx_get_reg(handle, UInt32($0)) }
        return SuperFXSnapshot(
            regs: regs,
            sfr: ms_superfx_get_sfr(handle),
            pbr: ms_superfx_get_pbr(handle),
            rombr: ms_superfx_get_rombr(handle),
            rambr: ms_superfx_get_rambr(handle),
            cbr: ms_superfx_get_cbr(handle),
            scbr: ms_superfx_get_scbr(handle),
            scmr: ms_superfx_get_scmr(handle),
            colr: ms_superfx_get_colr(handle),
            por: ms_superfx_get_por(handle),
            vcr: ms_superfx_get_vcr(handle),
            cfgr: ms_superfx_get_cfgr(handle),
            clsr: ms_superfx_get_clsr(handle),
            pipeline: ms_superfx_get_pipeline(handle),
            ramaddr: ms_superfx_get_ramaddr(handle),
            romcl: ms_superfx_get_romcl(handle),
            romdr: ms_superfx_get_romdr(handle),
            ramcl: ms_superfx_get_ramcl(handle),
            ramar: ms_superfx_get_ramar(handle),
            ramdr: ms_superfx_get_ramdr(handle),
            irqActive: ms_superfx_irq_active(handle)
        )
    }

    func recentTrace(limit: Int) -> [SuperFXTraceEntry] {
        let total = Int(ms_superfx_get_trace_count(handle))
        guard total > 0 else { return [] }
        let count = min(max(limit, 0), total)
        let start = total - count
        return (start..<total).map { index in
            let idx = UInt32(index)
            return SuperFXTraceEntry(
                pbr: ms_superfx_get_trace_pbr(handle, idx),
                rombr: ms_superfx_get_trace_rombr(handle, idx),
                opcode: ms_superfx_get_trace_opcode(handle, idx),
                r12: ms_superfx_get_trace_r12(handle, idx),
                r13: ms_superfx_get_trace_r13(handle, idx),
                r14: ms_superfx_get_trace_r14(handle, idx),
                r15: ms_superfx_get_trace_r15(handle, idx),
                sfr: ms_superfx_get_trace_sfr(handle, idx)
            )
        }
    }
}
