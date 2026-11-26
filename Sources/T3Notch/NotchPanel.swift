import AppKit
import ApplicationServices
import SwiftUI
import os

/// Borderless, non-activating panel over the notch. It is a fixed transparent canvas: the
/// island inside is drawn and animated by SwiftUI, so it can grow out of the notch.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 1 // above the menu bar so it can cover the notch
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    /// The status dot sets this false so clicking it never takes keyboard focus.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Geometry of the notch on one screen.
struct NotchGeometry: Equatable {
    let screenFrame: NSRect
    let notchSize: CGSize
    let hasRealNotch: Bool

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: width, height: top), hasRealNotch: true)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(screenFrame: screen.frame, notchSize: CGSize(width: 190, height: menuBar), hasRealNotch: false)
    }

    /// The notch rectangle in screen coordinates.
    var notchRect: NSRect {
        NSRect(x: screenFrame.midX - notchSize.width / 2, y: screenFrame.maxY - notchSize.height,
               width: notchSize.width, height: notchSize.height)
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// The springs every transition uses, so the island moves as one system.
enum Motion {
    /// Growing out of the notch: a little overshoot, like the Dynamic Island.
    static let open = Animation.bouncy(duration: 0.5, extraBounce: 0.08)
    /// Shrinking back into the notch: no overshoot.
    static let close = Animation.smooth(duration: 0.34)
    /// Content changes inside the open island.
    static let content = Animation.smooth(duration: 0.32)
    /// Small elements: dot, selection, buttons.
    static let snappy = Animation.snappy(duration: 0.28)
    /// One reply replacing another.
    static let message = Animation.smooth(duration: 0.45)
    /// List selection: fast and nearly critically damped, so it feels instant.
    static let select = Animation.spring(response: 0.16, dampingFraction: 0.9)
    /// Select mode's highlight, in when ⌃⌥ goes down and out when it goes up.
    static let hold = Animation.smooth(duration: 0.16)
}

/// Shows, hides and animates the island. The panel is a fixed canvas top-centred on the
/// chosen screen; clicks pass through everywhere except the island itself.
@MainActor
final class PanelController {
    enum Mode: Equatable { case hidden, expanded, peek }

    let panel = NotchPanel()
    let ui: OverlayUIState
    let store: Store
    private var geometry: NotchGeometry
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var heldKeyMonitor: Any?
    private var peekHideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?
    /// Reads the pointer while the island is open. Mouse-moved events are not enough: AppKit
    /// does not send them to a panel that is not key in an app that is not active, so a
    /// pointer that leaves the island over the panel's transparent canvas can go unseen.
    private var mouseTimer: Timer?
    /// What the current tour step waits for (see Onboarding.swift).
    var onboardingTask: Task<Void, Never>?
    /// The Hotkey step: the shortcut has folded the island once.
    var onboardingHidOnce = false
    /// How many successes the tour has had; each plays the next note up.
    var onboardingNote = 0

    init(store: Store) {
        self.store = store
        self.geometry = NotchGeometry.forScreen(NotchGeometry.screenUnderMouse())
        self.ui = OverlayUIState()
        ui.onClose = { [weak self] in self?.hide() }
        ui.onOpenInT3 = { [weak self] in self?.openInT3() }
        ui.onOpenPermission = { [weak self] permission in self?.grantPermissions(startingWith: permission) }
        ui.onRequestFocus = { [weak self] in self?.focusTextField() }
        ui.onDraftSent = { [weak self] in self?.draftSent() }
        ui.onTypingChange = { [weak self] _ in self?.updateCursor() }
        ui.onIslandFrameChange = { [weak self] in self?.updateMouse() }
        ui.onOnboardingStep = { [weak self] step in self?.go(to: step) }
        ui.onOnboardingPickerClosed = { [weak self] in self?.onboardingPickerClosed() }
        let host = FirstClickHostingView(rootView: OverlayView(store: store, ui: ui))
        host.sizingOptions = []
        panel.contentView = host
        panel.ignoresMouseEvents = true
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }
        // Whenever the island takes keyboard focus (hotkey, or a click on it), remember the
        // app that had it, so hiding the island can hand focus straight back.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rememberFrontApp()
                // Clicking a popped-up (peek) island opens it fully, ready to type and clip.
                if self.ui.mode == .peek { self.expand() }
            }
        }
        // The tour's keycaps go down while you hold their keys.
        heldKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackHeldKeys(event) }
            return event
        }
        // A draft, selections, a running select mode and a message on its way belong to the
        // focused chat.
        store.holdsTarget = { [weak self] in
            guard let self else { return false }
            return !self.ui.draft.isEmpty || !self.ui.clips.isEmpty || self.clipper != nil || self.ui.sending > 0
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    var mode: Mode { ui.mode }

    func toggle() {
        if ui.onboarding == .hotkey { onboardingHotkeyPressed(); return }
        ui.mode == .expanded ? hide() : expand()
    }

    func expand() {
        peekHideTask?.cancel()
        // A chat opened in T3 while the island held work for another chat.
        store.focusLastOpened()
        store.markReplySeen()
        let wasHidden = ui.mode == .hidden
        if wasHidden { place(on: NotchGeometry.screenUnderMouse()) }
        rememberFrontApp()
        present()
        panel.makeKey()
        animateMode(.expanded, afterLayout: wasHidden)
        startDraftSync()
        // No chat focused: open straight onto the list of chats.
        if store.targetThreadId == nil && store.connection == .connected && !ui.pickerOpen && ui.onboarding == nil {
            setPicker(true)
        } else {
            focusTextField()
        }
    }

    /// Shows the reply without taking focus; fades after a delay unless hovered.
    func peek(autoHide: Bool, compact: Bool = false) {
        // A chat that needs you, while the pointer's small peek shows: show the full one.
        if ui.mode == .peek, !compact, ui.peekCompact { withAnimation(Motion.open) { ui.peekCompact = false } }
        guard ui.mode == .hidden else { return }
        ui.peekCompact = compact
        place(on: NotchGeometry.screenUnderMouse())
        present()
        animateMode(.peek, afterLayout: true)
        if autoHide { schedulePeekHide(after: 8) }
    }

    /// The app that had keyboard focus before the island took it.
    private var previousApp: NSRunningApplication?
    /// Set by the app delegate: opens the settings card.
    var onOpenSettings: (() -> Void)?

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
    }

    /// Opens the thread in T3 (which takes focus) and hides the island.
    /// Opens the chat in T3 and hands over what is in the island: the draft text fills T3's
    /// chat box and the clips are pasted in as attachments. The island is cleared, since the
    /// draft now lives in T3.
    func openInT3() {
        let text = ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let clips = ui.clips
        hide(returnFocus: false)
        // With clips, the text is pasted after them (see Handoff); without, the link carries it.
        let pid = store.runtime?.app?.processIdentifier
        let pasteText = !clips.isEmpty && pid != nil && Permission.accessibility.isGranted
        store.openTargetInT3(prompt: text.isEmpty || pasteText ? nil : text)
        guard !text.isEmpty || !clips.isEmpty, store.targetThreadId != nil else { return }
        ui.draft = ""
        ui.clips = []
        ui.removedClips = []
        if let pid { Handoff.pasteClips(clips, text: pasteText ? text : "", into: pid) }
    }

    /// Gives keyboard focus back to the app you were in, if the island had taken it.
    private func returnFocus() {
        guard panel.isKeyWindow else { return }
        panel.resignKey()
        if !Store.demo { previousApp?.activate() } // the demo stage stays in front
    }

    /// Hides the island. `returnFocus: false` when another app is about to take focus
    /// anyway (opening the thread in T3), so the two activations don't fight.
    func hide(returnFocus shouldReturn: Bool = true) {
        peekHideTask?.cancel()
        stopDraftSync()
        onboardingSelectHidden(selecting: clipper != nil)
        if shouldReturn { returnFocus() } else { panel.resignKey() }
        withAnimation(Motion.close) {
            ui.mode = .hidden
            ui.pickerOpen = false
        }
        panel.ignoresMouseEvents = true
        stopMouseTimer()
        store.focusLastOpened() // as in `expand`
        // Take the canvas away once the island has shrunk into the notch.
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, self.ui.mode == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: - T3's own draft

    private let composer = T3Composer()
    private var draftSyncTimer: Timer?
    private var draftSyncBusy = false
    /// The text of T3's message field when the island and T3 last agreed; nil while they do
    /// not share a draft (T3 shows another chat, or both had their own text).
    private var syncedDraft: String?
    private let draftLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.t3notch.app", category: "draft")

    /// T3's message field for the island's chat: only while T3's window shows that chat.
    private var composerTarget: (pid: pid_t, title: String)? {
        guard Settings.syncDraft, Permission.accessibility.isGranted, ui.onboarding == nil, !Store.demo,
              let id = store.targetThreadId, store.chatShownInT3 == id,
              let title = store.targetTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let pid = store.runtime?.app?.processIdentifier else { return nil }
        return (pid, title)
    }

    /// Two drafts are one when only the white space at the end differs.
    private static func sameDraft(_ a: String, _ b: String) -> Bool {
        func trimmed(_ s: String) -> Substring { s[..<(s.lastIndex(where: { !$0.isWhitespace }).map { s.index(after: $0) } ?? s.startIndex)] }
        return trimmed(a) == trimmed(b)
    }

    /// While the island is open on the chat T3 shows, the island's message and T3's message
    /// field are one draft: what you type in one is in the other within half a second.
    private func startDraftSync() {
        guard draftSyncTimer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncDraft() }
        }
        RunLoop.main.add(timer, forMode: .common)
        draftSyncTimer = timer
        syncDraft()
    }

    /// The island closes. A draft that T3's field also has leaves the island: it would keep
    /// the island on this chat, and T3 has it.
    private func stopDraftSync() {
        draftSyncTimer?.invalidate()
        draftSyncTimer = nil
        guard let target = composerTarget, syncedDraft != nil, ui.clips.isEmpty, ui.sending == 0 else { syncedDraft = nil; return }
        let mine = ui.draft, synced = syncedDraft
        syncedDraft = nil
        guard !mine.isEmpty else { return }
        // T3 has it already: no write, which would move the cursor in T3's field.
        if let synced, Self.sameDraft(mine, synced) {
            ui.draft = ""
            return
        }
        composer.write(mine, pid: target.pid, chatTitle: target.title) { [weak self] now in
            guard let self, let now, Self.sameDraft(now, mine), self.ui.mode != .expanded, self.ui.draft == mine else { return }
            self.ui.draft = ""
            self.store.focusLastOpened()
        }
    }

    /// The message leaves from the island, so T3's field must not keep a copy of it.
    private func draftSent() {
        if syncedDraft != nil, let target = composerTarget {
            composer.write("", pid: target.pid, chatTitle: target.title)
        }
        syncedDraft = nil
    }

    private func syncDraft() {
        guard !draftSyncBusy else { return }
        guard let target = composerTarget else { syncedDraft = nil; return }
        let mine = ui.draft
        draftSyncBusy = true
        // You typed in the island: T3's field takes it.
        if let synced = syncedDraft, !Self.sameDraft(mine, synced) {
            composer.write(mine, pid: target.pid, chatTitle: target.title) { [weak self] now in
                guard let self else { return }
                self.draftSyncBusy = false
                self.syncedDraft = now
                if let now, !Self.sameDraft(now, mine) {
                    self.draftLog.notice("T3 keeps the draft differently: wrote \(mine.count, privacy: .public), has \(now.count, privacy: .public)")
                }
            }
            return
        }
        composer.read(pid: target.pid, chatTitle: target.title) { [weak self] text in
            guard let self else { return }
            self.draftSyncBusy = false
            // No field, T3 moved to another chat, or you typed while T3 answered.
            guard let text, self.composerTarget?.title == target.title, self.ui.draft == mine else {
                if text == nil { self.syncedDraft = nil }
                return
            }
            if let synced = self.syncedDraft {
                // You typed in T3: the island takes it.
                if !Self.sameDraft(text, synced) { self.ui.draft = text; self.syncedDraft = text }
            } else if mine.isEmpty || Self.sameDraft(text, mine) {
                // The island had nothing of its own: T3's draft is the draft.
                if !Self.sameDraft(text, mine) { self.ui.draft = text }
                self.syncedDraft = text
            } else if text.isEmpty {
                self.syncedDraft = "" // T3 had nothing: the next round gives it the island's text
            }
            // Both had their own text: they stay apart, so nothing is lost.
        }
    }

    private func present() {
        orderOutTask?.cancel()
        panel.orderFrontRegardless()
        startMouseTimer()
    }

    private func startMouseTimer() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ui.mode != .hidden else { return }
                self.updateMouse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTimer() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    /// Sets the mode with the open spring. From hidden, wait one runloop turn so the
    /// collapsed island is on screen first and the spring has somewhere to start from.
    private func animateMode(_ mode: Mode, afterLayout: Bool) {
        let apply: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            withAnimation(Motion.open) { self.ui.mode = mode }
            self.updateMouse()
        }
        if afterLayout { DispatchQueue.main.async(execute: apply) } else { apply() }
    }

    private func schedulePeekHide(after seconds: Double) {
        peekHideTask?.cancel()
        peekHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.ui.mode == .peek, !self.ui.hovering else { return }
            self.hide()
        }
    }

    private func place(on screen: NSScreen) {
        geometry = NotchGeometry.forScreen(screen)
        ui.notchSize = geometry.notchSize
        ui.hasRealNotch = geometry.hasRealNotch
        ui.maxReplyHeight = screen.frame.height * 0.4
        // Room for the widest island, its shadow, and the tallest content.
        let w: CGFloat = 760
        let h = min(screen.frame.height, geometry.notchSize.height + ui.maxReplyHeight + 380)
        panel.setFrame(NSRect(x: geometry.screenFrame.midX - w / 2, y: geometry.screenFrame.maxY - h, width: w, height: h),
                       display: true)
    }

    // MARK: - Mouse

    /// The island's rectangle in screen coordinates.
    private var islandScreenRect: NSRect {
        let r = ui.islandFrame // SwiftUI global space: top-left origin, in the hosting view
        let f = panel.frame
        return NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Lets clicks through the transparent canvas, tracks hover over the island, and
    /// peeks when the pointer rests on the notch while an agent works.
    private func updateMouse() {
        let p = NSEvent.mouseLocation
        if ui.mode == .hidden {
            panel.ignoresMouseEvents = true
            setHovering(false)
            checkNotchHover(p)
            return
        }
        let inside = NSMouseInRect(p, islandScreenRect.insetBy(dx: -4, dy: -4), false)
        panel.ignoresMouseEvents = !inside
        setHovering(inside)
    }

    private func setHovering(_ hovering: Bool) {
        guard ui.hovering != hovering else { return }
        ui.hovering = hovering
        if ui.mode == .peek, !hovering { schedulePeekHide(after: Self.peekLeaveDelay) }
        if hovering { peekHideTask?.cancel() }
    }

    /// How long a peek stays after the pointer leaves it: long enough to forgive a pointer
    /// that slips off the edge and comes back, short enough to feel like it follows you.
    private static let peekLeaveDelay = 0.6

    private func checkNotchHover(_ p: NSPoint) {
        // Setting on: any focused chat, not over a fullscreen app.
        guard Settings.expandOnHover, store.targetThread != nil, !ui.notchScreenFullscreen else { return }
        let g = NotchGeometry.forScreen(NotchGeometry.screenUnderMouse())
        if NSMouseInRect(p, g.notchRect.insetBy(dx: -8, dy: 0), false) {
            peek(autoHide: false, compact: true)
            schedulePeekHide(after: 1.5) // stays while hovered
        }
    }

    // MARK: - Keyboard

    /// SwiftUI's FocusState is unreliable in a non-activating panel, so focus the one
    /// visible text field through AppKit once SwiftUI has mounted it.
    private func focusTextField() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            _ = self?.focusTextFieldNow()
        }
    }

    /// The text cursor shows (in the accent colour) only while there is text, so the
    /// collapsed input has no stray cursor and the open one always has a visible one.
    private func updateCursor() {
        guard let editor = panel.firstResponder as? NSTextView else { return }
        let showing = ui.pickerOpen || ui.inputShows
        editor.insertionPointColor = showing ? .controlAccentColor : .clear
        editor.updateInsertionPointStateAndRestartTimer(true)
    }

    /// Focuses the visible text field; returns false when there is none.
    @discardableResult
    private func focusTextFieldNow() -> Bool {
        var target = panel.contentView?.firstEditableText
        // A selection's comment is open: it sits just above the message field, the lowest one.
        // A comment that just closed can still be in the view while it fades: then the message
        // field, the lowest, is the one.
        // A question's own answer field sits above both and keeps the old rule when no comment is open.
        if ui.editingClip != nil || store.pendingRequest == nil,
           let fields = panel.contentView?.editableTexts, fields.count > 1 {
            let byHeight = fields.sorted { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY }
            target = byHeight[ui.editingClip != nil ? 1 : 0]
        }
        guard let field = target else { return false }
        let ok = panel.makeFirstResponder(field)
        updateCursor()
        return ok
    }

    /// True while a text field is being edited (its field editor is first responder).
    private var isEditingText: Bool {
        (panel.firstResponder as? NSTextView)?.isEditable == true
    }

    /// Overlay shortcuts. Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        if handleOnboardingKey(event) { return true }
        if let step = Self.vimStep(event) {
            if ui.pickerOpen { movePicker(by: step) } else { scrollReply(by: step) }
            return true
        }
        let cmd = event.modifierFlags.contains(.command)
        let ctrl = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        let approval = store.pendingRequest.map { $0.kind != "user_input" } ?? false
        // The chat list's shortcut is rebindable (⌘K by default).
        if Settings.showChatsKey.matches(event) {
            setPicker(!ui.pickerOpen); return true
        }
        if Settings.openInT3Key.matches(event) { // ⌘O by default: open in T3, hide the island
            openInT3(); return true
        }
        // A selection's comment is open: ⏎ and ⌘Z are that field's keys, not the approval's or
        // the clip row's.
        let commenting = ui.editingClip.map { id in ui.clips.contains { $0.id == id } } ?? false
        if commenting, (event.keyCode == 36 && !cmd) || event.keyCode == 6 { return false }
        switch event.keyCode {
        case 53: // Esc
            if ui.pickerOpen { setPicker(false); return true }
            if let open = ui.editingClip { // back to the message
                withAnimation(Motion.content) { ui.editingClip = nil }
                if ui.clips.contains(where: { $0.id == open }) { focusTextField(); return true }
            }
            if approval { Task { await store.respond(decision: "decline") }; return true }
            hide(); return true
        case 6 where (cmd || ctrl) && !shift: // ⌘Z / ⌃Z: restore a removed clip, else normal undo
            var restored = false
            withAnimation(Motion.content) { restored = ui.undoClipRemoval() }
            return restored
        case 43 where cmd: // ⌘, opens settings
            onOpenSettings?(); return true
        case 35 where cmd: // ⌘P enters clipping mode
            startClipping(); return true
        case 47 where cmd: // ⌘.
            Task { await store.interruptRun() }; return true
        case 36 where cmd && approval: // ⌘⏎
            Task { await store.respond(decision: "acceptForSession") }; return true
        case 36 where cmd && !ui.pickerOpen: // ⌘⏎ does what ⏎ does not: queue or steer
            sendDraft(steer: !Settings.enterSteers); return true
        case 36 where approval && !ui.pickerOpen && ui.draft.isEmpty: // ⏎
            Task { await store.respond(decision: "accept") }; return true
        case 125 where ui.pickerOpen: // ↓
            movePicker(by: 1); return true
        case 126 where ui.pickerOpen: // ↑
            movePicker(by: -1); return true
        default:
            // Typing with no field focused (e.g. after clearing collapsed the input):
            // focus the field and give it this key, so no character is lost.
            let plain = event.modifierFlags.intersection([.command, .control]).isEmpty
            if plain, !isEditingText, let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
               focusTextFieldNow(), let editor = panel.firstResponder as? NSTextView {
                editor.keyDown(with: event)
                return true
            }
            return false
        }
    }

    /// ⌃J / ⌃N move down, ⌃K / ⌃P move up. Returns nil for any other key.
    private static func vimStep(_ event: NSEvent) -> Int? {
        let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard mods == .control else { return nil }
        switch event.keyCode {
        case 38, 45: return 1   // j, n
        case 40, 35: return -1  // k, p
        default: return nil
        }
    }

    func movePicker(by step: Int) {
        let last = max(ui.pickerCount - 1, 0)
        ui.pickerIndex = min(max(ui.pickerIndex + step, 0), last) // the highlight animates itself
    }

    /// Scrolls the reply by about four lines per press.
    private func scrollReply(by step: Int) {
        let y = min(max(ui.replyOffset + CGFloat(step) * 64, 0), ui.replyMaxOffset)
        withAnimation(Motion.snappy) { ui.replyScroll.scrollTo(y: y) }
    }

    func sendDraft(steer: Bool) {
        let text = ui.draft
        let clips = ui.clips
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !clips.isEmpty else { return }
        // Keep the draft when the selections cannot go in one message.
        guard Store.clipPlan(clips) != nil else {
            store.lastSendError = "Too many or too large selections for one message. Remove some and send again."
            return
        }
        draftSent()
        withAnimation(Motion.content) { ui.draft = ""; ui.clips = []; ui.removedClips = []; ui.clipDepth = 0 }
        ui.sending += 1
        let to = store.targetThreadId
        Task {
            let sent = await store.send(text, steer: steer, clips: clips, to: to)
            ui.sending -= 1
            // Not sent: the message and its selections come back.
            if !sent {
                ui.draft = ui.draft.isEmpty ? text : text + "\n" + ui.draft
                ui.clips = clips + ui.clips
                expand()
            }
            store.focusLastOpened()
        }
        hide() // sent: tuck the island away and hand focus back
    }

    // MARK: - Clipping

    private var clipper: ClipController?

    /// ⌘P: hide the island at once (so it is not in the frozen frame), clip, then come back.
    /// ⌘P. Without Screen Recording, show the permission buttons and start on its own once
    /// it is granted. Without Accessibility, clip anyway (hover picks whole windows) and
    /// offer that button afterwards.
    func startClipping() {
        guard clipper == nil else { return }
        guard Permission.screenRecording.isGranted else {
            clipWhenAllowed = true
            showMissingPermissions()
            return
        }
        clipWhenAllowed = false
        orderOutTask?.cancel()
        ui.mode = .hidden
        ui.pickerOpen = false
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        clipper = ClipController.start(depth: ui.clipDepth) { [weak self] clips, depth in
            guard let self else { return }
            self.clipper = nil
            self.ui.clipDepth = depth
            self.ui.clips += clips
            self.expand()
            self.showMissingPermissions()
        }
    }

    /// Set by the app delegate: select mode ended by itself, and ⌃⌥ may still be down.
    var onSelectEnded: (() -> Void)?
    /// `--select-dry`, for checking select mode: ⏎ sends nothing.
    var selectSendsNothing = false
    private let selectLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.t3notch.app", category: "select")

    /// ⌃⌥ is held in any app, or no longer. While held, select mode shows what is under the
    /// pointer and the island stays as it is. A click opens a comment field, and ⏎ there sends
    /// the selection and the comment to the last opened session.
    func selectHold(_ held: Bool) {
        guard held else {
            clipper?.holdEnded()
            return
        }
        guard clipper == nil else { return }
        // The tour's Select step, with the island in view: the hold is the lesson.
        let inTour = ui.onboarding == .select && ui.mode == .expanded
        if inTour, !Onboarding.canSelect {
            onboardingSelectHeld(started: false)
            return
        }
        guard Permission.accessibility.isGranted else {
            expand()
            showMissingPermissions()
            return
        }
        store.focusLastOpened()
        let islandHadKeys = panel.isKeyWindow
        var select = ClipController.Select(
            title: { [weak self] in self?.store.targetTitle },
            target: { [weak self] in self?.store.targetThreadId },
            cycle: { [weak self] step in self?.store.cycleTarget(step) },
            onEnd: { [weak self] end in self?.selectEnded(end, islandHadKeys: islandHadKeys, inTour: inTour) })
        if inTour { select.onScroll = { [weak self] in self?.onboardingSelectScrolled() } }
        select.onPick = { [weak self] image, rect in self?.land(image, from: rect) }
        clipper = ClipController.startSelecting(select)
        if inTour { onboardingSelectHeld(started: clipper != nil) }
    }

    private func selectEnded(_ end: ClipController.SelectEnd, islandHadKeys: Bool, inTour: Bool) {
        clipper = nil
        // The tour moves on after a click, and asks again after a hold without one.
        defer { if inTour { onboardingSelectEnded(clicked: !end.isRelease) } }
        switch end {
        case .released:
            return // the hold trigger knows: it reported the end, or gets the same key event
        case .cancelled:
            ui.landing = false
        case let .send(clip, comment, steer, to):
            let size = clip.thumbnail.size
            selectLog.notice("""
                send \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) \
                app=\(clip.context?.appName ?? "none", privacy: .public) \
                element=\(clip.context?.element?.role ?? "none", privacy: .public) \
                page=\(clip.context?.page != nil, privacy: .public) comment=\(comment.count, privacy: .public)
                """)
            // The selection is context for the chat: it sits in the island as a chip, and the
            // island's input has the keyboard. `land` opened the island when the click came.
            _ = (steer, to)
            // The comment stays with its selection: a click on the chip shows and edits it.
            var clip = clip
            clip.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            withAnimation(Motion.snappy) { ui.landing = false; ui.clips.append(clip) }
            if ui.mode != .expanded { expand() } else { panel.makeKey(); focusTextField() }
            onSelectEnded?()
            return
        case let .unsent(comment):
            ui.landing = false
            keep(nil, comment)
            showMissingPermissions()
            return
        }
        // The comment field had the keyboard; the island gets it back if it had it before.
        if islandHadKeys, ui.mode == .expanded {
            panel.makeKey()
            focusTextField()
        }
        onSelectEnded?()
    }

    /// A click in select mode picked something. Its picture flies from where it is on screen
    /// into the notch, and the island opens on the chat it is for, so you see where it went.
    private func land(_ image: NSImage, from rect: CGRect) {
        ui.landingSlot = nil
        ui.landing = true
        if ui.mode != .expanded { expand() }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let primary = NSScreen.screens.first?.frame.height else { return }
        let start = NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
        let window = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        window.contentView = view
        window.orderFrontRegardless()
        Task { [weak self] in
            // The island lays out the free place in its row of selections: wait for it, a
            // few frames at most. It reports where the place ends up, also while it opens.
            for _ in 0..<12 where self?.ui.landingSlot == nil { try? await Task.sleep(for: .milliseconds(16)) }
            guard let self else { window.orderOut(nil); return }
            // It ends in that place, or just under the notch when the island has none.
            var slot: NSRect
            if let s = self.ui.landingSlot {
                let frame = self.panel.frame
                slot = NSRect(x: frame.minX + s.minX, y: frame.maxY - s.maxY, width: s.width, height: s.height)
            } else {
                let notch = self.geometry.notchRect
                slot = NSRect(x: notch.midX - 32, y: notch.minY - 58, width: 64, height: 44)
            }
            let scale = min(slot.width / max(rect.width, 1), slot.height / max(rect.height, 1), 1)
            let size = CGSize(width: max(rect.width * scale, 12), height: max(rect.height * scale, 12))
            let end = NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                             width: size.width, height: size.height)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.44
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.12, 1)
                window.animator().setFrame(end, display: true)
            }, completionHandler: nil)
            // It fades as it arrives, while the chip comes in under it.
            try? await Task.sleep(for: .milliseconds(340))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                window.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { window.orderOut(nil) } })
        }
    }

    /// Puts a selection and its comment in the island and opens it, so nothing is lost.
    private func keep(_ clip: Clip?, _ comment: String) {
        if let clip { ui.clips.append(clip) }
        if !comment.isEmpty { ui.draft = ui.draft.isEmpty ? comment : ui.draft + "\n" + comment }
        expand()
    }

    // MARK: - Permissions

    private var clipWhenAllowed = false
    private var permissionTimer: Timer?
    private let permissionGuide = PermissionGuide()

    /// Walks through granting `first` and any other missing permission.
    func grantPermissions(startingWith first: Permission) { permissionGuide.start(first) }

    /// Shows a button per missing permission and watches for grants while any are missing.
    private func showMissingPermissions() {
        withAnimation(Motion.content) { ui.missingPermissions = Permission.missing }
        guard !ui.missingPermissions.isEmpty, permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }
    }

    private func checkPermissions() {
        if ui.missingPermissions.contains(.screenRecording) {
            Task { await Permission.confirmScreenRecordingLive() }
        }
        let missing = Permission.missing
        if missing != ui.missingPermissions {
            withAnimation(Motion.content) { ui.missingPermissions = missing }
        }
        if Permission.screenRecording.isGranted, clipWhenAllowed {
            clipWhenAllowed = false
            if ui.mode == .expanded { startClipping() }
        }
        if missing.isEmpty {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    /// Picks the highlighted chat in the open list (what ⏎ does there).
    func pickHighlighted() {
        let rows = store.pickerRows(query: ui.pickerQuery)
        guard rows.indices.contains(ui.pickerIndex) else { return }
        withAnimation(Motion.content) {
            store.focusedThreadId = rows[ui.pickerIndex]["key"].string
            ui.pickerOpen = false
            ui.pickerQuery = ""
        }
        focusTextField()
    }

    func setPicker(_ open: Bool) {
        withAnimation(Motion.content) {
            ui.pickerOpen = open
            // Start on the focused chat, so ⏎ keeps it.
            ui.pickerIndex = min(store.sidebarThreads.firstIndex { $0["key"].string == store.targetThreadId } ?? 0, 59)
            if !open { ui.pickerQuery = "" }
        }
        focusTextField()
    }
}

extension NSView {
    /// Every visible text field inside this view that can be typed in.
    var editableTexts: [NSView] {
        subviews.flatMap { sub -> [NSView] in
            if let tf = sub as? NSTextField, tf.isEditable, !tf.isHidden { return [tf] }
            if let tv = sub as? NSTextView, tv.isEditable, !tv.isHidden { return [tv] }
            return sub.editableTexts
        }
    }

    /// The first visible text field inside this view that can be typed in.
    var firstEditableText: NSView? {
        for sub in subviews {
            if let tf = sub as? NSTextField, tf.isEditable, !tf.isHidden { return tf }
            if let tv = sub as? NSTextView, tv.isEditable, !tv.isHidden { return tv }
            if let found = sub.firstEditableText { return found }
        }
        return nil
    }
}

