import AppKit
import ApplicationServices

// What the agent learns about a clip besides its pixels: the app, the window, the picked
// element and a shot of the whole window with the clip outlined. A crop alone loses where
// the element is and what is around it, so each clip sends both images.
//
// T3 takes the app data as a `SnapShotSource` on the window image (see `source(...)`); it
// shows the app name, window title and element tree to the agent inside an "untrusted
// captured-window data" block. The rest (URL, role path, page element, selected text) goes
// as a T3 `element` context record (see `elementRecord`), which T3 shows as a chip.

/// One element in the accessibility tree, with its frame in global points (top-left origin).
struct PickElement: Sendable {
    var role: String
    var subrole: String?
    var name: String?
    var value: String?
    var description: String?
    var identifier: String?
    var frame: CGRect?
    var selected: Bool?
    var enabled: Bool?
    var children: [PickElement] = []

    /// "AXButton \"Save\"", for the role path.
    var label: String {
        let n = name ?? description ?? identifier
        return n.map { "\(role) \"\(PickContext.clip($0, 60))\"" } ?? role
    }
}

struct PickContext: Sendable {
    var appName: String
    var bundleID: String?
    var appIconPNG: Data?
    var windowTitle: String
    /// The window's frame, global points.
    var windowFrame: CGRect
    /// The clip's frame, global points.
    var clipFrame: CGRect
    /// The page URL when the clip is inside a web view, else the window's document.
    var url: String?
    /// Window down to the element, outermost first. Empty for a dragged rectangle.
    var path: [PickElement] = []
    /// The picked element with part of its subtree.
    var element: PickElement?
    /// Text selected in the app when the clip was taken.
    var selectedText: String?
    var capturedAt = Date()
    /// The window as seen when clipping started, clip outlined, at most 2000 px long.
    var windowPNG: Data?
    /// `windowPNG`'s size in pixels and its pixels per point.
    var windowPixels: CGSize = .zero
    var windowScale: CGFloat = 1
    /// The reader left nodes out (depth, node count, child count or time limit).
    var readTruncated = false
    /// The picked page element, from the browser extension.
    var page: PageElement?

    /// A page element as the browser extension describes it. Text is clipped and the HTML
    /// has no scripts, styles, inline handlers or typed values.
    struct PageElement: Sendable {
        var selector: String
        var tag: String
        var role: String?
        var name: String?
        var text: String?
        var value: String?
        var html: String?
        var attributes: [String: String]
        /// The components around the element, nearest first, and the file and line that made
        /// it. Only a page in development says this (React, Vue, Svelte).
        var components: [String] = []
        var source: String?
    }

    /// Takes the extension's description of the picked page element: the element, the page
    /// URL and the path from the web area down.
    mutating func applyPage(_ d: [String: Any]) {
        guard let selector = d["selector"] as? String, let tag = d["tag"] as? String else { return }
        func str(_ k: String, _ max: Int) -> String? { (d[k] as? String).map { Self.clip($0, max) }.flatMap { $0.isEmpty ? nil : $0 } }
        let attributes = (d["attributes"] as? [String: String] ?? [:]).prefix(30)
            .reduce(into: [String: String]()) { $0[Self.clip($1.key, 60)] = Self.clip($1.value, 200) }
        page = PageElement(selector: Self.clip(selector, 1000), tag: Self.clip(tag, 40), role: str("role", 60),
                           name: str("name", 300), text: str("text", 4000), value: str("value", 2000),
                           html: str("html", 6000), attributes: attributes,
                           components: (d["components"] as? [String] ?? []).prefix(8).map { Self.clip($0, 80) },
                           source: str("source", 500))
        if let u = d["url"] as? String { url = PickReader.sanitize(u) }
        let pick = PickElement(role: page!.role.map { "\(tag)[\($0)]" } ?? tag, name: page!.name, value: page!.value,
                               description: nil, identifier: attributes["id"], frame: clipFrame)
        // `path` ends at the web area here (the pick was read without its subtree).
        let ancestors = (d["path"] as? [String] ?? []).suffix(30).map { PickElement(role: Self.clip($0, 120)) }
        path += ancestors + [pick]
        element = pick
    }

