import AppKit
import Darwin
import SwiftUI

/// Where this copy of the app runs, and the move into Applications.
///
/// A copy opened from the DMG, or from Downloads, cannot update itself: the DMG is read-only,
/// and macOS runs a quarantined app from a random read-only path (App Translocation) until it is
/// moved. So at launch the island offers to move the app into Applications and start it again
/// from there, as LetsMove does: copy, clear the quarantine flag, relaunch, then put the old copy
/// in the Trash or eject the DMG.
enum AppLocation {
    /// This app's bundle where it really is: for a translocated copy, the path it was opened from.
    static var bundleURL: URL { originalURL(of: Bundle.main.bundleURL) ?? Bundle.main.bundleURL }

    /// macOS runs this copy from a random read-only path.
    static var isTranslocated: Bool {
        let url = Bundle.main.bundleURL
        if let check = Translocation.isTranslocated {
            var translocated = false
            if check(url as CFURL, &translocated, nil).boolValue { return translocated }
        }
        return url.path.contains("/AppTranslocation/")
    }

    /// In /Applications or ~/Applications, or a folder inside one.
    static var isInApplications: Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        return applicationFolders.contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    }

    /// On a read-only volume, such as the mounted DMG.
    static var isOnReadOnlyVolume: Bool {
        (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    /// Whether to offer the move at launch: a release copy outside Applications. A dev build
    /// ("T3 Notch Dev") stays where `make` put it.
    static var shouldOfferMove: Bool {
        !BuildInfo.isDev && !Store.demo && (isTranslocated || !isInApplications)
    }

    /// Whether the updater can replace this copy where it is.
    static var canUpdateInPlace: Bool {
        !isTranslocated && !isOnReadOnlyVolume
            && FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    private static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), userApplications]
    }

    private static var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Where the move puts the app: ~/Applications when it already holds apps (someone who keeps
    /// apps there), else /Applications when this user can write to it, else ~/Applications. So it
    /// never needs an administrator password.
    static var destinationFolder: URL {
        let fm = FileManager.default
        let user = userApplications
        let userHasApps = ((try? fm.contentsOfDirectory(atPath: user.path)) ?? []).contains { $0.hasSuffix(".app") }
        if userHasApps, fm.isWritableFile(atPath: user.path) { return user }
        if fm.isWritableFile(atPath: "/Applications") { return URL(fileURLWithPath: "/Applications", isDirectory: true) }
        return user
    }

    // MARK: Move

    /// Copies this app into Applications, replacing an older copy there, and returns the new copy.
    /// It runs off the main thread; `relaunch(from:)` finishes the move.
    nonisolated static func copyToApplications() throws -> URL {
        let fm = FileManager.default
        let source = bundleURL
        let folder = destinationFolder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let quarantine = ["-d", "-r", "com.apple.quarantine", destination.path]
        // Already in Applications but translocated (copied there by something other than
        // Finder): clearing the flag is enough.
        if destination.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path {
            try run("/usr/bin/xattr", quarantine, allowFailure: true)
            return destination
        }
        if fm.fileExists(atPath: destination.path) {
            try quitCopy(at: destination)
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // The first launch was already approved; without this macOS would ask again and run the
        // new copy translocated too.
        try run("/usr/bin/xattr", quarantine, allowFailure: true)
        return destination
    }

    /// Quits this app and opens the new copy once this process has exited. The old copy goes to
    /// the Trash, or its DMG is ejected. `--moved` tells the new copy to go on with the tour at once.
    @MainActor
    static func relaunch(from destination: URL) {
        let source = bundleURL
        let values = try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsEjectableKey, .volumeURLKey])
        var eject = ""
        if values?.volumeIsReadOnly == true, values?.volumeIsEjectable == true, let volume = values?.volume {
            eject = volume.path
        } else if source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() && !isInApplications {
            // Downloads or another folder: the copy in Applications replaces it.
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        }
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
            /usr/bin/open "$2" --args --moved
            if [ -n "$3" ]; then /bin/sleep 2; /usr/sbin/diskutil eject "$3" >/dev/null 2>&1; fi
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "t3notch-relaunch", String(ProcessInfo.processInfo.processIdentifier),
                       destination.path, eject]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Asks a copy that runs from `bundle` to quit, and waits up to three seconds for it.
    nonisolated private static func quitCopy(at bundle: URL) throws {
        let path = bundle.resolvingSymlinksInPath().path
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: BuildInfo.bundleId)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().path == path
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if running.contains(where: { !$0.isTerminated }) {
            throw MoveError("T3 Notch in Applications is still running. Quit it and try again.")
        }
    }

    private static func originalURL(of url: URL) -> URL? {
        guard let original = Translocation.originalPath, isTranslocated,
              let result = original(url as CFURL, nil) else { return nil }
        return result.takeRetainedValue() as URL
    }

    nonisolated private static func run(_ tool: String, _ args: [String], allowFailure: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !allowFailure {
            throw MoveError("\(URL(fileURLWithPath: tool).lastPathComponent) failed")
        }
    }
}

/// Security.framework's translocation calls. They are not public API, so they are looked up at
/// run time, as LetsMove does; without them the path check above still works.
private enum Translocation {
    typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
    typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    static let isTranslocated: IsTranslocated? = symbol("SecTranslocateIsTranslocatedURL")
    static let originalPath: OriginalPath? = symbol("SecTranslocateCreateOriginalPathForURL")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

struct MoveError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The move step in the island.
enum MoveState: Equatable {
    case idle
    case moving
    case failed(String)
}

extension PanelController {
    /// Opens the island on the move step. `next` is the tour step to go on to if the move is
    /// skipped, or nil when the tour is done already.
    func offerMove(then next: OnboardingStep?) {
        Chime.prepare()
        ui.moveNext = next
        ui.move = .idle
        ui.onboardingKeysLit = false
        ui.onboarding = .install
        expand()
    }

    /// The move button. A dev build only pretends, so the step can be checked with
    /// `--onboarding install`.
    func moveToApplications() {
        guard ui.onboarding == .install, ui.move != .moving else { return }
        withAnimation(Motion.content) { ui.move = .moving }
        if BuildInfo.isDev {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.skipMove()
            }
            return
        }
        Task { [weak self] in
            do {
                let destination = try await Task.detached { try AppLocation.copyToApplications() }.value
                AppLocation.relaunch(from: destination)
            } catch {
                withAnimation(Motion.content) { self?.ui.move = .failed(error.localizedDescription) }
            }
        }
    }

    /// Esc or "Not now": go on with the tour, or close the island when the tour is done.
    /// The step comes back at the next launch while the app is outside Applications.
    func skipMove() {
        guard ui.onboarding == .install else { return }
        if let next = ui.moveNext {
            ui.moveNext = nil
            startOnboarding(at: next)
        } else {
            hide()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.ui.onboarding == .install else { return }
                self.ui.onboarding = nil
            }
        }
    }
}
