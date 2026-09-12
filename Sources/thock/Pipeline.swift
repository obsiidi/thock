import Foundation
import CAtomics

/// Wires the tap to the audio engine and the log:
///
///   tap thread ──► tapRing ──► trigger thread ──► logRing ──► drain/log
///
/// The trigger thread is the only place that talks to AVAudioPlayerNode, so
/// the tap callback stays free of Apple's locks and allocations.
final class Pipeline {
    let tapRing = EventRing()
    let logRing = EventRing()
    let tap: KeyTap
    let audio: AudioEngine?
    /// Whether auto-repeated keyDowns trigger a click. Off: a held key is
    /// one keystroke, like on a real keyboard.
    var clickOnRepeat = false
    /// Pitch jitter: rate = 1 ± jitter.
    var jitter: Float = 0.03

    private var thread: Thread?
    private let stopFlag: UnsafeMutablePointer<UInt64>
    private let triggered: UnsafeMutablePointer<UInt64>
    private let finished = DispatchSemaphore(value: 0)
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15   // trigger thread only
    private var nextVoice = 0                          // mirrors the render block's round-robin

    init(audio: AudioEngine?) {
        self.audio = audio
        tap = KeyTap(ring: tapRing)
        stopFlag = .allocate(capacity: 1)
        stopFlag.initialize(to: 0)
        triggered = .allocate(capacity: 1)
        triggered.initialize(to: 0)
    }

    deinit {
        stopFlag.deallocate()
        triggered.deallocate()
    }

    /// Number of clicks handed to the audio engine.
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

    private func loop() {
        while catomic_load_acquire(stopFlag) == 0 {
            tap.wake.wait()
            while var e = tapRing.pop() {
                if e.kind == .keyDown && (e.autorepeat == 0 || clickOnRepeat) {
                    let rate = 1 + nextUnit() * jitter
                    if audio?.trigger(rate: rate) ?? true {
                        e.voice = UInt8(nextVoice)
                        nextVoice = (nextVoice + 1) & (VoiceMixer.voiceCount - 1)
                    }
                    e.scheduled = mach_absolute_time()
                    e.rate = rate
                    catomic_store_release(triggered, catomic_load_relaxed(triggered) &+ 1)
                }
                _ = logRing.push(e)
            }
        }
        finished.signal()
    }
}
