import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: MachineStore
    @ObservedObject private var log = ConnectionLog.shared
    @Environment(\.openWindow) private var openWindow

    /// Only worth a section of its own once there are more machines than it would list.
    private var recents: [Machine] {
        guard store.machines.count > 5 else { return [] }
        return log.recentMachineIDs(limit: 5).compactMap { store.machine($0) }
    }

    private var sections: [(title: String, machines: [Machine])] {
        let grouped = Dictionary(grouping: store.machines, by: \.group)
        return grouped.keys
            .sorted { ($0.isEmpty ? "\u{FFFF}" : $0).localizedCaseInsensitiveCompare($1.isEmpty ? "\u{FFFF}" : $1) == .orderedAscending }
            .map { (title: $0.isEmpty ? "Ungrouped" : $0, machines: grouped[$0] ?? []) }
    }

    var body: some View {
        if store.machines.isEmpty {
            Text("No machines added yet")
        }
        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents) { machine in
                    Button {
                        connect(machine, via: machine.primary)
                    } label: {
                        Label(machine.name, systemImage: symbol(for: machine))
                    }
                }
            }
        }
        ForEach(sections, id: \.title) { section in
            Section(section.title) {
                ForEach(section.machines) { machine in
                    Button {
                        connect(machine, via: machine.primary)
                    } label: {
                        Label(machine.name, systemImage: symbol(for: machine))
                    }
                }
            }
        }
        Divider()
        Button("Open RDP Manager") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit RDP Manager") { NSApp.terminate(nil) }
    }

    /// The menu bar icon, which says whether anything needs looking at rather than being
    /// the same picture whatever the network is doing.
    struct Icon: View {
        @ObservedObject var store: MachineStore

        var body: some View {
            let offline = store.count(where: .offline)
            HStack(spacing: 3) {
                Image(systemName: "rectangle.connected.to.line.below")
                if offline > 0 { Text("\(offline)") }
            }
        }
    }

    private func symbol(for machine: Machine) -> String {
        switch store.statuses[machine.id]?.state ?? .unknown {
        case .online: return "circle.fill"
        case .offline: return "circle"
        case .unknown: return "circle.dotted"
        }
    }
}
