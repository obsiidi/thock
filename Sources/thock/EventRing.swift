import CAtomics

/// One captured keyboard event. Plain data only: no references, so writing
/// it into the ring never allocates.
struct KeyEvent {
    enum Kind: UInt8 {
        case keyDown = 0
        case keyUp = 1
        case flagsChanged = 2
    }

    var kind: Kind = .keyDown
    var autorepeat: UInt8 = 0
    var synthetic: UInt8 = 0
    var keyCode: UInt16 = 0
    var flags: UInt64 = 0
    /// CGEvent.timestamp as delivered by the system.
    var timestamp: UInt64 = 0
    /// mach_absolute_time() at callback entry (raw ticks, converted later).
    var received: UInt64 = 0
    /// Monotonic per-tap counter, assigned by the producer.
    var seq: UInt64 = 0
    /// mach_absolute_time() right after scheduleBuffer returned; 0 = not scheduled.
    var scheduled: UInt64 = 0
    /// Voice-pool slot that played this event.
    var voice: UInt8 = 0
    /// Playback rate applied to that voice (pitch jitter).
    var rate: Float = 1
    /// 1 = key went down (incl. modifier press), 0 = key went up.
    var pressed: UInt8 = 0
    /// Mechvibes key code from the scancode table, -1 if unmapped.
    var scan: Int32 = -1
    /// Sample index that was triggered, -1 if nothing was played.
    var sample: Int32 = -1
    /// Keystroke force 0…1 from the accelerometer (1 without sensor).
    var force: Float = 1
    /// Gain applied to the voice, in dB.
    var gainDb: Float = 0
    /// 1 if `force` came from a real sensor reading (not neutral/fixed).
    var forceMeasured: UInt8 = 0
}

/// Single-producer / single-consumer ring buffer with fixed capacity.
///
/// Producer: the event-tap thread (`push`). Consumer: the drain thread (`pop`).
/// Neither side blocks or allocates after `init`. When the ring is full the
/// event is dropped and counted; the consumer can read `droppedCount`.
final class EventRing {
    let capacity: Int
    private let mask: UInt64
    private let slots: UnsafeMutablePointer<KeyEvent>
    // Each counter lives on its own cache line to avoid false sharing.
    private let head: UnsafeMutablePointer<UInt64>   // next write index, producer-owned
    private let tail: UnsafeMutablePointer<UInt64>   // next read index, consumer-owned
    private let drops: UnsafeMutablePointer<UInt64>  // producer-written, consumer-read

    init(capacityLog2: Int = 12) {
        capacity = 1 << capacityLog2
        mask = UInt64(capacity - 1)
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: KeyEvent(), count: capacity)
        head = EventRing.allocateCounter()
        tail = EventRing.allocateCounter()
        drops = EventRing.allocateCounter()
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        UnsafeMutableRawPointer(head).deallocate()
        UnsafeMutableRawPointer(tail).deallocate()
        UnsafeMutableRawPointer(drops).deallocate()
    }

    private static func allocateCounter() -> UnsafeMutablePointer<UInt64> {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 128)
        let p = raw.bindMemory(to: UInt64.self, capacity: 1)
        p.initialize(to: 0)
        return p
    }

    /// Producer side. Real-time safe: no allocation, no locks.
    @inline(__always)
    func push(_ event: KeyEvent) -> Bool {
        let h = catomic_load_relaxed(head)
        let t = catomic_load_acquire(tail)
        if h &- t >= UInt64(capacity) {
            catomic_store_release(drops, catomic_load_relaxed(drops) &+ 1)
            return false
        }
        slots[Int(h & mask)] = event
        catomic_store_release(head, h &+ 1)
        return true
    }

    /// Consumer side. Returns nil when the ring is empty.
    func pop() -> KeyEvent? {
        let t = catomic_load_relaxed(tail)
        let h = catomic_load_acquire(head)
        if t == h { return nil }
        let event = slots[Int(t & mask)]
        catomic_store_release(tail, t &+ 1)
        return event
    }

    var droppedCount: UInt64 {
        catomic_load_acquire(drops)
    }
}
