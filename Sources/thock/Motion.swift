import Foundation
import IOKit
import IOKit.hid
import CAtomics

/// One accelerometer sample after baseline removal.
struct MotionSample {
    var ticks: UInt64 = 0      // mach_absolute_time at delivery
    var impact: Float = 0      // |a - baseline| in g
}

/// Broadcast ring for sensor samples: the HID thread writes, the trigger
/// thread scans the most recent window by time. No pop; the consumer reads
/// backwards from `head`. Capacity 4096 ≈ 5 s at 800 Hz.
final class MotionRing {
    static let capacityLog2 = 12
    let capacity = 1 << capacityLog2
    private let mask = UInt64((1 << capacityLog2) - 1)
    private let slots: UnsafeMutablePointer<MotionSample>
    private let head: UnsafeMutablePointer<UInt64>

    init() {
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: MotionSample(), count: capacity)
        head = .allocate(capacity: 16)
        head.initialize(repeating: 0, count: 16)
    }

    deinit {
        slots.deallocate()
        head.deallocate()
    }

    @inline(__always)
    func push(_ s: MotionSample) {
        let h = catomic_load_relaxed(head)
        slots[Int(h & mask)] = s
        catomic_store_release(head, h &+ 1)
    }

    var count: UInt64 { catomic_load_acquire(head) }

    /// Max impact of samples with ticks in [from, to]. Scans back from the
    /// newest sample; stops at the first older than `from`.
    func peak(from: UInt64, to: UInt64) -> Float {
        let h = catomic_load_acquire(head)
        var best: Float = 0
        var i = h
        let oldest = h > UInt64(capacity) ? h - UInt64(capacity) + 64 : 0
        while i > oldest {
            i -= 1
            let s = slots[Int(i & mask)]
            if s.ticks < from { break }
            if s.ticks <= to && s.impact > best { best = s.impact }
        }
        return best
    }

    /// Ticks of the newest sample, 0 if none.
    var newestTicks: UInt64 {
        let h = catomic_load_acquire(head)
        return h == 0 ? 0 : slots[Int((h - 1) & mask)].ticks
    }
}

/// The MacBook's chassis accelerometer (Bosch IMU behind the SPU), exposed as
/// an `AppleSPUHIDDevice` on vendor usage page 0xFF00, usage 3. Present on
/// M1 Pro/Max and M2 or later MacBooks; absent on M1 Air / 13" M1 Pro,
/// desktops and Intel. Access needs Input Monitoring — no root.
///
/// Reports: 22 bytes, u16 sequence at 0, x/y/z as IOFixed 16.16 at 6/10/14,
/// die temperature at 18. Native rate ~800 Hz once the driver is woken.
final class MotionSensor {
    enum Failure: Error {
        case noSensor
        case openFailed(IOReturn)
    }

    static let reportLength = 22
    static let nativeIntervalUs = 1000

    let ring = MotionRing()
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var startFailure: Failure?
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    // HID-thread state
    private var baseline: (Float, Float, Float) = (0, 0, -1)
    private var baselinePrimed = false
    private var lastSeq: UInt16 = 0
    private var haveSeq = false
    // counters (HID-thread written)
    private let reports: UnsafeMutablePointer<UInt64>
    private let gaps: UnsafeMutablePointer<UInt64>
    private let noiseBits: UnsafeMutablePointer<UInt64>   // Float bits of the EMA impact floor

    init() {
        reportBuffer = .allocate(capacity: 64)
        reportBuffer.initialize(repeating: 0, count: 64)
        reports = .allocate(capacity: 1)
        reports.initialize(to: 0)
        gaps = .allocate(capacity: 1)
        gaps.initialize(to: 0)
        noiseBits = .allocate(capacity: 1)
        noiseBits.initialize(to: 0)
    }

    deinit {
        reportBuffer.deallocate()
        reports.deallocate()
        gaps.deallocate()
        noiseBits.deallocate()
    }

    var reportCount: UInt64 { catomic_load_acquire(reports) }
    var gapCount: UInt64 { catomic_load_acquire(gaps) }
    /// Running noise floor of the impact signal in g (EMA).
    var noiseFloor: Float { Float(bitPattern: UInt32(truncatingIfNeeded: catomic_load_acquire(noiseBits))) }

