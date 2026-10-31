import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            ConnectionSettings()
                .tabItem { Label("Connections", systemImage: "network") }
        }
        .frame(width: 540)
        .padding()
    }
}

struct GeneralSettings: View {
    @AppStorage(Monitor.intervalKey) private var pollInterval: Double = Monitor.defaultInterval
    @AppStorage(NotificationKind.offline.defaultsKey) private var notifyOffline = true
    @AppStorage(NotificationKind.backOnline.defaultsKey) private var notifyBackOnline = true
    @AppStorage(NotificationKind.ipChange.defaultsKey) private var notifyIPChange = true

    var body: some View {
        Form {
            Picker("Check machines every", selection: $pollInterval) {
                Text("15 seconds").tag(15.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
            }
            Section("Notify me when") {
                Toggle("A machine goes offline", isOn: $notifyOffline)
                Toggle("A machine comes back online", isOn: $notifyBackOnline)
                Toggle("A machine's IP address changes", isOn: $notifyIPChange)
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @EnvironmentObject private var store: MachineStore
    @State private var message: String?

    var body: some View {
        Form {
            Section("Machine list file") {
                LabeledContent("Location") {
                    Text(store.storeURL.path)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Choose Folder…") { chooseFolder() }
                    Button("Use Default") { store.useDefaultLocation() }
                        .disabled(store.storeURL == MachineStore.defaultStoreURL)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.storeURL])
                    }
                }
                Text("Put the folder on a network share or in iCloud Drive to share the list with other Macs. If a machines.json already exists there, it is loaded. Passwords are never stored in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Backup") {
                HStack {
                    Button("Export…") { exportList() }
                    Button("Import…") { importList() }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds machines.json"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        store.setStoreURL(folder.appendingPathComponent("machines.json"))
        message = "Now using \(folder.path)"
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "rdp-manager-machines.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url)
            message = "Exported \(store.machines.count) machines."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importData(Data(contentsOf: url))
            message = "Imported \(count) machines."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct ConnectionSettings: View {
    @AppStorage(RDPClientPreference.defaultsKey) private var rdpClient = RDPClientPreference.auto.rawValue
    @AppStorage(TerminalPreference.defaultsKey) private var sshTerminal = ""
    /// Apps picked with Choose…, kept so the picker can show one that is not in the
    /// built-in list.
    @State private var extraTerminal: (name: String, bundleID: String)?

    var body: some View {
        Form {
            Section("RDP") {
                Picker("Client", selection: $rdpClient) {
                    ForEach(RDPClientPreference.allCases) { Text($0.label).tag($0.rawValue) }
                }
                LabeledContent("Windows App") {
                    if Launcher.windowsAppURL() != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                            Button("Get from App Store") { NSWorkspace.shared.open(Launcher.windowsAppStoreURL) }
                        }
                    }
                }
                LabeledContent("FreeRDP") {
                    if let url = Launcher.freerdpURL() {
                        Label(url.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .lineLimit(2)
                    } else {
                        Label("Not found", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
                Text("Windows App asks for the password on first connection and can remember it. FreeRDP signs in automatically with the password from the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("SSH") {
                Picker("Open in", selection: $sshTerminal) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(terminalChoices, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                HStack {
                    Button("Choose…") { chooseTerminal() }
                    Spacer()
                }
                Text(sshHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Other protocols") {
                LabeledContent("VNC", value: "macOS Screen Sharing")
                LabeledContent("Web", value: "Default browser")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: rememberSelectionIfUnlisted)
    }

    private var terminalChoices: [(name: String, bundleID: String)] {
        var choices = TerminalPreference.installed()
        if let extra = extraTerminal, !choices.contains(where: { $0.bundleID == extra.bundleID }) {
            choices.append(extra)
        }
        return choices
    }

    private var sshHelp: String {
        if sshTerminal.isEmpty {
            return "Opens ssh:// and lets macOS pick the app, which is Terminal unless you "
                + "changed it. Most terminals, Warp among them, never register for ssh:// and "
                + "so cannot be chosen this way."
        }
        let name = TerminalPreference.name(forBundleID: sshTerminal) ?? "That app"
        return "\(name) is handed a small script that runs the ssh command. The password from "
            + "the Keychain is not used: ssh asks for it, or you connect with a key."
    }

    /// A terminal chosen earlier may not be in the built-in list, so keep it selectable.
    private func rememberSelectionIfUnlisted() {
        guard !sshTerminal.isEmpty,
              !TerminalPreference.installed().contains(where: { $0.bundleID == sshTerminal }),
              let name = TerminalPreference.name(forBundleID: sshTerminal) else { return }
        extraTerminal = (name: name, bundleID: sshTerminal)
    }

    private func chooseTerminal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use Terminal"
        panel.message = "Choose the app that should open SSH sessions"
        guard panel.runModal() == .OK, let app = panel.url,
              let id = Bundle(url: app)?.bundleIdentifier else { return }
        extraTerminal = (name: FileManager.default.displayName(atPath: app.path), bundleID: id)
        sshTerminal = id
    }
}
