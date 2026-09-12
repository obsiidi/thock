import Foundation
import CoreGraphics
import AVFoundation
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

    static func nanosToTicks(_ nanos: UInt64) -> UInt64 {
        nanos * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    static func nowNanos() -> UInt64 {
        ticksToNanos(mach_absolute_time())
    }

    private static func micros(from a: UInt64, to b: UInt64) -> Int64 {
        (Int64(bitPattern: b) - Int64(bitPattern: a)) / 1000
    }

    /// Event timestamp (ns since boot, verified by --selftest-tap) -> callback entry.
    static func tapMicros(_ e: KeyEvent) -> Int64 {
        micros(from: e.timestamp, to: ticksToNanos(e.received))
    }

    /// Callback entry -> scheduleBuffer returned. nil if never scheduled.
    static func schedMicros(_ e: KeyEvent) -> Int64? {
        e.scheduled == 0 ? nil : micros(from: ticksToNanos(e.received), to: ticksToNanos(e.scheduled))
    }

    /// Event timestamp -> scheduleBuffer returned. nil if never scheduled.
    static func latMicros(_ e: KeyEvent) -> Int64? {
        e.scheduled == 0 ? nil : micros(from: e.timestamp, to: ticksToNanos(e.scheduled))
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
    let sched = Clock.schedMicros(e).map(String.init) ?? "-"
    let lat = Clock.latMicros(e).map(String.init) ?? "-"
    return "\(kind) code=\(e.keyCode) rep=\(e.autorepeat) syn=\(e.synthetic) "
        + "tap_us=\(Clock.tapMicros(e)) sched_us=\(sched) lat_us=\(lat) "
        + "flags=0x\(String(e.flags, radix: 16)) ts=\(e.timestamp) seq=\(e.seq)"
}

struct Percentiles {
    var min: Int64 = 0
    var median: Int64 = 0
    var p95: Int64 = 0
    var max: Int64 = 0
    var count = 0

    init(_ values: [Int64]) {
        let s = values.sorted()
        count = s.count
        guard !s.isEmpty else { return }
        min = s[0]
        median = s[s.count / 2]
        p95 = s[Swift.min(s.count - 1, (s.count * 95) / 100)]
        max = s[s.count - 1]
    }

    var description: String {
        "min=\(min) median=\(median) p95=\(p95) max=\(max)"
    }
}

// MARK: - Drain

/// Pulls events out of a ring on a low-priority thread and hands them to a
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
    thock: no permission to post synthetic events (needed by the self-tests).
      Grant "Accessibility" to the application that launched this process
      under System Settings > Privacy & Security, then run again.
    """)
    return false
}

// MARK: - Synthetic keystrokes

/// Posts synthetic keystrokes through the HID event path. F20 (0x5A) has no
/// default binding on macOS and types nothing.
final class SyntheticKeys {
    private let source: CGEventSource
    private let key: CGKeyCode = 0x5A

    init?() {
        guard let s = CGEventSource(stateID: .hidSystemState) else { return nil }
        s.userData = syntheticMarker
        source = s
    }

    func press() {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)
        usleep(2_000)
        up.post(tap: .cghidEventTap)
    }

    /// Presses `count` times with `spacingMicros` between key-downs.
    func burst(_ count: Int, spacingMicros: UInt32) {
        for _ in 0..<count {
            press()
            usleep(spacingMicros)
        }
    }
}

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

    /// Polls until `expected` synthetic keyDowns arrived or `timeout` passed.
    @discardableResult
    func waitForKeyDowns(_ expected: Int, timeout: Double) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = syntheticKeyDowns
            if n >= expected { return n }
            usleep(20_000)
        }
        return syntheticKeyDowns
    }
}

// MARK: - Audio setup shared by run / diag / selftest

func makeAudio(samplePath: String) -> AudioEngine? {
    do {
        let audio = try AudioEngine()
        try audio.loadClick(url: URL(fileURLWithPath: samplePath))
        try audio.start()
        return audio
    } catch {
        stderrLine("thock: audio setup failed (\(error)) — sample: \(samplePath)")
        return nil
    }
}

func describe(_ d: AudioEngine.DeviceInfo) -> String {
    "device=\"\(d.name)\" rate=\(Int(d.sampleRate)) ch=\(d.channels) "
        + "io_frames=\(d.bufferFrames) presentation_ms=\(String(format: "%.2f", d.presentationLatencyMs))"
}

// MARK: - run / --diag

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

/// Plays clicks until Ctrl-C. `log == nil` runs silently; `.keyDown` /
/// `.all` print one line per event.
enum LogMode {
    case keyDown
    case all
}

func runMain(samplePath: String, log: LogMode?) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard let audio = makeAudio(samplePath: samplePath) else { return 4 }

    let pipeline = Pipeline(audio: audio)
    let stats = DiagStats()
    let drain = Drain(ring: pipeline.logRing) { e in
        stats.record(e)
        switch log {
        case .all: print(formatLine(e))
        case .keyDown where e.kind == .keyDown: print(formatLine(e))
        default: break
        }
    }
    do {
        try pipeline.start()
    } catch {
        stderrLine("thock: could not create event tap (\(error))")
        audio.stop()
        return 3
    }
    drain.start()

    stderrLine("thock: running. \(describe(audio.deviceInfo())) click_frames=\(audio.clickFrames)")
    if log != nil {
        stderrLine("thock: --diag " + (log == .all ? "(keyDown, keyUp, flagsChanged)" : "(keyDown only; --all for everything)"))
    }
    stderrLine("thock: type keys; Ctrl-C to stop.")

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        pipeline.stop()
        drain.stop()
        audio.stop()
        fflush(stdout)
        stderrLine("thock: stopped. \(stats.summary()) clicks=\(pipeline.triggerCount) "
            + "seen=\(pipeline.tap.eventCount) dropped=\(pipeline.tapRing.droppedCount + pipeline.logRing.droppedCount) "
            + "reenabled=\(pipeline.tap.reenableCount)")
        exit(0)
    }
    sigint.resume()
    dispatchMain()
}

// MARK: - --selftest (Phase 1: latency to scheduleBuffer + render proof)

/// Listens on the main mixer output and records the host time of every
/// silence -> sound transition. With clicks 100 ms apart and a click that is
/// below threshold after 40 ms, one edge == one rendered click.
final class RenderEdgeDetector {
    private let lock = NSLock()
    private var edges: [UInt64] = []   // host ticks
    private var loud = false
    private var silentRun = 0
    private let threshold: Float = 0.01          // -40 dBFS
    private let silenceFrames: Int               // how long below threshold before "quiet"
    private var peakSeen: Float = 0

    init(sampleRate: Double) {
        silenceFrames = Int(sampleRate * 0.020)
    }

    func install(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 256, format: nil) { [unowned self] buffer, when in
            self.analyze(buffer, when: when)
        }
    }

    func remove(from node: AVAudioNode) {
        node.removeTap(onBus: 0)
    }

    private func analyze(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        let base = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        var found: [UInt64] = []
        var localPeak: Float = 0
        for i in 0..<frames {
            var v: Float = 0
            for ch in 0..<channels {
                v = max(v, abs(data[ch][i]))
            }
            localPeak = max(localPeak, v)
            if v > threshold {
                silentRun = 0
                if !loud {
                    loud = true
                    let offsetNs = UInt64(Double(i) / rate * 1e9)
                    found.append(base &+ Clock.nanosToTicks(offsetNs))
                }
            } else {
                silentRun += 1
                if silentRun >= silenceFrames {
                    loud = false
                }
            }
        }
        lock.lock()
        edges.append(contentsOf: found)
        peakSeen = max(peakSeen, localPeak)
        lock.unlock()
    }

    var snapshot: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return edges
    }

    var peak: Float {
        lock.lock()
        defer { lock.unlock() }
        return peakSeen
    }
}

func runSelftest(count: Int, samplePath: String) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard ensurePostPermission() else { return 2 }
    guard let keys = SyntheticKeys() else {
        stderrLine("thock: CGEventSource failed")
        return 3
    }
    guard let audio = makeAudio(samplePath: samplePath) else { return 4 }

    let detector = RenderEdgeDetector(sampleRate: audio.format.sampleRate)
    detector.install(on: audio.engine.mainMixerNode)

    let pipeline = Pipeline(audio: audio)
    let collector = EventCollector()
    let drain = Drain(ring: pipeline.logRing) { collector.add($0) }
    do {
        try pipeline.start()
    } catch {
        stderrLine("thock: could not create event tap (\(error))")
        audio.stop()
        return 3
    }
    drain.start()
    usleep(300_000)

    let device = audio.deviceInfo()
    stderrLine("selftest: count=\(count) spacing=100ms \(describe(device)) click_frames=\(audio.clickFrames)")

    keys.burst(count, spacingMicros: 100_000)
    collector.waitForKeyDowns(count, timeout: 3)
    usleep(300_000)

    detector.remove(from: audio.engine.mainMixerNode)
    pipeline.stop()
    drain.stop()
    audio.stop()

    let downs = collector.snapshot.filter { $0.kind == .keyDown && $0.synthetic != 0 }
    let scheduled = downs.filter { $0.scheduled != 0 }
    let lat = Percentiles(scheduled.compactMap(Clock.latMicros))
    let tap = Percentiles(scheduled.map(Clock.tapMicros))
    let sched = Percentiles(scheduled.compactMap(Clock.schedMicros))

    // Match each scheduled click to the first render edge after it.
    let edges = detector.snapshot.sorted()
    var renderMicros: [Int64] = []
    var edgeIndex = 0
    for e in scheduled.sorted(by: { $0.scheduled < $1.scheduled }) {
        while edgeIndex < edges.count && edges[edgeIndex] < e.scheduled {
            edgeIndex += 1
        }
        guard edgeIndex < edges.count else { break }
        let ns = Clock.ticksToNanos(edges[edgeIndex]) - Clock.ticksToNanos(e.scheduled)
        renderMicros.append(Int64(ns / 1000))
        edgeIndex += 1
    }
    let render = Percentiles(renderMicros)
    let dropped = pipeline.tapRing.droppedCount + pipeline.logRing.droppedCount

    print("selftest: keyDowns=\(downs.count)/\(count) scheduled=\(scheduled.count)/\(count) "
        + "rendered=\(edges.count)/\(count) dropped=\(dropped) reenabled=\(pipeline.tap.reenableCount) "
        + "mixer_peak=\(String(format: "%.3f", detector.peak))")
    print("selftest: lat_us   \(lat.description)   (event -> scheduleBuffer)")
    print("selftest: tap_us   \(tap.description)   (event -> tap callback)")
    print("selftest: sched_us \(sched.description)   (tap callback -> scheduleBuffer)")
    print("selftest: render_us \(render.description) n=\(render.count)   (scheduleBuffer -> mixer output, informational)")

    var failures: [String] = []
    if scheduled.count != count {
        failures.append("scheduled \(scheduled.count) of \(count) keyDowns")
    }
    if lat.median >= 5_000 {
        failures.append("lat_us median \(lat.median) >= 5000")
    }
    if edges.count != count {
        failures.append("rendered \(edges.count) clicks, expected \(count)")
    }
    if dropped != 0 {
        failures.append("ring dropped \(dropped) events")
    }

    if failures.isEmpty {
        print("selftest: PASS")
        return 0
    }
    for f in failures {
        print("selftest: FAIL — \(f)")
    }
    return 1
}

// MARK: - --selftest-tap (Phase 0: capture only, no audio)

/// Posts `count` synthetic keystrokes, idles, posts `count` more, then
/// checks that every one arrived exactly once through the tap.
func runTapSelftest(count: Int, idleSeconds: Double) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard ensurePostPermission() else { return 2 }
    guard let keys = SyntheticKeys() else {
        stderrLine("thock: CGEventSource failed")
        return 3
    }

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

    let timebase = Clock.timebase
    stderrLine("selftest-tap: count=\(count) idle=\(Int(idleSeconds))s "
        + "timebase=\(timebase.numer)/\(timebase.denom)")

    keys.burst(count, spacingMicros: 8_000)
    let gotA = collector.waitForKeyDowns(count, timeout: 3)
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

    keys.burst(count, spacingMicros: 8_000)
    let gotB = collector.waitForKeyDowns(2 * count, timeout: 3)
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

    let ages = Percentiles(synthDowns.map(Clock.tapMicros))
    let agesPlausible = ages.min >= 0 && ages.max <= 50_000

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
        failures.append("tap_us out of range (min=\(ages.min) max=\(ages.max))")
    }

    print("selftest-tap: keyDowns=\(synthDowns.count)/\(2 * count) keyUps=\(synthUps.count)/\(2 * count) "
        + "seqGaps=\(seqGaps) dropped=\(dropped) reenabled=\(reenabled) realEvents=\(realEvents)")
    print("selftest-tap: tap_us \(ages.description)")

    if failures.isEmpty {
        print("selftest-tap: PASS")
        return 0
    }
    for f in failures {
        print("selftest-tap: FAIL — \(f)")
    }
    return 1
}
