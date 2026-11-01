import SwiftUI

/// What a check found, and the decision it leaves the user: install it, skip this one, or
/// come back to it later.
struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(18)
            Divider()
            footer
                .padding(14)
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .available(let release):
            available(release)
        case .downloading(let fraction):
            busy("Downloading \(release?.displayName ?? "the update")…",
                 progress: fraction)
        case .installing:
            busy("Verifying and installing…", progress: nil)
        case .checking:
            busy("Checking for updates…", progress: nil)
        case .upToDate:
            message("You are up to date",
                    "RDP Manager \(AppVersion.running?.description ?? "") is the newest release.",
                    icon: "checkmark.circle.fill", tint: .green)
        case .failed(let reason):
            message("Could not check for updates", reason,
                    icon: "exclamationmark.triangle.fill", tint: .orange)
        case .idle:
            message("No update to show", "", icon: "info.circle", tint: .secondary)
        }
    }

    private var release: GitHubRelease? { updater.state.release ?? updater.pending }

    private func available(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(release.displayName).font(.headline)
            Text("You have \(AppVersion.running?.description ?? "an older version").")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func busy(_ title: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            // The swap happens after this app quits, so say so before it vanishes.
            if case .installing = updater.state {
                Text("RDP Manager will quit and reopen on the new version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ title: String, _ detail: String,
                         icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let release, let page = release.pageURL, !updater.state.isBusy {
                Link("Release Notes", destination: page)
            }
            Spacer()
            if let release, case .available = updater.state {
                Button("Skip This Version") { updater.skip(release) }
                Button("Later") { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(updater.state.isBusy ? "Hide" : "Done") { updater.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
