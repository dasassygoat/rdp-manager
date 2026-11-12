import SwiftUI

/// Type a few letters, press Return, be connected.
///
/// The app already runs with no windows open and a menu bar item, which makes it exactly the
/// kind of thing worth reaching without finding a window first. The menu bar list works but
/// is a list — with thirty machines in groups, typing three letters is faster than reading.
struct QuickConnectView: View {
    @ObservedObject var store: MachineStore
    /// Closing is the panel's business, not a scene's — see `QuickConnectPanel`.
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var results: [QuickConnectMatch.Result] {
        QuickConnectMatch.rank(store.machines, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Connect to…", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(14)
                .focused($focused)
                .onSubmit { connectToSelection() }
                .onChange(of: query) { _, _ in selection = 0 }
            Divider()

            if results.isEmpty {
                Text("No machine matches \"\(query)\".")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.machine.id) { index, result in
                                row(result.machine, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture { start(result.machine) }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(results.count) * 44, 308))
                    .onChange(of: selection) { _, new in
                        withAnimation(.linear(duration: 0.08)) { scroll.scrollTo(new) }
                    }
                }
            }
        }
        .frame(width: 460)
        .onAppear { focused = true }
        // Arrow keys move the selection; Return connects to it. Handled here rather than on
        // the field so they work wherever the focus happens to be.
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func row(_ machine: Machine, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            StatusDot(state: store.statuses[machine.id]?.state ?? .unknown)
            Image(systemName: machine.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name).font(.headline)
                Text(machine.lastIP ?? machine.displayHost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !machine.group.isEmpty {
                Text(machine.group).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: machine.primary.systemImage).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selection = max(0, min(results.count - 1, selection + by))
        return .handled
    }

    private func connectToSelection() {
        guard results.indices.contains(selection) else { return }
        start(results[selection].machine)
    }

    /// Not called `connect`, which is the global that actually launches the session; one
    /// name for both would make which is being called a matter of overload resolution.
    private func start(_ machine: Machine) {
        // Closed first, so the session's own window is not opening behind this one.
        close()
        connect(machine, via: machine.primary)
    }
}
