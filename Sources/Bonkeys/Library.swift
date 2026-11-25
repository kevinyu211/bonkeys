import AppKit
import AVFoundation
import BonkeysCore
import Observation

/// One sound the user recorded or imported.
struct UserSound: Identifiable, Hashable {
    let url: URL
    var id: String { Library.filePrefix + url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The user's own sounds: single files in `My Sounds`, folders of files in `Packs`.
@Observable
final class Library {
    static let filePrefix = "mine/", folderPrefix = "folder/"
    let root: URL
    private(set) var sounds: [UserSound] = []
    private(set) var folders: [URL] = []
    private(set) var problem: String?

    var soundsFolder: URL { root.appending(path: "My Sounds") }
    var packsFolder: URL { root.appending(path: "Packs") }

    init(root: URL = .applicationSupportDirectory.appending(path: "Bonkeys")) {
        self.root = root
        refresh()
    }

    var packs: [SoundPack] {
        folders.map { .init(id: Self.folderPrefix + $0.lastPathComponent, name: $0.lastPathComponent, icon: "📁", group: .mine, source: .userFolder($0)) }
            + sounds.map { .init(id: $0.id, name: $0.name, icon: "🎤", group: .mine, source: .userFile($0.url)) }
    }
    var effects: [Effect] { sounds.map { .init(id: $0.id, name: $0.name) } }

    func refresh() {
        for folder in [soundsFolder, packsFolder] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        sounds = contents(of: soundsFolder).filter(Self.isAudio).map { UserSound(url: $0) }
        folders = contents(of: packsFolder).filter { f in f.hasDirectoryPath && contents(of: f).contains(where: Self.isAudio) }
    }
    private func contents(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
    }
    static func isAudio(_ url: URL) -> Bool { SampleBank.audioExtensions.contains(url.pathExtension.lowercased()) }

    /// Copies audio files into My Sounds, and folders of audio into Packs.
    func importFiles(_ urls: [URL]) {
        problem = nil
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let usable = isFolder ? (try? SampleBank.load(pack: url)) != nil : Self.isAudio(url) && (try? SampleBank.load(single: url)) != nil
            guard usable else {
                problem = "“\(url.lastPathComponent)” has no sound Bonkeys can play."
                continue
            }
            do { try FileManager.default.copyItem(at: url, to: free(isFolder ? packsFolder : soundsFolder, url.lastPathComponent)) } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Returns the sound's new id, or nil if it couldn't be renamed.
    func rename(_ sound: UserSound, to name: String) -> String? {
        problem = nil
        // A name becomes a file name, so drop what can't be in one.
        let clean = String(name.map { "/:".contains($0) || $0.isNewline ? "-" : $0 }.prefix(60))
            .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
        guard !clean.isEmpty, clean != sound.name else { return nil }
        let target = free(soundsFolder, clean + "." + sound.url.pathExtension)
        do { try FileManager.default.moveItem(at: sound.url, to: target) } catch {
            problem = error.localizedDescription
            return nil
        }
        return UserSound(url: target).id
    }

    func trash(_ sound: UserSound) {
        problem = nil
        do { try FileManager.default.trashItem(at: sound.url, resultingItemURL: nil) } catch { problem = error.localizedDescription }
    }

    func newRecordingURL() -> URL { free(soundsFolder, "Recording.wav") }

    /// A path in `folder` nothing uses yet: "boing.wav", "boing 2.wav", and so on.
    private func free(_ folder: URL, _ name: String) -> URL {
        var url = folder.appending(path: name), n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// Records one short sound from the microphone. The microphone is on only between `start` and `stop`.
@Observable
final class SoundRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var problem: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var onChange: (() -> Void)?

    func start(to url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        problem = nil
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
            Task { @MainActor in self.begin(url, granted) }
        }
    }

    private func begin(_ url: URL, _ granted: Bool) {
        guard !isRecording else { return }
        guard granted else {
            problem = "Turn on Bonkeys under System Settings > Privacy & Security > Microphone."
            return
        }
        do {
            let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                             AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            r.delegate = self
            guard r.record(forDuration: SampleBank.maxSeconds) else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            isRecording = true
            onChange?()
        } catch { problem = "Couldn't record: \(error.localizedDescription)" }
    }

    func stop() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in self.finish(url) }
    }
    private func finish(_ url: URL) {
        guard isRecording else { return }
        recorder = nil
        isRecording = false
        if SampleBank.peak(of: url) < 0.01 {
            try? FileManager.default.removeItem(at: url)   // nothing worth keeping
            problem = "That recording was silent. Check your microphone and try again."
        }
        onChange?()
    }
}
