import Foundation
import Combine

/// A record of the sessions started from this Mac.
///
/// Deliberately not part of the shared machine list. "What I connected to recently" is
/// personal rather than something the other admins need, and every click writing to a file
/// several Macs merge would put ordinary use in the way of real edits. So this is one file
/// per Mac, in the app's own folder, never on the share.
@MainActor
final class ConnectionLog: ObservableObject {
    static let shared = ConnectionLog()

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var machineID: UUID
        var type: ConnectionType
        var at: Date

        init(id: UUID = UUID(), machineID: UUID, type: ConnectionType, at: Date = Date()) {
            self.id = id
            self.machineID = machineID
            self.type = type
            self.at = at
        }
    }

    /// Enough to answer "when was I last on this machine" across a year of ordinary use
    /// while leaving a file nobody has to think about.
    static let limit = 2000

    /// Oldest first, which is the order the file is written in and the cheap end to trim.
    @Published private(set) var entries: [Entry] = []

    private let fileURL: URL

    /// Nonisolated so it can be a default argument to `init`, which runs before the actor
    /// has anything to isolate.
    nonisolated static var defaultFileURL: URL {
        StoreLocation.defaultDirectory.appendingPathComponent("connections.json")
    }

    init(fileURL: URL = ConnectionLog.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Writing

    func record(_ machine: Machine, via type: ConnectionType, at date: Date = Date()) {
        entries.append(Entry(machineID: machine.id, type: type, at: date))
        if entries.count > Self.limit {
            entries.removeFirst(entries.count - Self.limit)
        }
        save()
    }

    /// Drops a deleted machine's sessions, so the log does not keep names of machines that
    /// are gone and recents cannot offer one.
    func forget(_ machineID: UUID) {
        let before = entries.count
        entries.removeAll { $0.machineID == machineID }
        if entries.count != before { save() }
    }

    // MARK: - Reading

    /// Newest first, which is how every caller wants it.
    func history(for machineID: UUID, limit: Int = 50) -> [Entry] {
        entries.reversed().filter { $0.machineID == machineID }.prefix(limit).map { $0 }
    }

    func lastConnection(to machineID: UUID) -> Entry? {
        entries.last { $0.machineID == machineID }
    }

    func count(for machineID: UUID) -> Int {
        entries.count { $0.machineID == machineID }
    }

    /// The machines most recently connected to, each appearing once.
    func recentMachineIDs(limit: Int = 5) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for entry in entries.reversed() where !seen.contains(entry.machineID) {
            seen.insert(entry.machineID)
            result.append(entry.machineID)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([Entry].self, from: data) else { return }
        entries = decoded.sorted { $0.at < $1.at }
    }

    /// A log is not worth an error in front of the user, or worth losing a session over:
    /// failures here are swallowed on purpose.
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {}
    }
}
