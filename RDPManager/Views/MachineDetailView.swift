import SwiftUI

struct MachineDetailView: View {
    @EnvironmentObject private var store: MachineStore
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

            Button {
                wake(machine)
            } label: {
                Label("Wake", systemImage: "power")
            }
            .controlSize(.large)
            .disabled(machine.macAddress.isEmpty)
            .help(machine.macAddress.isEmpty ? "Add a MAC address to enable Wake-on-LAN" : "Send Wake-on-LAN packet")
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
                row("Added", machine.createdAt.formatted(date: .abbreviated, time: .omitted))
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
