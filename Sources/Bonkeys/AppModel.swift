import AppKit
import Observation
import ServiceManagement
import BonkeysCore

@Observable
final class AppModel {
    static let shared = AppModel()

    var prefs: Preferences { didSet { if prefs != oldValue { prefs.save(); apply() } } }
    private(set) var stats = UsageStats()
    private(set) var allowed = InputTap.isAllowed
    private(set) var listening = false
    private(set) var sleepReason: String?
    private(set) var outputs: [OutputDevice] = []
    private(set) var loadError: String?
    private(set) var hotkeyTaken = false
    /// The Mac is turned down too far for the keys to reach the chosen volume.
    private(set) var volumeLimited = false
    private(set) var deviceUID: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    @ObservationIgnored let audio: AudioOutput
    @ObservationIgnored private let router: Router
    @ObservationIgnored private var tap: InputTap!
    @ObservationIgnored private var banks: [String: SampleBank] = [:]
    @ObservationIgnored private var effectSamples: [String: Sample] = [:]
    @ObservationIgnored private var lastDefaultOutput = Devices.defaultOutput
    @ObservationIgnored private var watchedDevice: UInt32?
    @ObservationIgnored private var stopWatchingVolume: (() -> Void)?
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var appliedHotkey: Hotkey?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var statsDirty = false
    @ObservationIgnored private var started = false

    private init() {
        prefs = Preferences.load()
        let mixer = Mixer()
        audio = AudioOutput(mixer: mixer)
        router = Router(mixer: mixer)
        tap = InputTap(router: router, engine: audio.state) {
            Task { @MainActor in AppModel.shared.audio.start() }
        }
    }

    let library = Library()
    let recorder = SoundRecorder()
    var packs: [SoundPack] { SoundPack.builtIn + library.packs }
    func pack(_ id: String) -> SoundPack { packs.first { $0.id == id } ?? packs[0] }
    var effects: [Effect] { Effect.builtIn + library.effects }
    /// What the volume slider shows and sets.
    var level: Double {
        get { prefs.fixedVolume ? deviceUID.flatMap { prefs.levels[$0] } ?? 0.4 : prefs.volume }
        set {
            if prefs.fixedVolume, let deviceUID { prefs.levels[deviceUID] = newValue } else { prefs.volume = newValue }
        }
    }
    var audible: Bool { prefs.enabled && sleepReason == nil }

