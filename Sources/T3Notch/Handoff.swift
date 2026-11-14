import AppKit
import ApplicationServices

/// Hands the island's clips over to T3's chat box. T3 keeps drafts only inside its window
/// (`apps/web/src/composerDraftStore.ts`), so there is no API for them; but its chat box
/// attaches pasted files, so the clips go in as a paste.
@MainActor
enum Handoff {
    /// Writes the clips to PNG files, puts them on the clipboard, waits until T3 is in front,
    /// and sends ⌘V to T3's process only, so it can never land in another app. The previous
    /// clipboard comes back afterwards. Without Accessibility (needed to send keys), the
    /// files stay on the clipboard to paste by hand.
    static func pasteClips(_ clips: [Clip], into pid: pid_t) {
        guard !clips.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("T3NotchHandoff/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls: [URL] = clips.enumerated().compactMap { i, clip in
            let url = dir.appendingPathComponent("clip-\(i + 1).png")
            return (try? clip.png.write(to: url)) != nil ? url : nil
        }
        guard !urls.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        guard AXIsProcessTrusted() else { return } // leave the files for a manual paste

        Task {
            // Wait for T3 to come forward with the chat open (up to ~2.5s).
            for _ in 0..<25 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(450))
            sendPaste(to: pid)
            try? await Task.sleep(for: .milliseconds(1200))
            restore(saved, to: pasteboard)
        }
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
