import AppKit
import ApplicationServices

/// T3's own message field, read and written through Accessibility. T3 keeps a chat's draft in
/// its window only (`apps/web/src/composerDraftStore.ts`, in local storage), so no server call
/// reaches it. The field is the text area named "Message <chat title>".
///
/// All calls run on one background queue: an app that hangs must not hold the island.
final class T3Composer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "t3notch.composer", qos: .userInitiated)
    private var cached: AXUIElement?
    private var cachedPid: pid_t = 0

    /// The field's text, or nil when T3's window shows no message field for this chat.
    func read(pid: pid_t, chatTitle: String, _ done: @escaping @MainActor (String?) -> Void) {
        queue.async {
            let text = self.field(pid: pid, chatTitle: chatTitle).flatMap { Self.string($0, kAXValueAttribute) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }

    /// Replaces the field's text. `done` gets the text as the field has it afterwards (its
    /// editor may write line breaks its own way), or nil when T3 did not take it.
    func write(_ text: String, pid: pid_t, chatTitle: String, _ done: @escaping @MainActor (String?) -> Void = { _ in }) {
        queue.async {
            var now: String?
            if let field = self.field(pid: pid, chatTitle: chatTitle),
               AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) == .success {
                now = Self.string(field, kAXValueAttribute)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(now) } }
        }
    }

    /// The message field of the chat with this title. A field for another chat is not it: a
    /// write there would put the text in the wrong chat.
    private func field(pid: pid_t, chatTitle: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if pid != cachedPid { cached = nil; cachedPid = pid }
        func fits(_ e: AXUIElement) -> Bool {
            guard Self.string(e, kAXRoleAttribute) == kAXTextAreaRole as String,
                  let name = Self.string(e, kAXDescriptionAttribute) else { return false }
            return name.hasSuffix(chatTitle) && name.count > chatTitle.count
        }
        if let cached, fits(cached) { return cached }
        cached = nil
        // You are typing there: the field has the keyboard.
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), fits(focused as! AXUIElement) {
            cached = (focused as! AXUIElement)
            return cached
        }
        // Else look for it. It sits at the bottom of the window, so go through the last
        // children first, and give up after a bounded number of elements.
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var stack = [window as! AXUIElement], seen = 0
        while let e = stack.popLast(), seen < 2500 {
            seen += 1
            if fits(e) { cached = e; return e }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list) // popLast takes the last child first
            }
        }
        return nil
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
