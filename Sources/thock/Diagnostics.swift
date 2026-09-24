import AppKit
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
    let voice = e.scheduled == 0 ? "-" : "\(e.voice)"
    let rate = e.scheduled == 0 ? "-" : String(format: "%.3f", e.rate)
    let sample = e.sample < 0 ? "-" : "\(e.sample)"
    let scan = e.scan < 0 ? "-" : "\(e.scan)"
    let force = e.sample < 0 ? "-" : String(format: "%.2f", e.force)
    let gain = e.sample < 0 ? "-" : String(format: "%.1f", e.gainDb)
    let head = "\(kind) key=\(Scancodes.name(Int(e.keyCode))) code=\(e.keyCode) scan=\(scan) "
        + "down=\(e.pressed) sample=\(sample) force=\(force) gain_db=\(gain) rep=\(e.autorepeat) syn=\(e.synthetic) "
    return head + "tap_us=\(Clock.tapMicros(e)) sched_us=\(sched) lat_us=\(lat) "
        + "voice=\(voice) rate=\(rate) "
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

    /// Presses `count` times with `spacingMicros` between key-downs
    /// (press() itself holds the key for 2 ms).
    func burst(_ count: Int, spacingMicros: UInt32) {
        for _ in 0..<count {
            press()
            usleep(spacingMicros > 2_000 ? spacingMicros - 2_000 : 0)
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

/// Which sounds to load.
enum PackSelection {
    case builtIn(clickPath: String)
    case directory(URL)

    var label: String {
        switch self {
        case .builtIn(let p): return "built-in click (\(p))"
        case .directory(let u): return u.lastPathComponent
        }
    }
}

/// Engine with the pack loaded; `start` false leaves the engine stopped
/// (for --map / --list-packs, which only need the sample tables).
func makeAudio(_ selection: PackSelection, bufferFrames: UInt32, start: Bool = true) -> AudioEngine? {
    do {
        let audio = try AudioEngine(bufferFrames: bufferFrames)
        switch selection {
        case .builtIn(let path):
            try audio.loadBuiltInClick(url: URL(fileURLWithPath: path))
        case .directory(let url):
            try audio.load(packDirectory: url)
        }
        if start {
            try audio.start()
        }
        return audio
    } catch {
        stderrLine("thock: audio setup failed for \(selection.label): \(error)")
        return nil
    }
}

func describe(_ p: Soundpack) -> String {
    "pack=\"\(p.name)\" type=\(p.type) v\(p.version) samples=\(p.samples.count) "
        + "keys: defined=\(p.directlyDefined) default=\(p.byDefault) keyup=\(p.hasKeyUp ? "yes" : "no")"
}

func describe(_ d: AudioEngine.DeviceInfo) -> String {
    let presentation = String(format: "%.2f", d.presentationLatencyMs)
    return "device=\"\(d.name)\" rate=\(Int(d.sampleRate)) ch=\(d.channels) "
        + "io_frames=\(d.bufferFrames) (requested \(d.bufferFramesRequested)) "
        + "presentation_ms=\(presentation)"
}

/// Sum of squares per channel, averaged over channels: the energy of one
/// click, used as the yardstick for the mixer energy in the self-test.
func energy(of buffer: AVAudioPCMBuffer, upTo limit: Int = Int.max) -> Double {
    guard let data = buffer.floatChannelData else { return 0 }
    let channels = Int(buffer.format.channelCount)
    let frames = min(Int(buffer.frameLength), max(0, limit))
    var total = 0.0
    for ch in 0..<channels {
        for i in 0..<frames {
            let v = Double(data[ch][i])
            total += v * v
        }
    }
    return total / Double(channels)
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

func runMain(_ selection: PackSelection, bufferFrames: UInt32, jitter: Float, velocity: Bool, log: LogMode?) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard let audio = makeAudio(selection, bufferFrames: bufferFrames), let pack = audio.pack else { return 4 }

    var motion: MotionSensor?
    if velocity && MotionSensor.isAvailable() {
        let m = MotionSensor()
        do {
            try m.start()
            motion = m
        } catch {
            stderrLine("thock: accelerometer unavailable (\(error)) — fixed loudness")
        }
    }
    let pipeline = Pipeline(audio: audio, pack: pack, motion: motion)
    pipeline.jitter = jitter
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

    stderrLine("thock: running. \(describe(audio.deviceInfo())) voices=\(VoiceMixer.voiceCount)")
    stderrLine("thock: \(describe(pack))")
    stderrLine("thock: velocity " + (motion != nil ? "on (accelerometer)" : (velocity ? "off (no sensor)" : "off")))
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
        motion?.stop()
        fflush(stdout)
        stderrLine("thock: stopped. \(stats.summary()) clicks=\(pipeline.triggerCount) "
            + "voices_started=\(audio.mixer.voicesStarted) "
            + "seen=\(pipeline.tap.eventCount) dropped=\(pipeline.tapRing.droppedCount + pipeline.logRing.droppedCount) "
            + "commands_dropped=\(audio.mixer.commandsDropped) "
            + "reenabled=\(pipeline.tap.reenableCount) (\(pipeline.tap.disableReasons)) overloads=\(audio.overloadCount)"
            + (motion.map { " motion_reports=\($0.reportCount) gaps=\($0.gapCount)" } ?? ""))
        exit(0)
    }
    sigint.resume()
    dispatchMain()
}

// MARK: - --diag-motion / --motion-selftest

/// One evaluated keystroke: peaks around the key event, evaluated ~40 ms
/// after it so the post-window samples have arrived. No key identity is
/// recorded — this log must never be a keylogger.
struct MotionHit {
    var eventNanos: UInt64
    var prePeak: Float       // max impact in [-20 ms, 0]
    var postPeak: Float      // max impact in (0, +20 ms]
    var maxOffsetUs: Int64   // where the overall max lies relative to the event
    var force: Float
}

/// Captures real (non-synthetic, non-repeat) key-downs together with the
/// accelerometer and evaluates each one after a short delay.
final class MotionCapture {
    let sensor = MotionSensor()
    let ring = EventRing()
    private(set) var tap: KeyTap!
    private var drain: Drain!
    private let velocity: VelocityEstimator
    private let lock = NSLock()
    private var pending: [UInt64] = []      // event nanos awaiting evaluation
    private(set) var hits: [MotionHit] = []
    var onHit: ((MotionHit) -> Void)?
    private var timer: DispatchSourceTimer?

    init() {
        velocity = VelocityEstimator(sensor: sensor)
    }

    func start() throws {
        try sensor.start()
        tap = KeyTap(ring: ring)
        drain = Drain(ring: ring) { [weak self] e in
            // Letters and space only: modifiers, backspace and enter are
            // hit differently and would blur the light/hard comparison.
            guard let self = self, e.kind == .keyDown, e.autorepeat == 0, e.synthetic == 0,
                  MotionCapture.isLetterOrSpace(Int(e.keyCode)) else { return }
            self.lock.lock()
            self.pending.append(e.timestamp)
            self.lock.unlock()
        }
        try tap.start()
        drain.start()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "thock.motion.eval"))
        t.schedule(deadline: .now() + 0.05, repeating: 0.01)
        t.setEventHandler { [weak self] in self?.evaluate() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        tap.stop()
        drain.stop()
        sensor.stop()
    }

    private func evaluate() {
        let nowNs = Clock.nowNanos()
        lock.lock()
        let due = pending.filter { nowNs &- $0 > 40_000_000 }
        pending.removeAll { nowNs &- $0 > 40_000_000 }
        lock.unlock()
        for eventNs in due {
            let t = Clock.nanosToTicks(eventNs)
            let ms = Clock.nanosToTicks(1_000_000)
            let pre = sensor.ring.peak(from: t &- 20 * ms, to: t)
            let post = sensor.ring.peak(from: t &+ 1, to: t &+ 20 * ms)
            // Locate the overall max in 1 ms steps.
            var bestOffset: Int64 = 0
            var best: Float = -1
            for step in -20...20 {
                let a = step >= 0 ? t &+ UInt64(step) * ms : t &- UInt64(-step) * ms
                let v = sensor.ring.peak(from: a, to: a &+ ms)
                if v > best { best = v; bestOffset = Int64(step) * 1000 }
            }
            let force = velocity.force(eventNanos: eventNs, nowTicks: mach_absolute_time())
            let hit = MotionHit(eventNanos: eventNs, prePeak: pre, postPeak: post, maxOffsetUs: bestOffset, force: force)
            lock.lock()
            hits.append(hit)
            lock.unlock()
            onHit?(hit)
        }
    }

    var snapshot: [MotionHit] {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }

    static func isLetterOrSpace(_ keyCode: Int) -> Bool {
        let letters: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
                                 31, 32, 34, 35, 37, 38, 40, 45, 46, 49]
        return letters.contains(keyCode)
    }
}

