/// The T3 Code version this client's wire handling was last written against.
/// Update both when you fix the client for a newer T3 release.
enum BuildInfo {
    static let builtAgainstServerVersion = "0.1.10-nightly.20261111.4529"
    static let builtAgainstT3Commit = "d3d7ad9a61e112224ddd1b6daa9f19d9cdae4243"
    /// GitHub repo of this app, used for the "protocol changed" fix-it prompt link.
    static let repo = "lille-morille/t3-notch"
    static let bundleId = "dev.t3notch.app"
}
