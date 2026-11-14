import AppKit
import ApplicationServices
import ScreenCaptureKit

/// The two permissions clipping uses, and the shortest way to grant each: one click opens
/// System Settings on the exact list, with T3 Notch already in it, so only the toggle is left.
enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess() || Self.screenRecordingConfirmed
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    /// The Privacy & Security pane for this permission (macOS 13+ System Settings).
    private var settingsURL: URL {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")!
    }

    /// Makes sure T3 Notch is listed in the pane (macOS only lists apps that asked), then
    /// opens it. The system's own request alert shows at most once.
    func openSettings() {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess() // lists the app; alerts only the first time
        case .accessibility:
            let asked = "askedForAccessibility"
            if !UserDefaults.standard.bool(forKey: asked) {
                UserDefaults.standard.set(true, forKey: asked)
                // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        }
        NSWorkspace.shared.open(settingsURL)
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