func runDiagMotion() -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard MotionSensor.isAvailable() else {
        stderrLine("diag-motion: no accelerometer on this Mac")
        return 1
    }
    let capture = MotionCapture()
    let t0 = Clock.nowNanos()
    capture.onHit = { h in
        let rel = Double(Int64(bitPattern: h.eventNanos) - Int64(bitPattern: t0)) / 1e9
        print(String(format: "hit t=%8.3fs pre=%.4fg post=%.4fg max_at=%+.1fms force=%.2f gain_db=%.1f",
                     rel, h.prePeak, h.postPeak, Double(h.maxOffsetUs) / 1000, h.force, VelocityEstimator.gainDb(force: h.force)))
    }
    do {
        try capture.start()
    } catch {
        stderrLine("diag-motion: start failed: \(error)")
        return 3
    }
    usleep(1_000_000)
    stderrLine("diag-motion: sensor streaming (\(capture.sensor.reportCount)/s), noise floor \(String(format: "%.4f", capture.sensor.noiseFloor)) g. "
        + "Type on the built-in keyboard; Ctrl-C for the summary. No key codes are logged.")

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let started = Date()
    sigint.setEventHandler {
        capture.stop()
        let hits = capture.snapshot
        let secs = Date().timeIntervalSince(started)
        let rate = Double(capture.sensor.reportCount) / secs
        print(String(format: "diag-motion: reports=%d (%.0f/s) gaps=%d hits=%d noise=%.4fg",
                     capture.sensor.reportCount, rate, capture.sensor.gapCount, hits.count, capture.sensor.noiseFloor))
        if !hits.isEmpty {
            let offsets = Percentiles(hits.map { $0.maxOffsetUs })
            let inPre = hits.filter { $0.maxOffsetUs <= 0 }.count
            let peaks = Percentiles(hits.map { Int64($0.prePeak.isNaN ? 0 : max($0.prePeak, $0.postPeak) * 10_000) })
            let forces = Percentiles(hits.map { Int64($0.force * 100) })
            print("diag-motion: max_offset_us \(offsets.description)   (negative = impact arrived before the key event)")
            print("diag-motion: max in pre-window (usable without delay): \(inPre)/\(hits.count)")
            print("diag-motion: peak (1e-4 g) \(peaks.description)")
            print("diag-motion: force (%) \(forces.description)")
        }
        exit(0)
    }
    sigint.resume()
    dispatchMain()
}

