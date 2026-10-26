import SwiftUI

struct MachineEditView: View {
    @EnvironmentObject private var store: MachineStore
    @Environment(\.dismiss) private var dismiss
    @State var machine: Machine
    let isNew: Bool

    @State private var password = ""
    @State private var tagsText = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Machine") {
                    TextField("Name", text: $machine.name, prompt: Text("Front desk PC"))
                    TextField("Hostname or IP", text: $machine.hostname,
                              prompt: Text(machine.name.isEmpty ? "office-pc or 192.168.1.20" : machine.name))
                    Picker("Type", selection: $machine.kind) {
                        ForEach(MachineKind.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: machine.kind) { _, kind in
                        if isNew { machine.primary = kind.defaultConnection }
                    }
                    Picker("Connect with", selection: $machine.primary) {
                        ForEach(ConnectionType.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Login") {
                    TextField("Username", text: $machine.username, prompt: Text("DOMAIN\\user or user"))
                    SecureField("Password", text: $password)
                    Text("The password stays in this Mac's Keychain. It is never written to the shared machine list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Organize") {
                    TextField("Group", text: $machine.group, prompt: Text("Office, Servers, Lab…"))
                    TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    TextField("MAC address", text: $machine.macAddress, prompt: Text("for Wake-on-LAN"))
                    TextField("Web admin URL", text: $machine.webURL, prompt: Text("https://… (defaults to the machine's IP)"))
                }
                Section("Ports") {
                    TextField("RDP", value: $machine.rdpPort, format: .number)
                    TextField("VNC", value: $machine.vncPort, format: .number)
                    TextField("SSH", value: $machine.sshPort, format: .number)
                }
                Section("Notes") {
                    TextEditor(text: $machine.notes)
                        .font(.body)
                        .frame(minHeight: 70)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.remove(machine.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(machine.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 680)
        .onAppear {
            tagsText = machine.tagsText
            if !isNew { password = Keychain.password(for: machine.id) ?? "" }
        }
    }

    private func save() {
        var m = machine
        m.name = m.name.trimmingCharacters(in: .whitespaces)
        m.hostname = m.hostname.trimmingCharacters(in: .whitespaces)
        if m.hostname.isEmpty { m.hostname = m.name }
        m.username = m.username.trimmingCharacters(in: .whitespaces)
        m.macAddress = m.macAddress.trimmingCharacters(in: .whitespaces)
        m.tags = tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if Resolver.isIPv4Literal(m.hostname), m.lastIP == nil {
            m.lastIP = m.hostname
            m.ipHistory.append(IPRecord(ip: m.hostname))
        }
        Keychain.setPassword(password, for: m.id)
        if isNew { store.add(m) } else { store.update(m) }
        Monitor.shared.refreshNow()
        dismiss()
    }
}
