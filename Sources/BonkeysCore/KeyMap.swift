/// Where a key sits on the board: which recording to use, and how far left or right it is.
public struct KeyPlacement: Sendable, Equatable {
    public var slot: SampleSlot
    /// -1 is the left edge of the keyboard, +1 the right edge.
    public var x: Float
}

public enum SampleSlot: Int, Sendable, CaseIterable {
    case row0, row1, row2, row3, row4, space, enter, backspace
}

/// macOS virtual key codes mapped onto an ANSI layout.
public enum KeyMap {
    private static let rows: [(slot: SampleSlot, offset: Float, codes: [Int])] = [
        // Function row: esc, F1...F12
        (.row0, 0, [53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]),
        // ` 1 2 3 4 5 6 7 8 9 0 - = (delete is below)
        (.row0, 0, [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]),
        // tab q w e r t y u i o p [ ] backslash
        (.row1, 0, [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42]),
        // caps a s d f g h j k l ; ' (return is below)
        (.row2, 0.2, [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]),
        // shift z x c v b n m , . / ISO-section
        (.row3, 0.6, [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44]),
    ]

    private static let table: [KeyPlacement?] = {
        var t = [KeyPlacement?](repeating: nil, count: 256)
        for row in rows {
            for (i, code) in row.codes.enumerated() {
                t[code] = KeyPlacement(slot: row.slot, x: (Float(i) + row.offset) / 13 * 2 - 1)
            }
        }
        func put(_ code: Int, _ slot: SampleSlot, _ x: Float) { t[code] = KeyPlacement(slot: slot, x: x) }
        put(49, .space, 0)
        put(36, .enter, 0.95); put(76, .enter, 1)              // return, keypad enter
        put(51, .backspace, 1); put(117, .backspace, 1)        // delete, forward delete
        put(60, .row3, 0.9)                                    // right shift
        put(10, .row3, -0.95)                                  // ISO section key
        put(63, .row4, -1); put(59, .row4, -0.85)              // fn, left control
        put(58, .row4, -0.7); put(55, .row4, -0.55)            // left option, left command
        put(54, .row4, 0.35); put(61, .row4, 0.5); put(62, .row4, 0.6) // right cmd, option, control
        put(123, .row4, 0.75); put(125, .row4, 0.85); put(124, .row4, 1); put(126, .row4, 0.85) // arrows
        put(115, .row1, 1); put(119, .row2, 1); put(116, .row1, 1); put(121, .row2, 1); put(114, .row0, 1)
        // Keypad, top to bottom.
        for code in [71, 81, 75, 67] { put(code, .row0, 1) }
        for code in [89, 91, 92, 78] { put(code, .row1, 1) }
        for code in [86, 87, 88, 69] { put(code, .row2, 1) }
        for code in [83, 84, 85] { put(code, .row3, 1) }
        for code in [82, 65] { put(code, .row4, 1) }
        // F13...F20
        for code in [105, 107, 113, 106, 64, 79, 80, 90] { put(code, .row0, 1) }
        return t
    }()

    /// Unknown keys still make a sound, from the middle of the home row.
    public static func placement(for keyCode: Int) -> KeyPlacement {
        if table.indices.contains(keyCode), let p = table[keyCode] { return p }
        return KeyPlacement(slot: .row2, x: 0)
    }

    public static let modifierCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Device-specific bit that says whether this exact modifier key is held. Nil for caps lock,
    /// which reports a lock state rather than a held state.
    public static func modifierMask(for keyCode: Int) -> UInt64? {
        switch keyCode {
        case 59: 0x1          // left control
        case 56: 0x2          // left shift
        case 60: 0x4          // right shift
        case 55: 0x8          // left command
        case 54: 0x10         // right command
        case 58: 0x20         // left option
        case 61: 0x40         // right option
        case 62: 0x2000       // right control
        case 63: 0x800000     // fn / globe
        default: nil
        }
    }

    /// A small fixed pitch difference per key, so neighbours on one row don't sound identical.
    public static func character(for keyCode: Int) -> Float {
        let hash = (UInt32(truncatingIfNeeded: keyCode) &* 2_654_435_761) >> 16
        return Float(hash % 1000) / 999 * 2 - 1
    }
}
