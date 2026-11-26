import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI
import os

/// A screen region added as context: the cropped PNG plus a thumbnail for the island, and
/// what the agent should know about it (filled in shortly after the clip is taken).
struct Clip: Identifiable, Equatable {
    let id = UUID()
    let png: Data
    let thumbnail: NSImage
    var context: PickContext?

    static func == (a: Clip, b: Clip) -> Bool { a.id == b.id }
}

// MARK: - Clipping mode

/// Picks a part of the screen, in one of two modes.
///
/// Clip mode, ⌘P from the open island: freezes every screen, then lets you hover to pick a UI
/// element (Accessibility) or drag a rectangle. Releasing adds the clip and returns to the
/// island; with ⇧ held it stays for more. Keys: k or ↑ picks the parent, j or ↓ the child,
/// h and l the previous and next sibling. ⏎ adds the highlight and ends, ⌫ removes the last
/// pick, Esc or ⌘P leave.
///
/// Select mode, ⌃⌥ held in any app (see `SelectTrigger`): shows the element under the pointer
/// on the live screen and takes no focus. A scroll changes the level. Letting go hides it. A
/// click freezes the screens and opens a comment field beside the selection: ⏎ sends both to
/// the chat, Esc leaves. There, ⌃K picks the parent, ⌃J the child, ⌃H and ⌃L the previous
/// and next sibling, as k, j, h and l do in clip mode.
///
/// Rects are global and top-left-origin (CoreGraphics/Accessibility space) throughout.
@MainActor
final class ClipController {
    private let state = ClipState()
    private var windows: [NotchPanel] = []
    private var monitors: [Any] = []
    private var resignObserver: Any?
    private let probe = ElementProbe()
    private let onFinish: ([Clip], Int) -> Void
    private var finished = false
    /// Select mode: the chat the comment goes to, and where the result goes. Nil in clip mode.
    private let select: Select?
    /// Select mode, while ⌃⌥ is held: takes the scroll and the click from the app under the
    /// pointer, which keeps the focus.
    private var tap: EventTap?
    /// Where the left button went down, while the tap holds it.
    private var pressAt: CGPoint?
    /// Text selected in the app in front when select mode started: the highlight while the
    /// pointer is on it.
    private var textSelection: ProbeResult?
    /// Screen content, asked for when select mode starts so the click can capture at once.
    private var shareable: Task<ScreenCapture.Content?, Never>?
    /// ⏎ came before the screens were captured: send when they are (true steers).
    private var sendWhenFrozen: Bool?
    /// The screens are captured (or could not be), after the click.
    private var captured = false
    /// ⏎ was pressed: the selection goes to the chat (true steers).
    private var sending: Bool?
    /// The chat that showed when ⏎ was pressed. The end can come a second later, and the
    /// island's chat can change in that time.
    private var sendTo: String?
    /// The comment did not go out with a selection; it goes to the island.
    private var unsent = false
    /// Select mode ended because the hold ended, not by Esc.
    private var released = false
    /// The button went up before the first probe answered: the comment opens when it does.
    private var clicking = false
    /// The overlay that holds the keyboard while the comment field is open, and the app that
    /// gets it back.
    private weak var keyPanel: NotchPanel?
    private var previousApp: NSRunningApplication?
    /// After a navigation key the highlight is not where the pointer points: keep it until the
    /// pointer moves 8pt away.
    private var lockedAt: CGPoint?
    /// Bumped by every navigation key and pointer move, so a late async result that an
    /// newer action replaced is dropped.
    private(set) var navigation = 0

    struct Select {
        /// The title of the chat the comment goes to, nil with none.
        let title: () -> String?
        /// The id of that chat, nil with none.
        let target: () -> String?
        /// ⇥ and ⇧⇥: the next or previous chat.
        let cycle: (Int) -> Void
        let onEnd: (SelectEnd) -> Void
    }

    enum SelectEnd {
        /// The hold ended before a click: ⌃⌥ let go, or something else was pressed.
        case released
        /// Esc, or another app took the keyboard.
        case cancelled
        /// ⏎: the selection and its comment, for the chat that showed when ⏎ was pressed
        /// (`to`, nil with none). `steer` for ⌘⏎.
        case send(Clip, comment: String, steer: Bool, to: String?)
        /// The screen could not be captured (Screen Recording is off), so there is no
        /// selection to send. The comment goes to the island.
        case unsent(comment: String)
    }

    private init(select: Select? = nil, onFinish: @escaping ([Clip], Int) -> Void) {
        self.select = select
        self.onFinish = onFinish
    }

    /// Captures the screens and shows the overlay. Calls `onFinish` with the clips taken
    /// (possibly none) when the mode ends; `onFailure` if capture is not allowed.
    /// Captures the screens and shows the overlay; calls `onFinish` with the clips taken
    /// (possibly none). The caller checks Screen Recording first (see `Permission`).
    /// The running clipping session, for the demo script.
    static weak var current: ClipController?

    // Demo hooks: a scripted pointer, element chain, scroll and click.
    func demoHover(pointer: CGPoint, chain: [CGRect]) {
        state.pointer = pointer
        state.setChain(chain)
    }
    func demoScroll(_ step: Int) { state.step(step) }
    func demoClick() { if let h = state.highlight { add(h) } }

    static func start(depth: Int, onFinish: @escaping ([Clip], Int) -> Void) -> ClipController {
        let controller = ClipController(onFinish: onFinish)
        current = controller
        controller.state.depth = depth
        Task { await controller.begin() }
        return controller
    }

