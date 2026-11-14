import AppKit
import Foundation
import Observation

/// One-click updates from GitHub Releases.
///
/// Checks the latest release at launch and every six hours. When its version is newer than
/// this app's, the island shows an update button. Installing downloads the release zip,
/// checks it (Gatekeeper must accept it, so it is Developer ID signed and notarized, with
/// our bundle id and, if this copy is a release, our team), swaps it in place of this app
/// and relaunches.
@Observable
@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case available(version: String)
        case installing(version: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var asset: URL?
    @ObservationIgnored private var timer: Timer?

    var availableVersion: String? {
        switch state {
        case .available(let v), .installing(let v): return v
        default: return nil
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard !Store.demo else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    // MARK: Check

    func check() async {
        if case .installing = state { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(BuildInfo.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSON.parse(data),
              let tag = release["tag_name"].string else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zip = release["assets"].array?.first {
            ($0["name"].string ?? "").hasSuffix(".zip")
        }?["browser_download_url"].string.flatMap(URL.init(string:))
        if Self.isNewer(version, than: Self.currentVersion), let zip {
            asset = zip
            state = .available(version: version)
        } else if case .available = state {
            state = .idle
        }
    }

    /// Compares dotted numeric versions: 0.10.0 is newer than 0.9.3.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Install

    func install() {
        guard case .available(let version) = state, let asset else { return }
        state = .installing(version: version)
        Task {
            do {
                // Unzipping and the signature checks run off the main thread.
                let app = try await Task.detached { try await Self.download(asset) }.value
                try await Task.detached { try Self.verify(app) }.value
                try swapIn(app)
                relaunch()
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(8))
                state = .available(version: version)
            }
        }
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("T3NotchUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (file, _) = try await URLSession.shared.download(from: url)
        let zip = work.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("the download has no app in it") }
        return app
    }

    /// Gatekeeper must accept it (Developer ID signed and notarized), it must be this app,
    /// and when this copy is itself a release, it must come from the same team.
    nonisolated private static func verify(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("the download is a different app")
        }
        if let mine = Self.teamIdentifier(of: Bundle.main.bundleURL), Self.isDeveloperID(Bundle.main.bundleURL) {
            guard Self.teamIdentifier(of: app) == mine else { throw UpdateError("the download is signed by someone else") }
        }
    }

    /// Replaces this app's bundle with the new one; the old copy goes to the Trash.
    private func swapIn(_ app: URL) throws {
        let current = Bundle.main.bundleURL
        try FileManager.default.trashItem(at: current, resultingItemURL: nil)
        try FileManager.default.moveItem(at: app, to: current)
    }

    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    nonisolated private static func signingInfo(_ app: URL) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", app.path]
        p.standardError = pipe
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    nonisolated static func teamIdentifier(of app: URL) -> String? {
        signingInfo(app).split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
    }

    nonisolated static func isDeveloperID(_ app: URL) -> Bool {
        signingInfo(app).contains("Authority=Developer ID Application")
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) rejected it: \(text.prefix(200))")
        }
        return text
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
