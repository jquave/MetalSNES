import Foundation
import os

enum JoypadInputSource {
    case keyboard
    case gamepad
}

final class Joypad {
    struct Snapshot {
        var joy1Auto: UInt16 = 0
        var joy2Auto: UInt16 = 0
        var strobeOn = false
        var joy1Shift: UInt16 = 0
        var joy1ReadCount = 0
    }

    // SNES joypad bits:
    // High byte: B Y Select Start Up Down Left Right
    // Low byte:  A X L R 0 0 0 0
    private struct InputSources {
        var keyboard: UInt16 = 0
        var gamepad: UInt16 = 0
    }

    private let _inputSources = OSAllocatedUnfairLock(initialState: InputSources())
    var joy1State: UInt16 {
        _inputSources.withLock { $0.keyboard | $0.gamepad }
    }
    var joy2State: UInt16 = 0

    // Auto-read results
    var joy1Auto: UInt16 = 0
    var joy2Auto: UInt16 = 0

    // Manual read state
    private var strobeOn = false
    private var joy1Shift: UInt16 = 0
    private var joy1ReadCount = 0

    func setSourceState(_ state: UInt16, for source: JoypadInputSource) {
        _inputSources.withLock {
            switch source {
            case .keyboard:
                $0.keyboard = state
            case .gamepad:
                $0.gamepad = state
            }
        }
    }

    func writeStrobe(_ value: UInt8) {
        let newStrobe = (value & 0x01) != 0
        if strobeOn && !newStrobe {
            // Latch controller state
            joy1Shift = joy1State
            joy1ReadCount = 0
        }
        strobeOn = newStrobe
    }

    func readJoy1() -> UInt8 {
        if strobeOn {
            return UInt8(joy1State >> 15) & 0x01
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
        joy1Auto = joy1State
        joy2Auto = joy2State
    }

    func captureSnapshot() -> Snapshot {
        Snapshot(
            joy1Auto: joy1Auto,
            joy2Auto: joy2Auto,
            strobeOn: strobeOn,
            joy1Shift: joy1Shift,
            joy1ReadCount: joy1ReadCount
        )
    }

    func restoreSnapshot(_ snapshot: Snapshot) {
        joy1Auto = snapshot.joy1Auto
        joy2Auto = snapshot.joy2Auto
        strobeOn = snapshot.strobeOn
        joy1Shift = snapshot.joy1Shift
        joy1ReadCount = snapshot.joy1ReadCount
    }
}
