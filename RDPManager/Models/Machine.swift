import Foundation

enum ConnectionType: String, Codable, CaseIterable, Identifiable {
    case rdp, vnc, ssh, web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rdp: return "RDP"
        case .vnc: return "VNC"
        case .ssh: return "SSH"
        case .web: return "Web"
        }
    }

    var systemImage: String {
        switch self {
        case .rdp: return "rectangle.connected.to.line.below"
        case .vnc: return "display"
        case .ssh: return "terminal"
        case .web: return "globe"
        }
    }
}

enum MachineKind: String, Codable, CaseIterable, Identifiable {
    case windows, mac, linux, device

    var id: String { rawValue }

    var label: String {
        switch self {
        case .windows: return "Windows"
        case .mac: return "Mac"
        case .linux: return "Linux"
        case .device: return "Device"
        }
    }

    var systemImage: String {
        switch self {
        case .windows: return "pc"
        case .mac: return "desktopcomputer"
        case .linux: return "server.rack"
        case .device: return "network"
        }
    }

    var defaultConnection: ConnectionType {
        switch self {
        case .windows: return .rdp
        case .mac: return .rdp
        case .linux: return .ssh
        case .device: return .web
        }
    }
}

/// Where a session's sound comes out.
///
/// Both clients take the same three numbers — `audiomode` in a .rdp file and
/// `/audio-mode:` on FreeRDP's command line — so one setting covers either one.
enum AudioMode: String, Codable, CaseIterable, Identifiable {
    /// Left on the machine being connected to, which is the default: a server you are
    /// administering should not start making noise on the desk you are sitting at.
    case remote
    /// Redirected down the connection and played here.
    case thisMac
    /// Played nowhere.
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remote: return "On the remote machine"
        case .thisMac: return "On this Mac"
        case .off: return "Don't play"
        }
    }

    /// The number both clients understand. Stored as a name rather than this number so
    /// the shared machine list stays readable and a renumbering could not silently
    /// change what a machine does.
    var rdpValue: Int {
        switch self {
        case .thisMac: return 0
        case .remote: return 1
        case .off: return 2
        }
    }
}

struct IPRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var ip: String
    var seenAt: Date

    init(ip: String, seenAt: Date = Date()) {
        self.id = UUID()
        self.ip = ip
        self.seenAt = seenAt
    }
}

