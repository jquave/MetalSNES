import AppKit
import Combine
import Foundation
import GameController

enum SNESButton: String, CaseIterable, Codable, Identifiable {
    case b
    case y
    case select
    case start
    case up
    case down
    case left
    case right
    case a
    case x
    case l
    case r

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .b: return "B"
        case .y: return "Y"
        case .select: return "Select"
        case .start: return "Start"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .a: return "A"
        case .x: return "X"
        case .l: return "L"
        case .r: return "R"
        }
    }

    var bitMask: UInt16 {
        switch self {
        case .b: return 0x8000
        case .y: return 0x4000
        case .select: return 0x2000
        case .start: return 0x1000
        case .up: return 0x0800
        case .down: return 0x0400
        case .left: return 0x0200
        case .right: return 0x0100
        case .a: return 0x0080
        case .x: return 0x0040
        case .l: return 0x0020
        case .r: return 0x0010
        }
    }
}

struct KeyboardBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var displayName: String
}

enum GamepadControl: String, CaseIterable, Codable, Hashable, Identifiable {
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case leftThumbstickUp
    case leftThumbstickDown
    case leftThumbstickLeft
    case leftThumbstickRight
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case menu
    case options

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .leftThumbstickUp: return "Left Stick Up"
        case .leftThumbstickDown: return "Left Stick Down"
        case .leftThumbstickLeft: return "Left Stick Left"
        case .leftThumbstickRight: return "Left Stick Right"
        case .buttonA: return "Button A"
        case .buttonB: return "Button B"
        case .buttonX: return "Button X"
        case .buttonY: return "Button Y"
        case .leftShoulder: return "Left Shoulder"
        case .rightShoulder: return "Right Shoulder"
        case .leftTrigger: return "Left Trigger"
        case .rightTrigger: return "Right Trigger"
        case .menu: return "Menu"
        case .options: return "Options"
        }
    }
}

struct GamepadBinding: Codable, Equatable, Hashable {
    var control: GamepadControl
}

struct InputConfiguration: Codable, Equatable {
    struct KeyboardMapping: Codable, Equatable, Hashable {
        var button: SNESButton
        var binding: KeyboardBinding
    }

    struct GamepadMapping: Codable, Equatable, Hashable {
        var button: SNESButton
        var binding: GamepadBinding
    }

    var keyboardMappings: [KeyboardMapping]
    var gamepadMappings: [GamepadMapping]

    static let defaults = InputConfiguration(
        keyboardMappings: [
            .init(button: .up, binding: .init(keyCode: 13, displayName: "W")),
            .init(button: .down, binding: .init(keyCode: 1, displayName: "S")),
            .init(button: .left, binding: .init(keyCode: 0, displayName: "A")),
            .init(button: .right, binding: .init(keyCode: 2, displayName: "D")),
            .init(button: .b, binding: .init(keyCode: 46, displayName: "M")),
            .init(button: .y, binding: .init(keyCode: 49, displayName: "Space")),
            .init(button: .start, binding: .init(keyCode: 36, displayName: "Return")),
            .init(button: .select, binding: .init(keyCode: 48, displayName: "Tab")),
            .init(button: .a, binding: .init(keyCode: 43, displayName: ",")),
            .init(button: .x, binding: .init(keyCode: 45, displayName: "N")),
            .init(button: .l, binding: .init(keyCode: 56, displayName: "Left Shift")),
            .init(button: .r, binding: .init(keyCode: 60, displayName: "Right Shift")),
        ],
        gamepadMappings: [
            .init(button: .up, binding: .init(control: .dpadUp)),
            .init(button: .down, binding: .init(control: .dpadDown)),
            .init(button: .left, binding: .init(control: .dpadLeft)),
            .init(button: .right, binding: .init(control: .dpadRight)),
            .init(button: .b, binding: .init(control: .buttonA)),
            .init(button: .a, binding: .init(control: .buttonB)),
            .init(button: .y, binding: .init(control: .buttonX)),
            .init(button: .x, binding: .init(control: .buttonY)),
            .init(button: .l, binding: .init(control: .leftShoulder)),
            .init(button: .r, binding: .init(control: .rightShoulder)),
            .init(button: .select, binding: .init(control: .options)),
            .init(button: .start, binding: .init(control: .menu)),
        ]
    )

    func keyboardBinding(for button: SNESButton) -> KeyboardBinding? {
        keyboardMappings.first(where: { $0.button == button })?.binding
    }

