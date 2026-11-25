import Foundation

struct SoundPack: Identifiable, Hashable {
    enum Source: Hashable { case keyboard(String), pack(String), tune([Int]), userFolder(URL), userFile(URL) }
    enum Group: String, CaseIterable { case fun = "Fun", tunes = "Tunes", keyboards = "Keyboards", mine = "Mine" }
    let id: String
    let name: String
    let icon: String          // an emoji, or empty to show the color
    var color: UInt32 = 0
    let group: Group
    let source: Source

    static let fallback = "muyu"
    static let builtIn: [SoundPack] = [
        .init(id: "muyu", name: "木鱼 Wooden Fish", icon: "🪵", group: .fun, source: .pack("muyu")),
        .init(id: "mahjong", name: "麻将 Mahjong", icon: "🀄️", group: .fun, source: .pack("mahjong")),
        .init(id: "bubble", name: "Bubble Wrap", icon: "🫧", group: .fun, source: .pack("bubble")),
        .init(id: "duck", name: "Rubber Duck", icon: "🦆", group: .fun, source: .pack("duck")),
        .init(id: "pop", name: "Mouth Pop", icon: "👄", group: .fun, source: .pack("pop")),
        .init(id: "water", name: "Water Drop", icon: "💧", group: .fun, source: .pack("water")),
        .init(id: "typewriter", name: "Typewriter", icon: "📠", group: .fun, source: .pack("typewriter")),
        // Old public-domain tunes, in semitones from C5.
        .init(id: "jasmine", name: "茉莉花 Jasmine", icon: "🌼", group: .tunes, source: .tune(
            [4, 4, 7, 9, 12, 12, 9, 7, 7, 9, 7, 4, 4, 7, 9, 12, 12, 9, 7, 7, 9, 7, 7, 7, 7, 4, 7, 9, 9, 7,
             4, 2, 4, 7, 4, 2, 0, 0, 2, 0, 4, 2, 0, 4, 2, 4, 7, 9, 12, 7, 2, 4, 7, 2, 4, 2, 0, -3, -5,
             -3, 0, 2, 4, 0, 2, 0, -3, -5])),
        .init(id: "ode", name: "Ode to Joy", icon: "🎻", group: .tunes, source: .tune(
            [4, 4, 5, 7, 7, 5, 4, 2, 0, 0, 2, 4, 4, 2, 2, 4, 4, 5, 7, 7, 5, 4, 2, 0, 0, 2, 4, 2, 0, 0,
             2, 2, 4, 0, 2, 4, 5, 4, 0, 2, 4, 5, 4, 2, 0, 2, -5, 4, 4, 5, 7, 7, 5, 4, 2, 0, 0, 2, 4, 2, 0, 0])),
        .init(id: "elise", name: "Für Elise", icon: "🎹", group: .tunes, source: .tune(
            [4, 3, 4, 3, 4, -1, 2, 0, -3, -12, -8, -3, -1, -8, -4, -1, 0, -8, 4, 3, 4, 3, 4, -1, 2, 0, -3,
             -12, -8, -3, -1, -8, 0, -1, -3])),
        .init(id: "twinkle", name: "Twinkle Twinkle", icon: "⭐️", group: .tunes, source: .tune(
            [0, 0, 7, 7, 9, 9, 7, 5, 5, 4, 4, 2, 2, 0, 7, 7, 5, 5, 4, 4, 2, 7, 7, 5, 5, 4, 4, 2,
             0, 0, 7, 7, 9, 9, 7, 5, 5, 4, 4, 2, 2, 0])),
    ] + ([
        ("mxblack", "MX Black", 0x3A3A3C), ("cream", "Cream", 0xE9DDC3), ("alpaca", "Alpaca", 0xF2B8C6),
        ("blackink", "Black Ink", 0x4B4453), ("redink", "Red Ink", 0xC8404A), ("turquoise", "Turquoise", 0x3DBFB8),
        ("holypanda", "Holy Panda", 0xF29B4B), ("mxbrown", "MX Brown", 0x8B5E3C), ("topre", "Topre", 0x9AA0A8),
        ("mxblue", "MX Blue", 0x3C82D6), ("boxnavy", "Box Navy", 0x2E3F73), ("bluealps", "Blue Alps", 0x5BA3D9),
        ("buckling", "Buckling Spring", 0xB9B4A7),
    ] as [(String, String, UInt32)]).map { SoundPack(id: $0.0, name: $0.1, icon: "", color: $0.2, group: .keyboards, source: .keyboard($0.0)) }
}

