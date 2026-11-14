import AppKit
import Darwin

/// Where the local T3 Code server is, read from the file the `t3` CLI uses.
struct T3Runtime: Equatable, Sendable {
    let pid: Int32
    let port: Int
    let origin: String
    let serverVersion: String

    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
    static let runtimeFile = home.appendingPathComponent("userdata/server-runtime.json")
    static let cli = home.appendingPathComponent("bin/t3")

    /// The running server, or nil when T3 is not running.
    static func current() -> T3Runtime? {
        guard let data = try? Data(contentsOf: runtimeFile),
              let json = try? JSON.parse(data),
              let pid = json["pid"].double, let port = json["port"].double
        else { return nil }
        // kill(pid, 0) checks the process exists without signalling it.
        guard kill(Int32(pid), 0) == 0 else { return nil }
        let origin = json["origin"].string ?? "http://127.0.0.1:\(Int(port))"
        return T3Runtime(pid: Int32(pid), port: Int(port), origin: origin,
                         serverVersion: json["serverVersion"].string ?? "unknown")
    }

    var httpBase: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// The T3 window app. `pid` is the background server, a child process running the same
    /// executable, so look up the app bundle it runs from and find that app's window process.
    var app: NSRunningApplication? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard let range = path.range(of: ".app/", options: .backwards),
              let bundleId = Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
        else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.activationPolicy == .regular }
    }
}
