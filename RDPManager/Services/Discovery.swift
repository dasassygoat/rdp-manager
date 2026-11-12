import Foundation
import Combine

/// Finds machines on the local network so they do not have to be typed in by hand.
///
/// How a host is decided to exist: every candidate address is probed on a handful of
/// service ports, concurrently, and anything that accepts a connection is a host. This
/// finds Windows machines that drop ICMP, and needs no `ping` subprocess per address.
///
/// The sweep then reads the ARP cache, which the probes above will have populated, to fill
/// in MAC addresses for Wake-on-LAN and to notice hosts that are on the network but are not
/// listening on anything the app knows. Reading it is best-effort: when it comes back empty
/// discovery still works from the port probes alone, it just cannot fill in a MAC, and
/// `macsAvailable` says which happened so the UI can tell the user rather than silently
/// omitting them.
@MainActor
final class Discovery: ObservableObject {
    /// Chosen to identify rather than to survey: each one maps to something the app can do.
    nonisolated static let probedPorts = [3389, 5900, 22, 80, 443]

    /// Addresses probed at once. Each one opens a connection per port, so this is a
    /// thirty-two-by-five fan-out: enough to sweep a /24 in a few seconds, not so much that
    /// it exhausts file descriptors.
    nonisolated static let concurrency = 32

    /// A LAN host answers in milliseconds; this is only long enough to tolerate a slow
    /// switch, and it is what a dead address costs.
    nonisolated static let probeTimeout: TimeInterval = 1.0

    struct Host: Identifiable, Equatable {
        var ip: String
        var hostname: String?
        var mac: String?
        var openPorts: Set<Int> = []
        /// Set when the address matches a machine already in the list.
        var existing: Machine?
        /// Set when the host is the Mac doing the sweeping. A sweep answers itself on every
        /// interface it has, and ticking those is how a list ends up with three records for
        /// the Mac you are sitting at.
        var isThisMac = false

        var id: String { ip }

        /// A host found only through the ARP cache, with nothing listening on a port the
        /// app knows what to do with.
        var isSilent: Bool { openPorts.isEmpty }

        /// How this host stands against the list, which is what makes a sweep a
        /// reconciliation rather than only a way to add machines.
        enum Standing: Equatable {
            /// Not in the list at all. On a network you administer, worth a look.
            case unknown
            /// In the list, at the address the list already has.
            case known
            /// In the list, but somewhere else now. The address on file is stale.
            case moved(from: String?)
        }

        var standing: Standing {
            guard let existing else { return .unknown }
            guard let known = existing.lastIP, known == ip else {
                return .moved(from: existing.lastIP)
            }
            return .known
        }

        /// Ports answering that are not the one this machine is set up to be reached on.
        /// A machine recorded as RDP that has started answering on 22 and 80 is worth
        /// knowing about; it is not necessarily wrong, but it is a change.
        var unexpectedPorts: Set<Int> {
            guard let existing else { return [] }
            return openPorts.subtracting([existing.port(for: existing.primary)])
        }

        var kind: MachineKind {
            if openPorts.contains(3389) { return .windows }
            if openPorts.contains(5900) { return .mac }
            if openPorts.contains(22) { return .linux }
            return .device
        }

        /// What the Connect button should do, which is not always the kind's default: a
        /// Linux box with nothing but a web interface is better opened in a browser.
        var primary: ConnectionType {
            if openPorts.contains(3389) { return .rdp }
            if openPorts.contains(5900) { return .vnc }
            if openPorts.contains(22) { return .ssh }
            return .web
        }

        /// The short name a reverse lookup gave, without the domain or the `.local` that
        /// Bonjour appends, falling back to the last octet so every row has a label.
        var suggestedName: String {
            if let hostname, !hostname.isEmpty {
                let short = hostname.split(separator: ".").first.map(String.init) ?? hostname
                if !short.isEmpty { return short }
            }
            let octet = ip.split(separator: ".").last.map(String.init) ?? ip
            return "host-\(octet)"
        }

        var portSummary: String {
            isSilent ? "no open ports"
                     : openPorts.sorted().map(String.init).joined(separator: ", ")
        }