struct Machine: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var hostname = ""
    var kind: MachineKind = .windows
    var lastIP: String?
    var macAddress = ""
    var group = ""
    var tags: [String] = []
    var notes = ""
    var primary: ConnectionType = .rdp
    var audio: AudioMode = .remote
    var username = ""
    /// Windows domain for RDP, kept apart from the username so `DOMAIN\\user` does not have
    /// to be typed into a field that is otherwise just a name. A username that still carries
    /// a backslash is split as before, so nothing already saved has to be retyped.
    var domain = ""
    /// Whether the poller watches this machine. A laptop that is legitimately off half the
    /// time otherwise produces a stream of offline alerts that teaches you to ignore them.
    var monitored = true
    /// Session options, applied to RDP.
    var multipleMonitors = false
    var shareClipboard = true
    /// A folder on this Mac to make available in the session. FreeRDP only — Windows App
    /// cannot be told about one through a handed .rdp file.
    var sharedFolder = ""
    /// Percentage, as both clients want it: 100, 140 or 180.
    var displayScale = 100
    var rdpPort = 3389
    var vncPort = 5900
    var sshPort = 22
    var webURL = ""
    var ipHistory: [IPRecord] = []
    var lastSeen: Date?
    var createdAt = Date()
    var modifiedAt = Date()

    init() {}

    /// Tolerant decoding so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? name
        kind = try c.decodeIfPresent(MachineKind.self, forKey: .kind) ?? .windows
        lastIP = try c.decodeIfPresent(String.self, forKey: .lastIP)
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        primary = try c.decodeIfPresent(ConnectionType.self, forKey: .primary) ?? kind.defaultConnection
        // Absent in files written before this setting existed, and in files written
        // by an older copy of the app on another Mac.
        audio = try c.decodeIfPresent(AudioMode.self, forKey: .audio) ?? .remote
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        monitored = try c.decodeIfPresent(Bool.self, forKey: .monitored) ?? true
        multipleMonitors = try c.decodeIfPresent(Bool.self, forKey: .multipleMonitors) ?? false
        shareClipboard = try c.decodeIfPresent(Bool.self, forKey: .shareClipboard) ?? true
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder) ?? ""
        let scale = try c.decodeIfPresent(Int.self, forKey: .displayScale) ?? 100
        displayScale = Self.allowedScales.contains(scale) ? scale : 100
        rdpPort = try c.decodeIfPresent(Int.self, forKey: .rdpPort) ?? 3389
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort) ?? 5900
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL) ?? ""
        ipHistory = try c.decodeIfPresent([IPRecord].self, forKey: .ipHistory) ?? []
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }

    /// What both clients accept. Anything else is treated as 100 rather than passed on,
    /// since a scale factor they reject fails the whole connection.
    static let allowedScales = [100, 140, 180]

    /// The domain and username to sign in with: the domain field when it is filled, and
    /// otherwise whatever is in front of a backslash in the username.
    var login: (domain: String, username: String) {
        if !domain.isEmpty { return (domain, username) }
        if let slash = username.firstIndex(of: "\\") {
            return (String(username[..<slash]), String(username[username.index(after: slash)...]))
        }
        return ("", username)
    }

    /// Address used when connecting: the last resolved IP when known, else the hostname.
    var connectHost: String {
        if let ip = lastIP, !ip.isEmpty { return ip }
        return displayHost
    }

    var displayHost: String { hostname.isEmpty ? name : hostname }

    func port(for type: ConnectionType) -> Int {
        switch type {
        case .rdp: return rdpPort
        case .vnc: return vncPort
        case .ssh: return sshPort
        case .web: return webTarget?.port ?? (webTarget?.scheme == "http" ? 80 : 443)
        }
    }

    var webTarget: URL? {
        let raw = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return URL(string: "https://\(connectHost)") }
        if raw.contains("://") { return URL(string: raw) }
        return URL(string: "https://\(raw)")
    }

    /// TCP port used to decide whether the machine is online before falling back to ping.
    var probePort: Int { port(for: primary) }

    /// Directed broadcast for Wake-on-LAN, assuming a /24 network.
    ///
    /// Only a fallback: `WakeOnLAN.directedBroadcast(for:)` works the real one out from the
    /// interface mask, and this is what is left when the machine is not on a subnet this Mac
    /// is on, where there is nothing better to go on than the commonest mask.
    var broadcastAddress: String? {
        guard let ip = lastIP else { return nil }
        var parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return nil }
        parts[3] = "255"
        return parts.joined(separator: ".")
    }

    var tagsText: String { tags.joined(separator: ", ") }
}

enum OnlineState: String {
    case unknown, online, offline

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

struct MachineStatus {
    var state: OnlineState = .unknown
    var latencyMs: Double?
    var lastChecked: Date?
    var lastSeen: Date?
    var resolvedIP: String?
}

/// A machine that was deleted, and when.
///
/// Without these a delete does not stick: another Mac that has not reloaded still has the
/// machine, writes the list back, and it reappears. The record is kept for a month, which is
/// far longer than any Mac is plausibly away from the share, and then forgotten.
struct Tombstone: Codable, Hashable, Identifiable {
    var id: UUID
    var at: Date
}

struct StoreDocument: Codable {
    var version: Int
    var machines: [Machine]
    var deleted: [Tombstone]

    /// How long a delete is remembered.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

    init(version: Int, machines: [Machine], deleted: [Tombstone] = []) {
        self.version = version
        self.machines = machines
        self.deleted = deleted
    }

    /// Tolerant for the same reason `Machine` is: a file written before deletes were
    /// recorded has no such key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        machines = try c.decodeIfPresent([Machine].self, forKey: .machines) ?? []
        deleted = try c.decodeIfPresent([Tombstone].self, forKey: .deleted) ?? []
    }
}