/// Interactive: 10 light hits, then 10 hard hits; PASS if the hard median is
/// at least twice the light median and the two groups do not overlap much.
func runMotionSelftest(hitsPerGroup n: Int = 10) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard MotionSensor.isAvailable() else {
        print("motion-selftest: FAIL — no accelerometer on this Mac")
        return 1
    }
    let capture = MotionCapture()
    do {
        try capture.start()
    } catch {
        stderrLine("motion-selftest: start failed: \(error)")
        return 3
    }
    usleep(500_000)

    func collect(_ count: Int, prompt: String) -> [Float] {
        let before = capture.snapshot.count
        stderrLine(prompt)
        var lastShown = 0
        while capture.snapshot.count < before + count {
            let have = capture.snapshot.count - before
            if have != lastShown {
                lastShown = have
                stderrLine("  \(have)/\(count)")
            }
            usleep(50_000)
        }
        stderrLine("  \(count)/\(count) ✓")
        return capture.snapshot[before..<(before + count)].map { max($0.prePeak, $0.postPeak) }
    }

    let light = collect(n, prompt: "motion-selftest: tap any letter key \(n) times LIGHTLY (as softly as you can).")
    usleep(700_000)
    let hard = collect(n, prompt: "motion-selftest: now hit a letter key \(n) times HARD.")
    capture.stop()

    func median(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
    func pct(_ v: [Float], _ p: Double) -> Float { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
    let ml = median(light), mh = median(hard)
    let ratio = ml > 0 ? mh / ml : Float.infinity
    let overlapFree = pct(light, 0.75) < pct(hard, 0.25)
    print(String(format: "motion-selftest: light median=%.4fg (p25=%.4f p75=%.4f)  hard median=%.4fg (p25=%.4f p75=%.4f)  ratio=%.2f",
                 ml, pct(light, 0.25), pct(light, 0.75), mh, pct(hard, 0.25), pct(hard, 0.75), ratio))
    var failures: [String] = []
    if ratio < 2 { failures.append("hard/light ratio \(String(format: "%.2f", ratio)) < 2") }
    if !overlapFree { failures.append("light p75 >= hard p25 — groups overlap") }
    if failures.isEmpty {
        print("motion-selftest: PASS")
        return 0
    }
    for f in failures { print("motion-selftest: FAIL — \(f)") }
    return 1
}

// MARK: - --selftest

/// Probe on the main mixer output: detects click onsets, integrates energy
/// and tracks the peak.
///
/// Onsets: `fast` is a peak-hold with 0.3 ms decay (tracks the click
/// envelope), `ref` is the max of `fast` over the window 1–2 ms earlier. An
/// onset is a sample where fast > threshold and fast > 2 × ref, with a 4 ms
/// refractory period. Reliable for isolated clicks (spaced mode); inside a
/// burst overlapping tails can hide an onset, so bursts are judged by
/// energy and by the render block's own start log instead.
final class MixerProbe {
    private let lock = NSLock()
    private var onsets: [UInt64] = []   // host ticks
    private var peakSeen: Float = 0
    private var energySum = 0.0
    private var node: AVAudioNode?

    private let threshold: Float = 0.01          // -40 dBFS
    private let ratio: Float = 2.0
    private let fastDecay: Float
    private let refractoryFrames: Int
    private let win1: Int                        // 1 ms in frames
    private let win2: Int                        // 2 ms in frames
    private var fast: Float = 0
    private var history: [Float]                 // ring of `fast`, win2 long
    private var histIndex = 0
    private var frameCounter = 0
    private var lastOnsetFrame = Int.min / 2

    init(sampleRate: Double) {
        fastDecay = Float(exp(-1.0 / (0.0003 * sampleRate)))
        refractoryFrames = Int(sampleRate * 0.004)
        win1 = Int(sampleRate * 0.001)
        win2 = Int(sampleRate * 0.002)
        history = [Float](repeating: 0, count: win2)
    }

    func install(on node: AVAudioNode) {
        self.node = node
        node.installTap(onBus: 0, bufferSize: 256, format: nil) { [unowned self] buffer, when in
            self.analyze(buffer, when: when)
        }
    }

    func remove() {
        node?.removeTap(onBus: 0)
        node = nil
    }

    private func analyze(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        let base = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        var found: [UInt64] = []
        var localPeak: Float = 0
        var localEnergy = 0.0
        for i in 0..<frames {
            var v: Float = 0
            for ch in 0..<channels {
                let x = data[ch][i]
                v = max(v, abs(x))
                localEnergy += Double(x * x)
            }
            localPeak = max(localPeak, v)
            fast = max(v, fast * fastDecay)

            var ref: Float = 0
            var k = histIndex           // oldest entry (2 ms ago) is at histIndex
            for _ in 0..<(win2 - win1) {
                ref = max(ref, history[k])
                k += 1
                if k == win2 { k = 0 }
            }
            history[histIndex] = fast
            histIndex += 1
            if histIndex == win2 { histIndex = 0 }

            if fast > threshold, fast > ratio * ref, frameCounter - lastOnsetFrame > refractoryFrames {
                lastOnsetFrame = frameCounter
                let offsetNs = UInt64(Double(i) / rate * 1e9)
                found.append(base &+ Clock.nanosToTicks(offsetNs))
            }
            frameCounter += 1
        }
        lock.lock()
        onsets.append(contentsOf: found)
        peakSeen = max(peakSeen, localPeak)
        energySum += localEnergy / Double(channels)
        lock.unlock()
    }

    var snapshot: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return onsets
    }

    var peak: Float {
        lock.lock()
        defer { lock.unlock() }
        return peakSeen
    }

    var energy: Double {
        lock.lock()
        defer { lock.unlock() }
        return energySum
    }
}

