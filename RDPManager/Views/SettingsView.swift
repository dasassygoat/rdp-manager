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
    @AppStorage(Updater.automaticKey) private var checkForUpdates = true
    @ObservedObject private var updater = Updater.shared

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
            Section("Updates") {
                LabeledContent("Version", value: AppVersion.running?.description ?? "unknown")
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                HStack {
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .disabled(updater.state.isBusy)
                    Spacer()
                    Text(lastCheckedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Updates come from the project's GitHub releases. One is only installed "
                     + "after you say so, and only if it is signed by the same developer as "
                     + "this copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lastCheckedText: String {
        guard let date = updater.lastChecked else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked " + formatter.localizedString(for: date, relativeTo: Date())
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
                    Button("Show Saved Copies") {
                        try? FileManager.default.createDirectory(
                            at: store.backupDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([store.backupDirectory])
                    }
                }
                Text("The last \(MachineStore.backupCount) versions of the list are kept on this Mac each time it changes, so a bad import or a bad merge can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                // While the list cannot be read the app is showing an empty one and saving
                // nothing, which is worth saying louder than a line of grey text.
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: store.loadFailed
                              ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                        Text(error).font(.callout)
                        Spacer()
                        if store.loadFailed {
                            Button("Try Again") { store.retryLoad() }
                        }
                    }
                    .foregroundStyle(store.loadFailed ? .red : .secondary)
                }
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
    @State private var toolMessage: String?
    /// Bumped after installing or removing so the status above is redrawn.
    @State private var toolRefresh = 0

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
                    switch Launcher.freerdpStatus {
                    case .usable(let url):
                        Label(url.path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            .lineLimit(2)
                    case .wrongArchitecture(_, let built):
                        // "Not found" would be a lie: it is there, it just cannot start here.
                        Label("Built for \(built); cannot run on this Mac",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    case .absent:
                        Label("Not found", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
                Text("Only FreeRDP can be given a saved password; Windows App on macOS has no way to accept one and asks every time. On \"Best available\", a machine with a password saved connects through FreeRDP and the rest go to Windows App.")
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
            Section("Command line") {
                LabeledContent("rdpm") {
                    if CommandLineTool.isCurrent() {
                        Label(CommandLineTool.defaultDestination.path, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    } else if let installed = CommandLineTool.installedSource() {
                        Label("another copy at \(installed.path)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(CommandLineTool.isCurrent() ? "Reinstall" : "Install…") { installTool() }
                        .disabled(CommandLineTool.bundledURL == nil)
                    Button("Remove") { removeTool() }
                        .disabled(CommandLineTool.installedSource() == nil)
                    Spacer()
                }
                if let toolMessage {
                    Text(toolMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Starts sessions from a terminal: `rdpm ssh <name>`, `rdpm ip <name>`, "
                     + "`rdpm list`. The binary lives in the app, so this is only a symlink.")
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

    private func installTool() {
        do {
            let destination = try CommandLineTool.install()
            toolMessage = "Installed at \(destination.path)."
        } catch CommandLineTool.Failure.cancelled {
            toolMessage = nil
        } catch {
            toolMessage = error.localizedDescription
        }
        toolRefresh += 1
    }

    private func removeTool() {
        do {
            try CommandLineTool.uninstall()
            toolMessage = "Removed."
        } catch {
            toolMessage = error.localizedDescription
        }
        toolRefresh += 1
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
