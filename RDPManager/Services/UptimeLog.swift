import Foundation
import Combine

/// When machines went down and came back.
///
/// The poller already works all of this out every thirty seconds and used to keep only the
/// single most recent sighting. Writing the transitions down turns the same work into an
/// answer to a question you would otherwise need a monitoring system for: has this machine
/// been dropping?
///
/// One file per Mac, like the connection log. Each Mac sees the network from where it is
/// standing — a machine unreachable from the back office may be fine from the front — so
/// these are this Mac's observations and not a shared truth, and keeping them out of the
/// shared list means polling never writes to the file other Macs merge.
@MainActor
final class UptimeLog: ObservableObject {
    static let shared = UptimeLog()

    struct Change: Codable, Identifiable, Hashable {
        var id = UUID()
        var machineID: UUID
        /// True for coming back, false for going down.
        var up: Bool
        var at: Date

        init(id: UUID = UUID(), machineID: UUID, up: Bool, at: Date = Date()) {
            self.id = id
            self.machineID = machineID
            self.up = up
            self.at = at
        }
    }

    /// A completed outage: down at one time, back at another.
    struct Outage: Identifiable, Hashable {
        var id: UUID
        var began: Date
        /// Nil while the machine is still down.
        var ended: Date?

        var duration: TimeInterval? { ended.map { $0.timeIntervalSince(began) } }
    }

    static let limit = 5000

    /// Oldest first.
    @Published private(set) var changes: [Change] = []

    private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        StoreLocation.defaultDirectory.appendingPathComponent("uptime.json")
    }

    init(fileURL: URL = UptimeLog.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Writing

    /// Records a change of state. Repeating the state already recorded is ignored, so a
    /// machine that is simply still down does not fill the file.
    func record(_ machineID: UUID, up: Bool, at date: Date = Date()) {
        if let last = changes.last(where: { $0.machineID == machineID }), last.up == up { return }
        changes.append(Change(machineID: machineID, up: up, at: date))
        if changes.count > Self.limit {
            changes.removeFirst(changes.count - Self.limit)
        }
        save()
    }

    func forget(_ machineID: UUID) {
        let before = changes.count
        changes.removeAll { $0.machineID == machineID }
        if changes.count != before { save() }
    }

    // MARK: - Reading

    /// Outages, newest first. One per time the machine went down, left open while it is
    /// still down.
    func outages(for machineID: UUID, since: Date? = nil) -> [Outage] {
        var result: [Outage] = []
        var open: Outage?
        for change in changes where change.machineID == machineID {
            if change.up {
                if var outage = open {
                    outage.ended = change.at
                    result.append(outage)
                    open = nil
                }
            } else if open == nil {
                open = Outage(id: change.id, began: change.at, ended: nil)
            }
        }
        if let open { result.append(open) }
        if let since {
            // An outage counts if any of it falls inside the window.
            result = result.filter { ($0.ended ?? Date()) >= since }
        }
        return result.reversed()
    }

    /// How long the machine was down inside the window, and how many times.
    func downtime(for machineID: UUID, since: Date) -> (count: Int, total: TimeInterval) {
        let now = Date()
        var total: TimeInterval = 0
        var count = 0
        for outage in outages(for: machineID, since: since) {
            // Only the part inside the window, so a machine that was down for a week does
            // not report a week of downtime against the last day.
            let from = max(outage.began, since)
            let to = outage.ended ?? now
            guard to > from else { continue }
            total += to.timeIntervalSince(from)
            count += 1
        }
        return (count, total)
    }

    /// Of the window, the share of it the machine was reachable for. Nil when nothing was
    /// recorded in it, which is not the same as "it was up".
    func availability(for machineID: UUID, since: Date) -> Double? {
        guard changes.contains(where: { $0.machineID == machineID }) else { return nil }
        let window = Date().timeIntervalSince(since)
        guard window > 0 else { return nil }
        let down = downtime(for: machineID, since: since).total
        return max(0, min(1, (window - down) / window))
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
              let decoded = try? Self.decoder.decode([Change].self, from: data) else { return }
        changes = decoded.sorted { $0.at < $1.at }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(changes).write(to: fileURL, options: .atomic)
        } catch {}
    }
}
