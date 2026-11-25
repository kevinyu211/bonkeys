import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable { let audioID: AudioDeviceID; let id: String; let name: String }

/// Read-only Core Audio queries. None of these need a permission.
nonisolated enum Devices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func ids(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &out) == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var a = address(selector), v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
    }

    static func outputs() -> [OutputDevice] {
        ids(kAudioHardwarePropertyDevices).filter(hasOutput).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return OutputDevice(audioID: id, id: uid, name: name)
        }
    }
    static var defaultOutput: AudioDeviceID? {
        number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }
    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// The device's own volume. Nil decibels means it has no software volume, as with many HDMI displays.
    static func volume(of id: AudioDeviceID) -> (decibels: Double?, silent: Bool) {
        func float(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> Float32? {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
        }
        var m = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let isMuted = AudioObjectGetPropertyData(id, &m, 0, nil, &size, &muted) == noErr && muted == 1
        for element: UInt32 in [0, 1] {
            if let db = float(kAudioDevicePropertyVolumeDecibels, element), db.isFinite {
                let scalar = float(kAudioDevicePropertyVolumeScalar, element) ?? 1
                return (Double(db), isMuted || scalar <= 0)
            }
        }
        return (nil, isMuted)
    }

    /// Calls back on the main queue when this device's volume or mute changes. Returns a way to stop.
    static func onVolumeChange(of id: AudioDeviceID, _ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in handler() }
        let watched = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyMute].map {
            AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementWildcard)
        }
        for var a in watched { AudioObjectAddPropertyListenerBlock(id, &a, .main, block) }
        return { for var a in watched { AudioObjectRemovePropertyListenerBlock(id, &a, .main, block) } }
    }

    /// Smaller hardware buffers mean less delay between key and sound. Only affects this process.
    static func requestBuffer(_ frames: UInt32, on id: AudioDeviceID) {
        var a = address(kAudioDevicePropertyBufferFrameSize), v = frames
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
    static func buffer(of id: AudioDeviceID) -> UInt32? { number(id, kAudioDevicePropertyBufferFrameSize) }

    /// True when another process is recording: a call, a dictation app, a screen recording with voice.
    static func microphoneInUseElsewhere() -> Bool {
        let me = UInt32(getpid())
        return ids(kAudioHardwarePropertyProcessObjectList).contains { p in
            guard number(p, kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = number(p, kAudioProcessPropertyPID), pid != me else { return false }
            // Siri's always-on wake-word listener holds the microphone all day. That isn't a call.
            return processName(Int32(bitPattern: pid)) != "corespeechd"
        }
    }
    private static func processName(_ pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        return String(decoding: buffer.prefix(Int(max(0, n))), as: UTF8.self)
    }

    /// Calls back on the main queue when devices come, go, or the default changes.
    static func onChange(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var a = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { @Sendable _, _ in handler() }
        }
    }
}
