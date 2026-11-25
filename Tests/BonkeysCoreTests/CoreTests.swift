import AVFoundation
import Foundation
import Testing
@testable import BonkeysCore

let sounds = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Resources/Sounds")
let packs = ["alpaca", "blackink", "bluealps", "boxnavy", "buckling", "cream", "holypanda",
             "mxblack", "mxblue", "mxbrown", "redink", "topre", "turquoise"]

func render(_ mixer: Mixer, _ frames: Int, block: Int = 128) -> (l: [Float], r: [Float]) {
    var l = [Float](repeating: 9, count: frames), r = l
    l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in
        var i = 0
        while i < frames {
            let n = min(block, frames - i)
            mixer.render(frames: n, left: lb.baseAddress! + i, right: rb.baseAddress! + i, outputRate: 48_000)
            i += n
        }
    } }
    return (l, r)
}
func energy(_ a: [Float]) -> Float { a.reduce(0) { $0 + $1 * $1 } }
func peak(_ a: [Float]) -> Float { a.map(abs).max() ?? 0 }

@Test(arguments: packs) func packLoadsAndIsPrompt(name: String) throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: name))
    #expect(bank.press.count == 8 && bank.release.count == 8 && bank.melody.isEmpty)
    for (i, s) in (bank.press + bank.release).map({ $0[0] }).enumerated() {
        let m = Mixer()
        m.play(s)
        let out = render(m, 48_000).l
        #expect(peak(out) > 0.1 && peak(out) < 0.75, "\(name) slot \(i) peak \(peak(out))")
        // Audible start within 3 ms of the buffer, i.e. no lag baked into the recording.
        let first = out.firstIndex { abs($0) > peak(out) * 0.05 } ?? .max
        #expect(first < 144, "\(name) slot \(i) starts at \(first)")
        #expect(out.suffix(100).allSatisfy { $0 == 0 })
    }
}

@Test func silentWhenNothingPlays() {
    let out = render(Mixer(), 1024)
    #expect(out.l.allSatisfy { $0 == 0 } && out.r.allSatisfy { $0 == 0 })
}

@Test func leftKeysAreLouderOnTheLeft() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "mxblack"))
    for (code, leftLouder) in [(0, true), (12, true), (35, false), (36, false)] {
        let m = Mixer(), r = Router(mixer: m)
        var c = PlaybackConfig(); c.bank = bank; c.audible = true
        r.update(c)
        r.handle(.key(code: code, down: true))
        let out = render(m, 9600)
        #expect((energy(out.l) > energy(out.r)) == leftLouder)
    }
}

@Test func pitchChangesLength() {
    let s = Sample([Float](repeating: 0.1, count: 4800), sampleRate: 48_000)
    func length(_ rate: Double) -> Int {
        let m = Mixer(); m.play(s, rate: rate)
        return render(m, 12_000).l.filter { $0 != 0 }.count
    }
    #expect(abs(length(1) - 4800) < 4)
    #expect(abs(length(2) - 2400) < 4)
    #expect(abs(length(0.5) - 9600) < 4)
}

@Test func mashingNeverClipsOrCrashes() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "holypanda"))
    let m = Mixer()
    for _ in 0..<1000 { m.play(bank.press[5][0]) }   // overflows ring and voices
    let out = render(m, 48_000)
    #expect(peak(out.l) <= 1 && out.l.allSatisfy(\.isFinite))
}

