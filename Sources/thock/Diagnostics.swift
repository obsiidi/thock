import Foundation
import CoreGraphics
import CAtomics

// MARK: - Clock

enum Clock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func ticksToNanos(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func nowNanos() -> UInt64 {
        ticksToNanos(mach_absolute_time())
    }

    /// Microseconds from the system's event timestamp to callback entry.
    /// Assumes CGEvent.timestamp is nanoseconds since boot (verified by
    /// --selftest-tap, see "clock check").
    static func ageMicros(_ e: KeyEvent) -> Int64 {
        (Int64(bitPattern: ticksToNanos(e.received)) - Int64(bitPattern: e.timestamp)) / 1000
    }
}

// MARK: - Output helpers

func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func formatLine(_ e: KeyEvent) -> String {
    let kind: String
    switch e.kind {
    case .keyDown: kind = "kd"
    case .keyUp: kind = "ku"
    case .flagsChanged: kind = "fc"
    }
    return "\(kind) code=\(e.keyCode) rep=\(e.autorepeat) syn=\(e.synthetic) "
        + "age_us=\(Clock.ageMicros(e)) flags=0x\(String(e.flags, radix: 16)) "
        + "ts=\(e.timestamp) seq=\(e.seq)"
}

// MARK: - Drain

/// Pulls events out of the ring on a low-priority thread and hands them to a
/// sink. This is where printing and any other non-real-time work happens.
final class Drain {
    private let ring: EventRing
    private let sink: (KeyEvent) -> Void
    private var thread: Thread?
    private let stopFlag: UnsafeMutablePointer<UInt64>
    private let finished = DispatchSemaphore(value: 0)

    init(ring: EventRing, sink: @escaping (KeyEvent) -> Void) {
        self.ring = ring
        self.sink = sink
        stopFlag = .allocate(capacity: 1)
        stopFlag.initialize(to: 0)
    }

    deinit {
        stopFlag.deallocate()
    }

    func start() {
        let t = Thread { [unowned self] in self.loop() }
        t.name = "thock.drain"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// Stops the thread after a final pass over the ring.
    func stop() {
        catomic_store_release(stopFlag, 1)
        finished.wait()
    }

    private func loop() {
        while catomic_load_acquire(stopFlag) == 0 {
            drainAll()
            usleep(10_000)
        }
        drainAll()
        finished.signal()
    }

    private func drainAll() {
        while let e = ring.pop() {
            sink(e)
        }
    }
}

// MARK: - Permissions

/// True when this process may listen to keyboard events. Otherwise triggers
/// the system prompt once and explains what to grant.
func ensureListenPermission() -> Bool {
    if CGPreflightListenEventAccess() {
        return true
    }
    _ = CGRequestListenEventAccess()
    stderrLine("""
    thock: no permission to listen to keyboard events.
      Grant "Input Monitoring" (or "Accessibility") to the application that
      launched this process — e.g. Terminal.app — under
      System Settings > Privacy & Security, then run again.
    """)
    return false
}

func ensurePostPermission() -> Bool {
    if CGPreflightPostEventAccess() {
        return true
    }
    _ = CGRequestPostEventAccess()
    stderrLine("""
    thock: no permission to post synthetic events (needed by --selftest-tap).
      Grant "Accessibility" to the application that launched this process
      under System Settings > Privacy & Security, then run again.
    """)
    return false
}

// MARK: - --diag

final class DiagStats {
    private let lock = NSLock()
    private var keyDowns = 0
    private var keyUps = 0
    private var flagChanges = 0
    private var repeats = 0

    func record(_ e: KeyEvent) {
        lock.lock()
        switch e.kind {
        case .keyDown:
            keyDowns += 1
            if e.autorepeat != 0 { repeats += 1 }
        case .keyUp: keyUps += 1
        case .flagsChanged: flagChanges += 1
        }
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "keyDown=\(keyDowns) (repeat=\(repeats)) keyUp=\(keyUps) flagsChanged=\(flagChanges)"
    }
}

func runDiag(printAll: Bool) -> Int32 {
    guard ensureListenPermission() else { return 2 }

    let ring = EventRing()
    let stats = DiagStats()
    let drain = Drain(ring: ring) { e in
        stats.record(e)
        if printAll || e.kind == .keyDown {
            print(formatLine(e))
        }
    }
    let tap = KeyTap(ring: ring)
    do {
        try tap.start()
    } catch {
        stderrLine("thock: could not create event tap (\(error))")
        return 3
    }
    drain.start()

    stderrLine("thock --diag: tap active"
        + (printAll ? " (keyDown, keyUp, flagsChanged)" : " (keyDown only; --all for everything)")
        + ". Type keys; Ctrl-C to stop.")

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        drain.stop()
        tap.stop()
        fflush(stdout)
        stderrLine("thock --diag: stopped. \(stats.summary()) "
            + "seen=\(tap.eventCount) dropped=\(ring.droppedCount) reenabled=\(tap.reenableCount)")
        exit(0)
    }
    sigint.resume()
    dispatchMain()
}

// MARK: - --selftest-tap

