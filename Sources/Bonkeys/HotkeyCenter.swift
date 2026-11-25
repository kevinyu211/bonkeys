import AppKit
import Carbon.HIToolbox

/// One system-wide shortcut through Carbon, which needs no permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var installed = false

    /// False when another app already owns the combination.
    func set(_ hotkey: Hotkey?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let hotkey else { return true }
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in HotkeyCenter.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let id = EventHotKeyID(signature: 0x424F4E4B, id: 1)
        return RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    /// A short label for a key cap.
    static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 76: "Keypad Enter", 117: "Forward Delete",
                                       115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let typed = (event.charactersIgnoringModifiers ?? "").uppercased()
        let printable = typed.unicodeScalars.first.map { $0.value > 32 && $0.value < 0xF700 } ?? false
        return named[event.keyCode] ?? (printable ? typed : "Key \(event.keyCode)")
    }

    /// Nil unless the press has Command, Control, or Option, so a plain letter can't be hijacked.
    static func make(from event: NSEvent) -> Hotkey? {
        let f = event.modifierFlags
        guard f.contains(.command) || f.contains(.control) || f.contains(.option) else { return nil }
        var mods = 0, label = ""
        if f.contains(.control) { mods |= controlKey; label += "⌃" }
        if f.contains(.option) { mods |= optionKey; label += "⌥" }
        if f.contains(.shift) { mods |= shiftKey; label += "⇧" }
        if f.contains(.command) { mods |= cmdKey; label += "⌘" }
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard let scalar = key.unicodeScalars.first, scalar.value > 32, scalar.value < 0xF700 else { return nil }
        return Hotkey(keyCode: UInt32(event.keyCode), carbonModifiers: UInt32(mods), label: label + key)
    }
}
