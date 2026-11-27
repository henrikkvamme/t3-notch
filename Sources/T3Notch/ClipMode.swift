import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI
import os

/// A screen region added as context: the cropped PNG plus a thumbnail for the island.
struct Clip: Identifiable, Equatable {
    let id = UUID()
    let png: Data
    let thumbnail: NSImage

    static func == (a: Clip, b: Clip) -> Bool { a.id == b.id }
}

// MARK: - Clipping mode

/// ⌘P from the open island. Freezes every screen, then lets you hover to pick a UI element
/// (Accessibility) or drag a rectangle. Releasing adds the clip and returns to the island;
/// with ⇧ held it stays for more. Esc, ⏎ or ⌘P leave without adding.
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

    private init(onFinish: @escaping ([Clip], Int) -> Void) {
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

    private func begin() async {
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
            let cmd = e.modifierFlags.contains(.command)
            // Esc, ⏎ or ⌘P end the mode.
            if e.keyCode == 53 || e.keyCode == 36 || (cmd && e.keyCode == 35) {
                MainActor.assumeIsolated { self.finish() }
                return nil
            }
            return e
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

    private func hover(_ p: CGPoint) {
        guard !Store.demo else { return } // the demo script drives the pointer
        state.pointer = p
        probe.probe(at: p) { [weak self] chain in
            self?.state.setChain(chain)
        }
    }

    /// Adds a clip. Releasing returns to the island with it straight away; holding ⇧ while
    /// releasing keeps clipping, so the next release without ⇧ brings them all back.
    private func add(_ rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4, let clip = state.crop(rect) else { return }
        state.clips.append(clip)
        withAnimation(Motion.snappy) { state.added.append(rect) }
        if !NSEvent.modifierFlags.contains(.shift) { finish() }
    }

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
        let clips = state.clips
        Task { [windows] in
            try? await Task.sleep(for: .milliseconds(220))
            for w in windows { w.orderOut(nil) }
        }
        onFinish(clips, state.depth)
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
        return rect(at: level)
    }

    /// The level shown, always inside the chain: the anchored element while it is under the
    /// pointer, else `depth` clamped to the chain.
    private var level: Int {
        if let anchor, let i = chain.firstIndex(where: { $0.isSame(as: anchor) }) { return i }
        return depth < 0 ? -1 : min(depth, max(chain.count - 1, 0))
    }

    private func rect(at level: Int) -> CGRect? {
        level < 0 ? chain.last : chain.indices.contains(level) ? chain[level] : nil
    }

    /// Takes the chain under the pointer. A frame that comes again further out is dropped
    /// (the outer one stays, so the window is always last): each level then looks different.
    func setChain(_ new: [CGRect]) {
        var unique: [CGRect] = []
        for r in new.reversed() where !unique.contains(where: { $0.isSame(as: r) }) { unique.append(r) }
        chain = unique.reversed()
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
    fileprivate func isSame(as o: CGRect) -> Bool {
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

/// Finds the UI element under a point and its ancestors' frames, off the main thread.
/// Calls coalesce: while one runs, only the newest point is kept.
final class ElementProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "t3notch.element-probe", qos: .userInteractive)
    private let lock = NSLock()
    private var running = false
    private var next: (CGPoint, @MainActor ([CGRect]) -> Void)?
    private var manualAccessibilityPids = Set<pid_t>() // only touched on `queue`
    private let me = ProcessInfo.processInfo.processIdentifier

    func probe(at point: CGPoint, _ done: @escaping @MainActor ([CGRect]) -> Void) {
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

    private func chainAt(_ p: CGPoint) -> [CGRect] {
        guard let (pid, window) = windowAt(p) else { return [] }
        guard AXIsProcessTrusted() else { return [window] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        if !manualAccessibilityPids.contains(pid) {
            // Electron apps only build their element tree when asked for it.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAccessibilityPids.insert(pid)
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success,
              var element = hit else { return [window] }
        var frames: [CGRect] = []
        for _ in 0..<14 {
            if let f = Self.frame(of: element) {
                let r = f.intersection(window)
                if !r.isNull, r.width >= 16, r.height >= 12,
                   frames.last.map({ !$0.isSame(as: r) }) ?? true {
                    frames.append(r)
                }
            }
            if Self.role(of: element) == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            element = next as! AXUIElement
        }
        if frames.last.map({ !$0.isSame(as: window) }) ?? true { frames.append(window) }
        return frames
    }

    /// The front-most normal window of another app under the point.
    private func windowAt(_ p: CGPoint) -> (pid_t, CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p) else { continue }
            return (pid, r)
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

    private static func role(of e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
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
