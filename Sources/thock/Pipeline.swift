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
    /// Whether auto-repeated keyDowns trigger a sound. Off: a held key is
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
    private let scan: UnsafeMutablePointer<Int32>      // CGKeyCode -> Mechvibes code
    private let modState: UnsafeMutablePointer<UInt8>  // modifier key currently held?
    private var lastFlags: UInt64 = 0

    init(audio: AudioEngine?, pack: Soundpack?) {
        self.audio = audio
        self.pack = pack
        tap = KeyTap(ring: tapRing)
        stopFlag = .allocate(capacity: 1)
        stopFlag.initialize(to: 0)
        triggered = .allocate(capacity: 1)
        triggered.initialize(to: 0)
        scan = .allocate(capacity: 128)
        for k in 0..<128 { scan[k] = Scancodes.table[k] }
        modState = .allocate(capacity: 128)
        modState.initialize(repeating: 0, count: 128)
    }

    deinit {
        stopFlag.deallocate()
        triggered.deallocate()
        scan.deallocate()
        modState.deallocate()
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

    private func loop() {
        while catomic_load_acquire(stopFlag) == 0 {
            tap.wake.wait()
            while var e = tapRing.pop() {
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
                }
                if play, let pack = pack {
                    let sample = e.pressed == 1 ? pack.keyDown[k] : pack.keyUp[k]
                    if sample >= 0 {
                        let rate = 1 + nextUnit() * jitter
                        if audio?.trigger(sample: sample, rate: rate) ?? true {
                            e.voice = UInt8(nextVoice)
                            nextVoice = (nextVoice + 1) & (VoiceMixer.voiceCount - 1)
                        }
                        e.sample = sample
                        e.rate = rate
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
