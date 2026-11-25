import Foundation
import os

/// Everything the key thread needs to decide what to play. Swapped in whole under a lock.
public struct PlaybackConfig: Sendable {
    public var bank: SampleBank?
    public var audible = false
    public var keyUp = true
    public var modifiers = true
    public var functionKeys = true
    public var mouse = false
    /// Key code to the sound that replaces it.
    public var special: [Int: Sample] = [:]
    public var randomPitch = true
    public var spatial: Float = 0.7
    /// Seconds between the key registering, partway down, and its sound. Applied to key-up too, so the
    /// two can never swap order.
    public var keyDelay = 0.0
    public var pitchSemitones: Double = 0
    public init() {}
}

public enum InputEvent: Sendable, Equatable {
    case key(code: Int, down: Bool)
    case mouse(down: Bool, x: Float)
}

/// Turns input events into sounds, and counts presses. Only a count is kept, never which keys.
public final class Router: Sendable {
    private let mixer: Mixer
    private let state = OSAllocatedUnfairLock(initialState: State())
    private struct State { var config = PlaybackConfig(), presses = 0, clicks = 0, step = 0, lastPress = -1, lastRelease = -1 }
    private static let functionCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                  105, 107, 113, 106, 64, 79, 80, 90]

    public init(mixer: Mixer) { self.mixer = mixer }

    public func update(_ config: PlaybackConfig) {
        state.withLock { s in
            if (s.config.bank?.melody ?? []) != (config.bank?.melody ?? []) { s.step = 0 }   // new tune starts from the top
            s.config = config
        }
    }

    /// Presses and clicks since the last call.
    public func drainCounts() -> (presses: Int, clicks: Int) {
        state.withLock { s in
            defer { s.presses = 0; s.clicks = 0 }
            return (s.presses, s.clicks)
        }
    }

    /// Returns true when the event made a sound.
    @discardableResult
    public func handle(_ event: InputEvent) -> Bool {
        let config = state.withLock { s in
            if s.config.audible {
                switch event {
                case .key(_, true): s.presses += 1
                case .mouse(true, _): s.clicks += 1
                default: break
                }
            }
            return s.config
        }
        guard config.audible else { return false }
        switch event {
        case .key(let code, let down): return playKey(code, down: down, config)
        case .mouse(let down, let x):
            guard config.mouse, down || config.keyUp else { return false }
            mixer.play(down ? SynthSounds.mouseDown : SynthSounds.mouseUp, pan: x * config.spatial * 0.5,
                       rate: jitter(config, 0.02))
            return true
        }
    }

    private func playKey(_ code: Int, down: Bool, _ c: PlaybackConfig) -> Bool {
        guard let bank = c.bank, down || c.keyUp else { return false }
        let isModifier = KeyMap.modifierCodes.contains(code)
        let place = KeyMap.placement(for: code)
        let pan = place.x * c.spatial * 0.8
        // The keypad's Enter follows Return unless it has its own sound.
        if let special = c.special[code] ?? (code == 76 ? c.special[36] : nil) {
            guard down else { return false }
            mixer.play(special, pan: pan, rate: jitter(c, 0.01), delay: c.keyDelay)
            return true
        }
        if !c.modifiers, isModifier { return false }
        if !c.functionKeys, Self.functionCodes.contains(code) { return false }
        let takes = (down ? bank.press : bank.release)[place.slot.rawValue]
        guard !takes.isEmpty else { return false }
        let tone = pow(2, c.pitchSemitones / 12)
        if !bank.melody.isEmpty {
            guard down, !isModifier else { return false }   // Shift for a capital shouldn't eat a note
            let note = state.withLock { s in
                defer { s.step += 1 }
                return bank.melody[s.step % bank.melody.count]
            }
            mixer.play(takes[0], pan: pan, rate: tone * pow(2, Double(note) / 12), delay: c.keyDelay)
            return true
        }
        let sample = takes[take(of: takes.count, down: down)]
        let character = 1 + Double(KeyMap.character(for: code)) * 0.025
        let gain: Float = c.randomPitch ? .random(in: 0.86...1) : 1
        mixer.play(sample, gain: gain, pan: pan, rate: character * jitter(c, 0.02) * tone, delay: c.keyDelay)
        return true
    }

    /// Random, but never the same take twice in a row.
    private func take(of count: Int, down: Bool) -> Int {
        guard count > 1 else { return 0 }
        return state.withLock { s in
            let last = down ? s.lastPress : s.lastRelease
            var n = Int.random(in: 0..<(count - 1))
            if n >= last, (0..<count).contains(last) { n += 1 }
            if down { s.lastPress = n } else { s.lastRelease = n }
            return n
        }
    }

    private func jitter(_ c: PlaybackConfig, _ amount: Double) -> Double {
        c.randomPitch ? 1 + .random(in: -amount...amount) : 1
    }
}