struct SelftestOptions {
    var count: Int
    var spacingMicros: UInt32
    var selection: PackSelection
    var bufferFrames: UInt32
    var label: String
    var jitter: Float = 0.03
    var verbose = false
}

func runSelftest(_ opt: SelftestOptions) -> Int32 {
    guard ensureListenPermission() else { return 2 }
    guard ensurePostPermission() else { return 2 }
    guard let keys = SyntheticKeys() else {
        stderrLine("thock: CGEventSource failed")
        return 3
    }
    guard let audio = makeAudio(opt.selection, bufferFrames: opt.bufferFrames), let pack = audio.pack else { return 4 }
    // The synthetic key is F20 (CGKeyCode 90): whatever the pack maps it to.
    let downSample = pack.keyDown[90]
    let upSample = pack.keyUp[90]
    guard downSample >= 0 else {
        stderrLine("thock: pack maps no sound to F20, cannot self-test")
        return 4
    }
    let soundsPerPress = 1 + (upSample >= 0 ? 1 : 0)
    let isClick: Bool
    if case .builtIn = opt.selection { isClick = true } else { isClick = false }

    let probe = MixerProbe(sampleRate: audio.format.sampleRate)
    probe.install(on: audio.engine.mainMixerNode)

    let pipeline = Pipeline(audio: audio, pack: pack)
    pipeline.jitter = opt.jitter
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
    usleep(500_000)

    let device = audio.deviceInfo()
    stderrLine("selftest: mode=\(opt.label) count=\(opt.count) spacing=\(opt.spacingMicros / 1000)ms "
        + "\(describe(device)) voices=\(VoiceMixer.voiceCount)")
    stderrLine("selftest: \(describe(pack)) F20 -> down=#\(downSample) up=#\(upSample) "
        + "frames=\(pack.samples[Int(downSample)].frames)")

    keys.burst(opt.count, spacingMicros: opt.spacingMicros)
    collector.waitForKeyDowns(opt.count, timeout: 3)
    usleep(400_000)

    probe.remove()
    pipeline.stop()
    drain.stop()
    audio.stop()

    // Events (trigger thread) and starts (render thread) are both FIFO.
    let downs = collector.snapshot.filter { $0.kind == .keyDown && $0.synthetic != 0 }
    let scheduled = downs.filter { $0.scheduled != 0 }.sorted { $0.scheduled < $1.scheduled }
    var allStarts: [VoiceCommand] = []
    while let c = audio.mixer.startLog.pop() {
        allStarts.append(c)
    }
    // Key-up sounds interleave with key-down starts; keep the down ones.
    let starts = allStarts.filter { $0.sample == downSample }
    let onsets = probe.snapshot.sorted()

    var e2rMicros: [Int64] = []       // event -> render cycle that started the voice
    var queueMicros: [Int64] = []     // command pushed -> render cycle
    var onsetMicros: [Int64] = []     // event -> onset at the mixer output (external)
    var agreeMicros: [Int64] = []     // onset - render cycle time
    for (i, e) in scheduled.enumerated() {
        let eventNs = Int64(bitPattern: e.timestamp)
        if i < starts.count {
            let startNs = Int64(bitPattern: Clock.ticksToNanos(starts[i].started))
            let issuedNs = Int64(bitPattern: Clock.ticksToNanos(starts[i].issued))
            e2rMicros.append((startNs - eventNs) / 1000)
            queueMicros.append((startNs - issuedNs) / 1000)
            if i < onsets.count {
                let onsetNs = Int64(bitPattern: Clock.ticksToNanos(onsets[i]))
                onsetMicros.append((onsetNs - eventNs) / 1000)
                agreeMicros.append((onsetNs - startNs) / 1000)
            }
        }
        if opt.verbose {
            let render = i < starts.count ? "\(e2rMicros[i])" : "-"
            let onset = i < onsets.count && i < starts.count ? "\(onsetMicros[i])" : "-"
            print("  #\(i) voice=\(e.voice) rate=\(String(format: "%.3f", e.rate)) tap_us=\(Clock.tapMicros(e)) "
                + "sched_us=\(Clock.schedMicros(e) ?? 0) e2r_us=\(render) onset_us=\(onset)")
        }
    }
    let lat = Percentiles(scheduled.compactMap(Clock.latMicros))
    let tap = Percentiles(scheduled.map(Clock.tapMicros))
    let e2r = Percentiles(e2rMicros)
    let queue = Percentiles(queueMicros)
    let onset = Percentiles(onsetMicros)
    let agree = Percentiles(agreeMicros)
    let rates = scheduled.map { $0.rate }

    let voicesStarted = Int(audio.mixer.voicesStarted)
    let dropped = pipeline.tapRing.droppedCount + pipeline.logRing.droppedCount
    let commandsDropped = audio.mixer.commandsDropped
    let overloads = audio.overloadCount
    // Expected mixer energy: every started voice plays its sample until it
    // ends or until the round-robin reuses the voice 16 starts later.
    var expectedEnergy = 0.0
    var stolen = 0
    for (j, c) in allStarts.enumerated() {
        guard let buffer = audio.mixer.buffer(at: c.sample) else { continue }
        var limit = Int.max
        if j + VoiceMixer.voiceCount < allStarts.count {
            let dtNs = Clock.ticksToNanos(allStarts[j + VoiceMixer.voiceCount].started) - Clock.ticksToNanos(c.started)
            limit = Int(Double(dtNs) / 1e9 * audio.format.sampleRate * Double(c.rate))
            if limit < Int(buffer.frameLength) { stolen += 1 }
        }
        expectedEnergy += energy(of: buffer, upTo: limit) * Double(c.gain * c.gain)
    }
    let energyRatio = expectedEnergy > 0 ? probe.energy / expectedEnergy : 0
    let expectedVoices = opt.count * soundsPerPress
    let rateMin = String(format: "%.3f", rates.min() ?? 1)
    let rateMax = String(format: "%.3f", rates.max() ?? 1)
    let tag = "selftest[\(opt.label)]"

    print("\(tag): keyDowns=\(downs.count)/\(opt.count) scheduled=\(scheduled.count)/\(opt.count) "
        + "voices_started=\(voicesStarted)/\(expectedVoices) stolen=\(stolen) "
        + (isClick ? "onsets=\(onsets.count)/\(opt.count) " : "")
        + "energy=\(String(format: "%.2f", energyRatio))x expected "
        + "mixer_peak=\(String(format: "%.3f", probe.peak))")
    print("\(tag): overloads=\(overloads) dropped=\(dropped) commands_dropped=\(commandsDropped) "
        + "reenabled=\(pipeline.tap.reenableCount) (\(pipeline.tap.disableReasons)) "
        + "io_frames=\(device.bufferFrames)/\(device.bufferFramesRequested) rate=\(rateMin)..\(rateMax)")
    print("\(tag): e2r_us     \(e2r.description)   (event -> render cycle that started the voice)")
    if isClick {
        print("\(tag): onset_us   \(onset.description)   (event -> onset at mixer output, n=\(onset.count))")
        print("\(tag): agree_us   \(agree.description)   (onset - render cycle; should be ~0..+1 buffer)")
    }
    print("\(tag): lat_us     \(lat.description)   (event -> command queued)")
    print("\(tag): tap_us     \(tap.description)   (event -> tap callback)")
    print("\(tag): queue_us   \(queue.description)   (command queued -> render cycle)")

    var failures: [String] = []
    if scheduled.count != opt.count {
        failures.append("scheduled \(scheduled.count) of \(opt.count) keyDowns")
    }
    if voicesStarted != expectedVoices {
        failures.append("render block started \(voicesStarted) voices, expected \(expectedVoices)")
    }
    if isClick && opt.spacingMicros >= 60_000 && onsets.count != opt.count {
        failures.append("onsets \(onsets.count), expected \(opt.count)")
    }
    // Overlapping copies of the same recording add with partial correlation,
    // so bursts get a wider band than isolated hits.
    let energyTolerance = opt.spacingMicros >= 60_000 ? 0.1 : 0.2
    if abs(energyRatio - 1) > energyTolerance {
        failures.append("mixer energy = \(String(format: "%.2f", energyRatio))x expected, tolerance ±\(Int(energyTolerance * 100))%")
    }
    if overloads != 0 {
        failures.append("\(overloads) HAL processor overloads")
    }
    if dropped != 0 || commandsDropped != 0 {
        failures.append("dropped events=\(dropped) commands=\(commandsDropped)")
    }
    if lat.median >= 5_000 {
        failures.append("lat_us median \(lat.median) >= 5000")
    }
    if e2r.p95 >= 8_000 {
        failures.append("e2r_us p95 \(e2r.p95) >= 8000")
    }
    if device.bufferFrames != device.bufferFramesRequested {
        failures.append("io_frames \(device.bufferFrames) != requested \(device.bufferFramesRequested)")
    }

    if failures.isEmpty {
        print("\(tag): PASS")
        return 0
    }
    for f in failures {
        print("\(tag): FAIL — \(f)")
    }
    return 1
}