final class EventCollector {
    private let lock = NSLock()
    private var events: [KeyEvent] = []

    func add(_ e: KeyEvent) {
        lock.lock()
        events.append(e)
        lock.unlock()
    }

    var snapshot: [KeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var syntheticKeyDowns: Int {
        snapshot.filter { $0.kind == .keyDown && $0.synthetic != 0 }.count
    }
}

/// Posts `count` synthetic F20 keystrokes, idles, posts `count` more, then
/// checks that every one arrived exactly once through the tap.
func runTapSelftest(count: Int, idleSeconds: Double) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard ensurePostPermission() else { return 2 }

    let ring = EventRing()
    let collector = EventCollector()
    let drain = Drain(ring: ring) { collector.add($0) }
    let tap = KeyTap(ring: ring)
    do {
        try tap.start()
    } catch {
        stderrLine("thock: could not create event tap (\(error))")
        return 3
    }
    drain.start()
    usleep(300_000)

    // F20: no default binding on macOS, types nothing.
    let testKey: CGKeyCode = 0x5A
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        stderrLine("thock: CGEventSource failed")
        return 3
    }
    source.userData = syntheticMarker

    func burst(_ n: Int) {
        for _ in 0..<n {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: testKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: testKey, keyDown: false)
            else { continue }
            down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            down.post(tap: .cghidEventTap)
            usleep(2_000)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    func waitForKeyDowns(_ expected: Int, timeout: Double) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = collector.syntheticKeyDowns
            if n >= expected { return n }
            usleep(20_000)
        }
        return collector.syntheticKeyDowns
    }

    let timebase = Clock.timebase
    stderrLine("selftest-tap: count=\(count) idle=\(Int(idleSeconds))s "
        + "timebase=\(timebase.numer)/\(timebase.denom)")

    burst(count)
    let gotA = waitForKeyDowns(count, timeout: 3)
    stderrLine("selftest-tap: burst A received \(gotA)/\(count) keyDowns")

    // Clock check: is CGEvent.timestamp nanoseconds or mach ticks?
    if let first = collector.snapshot.first(where: { $0.kind == .keyDown && $0.synthetic != 0 }) {
        let recvNs = Int64(bitPattern: Clock.ticksToNanos(first.received))
        let asNanos = recvNs - Int64(bitPattern: first.timestamp)
        let asTicks = recvNs - Int64(bitPattern: Clock.ticksToNanos(first.timestamp))
        stderrLine("selftest-tap: clock check — age if ts=ns: \(asNanos / 1000) us, "
            + "age if ts=ticks: \(asTicks / 1000) us")
    }

    stderrLine("selftest-tap: idling \(Int(idleSeconds))s ...")
    if idleSeconds > 0 {
        Thread.sleep(forTimeInterval: idleSeconds)
    }

    burst(count)
    let gotB = waitForKeyDowns(2 * count, timeout: 3)
    stderrLine("selftest-tap: burst B received \(gotB - gotA)/\(count) keyDowns")
    usleep(200_000)

    drain.stop()
    tap.stop()

    let events = collector.snapshot
    let synthDowns = events.filter { $0.kind == .keyDown && $0.synthetic != 0 }
    let synthUps = events.filter { $0.kind == .keyUp && $0.synthetic != 0 }
    let realEvents = events.filter { $0.synthetic == 0 }.count
    let dropped = ring.droppedCount
    let reenabled = tap.reenableCount

    var seqGaps = 0
    for (i, e) in events.enumerated() where e.seq != UInt64(i) {
        seqGaps += 1
    }

    let ages = synthDowns.map { Clock.ageMicros($0) }.sorted()
    let median = ages.isEmpty ? 0 : ages[ages.count / 2]
    let maxAge = ages.last ?? 0
    let minAge = ages.first ?? 0
    let agesPlausible = ages.allSatisfy { $0 >= 0 && $0 <= 50_000 }

    var failures: [String] = []
    if synthDowns.count != 2 * count {
        failures.append("expected \(2 * count) synthetic keyDowns, got \(synthDowns.count)")
    }
    if synthUps.count != 2 * count {
        failures.append("expected \(2 * count) synthetic keyUps, got \(synthUps.count)")
    }
    if seqGaps != 0 {
        failures.append("sequence has \(seqGaps) gaps/duplicates")
    }
    if dropped != 0 {
        failures.append("ring dropped \(dropped) events")
    }
    if !agesPlausible {
        failures.append("age out of range (min=\(minAge)us max=\(maxAge)us)")
    }

    print("selftest-tap: keyDowns=\(synthDowns.count)/\(2 * count) keyUps=\(synthUps.count)/\(2 * count) "
        + "seqGaps=\(seqGaps) dropped=\(dropped) reenabled=\(reenabled) realEvents=\(realEvents)")
    print("selftest-tap: age_us min=\(minAge) median=\(median) max=\(maxAge)")

    if failures.isEmpty {
        print("selftest-tap: PASS")
        return 0
    }
    for f in failures {
        print("selftest-tap: FAIL — \(f)")
    }
    return 1
}
