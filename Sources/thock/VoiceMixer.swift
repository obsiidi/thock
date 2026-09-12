import AVFoundation
import CAtomics

/// A trigger command from the trigger thread to the render block. The render
/// block echoes it into `VoiceMixer.startLog` with `started` filled in.
struct VoiceCommand {
    var sample: Int32 = 0      // index into the sample table
    var rate: Float = 1        // playback rate (pitch)
    var gain: Float = 1
    var issued: UInt64 = 0     // mach ticks when the trigger thread pushed it
    var started: UInt64 = 0    // host time of the render cycle that started it
}

/// Fixed-size SPSC ring of VoiceCommand. Never blocks, never allocates.
final class CommandRing {
    private let capacity: Int
    private let mask: UInt64
    private let slots: UnsafeMutablePointer<VoiceCommand>
    private let head: UnsafeMutablePointer<UInt64>
    private let tail: UnsafeMutablePointer<UInt64>

    init(capacityLog2: Int = 8) {
        capacity = 1 << capacityLog2
        mask = UInt64(capacity - 1)
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: VoiceCommand(), count: capacity)
        head = .allocate(capacity: 16)   // padded: own cache line
        head.initialize(repeating: 0, count: 16)
        tail = .allocate(capacity: 16)
        tail.initialize(repeating: 0, count: 16)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        head.deallocate()
        tail.deallocate()
    }

    @inline(__always)
    func push(_ c: VoiceCommand) -> Bool {
        let h = catomic_load_relaxed(head)
        let t = catomic_load_acquire(tail)
        if h &- t >= UInt64(capacity) { return false }
        slots[Int(h & mask)] = c
        catomic_store_release(head, h &+ 1)
        return true
    }

    @inline(__always)
    func pop(into c: UnsafeMutablePointer<VoiceCommand>) -> Bool {
        let t = catomic_load_relaxed(tail)
        let h = catomic_load_acquire(head)
        if t == h { return false }
        c.pointee = slots[Int(t & mask)]
        catomic_store_release(tail, t &+ 1)
        return true
    }

    /// Consumer-side convenience for diagnostics threads.
    func pop() -> VoiceCommand? {
        var c = VoiceCommand()
        return pop(into: &c) ? c : nil
    }
}

/// One decoded sample as raw channel pointers. The memory is owned by the
/// AVAudioPCMBuffer kept alive in `VoiceMixer.buffers`.
struct SampleRef {
    var left: UnsafePointer<Float>?
    var right: UnsafePointer<Float>?
    var frames: Int = 0
}

struct VoiceState {
    var active = false
    var sample: Int32 = 0
    var position: Float = 0    // fractional read position in frames
    var rate: Float = 1
    var gain: Float = 1
}

/// Polyphonic one-shot sample player inside a single AVAudioSourceNode.
///
/// Why not AVAudioPlayerNode: its scheduleBuffer path showed sporadic
/// 20–30 ms start delays regardless of buffer size (measured in Phase 2).
/// Here the trigger thread pushes a command into a lock-free ring and the
/// render block starts the voice on its next cycle — worst case one IO
/// buffer of latency, deterministic.
///
/// Render block rules: no allocation, no locks, no ObjC/Swift runtime calls
/// beyond pointer arithmetic. Voice state and the sample table are fixed
/// arrays behind raw pointers; pitch is linear-interpolated resampling.
final class VoiceMixer {
    static let voiceCount = 16
    static let maxSamples = 512

    let commands = CommandRing()
    /// Every started command, with `started` set. Drained by diagnostics;
    /// overflow is harmless (entries are dropped, playback unaffected).
    let startLog = CommandRing(capacityLog2: 10)

    private(set) var node: AVAudioSourceNode!
    private let voices: UnsafeMutablePointer<VoiceState>
    private let samples: UnsafeMutablePointer<SampleRef>
    private var buffers: [AVAudioPCMBuffer] = []     // keeps sample memory alive
    private var nextVoice = 0                        // render thread only
    private let startedCount: UnsafeMutablePointer<UInt64>
    private let droppedCommands: UnsafeMutablePointer<UInt64>
    private let scratch: UnsafeMutablePointer<VoiceCommand>