    /// True when a 22-byte accelerometer device exists (no permission needed).
    static func isAvailable() -> Bool {
        findDevice() != nil
    }

    private static func findDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey as String: 0xFF00,
            kIOHIDPrimaryUsageKey as String: 3,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        // Some Macs expose two devices for usage 3; the 22-byte one is the sensor.
        return devices.first {
            (IOHIDDeviceGetProperty($0, kIOHIDMaxInputReportSizeKey as CFString) as? Int) == reportLength
        }
    }

    /// Power and reporting state live on the AppleSPUHIDDriver services, not
    /// on the HID device: set there, before opening, or no report ever arrives.
    private static func setDriverProperties(reportingState: Int?, powerState: Int?, intervalUs: Int) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else {
            return
        }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let r = reportingState {
                IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, r as CFNumber)
            }
            if let p = powerState {
                IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, p as CFNumber)
            }
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, intervalUs as CFNumber)
            IOObjectRelease(service)
        }
        IOObjectRelease(iterator)
    }

    func start() throws {
        let t = Thread { [unowned self] in self.threadMain() }
        t.name = "thock.motion"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let f = startFailure { throw f }
    }

    func stop() {
        if let rl = runLoop {
            CFRunLoopStop(rl)
        }
        if let d = device {
            IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            device = nil
        }
        // The report interval is left at the native rate on purpose: another
        // thock process (app + diagnostics) may still be listening.
    }

    private func threadMain() {
        MotionSensor.setDriverProperties(reportingState: 1, powerState: 1, intervalUs: MotionSensor.nativeIntervalUs)
        guard let d = MotionSensor.findDevice() else {
            startFailure = .noSensor
            ready.signal()
            return
        }
        let status = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            startFailure = .openFailed(status)
            ready.signal()
            return
        }
        device = d
        IOHIDDeviceRegisterInputReportCallback(d, reportBuffer, 64, motionReportCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        let rl = CFRunLoopGetCurrent()!
        IOHIDDeviceScheduleWithRunLoop(d, rl, CFRunLoopMode.defaultMode.rawValue)
        runLoop = rl
        ready.signal()
        CFRunLoopRun()
    }

    /// HID thread. Real-time rules: parse, filter, push. No allocation.
    fileprivate func handle(report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length == MotionSensor.reportLength else { return }
        let now = mach_absolute_time()
        let seq = UInt16(report[0]) | UInt16(report[1]) << 8
        if haveSeq && seq &- lastSeq != 1 {
            catomic_store_release(gaps, catomic_load_relaxed(gaps) &+ 1)
        }
        lastSeq = seq
        haveSeq = true

        @inline(__always) func fixed(_ o: Int) -> Float {
            let raw = UInt32(report[o]) | UInt32(report[o + 1]) << 8 | UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24
            return Float(Int32(bitPattern: raw)) / 65536
        }
        let x = fixed(6), y = fixed(10), z = fixed(14)

        // Gravity/orientation baseline: slow EMA (~1 s at 800 Hz).
        if !baselinePrimed {
            baseline = (x, y, z)
            baselinePrimed = true
        } else {
            let a: Float = 1.0 / 800.0
            baseline.0 += (x - baseline.0) * a
            baseline.1 += (y - baseline.1) * a
            baseline.2 += (z - baseline.2) * a
        }
        let dx = x - baseline.0, dy = y - baseline.1, dz = z - baseline.2
        let impact = (dx * dx + dy * dy + dz * dz).squareRoot()

        // Noise floor: fast EMA of the impact, only follows downwards quickly.
        let floorNow = noiseFloor
        let floorNext = impact < floorNow ? floorNow + (impact - floorNow) * 0.05 : floorNow + (impact - floorNow) * 0.002
        catomic_store_release(noiseBits, UInt64(floorNext.bitPattern))

        ring.push(MotionSample(ticks: now, impact: impact))
        catomic_store_release(reports, catomic_load_relaxed(reports) &+ 1)
    }
}

