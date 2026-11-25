import SwiftUI
import BonkeysCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { return runSelfTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.indices.contains(i + 1) {
            return snapshot(to: URL(filePath: CommandLine.arguments[i + 1]))
        }
        AppModel.shared.start()
        if !AppModel.shared.allowed { SettingsWindow.shared.show() }
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.stop() }
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(AppModel.shared.open) }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    /// `Bonkeys --snapshot file.png`: draws the menu panel without opening it.
    private func snapshot(to url: URL) {
        let content: AnyView = if let i = CommandLine.arguments.firstIndex(of: "--tab"), CommandLine.arguments.indices.contains(i + 1) {
            AnyView(SettingsView(model: .shared, choice: { $0.name = CommandLine.arguments[i + 1]; return $0 }(SettingsTab())))
        } else { AnyView(MenuPanel(model: .shared)) }
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            exit(0)
        }
    }

    /// Imports, renames, and reloads in a scratch folder.
    private static func libraryCheck(_ resources: URL) -> String {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let library = Library(root: scratch), boing = resources.appending(path: "Effects/boing.wav")
        library.importFiles([boing, boing, resources.appending(path: "Packs/duck")])
        guard library.problem == nil else { return "FAIL import \(library.problem ?? "")" }
        library.importFiles([resources.appending(path: "CREDITS.md")])
        guard library.problem != nil else { return "FAIL took a text file" }
        library.refresh()
        guard library.sounds.map(\.name) == ["boing", "boing 2"], library.packs.count == 3 else { return "FAIL list \(library.sounds.map(\.name))" }
        guard library.rename(library.sounds[0], to: " ../a:b/c ") == "mine/-a-b-c.wav" else { return "FAIL rename" }
        library.refresh()
        guard library.rename(library.sounds[0], to: "boing 2") != "mine/boing 2.wav", library.rename(library.sounds[0], to: " . ") == nil else { return "FAIL overwrite" }
        library.refresh()
        return library.sounds.count == 2 ? "ok" : "FAIL count"
    }

    /// `Bonkeys --selftest`: silent end-to-end check of the audio path.
    private func runSelfTest() {
        Task {
            guard let root = Bundle.main.resourceURL,
                  let bank = try? SampleBank.load(pack: root.appending(path: "Packs/muyu")) else {
                print("FAIL: sounds not found in the app bundle")
                exit(1)
            }
            let audio = AppModel.shared.audio
            let r = await audio.selfTest(bank.press[0][0])
            print("rate=\(r.rate) buffer=\(r.buffer) frames (\(Double(r.buffer) / max(r.rate, 1) * 1000) ms) deviceLatencyMs=\(r.latencyMs)")
            print("coldStartMs=\(r.startMs) resumeMs=\(r.resumeMs) peak=\(r.peak) rebuildsIn5s=\(r.rebuilds) error=\(audio.lastError ?? "none")")
            print("packs: " + SoundPack.builtIn.map { "\($0.id)=\(AppModel.shared.canLoad($0.id) ? "ok" : "FAIL")" }.joined(separator: " "))
            print("effects: " + Effect.builtIn.map { "\($0.id)=\(AppModel.shared.canLoadEffect($0.id) ? "ok" : "FAIL")" }.joined(separator: " "))
            print("library: \(Self.libraryCheck(root))")
            print("inputMonitoring=\(InputTap.isAllowed) outputs=\(Devices.outputs().map(\.name)) micBusy=\(Devices.microphoneInUseElsewhere())")
            let router = Router(mixer: Mixer())
            var config = PlaybackConfig()
            config.bank = bank
            config.audible = true
            router.update(config)
            let tap = InputTap(router: router, engine: EngineState()) {}
            let tapOK = tap.start()
            if let device = audio.deviceID {
                @Sendable func report() {
                    let v = Devices.volume(of: device), db = v.decibels ?? 0, g = Loudness.gain(slider: 0.25, systemDB: db)
                    print("volume dB=\(db) silent=\(v.silent) keyGain=\(g.gain) heard=\(db + 20 * log10(g.gain)) limited=\(g.limited)")
                }
                report()
                _ = Devices.onVolumeChange(of: device, report)
            }
            if CommandLine.arguments.contains("--listen") { try? await Task.sleep(for: .seconds(20)) }
            print("tapStarted=\(tapOK) events=\(router.drainCounts())")
            tap.stop()
            exit(r.peak > 0.1 ? 0 : 1)
        }
    }
}

@main
struct BonkeysApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let model: AppModel
    var body: some View {
        let on = model.audible && model.allowed
        Image(systemName: on || !model.prefs.dimIconWhenOff ? "keyboard.fill" : "keyboard")
            .accessibilityLabel(on ? "Bonkeys, on" : "Bonkeys, silent")
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
