import AppKit
import Charts
import SwiftUI
import BonkeysCore
import UniformTypeIdentifiers

/// A plain AppKit window, because a menu-bar app has no main menu to open a Settings scene from.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let choice = SettingsTab()

    func show(tab: String? = nil) {
        if let tab { choice.name = tab }
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: .shared, choice: choice)))
            w.title = "Bonkeys"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

@Observable final class SettingsTab { var name = "Sound" }

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var choice: SettingsTab

    var body: some View {
        TabView(selection: $choice.name) {
            Tab("Sound", systemImage: "waveform", value: "Sound") { SoundTab(model: model) }
            Tab("My Sounds", systemImage: "mic", value: "My Sounds") { MySoundsTab(model: model) }
            Tab("Keys", systemImage: "keyboard", value: "Keys") { KeysTab(model: model) }
            Tab("Sleep", systemImage: "moon", value: "Sleep") { SleepTab(model: model) }
            Tab("Stats", systemImage: "chart.bar", value: "Stats") { StatsTab(model: model) }
            Tab("General", systemImage: "gearshape", value: "General") { GeneralTab(model: model) }
        }
        .frame(width: 540, height: 580)
    }
}

private struct SoundTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            if !model.allowed { PermissionNotice(model: model) }
            Section {
                Picker("Sound", selection: Binding(get: { model.pack(model.prefs.switchID).id }, set: { model.select($0) })) {
                    ForEach(SoundPack.Group.allCases, id: \.self) { group in
                        let packs = model.packs.filter { $0.group == group }
                        if !packs.isEmpty {
                            Section(group.rawValue) { ForEach(packs) { Text($0.icon.isEmpty ? $0.name : "\($0.icon) \($0.name)").tag($0.id) } }
                        }
                    }
                }
                LabeledContent("Key volume") { Slider(value: $model.level, in: 0...1).frame(width: 220) }
                if model.volumeLimited { VolumeLimitNote() }
                Toggle("Keep separate from the Mac's volume", isOn: $model.prefs.fixedVolume)
                Picker("Play through", selection: $model.prefs.outputUID) {
                    Text("System output").tag(String?.none)
                    ForEach(model.outputs) { Text($0.name).tag(String?.some($0.id)) }
                    if let uid = model.prefs.outputUID, !model.outputs.contains(where: { $0.id == uid }) {
                        Text("Disconnected device").tag(String?.some(uid))
                    }
                }
            }
            Section("Tone") {
                HStack(alignment: .top, spacing: 18) {
                    TonePad(brightness: $model.prefs.toneBrightness, pitch: $model.prefs.tonePitch) {
                        model.preview(model.prefs.switchID)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drag to tune. Left is deeper, right is brighter. Up raises the pitch.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Reset") { model.prefs.toneBrightness = 0; model.prefs.tonePitch = 0 }
                            .disabled(model.prefs.toneBrightness == 0 && model.prefs.tonePitch == 0)
                        Button("Preview") { model.preview(model.prefs.switchID) }
                    }
                }
            }
            Section {
                LabeledContent("Stereo spread") { Slider(value: $model.prefs.spatial, in: 0...1).frame(width: 220) }
                Toggle("Vary pitch on each press", isOn: $model.prefs.randomPitch)
            } footer: {
                Note("Spread places each key where it sits on the keyboard.")
            }
        }
        .formStyle(.grouped)
    }
}

struct TonePad: View {
    @Binding var brightness: Double
    @Binding var pitch: Double
    var onRelease: () -> Void
    private let side: CGFloat = 150

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            Path { p in
                p.move(to: .init(x: side / 2, y: 0)); p.addLine(to: .init(x: side / 2, y: side))
                p.move(to: .init(x: 0, y: side / 2)); p.addLine(to: .init(x: side, y: side / 2))
            }
            .stroke(.primary.opacity(0.12))
            Circle().fill(Color.accentColor.gradient).frame(width: 22, height: 22).shadow(radius: 2)
                .position(x: (brightness + 1) / 2 * (side - 22) + 11, y: (1 - pitch) / 2 * (side - 22) + 11)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                brightness = snap((g.location.x - 11) / (side - 22) * 2 - 1)
                pitch = snap(1 - (g.location.y - 11) / (side - 22) * 2)
            }
            .onEnded { _ in onRelease() })
        .accessibilityElement()
        .accessibilityLabel("Tone pad")
        .accessibilityValue("Brightness \(Int(brightness * 100)), pitch \(Int(pitch * 100))")
        .accessibilityAdjustableAction { direction in
            brightness = max(-1, min(1, brightness + (direction == .increment ? 0.1 : -0.1)))
        }
    }
    private func snap(_ v: Double) -> Double {
        let c = max(-1, min(1, v))
        return abs(c) < 0.06 ? 0 : c
    }
}