// MARK: - --list-packs / --map

func runListPacks(root: URL, bufferFrames: UInt32) -> Int32 {
    let dirs = SoundpackLoader.listPacks(in: root)
    if dirs.isEmpty {
        print("no packs found in \(root.path) (a pack is a folder with a config.json)")
        return 1
    }
    for dir in dirs {
        if let audio = makeAudio(.directory(dir), bufferFrames: bufferFrames, start: false), let p = audio.pack {
            print("\(dir.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0)) \(describe(p))")
        } else {
            print("\(dir.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0)) FAILED to load")
        }
    }
    return 0
}

func runMap(_ selection: PackSelection, bufferFrames: UInt32) -> Int32 {
    guard let audio = makeAudio(selection, bufferFrames: bufferFrames, start: false), let p = audio.pack else { return 4 }
    print(describe(p))
    print("cg   key        scan    down  source                 up    source")
    for cg in 0..<128 where !Scancodes.names[cg].isEmpty {
        let scan = Scancodes.table[cg]
        let down = p.keyDown[cg]
        let up = p.keyUp[cg]
        func src(_ i: Int32) -> String { i < 0 ? "" : p.samples[Int(i)].source }
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        print(pad("\(cg)", 5) + pad(Scancodes.name(cg), 11) + pad(scan < 0 ? "-" : "\(scan)", 8)
            + pad(down < 0 ? "-" : "#\(down)", 6) + pad(src(down), 23)
            + pad(up < 0 ? "-" : "#\(up)", 6) + src(up))
    }
    let letters = (0..<26).compactMap { i -> Int32? in
        let cg = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6][i]
        return p.keyDown[cg]
    }
    let letterSet = Set(letters)
    let space = p.keyDown[49], enter = p.keyDown[36], backspace = p.keyDown[51]
    print("summary: letters use \(letterSet.count) sample(s) \(letterSet.sorted().map { "#\($0)" }.joined(separator: " ")); "
        + "space=#\(space) enter=#\(enter) backspace=#\(backspace)")
    let distinct = !letterSet.contains(space) && !letterSet.contains(enter) && !letterSet.contains(backspace)
        && Set([space, enter, backspace]).count == 3
    print("summary: space/enter/backspace distinct from letters and each other: \(distinct ? "yes" : "NO")")
    return distinct ? 0 : 1
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