/// A sound that can be put on a special key.
struct Effect: Identifiable, Hashable {
    let id: String
    let name: String
    static let builtIn: [Effect] = [
        .init(id: "fx/gong", name: "Gong"), .init(id: "fx/templebell", name: "Temple bell"), .init(id: "fx/muyu", name: "木鱼 Wooden fish"),
        .init(id: "fx/tiles", name: "麻将 Tile spill"), .init(id: "fx/bubbles", name: "Bubble wrap burst"),
        .init(id: "fx/boing", name: "Boing"), .init(id: "fx/arcade", name: "Arcade"), .init(id: "fx/meow", name: "Meow"),
        .init(id: "fx/quack", name: "Quack"), .init(id: "fx/squeak", name: "Duck squeak"), .init(id: "fx/cash", name: "Cash register"),
        .init(id: "fx/carriage", name: "Typewriter return"), .init(id: "fx/ding", name: "Ding"),
    ]
}

struct SpecialKey: Codable, Equatable, Identifiable {
    var code: Int
    var label: String
    var sound: String?        // an Effect id, nil for the normal sound
    var id: Int { code }
    static let usual: [SpecialKey] = [.init(code: 36, label: "Return"), .init(code: 49, label: "Space"),
                                      .init(code: 51, label: "Delete"), .init(code: 53, label: "Esc"), .init(code: 48, label: "Tab")]
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String
}

struct Preferences: Codable, Equatable {
    var enabled = true
    var switchID = SoundPack.fallback
    var volume = 0.6              // used when fixedVolume is off
    var fixedVolume = true        // keys ignore the Mac's volume keys
    var levels: [String: Double] = [:]   // slider position per output device
    var keyUp = true
    var keyDelayMs = 30.0         // sound lands when the key bottoms out, not when it registers
    var modifiers = true
    var functionKeys = true
    var mouse = false
    var special: [SpecialKey] = []
    var randomPitch = true
    var spatial = 0.7
    var toneBrightness = 0.0      // -1 deep ... 1 bright
    var tonePitch = 0.0           // -1 low ... 1 high
    var outputUID: String?        // nil follows the system output
    var dimIconWhenOff = true
    var hotkey: Hotkey?
    var sleepInApps: [String] = []    // bundle ids
    var sleepOnMic = false
    var sleepOnSpeakers = false
    var quietHoursOn = false
    var quietStart = 22 * 60
    var quietEnd = 8 * 60

    private static let key = "preferences.v1"
    static func load() -> Preferences {
        guard let saved = UserDefaults.standard.data(forKey: key) else { return Preferences() }
        return merged(with: saved)
    }
    /// Lays saved values over the defaults, so a setting added in an update doesn't wipe the others.
    static func merged(with saved: Data) -> Preferences {
        let defaults = Preferences()
        guard let base = try? JSONEncoder().encode(defaults),
              var fields = try? JSONSerialization.jsonObject(with: base) as? [String: Any],
              let old = try? JSONSerialization.jsonObject(with: saved) as? [String: Any] else { return defaults }
        fields.merge(old) { $1 }
        if old["special"] == nil, old["returnDing"] as? Bool == true {   // the old "Bell on Return" switch
            fields["special"] = [["code": 36, "label": "Return", "sound": "fx/ding"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let p = try? JSONDecoder().decode(Preferences.self, from: data) else { return defaults }
        return p
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
