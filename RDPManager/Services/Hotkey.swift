import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor: a monitor needs
/// accessibility permission, which is a large thing to ask for a shortcut, and would let the
/// app read every keystroke the user types anywhere. This registers one combination with the
/// window server and hears about nothing else.
@MainActor
final class Hotkey {
    static let shared = Hotkey()

    /// On by default, and the one thing about it worth a setting: a global shortcut that
    /// clashes with something else has to be switchable without editing anything.
    static let enabledKey = "quickConnectHotkeyEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Control-Option-Command-K. Three modifiers because a global shortcut has to lose to
    /// whatever the frontmost app wants, and K for the palette it opens.
    static let description = "⌃⌥⌘K"

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: () -> Void = {}

    func register(_ action: @escaping () -> Void) {
        unregister()
        guard Self.isEnabled else { return }
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The callback is C, so it cannot capture self; the shared instance is how it gets
        // back here. There is only ever one hotkey, so this is honest rather than a shortcut.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == Hotkey.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Hotkey.shared.fire() }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), modifiers, id,
                            GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    fileprivate func fire() {
        action()
    }

    /// 'RDPM' as an OSType, which is how Carbon tells one app's hotkeys from another's.
    fileprivate static let signature: OSType = 0x5244_504D
}
