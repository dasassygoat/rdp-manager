import Foundation
import Combine

/// Wake a machine, wait for it to answer, then connect.
///
/// Wake-on-LAN on its own sends a packet and leaves you to guess when the machine is up,
/// which in practice means clicking Connect until it works. This waits on the port the
/// machine's own connection type uses, so the wait ends when the thing you actually want is
/// ready rather than when it answers a ping.
@MainActor
final class WakeSession: ObservableObject {
    static let shared = WakeSession()

    /// How long to keep trying. A desktop from sleep answers in seconds and one from cold
    /// in well under a minute; two minutes is generous without looking like a hang.
    static let timeout: TimeInterval = 120

    /// Machines currently being waited on, so the UI can show it rather than looking idle.
    @Published private(set) var waitingFor: Set<UUID> = []

    /// Seams for the tests, which have no network and no patience.
    var sendPacket: (Machine) throws -> Void = { try Launcher.wake($0) }
    var probe: (Machine) async -> Bool = { machine in
        // The address may have changed while the machine was off, so resolve again rather
        // than trusting the one recorded before it went down.
        let name = machine.hostname.isEmpty ? machine.name : machine.hostname
        let target = await Resolver.resolve(name) ?? machine.lastIP
        guard let target else { return false }
        return await Prober.tcpOpen(host: target, port: machine.probePort)
    }
    var onReady: (Machine) -> Void = { connect($0, via: $0.primary) }
    /// Separate from `onGaveUp` so the tests can silence it: the default puts a modal
    /// alert on screen, and a modal alert inside a test run never comes back.
    var onFailedToSend: (Machine, Error) -> Void = { machine, error in
        AppAlerts.show("Could not wake \(machine.name)", error.localizedDescription)
    }
    var onGaveUp: (Machine) -> Void = { machine in
        AppAlerts.show(
            "\(machine.name) did not come back",
            "The wake packet was sent, but nothing answered on port \(machine.probePort) "
            + "within \(Int(WakeSession.timeout)) seconds. It may still be starting, or it "
            + "may not be set up to wake from the network.")
    }
    var pollInterval: TimeInterval = 2
    var now: () -> Date = { Date() }

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isWaiting(for id: UUID) -> Bool { waitingFor.contains(id) }

    func wakeAndConnect(_ machine: Machine) {
        guard !waitingFor.contains(machine.id) else { return }
        do {
            try sendPacket(machine)
        } catch {
            onFailedToSend(machine, error)
            return
        }

        waitingFor.insert(machine.id)
        let deadline = now().addingTimeInterval(Self.timeout)
        tasks[machine.id] = Task { [weak self] in
            while let self, !Task.isCancelled, self.now() < deadline {
                if await self.probe(machine) {
                    guard !Task.isCancelled else { break }
                    self.finish(machine.id)
                    self.onReady(machine)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.finish(machine.id)
            self.onGaveUp(machine)
        }
    }

    /// Stops waiting, for the button that appears while it is. The machine is left awake:
    /// the packet has already gone, and that is not something to undo.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        finish(id)
    }

    private func finish(_ id: UUID) {
        waitingFor.remove(id)
        tasks[id] = nil
    }

    /// Lets a test wait for the attempt instead of polling the published state.
    func settle(_ id: UUID) async {
        await tasks[id]?.value
    }
}
