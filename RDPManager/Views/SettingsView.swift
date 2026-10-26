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
            Section("Other protocols") {
                LabeledContent("VNC", value: "macOS Screen Sharing")
                LabeledContent("SSH", value: "Terminal")
                LabeledContent("Web", value: "Default browser")
            }
        }
        .formStyle(.grouped)
    }
}
