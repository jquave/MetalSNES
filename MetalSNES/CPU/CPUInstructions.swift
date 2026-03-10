import Foundation

// 65C816 opcode disassembly table for debug views
enum CPUInstructions {
    struct OpcodeInfo {
        let mnemonic: String
        let bytes: Int // 0 means variable (depends on M/X flags)
        let addressingMode: String
    }

    static let opcodeTable: [UInt8: OpcodeInfo] = [
        0x00: OpcodeInfo(mnemonic: "BRK", bytes: 2, addressingMode: "imm"),
        0x01: OpcodeInfo(mnemonic: "ORA", bytes: 2, addressingMode: "(dp,X)"),
        0x02: OpcodeInfo(mnemonic: "COP", bytes: 2, addressingMode: "imm"),
        0x03: OpcodeInfo(mnemonic: "ORA", bytes: 2, addressingMode: "sr,S"),
        0x04: OpcodeInfo(mnemonic: "TSB", bytes: 2, addressingMode: "dp"),
        0x05: OpcodeInfo(mnemonic: "ORA", bytes: 2, addressingMode: "dp"),
        0x06: OpcodeInfo(mnemonic: "ASL", bytes: 2, addressingMode: "dp"),
        0x07: OpcodeInfo(mnemonic: "ORA", bytes: 2, addressingMode: "[dp]"),
        0x08: OpcodeInfo(mnemonic: "PHP", bytes: 1, addressingMode: "imp"),
        0x09: OpcodeInfo(mnemonic: "ORA", bytes: 0, addressingMode: "#immM"),
        0x0A: OpcodeInfo(mnemonic: "ASL", bytes: 1, addressingMode: "A"),
        0x0B: OpcodeInfo(mnemonic: "PHD", bytes: 1, addressingMode: "imp"),
        0x0C: OpcodeInfo(mnemonic: "TSB", bytes: 3, addressingMode: "abs"),
        0x0D: OpcodeInfo(mnemonic: "ORA", bytes: 3, addressingMode: "abs"),
        0x0E: OpcodeInfo(mnemonic: "ASL", bytes: 3, addressingMode: "abs"),
        0x0F: OpcodeInfo(mnemonic: "ORA", bytes: 4, addressingMode: "long"),

        0x10: OpcodeInfo(mnemonic: "BPL", bytes: 2, addressingMode: "rel"),
        0x18: OpcodeInfo(mnemonic: "CLC", bytes: 1, addressingMode: "imp"),
        0x1A: OpcodeInfo(mnemonic: "INC", bytes: 1, addressingMode: "A"),
        0x1B: OpcodeInfo(mnemonic: "TCS", bytes: 1, addressingMode: "imp"),
        0x20: OpcodeInfo(mnemonic: "JSR", bytes: 3, addressingMode: "abs"),
        0x22: OpcodeInfo(mnemonic: "JSL", bytes: 4, addressingMode: "long"),
        0x28: OpcodeInfo(mnemonic: "PLP", bytes: 1, addressingMode: "imp"),
        0x29: OpcodeInfo(mnemonic: "AND", bytes: 0, addressingMode: "#immM"),
        0x2A: OpcodeInfo(mnemonic: "ROL", bytes: 1, addressingMode: "A"),
        0x2B: OpcodeInfo(mnemonic: "PLD", bytes: 1, addressingMode: "imp"),
        0x30: OpcodeInfo(mnemonic: "BMI", bytes: 2, addressingMode: "rel"),
        0x38: OpcodeInfo(mnemonic: "SEC", bytes: 1, addressingMode: "imp"),
        0x3A: OpcodeInfo(mnemonic: "DEC", bytes: 1, addressingMode: "A"),
        0x3B: OpcodeInfo(mnemonic: "TSC", bytes: 1, addressingMode: "imp"),
        0x40: OpcodeInfo(mnemonic: "RTI", bytes: 1, addressingMode: "imp"),
        0x48: OpcodeInfo(mnemonic: "PHA", bytes: 1, addressingMode: "imp"),
        0x4A: OpcodeInfo(mnemonic: "LSR", bytes: 1, addressingMode: "A"),
        0x4B: OpcodeInfo(mnemonic: "PHK", bytes: 1, addressingMode: "imp"),
        0x4C: OpcodeInfo(mnemonic: "JMP", bytes: 3, addressingMode: "abs"),
        0x50: OpcodeInfo(mnemonic: "BVC", bytes: 2, addressingMode: "rel"),
        0x58: OpcodeInfo(mnemonic: "CLI", bytes: 1, addressingMode: "imp"),
        0x5A: OpcodeInfo(mnemonic: "PHY", bytes: 1, addressingMode: "imp"),
        0x5B: OpcodeInfo(mnemonic: "TCD", bytes: 1, addressingMode: "imp"),
        0x5C: OpcodeInfo(mnemonic: "JMP", bytes: 4, addressingMode: "long"),
        0x60: OpcodeInfo(mnemonic: "RTS", bytes: 1, addressingMode: "imp"),
        0x68: OpcodeInfo(mnemonic: "PLA", bytes: 1, addressingMode: "imp"),
        0x6A: OpcodeInfo(mnemonic: "ROR", bytes: 1, addressingMode: "A"),
        0x6B: OpcodeInfo(mnemonic: "RTL", bytes: 1, addressingMode: "imp"),
        0x6C: OpcodeInfo(mnemonic: "JMP", bytes: 3, addressingMode: "(abs)"),
        0x70: OpcodeInfo(mnemonic: "BVS", bytes: 2, addressingMode: "rel"),
        0x78: OpcodeInfo(mnemonic: "SEI", bytes: 1, addressingMode: "imp"),
        0x7A: OpcodeInfo(mnemonic: "PLY", bytes: 1, addressingMode: "imp"),
        0x7B: OpcodeInfo(mnemonic: "TDC", bytes: 1, addressingMode: "imp"),
        0x80: OpcodeInfo(mnemonic: "BRA", bytes: 2, addressingMode: "rel"),
        0x88: OpcodeInfo(mnemonic: "DEY", bytes: 1, addressingMode: "imp"),
        0x8A: OpcodeInfo(mnemonic: "TXA", bytes: 1, addressingMode: "imp"),
        0x8B: OpcodeInfo(mnemonic: "PHB", bytes: 1, addressingMode: "imp"),
        0x90: OpcodeInfo(mnemonic: "BCC", bytes: 2, addressingMode: "rel"),
        0x98: OpcodeInfo(mnemonic: "TYA", bytes: 1, addressingMode: "imp"),
        0x9A: OpcodeInfo(mnemonic: "TXS", bytes: 1, addressingMode: "imp"),
        0x9B: OpcodeInfo(mnemonic: "TXY", bytes: 1, addressingMode: "imp"),
        0xA8: OpcodeInfo(mnemonic: "TAY", bytes: 1, addressingMode: "imp"),
        0xA9: OpcodeInfo(mnemonic: "LDA", bytes: 0, addressingMode: "#immM"),
        0xA2: OpcodeInfo(mnemonic: "LDX", bytes: 0, addressingMode: "#immX"),
        0xA0: OpcodeInfo(mnemonic: "LDY", bytes: 0, addressingMode: "#immX"),
        0xAA: OpcodeInfo(mnemonic: "TAX", bytes: 1, addressingMode: "imp"),
        0xAB: OpcodeInfo(mnemonic: "PLB", bytes: 1, addressingMode: "imp"),
        0xB0: OpcodeInfo(mnemonic: "BCS", bytes: 2, addressingMode: "rel"),
        0xB8: OpcodeInfo(mnemonic: "CLV", bytes: 1, addressingMode: "imp"),
        0xBA: OpcodeInfo(mnemonic: "TSX", bytes: 1, addressingMode: "imp"),
        0xBB: OpcodeInfo(mnemonic: "TYX", bytes: 1, addressingMode: "imp"),
        0xC2: OpcodeInfo(mnemonic: "REP", bytes: 2, addressingMode: "#imm"),
        0xC8: OpcodeInfo(mnemonic: "INY", bytes: 1, addressingMode: "imp"),
        0xCA: OpcodeInfo(mnemonic: "DEX", bytes: 1, addressingMode: "imp"),
        0xCB: OpcodeInfo(mnemonic: "WAI", bytes: 1, addressingMode: "imp"),
        0xD0: OpcodeInfo(mnemonic: "BNE", bytes: 2, addressingMode: "rel"),
        0xD8: OpcodeInfo(mnemonic: "CLD", bytes: 1, addressingMode: "imp"),
        0xDA: OpcodeInfo(mnemonic: "PHX", bytes: 1, addressingMode: "imp"),
        0xDB: OpcodeInfo(mnemonic: "STP", bytes: 1, addressingMode: "imp"),
        0xE2: OpcodeInfo(mnemonic: "SEP", bytes: 2, addressingMode: "#imm"),
        0xE8: OpcodeInfo(mnemonic: "INX", bytes: 1, addressingMode: "imp"),
        0xEA: OpcodeInfo(mnemonic: "NOP", bytes: 1, addressingMode: "imp"),
        0xF0: OpcodeInfo(mnemonic: "BEQ", bytes: 2, addressingMode: "rel"),
        0xF8: OpcodeInfo(mnemonic: "SED", bytes: 1, addressingMode: "imp"),
        0xFA: OpcodeInfo(mnemonic: "PLX", bytes: 1, addressingMode: "imp"),
        0xFB: OpcodeInfo(mnemonic: "XCE", bytes: 1, addressingMode: "imp"),
    ]

    static func disassemble(opcode: UInt8) -> String {
        if let info = opcodeTable[opcode] {
            return info.mnemonic
        }
        return String(format: "???(%02X)", opcode)
    }
}