    /// Trims and shortens to at most `max` UTF-16 units, as T3's schema counts string length
    /// (JavaScript), cutting only between characters.
    static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.utf16.count > max else { return t }
        var out = "", units = 0
        for ch in t {
            let n = ch.utf16.count
            guard units + n <= max - 1 else { break } // room for the "…"
            out.append(ch)
            units += n
        }
        return out + "…"
    }

    /// The element's own text, or the text of its subtree, for the prompt.
    var elementText: String? {
        guard let e = element else { return nil }
        var parts: [String] = []
        func walk(_ n: PickElement) {
            guard parts.joined(separator: " ").count < 400 else { return }
            // A description is often the only label, as on System Settings' sidebar buttons.
            for s in [n.name, n.value, n.description] { if let s, !s.isEmpty, !parts.contains(s) { parts.append(s) } }
            n.children.forEach(walk)
        }
        walk(e)
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : Self.clip(text, 400)
    }

    /// The clip covers most of the window, so the window image shows it well enough.
    var detailIsRedundant: Bool {
        let c = clipFrame.intersection(windowFrame)
        return !c.isNull && c.width * c.height > 0.5 * windowFrame.width * windowFrame.height
    }
}

// MARK: - Reading

/// Carries an accessibility element to the probe queue. AXUIElement calls are thread-safe.
struct AXRef: @unchecked Sendable { let element: AXUIElement }

enum PickReader {
    /// Reads the app, window and element for a clip. Runs off the main thread; every
    /// accessibility call has a short timeout and the subtree is capped.
    static func read(pid: pid_t, windowID: CGWindowID?, windowFrame: CGRect, clipFrame: CGRect,
                     element: AXUIElement?, subtree: Bool = true, screenshot: CGImage?,
                     screenshotRect: CGRect) -> PickContext {
        let app = NSRunningApplication(processIdentifier: pid)
        var ctx = PickContext(appName: app?.localizedName ?? "Unknown app", bundleID: app?.bundleIdentifier,
                              appIconPNG: app?.icon.flatMap(iconPNG), windowTitle: windowTitle(windowID) ?? "",
                              windowFrame: windowFrame, clipFrame: clipFrame)
        if Permission.accessibility.isGranted {
            // One deadline for every read. Each AX object gets its own short timeout too (a
            // timeout set on one object does not carry over to the objects it returns), so a
            // stalled app costs at most about the deadline plus one call.
            let deadline = Date().addingTimeInterval(0.6)
            let axApp = timed(AXUIElementCreateApplication(pid))
            if let element {
                let element = timed(element)
                let chain = ancestors(of: element, deadline: deadline)
                ctx.path = chain.map { redacted(node(of: $0), isPick: false, visible: windowFrame) }
                var budget = 150, cut = chain.count >= 40
                ctx.element = tree(of: element, depth: subtree ? 4 : 0, budget: &budget, deadline: deadline, cut: &cut,
                                   isPick: true, visible: windowFrame)
                ctx.readTruncated = cut
                if Date() < deadline { ctx.url = url(above: element, deadline: deadline) }
                if let title = ctx.path.first(where: { $0.role == kAXWindowRole as String })?.name, ctx.windowTitle.isEmpty {
                    ctx.windowTitle = title
                }
            }
            if Date() < deadline, let s = selectedText(axApp) { ctx.selectedText = PickContext.clip(s, 4000) }
        }
        if let screenshot { windowImage(&ctx, screenshot: screenshot, screenshotRect: screenshotRect) }
        return ctx
    }

