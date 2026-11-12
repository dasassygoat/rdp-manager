import Foundation

/// Recognising, in the shared list, the Mac the app is running on.
///
/// The list is shared between Macs, so every Mac in it is listed on every Mac — including
/// the one you are sitting at, where its own row is the one row that can do nothing.
/// Connecting a machine to itself is not a thing to want.
///
/// Identity is taken from the two things that are the machine rather than where it happens
/// to be: its hardware addresses, and the names it answers to. Not its IP address — a
/// record whose address is stale would make this Mac out to be whichever machine holds
/// that address now, and hiding the wrong machine is worse than hiding none.
enum ThisMac {
    /// What this Mac is, gathered once. Both halves cost a system call or two, and neither
    /// changes while the app is running often enough to pay for that on every redraw; a
    /// renamed Mac or a new interface is picked up at the next launch.
    struct Identity: Equatable {
        /// Canonical, as `ARPTable.normalize` writes them.
        var macs: Set<String> = []
        /// Folded by `fold`, so a comparison is a set lookup rather than a decision.
        var names: Set<String> = []

        var isEmpty: Bool { macs.isEmpty && names.isEmpty }
    }

    /// Computed on first use. `nonisolated(unsafe)` rather than a lazy global because the
    /// identity is wanted from the main actor and from tests, and the work behind it is
    /// read-only system state.
    nonisolated(unsafe) private static var cached: Identity?

    static var current: Identity {
        if let cached { return cached }
        let identity = Identity(macs: hardwareAddresses(), names: hostNames())
        cached = identity
        return identity
    }

    /// Only for a Mac that has been renamed or has gained an interface since launch.
    static func forget() {
        cached = nil
    }

    /// Whether a record in the list describes this Mac.
    ///
    /// An empty field never matches: a machine with no MAC on file and no hostname is not
    /// this Mac, and taking an empty string as agreement would make it every Mac.
    static func matches(_ machine: Machine, identity: Identity = current) -> Bool {
        matches(mac: machine.macAddress, names: [machine.hostname, machine.name],
                identity: identity)
    }

    /// The same question asked of loose fields, for a host a sweep has just found and not
    /// yet made a record of.
    static func matches(mac: String, names: [String], identity: Identity = current) -> Bool {
        if let mac = ARPTable.normalize(mac), identity.macs.contains(mac) { return true }
        for name in names {
            let folded = fold(name)
            if !folded.isEmpty, identity.names.contains(folded) { return true }
        }
        return false
    }

    /// Every record that is this Mac. Not one: a Mac with several interfaces gets a record
    /// per address a sweep found it at, so this Mac was in a real list three times — once
    /// under its own name and twice as `host-NN` from its other interfaces. Hiding only the
    /// first would have left the other two sitting there.
    static func identify(in machines: [Machine], identity: Identity = current) -> [UUID] {
        machines.filter { matches($0, identity: identity) }.map(\.id)
    }

    /// Lowercased, trimmed, and without the trailing dot or `.local` that the same machine
    /// is written with in some places and not others.
    static func fold(_ name: String) -> String {
        // A Mac is called "Bryan’s Mac Studio" by Sharing settings, with the apostrophe
        // macOS types, and "Bryan's Mac Studio" by anyone who typed it into this app.
        var text = name
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        if text.hasSuffix(".local") { text.removeLast(".local".count) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Every interface's hardware address. All of them, not just Wi-Fi and Ethernet: a
    /// bridge or a Thunderbolt interface is still this Mac, and a record could have been
    /// filled in from any of them.
    static func hardwareAddresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: Set<String> = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self)
            guard link.pointee.sdl_alen == 6 else { continue }
            // `sockaddr_dl` is eight fixed bytes, then the interface name followed by the
            // hardware address. Read through the raw pointer rather than `sdl_data`: the
            // name and address together run past the twelve bytes the struct declares,
            // which is why `sa_len` exists. Same reasoning as `ARPTable.linkAddress`.
            let start = 8 + Int(link.pointee.sdl_nlen)
            let bytes = (0..<6).map {
                UnsafeRawPointer(address).load(fromByteOffset: start + $0, as: UInt8.self)
            }
            if let mac = ARPTable.normalize(
                bytes.map { String(format: "%02x", $0) }.joined(separator: ":")),
               !Self.placeholders.contains(mac) {
                addresses.insert(mac)
            }
        }
        return addresses
    }

    /// Addresses that are not an identity. macOS hands a process without Local Network
    /// access the same anonymized address for every interface, so a Mac that has not been
    /// granted it reports `02:00:00:00:00:00` throughout; taking that as this Mac’s MAC
    /// would make it any machine whose record happens to carry the same placeholder. The
    /// names are the half that works either way.
    static let placeholders: Set<String> = ["02:00:00:00:00:00", "00:00:00:00:00:00"]

    /// The names this Mac answers to: its hostname, and the name it is called in Sharing
    /// settings, which is what someone typing a machine into this app would have used.
    ///
    /// Deliberately not `Host.current().names`, which resolves — a reverse lookup on a slow
    /// or absent DNS server would stall whatever asked for the identity.
    static func hostNames() -> Set<String> {
        var names: Set<String> = []
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if gethostname(&buffer, buffer.count) == 0 {
            names.insert(String(cString: buffer))
        }
        if let computer = computerName() { names.insert(computer) }
        return Set(names.map(fold).filter { !$0.isEmpty })
    }

    /// The Sharing-settings name, read without resolving anything.
    private static func computerName() -> String? {
        // SCDynamicStoreCopyComputerName lives in SystemConfiguration, which this target
        // does not otherwise link; `scutil` reads the same value and this is asked once.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "ComputerName"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
