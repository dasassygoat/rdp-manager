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

    /// Set when the list could not be read: the file is there but unreadable or not a
    /// machine list, or the folder a chosen location lives in is missing. Saving is refused
    /// while it is set, because everything in memory is then a placeholder standing in for a
    /// file that may still be perfectly good.
    @Published private(set) var loadFailed = false

    static var defaultDirectory: URL { StoreLocation.defaultDirectory }

    static var defaultStoreURL: URL { StoreLocation.defaultFileURL }

    /// How many saved copies of the list to keep.
    static let backupCount = 10

    /// Saved copies live beside the app's own data rather than next to the list itself, so
    /// that several Macs sharing one file do not each drop copies onto the share, and so a
    /// share that has gone away still leaves something local to restore from.
    static var defaultBackupDirectory: URL {
        StoreLocation.defaultDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// An instance property so tests can point it at a temporary folder.
    var backupDirectory: URL = MachineStore.defaultBackupDirectory

    /// Whether the user pointed the list somewhere themselves.
    var isCustomLocation: Bool { storeURL != Self.defaultStoreURL }

    /// A path on a volume that is not mounted. Saving has to refuse here rather than create
    /// the folders: `/Volumes/Share` with nothing mounted on it is an ordinary empty folder
    /// as far as writing is concerned, so the list would land in a local copy that shadows
    /// the mount point, and the next Mac to look would see a different list at the same path.
    var isOnMissingVolume: Bool {
        let parts = storeURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
    }

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

    /// Every tag in use, once each. Unlike groups a machine can carry several, so this is
    /// the flattened set rather than one value per machine.
    var tags: [String] {
        Array(Set(machines.flatMap(\.tags).filter { !$0.isEmpty }))
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
        let fm = FileManager.default

        guard fm.fileExists(atPath: storeURL.path) else {
            // No file yet. At the default location that is simply a first run, and writing
            // one is the right thing. At a folder the user chose it may instead be a share
            // that has not mounted, where creating the folder would put a local one over the
            // mount point and quietly split the list in two.
            machines = []
            lastSavedData = nil
            if isOnMissingVolume {
                fail("\(storeURL.pathComponents[2]) is not mounted.")
            } else {
                loadFailed = false
                lastError = nil
            }
            return
        }

        guard let data = try? Data(contentsOf: storeURL) else {
            machines = []
            lastSavedData = nil
            fail("Could not read \(storeURL.lastPathComponent).")
            return
        }

        do {
            let doc = try decoder.decode(StoreDocument.self, from: data)
            machines = doc.machines
            sortMachines()
            lastSavedData = data
            loadFailed = false
            lastError = nil
        } catch {
            // Readable, but not a machine list: half-written by another Mac, or hand-edited
            // into something that will not parse. Showing an empty list is survivable.
            // Saving it over the real one is not.
            machines = []
            lastSavedData = nil
            fail("Could not read \(storeURL.lastPathComponent): \(error.localizedDescription).")
        }
    }

    private func fail(_ reason: String) {
        loadFailed = true
        lastError = reason + " Nothing will be saved until it can be read."
    }

    /// Tries the file again, for when a share finally mounts. The reload timer calls this
    /// while the load is failing, and Settings offers it as a button.
    func retryLoad() {
        load()
    }

    private func save() {
        // Never write over a list that could not be read. This is the whole reason
        // `loadFailed` exists: an unmounted share or a half-written file would otherwise be
        // replaced by the empty list being shown in its place.
        guard !loadFailed else { return }
        do {
            let data = try encoder.encode(StoreDocument(version: 1, machines: machines))
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            backUp(before: data)
            try data.write(to: storeURL, options: .atomic)
            lastSavedData = data
            lastError = nil
        } catch {
            lastError = "Could not write \(storeURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Keeps the copy that is about to be replaced, so a bad merge or a mistaken import can
    /// be undone. Only when the file is actually changing, and never at the cost of the save
    /// itself: a backup that cannot be written is not a reason to lose the edit.
    private func backUp(before newData: Data) {
        guard let existing = try? Data(contentsOf: storeURL), existing != newData else { return }
        do {
            try FileManager.default.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true)
            try existing.write(to: nextBackupURL(), options: .atomic)
            pruneBackups()
        } catch {}
    }

    /// A name no existing backup has. Two saves inside the same millisecond are easy to
    /// produce — an import is one — and the later one must not erase the earlier.
    private func nextBackupURL() -> URL {
        let stamp = Self.backupStamp.string(from: Date())
        var url = backupDirectory.appendingPathComponent("machines-\(stamp).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = backupDirectory.appendingPathComponent("machines-\(stamp)-\(suffix).json")
            suffix += 1
        }
        return url
    }

    private func pruneBackups() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)
        else { return }
        // The stamp sorts the same way lexically as it does in time.
        let backups = names.filter { $0.hasPrefix("machines-") && $0.hasSuffix(".json") }.sorted()
        guard backups.count > Self.backupCount else { return }
        for name in backups.prefix(backups.count - Self.backupCount) {
            try? FileManager.default.removeItem(at: backupDirectory.appendingPathComponent(name))
        }
    }

    private static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Reloads when another process changed the file. Called by the watcher and a slow timer
    /// (network shares and iCloud do not always deliver file events).
    func reloadFromDisk() {
        // While the list cannot be read there is nothing to merge into — try the whole load
        // again instead, which is how a share that mounts late recovers on its own.
        if loadFailed { load(); return }
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
