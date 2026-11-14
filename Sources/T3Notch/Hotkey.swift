import AppKit
import Carbon.HIToolbox

/// A key combination for a global shortcut, in Carbon terms, with a label for display.
struct KeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey.
    var modifiers: UInt32
    /// The key's name as it was pressed, such as "Space" or "K".
    var key: String

    static let showIsland = KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
    static let toggleDot = KeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), key: "Space")
    static let showChats = KeyBinding(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), key: "K")

    /// The island's own fixed shortcuts, which "Show chats" may not take.
    static let islandReserved: [KeyBinding] = [
        (kVK_Escape, 0), (kVK_Return, 0), (kVK_Return, cmdKey), (kVK_ANSI_P, cmdKey), (kVK_ANSI_O, cmdKey),
        (kVK_ANSI_Period, cmdKey), (kVK_ANSI_Comma, cmdKey), (kVK_ANSI_Z, cmdKey), (kVK_ANSI_Z, controlKey),
        (kVK_ANSI_J, controlKey), (kVK_ANSI_K, controlKey), (kVK_ANSI_N, controlKey), (kVK_ANSI_P, controlKey),
        (kVK_ANSI_X, cmdKey), (kVK_ANSI_C, cmdKey), (kVK_ANSI_V, cmdKey), (kVK_ANSI_A, cmdKey), (kVK_ANSI_W, cmdKey),
    ].map { KeyBinding(keyCode: UInt32($0.0), modifiers: UInt32($0.1), key: "") }

    /// Whether a key press is this combination (exact modifiers).
    func matches(_ event: NSEvent) -> Bool {
        guard let pressed = KeyBinding(event: event) else { return false }
        return pressed.keyCode == keyCode && pressed.modifiers == modifiers
    }

    func sameKeys(as other: KeyBinding) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    /// ⌃⌥⇧⌘ order, as macOS shows shortcuts.
    var label: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// The binding a key press makes, or nil when it needs a modifier and has none.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let name = Self.name(keyCode: event.keyCode, event: event)
        let isFunctionKey = (122...135).contains(Int(event.keyCode)) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120]
            .contains(Int(event.keyCode))
        guard mods != 0 || isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func name(keyCode: UInt16, event: NSEvent) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "⏎"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// A system-wide hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class Hotkey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private(set) var binding: KeyBinding

    init(_ binding: KeyBinding, id: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.binding = binding
        Self.installHandlerOnce()
        Self.handlers[id] = action
        _ = register(binding)
    }

    /// Switches to a new combination. Returns false, keeping the old one, when macOS or
    /// another app already owns it.
    func rebind(_ new: KeyBinding) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if register(new) {
            binding = new
            return true
        }
        _ = register(binding)
        return false
    }

    /// Unregisters while a new shortcut is being recorded, so pressing the current
    /// combination reaches the recorder instead of firing.
    func suspend() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func resume() {
        if ref == nil { _ = register(binding) }
    }

    private func register(_ b: KeyBinding) -> Bool {
        let hotKeyID = EventHotKeyID(signature: OSType(0x54334E54) /* 'T3NT' */, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(b.keyCode, b.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        return true
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { Hotkey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