@Test func concurrentPlayAndRender() async throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "cream"))
    let m = Mixer()
    await withTaskGroup(of: Void.self) { g in
        for _ in 0..<4 { g.addTask { for i in 0..<5000 { m.play(bank.press[i % 8][0], rate: 1.1) } } }
        g.addTask { for _ in 0..<500 { #expect(peak(render(m, 128).l) <= 1) } }
    }
}

@Test func routerRespectsToggles() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "cream"))
    let m = Mixer(), r = Router(mixer: m)
    var c = PlaybackConfig(); c.bank = bank
    r.update(c)
    #expect(!r.handle(.key(code: 0, down: true)))            // not audible
    #expect(r.drainCounts().presses == 0)
    c.audible = true; c.keyUp = false; c.modifiers = false; c.functionKeys = false
    r.update(c)
    #expect(r.handle(.key(code: 0, down: true)))
    #expect(!r.handle(.key(code: 0, down: false)))
    #expect(!r.handle(.key(code: 56, down: true)))
    #expect(!r.handle(.key(code: 122, down: true)))
    #expect(!r.handle(.mouse(down: true, x: 0)))
    c.mouse = true; c.bank = nil
    r.update(c)
    #expect(r.handle(.mouse(down: true, x: 0)))
    #expect(!r.handle(.key(code: 0, down: true)))            // no bank yet
    for code in [-5, 255, 256, 9999] { _ = r.handle(.key(code: code, down: true)) }
    let counts = r.drainCounts()
    #expect(counts.clicks == 2 && counts.presses > 0)
    #expect(r.drainCounts().presses == 0)
}

@Test func specialKeyReplacesOnlyThatKey() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "cream"))
    func tail(_ code: Int, modifiers: Bool = true) -> Float {
        let m = Mixer(), r = Router(mixer: m)
        var c = PlaybackConfig(); c.bank = bank; c.audible = true; c.modifiers = modifiers
        c.special = [36: SynthSounds.ding, 56: SynthSounds.ding]
        r.update(c); r.handle(.key(code: code, down: true))
        #expect(code == 0 || !r.handle(.key(code: code, down: false)))   // no click when it comes back up
        return energy(Array(render(m, 48_000).l[20_000...]))
    }
    #expect(tail(36) > 0.1)
    #expect(tail(76) > 0.1)                      // keypad Enter follows Return
    #expect(tail(56, modifiers: false) > 0.1)    // asked for by name, so it beats the modifier switch
    #expect(tail(0) == 0)
}

let resources = sounds.deletingLastPathComponent()
@Test(arguments: ["muyu", "mahjong", "bubble", "duck", "pop", "water", "typewriter"]) func funPackIsPromptAndLevel(name: String) throws {
    let bank = try SampleBank.load(pack: resources.appending(path: "Packs/\(name)"))
    #expect(bank.press[0].count >= 3)
    for s in (bank.press + bank.release).flatMap({ $0 }) {
        let m = Mixer(); m.play(s)
        let out = render(m, 48_000 * 5).l
        #expect(peak(out) > 0.03 && peak(out) < 0.75, "\(name) peak \(peak(out))")
        let first = out.firstIndex { abs($0) > peak(out) * 0.05 } ?? .max
        #expect(first < 144, "\(name) starts at \(first)")
        #expect(out.suffix(100).allSatisfy { $0 == 0 })
    }
}

