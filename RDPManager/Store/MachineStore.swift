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

    /// The records as this Mac last agreed with the file: what was read from it or written
    /// to it. A merge compares against this to tell an edit from an absence, so that a field
    /// only one Mac touched is kept whatever the timestamps say.
    private var baseline: [UUID: Machine] = [:]

    /// Machines deleted here or elsewhere, and when. Written to the file so the delete
    /// reaches the other Macs instead of being undone by the first one to save a stale copy.
    private var tombstones: [UUID: Date] = [:]

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
        // Adding something back undoes its delete, here and everywhere else.
        tombstones[m.id] = nil
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
        tombstones[id] = Date()
        save()
    }

    /// Records a newly resolved IP. Returns true when it differs from the last known one.
    ///
    /// Deliberately does not touch `modifiedAt`. These are observations, not edits: every
    /// Mac watching the same machine notices the same address change, and if each sighting
    /// counted as an edit then the Mac that polled most recently would win every merge and
    /// carry its own stale copy of the settings over everyone else's work.
    @discardableResult
    func recordIP(_ ip: String, for id: UUID) -> Bool {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return false }
        guard machines[i].lastIP != ip else { return false }
        machines[i].lastIP = ip
        machines[i].ipHistory.append(IPRecord(ip: ip))
        if machines[i].ipHistory.count > 200 {
            machines[i].ipHistory.removeFirst(machines[i].ipHistory.count - 200)
        }
        save()
        return true
    }

    /// Also an observation rather than an edit — see `recordIP`.
    func recordLastSeen(_ date: Date, for id: UUID) {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[i].lastSeen = date
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
            setBaseline(to: doc.machines)
            tombstones = Dictionary(doc.deleted.map { ($0.id, $0.at) }, uniquingKeysWith: max)
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
            pruneTombstones()
            let data = try encoder.encode(document())
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            backUp(before: data)
            try data.write(to: storeURL, options: .atomic)
            lastSavedData = data
            // An existing baseline entry is deliberately NOT moved here. It stands for the
            // last version both Macs are known to have seen, and another Mac editing right
            // now started from what was on disk before this write, not from this write.
            //
            // A machine with no entry is different: this write is the first time it existed
            // anywhere, so any copy another Mac ends up with descends from exactly this.
            for machine in machines where baseline[machine.id] == nil {
                baseline[machine.id] = machine
            }
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
        merge(doc)
        lastSavedData = data
    }

    /// Field by field against the last version both Macs agreed on, so an edit here and an
    /// unrelated edit there both survive. See `MachineMerge`.
    private func merge(_ incoming: StoreDocument) {
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date)
            ?? .distantPast
        let local = Dictionary(machines.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let incomingIDs = Set(incoming.machines.map(\.id))

        // Deletes from both sides, the later record winning for any machine both mention.
        for stone in incoming.deleted {
            tombstones[stone.id] = max(tombstones[stone.id] ?? .distantPast, stone.at)
        }

        var merged: [Machine] = incoming.machines.compactMap { remote in
            guard let mine = local[remote.id] else { return remote }
            return MachineMerge.merge(local: mine, remote: remote, base: baseline[remote.id])
        }
        // Keep machines we changed after the file was written and that are missing on disk.
        for mine in machines where !incomingIDs.contains(mine.id) && mine.modifiedAt > fileDate {
            merged.append(mine)
        }

        // A machine edited after it was deleted was put back deliberately; otherwise the
        // delete stands, however many Macs still have a copy.
        merged = merged.filter { machine in
            guard let deletedAt = tombstones[machine.id] else { return true }
            if machine.modifiedAt > deletedAt {
                tombstones[machine.id] = nil
                return true
            }
            return false
        }

        let changedHere = merged != incoming.machines
            || tombstones.count != incoming.deleted.count
        let mergedIDs = Set(merged.map(\.id))
        machines = merged
        sortMachines()
        for id in statuses.keys where !mergedIDs.contains(id) {
            statuses[id] = nil
        }
        // Either way the file's own records are now what both Macs have seen.
        setBaseline(to: incoming.machines)
        if changedHere { save() }
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

    private func document() -> StoreDocument {
        StoreDocument(
            version: 1,
            machines: machines,
            deleted: tombstones.map { Tombstone(id: $0.key, at: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private func setBaseline(to records: [Machine]) {
        baseline = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    private func pruneTombstones() {
        let cutoff = Date().addingTimeInterval(-StoreDocument.tombstoneLifetime)
        tombstones = tombstones.filter { $0.value > cutoff }
    }

    func exportData() throws -> Data {
        try encoder.encode(document())
    }

    /// Imports machines from a JSON export. Existing machines with the same id are replaced.
    func importData(_ data: Data) throws -> Int {
        let doc = try decoder.decode(StoreDocument.self, from: data)
        for m in doc.machines {
            // Importing a machine is asking for it back.
            tombstones[m.id] = nil
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
