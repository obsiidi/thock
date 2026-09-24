import Foundation
import CAtomics

/// Wires the tap to the audio engine and the log:
///
///   tap thread ──► tapRing ──► trigger thread ──► logRing ──► drain/log
///
/// The trigger thread turns raw events into "key went down / up", looks up
/// the pack's sample for the key and queues it in the VoiceMixer. Only fixed
/// tables are touched here: no hashing, no allocation.
final class Pipeline {
    let tapRing = EventRing()
    let logRing = EventRing()
    let tap: KeyTap
    let audio: AudioEngine?
    let pack: Soundpack?
    let velocity: VelocityEstimator
    /// Whether auto-repeated keyDowns trigger a sound. Off: a held key is
    /// one keystroke, like on a real keyboard.
    var clickOnRepeat = false
    /// Pitch jitter: rate = 1 ± jitter.
    var jitter: Float = 0.03
    private let keyUpFlag: UnsafeMutablePointer<UInt64>
    private let mutedFlag: UnsafeMutablePointer<UInt64>
    private let pointerFlag: UnsafeMutablePointer<UInt64>
    private let scrollFlag: UnsafeMutablePointer<UInt64>
    /// Click sounds for trackpad and mouse buttons.
    var pointerSounds: Bool {
        get { catomic_load_acquire(pointerFlag) != 0 }
        set { catomic_store_release(pointerFlag, newValue ? 1 : 0) }
    }
    /// Detent-like ticks while scrolling.
    var scrollTicks: Bool {
        get { catomic_load_acquire(scrollFlag) != 0 }
        set { catomic_store_release(scrollFlag, newValue ? 1 : 0) }
    }
    /// Points of continuous scrolling per tick, and the shortest gap between ticks.
    static let scrollStep: Float = 28
    static let minTickGapNs: UInt64 = 30_000_000
    // trigger-thread scroll state
    private var scrollAcc: Float = 0
    private var lastScrollNs: UInt64 = 0
    private var lastTickNs: UInt64 = 0
    /// Muted: events are still captured and logged, nothing is played.
    var muted: Bool {
        get { catomic_load_acquire(mutedFlag) != 0 }
        set { catomic_store_release(mutedFlag, newValue ? 1 : 0) }
    }
    /// Whether key-release sounds play (packs with "-up" defines / soundup).
    var keyUpSounds: Bool {
        get { catomic_load_acquire(keyUpFlag) != 0 }
        set { catomic_store_release(keyUpFlag, newValue ? 1 : 0) }
    }

    private var thread: Thread?
    private let stopFlag: UnsafeMutablePointer<UInt64>
    private let triggered: UnsafeMutablePointer<UInt64>
    private let finished = DispatchSemaphore(value: 0)
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15   // trigger thread only
    private var nextVoice = 0                          // mirrors the render block's round-robin
    private let scan: UnsafeMutablePointer<Int32>      // CGKeyCode -> Mechvibes code
    private let modState: UnsafeMutablePointer<UInt8>  // modifier key currently held?
    private var lastFlags: UInt64 = 0

    init(audio: AudioEngine?, pack: Soundpack?, motion: MotionSensor? = nil) {
        self.audio = audio
        self.pack = pack
        velocity = VelocityEstimator(sensor: motion)
        tap = KeyTap(ring: tapRing)
        stopFlag = .allocate(capacity: 1)
        stopFlag.initialize(to: 0)
        triggered = .allocate(capacity: 1)
        triggered.initialize(to: 0)
        scan = .allocate(capacity: 128)
        for k in 0..<128 { scan[k] = Scancodes.table[k] }
        modState = .allocate(capacity: 128)
        modState.initialize(repeating: 0, count: 128)
        keyUpFlag = .allocate(capacity: 1)
        keyUpFlag.initialize(to: 1)
        mutedFlag = .allocate(capacity: 1)
        mutedFlag.initialize(to: 0)
        pointerFlag = .allocate(capacity: 1)
        pointerFlag.initialize(to: 1)
        scrollFlag = .allocate(capacity: 1)
        scrollFlag.initialize(to: 0)
    }

    deinit {
        stopFlag.deallocate()
        triggered.deallocate()
        scan.deallocate()
        modState.deallocate()
        keyUpFlag.deallocate()
        mutedFlag.deallocate()
        pointerFlag.deallocate()
        scrollFlag.deallocate()
    }

    /// Number of sounds handed to the audio engine.
    var triggerCount: UInt64 {
        catomic_load_acquire(triggered)
    }

    func start() throws {
        try tap.start()
        let t = Thread { [unowned self] in self.loop() }
        t.name = "thock.trigger"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        tap.stop()
        catomic_store_release(stopFlag, 1)
        tap.wake.signal()
        finished.wait()
    }

    /// xorshift64*: uniform in [-1, 1). No allocation.
    @inline(__always)
    private func nextUnit() -> Float {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let v = rng &* 2_685_821_657_736_338_717
        return Float(v >> 40) / Float(1 << 24) * 2 - 1
    }

    /// CGEventFlags bit for a modifier key code, 0 if none.
    @inline(__always)
    private func modifierBit(_ keyCode: Int) -> UInt64 {
        switch keyCode {
        case 56, 60: return 1 << 17          // shift
        case 59, 62: return 1 << 18          // control
        case 58, 61: return 1 << 19          // option
        case 55, 54: return 1 << 20          // command
        case 57: return 1 << 16              // caps lock
        case 63: return 1 << 23              // fn
        default: return 0
        }
    }

