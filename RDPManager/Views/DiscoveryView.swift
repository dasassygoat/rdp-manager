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
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let new = discovery.newHosts.count
        let known = discovery.hosts.count - new
        guard discovery.total > 0 else { return "Ready to scan." }
        if discovery.hosts.isEmpty {
            return "Nothing answered on \(discovery.subnet?.description ?? "the network")."
        }
        var text = "\(new) new \(new == 1 ? "machine" : "machines")"
        if known > 0 { text += ", \(known) already in your list" }
        return text + " on \(discovery.subnet?.description ?? "the network")."
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
