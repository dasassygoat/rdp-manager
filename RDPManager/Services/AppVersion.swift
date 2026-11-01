import Foundation

/// A release number, for deciding whether what is published is newer than what is running.
///
/// Comparing these as strings is the classic way to ship an updater that stops offering
/// updates at 0.10.0, because "0.10.0" < "0.9.0" alphabetically. Numbers are compared as
/// numbers, a missing component counts as zero so 1.2 and 1.2.0 are the same release, and
/// a pre-release suffix sorts *before* the release it leads to, as 1.0-beta does for 1.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    /// What followed the first `-`, lowercased. Empty for a normal release.
    let prerelease: String

    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tags are written both ways; "v1.2.0" and "1.2.0" are the same release.
        if body.lowercased().hasPrefix("v") { body.removeFirst() }
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, !head.isEmpty else { return nil }
        let fields = head.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.allSatisfy(\.isNumber),
                  let value = Int(field) else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
        self.prerelease = parts.count > 1 ? parts[1].lowercased() : ""
    }

    var description: String {
        let body = numbers.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? body : "\(body)-\(prerelease)"
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        padded(lhs, rhs) == padded(rhs, lhs) && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let left = padded(lhs, rhs)
        let right = padded(rhs, lhs)
        if left != right { return left.lexicographicallyPrecedes(right) }
        // Same numbers: 1.0-beta comes before 1.0, and two pre-releases go alphabetically.
        if lhs.prerelease == rhs.prerelease { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        return lhs.prerelease < rhs.prerelease
    }

    /// Both padded to the same length with zeros, so 1.2 and 1.2.0 compare equal.
    private static func padded(_ version: AppVersion, _ other: AppVersion) -> [Int] {
        let width = max(version.numbers.count, other.numbers.count)
        return version.numbers + Array(repeating: 0, count: width - version.numbers.count)
    }

    /// What this copy of the app reports, from the bundle it is running out of.
    static var running: AppVersion? {
        guard let text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppVersion(text)
    }
}
