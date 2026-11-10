import Foundation
import AppKit
import Combine

/// Checks GitHub for a newer release and installs it when the user says so.
///
/// Nothing happens without being asked for twice over: a check only looks, and the
/// download and swap wait for the Update button. What arrives is verified against the
/// running app's own signature before anything is replaced — see `CodeSignature` — so a
/// release that is not from the same developer is refused rather than installed.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let automaticKey = "checkForUpdatesAutomatically"
    static let skippedVersionKey = "skippedUpdateVersion"
    static let lastCheckedKey = "lastUpdateCheck"

    /// A day between background checks. A release is not urgent, and this is also how
    /// often the app asks GitHub anything at all.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Where releases are published. The owner and repository are fixed: an updater that
    /// took its source from a setting would install whatever that setting pointed at.
    static let releasesURL = URL(
        string: "https://api.github.com/repos/dasassygoat/rdp-manager/releases?per_page=20")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading(Double)
        case installing
        case failed(String)

        var release: GitHubRelease? {
            if case .available(let release) = self { return release }
            return nil
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            case .idle, .upToDate, .available, .failed: return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    /// The release being installed, so the sheet can still name it once `state` has moved
    /// on from `.available`.
    @Published private(set) var pending: GitHubRelease?
    /// Whether there is an answer on screen. The update window follows this, and the
    /// buttons in it lower it to close. A silent check that finds nothing never
    /// interrupts, so it never raises this.
    @Published var isPresenting = false

    /// Opens the window the answer appears in, called just before raising it.
    ///
    /// This app deliberately keeps running with every window closed — see
    /// `applicationShouldTerminateAfterLastWindowClosed`. The answer used to be a sheet on
    /// the main window, which in that state had nothing to attach to: choosing "Check for
    /// Updates…" from the menu ran the whole check, found the update, and showed nothing
    /// at all. A closure because opening a window is the scene's business, not this
    /// service's.
    var prepareToPresent: () -> Void = {}

    /// What this copy reports itself to be. A seam for the same reason as `fetch`: the
    /// tests are compiled without an app bundle around them, so there is no real version
    /// for them to be newer or older than.
    var runningVersion: () -> AppVersion? = { AppVersion.running }

    /// Replaced in tests, which must not reach the network.
    var fetch: (URL) async throws -> Data = { url in
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.server(http.statusCode)
        }
        return data
    }

    enum Failure: LocalizedError {
        case server(Int)
        case noVersion
        case noAsset
        case unsignedHost

        var errorDescription: String? {
            switch self {
            case .server(404):
                // The API answers 404 rather than 403 for a repository the caller cannot
                // see, so this is what a private repository looks like from here.
                return "The releases could not be read. They are published from a private "
                    + "repository, which only its members can download from, so automatic "
                    + "updates will not work until it is public."
            case .server(let code):
                return "GitHub answered with status \(code)."
            case .noVersion:
                return "This build has no version number, so it cannot tell what is newer."
            case .noAsset:
                return "The release has no app attached to install."
            case .unsignedHost:
                return "This copy of RDP Manager is not signed with a Developer ID, so an "
                    + "update cannot be checked against it. Download the release by hand "
                    + "instead."
            }
        }
    }

    private var task: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    var checksAutomatically: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automaticKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
    }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedVersionKey) }
    }

    /// Called at launch. Does nothing when the user turned checks off or one ran recently,
    /// so starting the app ten times in a morning is still one request.
    func checkInBackground() {
        guard checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// `userInitiated` decides what silence means: a check from the menu says "you are up
    /// to date" and shows its errors, a background one keeps quiet unless it found
    /// something worth interrupting for.
    func check(userInitiated: Bool) {
        guard !state.isBusy else { return }
        task?.cancel()
        task = Task { await runCheck(userInitiated: userInitiated) }
    }

    private func runCheck(userInitiated: Bool) async {
        guard let current = runningVersion() else {
            state = .failed(Failure.noVersion.localizedDescription)
            if userInitiated { present() }
            return
        }
        state = .checking
        do {
            let data = try await fetch(Self.releasesURL)
            let releases = try GitHubRelease.decodeList(data)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
            if let newer = GitHubRelease.newest(in: releases, newerThan: current,
                                                skipping: skippedVersion) {
                state = .available(newer)
                present()
            } else {
                state = .upToDate
                if userInitiated { present() }
            }
        } catch {
            state = .failed(error.localizedDescription)
            // A background check that cannot reach GitHub is not worth a dialog.
            if userInitiated { present() }
        }
    }

    /// Hides this release. A later one is still offered — see `GitHubRelease.newest`.
    func skip(_ release: GitHubRelease) {
        skippedVersion = release.tag
        state = .idle
        isPresenting = false
    }

    func dismiss() {
        isPresenting = false
        if case .failed = state { state = .idle }
        if case .upToDate = state { state = .idle }
    }

    /// Waits for a check or install already under way. Only the tests need this; the app
    /// follows `state` instead of waiting on anything.
    func settle() async {
        await task?.value
    }

    /// Shows whatever `state` now holds, opening somewhere to show it first.
    private func present() {
        prepareToPresent()
        isPresenting = true
    }

    // MARK: Installing

    func install(_ release: GitHubRelease) {
        guard !state.isBusy else { return }
        task?.cancel()
        task = Task { await runInstall(release) }
    }

    private func runInstall(_ release: GitHubRelease) async {
        let bundle = Bundle.main.bundleURL
        pending = release
        // Everything is unpacked in here, and the install script deletes it once the swap
        // is done. Cleaning up on the way out instead would take the new app with it.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RDPManagerUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            guard let asset = release.appAsset else { throw Failure.noAsset }
            guard let team = CodeSignature.teamIdentifier(of: bundle),
                  let identifier = Bundle.main.bundleIdentifier else {
                throw Failure.unsignedHost
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            state = .downloading(0)
            let zip = try await download(asset, into: folder)

            state = .installing
            // Unpacking and verifying both shell out and take seconds. On the main actor
            // they freeze the window, which during an update reads as a crash.
            let app = try await Task.detached(priority: .userInitiated) {
                let unpacked = try Self.unzip(zip, into: folder)
                let app = try Self.appBundle(in: unpacked)
                try CodeSignature.verify(app: app, team: team, identifier: identifier)
                return app
            }.value
            try swap(to: app, replacing: bundle, workingIn: folder)
            // swap() relaunches us; nothing after this runs for long.
        } catch {
            try? FileManager.default.removeItem(at: folder)
            pending = nil
            state = .failed(error.localizedDescription)
            present()
        }
    }

    /// Reports how far along it is: a release is over twenty megabytes, which is long
    /// enough that a still spinner looks like a hang.
    private func download(_ asset: GitHubRelease.Asset, into folder: URL) async throws -> URL {
        var request = URLRequest(url: asset.url)
        request.timeoutInterval = 120
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(fraction)
            }
        }
        let (temporary, response) = try await URLSession.shared.download(
            for: request, delegate: progress)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.server(http.statusCode)
        }
        let destination = folder.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Turns the download's byte counts into a fraction for the sheet.
    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let report: (Double) -> Void

        init(report: @escaping (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten written: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            // A redirected download can report an unknown length; a bar is better left
            // where it is than sent backwards by dividing by -1.
            guard expected > 0 else { return }
            report(min(Double(written) / Double(expected), 1))
        }

        /// Required by the protocol. The async form of `download` hands back the file
        /// itself, so there is nothing to do with it here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    nonisolated private static func unzip(_ zip: URL, into workingFolder: URL) throws -> URL {
        let folder = workingFolder.appendingPathComponent("unpacked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = Pipe()
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodeSignature.Failure.unsigned("the download could not be unpacked. \(message)")
        }
        return folder
    }

    nonisolated private static func appBundle(in folder: URL) throws -> URL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw Failure.noAsset
        }
        return app
    }

    /// Replaces the running app and relaunches it.
    ///
    /// A bundle cannot be overwritten while it is the one executing, so the swap is handed
    /// to a script that waits for this process to exit first. The old copy is moved aside
    /// rather than deleted, and moved back if the new one fails to land, so a swap that
    /// goes wrong leaves a working app rather than none.
    private func swap(to new: URL, replacing destination: URL, workingIn folder: URL) throws {
        let script = """
        #!/bin/bash
        set -u
        new=\(Launcher.shellQuoted(new.path))
        dest=\(Launcher.shellQuoted(destination.path))
        work=\(Launcher.shellQuoted(folder.path))
        pid=\(ProcessInfo.processInfo.processIdentifier)
        old="$dest.old-$$"

        alive() { kill -0 "$pid" 2>/dev/null; }

        # Wait for the app to go. Asking it to quit can be refused — a sheet still
        # attached to a window is enough to cancel termination — so ask again, firmly,
        # rather than assume.
        for _ in $(seq 1 100); do alive || break; sleep 0.2; done
        if alive; then
          kill -TERM "$pid" 2>/dev/null
          for _ in $(seq 1 50); do alive || break; sleep 0.2; done
        fi
        # Still here: replacing a bundle out from under the process running it is how an
        # update corrupts an app. Leave everything alone and let the user try again.
        if alive; then
          rm -rf "$work" "$0"
          exit 1
        fi

        mv "$dest" "$old" || exit 1
        if ! ditto "$new" "$dest"; then
          # Put the working copy back rather than leave no app at all.
          rm -rf "$dest"
          mv "$old" "$dest"
          open "$dest"
          exit 1
        fi
        rm -rf "$old"
        xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        open "$dest"
        rm -rf "$work" "$0"
        """
        // Kept outside the folder it deletes, so the shell is not reading a script out
        // from under itself.
        let file = folder.deletingLastPathComponent()
            .appendingPathComponent("rdpmanager-install-\(UUID().uuidString).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        try process.run()

        // A sheet still attached to the window cancels termination outright — the app
        // simply stays up, and the script would then be replacing a running bundle. Take
        // the sheet down first and give SwiftUI a turn to do it before asking to quit.
        isPresenting = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.terminate(nil)
        }
    }
}
