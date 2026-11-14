import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// A screen region added as context: the cropped PNG plus a thumbnail for the island.
struct Clip: Identifiable, Equatable {
    let id = UUID()
    let png: Data
    let thumbnail: NSImage

    static func == (a: Clip, b: Clip) -> Bool { a.id == b.id }
}

// MARK: - Clipping mode

/// ⌘P from the open island. Freezes every screen, then lets you hover to pick a UI element
/// (Accessibility) or drag a rectangle; each click or drag adds a clip. Esc, ⏎ or ⌘P finish.
///
/// Rects are global and top-left-origin (CoreGraphics/Accessibility space) throughout.
@MainActor
final class ClipController {
    private let state = ClipState()
    private var windows: [NotchPanel] = []
    private var monitors: [Any] = []
    private let probe = ElementProbe()
    private let onFinish: ([Clip]) -> Void
    private var finished = false

    private init(onFinish: @escaping ([Clip]) -> Void) {
        self.onFinish = onFinish
    }

    /// Captures the screens and shows the overlay. Calls `onFinish` with the clips taken
    /// (possibly none) when the mode ends; `onFailure` if capture is not allowed.
    /// Captures the screens and shows the overlay; calls `onFinish` with the clips taken
    /// (possibly none). The caller checks Screen Recording first (see `Permission`).
    static func start(onFinish: @escaping ([Clip]) -> Void) -> ClipController {
        let controller = ClipController(onFinish: onFinish)
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
                onAdd: { [weak self] r in self?.add(r) }))
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
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
            MainActor.assumeIsolated { self?.state.scroll(by: e.scrollingDeltaY) }
            return nil
        } as Any)
    }

    private func hover(_ p: CGPoint) {
        probe.probe(at: p) { [weak self] chain in
            self?.state.setChain(chain)
        }
    }

    private func add(_ rect: CGRect) {
        guard rect.width >= 4, rect.height >= 4, let clip = state.crop(rect) else { return }
        state.clips.append(clip)
        withAnimation(Motion.snappy) { state.added.append(rect) }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        withAnimation(Motion.close) { state.active = false }
        let clips = state.clips
        Task { [windows] in
            try? await Task.sleep(for: .milliseconds(220))
            for w in windows { w.orderOut(nil) }
        }
        onFinish(clips)
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
    /// Element frames under the pointer, smallest first.
    var chain: [CGRect] = []
    /// How many steps up the chain the highlight is.
    var depth = 0
    var drag: CGRect?
    var added: [CGRect] = []
    var clips: [Clip] = []
    private var scrollAccumulator: CGFloat = 0

    var highlight: CGRect? {
        if let drag { return drag }
        guard !chain.isEmpty else { return nil }
        return chain[min(depth, chain.count - 1)]
    }

    func setChain(_ new: [CGRect]) {
        if new.first != chain.first { depth = 0 }
        chain = new
        depth = min(depth, max(chain.count - 1, 0))
    }

    func scroll(by delta: CGFloat) {
        scrollAccumulator += delta
        guard abs(scrollAccumulator) >= 6 else { return }
        let step = scrollAccumulator > 0 ? 1 : -1
        scrollAccumulator = 0
        depth = min(max(depth + step, 0), max(chain.count - 1, 0))
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
                   frames.last.map({ !Self.same($0, r) }) ?? true {
                    frames.append(r)
                }
            }
            if Self.role(of: element) == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            element = next as! AXUIElement
        }
        if frames.last.map({ !Self.same($0, window) }) ?? true { frames.append(window) }
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

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
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
    @State private var dragStart: CGPoint?

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
                    .strokeBorder(.green.opacity(0.9), lineWidth: 2)
                    .frame(width: l.width, height: l.height)
                    .offset(x: l.minX, y: l.minY)
                    .transition(.opacity.combined(with: .scale(1.04)))
            }
            if let h = highlight, state.active {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: h.width, height: h.height)
                    .offset(x: h.minX, y: h.minY)
            }
        }
        .frame(width: screenRect.width, height: screenRect.height, alignment: .topLeading)
        .animation(Motion.select, value: state.highlight)
        .animation(Motion.content, value: state.active)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase, state.drag == nil { onHover(global(p)) }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    let start = global(v.startLocation), now = global(v.location)
                    if hypot(now.x - start.x, now.y - start.y) > 4 {
                        state.drag = CGRect(x: min(start.x, now.x), y: min(start.y, now.y),
                                            width: abs(now.x - start.x), height: abs(now.y - start.y))
                    }
                }
                .onEnded { v in
                    if let d = state.drag {
                        state.drag = nil
                        onAdd(d)
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