    func gamepadBinding(for button: SNESButton) -> GamepadBinding? {
        gamepadMappings.first(where: { $0.button == button })?.binding
    }

    func button(forKeyCode keyCode: UInt16) -> SNESButton? {
        keyboardMappings.first(where: { $0.binding.keyCode == keyCode })?.button
    }

    mutating func setKeyboardBinding(_ binding: KeyboardBinding?, for button: SNESButton) {
        keyboardMappings.removeAll { mapping in
            mapping.button == button || (binding != nil && mapping.binding.keyCode == binding?.keyCode)
        }
        if let binding {
            keyboardMappings.append(.init(button: button, binding: binding))
        }
        keyboardMappings.sort { lhs, rhs in
            Self.orderIndex(for: lhs.button) < Self.orderIndex(for: rhs.button)
        }
    }

    mutating func setGamepadBinding(_ binding: GamepadBinding?, for button: SNESButton) {
        gamepadMappings.removeAll { mapping in
            mapping.button == button || (binding != nil && mapping.binding.control == binding?.control)
        }
        if let binding {
            gamepadMappings.append(.init(button: button, binding: binding))
        }
        gamepadMappings.sort { lhs, rhs in
            Self.orderIndex(for: lhs.button) < Self.orderIndex(for: rhs.button)
        }
    }

    func keyboardMask(for pressedKeyCodes: Set<UInt16>) -> UInt16 {
        var mask: UInt16 = 0
        for keyCode in pressedKeyCodes {
            if let button = button(forKeyCode: keyCode) {
                mask |= button.bitMask
            }
        }
        return mask
    }

    func gamepadMask(for activeControls: Set<GamepadControl>) -> UInt16 {
        var mask: UInt16 = 0
        for mapping in gamepadMappings where activeControls.contains(mapping.binding.control) {
            mask |= mapping.button.bitMask
        }
        return mask
    }

    private static func orderIndex(for button: SNESButton) -> Int {
        SNESButton.allCases.firstIndex(of: button) ?? 0
    }
}

final class InputManager: ObservableObject {
    enum CaptureMode: Equatable {
        case keyboard
        case gamepad
    }

    struct CaptureRequest: Identifiable, Equatable {
        let id = UUID()
        let button: SNESButton
        let mode: CaptureMode

        var prompt: String {
            switch mode {
            case .keyboard:
                return "Press a keyboard key for \(button.displayName). Press Escape to cancel."
            case .gamepad:
                return "Press a controller input for \(button.displayName)."
            }
        }
    }

    struct ControllerInfo: Identifiable, Equatable {
        let id: ObjectIdentifier
        let name: String
        let profileName: String
        let isSupported: Bool
    }

    @Published private(set) var configuration: InputConfiguration
    @Published private(set) var connectedControllers: [ControllerInfo] = []
    @Published var captureRequest: CaptureRequest?

    weak var joypad: Joypad?

    private let storageKey = "MetalSNES.inputConfiguration"
    private let userDefaults: UserDefaults
    private var keyboardPressedKeyCodes: Set<UInt16> = []
    private var controllerStates: [ObjectIdentifier: Set<GamepadControl>] = [:]
    private var controllerHandlersInstalled: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.configuration = Self.loadConfiguration(from: userDefaults)
        installObservers()
        refreshControllers()
        configureConnectedControllers()
        syncConnectedControllerStates()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attach(joypad: Joypad?) {
        self.joypad = joypad
        syncInputStates()
    }

    func keyboardBindingLabel(for button: SNESButton) -> String {
        configuration.keyboardBinding(for: button)?.displayName ?? "Unbound"
    }

    func gamepadBindingLabel(for button: SNESButton) -> String {
        configuration.gamepadBinding(for: button)?.control.displayName ?? "Unbound"
    }

    func isCapturing(_ button: SNESButton, mode: CaptureMode) -> Bool {
        captureRequest?.button == button && captureRequest?.mode == mode
    }

    func beginKeyboardCapture(for button: SNESButton) {
        resetKeyboardState()
        captureRequest = .init(button: button, mode: .keyboard)
    }

    func beginGamepadCapture(for button: SNESButton) {
        captureRequest = .init(button: button, mode: .gamepad)
        discoverControllers()
    }

    func cancelCapture() {
        captureRequest = nil
    }

    func clearKeyboardBinding(for button: SNESButton) {
        configuration.setKeyboardBinding(nil, for: button)
        persistConfiguration()
        syncKeyboardState()
    }

    func clearGamepadBinding(for button: SNESButton) {
        configuration.setGamepadBinding(nil, for: button)
        persistConfiguration()
        syncGamepadState()
    }

