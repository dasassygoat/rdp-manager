import AppKit
import Foundation

/// Puts `rdpm` on the PATH. The binary ships inside the app bundle, so installing is only
/// a symlink: replacing the app then updates the command with it.
@MainActor
enum CommandLineTool {
    static let defaultDestination = URL(fileURLWithPath: "/usr/local/bin/rdpm")

    /// Marks a link as ours, so uninstalling cannot remove an unrelated `rdpm`.
    static let bundleMarker = "RDP Manager.app/Contents/Helpers/rdpm"

    enum Failure: LocalizedError {
        case missingBinary
        case notOurs(String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                return "This copy of RDP Manager has no rdpm inside it. Rebuild the app, or "
                    + "run scripts/install-cli.sh from the repository."
            case .notOurs(let path):
                return "\(path) was not installed by RDP Manager, so it was left alone. "
                    + "Remove it yourself if you meant to replace it."
            case .cancelled:
                return "Installation was cancelled."
            case .failed(let message):
                return message
            }
        }
    }

    /// The copy inside this bundle, when there is one.
    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rdpm")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// What the installed command points at, whether a link or a real file.
    static func installedSource(at destination: URL = defaultDestination) -> URL? {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            let url = URL(fileURLWithPath: target)
            return url.path.hasPrefix("/")
                ? url
                : destination.deletingLastPathComponent().appendingPathComponent(target).standardized
        }
        return fm.fileExists(atPath: destination.path) ? destination : nil
    }

    /// Installed and pointing at this bundle's copy. A link left behind by an app that has
    /// moved or been deleted reads as not current, which is what Settings shows.
    static func isCurrent(at destination: URL = defaultDestination) -> Bool {
        guard let bundled = bundledURL,
              let installed = installedSource(at: destination) else { return false }
        return installed.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path
    }

    @discardableResult
    static func install(
        source: URL? = nil,
        at destination: URL = defaultDestination
    ) throws -> URL {
        // Checked whatever the source is: linking to a binary that is not there would
        // leave a dangling link and still look like a success.
        guard let source = source ?? bundledURL,
              FileManager.default.isExecutableFile(atPath: source.path) else {
            throw Failure.missingBinary
        }
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()

        // The quick path: somewhere already writable, which /usr/local/bin often is on a
        // Mac with developer tools. Otherwise macOS asks for an administrator.
        if fm.isWritableFile(atPath: directory.path) || !fm.fileExists(atPath: directory.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                if installedSource(at: destination) != nil || isSymbolicLink(destination) {
                    try fm.removeItem(at: destination)
                }
                try fm.createSymbolicLink(at: destination, withDestinationURL: source)
                return destination
            } catch {
                // Fall through and try with authorisation.
            }
        }
        try runPrivileged("""
            /bin/mkdir -p \(Launcher.shellQuoted(directory.path)) && \
            /bin/ln -sfn \(Launcher.shellQuoted(source.path)) \(Launcher.shellQuoted(destination.path))
            """)
        return destination
    }

    static func uninstall(at destination: URL = defaultDestination) throws {
        let fm = FileManager.default
        guard isSymbolicLink(destination) || fm.fileExists(atPath: destination.path) else { return }
        guard let installed = installedSource(at: destination),
              installed.path.contains(bundleMarker) else {
            throw Failure.notOurs(destination.path)
        }
        if fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
            do {
                try fm.removeItem(at: destination)
                return
            } catch {
                // Fall through and try with authorisation.
            }
        }
        try runPrivileged("/bin/rm -f \(Launcher.shellQuoted(destination.path))")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Runs one shell command as an administrator. macOS shows the password prompt; the
    /// password never reaches this process.
    private static func runPrivileged(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw Failure.failed("Could not ask for permission: \(error.localizedDescription)")
        }
        let message = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        // -128 is what AppleScript reports when the password prompt is dismissed.
        if message.contains("-128") { throw Failure.cancelled }
        throw Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
