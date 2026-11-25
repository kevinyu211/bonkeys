import SwiftUI

struct MenuPanel: View {
    @Bindable var model: AppModel
    @State private var group = SoundPack.Group.fun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PackIcon(pack: model.pack(model.prefs.switchID), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.pack(model.prefs.switchID).name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Bonkeys", isOn: $model.prefs.enabled).toggleStyle(.switch).labelsHidden()
            }
            if !model.allowed {
                PermissionNotice(model: model)
            } else if let error = model.loadError ?? model.audio.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            Picker("Sounds", selection: $group) {
                ForEach(SoundPack.Group.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView { PackGrid(model: model, group: group) }.frame(height: 232).scrollIndicators(.never)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.level, in: 0...1).accessibilityLabel("Key volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if model.volumeLimited { VolumeLimitNote() }
            HStack {
                Button("Settings…") { SettingsWindow.shared.show() }.keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { group = model.pack(model.prefs.switchID).group }
    }

    private var subtitle: String {
        if !model.prefs.enabled { return "Off" }
        if let reason = model.sleepReason { return reason }
        if model.prefs.switchID == "muyu" { return "功德 +\((model.stats.merit ?? 0).formatted())" }
        return "\(model.stats.keys(on: Date()).formatted()) keys today"
    }
}

struct PackGrid: View {
    let model: AppModel
    let group: SoundPack.Group
    var body: some View {
        let packs = model.packs.filter { $0.group == group }
        if packs.isEmpty {
            VStack(spacing: 10) {
                Text("🎤").font(.system(size: 34))
                Text("Record a sound or add your own files, and they show up here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Add a Sound…") { SettingsWindow.shared.show(tab: "My Sounds") }
            }
            .frame(maxWidth: .infinity).padding(.top, 40).padding(.horizontal, 20)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: packs.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            if start + i < packs.count { PackTile(model: model, pack: packs[start + i]) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                        }
                    }
                }
            }
            .padding(1)
        }
    }
}

struct PackIcon: View {
    let pack: SoundPack
    var size: CGFloat = 30
    var body: some View {
        if pack.icon.isEmpty {
            RoundedRectangle(cornerRadius: size * 0.26).fill(Color(hex: pack.color).gradient)
                .overlay(RoundedRectangle(cornerRadius: size * 0.26).strokeBorder(.primary.opacity(0.18)))
                .frame(width: size * 0.86, height: size * 0.86).frame(width: size, height: size)
        } else {
            Text(pack.icon).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}

private struct PackTile: View {
    let model: AppModel
    let pack: SoundPack
    @State private var hovering = false

    var body: some View {
        let selected = model.prefs.switchID == pack.id
        Button { model.select(pack.id) } label: {
            VStack(spacing: 4) {
                PackIcon(pack: pack)
                Text(pack.name).font(.caption2).multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8).padding(.horizontal, 4)
            .background(.primary.opacity(hovering ? 0.10 : 0.05), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pack.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

struct VolumeLimitNote: View {
    var body: some View {
        Text("Your Mac's volume is too low for the keys to get this loud. Turn the Mac up a little.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionNotice: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bonkeys can't hear your keyboard yet", systemImage: "hand.raised.fill").font(.callout.weight(.semibold))
            Text("Turn on Bonkeys under Input Monitoring. It only listens for the moment a key moves. It never records what you type.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow…") { model.requestPermission() }.buttonStyle(.borderedProminent)
                Button("Relaunch") { model.relaunch() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}
