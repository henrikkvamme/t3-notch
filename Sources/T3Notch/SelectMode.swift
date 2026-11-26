import AppKit
import ScreenCaptureKit
import SwiftUI

// The parts of select mode that stand on their own: the event tap that takes the scroll and
// the click while ⌃⌥ is held, the capture that leaves the overlay out, and the comment field.
// The mode itself is in `ClipController` (ClipMode.swift), which shares its element picking
// with clip mode.

// MARK: - Event tap

/// Sees the session's mouse events before the app under the pointer does, and can keep them
/// from it. A global `NSEvent` monitor only watches, so the app would scroll and take the
/// ⌃-click (a right click) too.
///
/// It runs on the main run loop and only while select mode shows, so nothing sits in the
/// event path otherwise. It needs Accessibility; without it, `init` returns nil.
@MainActor
final class EventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// Returns true to keep the event from the app.
    fileprivate let handler: (CGEventType, CGEvent) -> Bool
    /// macOS turned the tap off for a moment, so events were missed: a button that went down
    /// may have gone up unseen.
    var onMissedEvents: (() -> Void)?

    init?(_ types: [CGEventType], handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Stops the tap for good. The callback holds no reference, so stop before letting go.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    /// macOS turns a tap off when its callback is slow; turn it on again.
    fileprivate func enable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    isolated deinit { stop() }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // The tap's source is on the main run loop, so this runs on the main thread.
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let refcon = refcon
    let keep = MainActor.assumeIsolated {
        guard let refcon else { return false }
        let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.enable()
            tap.onMissedEvents?()
            return false
        }
        return tap.handler(type, event)
    }
    return keep ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Capture

/// Captures the screens without T3 Notch's own windows, so the overlay that shows while you
/// select is not in the picture.
enum ScreenCapture {
    struct Content: @unchecked Sendable {
        let value: SCShareableContent
    }

    /// What is on screen now. Slow enough (tens of milliseconds) to ask for ahead of time.
    static func content() async -> Content? {
        (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)).map(Content.init)
    }

    /// One frame per screen. `ahead` is content asked for earlier; it must list T3 Notch,
    /// or it is asked for again. An image is nil when its screen could not be captured.
    @MainActor
    static func screens(_ ahead: Content?) async -> [ClipState.Frozen] {
        let me = ProcessInfo.processInfo.processIdentifier
        var found = ahead
        if found?.value.applications.contains(where: { $0.processID == me }) != true { found = await content() }
        guard let content = found?.value else { return [] }
        let mine = content.applications.filter { $0.processID == me }
        var out: [ClipState.Frozen] = []
        for screen in NSScreen.screens {
            let rect = ClipController.globalRect(of: screen)
            var image: CGImage?
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let display = content.displays.first(where: { $0.displayID == id }) {
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                config.showsCursor = false
                image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            out.append(.init(rect: rect, image: image))
        }
        return out
    }
}

// MARK: - Comment field

/// Select mode's comment field: what you write goes to the chat with the selection. It looks
/// like a piece of the island, and shows the chat it goes to.
struct CommentCard: View {
    @Bindable var state: ClipState

    static let width: CGFloat = 320
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Add a comment", text: $state.comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                Text(state.destination.isEmpty ? "No chat" : state.destination).lineLimit(1)
                    .contentTransition(.opacity)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .animation(Motion.snappy, value: state.destination)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(width: Self.width, alignment: .leading)
        .background(.black, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

/// Where the comment card goes: beside the selection, never on it while there is room.
enum CommentPlacement {
    static let gap: CGFloat = 8
    static let margin: CGFloat = 10
    /// Clear of the menu bar and the notch.
    static let top: CGFloat = 40
    /// Room kept for the card at its tallest (six lines), so typing never makes it change sides.
    static let tallest: CGFloat = 168

    /// The card's top-left corner on the screen. Below the selection first, left edges in
    /// line; then above, to the right and to the left; inside the selection's bottom edge
    /// when it fills the screen. `clearAbove` is the room the selection's label takes.
    ///
    /// Below and beside, the card's top edge stays put and it grows downward as you type.
    /// Above and inside, its bottom edge stays put, so it never grows onto the selection.
    static func origin(card: CGSize, beside s: CGRect, in screen: CGSize, clearAbove: CGFloat) -> CGPoint {
        let tall = max(card.height, tallest)
        let x = min(max(s.minX, margin), screen.width - card.width - margin)
        if s.maxY + gap + tall <= screen.height - margin {
            return CGPoint(x: x, y: s.maxY + gap)
        }
        let bottom = s.minY - clearAbove - gap
        if bottom - tall >= top {
            return CGPoint(x: x, y: bottom - card.height)
        }
        let y = min(max(s.minY, top), screen.height - tall - margin)
        if s.maxX + gap + card.width <= screen.width - margin {
            return CGPoint(x: s.maxX + gap, y: y)
        }
        if s.minX - gap - card.width >= margin {
            return CGPoint(x: s.minX - gap - card.width, y: y)
        }
        return CGPoint(x: min(max(s.midX - card.width / 2, margin), screen.width - card.width - margin),
                       y: min(s.maxY, screen.height) - margin - 2 - card.height)
    }
}