private struct KeysTab: View {
    @Bindable var model: AppModel
    @State private var sample = ""
    var body: some View {
        Form {
            Section {
                LabeledContent("Sound delay") {
                    HStack {
                        Slider(value: $model.prefs.keyDelayMs, in: 0...150, step: 5).labelsHidden().frame(width: 200)
                            .accessibilityLabel("Sound delay")
                        Text("\(Int(model.prefs.keyDelayMs)) ms").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                TextField("Try it", text: $sample, prompt: Text("Type here"))
            } footer: {
                Note("Your Mac registers a key partway down. Raise this until the sound lands when the key hits the bottom.")
            }
            SpecialKeysSection(model: model)
            Section {
                Toggle("Sound when a key comes back up", isOn: $model.prefs.keyUp)
                Toggle("Modifier keys", isOn: $model.prefs.modifiers)
                Toggle("Function keys", isOn: $model.prefs.functionKeys)
            }
            Section {
                Toggle("Mouse clicks", isOn: $model.prefs.mouse)
            }
        }
        .formStyle(.grouped)
    }
}

/// Swap one key's sound for something silly.
private struct SpecialKeysSection: View {
    let model: AppModel
    @State private var monitor: Any?

    var body: some View {
        Section {
            ForEach(model.specialKeys) { key in
                HStack {
                    Picker(key.label, selection: Binding(get: { current(key) }, set: { model.setSpecial(key, sound: $0) })) {
                        Text("Normal").tag(String?.none)
                        Section { ForEach(Effect.builtIn) { Text($0.name).tag(String?.some($0.id)) } }
                        if !model.library.effects.isEmpty {
                            Section("My sounds") { ForEach(model.library.effects) { Text($0.name).tag(String?.some($0.id)) } }
                        }
                    }
                    if !SpecialKey.usual.contains(where: { $0.code == key.code }) {
                        Button("Remove \(key.label)", systemImage: "minus.circle.fill") { model.prefs.special.removeAll { $0.code == key.code } }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            Button(monitor == nil ? "Add a Key…" : "Press a key…") { monitor == nil ? begin() : end() }
        } header: { Text("Special keys") } footer: {
            Note("Give a key its own sound. It replaces the normal one.")
        }
        .onDisappear(perform: end)
    }
    /// A sound that has since been deleted counts as normal.
    private func current(_ key: SpecialKey) -> String? {
        model.specialSound(key.code).flatMap { id in model.effects.contains { $0.id == id } ? id : nil }
    }
    private func begin() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            if code != 53, !model.specialKeys.contains(where: { $0.code == code }) {
                model.setSpecial(SpecialKey(code: code, label: HotkeyCenter.keyName(event)), sound: "fx/boing")
            }
            end()
            return nil
        }
    }
    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct MySoundsTab: View {
    let model: AppModel
    @State private var dropping = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(model.recorder.isRecording ? "Stop" : "Record", systemImage: model.recorder.isRecording ? "stop.circle.fill" : "record.circle") {
                        model.toggleRecording()
                    }
                    .tint(.red)
                    Button("Add Files…", systemImage: "plus", action: choose)
                    Spacer()
                    if model.recorder.isRecording {
                        Text("Listening, up to 4 seconds").font(.callout).foregroundStyle(.red)
                    }
                }
                if let problem = model.recorder.problem ?? model.library.problem {
                    Text(problem).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Note("Tap your desk, say “bonk”, or drop audio files here. Each sound can be your whole keyboard or sit on one special key. The microphone is only on while you record.")
            }
            if !model.library.sounds.isEmpty {
                Section("Sounds") { ForEach(model.library.sounds) { UserSoundRow(model: model, sound: $0) } }
            }
            Section {
                ForEach(model.library.folders, id: \.self) { folder in
                    LabeledContent(folder.lastPathComponent) {
                        Button("Use") { model.select(Library.folderPrefix + folder.lastPathComponent) }
                    }
                }
                HStack {
                    Button("Open Packs Folder") { NSWorkspace.shared.open(model.library.packsFolder) }
                    Button("Reload") { model.libraryChanged() }
                }
            } header: { Text("Packs") } footer: {
                Note("A pack is a folder of audio files. Files named space, enter, delete or release go to those keys. All the others play at random on the rest.")
            }
        }
        .formStyle(.grouped)
        .overlay { if dropping { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(6) } }
        .dropDestination(for: URL.self) { urls, _ in model.importSounds(urls); return true } isTargeted: { dropping = $0 }
        .onAppear { model.libraryChanged() }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { model.importSounds(panel.urls) }
    }
}

private struct UserSoundRow: View {
    let model: AppModel
    let sound: UserSound
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack {
            TextField("Name", text: $name).labelsHidden().textFieldStyle(.plain).focused($editing)
                .onSubmit { model.rename(sound, to: name) }
                .onChange(of: editing) { if !editing { model.rename(sound, to: name) } }
            Button("Play \(sound.name)", systemImage: "play.circle.fill") { model.previewEffect(sound.id) }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            Button(model.prefs.switchID == sound.id ? "In Use" : "Use") { model.select(sound.id) }
                .disabled(model.prefs.switchID == sound.id)
            Button("Move \(sound.name) to Trash", systemImage: "trash") { model.remove(sound) }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .onAppear { name = sound.name }
        .onChange(of: sound) { name = sound.name }
    }
}

private struct SleepTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("While another app uses the microphone", isOn: $model.prefs.sleepOnMic)
                Toggle("On the built-in speakers", isOn: $model.prefs.sleepOnSpeakers)
                Toggle("During quiet hours", isOn: $model.prefs.quietHoursOn)
                if model.prefs.quietHoursOn {
                    DatePicker("From", selection: time($model.prefs.quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: time($model.prefs.quietEnd), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Go silent") } footer: {
                Note("Bonkeys is always silent on the lock screen and in password fields.")
            }
            Section("Silent in these apps") {
                ForEach(model.prefs.sleepInApps, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle.fill") { model.prefs.sleepInApps.removeAll { $0 == id } }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Button("Add App…", action: addApp)
            }
        }
        .formStyle(.grouped)
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        } set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) } ?? id
    }
    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.prefs.sleepInApps.contains(id) { model.prefs.sleepInApps.append(id) }
        }
    }
}