        /// A machine ready to add, with the fields the sweep could establish.
        func asMachine() -> Machine {
            var machine = Machine()
            machine.name = suggestedName
            machine.hostname = hostname ?? ip
            machine.lastIP = ip
            machine.macAddress = mac ?? ""
            machine.kind = kind
            machine.primary = primary
            machine.ipHistory = [IPRecord(ip: ip)]
            machine.lastSeen = isSilent ? nil : Date()
            return machine
        }
    }

    @Published private(set) var hosts: [Host] = []
    @Published private(set) var isScanning = false
    @Published private(set) var probed = 0
    @Published private(set) var total = 0
    @Published private(set) var subnet: IPv4Subnet?
    @Published private(set) var interfaceName: String?
    /// False when the last sweep could not read the ARP cache, so no MAC was filled in.
    /// A silently missing MAC would look like the network simply had none.
    @Published private(set) var macsAvailable = true
    /// Machines already in the list that this sweep gave a MAC they were missing.
    /// What this sweep covered, so "did not answer" can be told from "was not looked at".
    @Published private(set) var sweptAddresses: Set<String> = []
    @Published private(set) var backfilled = 0
    @Published var error: String?

    private let store: MachineStore
    private var task: Task<Void, Never>?

    init(store: MachineStore) {
        self.store = store
    }

    /// New hosts first, then the ones already in the list, each by address.
    var sortedHosts: [Host] {
        hosts.sorted { lhs, rhs in
            let lhsKnown = lhs.existing != nil
            let rhsKnown = rhs.existing != nil
            if lhsKnown != rhsKnown { return !lhsKnown }
            return (IPv4Subnet.parse(lhs.ip) ?? 0) < (IPv4Subnet.parse(rhs.ip) ?? 0)
        }
    }

    var newHosts: [Host] { hosts.filter { $0.existing == nil } }

    /// What a sweep ticks for the user. A host that answered on nothing is still worth
    /// listing — it is a real device, and a MAC is all Wake-on-LAN needs — but there is no
    /// way to connect to it, so adding it is a decision rather than the obvious default.
    var defaultSelection: Set<String> { Self.defaultSelection(among: hosts) }

