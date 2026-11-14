import Foundation
import Security

/// Holds the overlay's T3 bearer token in the Keychain and mints a new one with the
/// `t3` CLI when it is missing or rejected. Revoke it in T3 under the label below.
enum Auth {
    static let label = "notch-overlay"
    private static let service = "\(BuildInfo.bundleId).token"

    static func storedToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
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
