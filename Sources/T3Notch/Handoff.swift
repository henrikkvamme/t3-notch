import AppKit
import ApplicationServices

/// Hands the island's clips over to T3's chat box. T3 keeps drafts only inside its window
/// (`apps/web/src/composerDraftStore.ts`), so there is no API for them; but its chat box
/// attaches pasted files, so the clips go in as a paste.
@MainActor
enum Handoff {
    /// Waits until T3 is in front, then pastes each clip as image data with ⌘V sent to T3's
    /// process only, so it can never land in another app. The previous clipboard comes back
    /// afterwards. Without Accessibility (needed to send keys), the first clip is left on the
    /// clipboard to paste by hand. Steps are logged to ~/Library/Logs/T3Notch/handoff.log.
    static func pasteClips(_ clips: [Clip], into pid: pid_t) {
        guard !clips.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let trusted = AXIsProcessTrusted()
        log("handoff: \(clips.count) clip(s) to pid \(pid), accessibility=\(trusted)")
        guard trusted else {
            // Can't send keys: leave the first clip on the clipboard to paste by hand.
            put(clips[0].png, on: pasteboard)
            return
        }
        Task {
            // Wait for T3 to come forward with the chat open (up to ~3s).
            var front = false
            for _ in 0..<30 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { front = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            log("handoff: T3 frontmost=\(front), frontmost now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            try? await Task.sleep(for: .milliseconds(600))
            // One clip per paste, as image data: the same as pasting a copied screenshot.
            for (i, clip) in clips.enumerated() {
                put(clip.png, on: pasteboard)
                let viaMenu = pressPasteMenuItem(of: pid)
                if !viaMenu { sendPaste(to: pid) }
                log("handoff: pasted clip \(i + 1) via \(viaMenu ? "Edit › Paste" : "⌘V")")
                try? await Task.sleep(for: .milliseconds(350))
            }
            try? await Task.sleep(for: .milliseconds(800))
            restore(saved, to: pasteboard)
        }
    }

    private static func put(_ png: Data, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
    }

    private static func log(_ line: String) {
        let url = FrameLog.directory.appendingPathComponent("handoff.log")
        try? FileManager.default.createDirectory(at: FrameLog.directory, withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Presses the app's own Paste menu item, found by its ⌘V shortcut (so any language
    /// works). Returns false if there is no such item.
    private static func pressPasteMenuItem(of pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = element(app, kAXMenuBarAttribute) else { return false }
        for barItem in children(bar) {
            for menu in children(barItem) {
                for item in children(menu) {
                    guard string(item, kAXMenuItemCmdCharAttribute)?.lowercased() == "v",
                          number(item, kAXMenuItemCmdModifiersAttribute) == 0 // 0 = ⌘ only
                    else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func number(_ e: AXUIElement, _ attribute: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    private static func sendPaste(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }

    /// Every item on the clipboard, with each of its types, so it can be put back exactly.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