    private static func windowTitle(_ id: CGWindowID?) -> String? {
        guard let id, let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return (info.first?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func iconPNG(_ icon: NSImage) -> Data? {
        let size = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Sets the short messaging timeout on an AX object and returns it.
    private static func timed(_ e: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(e, 0.1)
        return e
    }

    /// Roles whose value is what someone typed. Only the picked element itself sends it.
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Drops values that the user did not mean to send: a typed field's value unless it is the
    /// picked element, and any value of an element outside the captured window (an offscreen
    /// field can hold a token). Labels and states stay.
    private static func redacted(_ n: PickElement, isPick: Bool, visible: CGRect) -> PickElement {
        var n = n
        let onScreen = n.frame.map { !$0.intersection(visible).isNull } ?? false
        if !onScreen || (!isPick && (editableRoles.contains(n.role) || n.subrole == "AXSearchField")) { n.value = nil }
        return n
    }

    /// The element and its ancestors up to the window, outermost first.
    private static func ancestors(of element: AXUIElement, deadline: Date) -> [AXUIElement] {
        var out = [element]
        var e = element
        for _ in 0..<40 {
            guard Date() < deadline else { break }
            if string(e, kAXRoleAttribute) == kAXWindowRole as String { break }
            guard let p = parent(of: e) else { break }
            out.append(p)
            e = p
        }
        return out.reversed()
    }

    private static func tree(of e: AXUIElement, depth: Int, budget: inout Int, deadline: Date, cut: inout Bool,
                             isPick: Bool, visible: CGRect) -> PickElement {
        var n = redacted(node(of: e), isPick: isPick, visible: visible)
        budget -= 1
        guard Date() < deadline else { cut = true; return n }
        let (kids, more) = children(of: e)
        if more { cut = true }
        guard depth > 0 else { if !kids.isEmpty { cut = true }; return n }
        for c in kids {
            guard budget > 0, Date() < deadline else { cut = true; break }
            n.children.append(tree(of: c, depth: depth - 1, budget: &budget, deadline: deadline, cut: &cut,
                                   isPick: false, visible: visible))
        }
        return n
    }

    nonisolated(unsafe) private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
                                     kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPositionAttribute,
                                     kAXSizeAttribute, kAXSelectedAttribute, kAXEnabledAttribute] as [CFString]

    static func node(of e: AXUIElement) -> PickElement {
        var values: CFArray?
        _ = AXUIElementCopyMultipleAttributeValues(e, attributes as CFArray, [], &values)
        let v = (values as? [AnyObject]) ?? []
        func at(_ i: Int) -> AnyObject? {
            guard i < v.count else { return nil }
            let o = v[i]
            // Missing attributes come back as AXValue errors.
            if CFGetTypeID(o) == AXValueGetTypeID(), AXValueGetType(o as! AXValue) == .axError { return nil }
            return o
        }
        func text(_ i: Int, _ max: Int) -> String? {
            guard let s = at(i) as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : PickContext.clip(t, max)
        }
        let role = text(0, 100) ?? "AXUnknown"
        let subrole = text(1, 100)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var frame: CGRect?
        if let p = at(6), let s = at(7), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() {
            var origin = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: origin, size: size)
            }
        }
        return PickElement(role: role, subrole: subrole, name: text(2, 1000),
                           value: secure ? nil : text(3, 2000), // never a password field's value
                           description: text(4, 2000), identifier: text(5, 200), frame: frame,
                           selected: (at(8) as? Bool).flatMap { $0 ? true : nil },
                           enabled: (at(9) as? Bool).flatMap { $0 ? nil : false })
    }

    /// The page URL of the web view around the element, or the window's document.
    private static func url(above element: AXUIElement, deadline: Date) -> String? {
        var e: AXUIElement? = element
        var document: String?
        for _ in 0..<40 {
            guard let cur = e, Date() < deadline else { break }
            if string(cur, kAXRoleAttribute) == "AXWebArea", let u = urlValue(cur, kAXURLAttribute) { return sanitize(u) }
            if document == nil, let d = string(cur, kAXDocumentAttribute) { document = d }
            e = parent(of: cur)
        }
        return document.map(sanitize)
    }

