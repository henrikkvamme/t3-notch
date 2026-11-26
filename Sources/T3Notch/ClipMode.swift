import AppKit
import ApplicationServices
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

/// ⌘P from the open island, or a tap of ⌃⌥ from any app (select mode). Freezes every screen,
/// then lets you hover to pick a UI element (Accessibility) or drag a rectangle. Releasing
/// adds the clip and returns to the island; with ⇧ held it stays for more.
///
/// Keys: k or ↑ picks the parent, j or ↓ the child, h and l the previous and next sibling.
/// ⏎ adds the highlight and ends, ⌫ removes the last pick, Esc or ⌘P leave. In select mode,
/// ⇥ and ⇧⇥ change the chat the picks go to.
///
/// Rects are global and top-left-origin (CoreGraphics/Accessibility space) throughout.
@MainActor
final class ClipController {
    private let state = ClipState()
    private var windows: [NotchPanel] = []
    private var monitors: [Any] = []
    private let probe = ElementProbe()
    private let onFinish: ([Clip], Int) -> Void
    private var finished = false
    /// Select mode: where the picks go, which ⇥ changes. Nil for ⌘P from the island.
    private let destination: Destination?
    /// The app in front when select mode started, which gets focus back if nothing is picked.
    private var previousApp: NSRunningApplication?
    /// After h/l the highlight is not under the pointer: keep it until the pointer moves away.
    private var lockedAt: CGPoint?

    struct Destination {
        let title: () -> String?
        let cycle: (Int) -> Void
    }

    private init(destination: Destination?, onFinish: @escaping ([Clip], Int) -> Void) {
        self.destination = destination
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

    static func start(depth: Int, destination: Destination? = nil,
                      onFinish: @escaping ([Clip], Int) -> Void) -> ClipController {
        let controller = ClipController(destination: destination, onFinish: onFinish)
        current = controller
        controller.state.depth = depth
        controller.state.destination = destination?.title() ?? (destination == nil ? nil : "")
        if destination != nil {
            controller.previousApp = NSWorkspace.shared.frontmostApplication
            // Text selected in the app in front is the first highlight, until the pointer moves.
            controller.state.preset = ElementProbe.selection()
            controller.state.presetPointer = globalMouse()
        }
        Task { await controller.begin() }
        return controller
    }

    private func begin() async {
        state.frozenWindows = Self.windowFrames()
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        var shots: [(NSScreen, CGRect, CGImage?)] = []
        for screen in NSScreen.screens {
            let rect = CGRect(x: screen.frame.minX, y: primaryMaxY - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
            let image = try? await SCScreenshotManager.captureImage(in: rect)
            shots.append((screen, rect, image))
        }
        state.frozen = shots.map { ClipState.Frozen(rect: $0.1, image: $0.2) }
        for (screen, rect, image) in shots {
            let panel = NotchPanel()
            panel.level = .screenSaver
            panel.ignoresMouseEvents = false
            panel.setFrame(screen.frame, display: false)
            panel.contentView = FirstClickHostingView(rootView: ClipOverlayView(
                state: state, screenRect: rect, image: image,
                onHover: { [weak self] p in self?.hover(p) },
                onAdd: { [weak self] r in self?.add(r) },
                onRemove: { [weak self] i in self?.remove(i) }))
            panel.orderFrontRegardless()
            windows.append(panel)
        }
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
            MainActor.assumeIsolated { self?.state.scroll(e) }
            return nil
        } as Any)
    }