@Test func effectsLoad() throws {
    let files = try FileManager.default.contentsOfDirectory(at: resources.appending(path: "Effects"), includingPropertiesForKeys: nil)
    #expect(files.count == 12)
    for f in files { #expect(SampleBank.effect(f) != nil, "\(f.lastPathComponent)") }
}

@Test func takesNeverRepeat() throws {
    let takes = (0..<4).map { Sample([Float](repeating: Float($0 + 1) / 10, count: 64), sampleRate: 48_000) }
    let bank = SampleBank(press: Array(repeating: takes, count: 8), release: Array(repeating: [], count: 8), melody: [])
    let m = Mixer(), r = Router(mixer: m)
    var c = PlaybackConfig(); c.bank = bank; c.audible = true; c.randomPitch = false; c.spatial = 0
    r.update(c)
    var last = -1, seen = Set<Int>()
    for _ in 0..<200 {
        #expect(r.handle(.key(code: 0, down: true)))
        #expect(!r.handle(.key(code: 0, down: false)))   // this set has no key-up sound
        let take = Int((peak(render(m, 256).l) * 10).rounded())
        #expect(take != last)
        last = take; seen.insert(take)
    }
    #expect(seen == [1, 2, 3, 4])
}

@Test func tuneAdvancesOnLettersOnly() {
    let m = Mixer(), r = Router(mixer: m)
    var c = PlaybackConfig(); c.bank = .tune([0, 12]); c.audible = true
    r.update(c)
    func zeroCrossings(_ code: Int) -> Int {
        guard r.handle(.key(code: code, down: true)) else { return 0 }
        #expect(!r.handle(.key(code: code, down: false)))
        let out = Array(render(m, 48_000).l[4800..<9600])
        return zip(out, out.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }
    let first = zeroCrossings(0)
    #expect(zeroCrossings(56) == 0)          // Shift plays nothing and keeps the place
    let second = zeroCrossings(1), third = zeroCrossings(2)
    #expect(abs(Double(second) / Double(first) - 2) < 0.1 && abs(third - first) <= 2)
    r.update(c)                              // same tune: keeps its place
    #expect(abs(zeroCrossings(3) - second) <= 2)
    c.bank = .tune([0, 7]); r.update(c)      // new tune: starts over
    #expect(abs(zeroCrossings(4) - first) <= 2)
}

@Test func userFilesAreSafe() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: (any Error).self) { try SampleBank.load(pack: dir) }                    // empty
    try Data("not audio".utf8).write(to: dir.appending(path: "bad.wav"))
    try Data().write(to: dir.appending(path: "zero.mp3"))
    #expect(throws: (any Error).self) { try SampleBank.load(pack: dir) }                    // nothing readable
    #expect(throws: (any Error).self) { try SampleBank.load(single: dir.appending(path: "bad.wav")) }
    #expect(throws: (any Error).self) { try SampleBank.load(pack: dir.appending(path: "gone")) }
    func write(_ name: String, seconds: Double, level: Float) throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let n = AVAudioFrameCount(seconds * 44_100), b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!
        b.frameLength = n
        for ch in 0..<2 { for i in 0..<Int(n) { b.floatChannelData![ch][i] = level * sin(Float(i) * 0.06) } }
        try AVAudioFile(forWriting: dir.appending(path: name), settings: f.settings).write(from: b)
    }
    try write("silent.wav", seconds: 0.2, level: 0)
    #expect(SampleBank.peak(of: dir.appending(path: "silent.wav")) == 0)
    #expect(throws: (any Error).self) { try SampleBank.load(single: dir.appending(path: "silent.wav")) }
    try write("Enter song.wav", seconds: 30, level: 0.9)
    let only = try SampleBank.load(pack: dir)                                               // just an enter file: used everywhere
    #expect(only.press.allSatisfy { $0.count == 1 })
    #expect(Double(only.press[0][0].count) <= 44_100 * SampleBank.maxSeconds)               // long file is cut
    try write("a.wav", seconds: 0.1, level: 0.01); try write("b.wav", seconds: 0.1, level: 0.9)
    let pack = try SampleBank.load(pack: dir)
    #expect(pack.press[0].count == 2 && pack.press[SampleSlot.enter.rawValue].count == 1 && pack.release[0].isEmpty)
}

