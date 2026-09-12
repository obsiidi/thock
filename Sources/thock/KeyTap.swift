import Foundation
import CoreGraphics
import CAtomics

/// Value placed in `eventSourceUserData` on synthetic events posted by the
/// self-test, so the tap can tell them apart from real keystrokes.
let syntheticMarker: Int64 = 0x7404C4

/// Listen-only CGEventTap on the session, running on its own high-QoS thread.
///
/// The callback does nothing but copy fields into the `EventRing`. Re-enabling
/// after `.tapDisabledByTimeout` / `.tapDisabledByUserInput` happens inline;
/// a 5 s watchdog timer on the same run loop is the safety net.
final class KeyTap {
    enum Failure: Error {
        case tapCreateFailed
    }

    let ring: EventRing
    fileprivate var port: CFMachPort?
    fileprivate let seq: UnsafeMutablePointer<UInt64>
    fileprivate let reenables: UnsafeMutablePointer<UInt64>

    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let ready = DispatchSemaphore(value: 0)
    private var startFailure: Failure?

    init(ring: EventRing) {
        self.ring = ring
        seq = .allocate(capacity: 1)
        seq.initialize(to: 0)
        reenables = .allocate(capacity: 1)
        reenables.initialize(to: 0)
    }

    deinit {
        seq.deallocate()
        reenables.deallocate()
    }

    /// Times the tap was found disabled and switched back on.
    var reenableCount: UInt64 {
        catomic_load_acquire(reenables)
    }

    /// Events seen by the callback (including ones dropped by the ring).
    var eventCount: UInt64 {
        catomic_load_acquire(seq)
    }

    func start() throws {
        let t = Thread { [unowned self] in self.threadMain() }
        t.name = "thock.keytap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let failure = startFailure {
            throw failure
        }
    }

    func stop() {
        if let port = port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
    }

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            startFailure = .tapCreateFailed
            ready.signal()
            return
        }
        self.port = port

        let rl = CFRunLoopGetCurrent()!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(rl, source, .commonModes)

        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0
        ) { [unowned self] _ in self.watchdog() }
        CFRunLoopAddTimer(rl, timer, .commonModes)

        CGEvent.tapEnable(tap: port, enable: true)
        runLoop = rl
        ready.signal()
        CFRunLoopRun()
    }

    /// Runs on the tap thread every 5 s, outside the event callback.
    private func watchdog() {
        guard let port = port else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            bumpReenables()
        }
    }

    fileprivate func bumpReenables() {
        catomic_store_release(reenables, catomic_load_relaxed(reenables) &+ 1)
    }
}

/// Event-tap callback. Real-time rules apply: no allocation, no locks, no
/// logging, no strings. Everything goes into the ring.
private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()

    let kind: KeyEvent.Kind
    switch type {
    case .keyDown:
        kind = .keyDown
    case .keyUp:
        kind = .keyUp
    case .flagsChanged:
        kind = .flagsChanged
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = tap.port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        tap.bumpReenables()
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }

    var e = KeyEvent()
    e.received = mach_absolute_time()
    e.kind = kind
    e.keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    e.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? 1 : 0
    e.synthetic = event.getIntegerValueField(.eventSourceUserData) == syntheticMarker ? 1 : 0
    e.flags = event.flags.rawValue
    e.timestamp = event.timestamp
    let s = catomic_load_relaxed(tap.seq)
    e.seq = s
    catomic_store_release(tap.seq, s &+ 1)
    _ = tap.ring.push(e)

    return Unmanaged.passUnretained(event)
}
