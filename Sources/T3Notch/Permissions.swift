import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The two permissions clipping uses, and the shortest way to grant each.
///
/// macOS keeps a grant together with the app's code signature at the time of the grant. When the
/// signature changes (a build signed another way, or with another certificate), System Settings
/// still shows the switch on, but the grant no longer matches, so the app is not allowed. Turning
/// the switch off and on does not fix it. So a request first removes the app's own entry and
/// then adds it again: the new entry belongs to the running copy, and its switch works.
enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    /// The list's name in System Settings. macOS 27 renamed Accessibility.
    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility:
            return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control" : "Accessibility"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess() || Self.screenRecordingConfirmed
        case .accessibility: return AXIsProcessTrusted() || Self.accessibilityWorks()
        }
    }

    /// `AXIsProcessTrusted` can answer from a cache in the process and stay false after the
    /// grant. A real Accessibility call cannot succeed without the grant, so success counts.
    private static func accessibilityWorks() -> Bool {
        var app: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success
    }

    /// The service name `tccutil` uses.
    private var tccService: String {
        switch self {
        case .screenRecording: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        }
    }

    /// The Privacy & Security list for this permission. On macOS 27 the Accessibility anchor
    /// opens the list that System Settings calls "Device Control and Data Access".
    var settingsURL: URL {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }

    /// Gives this copy of the app a fresh, working entry in the list, then opens the list.
    /// Does nothing when the permission is already granted, or once the task is cancelled.
    func request() async {
        if self == .screenRecording { await Self.confirmScreenRecordingLive() }
        guard !isGranted, !Task.isCancelled else { return }
        // Not granted, so the entry (if any) is off or belongs to another signature: removing
        // it loses nothing.
        await resetEntry()
        guard !Task.isCancelled else { return }
        switch self {
        case .screenRecording:
            // Since macOS 15 the request alone may not add the app to the list; a
            // ScreenCaptureKit query does (as Ice does it).
            _ = CGRequestScreenCaptureAccess()
            _ = try? await SCShareableContent.current
            guard !Task.isCancelled else { return }
        case .accessibility:
            // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        NSWorkspace.shared.open(settingsURL)
    }

    /// `tccutil reset <service> <own bundle id>`. An app may reset its own entries without
    /// an admin password.
    private func resetEntry() async {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let service = tccService
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleId]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
    }

    static var missing: [Permission] { allCases.filter { !$0.isGranted } }

    /// `CGPreflightScreenCaptureAccess` can keep answering "no" until the app restarts,
    /// even after the toggle is on. ScreenCaptureKit sees the grant live, so a successful
    /// content query also counts.
    nonisolated(unsafe) private static var screenRecordingConfirmed = false

    static func confirmScreenRecordingLive() async {
        guard !screenRecordingConfirmed, !CGPreflightScreenCaptureAccess() else { return }
        if (try? await SCShareableContent.current) != nil { screenRecordingConfirmed = true }
    }
}
