import Foundation
import AppKit
import os

final class Joypad {
    // SNES joypad bits:
    // High byte: B Y Select Start Up Down Left Right
    // Low byte:  A X L R 0 0 0 0
    private let _joy1State = OSAllocatedUnfairLock(initialState: UInt16(0))
    var joy1State: UInt16 {
        get { _joy1State.withLock { $0 } }
        set { _joy1State.withLock { $0 = newValue } }
    }
    var joy2State: UInt16 = 0

    // Auto-read results
    var joy1Auto: UInt16 = 0
    var joy2Auto: UInt16 = 0

    // Manual read state
    private var strobeOn = false
    private var joy1Shift: UInt16 = 0
    private var joy1ReadCount = 0

    // Key mapping: keyCode → SNES button bit
    // SNES layout: B Y Select Start Up Down Left Right | A X L R
    static let keyMap: [UInt16: UInt16] = [
        13:  0x0800,  // W → Up
        1:   0x0400,  // S → Down
        0:   0x0200,  // A → Left
        2:   0x0100,  // D → Right
        46:  0x8000,  // M → B
        49:  0x4000,  // Space → Y
        36:  0x1000,  // Return → Start
        48:  0x2000,  // Tab → Select
        43:  0x0080,  // , → A
        45:  0x0040,  // N → X
        56:  0x0020,  // LShift → L
        60:  0x0010,  // RShift → R
    ]

    func keyDown(_ keyCode: UInt16) {
        if let bit = Self.keyMap[keyCode] {
            _joy1State.withLock { $0 |= bit }
        }
    }

    func keyUp(_ keyCode: UInt16) {
        if let bit = Self.keyMap[keyCode] {
            _joy1State.withLock { $0 &= ~bit }
        }
    }

    func writeStrobe(_ value: UInt8) {
        let newStrobe = (value & 0x01) != 0
        if strobeOn && !newStrobe {
            // Latch controller state
            joy1Shift = _joy1State.withLock { $0 }
            joy1ReadCount = 0
        }
        strobeOn = newStrobe
    }

    func readJoy1() -> UInt8 {
        if strobeOn {
            return UInt8(_joy1State.withLock { $0 } >> 15) & 0x01
        }
        let bit = (joy1Shift >> 15) & 0x01
        joy1Shift <<= 1
        joy1ReadCount += 1
        return UInt8(bit)
    }

    func readJoy2() -> UInt8 {
        return 0
    }

    func autoRead() {
        joy1Auto = _joy1State.withLock { $0 }
        joy2Auto = joy2State
    }
}
