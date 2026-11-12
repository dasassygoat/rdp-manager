import Foundation
import Combine

/// Polls every machine: resolves its hostname, records IP changes, and tracks online state.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor(store: MachineStore.shared)

    static let intervalKey = "pollInterval"
    static let defaultInterval: Double = 30

    @Published private(set) var isChecking = false
    @Published private(set) var lastCycle: Date?

    private let store: MachineStore
    private var loop: Task<Void, Never>?
    private var failures: [UUID: Int] = [:]

    /// Injectable so a test does not write to this Mac's real log.
    var uptime: UptimeLog = .shared

    struct ProbeResult {
        var ip: String?
        var reachable: Bool
        var latencyMs: Double?
    }

    /// What a cycle found worth telling the user about, gathered so that one event affecting
    /// many machines is one notification rather than many.
    ///
    /// A switch going down used to mean twenty separate alerts with twenty sounds, arriving
    /// at once. That is the moment the alerts matter most and the moment they become noise.
    struct CycleReport {
        var wentOffline: [Machine] = []
        var cameBack: [Machine] = []
        var changedIP: [(machine: Machine, from: String, to: String)] = []

        var isEmpty: Bool {
            wentOffline.isEmpty && cameBack.isEmpty && changedIP.isEmpty
        }
    }

    /// One line for a group of machines that all did the same thing, naming their shared
    /// group when they have one — a site-wide outage reads as a site, not a list.
    static func summary(_ machines: [Machine], did what: String) -> (title: String, body: String) {
        let names = machines.map(\.name).sorted()
        if names.count == 1 {
            return ("\(names[0]) \(what)", "")
        }
        let groups = Set(machines.map(\.group).filter { !$0.isEmpty })
        let where_ = groups.count == 1 && groups.first != nil
            && machines.allSatisfy { !$0.group.isEmpty }
            ? " in \(groups.first!)" : ""
        let listed = names.count > 6
            ? names.prefix(6).joined(separator: ", ") + " and \(names.count - 6) more"
            : names.joined(separator: ", ")
        return ("\(names.count) machines\(where_) \(what)", listed)
    }

    init(store: MachineStore) {
        self.store = store
    }

    var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: Self.intervalKey)
        return v >= 5 ? v : Self.defaultInterval
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
                let seconds = self?.interval ?? Self.defaultInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refreshNow() {
        Task { await runCycle() }
    }

    func runCycle() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        // A machine that is not monitored is not probed and never reports a state, so it
        // cannot raise an alert for being off when being off is the point.
        let machines = store.machines.filter(\.monitored)
        for machine in store.machines where !machine.monitored {
            if store.statuses[machine.id] != nil { store.statuses[machine.id] = nil }
            failures[machine.id] = nil
        }
        var report = CycleReport()
        await withTaskGroup(of: (UUID, ProbeResult).self) { group in
            for machine in machines {
                group.addTask { (machine.id, await Self.probe(machine)) }
            }
            for await (id, result) in group {
                apply(result, to: id, into: &report)
            }
        }
        announce(report)
        lastCycle = Date()
    }

    /// Where to look for a machine, in the order worth trying: what its name resolves to,
    /// the address it was last found at, and — when neither answers — wherever its MAC is
    /// in the ARP cache now.
    ///
    /// That last one is the case the app used to lose completely. A machine with no DNS
    /// record and no Bonjour name cannot be found by name, and once its DHCP lease changes
    /// the address on file belongs to something else, so it stayed "offline" until someone
    /// noticed and edited it by hand. The MAC was already being collected for Wake-on-LAN.
    nonisolated static func addressesToTry(
        for machine: Machine,
        resolved: String?,
        arpTable: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        if let resolved, !resolved.isEmpty { candidates.append(resolved) }
        if let last = machine.lastIP, !last.isEmpty { candidates.append(last) }
        if !machine.macAddress.isEmpty,
           let viaMAC = ARPTable.address(ofMAC: machine.macAddress, table: arpTable) {
            candidates.append(viaMAC)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    nonisolated static func probe(_ machine: Machine) async -> ProbeResult {
        let resolved = await Resolver.resolve(machine.hostname.isEmpty ? machine.name : machine.hostname)
        // Read only when it might be needed: the cache is only consulted for a machine that
        // has a MAC on file, and reading it costs a sysctl.
        let arp = machine.macAddress.isEmpty ? [:] : ARPTable.current()
        let candidates = addressesToTry(for: machine, resolved: resolved, arpTable: arp)
        guard !candidates.isEmpty else {
            return ProbeResult(ip: nil, reachable: false, latencyMs: nil)
        }

        for target in candidates {
            let started = Date()
            if await Prober.tcpOpen(host: target, port: machine.probePort) {
                // The address it actually answered at, so a machine found by its MAC has
                // its new address recorded rather than being probed from scratch next time.
                return ProbeResult(ip: target, reachable: true,
                                   latencyMs: Date().timeIntervalSince(started) * 1000)
            }
            let ping = await Prober.ping(target)
            if ping.reachable {
                return ProbeResult(ip: target, reachable: true, latencyMs: ping.latencyMs)
            }
        }
        return ProbeResult(ip: resolved, reachable: false, latencyMs: nil)
    }

    /// Says what the cycle found, grouped by what happened rather than by machine.
    private func announce(_ report: CycleReport) {
        guard !report.isEmpty else { return }

        if !report.wentOffline.isEmpty {
            let (title, body) = Self.summary(report.wentOffline, did: "went offline")
            Notifier.shared.post(.offline, title: title,
                                 body: body.isEmpty
                                 ? "No response from \(report.wentOffline[0].connectHost)"
                                 : body)
        }
        if !report.cameBack.isEmpty {
            let (title, body) = Self.summary(report.cameBack, did: "are back online")
            Notifier.shared.post(.backOnline, title: title,
                                 body: body.isEmpty ? report.cameBack[0].connectHost : body)
        }
        if report.changedIP.count == 1 {
            let change = report.changedIP[0]
            Notifier.shared.post(.ipChange,
                                 title: "\(change.machine.name) changed IP address",
                                 body: "\(change.from) is now \(change.to)")
        } else if report.changedIP.count > 1 {
            let (title, _) = Self.summary(report.changedIP.map(\.machine), did: "changed address")
            Notifier.shared.post(.ipChange, title: title,
                                 body: report.changedIP
                                    .map { "\($0.machine.name): \($0.from) → \($0.to)" }
                                    .sorted()
                                    .prefix(6)
                                    .joined(separator: "\n"))
        }
    }

    private func apply(_ result: ProbeResult, to id: UUID, into report: inout CycleReport) {
        guard let machine = store.machine(id) else { return }
        var status = store.statuses[id] ?? MachineStatus()
        let previous = status.state
        status.lastChecked = Date()
        status.latencyMs = result.latencyMs
        status.resolvedIP = result.ip

        if let ip = result.ip {
            let before = machine.lastIP
            if store.recordIP(ip, for: id), let before {
                report.changedIP.append((machine, before, ip))
            }
        }

        if result.reachable {
            failures[id] = 0
            status.state = .online
            status.lastSeen = Date()
        } else {
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            // Two misses in a row before an online machine is called offline.
            if count >= 2 || previous != .online {
                status.state = .offline
            }
        }

        if previous == .online && status.state == .offline {
            store.recordLastSeen(status.lastSeen ?? Date(), for: id)
            uptime.record(id, up: false)
            report.wentOffline.append(machine)
        } else if previous == .offline && status.state == .online {
            uptime.record(id, up: true)
            report.cameBack.append(machine)
        } else if previous == .unknown && status.state == .online {
            // The first sighting after launch. Worth recording so an outage that starts
            // later has a beginning to be measured from.
            uptime.record(id, up: true)
        }
        store.statuses[id] = status
    }
}
