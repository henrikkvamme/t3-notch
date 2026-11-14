import Foundation

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
}
