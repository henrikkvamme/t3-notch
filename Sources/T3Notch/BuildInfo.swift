import Foundation

/// The T3 Code version this client's wire handling was last written against.
/// Update both when you fix the client for a newer T3 release.
enum BuildInfo {
    static let builtAgainstServerVersion = "0.1.10-nightly.20261116.4787"
    static let builtAgainstT3Commit = "b5554ac8114f2ce7ce8b5973690ccb8cbb248efd"
    /// GitHub repo of this app, used for the "protocol changed" fix-it prompt link.
    static let repo = "lille-morille/t3-notch"
    static let bundleId = "dev.t3notch.app"

    /// A local `make` build ("T3 Notch Dev", bundle id `dev.t3notch.app.dev`). It keeps its own
    /// logs and never updates itself, so it can run beside the installed release.
    static let isDev = Bundle.main.bundleIdentifier == bundleId + ".dev"
}