@Test func oldStatsStillLoad() throws {
    let s = try JSONDecoder().decode(UsageStats.self, from: Data(#"{"days":{"2026-11-24":{"keys":5,"clicks":1}}}"#.utf8))
    #expect(s.totalKeys == 5 && s.merit == nil)
}

@Test func keyMapCoversLettersDigitsInOrder() {
    for code in 0...127 { #expect(abs(KeyMap.placement(for: code).x) <= 1) }
    #expect(KeyMap.placement(for: 12).x < KeyMap.placement(for: 13).x)
    #expect(KeyMap.placement(for: 49).slot == .space)
    #expect(KeyMap.placement(for: 18).slot == .row0 && KeyMap.placement(for: 6).slot == .row3)
}

@Test func quietHoursWrapMidnight() {
    #expect(QuietHours.contains(23 * 60, start: 22 * 60, end: 7 * 60))
    #expect(QuietHours.contains(60, start: 22 * 60, end: 7 * 60))
    #expect(!QuietHours.contains(12 * 60, start: 22 * 60, end: 7 * 60))
    #expect(QuietHours.contains(13 * 60, start: 12 * 60, end: 14 * 60))
    #expect(!QuietHours.contains(0, start: 0, end: 0))
}

@Test func statsStreak() throws {
    var s = UsageStats()
    let now = Date()
    func back(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: -n, to: now)! }
    #expect(s.streak(today: now) == 0)
    s.add(keys: 5, clicks: 1, on: back(1)); s.add(keys: 5, clicks: 0, on: back(2)); s.add(keys: 5, clicks: 0, on: back(4))
    #expect(s.streak(today: now) == 2)
    s.add(keys: 1, clicks: 0, on: now)
    #expect(s.streak(today: now) == 3 && s.totalKeys == 16 && s.totalClicks == 1)
    #expect(try JSONDecoder().decode(UsageStats.self, from: JSONEncoder().encode(s)) == s)
}

@Test(arguments: [0.0, 0.03, 0.15]) func keyDelayMovesTheSoundExactly(delay: Double) throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "mxblack"))
    func onset(_ d: Double, down: Bool) -> Int {
        let m = Mixer(), r = Router(mixer: m)
        var c = PlaybackConfig(); c.bank = bank; c.audible = true; c.randomPitch = false; c.keyDelay = d
        r.update(c); r.handle(.key(code: 5, down: down))
        return render(m, 24_000).l.firstIndex { $0 != 0 } ?? -1
    }
    for down in [true, false] {
        #expect(abs(onset(delay, down: down) - onset(0, down: down) - Int(delay * 48_000)) <= 1)
    }
}

@Test func fastTypingWithDelayKeepsEveryKey() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "mxblack"))
    let m = Mixer()
    for _ in 0..<20 { m.play(bank.press[0][0], gain: 0.02, delay: 0.15); _ = render(m, 480) } // 10 ms apart
    #expect(energy(render(m, 24_000).l) > 0)
}

@Test func volumeKeysDoNotChangeKeyLoudness() {
    for slider in [0.1, 0.25, 0.45] {
        let target = Loudness.decibels(slider: slider)
        for system in stride(from: -47.625, through: 0, by: 3.96875) {
            let (gain, limited) = Loudness.gain(slider: slider, systemDB: system)
            let heard = system + 20 * log10(gain)
            if limited { #expect(gain == Loudness.maxGain && heard < target) } else { #expect(abs(heard - target) < 0.1) }
        }
    }
    #expect(Loudness.gain(slider: 1, systemDB: -60).gain == Loudness.maxGain)
    #expect(Loudness.gain(slider: 0, systemDB: -60).gain == 0)
    #expect(Loudness.gain(slider: 0.45, systemDB: -47.625).limited == false)
}

@Test func switchingOnKeepsTheCurrentLoudness() {
    for (gain, system) in [(1.0, -47.625), (0.5, -20.0), (0.2, -30.0)] {
        let s = Loudness.slider(matching: gain, systemDB: system)
        #expect(abs(Loudness.gain(slider: s, systemDB: system).gain - gain) < 0.001)
    }
}

@Test func masterGainScalesAndNeverPassesTheCeiling() throws {
    let bank = try SampleBank.load(folder: sounds.appending(path: "cream"))
    func out(_ gain: Float, _ ceiling: Float, _ hits: Int = 1) -> Float {
        let m = Mixer(); m.setGain(gain, ceiling: ceiling)
        for _ in 0..<hits { m.play(bank.press[1][0]) }
        return peak(render(m, 9600).l)
    }
    let base = out(1, 1)
    #expect(abs(out(0.1, 1) / base - 0.1) < 0.005)
    #expect(out(0, 1) == 0)
    #expect(out(4, 1, 10) <= 1)
    #expect(out(4, 0.4, 10) <= 0.4001)
}