    /// One overlay per screen, over everything. `takesMouse` false lets clicks through.
    private func showOverlays(takesMouse: Bool) {
        for screen in NSScreen.screens {
            let panel = NotchPanel()
            panel.level = .screenSaver
            panel.ignoresMouseEvents = !takesMouse
            panel.setFrame(screen.frame, display: false)
            panel.contentView = FirstClickHostingView(rootView: ClipOverlayView(
                state: state, screenRect: Self.globalRect(of: screen),
                onHover: { [weak self] p in self?.hover(p) },
                onAdd: { [weak self] r in self?.add(r) },
                onRemove: { [weak self] i in self?.remove(i) },
                onClick: { [weak self] p in self?.repick(at: p) },
                onCommentShown: { [weak self] in self?.focusComment() }))
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        state.screens = NSScreen.screens.map(Self.globalRect)
    }

    /// A screen's frame in global top-left-origin points.
    static func globalRect(of screen: NSScreen) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    private func begin() async {
        state.frozenWindows = Self.windowFrames()
        var shots: [ClipState.Frozen] = []
        for screen in NSScreen.screens {
            let rect = Self.globalRect(of: screen)
            shots.append(.init(rect: rect, image: try? await SCScreenshotManager.captureImage(in: rect)))
        }
        state.frozen = shots
        showOverlays(takesMouse: true)
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        // Only the frontmost app may hide the pointer; T3 Notch is frontmost while clipping,
        // and the island hands focus back when it hides.
        NSApp.activate()
        NSCursor.hide()
        withAnimation(Motion.content) { state.active = true }
        installMonitors()
        hover(Self.globalMouse())
    }

    private func installMonitors() {
        // Keys reach the mode only while T3 Notch is the active app. When another app takes
        // focus (⌘⇥, a dialog), end the mode, or Esc and ⏎ would go to that app.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.finish() } }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.key(e) } ? nil : e
        } as Any)
        // Hover from mouse moves too: SwiftUI hover may not fire on screens whose overlay
        // is not the key window.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in
            MainActor.assumeIsolated {
                if self?.state.drag == nil { self?.hover(ClipController.globalMouse()) }
            }
            return e
        } as Any)
        // Scroll to grow (up) or shrink (down) the picked element.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state.preset != nil { _ = self.leavePreset(); return }
                self.state.scroll(e)
            }
            return nil
        } as Any)
    }

    /// Handles a key while the mode runs. Returns true when the key was used.
    private func key(_ e: NSEvent) -> Bool {
        if select != nil { return commentKey(e) }
        let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): finish() // Esc
        case (35, _) where mods == .command: finish() // ⌘P
        case (36, _), (76, _): // ⏎ adds the highlight (unless already added) and ends
            if state.hoveredSaved == nil, let h = state.highlight, !state.added.contains(where: { $0.isSame(as: h) }) {
                add(h, keepOpen: true)
            }
            finish()
        case (51, _), (117, _): // ⌫: remove the last pick
            if !state.added.isEmpty { remove(state.added.count - 1) }
        case (126, _), (_, "k"): keyboardStep(1)
        case (125, _), (_, "j"): keyboardStep(-1)
        case (123, _), (_, "h"): sibling(-1)
        case (124, _), (_, "l"): sibling(1)
        default: return false
        }
        return true
    }

    /// Keyboard navigation takes over from the pointer: it overrides a saved clip under the
    /// pointer and holds the highlight until the pointer moves.
    private func beginNavigation() -> Int {
        navigation += 1
        lockedAt = state.pointer
        state.navigating = true
        return navigation
    }

    /// From the text selection preset, any navigation first goes to the element that holds
    /// the selection, with its chain. Returns true when it did that.
    private func leavePreset() -> Bool {
        guard let preset = state.preset, let element = preset.elements.first ?? nil else {
            state.preset = nil
            textSelection = nil
            return false
        }
        let generation = beginNavigation()
        state.preset = nil
        textSelection = nil
        probe.chain(for: element, pid: preset.pid, windowID: preset.windowID, window: preset.window) { [weak self] result in
            guard let self, self.navigation == generation, let first = result.frames.first else { return }
            self.state.setProbe(result)
            self.state.anchor(first)
        }
        return true
    }

    private func keyboardStep(_ step: Int) {
        guard state.region == nil else { return } // a dragged rectangle has no levels
        if leavePreset() { return }
        _ = beginNavigation()
        state.step(step)
    }

    /// Moves the highlight to the previous (−1) or next (+1) sibling of the highlighted
    /// element, and keeps it there until the pointer moves 8pt.
    private func sibling(_ direction: Int) {
        guard state.region == nil else { return }
        if leavePreset() { return }
        guard let h = state.highlight else { return }
        let p = state.probe
        if let node = state.dom(for: h) {
            let generation = beginNavigation()
            probe.domSibling(of: node, direction: direction, base: p) { [weak self] result in
                guard let self, self.navigation == generation, let result, let first = result.frames.first else { return }
                self.state.setProbe(result)
                self.state.anchor(first)
            }
            return
        }
        guard let element = state.element(for: h) else { return }
        let generation = beginNavigation()
        probe.sibling(of: element, direction: direction, pid: p.pid, windowID: p.windowID, window: p.window) { [weak self] result in
            guard let self, self.navigation == generation, let result, let first = result.frames.first else { return }
            self.state.setProbe(result)
            self.state.anchor(first)
        }
    }

    private func hover(_ p: CGPoint) {
        guard !Store.demo else { return } // the demo script drives the pointer
        guard state.phase != .annotate else { return } // the selection stays where you clicked
        guard !clicking else { return } // the click's own probe must not be replaced
        state.pointer = p
        if select != nil { state.preset = textSelection.flatMap { $0.frames.first?.insetBy(dx: -6, dy: -6).contains(p) == true ? $0 : nil } }
        if let locked = lockedAt {
            guard hypot(p.x - locked.x, p.y - locked.y) > 8 else { return }
            lockedAt = nil
            state.navigating = false
            navigation += 1 // the pointer leads again: drop pending navigation results
        }
        probe.probe(at: p) { [weak self] result in
            guard let self, self.lockedAt == nil, self.state.phase != .annotate else { return }
            self.state.setProbe(result)
        }
    }

    /// Adds a clip. Releasing returns to the island with it straight away; holding ⇧ while
    /// releasing keeps clipping, so the next release without ⇧ brings them all back.
    private func add(_ rect: CGRect, keepOpen: Bool = false) {
        if select != nil {
            if state.phase == .annotate { selectRegion(rect) }
            return
        }
        guard rect.width >= 4, rect.height >= 4, let clip = state.crop(rect) else { return }
        state.clips.append(clip)
        readContext(of: clip.id, rect: rect)
        withAnimation(Motion.snappy) { state.added.append(rect) }
        if !keepOpen, !NSEvent.modifierFlags.contains(.shift) { finish() }
    }

    /// Reads what the agent should know about a clip (app, window, element, marked window
    /// shot) in the background; `finish` waits for it.
    private func readContext(of id: UUID, rect: CGRect) {
        // The text selection preset has its own window; else the window under the pointer.
        let p = state.preset.flatMap { $0.frames.first?.isSame(as: rect) == true ? $0 : nil } ?? state.probe
        // A dragged rectangle or a stale probe: use the window under the rectangle's centre.
        let inWindow = !p.window.isNull && p.window.contains(CGPoint(x: rect.midX, y: rect.midY))
        guard inWindow, p.pid != 0 else { return }
        // The window must be where it was when the screens froze, or its frame would crop
        // other pixels out of the frozen image.
        if let id = p.windowID {
            guard let then = state.frozenWindows[id], then.isSame(as: p.window) else { return }
        }
        // A page element: read the accessibility path to the web area, then ask the extension.
        let node = p.frames.first?.isSame(as: rect) == true ? p.dom(at: 0) : state.dom(for: rect)
        let element = node != nil ? p.webAreaElement.map(AXRef.init)
            : (p.frames.first?.isSame(as: rect) == true ? p.elements.first ?? nil : state.element(for: rect)).map(AXRef.init)
        // The screen with the selection, so the window image always shows it (a window that
        // spans screens is cut to this one).
        let shot = state.frozenScreen(for: rect)
        pendingContexts += 1
        probe.context({
            var ctx = PickReader.read(pid: p.pid, windowID: p.windowID, windowFrame: p.window, clipFrame: rect,
                                      element: element?.element, subtree: node == nil,
                                      screenshot: shot?.image, screenshotRect: shot?.rect ?? .null)
            if let node, let d = BrowserBridge.shared.describe(node) { ctx.applyPage(d) }
            return ctx
        }) { [weak self] ctx in
            guard let self else { return }
            if let i = self.state.clips.firstIndex(where: { $0.id == id }) { self.state.clips[i].context = ctx }
            self.pendingContexts -= 1
            if self.pendingContexts == 0, let done = self.whenContextsRead { self.whenContextsRead = nil; done() }
        }
    }

    private var pendingContexts = 0
    private var whenContextsRead: (() -> Void)?

    /// Removes a saved clip and stays in clipping mode.
    private func remove(_ index: Int) {
        guard state.added.indices.contains(index), state.clips.indices.contains(index) else { return }
        withAnimation(Motion.snappy) {
            state.added.remove(at: index)
            state.clips.remove(at: index)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if select == nil { NSCursor.unhide() } else { leaveSelect() }
        withAnimation(select == nil ? Motion.close : Motion.hold) { state.active = false }
        Task { [windows] in
            try? await Task.sleep(for: .milliseconds(220))
            for w in windows { w.orderOut(nil) }
        }
        let deliver = { [self] in
            guard let select else { onFinish(state.clips, state.depth); return }
            let comment = state.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if let steer = sending, let clip = state.clips.first {
                select.onEnd(.send(clip, comment: comment, steer: steer, to: sendTo))
            } else {
                select.onEnd(unsent ? .unsent(comment: comment) : released ? .released : .cancelled)
            }
        }
        if pendingContexts == 0 { deliver() } else {
            whenContextsRead = deliver
            // An app that stops answering must not hold the clips back: send them without
            // the context still missing after a second.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let done = self.whenContextsRead else { return }
                self.whenContextsRead = nil
                done()
            }
        }
    }

    // MARK: Select mode

    /// ⌃⌥ is held in some app. Shows the element under the pointer on the live screen. The app
    /// keeps the focus and the pointer: the overlays let clicks through, and an event tap takes
    /// the scroll (levels) and the left button (the comment). Nil when the tap is not allowed
    /// (no Accessibility).
    static func startSelecting(_ select: Select) -> ClipController? {
        let controller = ClipController(select: select, onFinish: { _, _ in })
        return controller.beginHover() ? controller : nil
    }

    private func beginHover() -> Bool {
        // The tap sees the keys go up in order with the clicks. The hold trigger's events come
        // another way and can pass a click on a busy main thread.
        let events: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel,
                                     .flagsChanged]
        guard let tap = EventTap(events, handler: { [weak self] type, event in self?.tapped(type, event) ?? false })
        else { return false }
        self.tap = tap
        tap.onMissedEvents = { [weak self] in self?.missedEvents() }
        state.phase = .hover
        state.destination = select?.title() ?? ""
        showOverlays(takesMouse: false)
        if Permission.screenRecording.isGranted { shareable = Task { await ScreenCapture.content() } }
        // Text selected in the app in front is the highlight while the pointer is on it. Read
        // off the main thread: the app may not answer.
        probe.selection { [weak self] found in
            guard let self, let found, !self.finished, self.state.phase == .hover else { return }
            self.textSelection = found
            if let p = self.state.pointer { self.hover(p) }
        }
        // One turn later, so the overlays are on screen and the fade has somewhere to start.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            withAnimation(Motion.hold) { self.state.active = true }
        }
        hover(Self.globalMouse())
        return true
    }

    /// The hold trigger says the hold ended: ⌃⌥ went up, or another key or button went down.
    /// Hides select mode, unless the comment field is open: that stays until ⏎ or Esc.
    func holdEnded() {
        guard select != nil, state.phase == .hover, !finished else { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.control), flags.contains(.option) {
            // The keys are still down, so something else was pressed.
            release()
            return
        }
        // The keys went up. The tap gets that in order with a click made just before, so it
        // decides. This is for a tap that macOS turned off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.release() }
    }

    /// Ends the hold, unless a click is under way: then the button going up opens the comment.
    private func release() {
        guard state.phase == .hover, !finished, pressAt == nil, !clicking else { return }
        released = true
        finish()
    }

    /// The tap was off for a moment. A press it holds may have ended unseen, and would keep
    /// `release` from ending the hold: drop it, unless the button is still down (a drag goes
    /// on). The hold ends here if the keys went up too.
    private func missedEvents() {
        guard state.phase == .hover, !finished else { return }
        if pressAt != nil, CGEventSource.buttonState(.combinedSessionState, button: .left) { return }
        pressAt = nil
        state.drag = nil
        let flags = NSEvent.modifierFlags
        if !flags.contains(.control) || !flags.contains(.option) { release() }
    }

    /// An event the tap saw. Returns true to keep it from the app under the pointer.
    private func tapped(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard !finished else { return false }
        // Clicked, and the screens are being captured: keep the button and the scroll from
        // the app until the overlays take them.
        guard state.phase == .hover else { return type != .mouseMoved && type != .flagsChanged }
        let p = event.location
        switch type {
        case .flagsChanged:
            if !event.flags.contains(.maskControl) || !event.flags.contains(.maskAlternate) { release() }
            return false
        case .mouseMoved:
            hover(p)
            return false
        case .leftMouseDown:
            pressAt = p
            return true
        case .leftMouseDragged:
            guard let start = pressAt else { return false }
            state.pointer = p
            if hypot(p.x - start.x, p.y - start.y) > 4 {
                state.drag = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                    width: abs(p.x - start.x), height: abs(p.y - start.y))
            }
            return true
        case .leftMouseUp:
            // A button that went down before select mode showed belongs to the app.
            guard pressAt != nil else { return false }
            pressAt = nil
            if let d = state.drag {
                state.drag = nil
                annotate(d, region: true)
            } else if let h = state.highlight {
                annotate(h, region: false)
            } else {
                // Clicked before the first probe answered: comment on what it finds.
                clicking = true
                probe.probe(at: p) { [weak self] result in
                    guard let self, self.clicking else { return }
                    self.clicking = false
                    guard !self.finished, self.state.phase == .hover else { return }
                    self.state.pointer = p
                    self.state.setProbe(result)
                    if let h = self.state.highlight { self.annotate(h, region: false) }
                    let flags = NSEvent.modifierFlags
                    if !flags.contains(.control) || !flags.contains(.option) { self.release() }
                }
                return true
            }
            // Nothing to comment on, and the keys went up during the click: the hold is over.
            if !event.flags.contains(.maskControl) || !event.flags.contains(.maskAlternate) { release() }
            return true
        case .scrollWheel:
            if state.preset != nil { _ = leavePreset() } else if let e = NSEvent(cgEvent: event) { state.scroll(e) }
            return true
        default:
            return false
        }
    }

    /// The click: the selection stays put and the comment field opens beside it.
    private func annotate(_ rect: CGRect, region: Bool) {
        guard state.phase == .hover, rect.width >= 4, rect.height >= 4 else { return }
        guard Permission.screenRecording.isGranted else {
            unsent = true
            finish()
            return
        }
        navigation += 1 // drops a hover probe that is still on its way
        state.frozenWindows = Self.windowFrames()
        if region { selectRegion(rect) }
        withAnimation(Motion.content) { state.phase = .annotate }
        // Capture before the overlays take the pointer and the keyboard. Until then the app
        // keeps what its hover and focus show (a tooltip, an open menu), so the picture has it.
        Task { [weak self, shareable] in
            let frozen = await ScreenCapture.screens(await shareable?.value)
            guard let self, !self.finished else { return }
            self.state.frozen = frozen
            self.captured = true
            self.takeOver()
            if let steer = self.sendWhenFrozen { self.send(steer: steer) }
        }
        // A slow capture must not keep the comment field waiting.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.takeOver()
        }
    }

    /// The overlays take the pointer and the keyboard for the comment field. T3 Notch does not
    /// become the active app, so the app you were in keeps its look.
    private func takeOver() {
        guard state.phase == .annotate, !finished, let tap else { return }
        tap.stop()
        self.tap = nil
        for w in windows { w.ignoresMouseEvents = false }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.key(e) } ? nil : e
        } as Any)
        // A scroll still changes the level while ⌃⌥ is held, as before the click.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.modifierFlags.isSuperset(of: [.control, .option]), self.state.region == nil else { return }
                if self.state.preset != nil { _ = self.leavePreset() } else { self.state.scroll(e) }
            }
            return nil
        } as Any)
        // Another app took the keyboard (⌘⇥, a dialog): leave, or ⏎ and Esc would go to it.
        // A click on another screen's overlay only moves the keyboard between our windows.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.windows.contains(where: \.isKeyWindow) else { return }
                    self.finish()
                }
            }
        }
        focusComment()
    }

    /// Gives the keyboard to the comment field, on the screen that shows it now.
    private func focusComment() {
        guard state.phase == .annotate, !finished, tap == nil, let screen = state.cardScreen,
              let i = state.screens.firstIndex(of: screen), windows.indices.contains(i) else { return }
        let host = windows[i]
        if !host.isKeyWindow { host.makeKey() }
        keyPanel = host
        // SwiftUI's FocusState is unreliable in a non-activating panel, so focus the field
        // through AppKit once SwiftUI has mounted it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak host] in
            guard let self, !self.finished, let host, host.isKeyWindow,
                  (host.firstResponder as? NSTextView)?.isEditable != true,
                  let field = host.contentView?.firstEditableText, host.makeFirstResponder(field),
                  let editor = host.firstResponder as? NSTextView else { return }
            // A text field selects its text when it takes focus: put the cursor at the end.
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
    }

    /// Keys while the comment field is open. Returns true when the key was used; the others
    /// type into the field.
    private func commentKey(_ e: NSEvent) -> Bool {
        guard state.phase == .annotate, !finished else { return false }
        let editor = keyPanel?.firstResponder as? NSTextView
        // An input method is composing: ⏎ and Esc are its keys.
        if editor?.hasMarkedText() == true { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
        // ⌃ alone, or with ⌥ still held from the click.
        let control = mods == .control || mods == [.control, .option]
        switch Int(e.keyCode) {
        case kVK_Escape:
            finish()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods == .shift {
                editor?.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            guard mods.isEmpty || mods == .command else { return false }
            if sendWhenFrozen == nil { sendTo = select?.target() }
            send(steer: mods == .command)
        case kVK_Tab where mods.subtracting(.shift).isEmpty: // ⇥ / ⇧⇥: the chat it goes to
            guard sendWhenFrozen == nil else { return true } // ⏎ was pressed: the chat is set
            select?.cycle(mods.contains(.shift) ? -1 : 1)
            state.destination = select?.title() ?? ""
        case kVK_ANSI_K where control, kVK_ANSI_P where control: keyboardStep(1)
        case kVK_ANSI_J where control, kVK_ANSI_N where control: keyboardStep(-1)
        case kVK_ANSI_H where control: sibling(-1)
        case kVK_ANSI_L where control: sibling(1)
        default: return false
        }
        return true
    }

    /// A click outside the comment field moves the selection to what is under the pointer.
    /// The comment stays.
    private func repick(at p: CGPoint) {
        guard state.phase == .annotate, !finished else { return }
        navigation += 1
        let generation = navigation
        probe.probe(at: p) { [weak self] result in
            guard let self, self.navigation == generation, !self.finished, !result.frames.isEmpty else { return }
            self.state.region = nil
            self.state.preset = nil
            self.textSelection = nil
            self.state.pointer = p
            self.state.resetLevel()
            self.state.setProbe(result)
        }
    }

    /// A dragged rectangle is the selection. It has no element, so look up its window for the
    /// agent's context.
    private func selectRegion(_ rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }
        navigation += 1
        let generation = navigation
        state.preset = nil
        state.region = rect
        probe.probe(at: CGPoint(x: rect.midX, y: rect.midY)) { [weak self] result in
            guard let self, self.navigation == generation, !self.finished else { return }
            self.state.setProbe(result)
        }
    }

    /// ⏎: crops the selection out of the frozen screen and ends. `finish` waits for what the
    /// agent should know about it.
    private func send(steer: Bool) {
        guard state.phase == .annotate, !finished, let rect = state.selection else { return }
        guard captured else {
            sendWhenFrozen = steer
            return
        }
        if let clip = state.crop(rect) {
            state.clips = [clip]
            readContext(of: clip.id, rect: rect)
            sending = steer
        } else {
            unsent = true
        }
        finish()
    }

    /// Select mode ends: the app gets its scroll, its clicks and its keyboard back.
    private func leaveSelect() {
        tap?.stop()
        tap = nil
        shareable?.cancel()
        for w in windows { w.ignoresMouseEvents = true }
        guard let keyPanel, keyPanel.isKeyWindow else { return }
        keyPanel.resignKey()
        previousApp?.activate()
    }

    /// Every normal window's frame now, by window number.
    private static func windowFrames() -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: CGRect] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let n = w[kCGWindowNumber as String] as? NSNumber,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            out[CGWindowID(n.uint32Value)] = r
        }
        return out
    }

    static func globalMouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: primaryMaxY - p.y)
    }
}