    func restoreDefaults() {
        configuration = .defaults
        persistConfiguration()
        syncInputStates()
    }

    func discoverControllers() {
        GCController.startWirelessControllerDiscovery {}
    }

    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if captureRequest?.mode == .keyboard {
            if event.keyCode == 53 {
                cancelCapture()
            } else {
                configuration.setKeyboardBinding(Self.keyboardBinding(from: event), for: captureRequest!.button)
                persistConfiguration()
                captureRequest = nil
                syncKeyboardState()
            }
            return true
        }

        guard shouldConsumeKeyboardEvent(event), configuration.button(forKeyCode: event.keyCode) != nil else {
            return false
        }

        keyboardPressedKeyCodes.insert(event.keyCode)
        syncKeyboardState()
        return true
    }

    @discardableResult
    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard shouldConsumeKeyboardEvent(event), configuration.button(forKeyCode: event.keyCode) != nil else {
            return false
        }

        keyboardPressedKeyCodes.remove(event.keyCode)
        syncKeyboardState()
        return true
    }

    @discardableResult
    func handleFlagsChanged(_ event: NSEvent) -> Bool {
        if captureRequest?.mode == .keyboard {
            configuration.setKeyboardBinding(Self.keyboardBinding(from: event), for: captureRequest!.button)
            persistConfiguration()
            captureRequest = nil
            syncKeyboardState()
            return true
        }

        guard configuration.button(forKeyCode: event.keyCode) != nil else {
            return false
        }

        if Self.isModifierPressed(for: event.keyCode, flags: event.modifierFlags) {
            keyboardPressedKeyCodes.insert(event.keyCode)
        } else {
            keyboardPressedKeyCodes.remove(event.keyCode)
        }
        syncKeyboardState()
        return true
    }

    func resetKeyboardState() {
        keyboardPressedKeyCodes.removeAll()
        syncKeyboardState()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let controller = notification.object as? GCController {
                self.installHandlers(for: controller)
                self.updateControllerState(for: controller)
            }
            self.refreshControllers()
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name.GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let controller = notification.object as? GCController {
                self.controllerStates.removeValue(forKey: ObjectIdentifier(controller))
            }
            self.refreshControllers()
            self.syncGamepadState()
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.resetKeyboardState()
            self.controllerStates.removeAll()
            self.syncGamepadState()
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshControllers()
            self.configureConnectedControllers()
            self.syncConnectedControllerStates()
        })
    }

    private func refreshControllers() {
        connectedControllers = GCController.controllers()
            .map { controller in
                let isSupported = controller.extendedGamepad != nil || controller.microGamepad != nil
                return ControllerInfo(
                    id: ObjectIdentifier(controller),
                    name: controller.vendorName ?? "Controller",
                    profileName: controller.extendedGamepad != nil ? "Extended" : controller.microGamepad != nil ? "Micro" : "Unsupported",
                    isSupported: isSupported
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func configureConnectedControllers() {
        for controller in GCController.controllers() {
            installHandlers(for: controller)
        }
    }

    private func installHandlers(for controller: GCController) {
        let controllerID = ObjectIdentifier(controller)
        guard controllerHandlersInstalled.insert(controllerID).inserted else {
            return
        }

        controller.handlerQueue = .main
        if let gamepad = controller.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let self, let controller else { return }
                Task { @MainActor in
                    self.updateControllerState(for: controller)
                }
            }
        } else if let gamepad = controller.microGamepad {
            gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
                guard let self, let controller else { return }
                Task { @MainActor in
                    self.updateControllerState(for: controller)
                }
            }
        }
    }

    private func updateControllerState(for controller: GCController) {
        let controllerID = ObjectIdentifier(controller)
        let previous = controllerStates[controllerID] ?? []
        let next = activeControls(for: controller)
        controllerStates[controllerID] = next

        if captureRequest?.mode == .gamepad, let control = next.subtracting(previous).first {
            configuration.setGamepadBinding(.init(control: control), for: captureRequest!.button)
            persistConfiguration()
            captureRequest = nil
        }

        syncGamepadState()
    }

    private func syncConnectedControllerStates() {
        for controller in GCController.controllers() {
            controllerStates[ObjectIdentifier(controller)] = activeControls(for: controller)
        }
        syncGamepadState()
    }

    private func activeControls(for controller: GCController) -> Set<GamepadControl> {
        var active: Set<GamepadControl> = []

        if let gamepad = controller.extendedGamepad {
            if gamepad.dpad.up.isPressed { active.insert(.dpadUp) }
            if gamepad.dpad.down.isPressed { active.insert(.dpadDown) }
            if gamepad.dpad.left.isPressed { active.insert(.dpadLeft) }
            if gamepad.dpad.right.isPressed { active.insert(.dpadRight) }
            if gamepad.leftThumbstick.up.isPressed { active.insert(.leftThumbstickUp) }
            if gamepad.leftThumbstick.down.isPressed { active.insert(.leftThumbstickDown) }
            if gamepad.leftThumbstick.left.isPressed { active.insert(.leftThumbstickLeft) }
            if gamepad.leftThumbstick.right.isPressed { active.insert(.leftThumbstickRight) }
            if gamepad.buttonA.isPressed { active.insert(.buttonA) }
            if gamepad.buttonB.isPressed { active.insert(.buttonB) }
            if gamepad.buttonX.isPressed { active.insert(.buttonX) }
            if gamepad.buttonY.isPressed { active.insert(.buttonY) }
            if gamepad.leftShoulder.isPressed { active.insert(.leftShoulder) }
            if gamepad.rightShoulder.isPressed { active.insert(.rightShoulder) }
            if gamepad.leftTrigger.isPressed { active.insert(.leftTrigger) }
            if gamepad.rightTrigger.isPressed { active.insert(.rightTrigger) }
            if gamepad.buttonMenu.isPressed { active.insert(.menu) }
            if gamepad.buttonOptions?.isPressed == true { active.insert(.options) }
        } else if let gamepad = controller.microGamepad {
            if gamepad.dpad.up.isPressed { active.insert(.dpadUp) }
            if gamepad.dpad.down.isPressed { active.insert(.dpadDown) }
            if gamepad.dpad.left.isPressed { active.insert(.dpadLeft) }
            if gamepad.dpad.right.isPressed { active.insert(.dpadRight) }
            if gamepad.buttonA.isPressed { active.insert(.buttonA) }
            if gamepad.buttonX.isPressed { active.insert(.buttonX) }
            if gamepad.buttonMenu.isPressed { active.insert(.menu) }
        }

        return active
    }

    private func syncInputStates() {
        syncKeyboardState()
        syncGamepadState()
    }

    private func syncKeyboardState() {
        joypad?.setSourceState(configuration.keyboardMask(for: keyboardPressedKeyCodes), for: .keyboard)
    }

    private func syncGamepadState() {
        let activeControls = controllerStates.values.reduce(into: Set<GamepadControl>()) { result, controls in
            result.formUnion(controls)
        }
        joypad?.setSourceState(configuration.gamepadMask(for: activeControls), for: .gamepad)
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        userDefaults.set(data, forKey: storageKey)
    }

    private func shouldConsumeKeyboardEvent(_ event: NSEvent) -> Bool {
        if Self.isModifierKey(event.keyCode) {
            return true
        }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        return event.modifierFlags.intersection(blockedModifiers).isEmpty
    }

    private static func loadConfiguration(from userDefaults: UserDefaults) -> InputConfiguration {
        guard
            let data = userDefaults.data(forKey: "MetalSNES.inputConfiguration"),
            let configuration = try? JSONDecoder().decode(InputConfiguration.self, from: data)
        else {
            return .defaults
        }
        return configuration
    }

    private static func keyboardBinding(from event: NSEvent) -> KeyboardBinding {
        KeyboardBinding(keyCode: event.keyCode, displayName: displayName(for: event))
    }

    private static func displayName(for event: NSEvent) -> String {
        if let name = specialKeyNames[event.keyCode] {
            return name
        }
        if let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines), !characters.isEmpty {
            return characters.count == 1 ? characters.uppercased() : characters.capitalized
        }
        return "Key \(event.keyCode)"
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    private static func isModifierPressed(for keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55:
            return flags.contains(.command)
        case 56, 60:
            return flags.contains(.shift)
        case 58, 61:
            return flags.contains(.option)
        case 59, 62:
            return flags.contains(.control)
        case 57:
            return flags.contains(.capsLock)
        case 63:
            return flags.contains(.function)
        default:
            return false
        }
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        54: "Right Command",
        55: "Left Command",
        56: "Left Shift",
        57: "Caps Lock",
        58: "Left Option",
        59: "Left Control",
        60: "Right Shift",
        61: "Right Option",
        62: "Right Control",
        63: "Function",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        109: "F10",
        111: "F12",
        118: "F4",
        120: "F2",
        122: "F1",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
    ]
}
