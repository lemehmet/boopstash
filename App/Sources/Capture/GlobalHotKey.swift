import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut through Carbon's hot-key API, which works in the
/// sandbox and needs no Accessibility permission: the system delivers only
/// this chord to us and sees nothing else that is typed.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Carbon calls back through a C function pointer, which cannot capture;
    /// the registered instance is found through this.
    private static var current: GlobalHotKey?

    /// Nil when Carbon refuses, typically because another app already owns
    /// the chord; anything half set up is undone first.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x424F4F50), id: 1) // 'BOOP'
        let registered = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
        guard registered == noErr, reference != nil else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        Self.current = self
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        if Self.current === self { Self.current = nil }
    }

    /// ⌃⌥⌘V: "paste" into Boopstash from anywhere.
    static func captureClipboard(action: @escaping @MainActor () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey | controlKey, action: action)
    }
}