/// Merging one machine's record from two Macs.
///
/// The store used to resolve a conflict a whole machine at a time: the record with the later
/// `modifiedAt` won and the other was discarded. That loses edits that never actually
/// conflicted — one admin renaming a machine while another fixes its port means one of the
/// two changes is thrown away, and the one that survives depends on which Mac saved last.
///
/// This compares each field against the last version both Macs had seen, so a field only
/// one side touched is taken from that side whatever the timestamps say. Only a field both
/// sides changed, to different values, needs `modifiedAt` to settle it.
struct MachineMerge {
    let local: Machine
    let remote: Machine
    /// The last record both Macs are known to have agreed on: what this Mac last read from
    /// the file or wrote to it.
    let base: Machine
    private(set) var result: Machine

    init(local: Machine, remote: Machine, base: Machine) {
        self.local = local
        self.remote = remote
        self.base = base
        self.result = remote
    }

    mutating func field<T: Equatable>(_ keyPath: WritableKeyPath<Machine, T>) {
        let mine = local[keyPath: keyPath]
        let theirs = remote[keyPath: keyPath]
        let agreed = base[keyPath: keyPath]

        if mine == theirs { result[keyPath: keyPath] = mine }
        else if mine == agreed { result[keyPath: keyPath] = theirs }   // only they changed it
        else if theirs == agreed { result[keyPath: keyPath] = mine }   // only we changed it
        else {
            // Both changed it, to different things. Nothing here can tell which is right,
            // so the later edit wins — the old whole-record rule, now confined to the one
            // field it is actually needed for.
            result[keyPath: keyPath] = local.modifiedAt >= remote.modifiedAt ? mine : theirs
        }
    }

    static func merge(local: Machine, remote: Machine, base: Machine?) -> Machine {
        // With nothing known to have been agreed on there is no way to tell a change from
        // an absence, so this falls back to the old rule.
        guard let base else {
            return local.modifiedAt > remote.modifiedAt ? local : remote
        }

        // A record older than the version we agreed on is not an edit, it is a copy that
        // has not caught up — another Mac that has been away from the share, or one still
        // holding the list from yesterday. Comparing fields against the baseline would read
        // every field it has not yet heard about as a deliberate change back.
        guard remote.modifiedAt >= base.modifiedAt else { return local }

        var merge = MachineMerge(local: local, remote: remote, base: base)
        merge.field(\.name)
        merge.field(\.hostname)
        merge.field(\.kind)
        merge.field(\.macAddress)
        merge.field(\.group)
        merge.field(\.tags)
        merge.field(\.notes)
        merge.field(\.primary)
        merge.field(\.audio)
        merge.field(\.username)
        merge.field(\.domain)
        merge.field(\.monitored)
        merge.field(\.multipleMonitors)
        merge.field(\.shareClipboard)
        merge.field(\.sharedFolder)
        merge.field(\.displayScale)
        merge.field(\.rdpPort)
        merge.field(\.vncPort)
        merge.field(\.sshPort)
        merge.field(\.webURL)
        merge.field(\.lastIP)

        var merged = merge.result
        // Observations rather than edits: whoever saw the machine more recently saw it, and
        // both Macs' sightings are worth keeping.
        merged.lastSeen = [local.lastSeen, remote.lastSeen].compactMap { $0 }.max()
        merged.ipHistory = mergedHistory(local.ipHistory, remote.ipHistory)
        // The record is as old as the first Mac to have it and as new as the last edit.
        merged.createdAt = min(local.createdAt, remote.createdAt)
        merged.modifiedAt = max(local.modifiedAt, remote.modifiedAt)
        return merged
    }

    /// Both Macs' sightings, in order, without the duplicates that come of two Macs
    /// recording the same change.
    static func mergedHistory(_ mine: [IPRecord], _ theirs: [IPRecord]) -> [IPRecord] {
        var seen = Set<String>()
        var all = (mine + theirs).sorted { $0.seenAt < $1.seenAt }
        all = all.filter { record in
            // Two Macs noticing the same address at nearly the same moment is one event.
            let key = "\(record.ip)@\(Int(record.seenAt.timeIntervalSince1970))"
            return seen.insert(key).inserted
        }
        if all.count > 200 { all.removeFirst(all.count - 200) }
        return all
    }
}
