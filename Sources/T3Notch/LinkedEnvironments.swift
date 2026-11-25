import Foundation
import Observation

/// Tokens for linked environments, one per environment, in a 0600 file beside the local
/// token (see `Auth`). Each token is a session on that environment, which shows it under
/// Settings → Sharing & access there with the label `T3 Notch`, where it can be revoked.
enum LinkedCredentials {
    struct Entry: Codable, Equatable {
        var url: String
        var token: String
    }

    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/T3Notch/linked-environments.json")
    }

    private static func all() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    static func get(_ environmentId: String) -> Entry? { all()[environmentId] }

    static func set(_ environmentId: String, _ entry: Entry?) {
        var entries = all()
        entries[environmentId] = entry
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = (try? JSONEncoder().encode(entries)) ?? Data("{}".utf8)
        fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// A T3 environment the local one links to (`t3 environment list`), such as a server the
/// desktop app also shows chats from. The overlay connects to it directly, the way T3's own
/// client does (`connectLinkedEnvironment` in `packages/client-runtime/src/linkedThread.ts`):
///
/// 1. The local server asks the linked one for a one-time pairing for this client
///    (`peerLinks.pairClient`). That needs a full-access link and `access:write` here.
/// 2. The overlay tries the addresses the pairing names (`/.well-known/t3/environment` must
///    answer with this environment's id) and redeems the pairing at the first that does
///    (`POST /oauth/token`), for a bearer token with only the orchestration scopes.
/// 3. With that token it opens the environment's own `/ws`, as for the local server.
///
/// The token is kept, so the next launch skips the pairing. A rejected token pairs again.
@Observable
@MainActor
final class LinkedEnvironment {
    enum State: Equatable {
        case connecting
        case connected
        /// Failed for now; it tries again by itself.
        case failed(String)
        /// T3 refused a pairing for a reason the overlay cannot fix, such as a link below full
        /// access. It asks again now and then.
        case unavailable(String)
    }

    let id: String
    var label: String
    private(set) var state: State = .connecting
    private(set) var httpBase: URL?
    private(set) var token: String?

    @ObservationIgnored let rpc = RPCClient()
    @ObservationIgnored var shellStreamId: String?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var failuresAtSavedAddress = 0
    @ObservationIgnored private var stopped = false

    /// Asks the local server for a pairing with this environment (`peerLinks.pairClient`).
    @ObservationIgnored var requestPairing: (String) async throws -> JSON = { _ in throw AppError.rpc("no local server") }
    /// The socket opened; subscribe to its shell.
    @ObservationIgnored var onConnected: (LinkedEnvironment) -> Void = { _ in }
    /// The socket closed or failed; drop this environment's chats.
    @ObservationIgnored var onDisconnected: (LinkedEnvironment) -> Void = { _ in }

    init(id: String, label: String) {
        self.id = id
        self.label = label
        rpc.onClose = { [weak self] reason in
            guard let self, !self.stopped, reason != "closed" else { return }
            self.onDisconnected(self)
            self.fail(reason)
        }
    }

    func start() {
        stopped = false
        Task { await connect() }
    }

    /// Closes the socket for good (the link is gone or the app reconnects from scratch).
    func stop() {
        stopped = true
        retryTask?.cancel(); retryTask = nil
        shellStreamId = nil
        rpc.close()
    }

    func reconnectNow() {
        retryTask?.cancel(); retryTask = nil
        rpc.close()
        shellStreamId = nil
        Task { await connect() }
    }

    private func connect() async {
        guard !stopped else { return }
        state = .connecting
        if let saved = LinkedCredentials.get(id), let base = URL(string: saved.url) {
            do {
                try await rpc.connect(httpBase: base, token: saved.token)
                connected(base: base, token: saved.token)
                return
            } catch AppError.auth {
                // Revoked there, or expired: pair again.
                LinkedCredentials.set(id, nil)
            } catch {
                // Out of reach. Try the saved address a few times before pairing again, which
                // also fetches the link's current addresses.
                failuresAtSavedAddress += 1
                if failuresAtSavedAddress < 3 { fail("\(error.localizedDescription)"); return }
            }
        }
        failuresAtSavedAddress = 0
        do {
            let pairing = try await requestPairing(id)
            if let name = pairing["label"].string, !name.isEmpty { label = name }
            let urls = (pairing["urls"].array ?? []).compactMap(\.string)
            guard pairing["type"].string == "credential", let credential = pairing["credential"].string else {
                // Out of reach is temporary; the other reasons need a change in T3 first.
                let reason = pairing["reason"].string
                if reason == "unreachable" { fail(Self.describe(unsupported: reason)) }
                else { unavailable(Self.describe(unsupported: reason)) }
                return
            }
            guard let base = await firstAddressAnswering(urls) else {
                fail("no address of \(label) answers from this Mac")
                return
            }
            let token = try await redeem(credential, at: base)
            LinkedCredentials.set(id, .init(url: base.absoluteString, token: token))
            try await rpc.connect(httpBase: base, token: token)
            connected(base: base, token: token)
        } catch {
            fail("\(error)")
        }
    }

    private func connected(base: URL, token: String) {
        guard !stopped else { rpc.close(); return }
        httpBase = base
        self.token = token
        failuresAtSavedAddress = 0
        state = .connected
        onConnected(self)
    }

    private func fail(_ reason: String) {
        guard !stopped else { return }
        state = .failed(String(reason.prefix(200)))
        scheduleRetry(after: .seconds(10))
    }

    private func unavailable(_ reason: String) {
        guard !stopped else { return }
        state = .unavailable(reason)
        scheduleRetry(after: .seconds(300))
    }

    private func scheduleRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.retryTask = nil
            await self.connect()
        }
    }

    /// The first address, in the link's order of preference, that answers as this environment.
    private func firstAddressAnswering(_ urls: [String]) async -> URL? {
        let id = self.id
        let probes = urls.compactMap(URL.init(string:)).map { base in
            Task { () -> URL? in
                var request = URLRequest(url: base.appendingPathComponent(".well-known/t3/environment"))
                request.timeoutInterval = 6
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSON.parse(data), json["environmentId"].string == id else { return nil }
                return base
            }
        }
        for probe in probes {
            if let base = await probe.value { return base }
        }
        return nil
    }

    /// Redeems a one-time pairing for a bearer token with only the scopes the overlay needs.
    private func redeem(_ credential: String, at base: URL) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:token-exchange"),
            .init(name: "subject_token", value: credential),
            .init(name: "subject_token_type", value: "urn:t3:params:oauth:token-type:environment-bootstrap"),
            .init(name: "requested_token_type", value: "urn:ietf:params:oauth:token-type:access_token"),
            .init(name: "scope", value: "orchestration:read orchestration:operate"),
            .init(name: "client_label", value: "T3 Notch"),
            .init(name: "client_device_type", value: "desktop"),
            .init(name: "client_os", value: "macOS"),
        ]
        // `+` in a form body means a space, so encode it too.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let token = try? JSON.parse(data)["access_token"].string else {
            throw AppError.auth("\(label) refused the pairing (\(status)): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return token
    }

    private static func describe(unsupported reason: String?) -> String {
        switch reason {
        case "link_access": return "linked below full access, so it can't pair this app"
        case "version": return "runs a T3 version that can't pair this app"
        case "refused": return "refused to pair this app"
        case "unreachable": return "the local T3 can't reach it"
        default: return "can't pair this app (\(reason ?? "unknown"))"
        }
    }
}
