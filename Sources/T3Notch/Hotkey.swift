import Carbon.HIToolbox

/// A system-wide hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
final class Hotkey {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Default: ⌥Space.
    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), id: UInt32 = 1, action: @escaping () -> Void) {
        self.id = id
        Self.installHandlerOnce()
        Self.handlers[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x54334E54) /* 'T3NT' */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
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