// MARK: - --stats / --stats-card / --selftest-stats

func printStatsSummary(_ s: StatsSummary, labels: [String]) {
    let active = TypingStats.activeMinutes(Array(s.last14.suffix(7)))
    print("stats: today keys=\(s.today.keys) peak_wpm=\(s.today.peakWPM) active_min=\(s.today.activeMinuteCount) "
        + "clicks=\(s.today.clicks) force_samples=\(s.today.forceSamples)")
    print("stats: week  keys=\(s.week.keys) peak_wpm=\(s.week.peakWPM) active_min=\(active) streak=\(s.streak)")
    print("stats: all   keys=\(s.totalKeys) days=\(s.totalDays) best_day=\(s.bestDayKeys) (\(s.bestDayDate ?? "-")) best_wpm=\(s.bestWPM)")
    let top = s.week.perKey.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(5)
    print("stats: top keys (7 d): " + top.map { "\(labels[$0.offset])=\($0.element)" }.joined(separator: " "))
    if let hk = s.week.hardestKey {
        print("stats: hardest-hit key (7 d): \(labels[hk.keyCode]) avg_force=\(String(format: "%.2f", hk.force))")
    }
    print("stats: line: \(StatsFormat.todayLine(s))")
}

func runStats() -> Int32 {
    let stats = TypingStats()
    print("stats: file \(stats.fileURL.path)")
    printStatsSummary(stats.summary(), labels: KeyboardLayout.labels())
    return 0
}

