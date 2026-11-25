import AVFoundation

/// Immutable mono audio at a raw address the render thread can read without touching ARC.
public struct Sample: @unchecked Sendable {
    // Memory is written once, before the value is shared, and never freed: banks live for the app's
    // lifetime (about 1 MB each), so the render thread can never read a dangling pointer.
    let base: UnsafePointer<Float>
    public let count: Int
    public let sampleRate: Double
    public let gain: Float

    public init(_ data: [Float], sampleRate: Double, gain: Float = 1) {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, data.count))
        p.initialize(repeating: 0, count: max(1, data.count))
        data.withUnsafeBufferPointer { if let b = $0.baseAddress { p.update(from: b, count: data.count) } }
        base = UnsafePointer(p)
        count = data.count
        self.sampleRate = sampleRate
        self.gain = gain
    }
}

/// One playable set: some takes per key position, so repeats never sound identical.
public struct SampleBank: Sendable {
    public let press: [[Sample]]    // indexed by SampleSlot, never empty inside
    public let release: [[Sample]]  // inner arrays are empty when the set has no key-up sound
    /// Semitones from the recorded pitch. When set, each press plays the next note instead of a fixed key sound.
    public let melody: [Int]

    public enum LoadError: Error { case missing(String) }
    public static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac"]
    /// Anything longer is cut here, so dropping in a whole song can't fill the memory.
    public static let maxSeconds = 4.0
    static let maxTakes = 32

    /// Loads one mechanical keyboard folder. Some lack the special keys, so those fall back to a plain key.
    public static func load(folder: URL) throws -> SampleBank {
        func read(_ path: String, target: Float) -> Sample? { sample(folder.appending(path: path + ".mp3"), peak: target, loudness: 1) }
        var rows: [Sample?] = (0...4).map { read("press/GENERIC_R\($0)", target: 0.5) }
        guard let anyRow = rows.compactMap({ $0 }).first else { throw LoadError.missing(folder.lastPathComponent) }
        for i in rows.indices where rows[i] == nil { rows[i] = anyRow }
        let press = rows.compactMap { $0 } + [
            read("press/SPACE", target: 0.6) ?? rows[4] ?? anyRow,
            read("press/ENTER", target: 0.56) ?? rows[2] ?? anyRow,
            read("press/BACKSPACE", target: 0.54) ?? rows[0] ?? anyRow,
        ]
        guard let up = read("release/GENERIC", target: 0.2) else { throw LoadError.missing("release/GENERIC") }
        let release = Array(repeating: up, count: 5) + [
            read("release/SPACE", target: 0.24) ?? up,
            read("release/ENTER", target: 0.23) ?? up,
            read("release/BACKSPACE", target: 0.22) ?? up,
        ]
        return SampleBank(press: press.map { [$0] }, release: release.map { [$0] }, melody: [])
    }

    /// Loads a plain folder of audio files. Names starting with space, enter, return, backspace, delete or
    /// release go to those keys. Every other file is a take for the ordinary keys.
    public static func load(pack folder: URL) throws -> SampleBank {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        func takes(_ prefixes: [String], peak: Float, loudness: Float) -> [Sample] {
            files.filter { f in prefixes.contains { f.lastPathComponent.lowercased().hasPrefix($0) } }
                .prefix(maxTakes).compactMap { sample($0, peak: peak, loudness: loudness) }
        }
        let named = ["space", "enter", "return", "backspace", "delete", "release"]
        var press = files.filter { f in !named.contains { f.lastPathComponent.lowercased().hasPrefix($0) } }
            .prefix(maxTakes).compactMap { sample($0, peak: 0.5, loudness: 0.07) }
        let space = takes(["space"], peak: 0.55, loudness: 0.08)
        let enter = takes(["enter", "return"], peak: 0.55, loudness: 0.09)
        let back = takes(["backspace", "delete"], peak: 0.5, loudness: 0.07)
        if press.isEmpty { press = [space, enter, back].first { !$0.isEmpty } ?? [] }
        guard !press.isEmpty else { throw LoadError.missing(folder.lastPathComponent) }
        let up = takes(["release"], peak: 0.2, loudness: 0.03)
        return SampleBank(press: Array(repeating: press, count: 5) + [space, enter, back].map { $0.isEmpty ? press : $0 },
                          release: Array(repeating: up, count: SampleSlot.allCases.count), melody: [])
    }

    /// One sound for every key.
    public static func load(single url: URL) throws -> SampleBank {
        guard let s = sample(url, peak: 0.5, loudness: 0.07) else { throw LoadError.missing(url.lastPathComponent) }
        return SampleBank(press: Array(repeating: [s], count: SampleSlot.allCases.count),
                          release: Array(repeating: [], count: SampleSlot.allCases.count), melody: [])
    }

