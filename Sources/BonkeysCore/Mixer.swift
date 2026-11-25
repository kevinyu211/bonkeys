import Foundation
import os
import Synchronization

/// A tiny polyphonic player. Any thread may call `play`; one audio thread calls `render`.
/// The audio side never locks, allocates, or retains.
public final class Mixer: @unchecked Sendable {
    // @unchecked: `ring` slots are handed over through the atomic head/tail, `voices` belongs to the
    // render thread alone, and producers are serialised by `producerLock`.
    private struct Command {
        var base: UnsafePointer<Float>
        var count: Int
        var step: Double      // source frames per second, before dividing by the output rate
        var left: Float
        var right: Float
        var delayL: Double    // seconds the left ear lags
        var delayR: Double
    }
    private struct Voice {
        var cmd: Command
        var posL: Double = 0, posR: Double = 0, step: Double = 0
        var active = false
    }

    private static let ringSize = 256, maxVoices = 48
    private let ring: UnsafeMutablePointer<Command>
    private let voices: UnsafeMutablePointer<Voice>
    private let head = Atomic<Int>(0)   // next write
    private let tail = Atomic<Int>(0)   // next read
    private let producerLock = OSAllocatedUnfairLock()
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let ceilingBits = Atomic<UInt32>(Float(1).bitPattern)
    private var gainNow: Float = 1      // render thread only
    private let silence: UnsafeMutablePointer<Float>

    public init() {
        silence = .allocate(capacity: 1)
        silence.initialize(to: 0)
        let empty = Command(base: UnsafePointer(silence), count: 0, step: 0, left: 0, right: 0, delayL: 0, delayR: 0)
        ring = .allocate(capacity: Self.ringSize)
        ring.initialize(repeating: empty, count: Self.ringSize)
        voices = .allocate(capacity: Self.maxVoices)
        voices.initialize(repeating: Voice(cmd: empty), count: Self.maxVoices)
    }

    deinit { ring.deallocate(); voices.deallocate(); silence.deallocate() }

    /// Master gain, and the loudest sample allowed out (leave room for any EQ boost that follows).
    public func setGain(_ gain: Float, ceiling: Float = 1) {
        gainBits.store(max(0, gain).bitPattern, ordering: .relaxed)
        ceilingBits.store(max(0.05, min(1, ceiling)).bitPattern, ordering: .relaxed)
    }

    /// `pan` is -1 (left) to 1 (right). `rate` 1 is the recorded pitch. `delay` is in seconds.
    public func play(_ sample: Sample, gain: Float = 1, pan: Float = 0, rate: Double = 1, delay: Double = 0) {
        guard sample.count > 1 else { return }
        let p = max(-1, min(1, pan))
        let angle = (p + 1) * .pi / 4
        let g = gain * sample.gain * Float(2).squareRoot()
        // The far ear also hears it up to 0.3 ms later, which is what makes headphones feel spatial.
        let itd = Double(abs(p)) * 0.0003
        let cmd = Command(base: sample.base, count: sample.count, step: sample.sampleRate * rate,
                          left: cos(angle) * g, right: sin(angle) * g,
                          delayL: delay + (p > 0 ? itd : 0), delayR: delay + (p < 0 ? itd : 0))
        producerLock.withLockUnchecked {
            let h = head.load(ordering: .relaxed)
            guard h - tail.load(ordering: .acquiring) < Self.ringSize else { return } // full: drop
            ring[h % Self.ringSize] = cmd
            head.store(h + 1, ordering: .releasing)
        }
    }

    /// Overwrites both channels with the next `frames` frames.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, outputRate: Double) {
        let gain = Float(bitPattern: gainBits.load(ordering: .relaxed))
        let ceiling = Float(bitPattern: ceilingBits.load(ordering: .relaxed))
        // Glide while something is sounding (no clicks); jump when silent so the next key is right at once.
        if !(0..<Self.maxVoices).contains(where: { voices[$0].active }) { gainNow = gain }
        let glide = Float(1 - exp(-1 / (0.005 * outputRate)))
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        while t < h {
            start(ring[t % Self.ringSize], outputRate: outputRate)
            t += 1
        }
        tail.store(t, ordering: .releasing)

        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        for i in 0..<Self.maxVoices where voices[i].active {
            var v = voices[i]
            let end = Double(v.cmd.count - 1)
            for f in 0..<frames {
                if v.posL >= 0, v.posL < end { left[f] += read(v.cmd.base, v.posL) * v.cmd.left }
                if v.posR >= 0, v.posR < end { right[f] += read(v.cmd.base, v.posR) * v.cmd.right }
                v.posL += v.step
                v.posR += v.step
            }
            if v.posL >= end, v.posR >= end { v.active = false }
            voices[i] = v
        }
        for f in 0..<frames {
            gainNow += (gain - gainNow) * glide
            left[f] = limit(left[f] * gainNow / ceiling) * ceiling
            right[f] = limit(right[f] * gainNow / ceiling) * ceiling
        }
    }

    private func start(_ cmd: Command, outputRate: Double) {
        var slot = 0, furthest = -Double.infinity
        for i in 0..<Self.maxVoices {
            if !voices[i].active { slot = i; break }
            let progress = voices[i].posL / Double(voices[i].cmd.count)
            if progress > furthest { furthest = progress; slot = i } // steal the one closest to done
        }
        voices[slot] = Voice(cmd: cmd, posL: -cmd.delayL * cmd.step, posR: -cmd.delayR * cmd.step,
                             step: cmd.step / outputRate, active: true)
    }

    @inline(__always) private func read(_ base: UnsafePointer<Float>, _ pos: Double) -> Float {
        let i = Int(pos), frac = Float(pos - Double(i))
        return base[i] + (base[i + 1] - base[i]) * frac
    }

    /// Linear up to 0.7, then eases towards 1 so fast typing never clips.
    @inline(__always) private func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.7 else { return x }
        let y = 0.7 + 0.3 * tanhf((a - 0.7) / 0.3)
        return x < 0 ? -y : y
    }
}
