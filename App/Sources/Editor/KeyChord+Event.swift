import AppKit
import BoopstashCore

extension KeyChord {
    /// Translates a key event into Core's chord. Nil for events that are not
    /// a key press we could bind (dead keys, bare modifiers).
    init?(event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else {
            return nil
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let key: String
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: key = "left"
        case NSRightArrowFunctionKey: key = "right"
        case NSUpArrowFunctionKey: key = "up"
        case NSDownArrowFunctionKey: key = "down"
        case NSHomeFunctionKey: key = "home"
        case NSEndFunctionKey: key = "end"
        case NSPageUpFunctionKey: key = "pageup"
        case NSPageDownFunctionKey: key = "pagedown"
        case NSDeleteFunctionKey: key = "delete"
        case 0x7F, 0x08: key = "backspace"
        case 0x09, 0x19: key = "tab" // Shift-Tab arrives as backtab (0x19)
        case 0x0D, 0x03: key = "enter"
        case 0x1B: key = "escape"
        case 0x20: key = "space"
        default:
            guard characters.count == 1, scalar.value < 0xF700 else { return nil }
            key = characters.lowercased()
        }
        self.init(key, modifiers)
    }
}
