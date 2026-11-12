import AppKit
import SwiftUI

/// The window the quick-connect box lives in.
///
/// An `NSPanel` rather than a SwiftUI `Window` scene, because the global shortcut fires
/// outside any view and a scene can only be opened through `openWindow`, which comes from
/// the environment. A panel can be made from anywhere, which is what a shortcut that works
/// with every window closed needs — and a floating panel that goes away when it loses focus
/// is what this should be anyway.
@MainActor
final class QuickConnectPanel {
    static let shared = QuickConnectPanel()

    private var panel: NSPanel?

    func show(store: MachineStore) {
        if let panel, panel.isVisible {
            // Asking again while it is up means the shortcut was pressed twice: put it away.
            close()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let view = QuickConnectView(store: store) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        // Sized to its contents, then placed a little above centre, where a palette belongs.
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        if let screen = panel.screen ?? NSScreen.main {
            var frame = panel.frame
            frame.origin.y = screen.visibleFrame.midY + screen.visibleFrame.height * 0.12
            panel.setFrameOrigin(frame.origin)
        }

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Clicking elsewhere puts it away, the way a palette should.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelLostFocus(_:)),
            name: NSWindow.didResignKeyNotification, object: panel)
    }

    @objc private func panelLostFocus(_ notification: Notification) {
        close()
    }

    func close() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}
