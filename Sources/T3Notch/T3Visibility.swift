import AppKit

/// Whether T3 Code can be seen right now, on any display.
enum T3Visibility {
    /// True when T3 is frontmost, or when one of its normal windows is on screen (the current
    /// Space of any display, not minimized or hidden) and no single window in front covers it.
    /// Window bounds are readable without Screen Recording permission.
    static func isInView(pid: pid_t) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        // The list runs front to back; keep the normal windows in front of the current one.
        var inFront: [CGRect] = []
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.width > 100, r.height > 100 else { continue }
            if owner == pid, !inFront.contains(where: { $0.contains(r) }) { return true }
            inFront.append(r)
        }
        return false
    }
}
