import AVFoundation
import Synchronization
import BonkeysCore

/// Shared with the key thread so it can tell whether the engine is asleep.
nonisolated final class EngineState: Sendable {
    let running = Atomic<Bool>(false)
    let lastPlay = Atomic<UInt64>(0)
    func touch() { lastPlay.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed) }
    var idleSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds &- lastPlay.load(ordering: .relaxed)) / 1e9
    }
}

/// Mixer -> tone EQ -> chosen output device.
final class AudioOutput {
    let mixer: Mixer
    let state = EngineState()
    private(set) var lastError: String?
    private(set) var rebuilds = 0
    private var engine = AVAudioEngine()
    private var eq = AVAudioUnitEQ(numberOfBands: 2)
    private var built = false
    private var outputUID: String?
    private var gain: Float = 1
    private var testMuted = false
    private var brightness: Float = 0
    private var observer: (any NSObjectProtocol)?

    init(mixer: Mixer) { self.mixer = mixer }

    /// The device sound goes to right now.
    var deviceID: AudioDeviceID? {
        outputUID.flatMap { uid in Devices.outputs().first { $0.id == uid }?.audioID } ?? Devices.defaultOutput
    }

    func setGain(_ g: Double) {
        gain = Float(g)
        pushGain()
    }
    private func pushGain() {
        // The bright shelf adds up to 8 dB after the limiter, so lower the limiter by the same amount.
        mixer.setGain(gain, ceiling: pow(10, -abs(brightness) * 8 / 20))
    }

    func setTone(brightness b: Double) {
        brightness = Float(b)
        applyTone()
        pushGain()
    }

    private func applyTone() {
        let low = eq.bands[0], high = eq.bands[1]
        low.filterType = .lowShelf; low.frequency = 320; low.gain = -brightness * 8; low.bypass = false
        high.filterType = .highShelf; high.frequency = 3200; high.gain = brightness * 10; high.bypass = false
        eq.globalGain = -abs(brightness) * 2
    }

    func setOutput(uid: String?) {
        guard uid != outputUID else { return }
        outputUID = uid
        rebuild()
    }

    /// Drops the current graph. Restarts only if it was playing.
    func rebuild() {
        rebuilds += 1
        let wasRunning = state.running.load(ordering: .relaxed)
        tearDown()
        if wasRunning { start() }
    }

    private func tearDown() {
        state.running.store(false, ordering: .relaxed)
        engine.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine = AVAudioEngine()
        eq = AVAudioUnitEQ(numberOfBands: 2)
        built = false
    }

    private func build() {
        // A chosen device that is unplugged falls back to the system output until it returns.
        let chosen = outputUID.flatMap { uid in Devices.outputs().first { $0.id == uid }?.audioID }
        if let chosen, let unit = engine.outputNode.audioUnit {
            var id = chosen
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if let device = chosen ?? Devices.defaultOutput { Devices.requestBuffer(128, on: device) }
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard hardwareRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2) else {
            lastError = "No audio output is available."
            return
        }
        let source = Self.makeSource(mixer: mixer, format: format)
        engine.attach(source)
        engine.attach(eq)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = testMuted ? 0 : 1
        applyTone()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        built = true
    }

    /// Built outside the main actor: the block runs on the audio thread.
    private nonisolated static func makeSource(mixer: Mixer, format: AVAudioFormat) -> AVAudioSourceNode {
        let rate = format.sampleRate
        return AVAudioSourceNode(format: format) { @Sendable _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            mixer.render(frames: Int(frames), left: l, right: r, outputRate: rate)
            return noErr
        }
    }

    func start() {
        guard !state.running.load(ordering: .relaxed) else { return }
        if !built { build() }
        guard built else { return }
        do {
            try engine.start()
            lastError = nil
            state.touch()
            state.running.store(true, ordering: .relaxed)
        } catch {
            lastError = error.localizedDescription
            tearDown()
        }
    }

    /// Keeps the graph, releases the device. Lets the Mac idle-sleep and costs no CPU.
    func pause() {
        guard state.running.load(ordering: .relaxed) else { return }
        state.running.store(false, ordering: .relaxed)
        engine.pause()
    }

    // MARK: Diagnostics

    struct Report { var rate = 0.0, buffer: UInt32 = 0, latencyMs = 0.0, startMs = 0.0, resumeMs = 0.0, peak: Float = 0, rebuilds = 0 }

    /// Plays one sample through the real graph, muted at the last stage, and measures what came through.
    func selfTest(_ sample: Sample) async -> Report {
        var r = Report()
        testMuted = true
        setGain(1)
        func timed(_ work: () -> Void) -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        r.startMs = timed { start() }
        guard state.running.load(ordering: .relaxed) else { return r }
        pause()
        r.resumeMs = timed { start() }
        let peak = PeakBox()
        Self.measure(eq, into: peak)
        mixer.play(sample)
        try? await Task.sleep(for: .milliseconds(500))
        eq.removeTap(onBus: 0)
        r.peak = peak.value
        r.rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if let d = Devices.defaultOutput { r.buffer = Devices.buffer(of: d) ?? 0 }
        r.latencyMs = engine.outputNode.presentationLatency * 1000
        try? await Task.sleep(for: .seconds(5))
        r.rebuilds = rebuilds
        pause()
        return r
    }
    private nonisolated static func measure(_ node: AVAudioNode, into box: PeakBox) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            guard let d = buffer.floatChannelData else { return }
            for i in 0..<Int(buffer.frameLength) { box.raise(abs(d[0][i])) }
        }
    }
}

nonisolated final class PeakBox: Sendable {
    private let bits = Atomic<UInt32>(0)
    var value: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func raise(_ v: Float) { if v > value { bits.store(v.bitPattern, ordering: .relaxed) } }
}