    func start() {
        guard !started else { return }
        started = true
        stats = Self.loadStats()
        outputs = Devices.outputs()
        Devices.onChange { MainActor.assumeIsolated { AppModel.shared.devicesChanged() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshSleep() }
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.setLocked(locked) }
            }
        }
        HotkeyCenter.shared.action = { AppModel.shared.toggle() }
        apply()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.tick() } }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        flushStats(force: true)
        tap.stop()
        audio.pause()
    }

    // MARK: Actions

    func toggle() { prefs.enabled.toggle() }

    func select(_ id: String, preview: Bool = true) {
        flushStats(force: false)   // so presses so far count for the set they were typed on
        prefs.switchID = id
        if preview { self.preview(id) }
    }

    func preview(_ id: String) {
        guard let bank = bank(id) else { return }
        audio.start()
        let pitch = pow(2, prefs.tonePitch * 4 / 12)
        let spread = Float(prefs.spatial)
        Task {
            if !bank.melody.isEmpty {
                for note in bank.melody.prefix(7) {
                    audio.state.touch()
                    audio.mixer.play(bank.press[0][0], rate: pitch * pow(2, Double(note) / 12))
                    try? await Task.sleep(for: .milliseconds(210))
                }
                return
            }
            for (slot, pan) in [(SampleSlot.row1, -0.5), (.row2, 0.1), (.row3, 0.5), (.space, 0)] as [(SampleSlot, Float)] {
                audio.state.touch()
                if let s = bank.press[slot.rawValue].randomElement() {
                    audio.mixer.play(s, pan: pan * spread, rate: pitch * .random(in: 0.98...1.02))
                }
                try? await Task.sleep(for: .milliseconds(75))
                if prefs.keyUp, let s = bank.release[slot.rawValue].randomElement() { audio.mixer.play(s, pan: pan * spread, rate: pitch) }
                try? await Task.sleep(for: .milliseconds(65))
            }
        }
    }

    func previewEffect(_ id: String) {
        guard let sample = effect(id) else { return }
        audio.start()
        audio.state.touch()
        audio.mixer.play(sample)
    }

    /// The sound on a special key, or nil for the normal one.
    func specialSound(_ code: Int) -> String? { prefs.special.first { $0.code == code }?.sound }
    func setSpecial(_ key: SpecialKey, sound: String?) {
        var key = key
        key.sound = sound
        if let i = prefs.special.firstIndex(where: { $0.code == key.code }) { prefs.special[i] = key } else { prefs.special.append(key) }
        if let sound { previewEffect(sound) }
    }
    /// The usual keys plus any the user added.
    var specialKeys: [SpecialKey] {
        SpecialKey.usual + prefs.special.filter { k in !SpecialKey.usual.contains { $0.code == k.code } }
    }

    // MARK: My sounds

    /// Call after files in the library change.
    func libraryChanged() {
        library.refresh()
        banks = banks.filter { id, _ in SoundPack.builtIn.contains { $0.id == id } }
        effectSamples = effectSamples.filter { !$0.key.hasPrefix(Library.filePrefix) }
        apply()
    }
    func importSounds(_ urls: [URL]) {
        library.importFiles(urls)
        libraryChanged()
    }
    func rename(_ sound: UserSound, to name: String) {
        guard let new = library.rename(sound, to: name) else { return }
        for i in prefs.special.indices where prefs.special[i].sound == sound.id { prefs.special[i].sound = new }
        if prefs.switchID == sound.id { prefs.switchID = new }
        libraryChanged()
    }
    func remove(_ sound: UserSound) {
        library.trash(sound)
        for i in prefs.special.indices where prefs.special[i].sound == sound.id { prefs.special[i].sound = nil }
        if prefs.switchID == sound.id { prefs.switchID = SoundPack.fallback }
        libraryChanged()
    }
    func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else {
            recorder.start(to: library.newRecordingURL()) { AppModel.shared.recordingChanged() }
        }
    }
    private func recordingChanged() {
        // The keys stay quiet while the microphone is on, and the half-written file isn't listed.
        if recorder.isRecording { audio.pause(); apply() } else { libraryChanged() }
    }

    func requestPermission() {
        InputTap.askForPermission()
        openPrivacySettings()
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { @Sendable _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch { launchAtLoginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetStats() {
        _ = router.drainCounts()
        stats = UsageStats()
        statsDirty = true
        flushStats(force: true)
    }

    /// bonkeys://on, off, toggle, settings, volume/0-100, switch/<id>
    func open(_ url: URL) {
        let argument = url.pathComponents.last { $0 != "/" } ?? ""
        switch url.host() {
        case "on": prefs.enabled = true
        case "off": prefs.enabled = false
        case "toggle": toggle()
        case "settings": SettingsWindow.shared.show()
        case "volume": if let v = Double(argument), v.isFinite { level = max(0, min(100, v)) / 100 }
        case "switch": if packs.contains(where: { $0.id == argument }) { select(argument) }
        default: break
        }
    }

    // MARK: State

    private func bank(_ id: String) -> SampleBank? {
        let pack = pack(id)
        if let b = banks[pack.id] { return b }
        guard let root = Bundle.main.resourceURL else { return nil }
        do {
            let b = switch pack.source {
            case .keyboard(let name): try SampleBank.load(folder: root.appending(path: "Sounds/\(name)"))
            case .pack(let name): try SampleBank.load(pack: root.appending(path: "Packs/\(name)"))
            case .tune(let notes): SampleBank.tune(notes)
            case .userFolder(let url): try SampleBank.load(pack: url)
            case .userFile(let url): try SampleBank.load(single: url)
            }
            banks[pack.id] = b
            loadError = nil
            return b
        } catch {
            loadError = "Couldn't load the \(pack.name) sounds."
            return nil
        }
    }

    func canLoad(_ id: String) -> Bool { bank(id) != nil }
    func canLoadEffect(_ id: String) -> Bool { effect(id) != nil }

    private func effect(_ id: String) -> Sample? {
        if let s = effectSamples[id] { return s }
        let sample: Sample?
        if id == "fx/ding" {
            sample = SynthSounds.ding
        } else if id.hasPrefix("fx/"), let root = Bundle.main.resourceURL {
            sample = SampleBank.effect(root.appending(path: "Effects/\(id.dropFirst(3)).wav"))
        } else {
            sample = library.sounds.first { $0.id == id }.flatMap { SampleBank.effect($0.url) }
        }
        effectSamples[id] = sample
        return sample
    }

    private func apply() {
        guard started else { return }
        audio.setTone(brightness: prefs.toneBrightness)
        audio.setOutput(uid: prefs.outputUID)
        updateGain()
        if appliedHotkey != prefs.hotkey {
            appliedHotkey = prefs.hotkey
            hotkeyTaken = !HotkeyCenter.shared.set(prefs.hotkey)
        }
        sleepReason = computeSleepReason()
        pushConfig()
        if audible, allowed {
            listening = tap.start()
            if listening { audio.start() }
        } else {
            tap.stop()
            listening = false
            // A preview may be playing. If so, the idle check in `tick` pauses the engine later.
            if audio.state.idleSeconds > 2 { audio.pause() }
        }
    }

    private func updateGain() {
        let device = audio.deviceID
        if device != watchedDevice {
            stopWatchingVolume?()
            stopWatchingVolume = device.map { Devices.onVolumeChange(of: $0) { MainActor.assumeIsolated { AppModel.shared.updateGain() } } }
            watchedDevice = device
        }
        let uid = device.flatMap(Devices.uid)
        if uid != deviceUID { deviceUID = uid }
        let plain = min(1, prefs.volume * prefs.volume * 1.6)
        var gain = plain, limited = false
        if prefs.fixedVolume, let device, let uid {
            let (decibels, silent) = Devices.volume(of: device)
            let systemDB = decibels ?? 0
            if prefs.levels[uid] == nil, !silent {
                // First time on this device: match how it sounds now, so nothing jumps.
                prefs.levels[uid] = Loudness.slider(matching: plain, systemDB: systemDB)
                return   // setting it ran this again
            }
            (gain, limited) = Loudness.gain(slider: prefs.levels[uid] ?? 0.4, systemDB: systemDB)
            if silent { (gain, limited) = (0, false) }
        }
        audio.setGain(gain)
        if limited != volumeLimited { volumeLimited = limited }
    }

    private func pushConfig() {
        var c = PlaybackConfig()
        c.bank = bank(prefs.switchID)
        c.audible = audible
        c.keyUp = prefs.keyUp
        c.keyDelay = max(0, min(150, prefs.keyDelayMs)) / 1000
        c.modifiers = prefs.modifiers
        c.functionKeys = prefs.functionKeys
        c.mouse = prefs.mouse
        for key in prefs.special {
            if let id = key.sound, let sample = effect(id) { c.special[key.code] = sample }
        }
        c.randomPitch = prefs.randomPitch
        c.spatial = Float(prefs.spatial)
        c.pitchSemitones = prefs.tonePitch * 4
        router.update(c)
    }

    private func devicesChanged() {
        // Starting an engine makes macOS create a private device, which lands here too. Rebuilding on
        // that would loop forever, so only react to a real change.
        let latest = Devices.outputs(), current = Devices.defaultOutput
        guard latest != outputs || current != lastDefaultOutput else { return }
        outputs = latest
        lastDefaultOutput = current
        audio.rebuild()
        updateGain()
        refreshSleep()
    }

    private func setLocked(_ locked: Bool) {
        screenLocked = locked
        refreshSleep()
    }

    private func refreshSleep() {
        if computeSleepReason() != sleepReason { apply() }
    }

    private func computeSleepReason() -> String? {
        if screenLocked { return "Screen is locked" }
        if recorder.isRecording { return "Recording a sound" }
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, prefs.sleepInApps.contains(id) {
            return "\(app.localizedName ?? id) is in front"
        }
        if prefs.sleepOnMic, Devices.microphoneInUseElsewhere() { return "Microphone is in use" }
        if prefs.sleepOnSpeakers {
            let uid = outputs.contains { $0.id == prefs.outputUID } ? prefs.outputUID : Devices.defaultOutput.flatMap(Devices.uid)
            if uid == "BuiltInSpeakerDevice" { return "Playing on built-in speakers" }
        }
        if prefs.quietHoursOn {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            if QuietHours.contains((c.hour ?? 0) * 60 + (c.minute ?? 0), start: prefs.quietStart, end: prefs.quietEnd) {
                return "Quiet hours"
            }
        }
        return nil
    }

    private func tick() {
        tickCount += 1
        let nowAllowed = InputTap.isAllowed
        if nowAllowed != allowed {
            allowed = nowAllowed
            apply()
        } else if allowed, audible, !listening {
            apply()
        }
        refreshSleep()
        if audio.state.running.load(ordering: .relaxed), audio.state.idleSeconds > 45 { audio.pause() }
        flushStats(force: tickCount % 15 == 0)
    }

    // MARK: Stats

    private static let statsURL = URL.applicationSupportDirectory.appending(path: "Bonkeys/stats.json")

    private static func loadStats() -> UsageStats {
        guard let data = try? Data(contentsOf: statsURL) else { return UsageStats() }
        return (try? JSONDecoder().decode(UsageStats.self, from: data)) ?? UsageStats()
    }

    private func flushStats(force: Bool) {
        let counts = router.drainCounts()
        if counts.presses + counts.clicks > 0 {
            stats.add(keys: counts.presses, clicks: counts.clicks, on: Date())
            if prefs.switchID == "muyu" { stats.merit = (stats.merit ?? 0) + counts.presses }
            statsDirty = true
        }
        guard force, statsDirty else { return }
        try? FileManager.default.createDirectory(at: Self.statsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stats), (try? data.write(to: Self.statsURL, options: .atomic)) != nil { statsDirty = false }
    }
}