// MARK: - State

@Observable
@MainActor
final class ClipState {
    struct Frozen { let rect: CGRect; let image: CGImage? }

    /// Clip mode, or select mode's two steps: `hover` while ⌃⌥ is held (live screen, no
    /// focus), then `annotate` once a click opened the comment field (frozen screens).
    enum Phase { case clip, hover, annotate }

    var active = false
    var phase = Phase.clip
    var frozen: [Frozen] = []
    /// Every screen's frame, to choose the one that shows the comment field.
    var screens: [CGRect] = []
    /// Select mode: a dragged rectangle is the selection, in place of an element.
    var region: CGRect?
    /// Select mode: the comment being written.
    var comment = ""
    /// Window frames when the screens froze, by window number.
    @ObservationIgnored var frozenWindows: [CGWindowID: CGRect] = [:]
    /// Element frames under the pointer, smallest first, each one different from the others.
    private(set) var chain: [CGRect] = []
    /// The level you want: how many steps up the chain, −1 for the whole window. It is kept
    /// as you move between elements and can be past the end of a short chain; `level` is
    /// the level shown.
    var depth = 0
    /// The element you scrolled to. It stays picked while it is under the pointer, even when
    /// the chain below it gets longer or shorter. None before the first scroll.
    private var anchor: CGRect?
    var drag: CGRect?
    /// Where the pointer is (global), for the dot cursor.
    var pointer: CGPoint?
    var added: [CGRect] = []
    var clips: [Clip] = []
    /// Select mode: the title of the chat the comment goes to ("" for none).
    var destination = ""
    /// Select mode: text selected in the app in front, shown as the highlight while the
    /// pointer is on it.
    var preset: ProbeResult?
    /// A navigation key moved the highlight: it wins over a saved clip under the pointer.
    var navigating = false
    private var scrollAccumulator: CGFloat = 0
    private var scrollThreshold: CGFloat = 40
    @ObservationIgnored private let haptics = ClipHaptics()

