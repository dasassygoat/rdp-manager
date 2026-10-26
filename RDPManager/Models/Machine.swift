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
    var username = ""
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
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        rdpPort = try c.decodeIfPresent(Int.self, forKey: .rdpPort) ?? 3389
        vncPort = try c.decodeIfPresent(Int.self, forKey: .vncPort) ?? 5900
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL) ?? ""
        ipHistory = try c.decodeIfPresent([IPRecord].self, forKey: .ipHistory) ?? []
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
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

struct StoreDocument: Codable {
    var version: Int
    var machines: [Machine]
}
