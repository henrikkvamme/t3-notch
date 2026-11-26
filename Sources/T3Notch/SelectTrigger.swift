import AppKit
import Carbon.HIToolbox

/// Reports while ⌃⌥ is held in any app. `onHold(true)` comes once both keys have been down
/// for `delay` with no other key, modifier, click or scroll, so a ⌃⌥ chord for an app's own
/// shortcut never shows select mode. `onHold(false)` comes when a key goes up or something
/// else is pressed. Off while VoiceOver runs (⌃⌥ is its VO key) and while a password field
/// has secure input.
///
/// Global monitors see other apps' events only with Accessibility, which select mode needs too.
@MainActor
final class SelectTrigger {
    /// How long both keys must stay down before select mode shows.
    static let delay: TimeInterval = 0.15

    private let onHold: (Bool) -> Void
    private var monitors: [Any] = []
    private var detector = HoldDetector()
    /// What `onHold` was last told.
    private var reported = false
    /// Bumped by every change, so a pending start that a newer change replaced is dropped.
    private var generation = 0

    init(onHold: @escaping (Bool) -> Void) {
        self.onHold = onHold
        let flags: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.flagsChanged(e.modifierFlags) }
        }
        let other: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Once select mode shows, the left button and the scroll are its own.
                if self.reported, [.leftMouseDown, .scrollWheel].contains(e.type) { return }
                guard self.detector.interrupt() else { return }
                self.changed()
            }
        }
        let spoilers: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any,
            NSEvent.addGlobalMonitorForEvents(matching: spoilers, handler: other) as Any,
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in flags(e); return e } as Any,
            NSEvent.addLocalMonitorForEvents(matching: spoilers) { e in other(e); return e } as Any,
        ]
    }

    /// Select mode ended by itself (sent, or Esc) while the keys may still be down. If they
    /// are, the hold goes on: select mode shows again at once.
    func resume() {
        detector = HoldDetector()
        generation += 1
        reported = false
        flagsChanged(NSEvent.modifierFlags, delay: 0)
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags, delay: TimeInterval = SelectTrigger.delay) {
        let mods = flags.intersection([.control, .option, .command, .shift, .function])
        guard detector.update(control: mods.contains(.control), option: mods.contains(.option),
                              other: !mods.subtracting([.control, .option]).isEmpty) else { return }
        changed(delay: delay)
    }

    /// `detector.held` changed: start after the delay, or stop now.
    private func changed(delay: TimeInterval = SelectTrigger.delay) {
        generation += 1
        guard detector.held else { report(false); return }
        guard delay > 0 else { report(Self.enabled); return }
        let started = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == started, self.detector.held, Self.enabled else { return }
            self.report(true)
        }
    }

    private func report(_ held: Bool) {
        guard held != reported else { return }
        reported = held
        onHold(held)
    }

    /// Off by setting, under VoiceOver, and while secure input is on.
    static var enabled: Bool {
        Settings.controlOptionSelect && !NSWorkspace.shared.isVoiceOverEnabled && !IsSecureEventInputEnabled()
    }
}

/// The hold state machine, kept free of AppKit so it can be tested on its own.
struct HoldDetector {
    /// ⌃ and ⌥ are both down, with nothing else pressed since they went down.
    private(set) var held = false
    /// Something else happened while the keys were down: no hold until all are up.
    private var spoiled = false

    /// Feeds the modifiers that are down now. Returns true when `held` changed.
    mutating func update(control: Bool, option: Bool, other: Bool) -> Bool {
        if other { spoiled = true }
        if !control && !option && !other { spoiled = false }
        let now = control && option && !other && !spoiled
        defer { held = now }
        return now != held
    }

    /// A key, click or scroll while the keys are down ends the hold. Returns true when it did.
    mutating func interrupt() -> Bool {
        guard held else { return false }
        spoiled = true
        held = false
        return true
    }
}
