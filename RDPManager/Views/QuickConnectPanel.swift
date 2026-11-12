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
    /// Whether the panel has had focus yet, so an early resign does not close it.
    private var becameKey = false

    func show(store: MachineStore) {
        if let panel, panel.isVisible {
            // Asking again while it is up means the shortcut was pressed twice: put it away.
            close()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            // Titled, so it can become the key window and take what is typed into it. Not
            // `.nonactivatingPanel`, which only stops a click activating the app and does
            // not let an inactive app's window take the keyboard — the app has to come
            // forward, which `activateThenFocus` does.
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // A panel is allowed to stay non-key until something in it needs the keyboard;
        // this one needs it immediately.
        panel.becomesKeyOnlyIfNeeded = false

        let view = QuickConnectView(
            store: store,
            close: { [weak self] in self?.close() },
            resize: { [weak self] height in self?.resize(to: height) })
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        place(panel)

        self.panel = panel
        becameKey = false
        panel.orderFrontRegardless()
        activateThenFocus(panel)

        // Clicking elsewhere puts it away, the way a palette should — but only once it has
        // actually had focus. Activation is asynchronous, so a resign notification can
        // arrive while the panel is still on its way to becoming key, and closing on that
        // one would shut it the instant it opened.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelLostFocus(_:)),
            name: NSWindow.didResignKeyNotification, object: panel)
    }

    /// Brings the app forward and then gives the panel the keyboard.
    ///
    /// No window of an inactive application can be the key window, so the app has to be
    /// activated before the panel is made key — and activating gives key status to whichever
    /// window had it last, usually the machine list. Doing it the other way round leaves the
    /// panel on screen with everything typed going into that window instead.
    private func activateThenFocus(_ panel: NSPanel) {
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// A little above the middle of the screen the pointer is on, where a palette belongs,
    /// and wholly inside it: `visibleFrame` is not the same rectangle on every display, and
    /// a window placed by arithmetic on its middle can end up half off the top.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let wanted = visible.maxY - size.height - visible.height * 0.18
        let y = min(max(wanted, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Grows and shrinks with the list, holding the top edge still: a box that moved up
    /// and down the screen as you typed would be unusable.
    private func resize(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        var frame = panel.frame
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    @objc private func panelBecameKey(_ notification: Notification) {
        becameKey = true
    }

    @objc private func panelLostFocus(_ notification: Notification) {
        guard becameKey else { return }
        close()
    }

    func close() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(self, name: nil, object: panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}