    /// The saved clip under the pointer (newest wins), which a click removes.
    var hoveredSaved: Int? {
        guard drag == nil, !navigating, let p = pointer else { return nil }
        return added.lastIndex { $0.contains(p) }
    }

    var highlight: CGRect? {
        if let drag { return drag }
        if let i = hoveredSaved { return added[i] }
        if let region { return region }
        if let r = preset?.frames.first { return r }
        return rect(at: level)
    }

    /// Select mode: what the comment is about. A drag in progress is not it yet, so the
    /// comment field stays where it is until the drag ends.
    var selection: CGRect? {
        region ?? preset?.frames.first ?? rect(at: level)
    }

    /// The screen that shows the comment field: the one the selection is mostly on.
    var cardScreen: CGRect? {
        guard let s = selection else { return nil }
        return screens.max(by: { area($0.intersection(s)) < area($1.intersection(s)) })
    }

    /// The frozen frame of one screen, once it is captured.
    func image(for screen: CGRect) -> CGImage? {
        frozen.first { $0.rect == screen }?.image
    }

    /// Starts again at the element you most likely mean, as before any scroll.
    func resetLevel() {
        anchor = nil
        depth = 0
    }

    /// A short "role · name" label for the highlighted element.
    var highlightLabel: String? {
        guard drag == nil, hoveredSaved == nil, region == nil else { return nil }
        if preset != nil { return "Selected text" }
        guard let h = highlight, let i = chain.firstIndex(where: { $0.isSame(as: h) }) else { return nil }
        return chainLabels[i]
    }

