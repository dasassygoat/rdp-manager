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

    struct ProbeResult {
        var ip: String?
        var reachable: Bool
        var latencyMs: Double?
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
        await withTaskGroup(of: (UUID, ProbeResult).self) { group in
            for machine in machines {
                group.addTask { (machine.id, await Self.probe(machine)) }
            }
            for await (id, result) in group {
                apply(result, to: id)
            }
        }
        lastCycle = Date()
    }

    nonisolated static func probe(_ machine: Machine) async -> ProbeResult {
        let resolved = await Resolver.resolve(machine.hostname.isEmpty ? machine.name : machine.hostname)
        guard let target = resolved ?? machine.lastIP else {
            return ProbeResult(ip: nil, reachable: false, latencyMs: nil)
        }
        let started = Date()
        if await Prober.tcpOpen(host: target, port: machine.probePort) {
            return ProbeResult(ip: resolved, reachable: true,
                               latencyMs: Date().timeIntervalSince(started) * 1000)
        }
        let ping = await Prober.ping(target)
        return ProbeResult(ip: resolved, reachable: ping.reachable, latencyMs: ping.latencyMs)
    }

    private func apply(_ result: ProbeResult, to id: UUID) {
        guard let machine = store.machine(id) else { return }
        var status = store.statuses[id] ?? MachineStatus()
        let previous = status.state
        status.lastChecked = Date()
        status.latencyMs = result.latencyMs
        status.resolvedIP = result.ip

        if let ip = result.ip {
            let before = machine.lastIP
            if store.recordIP(ip, for: id), let before {
                Notifier.shared.post(.ipChange, title: "\(machine.name) changed IP address",
                                     body: "\(before) is now \(ip)")
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
            Notifier.shared.post(.offline, title: "\(machine.name) went offline",
                                 body: "No response from \(machine.connectHost)")
        } else if previous == .offline && status.state == .online {
            Notifier.shared.post(.backOnline, title: "\(machine.name) is back online",
                                 body: machine.connectHost)
        }
        store.statuses[id] = status
    }
}
