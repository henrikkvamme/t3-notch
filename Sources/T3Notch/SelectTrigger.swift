import AppKit
import Carbon.HIToolbox

/// Calls `onTap` for a clean tap of ⌃⌥ anywhere: both keys down, then both up within
/// 400 ms, with no other key, modifier, click or scroll in between. Holding ⌃⌥ for an app's
/// own shortcut never fires it. Off while VoiceOver runs (⌃⌥ is its VO key) and while a
/// password field has secure input.
///
/// Global monitors see other apps' events only with Accessibility, which clip mode needs too.
@MainActor
final class SelectTrigger {
    /// Longest press that still counts as a tap.
    static let maxTap: TimeInterval = 0.4
    /// The keys of the tap, as the welcome tour draws them. Change them with `flagsChanged`.
    static let keycaps = [KeyCap(symbol: "⌃", name: "control"), KeyCap(symbol: "⌥", name: "option")]

    private let onTap: () -> Void
    private var monitors: [Any] = []
    private var detector = TapDetector(maxTap: SelectTrigger.maxTap)

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        let flags: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.flagsChanged(e) }
        }
        let other: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.detector.interrupt() }
        }
        let spoilers: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any,
            NSEvent.addGlobalMonitorForEvents(matching: spoilers, handler: other) as Any,
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in flags(e); return e } as Any,
            NSEvent.addLocalMonitorForEvents(matching: spoilers) { e in other(e); return e } as Any,
        ]
    }

    private func flagsChanged(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.control, .option, .command, .shift, .function])
        guard detector.update(control: mods.contains(.control), option: mods.contains(.option),
                              other: !mods.subtracting([.control, .option]).isEmpty, at: e.timestamp)
        else { return }
        guard Self.enabled else { return }
        onTap()
    }

    /// Off by setting, under VoiceOver, and while secure input is on.
    static var enabled: Bool {
        Settings.controlOptionSelect && !NSWorkspace.shared.isVoiceOverEnabled && !IsSecureEventInputEnabled()
    }
}

/// The tap state machine, kept free of AppKit so it can be tested on its own.
struct TapDetector {
    let maxTap: TimeInterval
    private var downAt: TimeInterval?
    /// Something else happened since the keys went down: no tap until all are up.
    private var spoiled = false

    init(maxTap: TimeInterval) { self.maxTap = maxTap }

    /// Feeds one modifier change. Returns true when it completes a tap.
    mutating func update(control: Bool, option: Bool, other: Bool, at time: TimeInterval) -> Bool {
        if other { spoiled = true }
        if control && option && !other {
            if downAt == nil { downAt = time }
            return false
        }
        if !control && !option && !other {
            defer { downAt = nil; spoiled = false }
            guard let start = downAt, !spoiled else { return false }
            return time - start <= maxTap
        }
        // One of the two released while the other is held: keep waiting for both up, but a
        // key pressed again later must not restart the clock.
        return false
    }

    /// A key, click or scroll while the modifiers are down cancels the tap.
    mutating func interrupt() {
        if downAt != nil { spoiled = true }
    }
}