    init(format: AVAudioFormat) {
        voices = .allocate(capacity: VoiceMixer.voiceCount)
        voices.initialize(repeating: VoiceState(), count: VoiceMixer.voiceCount)
        samples = .allocate(capacity: VoiceMixer.maxSamples)
        samples.initialize(repeating: SampleRef(), count: VoiceMixer.maxSamples)
        startedCount = .allocate(capacity: 1)
        startedCount.initialize(to: 0)
        droppedCommands = .allocate(capacity: 1)
        droppedCommands.initialize(to: 0)
        scratch = .allocate(capacity: 1)
        scratch.initialize(to: VoiceCommand())
        node = AVAudioSourceNode(format: format) { [unowned self] isSilence, timestamp, frameCount, audioBufferList in
            self.render(isSilence: isSilence, timestamp: timestamp, frameCount: Int(frameCount), abl: audioBufferList)
        }
    }

    deinit {
        voices.deallocate()
        samples.deallocate()
        startedCount.deallocate()
        droppedCommands.deallocate()
        scratch.deallocate()
    }

    /// Voices the render block has started so far.
    var voicesStarted: UInt64 { catomic_load_acquire(startedCount) }
    /// Trigger commands lost because the command ring was full.
    var commandsDropped: UInt64 { catomic_load_acquire(droppedCommands) }
    var sampleCount: Int { buffers.count }

    /// Decoded buffer for a sample index (diagnostics; not for the render thread).
    func buffer(at index: Int32) -> AVAudioPCMBuffer? {
        index >= 0 && Int(index) < buffers.count ? buffers[Int(index)] : nil
    }

    /// Registers a decoded buffer (must be in the mixer's format, float32
    /// non-interleaved). Call before the engine starts. Returns the index.
    func register(_ buffer: AVAudioPCMBuffer) -> Int32 {
        precondition(buffers.count < VoiceMixer.maxSamples, "sample table full")
        guard let data = buffer.floatChannelData, buffer.frameLength > 1 else { return -1 }
        let index = buffers.count
        buffers.append(buffer)
        var ref = SampleRef()
        ref.frames = Int(buffer.frameLength)
        ref.left = UnsafePointer(data[0])
        ref.right = buffer.format.channelCount > 1 ? UnsafePointer(data[1]) : UnsafePointer(data[0])
        samples[index] = ref
        return Int32(index)
    }

    /// Trigger thread. Returns false if the command ring is full.
    @inline(__always)
    func trigger(sample: Int32, rate: Float, gain: Float = 1) -> Bool {
        var c = VoiceCommand()
        c.sample = sample
        c.rate = rate
        c.gain = gain
        c.issued = mach_absolute_time()
        if commands.push(c) {
            return true
        }
        catomic_store_release(droppedCommands, catomic_load_relaxed(droppedCommands) &+ 1)
        return false
    }

    // MARK: render thread

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                        frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        guard out.count > 0, let left = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let right = out.count > 1 ? out[1].mData?.assumingMemoryBound(to: Float.self) : nil
        left.update(repeating: 0, count: frameCount)
        right?.update(repeating: 0, count: frameCount)

        // Start a voice for every pending command.
        let cycleTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
            ? timestamp.pointee.mHostTime : mach_absolute_time()
        var started: UInt64 = 0
        while commands.pop(into: scratch) {
            let index = Int(scratch.pointee.sample)
            if index < 0 || index >= VoiceMixer.maxSamples || samples[index].frames < 2 {
                continue
            }
            let v = nextVoice
            nextVoice = (v + 1) & (VoiceMixer.voiceCount - 1)
            voices[v].active = true
            voices[v].sample = scratch.pointee.sample
            voices[v].position = 0
            voices[v].rate = scratch.pointee.rate
            voices[v].gain = scratch.pointee.gain
            scratch.pointee.started = cycleTime
            _ = startLog.push(scratch.pointee)
            started &+= 1
        }
        if started != 0 {
            catomic_store_release(startedCount, catomic_load_relaxed(startedCount) &+ started)
        }

        var anyActive = false
        for v in 0..<VoiceMixer.voiceCount where voices[v].active {
            let s = samples[Int(voices[v].sample)]
            guard let srcL = s.left, let srcR = s.right else {
                voices[v].active = false
                continue
            }
            var pos = voices[v].position
            let rate = voices[v].rate
            let gain = voices[v].gain
            let last = Float(s.frames - 1)
            var i = 0
            while i < frameCount && pos < last {
                let idx = Int(pos)
                let frac = pos - Float(idx)
                left[i] += (srcL[idx] + (srcL[idx + 1] - srcL[idx]) * frac) * gain
                if let r = right {
                    r[i] += (srcR[idx] + (srcR[idx + 1] - srcR[idx]) * frac) * gain
                }
                pos += rate
                i += 1
            }
            voices[v].position = pos
            if pos >= last {
                voices[v].active = false
            } else {
                anyActive = true
            }
        }
        isSilence.pointee = ObjCBool(!anyActive)
        return noErr
    }
}
