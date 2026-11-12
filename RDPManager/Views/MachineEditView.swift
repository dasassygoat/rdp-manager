import AppKit
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
                    Picker("Sign in with", selection: $machine.credentialID) {
                        Text("This machine's own").tag(UUID?.none)
                        ForEach(store.credentials) { set in
                            Text(set.name.isEmpty ? set.qualifiedUsername : set.name)
                                .tag(UUID?.some(set.id))
                        }
                    }
                    if let id = machine.credentialID, let set = store.credential(id) {
                        LabeledContent("Account", value: set.qualifiedUsername)
                        Text("Shared with \(store.machineCount(usingCredential: id)) machine(s). "
                             + "Change it in Settings \u{2192} Sign-ins; the password lives in "
                             + "this Mac's Keychain under that sign-in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Username", text: $machine.username, prompt: Text("user"))
                        TextField("Domain", text: $machine.domain,
                                  prompt: Text("optional, for a Windows domain"))
                        SecureField("Password", text: $password)
                        Text("The password stays in this Mac's Keychain. It is never written to the shared machine list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Worth saying here rather than only in Settings: this is where the
                    // password is typed, so this is where the surprise would land.
                    if machine.primary == .rdp, !password.isEmpty || machine.credentialID != nil {
                        Text(passwordRouteNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Organize") {
                    TextField("Group", text: $machine.group, prompt: Text("Office, Servers, Lab…"))
                    TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    TextField("MAC address", text: $machine.macAddress, prompt: Text("for Wake-on-LAN"))
                    TextField("Web admin URL", text: $machine.webURL, prompt: Text("https://… (defaults to the machine's IP)"))
                }
                Section("Session") {
                    Picker("Play sound", selection: $machine.audio) {
                        ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Scale", selection: $machine.displayScale) {
                        ForEach(Machine.allowedScales, id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Toggle("Use all displays", isOn: $machine.multipleMonitors)
                    Toggle("Share the clipboard", isOn: $machine.shareClipboard)
                    HStack {
                        TextField("Share a folder", text: $machine.sharedFolder,
                                  prompt: Text("none"))
                        Button("Choose…") { chooseSharedFolder() }
                        if !machine.sharedFolder.isEmpty {
                            Button("Clear") { machine.sharedFolder = "" }
                        }
                    }
                    Text("Applies to RDP. \"On this Mac\" sends the session's audio down "
                         + "the connection to play here instead. A shared folder needs "
                         + "FreeRDP: Windows App cannot be told about one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Monitoring") {
                    Toggle("Check whether this machine is online", isOn: $machine.monitored)
                    Text("Turn this off for a machine that is meant to be off much of the "
                         + "time, so it stops reporting itself offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Getting there") {
                    TextField("SSH jump host", text: $machine.jumpHost,
                              prompt: Text("optional, user@host that can reach it"))
                    TextField("RD Gateway", text: $machine.gateway,
                              prompt: Text("optional, gateway.example.com"))
                    Text("For a machine this Mac cannot reach directly. SSH goes through "
                         + "the jump host; RDP goes through the gateway, which asks for its "
                         + "own credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(width: 520, height: 760)
        .onAppear {
            tagsText = machine.tagsText
            if !isNew { password = Keychain.password(for: machine.id) ?? "" }
        }
    }

    /// Which client a saved password actually reaches. Windows App on macOS cannot be
    /// handed one, so a password only signs you in when FreeRDP carries the connection.
    private var passwordRouteNote: String {
        switch Launcher.rdpPreference {
        case .windowsApp:
            return "Windows App cannot be given a password, so it will still ask every "
                + "time. Change the client in Settings \u{2192} Connections to use this "
                + "password."
        case .freerdp, .auto:
            return "RDP connections for this machine will use FreeRDP, the only client "
                + "that can be given a password."
        }
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        if panel.runModal() == .OK, let url = panel.url {
            machine.sharedFolder = url.path
        }
    }

    private func save() {
        var m = machine
        m.name = m.name.trimmingCharacters(in: .whitespaces)
        m.hostname = m.hostname.trimmingCharacters(in: .whitespaces)
        if m.hostname.isEmpty { m.hostname = m.name }
        m.username = m.username.trimmingCharacters(in: .whitespaces)
        m.macAddress = m.macAddress.trimmingCharacters(in: .whitespaces)
        m.domain = m.domain.trimmingCharacters(in: .whitespaces)
        m.sharedFolder = m.sharedFolder.trimmingCharacters(in: .whitespaces)
        m.jumpHost = m.jumpHost.trimmingCharacters(in: .whitespaces)
        m.gateway = m.gateway.trimmingCharacters(in: .whitespaces)
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