private func motionReportCallback(
    context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex
) {
    guard let context = context else { return }
    Unmanaged<MotionSensor>.fromOpaque(context).takeUnretainedValue().handle(report: report, length: Int(length))
}

/// Turns a keystroke's chassis impact into a force 0…1 and the sound
/// parameters derived from it. Trigger thread only, except the atomic knobs.
final class VelocityEstimator {
    /// Window around the key event, in ns. The impact reaches the sensor
    /// about as fast as the key event reaches us, so most of the peak is
    /// already in the ring; the post window catches what arrived since.
    var preWindowNs: UInt64 = 15_000_000
    var postWindowNs: UInt64 = 5_000_000
    /// Decay of the running maximum: halves every `halfLifeSeconds`.
    var halfLifeSeconds: Double = 60
    private var runningMax: Float = 0.02        // g; sane start for a light typist
    /// Whether the last `force` call was backed by a sensor reading.
    private(set) var lastMeasured = false
    private var lastUpdateTicks: UInt64 = 0
    private let sensitivityBits: UnsafeMutablePointer<UInt64>
    private let enabledFlag: UnsafeMutablePointer<UInt64>
    let sensor: MotionSensor?

    init(sensor: MotionSensor?) {
        self.sensor = sensor
        sensitivityBits = .allocate(capacity: 1)
        sensitivityBits.initialize(to: UInt64(Float(1).bitPattern))
        enabledFlag = .allocate(capacity: 1)
        enabledFlag.initialize(to: sensor == nil ? 0 : 1)
    }

    deinit {
        sensitivityBits.deallocate()
        enabledFlag.deallocate()
    }

    /// 0.3 (needs a slam for full volume) … 3 (light taps already loud). 1 = auto.
    var sensitivity: Float {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: catomic_load_acquire(sensitivityBits))) }
        set { catomic_store_release(sensitivityBits, UInt64(newValue.bitPattern)) }
    }

    var enabled: Bool {
        get { catomic_load_acquire(enabledFlag) != 0 }
        set { catomic_store_release(enabledFlag, newValue && sensor != nil ? 1 : 0) }
    }

    /// Peak impact around an event, in g. 0 without sensor.
    @inline(__always)
    func peak(eventNanos: UInt64) -> Float {
        guard let sensor = sensor else { return 0 }
        let t = Clock.nanosToTicks(eventNanos)
        return sensor.ring.peak(from: t &- Clock.nanosToTicks(preWindowNs), to: t &+ Clock.nanosToTicks(postWindowNs))
    }

    /// Force 0…1 for an event. Updates the running maximum.
    @inline(__always)
    func force(eventNanos: UInt64, nowTicks: UInt64) -> Float {
        lastMeasured = false
        guard enabled, let sensor = sensor else { return 1 }
        let raw = peak(eventNanos: eventNanos)
        let floor = sensor.noiseFloor * 2
        let signal = max(0, raw - floor)
        // Nothing above the noise floor: external keyboard or synthetic
        // event — no impact information, play at a neutral level.
        if signal <= 0 { return 0.5 }
        lastMeasured = true
        // Decay the running max toward the floor, then let this hit raise it.
        if lastUpdateTicks != 0 {
            let dt = Double(Clock.ticksToNanos(nowTicks &- lastUpdateTicks)) / 1e9
            let decay = Float(pow(0.5, dt / halfLifeSeconds))
            runningMax = max(0.005, runningMax * decay)
        }
        lastUpdateTicks = nowTicks
        if signal > runningMax { runningMax = signal }
        let f = signal / (runningMax * 0.8) * sensitivity
        return min(1, max(0, f))
    }

    /// Gain in dB for a force: -15 dB for the lightest touch, 0 dB for a slam.
    @inline(__always)
    static func gainDb(force: Float) -> Float {
        -15 * (1 - pow(force, 0.7))
    }

    /// Low-pass cutoff in Hz: soft hits are duller.
    @inline(__always)
    static func cutoffHz(force: Float) -> Float {
        1500 + 18_500 * pow(force, 0.8)
    }

    /// Extra playback-rate factor: a touch lower for soft hits.
    @inline(__always)
    static func rateFactor(force: Float) -> Float {
        1 + (force - 0.5) * 0.03
    }
}