    /// Drops user names and passwords, and the query and fragment of public URLs (they can
    /// carry tokens). Local and private hosts keep them: they are usually the app under work.
    static func sanitize(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return PickContext.clip(s, 2000) }
        c.user = nil
        c.password = nil
        if !(c.scheme == "file" || isLocalHost(c.host ?? "")) { c.query = nil; c.fragment = nil }
        return PickContext.clip(c.string ?? s, 2000)
    }

    /// True for loopback, private and link-local IP addresses, `localhost`, `.local` names
    /// and single-label names. A public name such as `10.example.com` is not local.
    static func isLocalHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) } // network order
            return b[0] == 127 || b[0] == 10 || (b[0] == 192 && b[1] == 168)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 169 && b[1] == 254)
                || (b[0] == 100 && (64...127).contains(b[1])) // CGNAT, as Tailscale uses
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            let loopback = b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1
            return loopback || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        }
        if host.contains(":") { return false } // not a valid address
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".")
    }

    private static func selectedText(_ app: AXUIElement) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let e = timed(f as! AXUIElement)
        let role = string(e, kAXRoleAttribute), subrole = string(e, kAXSubroleAttribute)
        guard role != "AXSecureTextField", subrole != "AXSecureTextField",
              let s = string(e, kAXSelectedTextAttribute), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func urlValue(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return nil }
        return (v as? URL)?.absoluteString ?? (v as? String)
    }

    private static func parent(of e: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return timed(v as! AXUIElement)
    }

    /// Up to 60 children, and whether there were more.
    private static func children(of e: AXUIElement) -> ([AXUIElement], Bool) {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
              let list = v as? [AnyObject] else { return ([], false) }
        let kids = list.prefix(60).compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? timed($0 as! AXUIElement) : nil }
        return (kids, list.count > 60)
    }

    // MARK: Window image

    /// Cuts the window out of the frozen screen, scales it to at most 2000 px on the long edge
    /// (as T3's own window shots) and outlines the clip. No numbers or arrows: a plain box
    /// marks a UI element best without hiding its text.
    private static func windowImage(_ ctx: inout PickContext, screenshot: CGImage, screenshotRect: CGRect) {
        let w = ctx.windowFrame.intersection(screenshotRect)
        guard !w.isNull, w.width >= 8, w.height >= 8 else { return }
        let native = CGFloat(screenshot.width) / screenshotRect.width
        let px = CGRect(x: (w.minX - screenshotRect.minX) * native, y: (w.minY - screenshotRect.minY) * native,
                        width: w.width * native, height: w.height * native).integral
        guard let window = screenshot.cropping(to: px) else { return }
        let scale = min(native, 2000 / max(w.width, w.height))
        let size = CGSize(width: (w.width * scale).rounded(), height: (w.height * scale).rounded())
        guard let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cg.interpolationQuality = .high
        cg.draw(window, in: CGRect(origin: .zero, size: size))
        // Outline in image pixels; CoreGraphics' origin is bottom-left.
        let c = ctx.clipFrame.intersection(w)
        if !c.isNull, c.width * c.height < 0.97 * w.width * w.height {
            let r = CGRect(x: (c.minX - w.minX) * scale, y: size.height - (c.maxY - w.minY) * scale,
                           width: c.width * scale, height: c.height * scale)
            let line = max(3, scale * 1.5)
            cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)) // halo so it shows on any colour
            cg.setLineWidth(line + 2)
            cg.stroke(r.insetBy(dx: -line / 2 - 1, dy: -line / 2 - 1))
            cg.setStrokeColor(CGColor(red: 1, green: 0.18, blue: 0.58, alpha: 1)) // vivid magenta
            cg.setLineWidth(line)
            cg.stroke(r.insetBy(dx: -line / 2, dy: -line / 2))
        }
        guard let out = cg.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]),
              png.count <= 10 * 1024 * 1024 else { return }
        ctx.windowPNG = png
        ctx.windowPixels = size
        ctx.windowScale = scale
        // Frames are relative to the visible window part from here on.
        ctx.windowFrame = w
    }
}

// MARK: - Encoding for T3