    /// Picks a frame of the chain, as a scroll to it would.
    func anchor(_ frame: CGRect) {
        guard let i = chain.firstIndex(where: { $0.isSame(as: frame) }) else { return }
        anchor = chain[i]
        depth = i
    }

    /// The level shown, always inside the chain: the anchored element while it is under the
    /// pointer, else `depth` clamped to the chain.
    private var level: Int {
        if let anchor, let i = chain.firstIndex(where: { $0.isSame(as: anchor) }) { return i }
        // Before any scroll, start at the element you most likely mean, not the smallest.
        if anchor == nil, depth == 0, let p = preferred { return p }
        return depth < 0 ? -1 : min(depth, max(chain.count - 1, 0))
    }

    private func rect(at level: Int) -> CGRect? {
        level < 0 ? chain.last : chain.indices.contains(level) ? chain[level] : nil
    }

    /// Takes the chain under the pointer. A frame that comes again further out is dropped
    /// (the outer one stays, so the window is always last): each level then looks different.
    func setChain(_ new: [CGRect]) {
        setProbe(ProbeResult(frames: new, elements: new.map { _ in nil }))
    }

    /// The last probe, for the clip's context: the element behind each `chain` frame.
    @ObservationIgnored private(set) var probe = ProbeResult()
    @ObservationIgnored private var chainElements: [AXUIElement?] = []
    @ObservationIgnored private var chainDOM: [DOMNode?] = []
    private var chainLabels: [String?] = []
    /// The chain index of the probe's preferred element, if any.
    private var preferred: Int?

    func setProbe(_ result: ProbeResult) {
        probe = result
        let labels = result.labels.count == result.frames.count ? result.labels : result.frames.map { _ in nil }
        var unique: [(CGRect, AXUIElement?, String?, DOMNode?)] = []
        for (i, r) in result.frames.enumerated().reversed() where !unique.contains(where: { $0.0.isSame(as: r) }) {
            unique.append((r, result.elements.indices.contains(i) ? result.elements[i] : nil, labels[i], result.dom(at: i)))
        }
        unique.reverse()
        chain = unique.map(\.0)
        chainElements = unique.map(\.1)
        chainLabels = unique.map(\.2)
        chainDOM = unique.map(\.3)
        preferred = result.preferred.flatMap { p in
            result.frames.indices.contains(p) ? chain.firstIndex(where: { $0.isSame(as: result.frames[p]) }) : nil
        }
    }

    /// The element behind a highlighted frame, if it came from the accessibility tree.
    func element(for rect: CGRect) -> AXUIElement? {
        guard let i = chain.firstIndex(where: { $0.isSame(as: rect) }) else { return nil }
        return chainElements[i]
    }

    /// The page element behind a highlighted frame, if the browser extension found it.
    func dom(for rect: CGRect) -> DOMNode? {
        guard let i = chain.firstIndex(where: { $0.isSame(as: rect) }) else { return nil }
        return chainDOM[i]
    }

    /// The frozen screen a rect is mostly on.
    func frozenScreen(for rect: CGRect) -> Frozen? {
        frozen.max(by: { area($0.rect.intersection(rect)) < area($1.rect.intersection(rect)) })
    }

    /// A mouse wheel moves one level per tick. A trackpad moves one level after 16pt of
    /// travel and then one per 40pt, so a short swipe always counts and a long one does not
    /// skip levels. Its momentum is ignored.
    func scroll(_ e: NSEvent) {
        guard e.hasPreciseScrollingDeltas else {
            if e.scrollingDeltaY != 0 { step(e.scrollingDeltaY > 0 ? 1 : -1) }
            return
        }
        guard e.momentumPhase.isEmpty else { return }
        if e.phase == .began {
            scrollAccumulator = 0
            scrollThreshold = 16
        }
        let delta = e.scrollingDeltaY
        guard delta != 0 else { return }
        // A turn starts from zero: travel the other way must not cancel it. Devices that
        // send no phases never get the reset above.
        if (delta > 0) != (scrollAccumulator > 0) { scrollAccumulator = 0 }
        scrollAccumulator += delta
        guard abs(scrollAccumulator) >= scrollThreshold else { return }
        step(scrollAccumulator > 0 ? 1 : -1)
        scrollAccumulator = 0
        scrollThreshold = 40
    }

    /// Moves the highlight one level up (+1) or down (−1) from the level shown. Levels: −1
    /// is the window (its own level, below the smallest element), then 0 … top from the
    /// smallest element outwards. Scrolling stops at both ends, and at a level that would
    /// show the same frame (−1 and top are both the window).
    func step(_ step: Int) {
        guard step != 0, !chain.isEmpty else { return }
        let current = level
        let target = min(max(current + step, -1), chain.count - 1)
        guard let now = rect(at: current), let next = rect(at: target), !next.isSame(as: now) else {
            haptics.limit(step > 0 ? .top : .bottom)
            return
        }
        depth = target
        // An element you scroll to stays picked while it is under the pointer. Level −1 means
        // "the window" wherever you point; before any scroll, level 0 is the smallest element.
        anchor = target >= 0 ? next : nil
        haptics.step(depth: target)
    }

