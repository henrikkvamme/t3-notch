import Foundation

/// Holds the overlay's T3 bearer token and mints a new one with the `t3` CLI when it is
/// missing or rejected. Revoke it in T3 under the label below.
///
/// The token lives in a 0600 file rather than the Keychain: the app is ad-hoc signed, so
/// every rebuild changes its signature and the Keychain would prompt for access each time.
/// T3 keeps its own secrets the same way, under ~/.t3/userdata/secrets.
enum Auth {
    static let label = "notch-overlay"

    private static var tokenFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/T3Notch/token")
    }

    static func storedToken() -> String? {
        guard let s = try? String(contentsOf: tokenFile, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func store(_ token: String) {
        let fm = FileManager.default
        let dir = tokenFile.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: tokenFile)
    }

    /// Runs `t3 auth session issue` with the narrowest scopes the overlay needs.
    static func issueToken() async throws -> String {
        let args = ["auth", "session", "issue",
                    "--scope", "orchestration:read", "--scope", "orchestration:operate",
                    "--ttl", "30d", "--label", label, "--token-only"]
        let out = try await runCLI(args)
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(" ") else {
            throw AppError.auth("t3 auth session issue printed no token")
        }
        store(token)
        return token
    }

    static func runCLI(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = T3Runtime.cli
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 { cont.resume(returning: o) }
                else { cont.resume(throwing: AppError.auth("t3 \(args.prefix(3).joined(separator: " ")) failed: \(e.prefix(300))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

enum AppError: Error, CustomStringConvertible {
    case auth(String)
    case rpc(String)
    case protocolMismatch(String)

    var description: String {
        switch self {
        case .auth(let s), .rpc(let s), .protocolMismatch(let s): return s
        }
    }
}
