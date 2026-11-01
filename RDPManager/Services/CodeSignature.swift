import Foundation

/// Checks that a downloaded app is the same app, from the same developer, as the one
/// running. This is the only thing standing between an update and running whatever a
/// hijacked connection or a compromised release hands over, so it fails closed: anything
/// it cannot establish is a refusal, never a warning.
enum CodeSignature {
    enum Failure: LocalizedError {
        case unsigned(String)
        case wrongTeam(found: String, expected: String)
        case wrongIdentifier(found: String, expected: String)
        case notNotarized(String)

        var errorDescription: String? {
            switch self {
            case .unsigned(let detail):
                return "The downloaded app is not signed as expected: \(detail)"
            case .wrongTeam(let found, let expected):
                return "The downloaded app is signed by team \(found), not \(expected). "
                    + "It was not published by the developer of this app, so it was not installed."
            case .wrongIdentifier(let found, let expected):
                return "The downloaded app identifies itself as \(found), not \(expected), "
                    + "so it was not installed."
            case .notNotarized(let detail):
                return "The downloaded app was rejected by macOS: \(detail)"
            }
        }
    }

    /// Runs a tool and hands back everything it said. Both streams are read before waiting,
    /// since `codesign` writes its detail to stderr and a full pipe would deadlock.
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
            + err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Pulls `TeamIdentifier` out of `codesign -d --verbose=4`. An ad-hoc signed build —
    /// what a local Debug build is — reports "not set", which is not a team.
    static func parseTeamIdentifier(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: "TeamIdentifier=") else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    static func teamIdentifier(of app: URL) -> String? {
        let result = run("/usr/bin/codesign", ["-d", "--verbose=4", app.path])
        guard result.status == 0 else { return nil }
        return parseTeamIdentifier(result.output)
    }

    static func bundleIdentifier(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// Accepts the download only if it is intact, signed by `team`, carries `identifier`,
    /// and passes the Gatekeeper check for something being installed — which is what
    /// requires it to have been notarized.
    static func verify(app: URL, team: String, identifier: String) throws {
        guard let found = bundleIdentifier(of: app) else {
            throw Failure.unsigned("it has no bundle identifier")
        }
        guard found == identifier else {
            throw Failure.wrongIdentifier(found: found, expected: identifier)
        }

        // The requirement is part of the verify call rather than a separate lookup: asking
        // who signed it and then trusting the answer leaves a gap between the two.
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let verified = run("/usr/bin/codesign",
                           ["--verify", "--deep", "--strict", "--verbose=2",
                            "-R", "=\(requirement)", app.path])
        guard verified.status == 0 else {
            if let actual = teamIdentifier(of: app), actual != team {
                throw Failure.wrongTeam(found: actual, expected: team)
            }
            throw Failure.unsigned(firstLine(of: verified.output))
        }

        let assessed = run("/usr/sbin/spctl", ["-a", "-t", "install", "-vv", app.path])
        guard assessed.status == 0 else {
            throw Failure.notNotarized(firstLine(of: assessed.output))
        }
    }

    private static func firstLine(of output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").first.map(String.init)
            ?? (trimmed.isEmpty ? "no detail given" : trimmed)
    }
}