    /// Crops a global rect out of the frozen frame of the screen it is mostly on.
    func crop(_ rect: CGRect) -> Clip? {
        guard let f = frozen.max(by: { area($0.rect.intersection(rect)) < area($1.rect.intersection(rect)) }),
              let image = f.image else { return nil }
        let r = rect.intersection(f.rect)
        guard !r.isNull, r.width >= 2, r.height >= 2 else { return nil }
        let scale = CGFloat(image.width) / f.rect.width
        let px = CGRect(x: (r.minX - f.rect.minX) * scale, y: (r.minY - f.rect.minY) * scale,
                        width: r.width * scale, height: r.height * scale).integral
        guard let cropped = image.cropping(to: px),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]),
              png.count <= 10 * 1024 * 1024 else { return nil }
        let thumb = NSImage(cgImage: cropped, size: NSSize(width: r.width, height: r.height))
        return Clip(png: png, thumbnail: thumb)
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

extension CGRect {
    /// True when the two frames look the same on screen (less than 2pt apart on each side).
    func isSame(as o: CGRect) -> Bool {
        abs(minX - o.minX) < 2 && abs(minY - o.minY) < 2 && abs(width - o.width) < 2 && abs(height - o.height) < 2
    }
}

// MARK: - Haptics

/// Trackpad feedback for level changes: a light tap per level, and a stronger one when a
/// scroll reaches the top or bottom level. The stronger one comes once per reach, and again
/// only after a step away. Each one is logged (category "haptics"), so `log stream` shows
/// them on a Mac with no trackpad.
@MainActor
final class ClipHaptics {
    enum Edge: String { case top, bottom }

    private let perform: (NSHapticFeedbackManager.FeedbackPattern) -> Void
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.t3notch.app", category: "haptics")
    private var atLimit: Edge?

    init(perform: @escaping (NSHapticFeedbackManager.FeedbackPattern) -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform($0, performanceTime: .now)
    }) {
        self.perform = perform
    }

    func step(depth: Int) {
        atLimit = nil
        perform(.alignment)
        log.notice("haptic step depth=\(depth, privacy: .public)")
    }

    func limit(_ edge: Edge) {
        guard atLimit != edge else { return }
        atLimit = edge
        perform(.levelChange)
        log.notice("haptic limit \(edge.rawValue, privacy: .public)")
    }
}

// MARK: - Element probe

/// What is under the pointer: the window and the element chain, smallest first.
struct ProbeResult: @unchecked Sendable {
    var pid: pid_t = 0
    var windowID: CGWindowID?
    var window: CGRect = .null
    /// Frames, smallest first; the window is last.
    var frames: [CGRect] = []
    /// The element behind each frame (nil for the window entry added at the end).
    var elements: [AXUIElement?] = []
    /// A "role · name" label per frame.
    var labels: [String?] = []
    /// The index of the frame you most likely mean (see `ElementProbe.preferredIndex`).
    var preferred: Int?
    /// The page element behind each frame, when the browser extension answered (else empty
    /// or nil entries). Page elements come first, then the accessibility chain from the web
    /// area up.
    var dom: [DOMNode?] = []
    /// The page's web area (its viewport) in global points, when the chain has one.
    var webArea: CGRect = .null
    /// The web area's element and the page URL, found while building the chain.
    var webAreaElement: AXUIElement?

    /// The page element behind a frame index, if any.
    func dom(at i: Int) -> DOMNode? { dom.indices.contains(i) ? dom[i] : nil }

    /// This chain with the page part replaced by `page`, which the extension found.
    func merging(_ page: BrowserBridge.Chain) -> ProbeResult {
        var r = self
        // Keep the accessibility chain from the web area outwards; drop what was inside it.
        let tail = frames.indices.filter { dom(at: $0) == nil && frames[$0].contains(webArea.insetBy(dx: 2, dy: 2)) }
        let start = tail.first ?? frames.count
        r.frames = page.frames + frames[start...]
        r.elements = page.frames.map { _ in nil } + elements[start...]
        r.labels = page.labels.map { Optional($0) } + (labels.count == frames.count ? Array(labels[start...]) : frames[start...].map { _ in nil })
        r.dom = page.nodes.map { Optional($0) } + frames[start...].map { _ in nil }
        r.preferred = page.preferred ?? 0
        return r
    }
}