func runStatsCard(path: String) -> Int32 {
    _ = NSApplication.shared
    let stats = TypingStats()
    let summary = stats.summary()
    let data: Data? = MainActor.assumeIsolated {
        ShareCard.render(summary: summary, labels: KeyboardLayout.labels()).flatMap(ShareCard.pngData)
    }
    guard let png = data else {
        stderrLine("stats-card: rendering failed")
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        stderrLine("stats-card: \(error.localizedDescription)")
        return 1
    }
    print("stats-card: wrote \(path) (\(png.count) bytes)")
    return 0
}

/// Posts synthetic F20 keystrokes through the real tap and drain, counts
/// them into a temporary stats file, reloads it and checks the numbers.
func runStatsSelftest(count: Int) -> Int32 {
    guard ensureListenPermission(), ensurePostPermission() else { return 2 }
    guard let keys = SyntheticKeys() else { return 3 }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("thock-stats-selftest-\(getpid()).json")
    try? FileManager.default.removeItem(at: file)
    let stats = TypingStats(fileURL: file, countSynthetic: true)

    let ring = EventRing()
    let tap = KeyTap(ring: ring)
    let drain = Drain(ring: ring) { stats.record($0) }
    do { try tap.start() } catch {
        stderrLine("selftest-stats: tap failed: \(error)")
        return 3
    }
    drain.start()
    usleep(300_000)
    keys.burst(count, spacingMicros: 50_000)
    usleep(400_000)
    drain.stop()
    tap.stop()
    stats.flush()

    let before = stats.summary()
    let reloaded = TypingStats(fileURL: file, countSynthetic: true).summary()
    let fileBytes = (try? Data(contentsOf: file))?.count ?? 0
    try? FileManager.default.removeItem(at: file)

    print("selftest-stats: keys=\(before.today.keys)/\(count) f20=\(before.today.perKey[90]) peak_kpm=\(before.today.peakKPM) "
        + "active_min=\(before.today.activeMinuteCount) file_bytes=\(fileBytes) reloaded_keys=\(reloaded.today.keys)")
    var failures: [String] = []
    if before.today.keys != count { failures.append("counted \(before.today.keys) keys, expected \(count)") }
    if before.today.perKey[90] != count { failures.append("F20 slot \(before.today.perKey[90]), expected \(count)") }
    if before.today.peakKPM != count { failures.append("peak per minute \(before.today.peakKPM), expected \(count)") }
    if before.today.activeMinuteCount < 1 { failures.append("no active minute recorded") }
    if reloaded.today != before.today { failures.append("reloaded day differs from saved day") }
    if failures.isEmpty {
        print("selftest-stats: PASS")
        return 0
    }
    failures.forEach { print("selftest-stats: FAIL — \($0)") }
    return 1
}
