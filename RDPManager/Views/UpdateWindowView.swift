import SwiftUI

/// `UpdateView` in a window of its own.
///
/// The update answer used to be a sheet on the main window. This app goes on running
/// after its last window is closed — see `applicationShouldTerminateAfterLastWindowClosed`
/// — and a sheet in that state has nothing to attach to, so "Check for Updates…" did the
/// whole check and then showed nothing at all. A window can always be opened.
struct UpdateWindowView: View {
    @ObservedObject private var updater = Updater.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        UpdateView(updater: updater)
            // The buttons inside say they are done by lowering this flag; the window
            // follows it rather than each button having to know it is in a window.
            .onChange(of: updater.isPresenting) { _, presenting in
                if !presenting { dismiss() }
            }
            .onDisappear {
                // Closed with the red button rather than one of ours.
                if updater.isPresenting { updater.dismiss() }
            }
    }
}
