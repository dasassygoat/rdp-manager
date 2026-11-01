import SwiftUI

enum SidebarItem: Hashable {
    case all, online, offline
    case group(String)
}

struct ContentView: View {
    @EnvironmentObject private var store: MachineStore
    @EnvironmentObject private var monitor: Monitor
    @State private var sidebar: SidebarItem? = .all
    @State private var selection: UUID?
    @State private var search = ""
    @State private var editing: Machine?
    @State private var creating = false
    @State private var discovering = false
    @ObservedObject private var updater = Updater.shared

    private var visibleMachines: [Machine] {
        store.machines.filter { machine in
            let state = store.statuses[machine.id]?.state ?? .unknown
            switch sidebar ?? .all {
            case .all: break
            case .online: if state != .online { return false }
            case .offline: if state == .online { return false }
            case .group(let g): if machine.group != g { return false }
            }
            let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return true }
            let haystack = [machine.name, machine.hostname, machine.lastIP ?? "", machine.group,
                            machine.notes, machine.tagsText, machine.username]
                .joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
        } content: {
            MachineListView(machines: visibleMachines, selection: $selection, onEdit: { editing = $0 })
                .searchable(text: $search, prompt: "Search machines")
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            if let id = selection, let machine = store.machine(id) {
                MachineDetailView(machine: machine, onEdit: { editing = $0 })
            } else {
                ContentUnavailableView(
                    "No Machine Selected",
                    systemImage: "desktopcomputer",
                    description: Text("Click a machine's name to connect, or select it to see details."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("Add Machine", systemImage: "plus") }
                    .help("Add a machine (⌘N)")
            }
            ToolbarItem {
                Button { discovering = true } label: {
                    Label("Find Machines", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Scan this network for machines (⇧⌘F)")
            }
            ToolbarItem {
                Button { monitor.refreshNow() } label: {
                    if monitor.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help("Check all machines now (⌘R)")
                .disabled(monitor.isChecking)
            }
        }
        .sheet(isPresented: $creating) {
            MachineEditView(machine: Machine(), isNew: true)
        }
        .sheet(item: $editing) { machine in
            MachineEditView(machine: machine, isNew: false)
        }
        .sheet(isPresented: $discovering) {
            DiscoveryView(store: store)
        }
        .sheet(isPresented: $updater.isPresenting) {
            UpdateView(updater: updater)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMachineRequested)) { _ in
            creating = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .discoveryRequested)) { _ in
            discovering = true
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: MachineStore
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Machines") {
                Label("All", systemImage: "desktopcomputer")
                    .badge(store.machines.count)
                    .tag(SidebarItem.all)
                Label("Online", systemImage: "circle.fill")
                    .badge(store.count(where: .online))
                    .tag(SidebarItem.online)
                Label("Offline", systemImage: "circle")
                    .badge(store.count(where: .offline))
                    .tag(SidebarItem.offline)
            }
            if !store.groups.isEmpty {
                Section("Groups") {
                    ForEach(store.groups, id: \.self) { group in
                        Label(group, systemImage: "folder")
                            .badge(store.machines.filter { $0.group == group }.count)
                            .tag(SidebarItem.group(group))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 210)
    }
}

struct StatusDot: View {
    let state: OnlineState

    var color: Color {
        switch state {
        case .online: return .green
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .help(state.label)
    }
}