/// Finds the UI element under a point and its ancestors' frames, off the main thread.
/// Calls coalesce: while one runs, only the newest point is kept.
final class ElementProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "t3notch.element-probe", qos: .userInteractive)
    private let lock = NSLock()
    private var running = false
    private var next: (CGPoint, @MainActor (ProbeResult) -> Void)?
    private var manualAccessibilityPids = Set<pid_t>() // only touched on `queue`
    /// Apps that did not answer in time, and until when they get no second try. Only touched on `queue`.
    private var slowUntil: [pid_t: Date] = [:]
    private let me = ProcessInfo.processInfo.processIdentifier

    func probe(at point: CGPoint, _ done: @escaping @MainActor (ProbeResult) -> Void) {
        lock.lock()
        next = (point, done) // replaces any point not yet probed
        let start = !running
        running = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let (p, callback) = next else { running = false; lock.unlock(); return }
                next = nil
                lock.unlock()
                let chain = chainAt(p)
                DispatchQueue.main.async { MainActor.assumeIsolated { callback(chain) } }
            }
        }
    }

    /// Reads a clip's context on the probe queue, so it never races a probe of the same app.
    func context(_ make: @escaping @Sendable () -> PickContext, _ done: @escaping @MainActor (PickContext) -> Void) {
        queue.async {
            let ctx = make()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ctx) } }
        }
    }

    /// The chain from `element` up to the window, on the probe queue.
    func chain(for element: AXUIElement, pid: pid_t, windowID: CGWindowID?, window: CGRect,
               _ done: @escaping @MainActor (ProbeResult) -> Void) {
        let ref = AXRef(element: element)
        queue.async { [self] in
            AXUIElementSetMessagingTimeout(ref.element, 0.08)
            let result = chain(from: ref.element, pid: pid, windowID: windowID, window: window)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// The front app's text selection (see `selectionNow`), read on the probe queue.
    func selection(_ done: @escaping @MainActor (ProbeResult?) -> Void) {
        queue.async {
            let result = Self.selectionNow()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// Finds the previous or next sibling of `element` with a usable frame, and its chain.
    func sibling(of element: AXUIElement, direction: Int, pid: pid_t, windowID: CGWindowID?, window: CGRect,
                 _ done: @escaping @MainActor (ProbeResult?) -> Void) {
        let ref = AXRef(element: element)
        queue.async { [self] in
            let result = siblingChain(of: ref.element, direction: direction, pid: pid, windowID: windowID, window: window)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    private func siblingChain(of element: AXUIElement, direction: Int, pid: pid_t, windowID: CGWindowID?,
                              window: CGRect) -> ProbeResult? {
        var parent: CFTypeRef?, children: CFTypeRef?
        // One key press, not a stream of hovers: a busy app gets more time to answer.
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let par = parent, CFGetTypeID(par) == AXUIElementGetTypeID(),
              { AXUIElementSetMessagingTimeout(par as! AXUIElement, 0.3); return true }(),
              AXUIElementCopyAttributeValue(par as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement],
              let start = list.firstIndex(where: { CFEqual($0, element) }) else { return nil }
        var i = start + direction
        while list.indices.contains(i) {
            AXUIElementSetMessagingTimeout(list[i], 0.08)
            if let f = Self.frame(of: list[i])?.intersection(window), !f.isNull, f.width >= 16, f.height >= 12 {
                return chain(from: list[i], pid: pid, windowID: windowID, window: window)
            }
            i += direction
        }
        return nil
    }

    private func chainAt(_ p: CGPoint) -> ProbeResult {
        guard let (pid, windowID, window) = windowAt(p) else { return ProbeResult() }
        let result = ProbeResult(pid: pid, windowID: windowID, window: window, frames: [window], elements: [nil], labels: [nil])
        guard AXIsProcessTrusted() else { return result }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        if !manualAccessibilityPids.contains(pid) {
            // Electron apps only build their element tree when asked for it.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAccessibilityPids.insert(pid)
        }
        var hit: AXUIElement?
        var error = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit)
        if error == .cannotComplete, slowUntil[pid].map({ $0 < Date() }) ?? true {
            // The first answer of an app can take longer than the timeout. Ask once more with
            // more time, so a still pointer does not stay on the window. An app that is still
            // silent gets no second try for a moment: the highlight must not lag behind it.
            AXUIElementSetMessagingTimeout(app, 0.3)
            error = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit)
            slowUntil[pid] = error == .cannotComplete ? Date().addingTimeInterval(2) : nil
        }
        guard error == .success, let element = hit else { return result }
        return withPage(chain(from: element, pid: pid, windowID: windowID, window: window), at: p)
    }

    /// The element and its ancestors up to the window, smallest first, with labels and the
    /// preferred level.
    private func chain(from start: AXUIElement, pid: pid_t, windowID: CGWindowID?, window: CGRect) -> ProbeResult {
        var element = start
        var frames: [CGRect] = []
        var elements: [AXUIElement?] = []
        var info: [ElementInfo] = []
        var webArea: (AXUIElement, CGRect)?
        for _ in 0..<14 {
            let role = Self.string(element, kAXRoleAttribute)
            if role == "AXWebArea", webArea == nil, let f = Self.frame(of: element) { webArea = (element, f) }
            if let f = Self.frame(of: element) {
                let r = f.intersection(window)
                if !r.isNull, r.width >= 16, r.height >= 12,
                   frames.last.map({ !$0.isSame(as: r) }) ?? true {
                    frames.append(r)
                    elements.append(element)
                    info.append(ElementInfo(role: role, roleDescription: Self.string(element, kAXRoleDescriptionAttribute),
                                            name: Self.name(of: element)))
                }
            }
            if role == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            element = next as! AXUIElement
        }
        var labels = info.map(\.label)
        let preferred = Self.preferredIndex(info, frames: frames, window: window)
        if frames.last.map({ !$0.isSame(as: window) }) ?? true {
            frames.append(window); elements.append(nil); labels.append("Window")
        }
        var result = ProbeResult(pid: pid, windowID: windowID, window: window, frames: frames, elements: elements,
                                 labels: labels, preferred: preferred)
        if let (e, f) = webArea {
            result.webAreaElement = e
            result.webArea = f.intersection(window)
        }
        return result
    }

    /// Asks the browser extension for the page elements under `p`, when the chain is in a web
    /// page and a browser is connected. Falls back to the accessibility chain.
    private func withPage(_ result: ProbeResult, at p: CGPoint) -> ProbeResult {
        guard let area = result.webAreaElement, !result.webArea.isNull, result.webArea.contains(p),
              BrowserBridge.shared.isConnected,
              let url = PickReader.urlValue(area, kAXURLAttribute),
              let page = BrowserBridge.shared.hit(at: p, area: result.webArea, window: result.window, url: url)
        else { return result }
        return result.merging(page)
    }

    /// The previous (−1) or next (+1) sibling of a page element, with the rest of `base`'s
    /// chain from the web area out.
    func domSibling(of node: DOMNode, direction: Int, base: ProbeResult, _ done: @escaping @MainActor (ProbeResult?) -> Void) {
        queue.async {
            let page = BrowserBridge.shared.sibling(of: node, direction: direction, area: base.webArea)
            let result = page.map { base.merging($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    struct ElementInfo {
        let role: String?
        let roleDescription: String?
        let name: String?

        var label: String? {
            let kind = roleDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            switch (kind, name) {
            case let (k?, n?): return "\(k) · \(n)"
            case let (k?, nil): return k
            case let (nil, n?): return n
            default: return nil
            }
        }
    }

    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXTextField", "AXTextArea", "AXMenuItem",
        "AXPopUpButton", "AXComboBox", "AXSlider", "AXMenuButton", "AXDisclosureTriangle", "AXSearchField",
        "AXTab", "AXCell", "AXRow",
    ]
    static let wrapperRoles: Set<String> = ["AXGroup", "AXUnknown", "AXLayoutItem", "AXSplitGroup", "AXScrollArea"]

    /// The element you most likely mean under the pointer: the nearest control a few levels
    /// up (a click on a button's label means the button), else the smallest element that is
    /// not an unnamed wrapper. Never more than 80% of the window: then the smallest element.
    static func preferredIndex(_ info: [ElementInfo], frames: [CGRect], window: CGRect) -> Int? {
        guard !info.isEmpty else { return nil }
        var pick: Int?
        if let i = info.prefix(4).firstIndex(where: { $0.role.map(controlRoles.contains) ?? false }) {
            pick = i
        } else {
            pick = info.firstIndex { !($0.role.map(wrapperRoles.contains) ?? true) || $0.name != nil }
        }
        guard let i = pick else { return 0 }
        let area = frames[i].width * frames[i].height, windowArea = window.width * window.height
        return windowArea > 0 && area > 0.8 * windowArea ? 0 : i
    }

    /// Text selected in the app in front, as a probe whose first frame is the selection's
    /// bounds. Nil when nothing is selected, the bounds are unknown, or it is a password.
    private static func selectionNow() -> ProbeResult? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let e = f as! AXUIElement
        AXUIElementSetMessagingTimeout(e, 0.1) // a timeout does not carry over from `app`
        guard string(e, kAXRoleAttribute) != "AXSecureTextField", string(e, kAXSubroleAttribute) != "AXSecureTextField",
              let text = string(e, kAXSelectedTextAttribute), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success, let bounds
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.width >= 2, rect.height >= 2 else { return nil }
        let pid = front.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let w = list.first(where: { w in
                  (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0
                      && (w[kCGWindowBounds as String] as? [String: CGFloat])
                          .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }?
                          .contains(CGPoint(x: rect.midX, y: rect.midY)) == true
              }),
              let window = (w[kCGWindowBounds as String] as? [String: CGFloat])
                  .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
        else { return nil }
        // A little air around the text, inside the window.
        let padded = rect.insetBy(dx: -4, dy: -3).intersection(window)
        guard !padded.isNull else { return nil }
        return ProbeResult(pid: pid, windowID: (w[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) },
                           window: window, frames: [padded, window], elements: [e, nil], labels: ["Selected text", "Window"])
    }

    /// The front-most normal window of another app under the point. Windows of background-only
    /// apps are skipped: they are click-through overlays (such as an agent's cursor layer),
    /// never something you work in.
    private func windowAt(_ p: CGPoint) -> (pid_t, CGWindowID?, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy != .prohibited,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p) else { continue }
            return (pid, (w[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }, r)
        }
        return nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// A short name: the title, else the description, else a short text value.
    private static func name(of e: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = string(e, attr)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s.count > 40 ? String(s.prefix(39)) + "…" : s
            }
        }
        return nil
    }
}

// MARK: - Overlay

/// One screen's overlay. Clip mode: the frozen frame, dimmed everywhere except the highlight.
/// Select mode: only the highlight on the live screen while ⌃⌥ is held, then the frozen
/// frame, the dim and the comment field once you click.
private struct ClipOverlayView: View {
    let state: ClipState
    let screenRect: CGRect
    let onHover: (CGPoint) -> Void
    let onAdd: (CGRect) -> Void
    let onRemove: (Int) -> Void
    /// Select mode: a click outside the comment field.
    let onClick: (CGPoint) -> Void
    /// Select mode: the comment field is on this screen now.
    let onCommentShown: () -> Void
    @State private var cardSize = CGSize(width: CommentCard.width, height: 64)
    /// A press that started on the comment card is not a pick.
    @State private var pressOnCard: Bool?

    var body: some View {
        let highlight = state.highlight.map(local)
        let selecting = state.phase != .clip
        ZStack(alignment: .topLeading) {
            if let image = state.image(for: screenRect) {
                Image(decorative: image, scale: CGFloat(image.width) / screenRect.width)
                    .resizable()
                    .frame(width: screenRect.width, height: screenRect.height)
            }
            // Dim with a hole where the highlight is. Not while ⌃⌥ is only held: the screen
            // is live then, and nothing but the highlight shows.
            Rectangle().fill(.black.opacity(state.active && state.phase != .hover ? 0.38 : 0))
                .overlay(alignment: .topLeading) {
                    if let h = highlight {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .frame(width: h.width, height: h.height)
                            .offset(x: h.minX, y: h.minY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            ForEach(Array(state.added.enumerated()), id: \.offset) { _, r in
                let l = local(r)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(white: 0.55), lineWidth: 2) // darker than the live selection
                    .frame(width: l.width, height: l.height)
                    .offset(x: l.minX, y: l.minY)
                    .transition(.opacity.combined(with: .scale(1.04)))
            }
            // Clip mode's pointer: a small white dot that morphs into the selection outline
            // when an element is under it or a drag starts, and back to a dot when nothing is.
            // Select mode keeps the real pointer and outlines in the accent colour, with a
            // tint while the screen is live, so the outline shows on any background.
            if state.active, let shape = highlight ?? (selecting ? nil : state.pointer.map({ p in
                let l = local(CGRect(origin: p, size: .zero))
                return CGRect(x: l.minX - 6, y: l.minY - 6, width: 12, height: 12)
            })) {
                let isDot = highlight == nil
                let fill = selecting ? Color.accentColor.opacity(state.phase == .hover ? 0.08 : 0) : .white.opacity(isDot ? 0.95 : 0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selecting ? Color.accentColor : .white.opacity(0.9), lineWidth: selecting ? 2 : 1.5))
                    .shadow(color: .black.opacity(isDot || selecting ? 0.35 : 0), radius: 2)
                    .frame(width: shape.width, height: shape.height)
                    .offset(x: shape.minX, y: shape.minY)
                    .allowsHitTesting(false)
            }
            // What the highlight is, just above it (or inside, at the top of the screen).
            if state.active, let h = highlight, let label = state.highlightLabel {
                Text(label)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.72), in: .capsule)
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(x: max(h.minX, 4), y: Self.labelIsAbove(h) ? h.minY - 22 : h.minY + 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if state.active, let i = state.hoveredSaved {
                let l = local(state.added[i])
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: .circle)
                    .position(x: l.midX, y: l.midY)
                    .allowsHitTesting(false)
                    .transition(.blurReplace.combined(with: .scale(0.6)))
            }
            // Select mode's comment field, beside the selection, on the screen it is mostly on.
            if state.active, state.phase == .annotate, state.cardScreen == screenRect, let card = cardFrame {
                CommentCard(state: state)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { cardSize = $0 }
                    .offset(x: card.minX, y: card.minY)
                    .onAppear(perform: onCommentShown)
                    .transition(.opacity.combined(with: .scale(0.96)))
            }
        }
        .frame(width: screenRect.width, height: screenRect.height, alignment: .topLeading)
        .animation(Motion.select, value: state.highlight)
        .animation(Motion.select, value: state.selection) // the comment field moves with it
        .animation(Motion.snappy, value: state.hoveredSaved)
        .animation(selecting ? Motion.hold : Motion.content, value: state.active)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase, state.drag == nil { onHover(global(p)) }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if pressOnCard == nil { pressOnCard = cardFrame?.insetBy(dx: -4, dy: -4).contains(v.startLocation) ?? false }
                    guard pressOnCard == false else { return }
                    let start = global(v.startLocation), now = global(v.location)
                    state.pointer = now
                    if hypot(now.x - start.x, now.y - start.y) > 4 {
                        state.drag = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                            width: abs(now.x - start.x), height: abs(now.y - start.y))
                    }
                }
                .onEnded { v in
                    defer { pressOnCard = nil }
                    guard pressOnCard == false else { return }
                    if let d = state.drag {
                        state.drag = nil
                        onAdd(d)
                    } else if state.phase == .annotate {
                        onClick(global(v.location)) // a click moves the selection
                    } else if let i = state.hoveredSaved {
                        onRemove(i) // a click on a saved clip removes it
                    } else if let h = state.highlight {
                        onAdd(h) // a click adds the highlighted element
                    }
                    onHover(global(v.location))
                }
        )
        .ignoresSafeArea()
    }

    /// The label sits above the highlight when there is room, else inside its top edge.
    private static func labelIsAbove(_ highlight: CGRect) -> Bool { highlight.minY >= 24 }

    /// Where the comment card is on this screen, while it shows here.
    private var cardFrame: CGRect? {
        guard state.phase == .annotate, state.cardScreen == screenRect, let h = state.selection.map(local) else { return nil }
        // Room for the label above an element, whether or not it shows during a drag.
        let clear: CGFloat = state.region == nil && Self.labelIsAbove(h) ? 24 : 0
        return CGRect(origin: CommentPlacement.origin(card: cardSize, beside: h, in: screenRect.size, clearAbove: clear),
                      size: cardSize)
    }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -screenRect.minX, dy: -screenRect.minY)
    }

    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + screenRect.minX, y: p.y + screenRect.minY)
    }
}