extension PickContext {
    /// The selection with what is around it, cut from `windowPNG`: the outline is on it. The
    /// margin is 80 to 200 pt and grows with the selection's shorter side. At most 1568 px long, the most a
    /// model looks at. Nil without a window picture.
    func surroundPNG() -> Data? {
        guard let windowPNG, windowScale > 0, let rep = NSBitmapImageRep(data: windowPNG), let image = rep.cgImage else { return nil }
        let c = clipFrame.intersection(windowFrame)
        guard !c.isNull else { return nil }
        let margin = max(80, min(200, 0.6 * min(c.width, c.height)))
        let r = c.insetBy(dx: -margin, dy: -margin).intersection(windowFrame)
        let px = CGRect(x: (r.minX - windowFrame.minX) * windowScale, y: (r.minY - windowFrame.minY) * windowScale,
                        width: r.width * windowScale, height: r.height * windowScale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 8, px.height >= 8, let cut = image.cropping(to: px) else { return nil }
        let shrink = min(1, 1568 / max(px.width, px.height))
        var out = cut
        if shrink < 1 {
            let size = CGSize(width: (px.width * shrink).rounded(), height: (px.height * shrink).rounded())
            guard let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            cg.interpolationQuality = .high
            cg.draw(cut, in: CGRect(origin: .zero, size: size))
            guard let small = cg.makeImage() else { return nil }
            out = small
        }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// A global rect in `windowPNG` pixels, or nil when it is off the image.
    func imageBounds(_ r: CGRect?) -> JSON {
        guard let r else { return .null }
        let c = r.intersection(windowFrame)
        guard !c.isNull, windowPixels.width > 0 else { return .null }
        let x = ((c.minX - windowFrame.minX) * windowScale).rounded(.down)
        let y = ((c.minY - windowFrame.minY) * windowScale).rounded(.down)
        let w = min((c.width * windowScale).rounded(.up), windowPixels.width - x)
        let h = min((c.height * windowScale).rounded(.up), windowPixels.height - y)
        guard w >= 1, h >= 1 else { return .null }
        return ["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)]
    }

    private func json(_ e: PickElement, children: [JSON]) -> JSON {
        var o: [String: JSON] = ["role": .string(e.role), "bounds": imageBounds(e.frame), "children": .array(children)]
        if let s = e.name { o["name"] = .string(s) }
        if let s = e.value { o["value"] = .string(s) }
        if let s = e.description ?? e.subrole.map({ "subrole \($0)" }) { o["description"] = .string(s) }
        var state: [String: JSON] = [:]
        if e.selected == true { state["selected"] = true }
        if e.enabled == false { state["enabled"] = false }
        if !state.isEmpty { o["state"] = .object(state) }
        return .object(o)
    }

    private func subtree(_ e: PickElement, limit: Int?) -> JSON {
        let kids = limit.map { Array(e.children.prefix($0)) } ?? e.children
        return json(e, children: kids.map { subtree($0, limit: limit) })
    }

    /// The element tree for T3: the path from the window down to the element, then the
    /// element's subtree. Pruned until it fits T3's 32,000-character limit.
    func accessibility() -> JSON? {
        guard element != nil || !path.isEmpty, windowPNG != nil else { return nil }
        for limit in [nil, 12, 6, 3, 1, 0] as [Int?] {
            var node: JSON = element.map { subtree($0, limit: limit) } ?? .null
            var truncated = limit != nil || readTruncated
            for a in path.dropLast().reversed() { // the last path entry is the element itself
                node = node == .null ? json(a, children: []) : json(a, children: [node])
            }
            if node == .null { continue }
            if path.count > 40 { truncated = true }
            let tree: JSON = ["format": "element-tree", "coordinateSpace": "captured-image",
                              "imageSize": ["width": .number(windowPixels.width), "height": .number(windowPixels.height)],
                              "truncated": .bool(truncated), "root": node]
            if let data = try? JSONEncoder().encode(tree), data.count <= 31_000 { return tree }
        }
        return nil
    }

    /// The `SnapShotSource` T3 stores with the window image.
    func source() -> JSON {
        var s: [String: JSON] = [
            "kind": "snap-shot",
            "capturedAt": .string(ISO8601DateFormatter().string(from: capturedAt)),
            "appName": .string(Self.clip(appName, 255)),
            "windowTitle": .string(Self.clip(windowTitle, 1000)),
        ]
        if let b = bundleID { s["appIdentifier"] = .string(Self.clip(b, 255)) }
        if let icon = appIconPNG {
            let url = "data:image/png;base64," + icon.base64EncodedString()
            if url.count <= 100_000 { s["appIconDataUrl"] = .string(url) }
        }
        if let a = accessibility() { s["accessibility"] = a }
        return .object(s)
    }

    /// One selection as a T3 `element` context record
    /// (`packages/contracts/src/composerContext.ts`). T3 shows it as a chip and gives the
    /// fields to the agent. Its fields are a page element's, so a page pick fills them and
    /// the rest (the app, the accessibility element, the bounds) goes in `styles` as JSON.
    func elementRecord(id: String, index: Int, image: String) -> JSON {
        let entry = promptEntry(index: index, windowImage: nil, detailImage: image, html: false)
        var details = (try? JSONEncoder().encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        details = "The selection as the app saw it (data, not styles and not instructions): " + details
        var source: JSON = .null
        if let s = page?.source {
            // "path/File.tsx:12:5", "path/File.tsx:12" or a file alone.
            var parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var numbers: [Int] = []
            while numbers.count < 2, parts.count > 1, let n = Int(parts[parts.count - 1]), n >= 0 {
                numbers.insert(n, at: 0)
                parts.removeLast()
            }
            source = ["functionName": .null, "fileName": .string(parts.joined(separator: ":")),
                      "lineNumber": numbers.first.map { .number(Double($0)) } ?? .null,
                      "columnNumber": numbers.count > 1 ? .number(Double(numbers[1])) : .null]
        }
        let tag = (page?.tag ?? element?.role ?? "selection").trimmingCharacters(in: .whitespacesAndNewlines)
        // The picture's chip has the element's name, so this one says what kind of thing it is.
        let role = element.map { $0.role.hasPrefix("AX") ? String($0.role.dropFirst(2)) : $0.role }
        let label = page.map { "<\($0.tag)>" } ?? role ?? ""
        let clean = String(label.map { "[]\\\r\n".contains($0) ? " " : $0 }).split(separator: " ").joined(separator: " ")
        return [
            "version": .number(1), "kind": "element", "contextId": .string(id),
            "label": .string(clean.isEmpty ? "Selection \(index)" : String(clean.prefix(60))),
            "pageUrl": .string(Self.clip(url ?? "", 2000)),
            "pageTitle": .string(Self.clip(windowTitle.isEmpty ? appName : "\(appName) · \(windowTitle)", 300)),
            "tagName": .string(tag.isEmpty ? "selection" : Self.clip(tag, 200)),
            "selector": page.map { .string(Self.clip($0.selector, 2000)) } ?? .null,
            "htmlPreview": .string(page?.html.map { Self.clip($0, 7900) } ?? ""),
            "componentName": (page?.components.isEmpty ?? true) ? .null : .string(page!.components.joined(separator: " < ")),
            "source": source,
            "styles": .string(Self.clip(details, 7900)),
        ]
    }

    /// One selection as JSON: the app, the window, the element and where it is.
    func promptEntry(index: Int, windowImage: String?, detailImage: String?, html: Bool = true) -> JSON {
        var o: [String: JSON] = ["selection": .number(Double(index)), "app": .string(appName)]
        if let windowImage { o["window_image"] = .string(windowImage) }
        if let detailImage { o["image"] = .string(detailImage) }
        if let b = bundleID { o["bundle_id"] = .string(b) }
        if !windowTitle.isEmpty { o["window"] = .string(Self.clip(windowTitle, 300)) }
        if let url { o["url"] = .string(url) }
        if let e = element {
            var el: [String: JSON] = ["role": .string(e.role)]
            if let s = e.name { el["name"] = .string(Self.clip(s, 300)) }
            if let s = e.identifier { el["identifier"] = .string(s) }
            if let t = elementText { el["text"] = .string(t) }
            if !path.isEmpty { el["path"] = .string(path.map(\.label).joined(separator: " > ")) }
            o["element"] = .object(el)
            if let p = page {
                var d: [String: JSON] = ["selector": .string(p.selector), "tag": .string(p.tag)]
                if let s = p.role { d["role"] = .string(s) }
                if let s = p.name { d["name"] = .string(s) }
                if let s = p.text { d["text"] = .string(s) }
                if let s = p.value { d["value"] = .string(s) }
                if html, let s = p.html { d["html"] = .string(s) }
                if !p.components.isEmpty { d["components"] = .array(p.components.map { .string($0) }) }
                if let s = p.source { d["source"] = .string(s) }
                if !p.attributes.isEmpty { d["attributes"] = .object(p.attributes.mapValues { .string($0) }) }
                o["dom"] = .object(d)
            }
        } else {
            o["element"] = "dragged rectangle, no element"
        }
        let c = clipFrame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        o["bounds_in_window_pt"] = ["x": .number(c.minX.rounded()), "y": .number(c.minY.rounded()),
                                    "width": .number(c.width.rounded()), "height": .number(c.height.rounded())]
        o["window_size_pt"] = ["width": .number(windowFrame.width.rounded()), "height": .number(windowFrame.height.rounded())]
        if let s = selectedText { o["selected_text"] = .string(s) }
        return .object(o)
    }
}