    /// flagsChanged carries no down/up; derive it from the flag bit and the
    /// per-key state (both shifts held, one released: bit stays set).
    /// Caps lock reports the lock state, so a changed bit means "pressed".
    @inline(__always)
    private func modifierPressed(_ e: KeyEvent) -> UInt8 {
        let k = Int(e.keyCode & 127)
        let bit = modifierBit(k)
        defer { lastFlags = e.flags }
        if k == 57 {
            return (e.flags & bit) != (lastFlags & bit) ? 1 : 0
        }
        if modState[k] == 0 {
            if bit == 0 || (e.flags & bit) != 0 {
                modState[k] = 1
                return 1
            }
            return 0
        }
        modState[k] = 0
        return 0
    }

    /// Trackpad / mouse clicks and scroll ticks. Trigger thread, no allocation.
    private func handlePointer(_ e: inout KeyEvent) {
        guard let audio = audio, let mouse = audio.mouse, catomic_load_acquire(mutedFlag) == 0 else { return }
        switch e.kind {
        case .pointerDown, .pointerUp:
            guard catomic_load_acquire(pointerFlag) != 0 else { return }
            let down = e.kind == .pointerDown
            e.pressed = down ? 1 : 0
            // Force Touch trackpads report the click pressure; mice report 1.
            let force = min(1, max(0, e.pressure))
            let gainDb: Float = down ? -6 * (1 - force) : -3
            trigger(&e, sample: down ? mouse.down : mouse.up, gainDb: gainDb)
        case .scroll:
            guard catomic_load_acquire(scrollFlag) != 0 else { return }
            let now = Clock.ticksToNanos(mach_absolute_time())
            if e.scrollPhase == 1 || now &- lastScrollNs > 300_000_000 { scrollAcc = 0 }
            lastScrollNs = now
            var tick = false
            if e.continuous == 0 {
                tick = e.scrollDelta > 0          // one tick per wheel detent
            } else {
                scrollAcc += e.scrollDelta
                if scrollAcc >= Pipeline.scrollStep {
                    scrollAcc -= Pipeline.scrollStep
                    if scrollAcc > Pipeline.scrollStep { scrollAcc = 0 }   // fast flicks: don't queue a burst
                    tick = true
                }
            }
            guard tick, now &- lastTickNs >= Pipeline.minTickGapNs else { return }
            lastTickNs = now
            trigger(&e, sample: mouse.tick, gainDb: e.momentum != 0 ? -7 : -2)
        default:
            return
        }
    }

    @inline(__always)
    private func trigger(_ e: inout KeyEvent, sample: Int32, gainDb: Float) {
        let rate = 1 + nextUnit() * jitter
        if audio?.trigger(sample: sample, rate: rate, gain: powf(10, gainDb / 20)) ?? false {
            e.voice = UInt8(nextVoice)
            nextVoice = (nextVoice + 1) & (VoiceMixer.voiceCount - 1)
        }
        e.sample = sample
        e.rate = rate
        e.gainDb = gainDb
        e.scheduled = mach_absolute_time()
        catomic_store_release(triggered, catomic_load_relaxed(triggered) &+ 1)
    }

    private func loop() {
        while catomic_load_acquire(stopFlag) == 0 {
            tap.wake.wait()
            while var e = tapRing.pop() {
                if e.kind == .pointerDown || e.kind == .pointerUp || e.kind == .scroll {
                    handlePointer(&e)
                    _ = logRing.push(e)
                    continue
                }
                let k = Int(e.keyCode & 127)
                e.scan = scan[k]
                var play = false
                switch e.kind {
                case .keyDown:
                    e.pressed = 1
                    play = e.autorepeat == 0 || clickOnRepeat
                case .keyUp:
                    e.pressed = 0
                    play = true
                case .flagsChanged:
                    e.pressed = modifierPressed(e)
                    play = true
                case .pointerDown, .pointerUp, .scroll:
                    break
                }
                if play, e.pressed == 0, catomic_load_acquire(keyUpFlag) == 0 {
                    play = false
                }
                if play, catomic_load_acquire(mutedFlag) != 0 {
                    play = false
                }
                if play, let pack = pack {
                    let sample = e.pressed == 1 ? pack.keyDown[k] : pack.keyUp[k]
                    if sample >= 0 {
                        // Key-up sounds are quieter than the press that caused them.
                        let now = mach_absolute_time()
                        let force = e.pressed == 1 ? velocity.force(eventNanos: e.timestamp, nowTicks: now) : 0.5
                        let velocityOn = velocity.enabled
                        let gainDb = velocityOn ? VelocityEstimator.gainDb(force: force) : 0
                        let rate = (1 + nextUnit() * jitter) * (velocityOn ? VelocityEstimator.rateFactor(force: force) : 1)
                        var lowpass: Float = 0
                        if velocityOn, let fs = audio?.format.sampleRate {
                            let fc = VelocityEstimator.cutoffHz(force: force)
                            if fc < Float(fs) * 0.45 {
                                lowpass = Float(exp(-2 * Double.pi * Double(fc) / fs))
                            }
                        }
                        let gain = powf(10, gainDb / 20)
                        if audio?.trigger(sample: sample, rate: rate, gain: gain, lowpass: lowpass) ?? true {
                            e.voice = UInt8(nextVoice)
                            nextVoice = (nextVoice + 1) & (VoiceMixer.voiceCount - 1)
                        }
                        e.sample = sample
                        e.rate = rate
                        e.force = velocityOn ? force : 1
                        e.forceMeasured = e.pressed == 1 && velocity.lastMeasured ? 1 : 0
                        e.gainDb = gainDb
                        e.scheduled = mach_absolute_time()
                        catomic_store_release(triggered, catomic_load_relaxed(triggered) &+ 1)
                    }
                }
                _ = logRing.push(e)
            }
        }
        finished.signal()
    }
}
