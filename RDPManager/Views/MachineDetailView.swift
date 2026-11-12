import SwiftUI

struct MachineDetailView: View {
    @EnvironmentObject private var store: MachineStore
    @ObservedObject private var log = ConnectionLog.shared
    @ObservedObject private var waking = WakeSession.shared
    @ObservedObject private var uptime = UptimeLog.shared
    let machine: Machine
    let onEdit: (Machine) -> Void

    private var status: MachineStatus { store.statuses[machine.id] ?? MachineStatus() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actionButtons
                details
                if !machine.notes.isEmpty {
                    section("Notes") {
                        Text(machine.notes).textSelection(.enabled)
                    }
                }
                availability
                sessions
                history
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(machine.name)
        .toolbar {
            ToolbarItem {
                Menu {
                    MachineActions(machine: machine, onEdit: onEdit)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem {
                Button("Edit") { onEdit(machine) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: machine.kind.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(machine.name).font(.largeTitle.bold())
                HStack(spacing: 8) {
                    StatusDot(state: status.state)
                    Text(status.state.label)
                    if let ms = status.latencyMs {
                        Text("· \(Int(ms.rounded())) ms").foregroundStyle(.secondary)
                    }
                    if let checked = status.lastChecked {
                        Text("· checked \(checked, style: .relative) ago").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                if !machine.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(machine.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                connect(machine, via: machine.primary)
            } label: {
                Label("Connect with \(machine.primary.label)", systemImage: machine.primary.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            ForEach(ConnectionType.allCases.filter { $0 != machine.primary }) { type in
                Button {
                    connect(machine, via: type)
                } label: {
                    Label(type.label, systemImage: type.systemImage)
                }
                .controlSize(.large)
            }

            if waking.isWaiting(for: machine.id) {
                Button {
                    waking.cancel(machine.id)
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(machine.primary.label)…")
                    }
                }
                .controlSize(.large)
                .help("Stop waiting. The machine has already been sent the wake packet.")
            } else {
                Menu {
                    Button("Wake and Connect") { waking.wakeAndConnect(machine) }
                    Button("Wake Only") { wake(machine) }
                } label: {
                    Label("Wake", systemImage: "power")
                } primaryAction: {
                    // The common case: the reason to wake a machine is to get on it.
                    waking.wakeAndConnect(machine)
                }
                .menuStyle(.button)
                .controlSize(.large)
                .disabled(machine.macAddress.isEmpty)
                .help(machine.macAddress.isEmpty
                      ? "Add a MAC address to enable Wake-on-LAN"
                      : "Wake it, wait for port \(machine.probePort), then connect")
            }
        }
    }

    private var details: some View {
        section("Details") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Hostname", machine.displayHost)
                row("IP address", machine.lastIP ?? "not resolved yet")
                if let resolved = status.resolvedIP, resolved != machine.lastIP {
                    row("Resolving to", resolved)
                }
                row("Username", machine.username.isEmpty ? "—" : machine.username)
                row("MAC address", machine.macAddress.isEmpty ? "—" : machine.macAddress)
                row("Group", machine.group.isEmpty ? "—" : machine.group)
                row("Ports", "RDP \(machine.rdpPort) · VNC \(machine.vncPort) · SSH \(machine.sshPort)")
                row("Web admin", machine.webTarget?.absoluteString ?? "—")
                if let seen = machine.lastSeen ?? status.lastSeen {
                    row("Last seen online", seen.formatted(date: .abbreviated, time: .shortened))
                }
                if let last = log.lastConnection(to: machine.id) {
                    row("Last connected",
                        "\(last.at.formatted(date: .abbreviated, time: .shortened)) "
                        + "· \(last.type.label)")
                }
                row("Added", machine.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    /// What the poller has been seeing. It worked all of this out every thirty seconds and
    /// used to keep only the latest sighting.
    @ViewBuilder private var availability: some View {
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        let outages = uptime.outages(for: machine.id, since: week)
        if !outages.isEmpty {
            section("Availability") {
                VStack(alignment: .leading, spacing: 8) {
                    let summary = uptime.downtime(for: machine.id, since: week)
                    HStack(spacing: 6) {
                        Text(Self.outageSummary(summary))
                        if let share = uptime.availability(for: machine.id, since: week) {
                            Text("· \(share * 100, specifier: "%.1f")% reachable")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Table(outages) {
                        TableColumn("Went down") {
                            Text($0.began.formatted(date: .abbreviated, time: .shortened))
                        }
                        TableColumn("Came back") { outage in
                            Text(outage.ended?.formatted(date: .abbreviated, time: .shortened)
                                 ?? "still down")
                        }
                        TableColumn("For") { outage in
                            Text(outage.duration.map(Self.describe) ?? "—")
                        }
                    }
                    .frame(height: min(CGFloat(outages.count) * 28 + 32, 200))
                    Text("Seen from this Mac over the last seven days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func outageSummary(_ summary: (count: Int, total: TimeInterval)) -> String {
        switch summary.count {
        case 0: return "No outages in the last seven days"
        case 1: return "One outage, \(describe(summary.total))"
        default: return "\(summary.count) outages, \(describe(summary.total)) in all"
        }
    }

    private static func describe(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds.rounded() / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The sessions started from this Mac. Worth having for the same reason the IP history
    /// is: the app knows when you were last on a machine and used to throw it away.
    @ViewBuilder private var sessions: some View {
        let entries = log.history(for: machine.id, limit: 20)
        if !entries.isEmpty {
            section("Recent Sessions") {
                VStack(alignment: .leading, spacing: 8) {
                    Table(entries) {
                        TableColumn("When") {
                            Text($0.at.formatted(date: .abbreviated, time: .shortened))
                        }
                        TableColumn("With") { Text($0.type.label) }
                    }
                    .frame(height: min(CGFloat(entries.count) * 28 + 32, 200))
                    Text("\(log.count(for: machine.id)) in all, recorded on this Mac only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var history: some View {
        section("IP History") {
            if machine.ipHistory.isEmpty {
                Text("No addresses recorded yet.").foregroundStyle(.secondary)
            } else {
                Table(Array(machine.ipHistory.reversed())) {
                    TableColumn("IP address") { Text($0.ip).monospaced() }
                    TableColumn("First seen") { Text($0.seenAt.formatted(date: .abbreviated, time: .shortened)) }
                }
                .frame(height: min(CGFloat(machine.ipHistory.count) * 28 + 32, 260))
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