    /// Typing plays the tune, one note per press.
    public static func tune(_ notes: [Int]) -> SampleBank {
        SampleBank(press: Array(repeating: [SynthSounds.note], count: SampleSlot.allCases.count),
                   release: Array(repeating: [], count: SampleSlot.allCases.count), melody: notes)
    }

    /// A one-off sound for a special key.
    public static func effect(_ url: URL) -> Sample? { sample(url, peak: 0.6, loudness: 0.11) }

    /// Loudest point of a file, 0 to 1. Zero if it can't be read.
    public static func peak(of url: URL) -> Float { (try? decode(url))?.0.map(abs).max() ?? 0 }

    /// Reads, trims and levels one file. `loudness` caps the loudest 50 ms, so long sounds don't drown short clicks.
    static func sample(_ url: URL, peak target: Float, loudness cap: Float) -> Sample? {
        guard let (raw, rate) = try? decode(url) else { return nil }
        let data = trim(raw)
        let peak = data.map(abs).max() ?? 0
        guard peak > 0.0001, rate > 0 else { return nil }
        let window = max(1, Int(rate * 0.05))
        var loudest: Float = 0, i = 0
        repeat {
            let part = data[i..<min(data.count, i + window)]
            loudest = max(loudest, (part.reduce(Float(0)) { $0 + $1 * $1 } / Float(window)).squareRoot())
            i += window / 2 + 1
        } while i < data.count
        return Sample(data, sampleRate: rate, gain: min(target / peak, cap / max(loudest, 0.0001)))
    }

    static func decode(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let limit = AVAudioFramePosition(format.sampleRate * maxSeconds)
        let cut = file.length > limit
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, limit))) else {
            throw LoadError.missing(url.lastPathComponent)
        }
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        guard let channels = buffer.floatChannelData else { throw LoadError.missing(url.lastPathComponent) }
        let n = Int(buffer.frameLength), c = Int(format.channelCount)
        var mono = (0..<n).map { i in (0..<c).reduce(Float(0)) { $0 + channels[$1][i] } / Float(c) }
        if cut {
            let fade = min(n, Int(format.sampleRate * 0.3))
            for i in 0..<fade { mono[n - 1 - i] *= Float(i) / Float(fade) }
        }
        return (mono, format.sampleRate)
    }

    /// Drops silence at both ends (at the front it would be heard as lag) and softens the edges to avoid pops.
    static func trim(_ data: [Float]) -> [Float] {
        let peak = data.map(abs).max() ?? 0
        guard peak > 0, let onset = data.firstIndex(where: { abs($0) > peak * 0.06 }) else { return data }
        let last = data.lastIndex { abs($0) > peak * 0.003 } ?? data.count - 1
        var out = Array(data[max(0, onset - 40)...max(onset, min(data.count - 1, last + 256))])
        let head = min(24, out.count), tail = min(256, out.count)
        for i in 0..<head { out[i] *= Float(i) / Float(head) }
        for i in 0..<tail { out[out.count - 1 - i] *= Float(i) / Float(tail) }
        return out
    }
}

/// Sounds generated in code rather than recorded.
public enum SynthSounds {
    public static let ding: Sample = {
        let rate = 48_000.0
        let partials: [(Double, Double, Double)] = [(2093, 1, 0.45), (4186, 0.35, 0.25), (5960, 0.2, 0.12)]
        let data = (0..<Int(rate * 1.1)).map { i -> Float in
            let t = Double(i) / rate
            let v = partials.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) * exp(-t / $1.2) }
            return Float(v * min(1, t / 0.002))
        }
        return Sample(data, sampleRate: rate, gain: 0.16)
    }()

    /// A soft plucked note, C5.
    public static let note: Sample = {
        let rate = 48_000.0
        let partials: [(Double, Double, Double)] = [(523.25, 1, 0.32), (1046.5, 0.22, 0.16), (3140, 0.16, 0.05)]
        let data = (0..<Int(rate * 0.9)).map { i -> Float in
            let t = Double(i) / rate
            let v = partials.reduce(0) { $0 + $1.1 * sin(2 * .pi * $1.0 * t) * exp(-t / $1.2) }
            return Float(v * min(1, t / 0.003) * min(1, (0.9 - t) / 0.05))
        }
        return Sample(data, sampleRate: rate, gain: 0.16)
    }()

    public static let mouseDown = click(pitch: 2600, length: 0.022, gain: 0.32, seed: 7)
    public static let mouseUp = click(pitch: 3500, length: 0.016, gain: 0.18, seed: 19)

    private static func click(pitch: Double, length: Double, gain: Float, seed: UInt64) -> Sample {
        let rate = 48_000.0
        var state = seed
        let data = (0..<Int(rate * length)).map { i -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(state >> 40) / Double(1 << 23) - 1
            let t = Double(i) / rate
            return Float((0.55 * noise * exp(-t / 0.0015) + sin(2 * .pi * pitch * t) * exp(-t / 0.004)) * min(1, t / 0.0002))
        }
        return Sample(data, sampleRate: rate, gain: gain)
    }
}