    nonisolated static func defaultSelection(among hosts: [Host]) -> Set<String> {
        Set(hosts.filter { $0.existing == nil && !$0.isSilent && !$0.isThisMac }.map(\.ip))
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    func start() {
        guard !isScanning else { return }
        guard let interface = LocalInterfaces.active().first else {
            error = "No active network interface was found."
            return
        }
        guard interface.subnet.isScannable else {
            error = "\(interface.subnet) is too large to scan; discovery covers up to "
                + "\(IPv4Subnet.maximumHosts) addresses."
            return
        }

        error = nil
        hosts = []
        probed = 0
        macsAvailable = true
        subnet = interface.subnet
        interfaceName = interface.name
        let addresses = interface.subnet.hostAddresses.map(IPv4Subnet.format)
        total = addresses.count
        isScanning = true

        task = Task { [weak self] in
            await self?.sweep(addresses)
            self?.isScanning = false
        }
    }

    private func sweep(_ addresses: [String]) async {
        var openByHost: [String: Set<Int>] = [:]

        // Probe in bounded batches so a /24 does not open a thousand sockets at once.
        for batch in addresses.chunked(into: Self.concurrency) {
            if Task.isCancelled { return }
            let results = await withTaskGroup(of: (String, Set<Int>).self) { group in
                for address in batch {
                    group.addTask {
                        var open: Set<Int> = []
                        await withTaskGroup(of: (Int, Bool).self) { ports in
                            for port in Discovery.probedPorts {
                                ports.addTask {
                                    (port, await Prober.tcpOpen(host: address, port: port,
                                                                timeout: Discovery.probeTimeout))
                                }
                            }
                            for await (port, isOpen) in ports where isOpen { open.insert(port) }
                        }
                        return (address, open)
                    }
                }
                var collected: [(String, Set<Int>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (address, open) in results where !open.isEmpty { openByHost[address] = open }
            probed += batch.count
        }

        if Task.isCancelled { return }

        sweptAddresses = Set(addresses)

        // Read the cache only now: the probes above are what populated it.
        let arp = ARPTable.current()
        macsAvailable = !arp.isEmpty
        let candidates = Set(openByHost.keys).union(arp.keys.filter { addresses.contains($0) })

        var found: [Host] = []
        for ip in candidates {
            if Task.isCancelled { return }
            var host = Host(ip: ip, mac: arp[ip], openPorts: openByHost[ip] ?? [])
            host.hostname = await Resolver.reverseLookup(ip)
            host.existing = match(host)
            host.isThisMac = ThisMac.matches(mac: host.mac ?? "",
                                             names: [host.hostname ?? ""])
            found.append(host)
        }
        hosts = backfillMACs(into: found)
    }

    /// Fills in the MAC of a machine already in the list that has none, which is the field
    /// Wake-on-LAN needs and the one a machine added before the sweep could read the cache
    /// is missing. Only ever fills an empty field: a MAC already recorded is the user's,
    /// and a sweep that disagreed with it would be wrong about which machine this is.
    /// Returns the hosts with their matches refreshed, so a row does not show stale data.
    /// Not private so the tests can drive it directly with a store they built.
    func backfillMACs(into found: [Host]) -> [Host] {
        backfilled = 0
        return found.map { host in
            guard var machine = host.existing, machine.macAddress.isEmpty,
                  let mac = host.mac, !mac.isEmpty else { return host }
            machine.macAddress = mac
            store.update(machine)
            backfilled += 1
            var updated = host
            updated.existing = machine
            return updated
        }
    }

    /// Matches a found host against the list by address, then MAC, then name, so a machine
    /// that moved to a new IP is recognised instead of offered as a duplicate.
    /// Not private so the tests can drive it directly with a store they built.
    func match(_ host: Host) -> Machine? {
        if let byIP = store.machines.first(where: { $0.lastIP == host.ip }) { return byIP }
        if let mac = host.mac, !mac.isEmpty,
           let byMAC = store.machines.first(where: {
               WakeOnLAN.macBytes($0.macAddress) == WakeOnLAN.macBytes(mac)
                   && !$0.macAddress.isEmpty
           }) { return byMAC }
        if let hostname = host.hostname?.lowercased(), !hostname.isEmpty {
            let short = hostname.split(separator: ".").first.map(String.init) ?? hostname
            if let byName = store.machines.first(where: {
                let candidates = [$0.hostname.lowercased(), $0.name.lowercased()]
                return candidates.contains(hostname) || candidates.contains(short)
            }) { return byName }
        }
        return nil
    }

    /// Lets a test set what a sweep found without a network to sweep.
    func setHostsForTesting(_ found: [Host]) {
        hosts = found
    }

    // MARK: - Reconciliation

    /// Hosts that answered and are not in the list.
    var unknownHosts: [Host] {
        hosts.filter { $0.standing == .unknown }
            .sorted { (IPv4Subnet.parse($0.ip) ?? 0) < (IPv4Subnet.parse($1.ip) ?? 0) }
    }

    /// Machines the sweep found somewhere other than where the list says they are.
    var movedHosts: [Host] {
        hosts.filter {
            if case .moved = $0.standing { return true }
            return false
        }
    }

    /// Hosts answering on something other than the port their machine is set up for.
    var changedHosts: [Host] {
        hosts.filter { $0.existing != nil && !$0.unexpectedPorts.isEmpty }
    }

    /// Machines the list has at an address inside the swept range that did not answer.
    ///
    /// Only machines whose recorded address was actually in the range: a machine at another
    /// site, or one with no address yet, has not gone missing just because it was not part
    /// of this sweep.
    func unseenMachines(in addresses: Set<String>) -> [Machine] {
        let answered = Set(hosts.map(\.ip))
        return store.machines.filter { machine in
            guard let ip = machine.lastIP, !ip.isEmpty else { return false }
            return addresses.contains(ip) && !answered.contains(ip)
        }
    }

    /// Writes the new addresses of machines that moved. Recorded as a sighting rather than
    /// an edit, which is what it is — see `MachineStore.recordIP`.
    @discardableResult
    func applyMoves() -> Int {
        var updated = 0
        for host in movedHosts {
            guard let machine = host.existing else { continue }
            if store.recordIP(host.ip, for: machine.id) { updated += 1 }
        }
        hosts = hosts.map { host in
            var refreshed = host
            refreshed.existing = match(host)
            return refreshed
        }
        return updated
    }

    func add(_ hosts: [Host]) {
        for host in hosts where host.existing == nil {
            store.add(host.asMachine())
        }
        // The added ones are no longer new, so re-match rather than leaving stale rows.
        self.hosts = self.hosts.map { host in
            var updated = host
            updated.existing = match(host)
            return updated
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
