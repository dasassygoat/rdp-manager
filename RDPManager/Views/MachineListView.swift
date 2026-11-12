import SwiftUI

struct MachineListView: View {
    @EnvironmentObject private var store: MachineStore
    let machines: [Machine]
    @Binding var selection: UUID?
    let onEdit: (Machine) -> Void

    var body: some View {
        List(machines, selection: $selection) { machine in
            MachineRow(machine: machine, status: store.statuses[machine.id] ?? MachineStatus())
                .tag(machine.id)
                .contextMenu { MachineActions(machine: machine, onEdit: onEdit) }
        }
        .overlay {
            if store.machines.isEmpty {
                ContentUnavailableView(
                    "No Machines Yet",
                    systemImage: "plus.circle",
                    description: Text("Press ⌘N or click + to add the first computer."))
            } else if machines.isEmpty {
                ContentUnavailableView.search
            }
        }
        // Arrow keys already move the selection; this makes the obvious next keystroke do
        // the obvious thing rather than leaving the mouse as the only way to connect.
        .onKeyPress(.return) {
            guard let id = selection, let machine = machines.first(where: { $0.id == id })
            else { return .ignored }
            connect(machine, via: machine.primary)
            return .handled
        }
        .navigationTitle("RDP Manager")
    }
}

struct MachineRow: View {
    let machine: Machine
    let status: MachineStatus

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: status.state)
            Image(systemName: machine.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    connect(machine, via: machine.primary)
                } label: {
                    Text(machine.name).font(.headline)
                }
                .buttonStyle(.link)
                .help("Connect with \(machine.primary.label)")
                HStack(spacing: 6) {
                    Text(machine.lastIP ?? machine.displayHost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let ms = status.latencyMs {
                        Text("\(Int(ms.rounded())) ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if !machine.group.isEmpty {
                Text(machine.group)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Image(systemName: machine.primary.systemImage)
                .foregroundStyle(.secondary)
                .help(machine.primary.label)
        }
        .padding(.vertical, 3)
    }
}

/// Shared between the row context menu and the detail view toolbar menu.
struct MachineActions: View {
    @EnvironmentObject private var store: MachineStore
    let machine: Machine
    let onEdit: (Machine) -> Void

    var body: some View {
        Button("Connect with \(machine.primary.label)") { connect(machine, via: machine.primary) }
        Divider()
        ForEach(ConnectionType.allCases.filter { $0 != machine.primary }) { type in
            Button("Open with \(type.label)") { connect(machine, via: type) }
        }
        Divider()
        Button("Wake and Connect") { WakeSession.shared.wakeAndConnect(machine) }
            .disabled(machine.macAddress.isEmpty)
        Button("Wake Only") { wake(machine) }
            .disabled(machine.macAddress.isEmpty)
        Button("Copy IP Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(machine.lastIP ?? machine.displayHost, forType: .string)
        }
        Divider()
        Button("Edit…") { onEdit(machine) }
        Button("Delete", role: .destructive) {
            store.remove(machine.id)
            // Otherwise the log keeps a machine that no longer exists, and recents offers it.
            ConnectionLog.shared.forget(machine.id)
        }
    }
}
