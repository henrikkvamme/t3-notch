import AppKit
import ApplicationServices
import SwiftUI

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
}

/// Shows, hides and animates the island. The panel is a fixed canvas top-centred on the
/// chosen screen; clicks pass through everywhere except the island itself.
@MainActor
final class PanelController {
    enum Mode: Equatable { case hidden, expanded, peek }

    let panel = NotchPanel()
    let ui: OverlayUIState
    private let store: Store
    private var geometry: NotchGeometry
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var peekHideTask: Task<Void, Never>?
    private var orderOutTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
        self.geometry = NotchGeometry.forScreen(NotchGeometry.screenUnderMouse())
        self.ui = OverlayUIState()
        ui.onClose = { [weak self] in self?.hide() }
        ui.onOpenInT3 = { [weak self] in self?.openInT3() }
        ui.onOpenPermission = { permission in permission.openSettings() }
        ui.onRequestFocus = { [weak self] in self?.focusTextField() }
        ui.onTypingChange = { [weak self] _ in self?.updateCursor() }
        ui.onIslandFrameChange = { [weak self] in self?.updateMouse() }
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
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    var mode: Mode { ui.mode }

    func toggle() {
        ui.mode == .expanded ? hide() : expand()
    }

    func expand() {
        peekHideTask?.cancel()
        store.markReplySeen()
        let wasHidden = ui.mode == .hidden
        if wasHidden { place(on: NotchGeometry.screenUnderMouse()) }
        rememberFrontApp()
        present()
        panel.makeKey()
        animateMode(.expanded, afterLayout: wasHidden)
        // No chat focused: open straight onto the list of chats.
        if store.targetThreadId == nil && store.connection == .connected && !ui.pickerOpen {
            setPicker(true)
        } else {
            focusTextField()
        }
    }

    /// Shows the reply without taking focus; fades after a delay unless hovered.
    func peek(autoHide: Bool) {
        guard ui.mode == .hidden else { return }
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
        let pasteText = !clips.isEmpty && pid != nil && AXIsProcessTrusted()
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
        if shouldReturn { returnFocus() } else { panel.resignKey() }
        withAnimation(Motion.close) {
            ui.mode = .hidden
            ui.pickerOpen = false
        }
        panel.ignoresMouseEvents = true
        // Take the canvas away once the island has shrunk into the notch.
        orderOutTask?.cancel()
        orderOutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, self.ui.mode == .hidden else { return }
            self.panel.orderOut(nil)
        }
    }

    private func present() {
        orderOutTask?.cancel()
        panel.orderFrontRegardless()
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
        if ui.mode == .peek, !hovering { schedulePeekHide(after: 1.5) }
        if hovering { peekHideTask?.cancel() }
    }

    private func checkNotchHover(_ p: NSPoint) {
        // Setting on: any focused chat, not over a fullscreen app.
        guard Settings.expandOnHover, store.targetThread != nil, !ui.notchScreenFullscreen else { return }
        let g = NotchGeometry.forScreen(NotchGeometry.screenUnderMouse())
        if NSMouseInRect(p, g.notchRect.insetBy(dx: -8, dy: 0), false) {
            peek(autoHide: false)
            schedulePeekHide(after: 2.5) // stays while hovered
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
        let showing = ui.pickerOpen || !ui.draft.isEmpty
        editor.insertionPointColor = showing ? .controlAccentColor : .clear
        editor.updateInsertionPointStateAndRestartTimer(true)
    }

    /// Focuses the visible text field; returns false when there is none.
    @discardableResult
    private func focusTextFieldNow() -> Bool {
        guard let root = panel.contentView, let field = Self.findTextField(in: root) else { return false }
        let ok = panel.makeFirstResponder(field)
        updateCursor()
        return ok
    }

    /// True while a text field is being edited (its field editor is first responder).
    private var isEditingText: Bool {
        (panel.firstResponder as? NSTextView)?.isEditable == true
    }

    private static func findTextField(in view: NSView) -> NSView? {
        for sub in view.subviews {
            if let tf = sub as? NSTextField, tf.isEditable, !tf.isHidden { return tf }
            if let tv = sub as? NSTextView, tv.isEditable, !tv.isHidden { return tv }
            if let found = findTextField(in: sub) { return found }
        }
        return nil
    }

    /// Overlay shortcuts. Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
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
        switch event.keyCode {
        case 53: // Esc
            if ui.pickerOpen { setPicker(false); return true }
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
        case 36 where cmd && !ui.pickerOpen: // ⌘⏎ steers the running turn
            sendDraft(steer: true); return true
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
        withAnimation(Motion.content) { ui.draft = ""; ui.clips = []; ui.removedClips = []; ui.clipDepth = 0 }
        Task { await store.send(text, steer: steer, clips: clips) }
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

    // MARK: - Permissions

    private var clipWhenAllowed = false
    private var permissionTimer: Timer?

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
            store.focusedThreadId = rows[ui.pickerIndex]["id"].string
            ui.pickerOpen = false
            ui.pickerQuery = ""
        }
        focusTextField()
    }

    func setPicker(_ open: Bool) {
        withAnimation(Motion.content) {
            ui.pickerOpen = open
            // Start on the focused chat, so ⏎ keeps it.
            ui.pickerIndex = min(store.sidebarThreads.firstIndex { $0["id"].string == store.targetThreadId } ?? 0, 59)
            if !open { ui.pickerQuery = "" }
        }
        focusTextField()
    }
}