    /// Handles a key while the mode runs. Returns true when the key was used.
    private func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased()) {
        case (53, _): finish() // Esc
        case (35, _) where mods == .command: finish() // ⌘P
        case (36, _), (76, _): // ⏎ adds the highlight (unless already added) and ends
            if state.hoveredSaved == nil, let h = state.highlight, !state.added.contains(where: { $0.isSame(as: h) }) {
                add(h, keepOpen: true)
            }
            finish()
        case (48, _) where destination != nil: // ⇥ / ⇧⇥: the chat the picks go to
            destination?.cycle(mods.contains(.shift) ? -1 : 1)
            state.destination = destination?.title() ?? ""
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

    private func keyboardStep(_ step: Int) {
        state.preset = nil
        state.step(step)
    }

    /// Moves the highlight to the previous (−1) or next (+1) sibling of the highlighted
    /// element, and keeps it there until the pointer moves 8pt.
    private func sibling(_ direction: Int) {
        guard let h = state.highlight, let element = state.element(for: h) else { return }
        let p = state.probe
        probe.sibling(of: element, direction: direction, pid: p.pid, windowID: p.windowID, window: p.window) { [weak self] result in
            guard let self, let result, let first = result.frames.first else { return }
            self.state.preset = nil
            self.lockedAt = self.state.pointer
            self.state.setProbe(result)
            self.state.anchor(first)
        }
    }

    private func hover(_ p: CGPoint) {
        guard !Store.demo else { return } // the demo script drives the pointer
        state.pointer = p
        if let start = state.presetPointer, hypot(p.x - start.x, p.y - start.y) > 8 {
            state.preset = nil
            state.presetPointer = nil
        }
        if let locked = lockedAt {
            guard hypot(p.x - locked.x, p.y - locked.y) > 8 else { return }
            lockedAt = nil
        }
        probe.probe(at: p) { [weak self] result in
            guard let self, self.lockedAt == nil else { return }
            self.state.setProbe(result)
        }
    }

    /// Adds a clip. Releasing returns to the island with it straight away; holding ⇧ while
    /// releasing keeps clipping, so the next release without ⇧ brings them all back.
    private func add(_ rect: CGRect, keepOpen: Bool = false) {
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
        let element = (p.frames.first?.isSame(as: rect) == true ? p.elements.first ?? nil : state.element(for: rect))
            .map(AXRef.init)
        // The screen with the selection, so the window image always shows it (a window that
        // spans screens is cut to this one).
        let shot = state.frozenScreen(for: rect)
        pendingContexts += 1
        probe.context({
            PickReader.read(pid: p.pid, windowID: p.windowID, windowFrame: p.window, clipFrame: rect,
                            element: element?.element, screenshot: shot?.image, screenshotRect: shot?.rect ?? .null)
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
        NSCursor.unhide()
        monitors = []
        withAnimation(Motion.close) { state.active = false }
        Task { [windows] in
            try? await Task.sleep(for: .milliseconds(220))
            for w in windows { w.orderOut(nil) }
        }
        // Select mode with nothing picked: give focus back to the app it started in.
        if destination != nil, state.clips.isEmpty { previousApp?.activate() }
        let deliver = { [self] in onFinish(state.clips, state.depth) }
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

    var active = false
    var frozen: [Frozen] = []
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
    /// Select mode: the title of the chat the picks go to ("" for none). Nil in ⌘P clip mode.
    var destination: String?
    /// Text selected when select mode started: shown as the highlight until the pointer moves.
    var preset: ProbeResult?
    @ObservationIgnored var presetPointer: CGPoint?
    private var scrollAccumulator: CGFloat = 0
    private var scrollThreshold: CGFloat = 40
    @ObservationIgnored private let haptics = ClipHaptics()

    /// The saved clip under the pointer (newest wins), which a click removes.
    var hoveredSaved: Int? {
        guard drag == nil, let p = pointer else { return nil }
        return added.lastIndex { $0.contains(p) }
    }

    var highlight: CGRect? {
        if let drag { return drag }
        if let i = hoveredSaved { return added[i] }
        if let r = preset?.frames.first { return r }
        return rect(at: level)
    }

    /// A short "role · name" label for the highlighted element.
    var highlightLabel: String? {
        guard drag == nil, hoveredSaved == nil else { return nil }
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
    private var chainLabels: [String?] = []
    /// The chain index of the probe's preferred element, if any.
    private var preferred: Int?

    func setProbe(_ result: ProbeResult) {
        probe = result
        let labels = result.labels.count == result.frames.count ? result.labels : result.frames.map { _ in nil }
        var unique: [(CGRect, AXUIElement?, String?)] = []
        for (i, r) in result.frames.enumerated().reversed() where !unique.contains(where: { $0.0.isSame(as: r) }) {
            unique.append((r, result.elements.indices.contains(i) ? result.elements[i] : nil, labels[i]))
        }
        unique.reverse()
        chain = unique.map(\.0)
        chainElements = unique.map(\.1)
        chainLabels = unique.map(\.2)
        preferred = result.preferred.flatMap { p in
            result.frames.indices.contains(p) ? chain.firstIndex(where: { $0.isSame(as: result.frames[p]) }) : nil
        }
    }

    /// The element behind a highlighted frame, if it came from the accessibility tree.
    func element(for rect: CGRect) -> AXUIElement? {
        guard let i = chain.firstIndex(where: { $0.isSame(as: rect) }) else { return nil }
        return chainElements[i]
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
}

/// Finds the UI element under a point and its ancestors' frames, off the main thread.
/// Calls coalesce: while one runs, only the newest point is kept.
final class ElementProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "t3notch.element-probe", qos: .userInteractive)
    private let lock = NSLock()
    private var running = false
    private var next: (CGPoint, @MainActor (ProbeResult) -> Void)?
    private var manualAccessibilityPids = Set<pid_t>() // only touched on `queue`
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
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let par = parent, CFGetTypeID(par) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(par as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement],
              let start = list.firstIndex(where: { CFEqual($0, element) }) else { return nil }
        var i = start + direction
        while list.indices.contains(i) {
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
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              let element = hit else { return result }
        return chain(from: element, pid: pid, windowID: windowID, window: window)
    }

    /// The element and its ancestors up to the window, smallest first, with labels and the
    /// preferred level.
    private func chain(from start: AXUIElement, pid: pid_t, windowID: CGWindowID?, window: CGRect) -> ProbeResult {
        var element = start
        var frames: [CGRect] = []
        var elements: [AXUIElement?] = []
        var info: [ElementInfo] = []
        for _ in 0..<14 {
            let role = Self.string(element, kAXRoleAttribute)
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
        return ProbeResult(pid: pid, windowID: windowID, window: window, frames: frames, elements: elements,
                           labels: labels, preferred: preferred)
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
    static func selection() -> ProbeResult? {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var focused: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let e = f as! AXUIElement
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

    /// The front-most normal window of another app under the point.
    private func windowAt(_ p: CGPoint) -> (pid_t, CGWindowID?, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
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

/// One screen's overlay: the frozen frame, dimmed everywhere except the highlight.
private struct ClipOverlayView: View {
    let state: ClipState
    let screenRect: CGRect
    let image: CGImage?
    let onHover: (CGPoint) -> Void
    let onAdd: (CGRect) -> Void
    let onRemove: (Int) -> Void

    var body: some View {
        let highlight = state.highlight.map(local)
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: CGFloat(image.width) / screenRect.width)
                    .resizable()
                    .frame(width: screenRect.width, height: screenRect.height)
            }
            // Dim with a hole where the highlight is.
            Rectangle().fill(.black.opacity(state.active ? 0.38 : 0))
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
            // The pointer: a small white dot that morphs into the selection outline when an
            // element is under it or a drag starts, and back to a dot when nothing is.
            if state.active, let shape = highlight ?? state.pointer.map({ p in
                let l = local(CGRect(origin: p, size: .zero))
                return CGRect(x: l.minX - 6, y: l.minY - 6, width: 12, height: 12)
            }) {
                let isDot = highlight == nil
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(isDot ? 0.95 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(isDot ? 0.35 : 0), radius: 2)
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
                    .offset(x: max(h.minX, 4), y: h.minY >= 24 ? h.minY - 22 : h.minY + 4)
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
        }
        .overlay(alignment: .bottom) {
            // Select mode: where the picks go, and the keys. On the screen with the pointer.
            if state.active, let title = state.destination,
               let p = state.pointer, screenRect.contains(p) {
                SelectHint(title: title, picks: state.added.count)
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: screenRect.width, height: screenRect.height, alignment: .topLeading)
        .animation(Motion.select, value: state.highlight)
        .animation(Motion.snappy, value: state.hoveredSaved)
        .animation(Motion.content, value: state.active)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase, state.drag == nil { onHover(global(p)) }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    let start = global(v.startLocation), now = global(v.location)
                    state.pointer = now
                    if hypot(now.x - start.x, now.y - start.y) > 4 {
                        state.drag = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                            width: abs(now.x - start.x), height: abs(now.y - start.y))
                    }
                }
                .onEnded { v in
                    if let d = state.drag {
                        state.drag = nil
                        onAdd(d)
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

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -screenRect.minX, dy: -screenRect.minY)
    }

    private func global(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + screenRect.minX, y: p.y + screenRect.minY)
    }
}

/// Select mode's bar: the chat the picks go to, and the keys.
private struct SelectHint: View {
    let title: String
    let picks: Int

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text(title.isEmpty ? "No chat" : title).fontWeight(.semibold).lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                if picks > 0 { Text("\(picks)").monospacedDigit().foregroundStyle(.secondary) }
            }
            Text("⇥ chat   j k level   h l sibling   ⏎ add   ⇧ click more   esc")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }
}
