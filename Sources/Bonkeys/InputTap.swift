import CoreGraphics
import Foundation
import BonkeysCore

/// Listens to key and mouse events on its own thread so a busy UI never delays a sound.
/// Listen-only: it cannot change or block input, and nothing about the keys is stored.
nonisolated final class InputTap: @unchecked Sendable {
    // @unchecked: `held` is touched only by the tap thread; `port`/`loop` are written once, on that
    // thread before `ready` is signalled, and cleared only by the main actor in `stop`.
    private let router: Router
    private let engine: EngineState
    private let wake: @Sendable () -> Void
    private var port: CFMachPort?
    private var loop: CFRunLoop?
    private var held = Set<Int>()

    init(router: Router, engine: EngineState, wake: @escaping @Sendable () -> Void) {
        self.router = router
        self.engine = engine
        self.wake = wake
    }

    static var isAllowed: Bool { CGPreflightListenEventAccess() }
    static func askForPermission() { CGRequestListenEventAccess() }
    var isRunning: Bool { port != nil }

    /// False when macOS refuses, which means the permission is missing.
    func start() -> Bool {
        guard port == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            held.removeAll()
            let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                        .rightMouseDown, .rightMouseUp]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let me = Unmanaged.passUnretained(self).toOpaque()   // owned by AppModel for the app's lifetime
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: { _, type, event, info in
                if let info { Unmanaged<InputTap>.fromOpaque(info).takeUnretainedValue().receive(type, event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: me)
            guard let port else { ready.signal(); return }
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "Bonkeys input"
        thread.start()
        ready.wait()
        return port != nil
    }

    func stop() {
        guard let port, let loop else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        CFRunLoopStop(loop)
        self.port = nil
        self.loop = nil
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            send(.key(code: code(event), down: true))
        case .keyUp:
            send(.key(code: code(event), down: false))
        case .flagsChanged:
            let c = code(event)
            guard KeyMap.modifierCodes.contains(c) else { return }
            guard let bit = KeyMap.modifierMask(for: c) else { return send(.key(code: c, down: true)) } // caps lock
            let down = event.flags.rawValue & bit != 0
            guard down != held.contains(c) else { return }   // fn can report twice
            if down { held.insert(c) } else { held.remove(c) }
            send(.key(code: c, down: down))
        case .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp:
            let width = CGDisplayBounds(CGMainDisplayID()).width
            let x = width > 0 ? max(-1, min(1, event.location.x / width * 2 - 1)) : 0
            send(.mouse(down: type == .leftMouseDown || type == .rightMouseDown, x: Float(x)))
        default: break
        }
    }

    private func code(_ event: CGEvent) -> Int { Int(event.getIntegerValueField(.keyboardEventKeycode)) }

    private func send(_ event: InputEvent) {
        guard router.handle(event) else { return }
        engine.touch()
        if !engine.running.load(ordering: .relaxed) { wake() }
    }
}
