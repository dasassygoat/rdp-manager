import Foundation
import Combine

/// Owns the machine list, persists it to a JSON file that may live on a share or in
/// iCloud Drive, and merges in changes that other Macs write to the same file.
@MainActor
final class MachineStore: ObservableObject {
    static let shared = MachineStore()

    @Published private(set) var machines: [Machine] = []
    @Published var statuses: [UUID: MachineStatus] = [:]
    @Published private(set) var storeURL: URL
    @Published var lastError: String?

    static var defaultDirectory: URL { StoreLocation.defaultDirectory }

    static var defaultStoreURL: URL { StoreLocation.defaultFileURL }

    private static let pathKey = StoreLocation.pathKey

    private var watcher: FileWatcher?
    private var pollTimer: Timer?
    private var lastSavedData: Data?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `storeURL` overrides the saved location and `watchForChanges` disables the file
    /// watcher and reload timer; both are for tests, which bind a store to a temp file.
    init(storeURL: URL? = nil, watchForChanges: Bool = true) {
        if let storeURL {
            self.storeURL = storeURL
        } else if let saved = UserDefaults.standard.string(forKey: Self.pathKey), !saved.isEmpty {
            self.storeURL = URL(fileURLWithPath: saved)
        } else {
            self.storeURL = Self.defaultStoreURL
        }
        load()
        if watchForChanges { startWatching() }
    }

    // MARK: - Lookup

    func machine(_ id: UUID) -> Machine? {
        machines.first { $0.id == id }
    }

    var groups: [String] {
        Array(Set(machines.map(\.group).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func count(where state: OnlineState) -> Int {
        machines.filter { (statuses[$0.id]?.state ?? .unknown) == state }.count
    }

    // MARK: - Editing

    func add(_ machine: Machine) {
        var m = machine
        m.modifiedAt = Date()
        machines.append(m)
        sortMachines()
        save()
    }

    func update(_ machine: Machine) {
        guard let i = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        var m = machine
        m.modifiedAt = Date()
        machines[i] = m
        sortMachines()
        save()
    }

    func remove(_ id: UUID) {
        machines.removeAll { $0.id == id }
        statuses[id] = nil
        Keychain.deletePassword(for: id)
        save()
    }

    /// Records a newly resolved IP. Returns true when it differs from the last known one.
    @discardableResult
    func recordIP(_ ip: String, for id: UUID) -> Bool {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return false }
        guard machines[i].lastIP != ip else { return false }
        machines[i].lastIP = ip
        machines[i].ipHistory.append(IPRecord(ip: ip))
        if machines[i].ipHistory.count > 200 {
            machines[i].ipHistory.removeFirst(machines[i].ipHistory.count - 200)
        }
        machines[i].modifiedAt = Date()
        save()
        return true
    }

    func recordLastSeen(_ date: Date, for id: UUID) {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[i].lastSeen = date
        machines[i].modifiedAt = Date()
        save()
    }

    private func sortMachines() {
        machines.sort {
            if $0.group != $1.group {
                if $0.group.isEmpty { return false }
                if $1.group.isEmpty { return true }
                return $0.group.localizedCaseInsensitiveCompare($1.group) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Location

    /// Points the store at a different file. If the file already exists its contents are
    /// loaded (joining an existing shared list); otherwise the current list is written there.
    func setStoreURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.pathKey)
        storeURL = url
        lastSavedData = nil
        if FileManager.default.fileExists(atPath: url.path) {
            load()
        } else {
            save()
        }
        startWatching()
    }

    func useDefaultLocation() {
        setStoreURL(Self.defaultStoreURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else {
            machines = []
            return
        }
        do {
            let doc = try decoder.decode(StoreDocument.self, from: data)
            machines = doc.machines
            sortMachines()
            lastSavedData = data
            lastError = nil
        } catch {
            lastError = "Could not read \(storeURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(StoreDocument(version: 1, machines: machines))
            try data.write(to: storeURL, options: .atomic)
            lastSavedData = data
            lastError = nil
        } catch {
            lastError = "Could not write \(storeURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Reloads when another process changed the file. Called by the watcher and a slow timer
    /// (network shares and iCloud do not always deliver file events).
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL), data != lastSavedData else { return }
        guard let doc = try? decoder.decode(StoreDocument.self, from: data) else { return }
        merge(doc.machines)
        lastSavedData = data
    }

    /// Last-writer-wins per machine, by `modifiedAt`.
    private func merge(_ incoming: [Machine]) {
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date)
            ?? .distantPast
        let local = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let incomingIDs = Set(incoming.map(\.id))

        var merged: [Machine] = incoming.map { remote in
            if let mine = local[remote.id], mine.modifiedAt > remote.modifiedAt { return mine }
            return remote
        }
        // Keep machines we changed after the file was written and that are missing on disk.
        for mine in machines where !incomingIDs.contains(mine.id) && mine.modifiedAt > fileDate {
            merged.append(mine)
        }

        let keptLocalChanges = merged != incoming
        let mergedIDs = Set(merged.map(\.id))
        machines = merged
        sortMachines()
        for id in statuses.keys where !mergedIDs.contains(id) {
            statuses[id] = nil
        }
        if keptLocalChanges { save() }
    }

    private func startWatching() {
        watcher = FileWatcher(url: storeURL) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadFromDisk() }
        }
    }

    // MARK: - Export / import

    func exportData() throws -> Data {
        try encoder.encode(StoreDocument(version: 1, machines: machines))
    }

    /// Imports machines from a JSON export. Existing machines with the same id are replaced.
    func importData(_ data: Data) throws -> Int {
        let doc = try decoder.decode(StoreDocument.self, from: data)
        for m in doc.machines {
            if let i = machines.firstIndex(where: { $0.id == m.id }) {
                machines[i] = m
            } else {
                machines.append(m)
            }
        }
        sortMachines()
        save()
        return doc.machines.count
    }
}
