import SwiftUI

/// Sheet that sweeps the local network and offers what it found as machines to add.
struct DiscoveryView: View {
    @EnvironmentObject private var store: MachineStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery: Discovery
    /// Addresses ticked for adding. Seeded from each sweep, then left to the user.
    @State private var selected: Set<String> = []
    @State private var seededFor: Int = -1

    init(store: MachineStore) {
        _discovery = StateObject(wrappedValue: Discovery(store: store))
    }

    private var addable: [Discovery.Host] {
        discovery.newHosts.filter { selected.contains($0.ip) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .onAppear { discovery.start() }
        .onDisappear { discovery.cancel() }
        .onChange(of: discovery.hosts.count) { _, count in
            // Tick every new host once per sweep, without fighting the user afterwards.
            guard !discovery.isScanning, seededFor != count else { return }
            seededFor = count
            selected = discovery.defaultSelection
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find Machines").font(.headline)
            if let error = discovery.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if discovery.isScanning {
                Text("Scanning \(discovery.subnet?.description ?? "the network") on "
                     + "\(discovery.interfaceName ?? "this Mac")…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(discovery.probed),
                             total: Double(max(discovery.total, 1)))
            } else {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                if !discovery.macsAvailable && !discovery.hosts.isEmpty {
                    // Saying nothing here would make an empty MAC field look like the
                    // network has none, rather than like this Mac would not hand them over.
                    Label("The ARP cache could not be read, so Wake-on-LAN is not filled "
                          + "in. Everything else the sweep found is here.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                reconciliation
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the sweep found out about machines already in the list. A sweep used to be only
    /// a way to add machines, and it already knew all of this.
    @ViewBuilder private var reconciliation: some View {
        let moved = discovery.movedHosts
        let changed = discovery.changedHosts
        let unseen = discovery.unseenMachines(in: discovery.sweptAddresses)

        if !moved.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(movedText(moved), systemImage: "arrow.triangle.swap")
                    .font(.caption)
                Spacer()
                Button("Update Addresses") { discovery.applyMoves() }
                    .controlSize(.small)
            }
        }
        if !changed.isEmpty {
            Label(changedText(changed), systemImage: "bolt.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !unseen.isEmpty {
            Label(unseenText(unseen), systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func movedText(_ moved: [Discovery.Host]) -> String {
        let names = moved.compactMap { host -> String? in
            guard let machine = host.existing else { return nil }
            return "\(machine.name) is at \(host.ip)"
        }
        return names.count == 1
            ? names[0] + ", not where the list says"
            : "\(names.count) machines have moved: " + names.prefix(3).joined(separator: ", ")
            + (names.count > 3 ? "…" : "")
    }

    private func changedText(_ changed: [Discovery.Host]) -> String {
        let bits = changed.compactMap { host -> String? in
            guard let machine = host.existing else { return nil }
            let ports = host.unexpectedPorts.sorted().map(String.init).joined(separator: ", ")
            return "\(machine.name) also answers on \(ports)"
        }
        return bits.prefix(3).joined(separator: "; ") + (bits.count > 3 ? "…" : "")
    }

    private func unseenText(_ unseen: [Machine]) -> String {
        let names = unseen.map(\.name).sorted()
        return names.count == 1
            ? "\(names[0]) is in your list at an address on this network but did not answer."
            : "\(names.count) machines in your list are on this network but did not answer: "
            + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : "")
    }

    private var summary: String {
        let known = discovery.hosts.count - discovery.unknownHosts.count
        guard discovery.total > 0 else { return "Ready to scan." }
        if discovery.hosts.isEmpty {
            return "Nothing answered on \(discovery.subnet?.description ?? "the network")."
        }
        let unknown = discovery.unknownHosts.count
        var text = "\(unknown) new \(unknown == 1 ? "machine" : "machines")"
        if known > 0 { text += ", \(known) already in your list" }
        text += " on \(discovery.subnet?.description ?? "the network")."
        // Worth saying: the list changed without the user asking for anything.
        if discovery.backfilled > 0 {
            let count = discovery.backfilled
            text += " Filled in the MAC address of \(count) "
                + (count == 1 ? "machine" : "machines") + " already in your list."
        }
        return text
    }

    @ViewBuilder
    private var content: some View {
        if discovery.hosts.isEmpty {
            VStack {
                Spacer()
                if discovery.isScanning {
                    ProgressView().controlSize(.large)
                } else if discovery.error == nil {
                    ContentUnavailableView(
                        "No Machines Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Nothing on this network answered on "
                                          + "RDP, VNC, SSH or HTTP."))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(discovery.sortedHosts) { host in
                    DiscoveredRow(host: host, isSelected: selected.contains(host.ip)) {
                        if selected.contains(host.ip) {
                            selected.remove(host.ip)
                        } else {
                            selected.insert(host.ip)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Button("Rescan") { discovery.start() }
                .disabled(discovery.isScanning)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(addable.isEmpty ? "Add" : "Add \(addable.count)") {
                discovery.add(addable)
                selected = []
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(addable.isEmpty)
        }
        .padding(14)
    }
}

private struct DiscoveredRow: View {
    let host: Discovery.Host
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let existing = host.existing {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Already added as \(existing.name)")
                    .frame(width: 16)
            } else {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .labelsHidden()
            }
            Image(systemName: host.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.existing?.name ?? host.suggestedName)
                        .font(.body)
                    if host.isThisMac {
                        Text("this Mac")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if host.existing != nil {
                        Text("in your list")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A silent host gets web as its connection because a machine needs one, not
            // because anything answered there; naming it would promise a page to open.
            Text(host.isSilent ? "—" : host.primary.label)
                .font(.caption)
                .foregroundStyle(host.isSilent ? .tertiary : .secondary)
        }
        .padding(.vertical, 2)
        .opacity(host.existing == nil ? 1 : 0.6)
    }

    private var detail: String {
        var parts = [host.ip]
        if let mac = host.mac { parts.append(mac) }
        parts.append(host.portSummary)
        return parts.joined(separator: " · ")
    }
}