private struct StatsTab: View {
    let model: AppModel
    @State private var confirming = false

    private var streakText: String {
        let n = model.stats.streak(today: Date())
        return n == 1 ? "1 day" : "\(n) days"
    }
    private struct Bar: Identifiable { let id: Date; let keys: Int }
    private var bars: [Bar] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<14).reversed().compactMap { n in
            Calendar.current.date(byAdding: .day, value: -n, to: today).map { Bar(id: $0, keys: model.stats.keys(on: $0)) }
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Today", value: model.stats.keys(on: Date()).formatted())
                LabeledContent("All time", value: model.stats.totalKeys.formatted())
                LabeledContent("Mouse clicks", value: model.stats.totalClicks.formatted())
                LabeledContent("Streak", value: streakText)
            }
            Section("Key presses, last 14 days") {
                Chart(bars) { BarMark(x: .value("Day", $0.id, unit: .day), y: .value("Keys", $0.keys)).cornerRadius(3) }
                    .frame(height: 170)
            }
            Section {
                Button("Reset Stats…", role: .destructive) { confirming = true }
                    .confirmationDialog("Erase all typing stats?", isPresented: $confirming) {
                        Button("Erase Stats", role: .destructive) { model.resetStats() }
                    } message: { Text("This can't be undone.") }
            } footer: {
                Note("Only daily totals are kept, on this Mac. Which keys you press is never saved.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Bonkeys is on", isOn: $model.prefs.enabled)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                if let error = model.launchAtLoginError { Text(error).font(.caption).foregroundStyle(.orange) }
                Toggle("Hollow menu bar icon when silent", isOn: $model.prefs.dimIconWhenOff)
                LabeledContent("On/off shortcut") { HotkeyRecorder(hotkey: $model.prefs.hotkey) }
                if model.hotkeyTaken { Text("Another app already uses that shortcut.").font(.caption).foregroundStyle(.orange) }
            }
            Section("Permission") {
                LabeledContent("Input Monitoring") {
                    HStack {
                        Label(model.allowed ? "Allowed" : "Needed", systemImage: model.allowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.allowed ? .green : .orange)
                        Button("Open…") { model.openPrivacySettings() }
                    }
                }
            }
            Section {
                Note("Fun sounds are public-domain (CC0) recordings from Freesound. Mechanical keyboards come from kbsim by Thomas Lai (MIT License).")
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(monitor != nil ? "Press keys…" : hotkey?.label ?? "Record") { monitor == nil ? begin() : end() }
            if hotkey != nil, monitor == nil {
                Button("Clear", systemImage: "xmark.circle.fill") { hotkey = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .onDisappear(perform: end)
    }
    private func begin() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { end() } else if let made = HotkeyCenter.make(from: event) { hotkey = made; end() }
            return nil
        }
    }
    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Small print under a section.
private struct Note: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
