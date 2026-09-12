import AVFoundation
import CoreAudio
import CAtomics

/// AVAudioEngine wrapper:
///
///   VoiceMixer (AVAudioSourceNode, 16 voices) ─► mainMixer ─► output
///
/// Samples are decoded into the hardware format once at load. The IO buffer
/// size is requested from the HAL before start; overloads are counted via
/// the device's processor-overload notification.
final class AudioEngine {
    enum Failure: Error {
        case noOutputFormat
        case bufferAllocation
        case conversion(String)
    }

    struct DeviceInfo {
        var name: String
        var sampleRate: Double
        var channels: UInt32
        var bufferFrames: UInt32
        var bufferFramesRequested: UInt32
        var presentationLatencyMs: Double
    }

    let engine = AVAudioEngine()
    let mixer: VoiceMixer
    /// Hardware sample rate, float32, non-interleaved, stereo. Matches the
    /// mixer so nothing resamples at playback time.
    let format: AVAudioFormat
    let requestedBufferFrames: UInt32

    private(set) var click: AVAudioPCMBuffer?
    private var clickIndex: Int32 = -1
    private var deviceID: AudioDeviceID = 0
    private let overloads: UnsafeMutablePointer<UInt64>
    private let overloadQueue = DispatchQueue(label: "thock.overload")
    private var overloadBlock: AudioObjectPropertyListenerBlock?
    private var overloadDevice: AudioDeviceID = 0
    private var configObserver: NSObjectProtocol?

    init(bufferFrames: UInt32) throws {
        requestedBufferFrames = bufferFrames
        // The hardware format. Do not use mainMixerNode.outputFormat here:
        // before prepare() it reports a 44.1 kHz default regardless of the
        // device, and decoding into that makes the mixer resample at runtime.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              let engineFormat = AVAudioFormat(
                standardFormatWithSampleRate: hardware.sampleRate,
                channels: min(hardware.channelCount, 2)
              ) else {
            throw Failure.noOutputFormat
        }
        format = engineFormat
        mixer = VoiceMixer(format: engineFormat)
        engine.attach(mixer.node)
        engine.connect(mixer.node, to: engine.mainMixerNode, format: engineFormat)

        overloads = .allocate(capacity: 1)
        overloads.initialize(to: 0)
    }

    deinit {
        removeOverloadListener()
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
        }
        overloads.deallocate()
    }

    /// Times the HAL reported an IO cycle overrun on the output device.
    var overloadCount: UInt64 {
        catomic_load_acquire(overloads)
    }

    func loadClick(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Failure.bufferAllocation
        }
        try file.read(into: raw)
        let decoded = try SampleConverter.convert(raw, to: format)
        click = decoded
        clickIndex = mixer.register(decoded)
    }

    var clickFrames: AVAudioFrameCount {
        click?.frameLength ?? 0
    }

    func start() throws {
        engine.prepare()
        deviceID = currentOutputDevice() ?? AudioEngine.defaultOutputDevice() ?? 0
        applyBufferFrames()
        try engine.start()
        installOverloadListener()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        removeOverloadListener()
        engine.stop()
    }

    /// Trigger thread only. Queues the click for the next render cycle.
    @inline(__always)
    func trigger(rate: Float) -> Bool {
        mixer.trigger(sample: clickIndex, rate: rate)
    }

    /// The engine stops itself when the output device changes (headphones
    /// plugged in, etc.). Re-apply the buffer size on the new device and
    /// bring it back; the mixer resamples if the rate changed.
    private func restartAfterConfigurationChange() {
        removeOverloadListener()
        engine.prepare()
        deviceID = currentOutputDevice() ?? AudioEngine.defaultOutputDevice() ?? 0
        applyBufferFrames()
        do {
            try engine.start()
            installOverloadListener()
        } catch {
            stderrLine("thock: audio restart after device change failed: \(error)")
        }
    }

    // MARK: CoreAudio HAL

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return (status == noErr && id != 0) ? id : nil
    }

    private func currentOutputDevice() -> AudioDeviceID? {
        guard let au = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size
        )
        return (status == noErr && id != 0) ? id : nil
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Clamps the requested IO buffer size to the device's range and sets
    /// it. This is a HAL client property: it affects this process's IO cycle
    /// only and is not persisted.
    private func applyBufferFrames() {
        guard deviceID != 0 else { return }
        var address = outputAddress(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var frames = requestedBufferFrames
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range) == noErr {
            frames = max(UInt32(range.mMinimum), min(UInt32(range.mMaximum), frames))
        }
        address = outputAddress(kAudioDevicePropertyBufferFrameSize)
        size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &frames)
        if status != noErr {
            stderrLine("thock: could not set IO buffer size to \(frames) (OSStatus \(status))")
        }
    }

    private func readBufferFrames() -> UInt32 {
        guard deviceID != 0 else { return 0 }
        var address = outputAddress(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr else { return 0 }
        return frames
    }

    private func deviceName() -> String {
        guard deviceID != 0 else { return "?" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef) == noErr,
              let name = nameRef?.takeRetainedValue() else { return "?" }
        return name as String
    }

    private func installOverloadListener() {
        guard deviceID != 0, overloadBlock == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let counter = overloads
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            catomic_store_release(counter, catomic_load_relaxed(counter) &+ 1)
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, overloadQueue, block) == noErr {
            overloadBlock = block
            overloadDevice = deviceID
        }
    }

    private func removeOverloadListener() {
        guard let block = overloadBlock, overloadDevice != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(overloadDevice, &address, overloadQueue, block)
        overloadBlock = nil
        overloadDevice = 0
    }

    func deviceInfo() -> DeviceInfo {
        DeviceInfo(
            name: deviceName(),
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            bufferFrames: readBufferFrames(),
            bufferFramesRequested: requestedBufferFrames,
            presentationLatencyMs: engine.outputNode.presentationLatency * 1000
        )
    }
}

/// Decodes a PCM buffer into the engine format once, at load time, so the
/// playback path never converts.
enum SampleConverter {
    static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let source = input.format
        let sameRate = source.sampleRate == target.sampleRate
        let sameLayout = source.commonFormat == target.commonFormat
            && source.isInterleaved == target.isInterleaved

        if sameRate && sameLayout && source.channelCount == target.channelCount {
            return input
        }

        // Same channel count: let AVAudioConverter handle rate and layout.
        if source.channelCount == target.channelCount {
            return try resample(input, to: target)
        }

        // Mono source, N-channel target: convert mono, then copy to every channel.
        if source.channelCount == 1, !target.isInterleaved,
           let monoTarget = AVAudioFormat(standardFormatWithSampleRate: target.sampleRate, channels: 1) {
            let mono = (sameRate && sameLayout) ? input : try resample(input, to: monoTarget)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: mono.frameLength),
                  let src = mono.floatChannelData, let dst = out.floatChannelData else {
                throw AudioEngine.Failure.bufferAllocation
            }
            out.frameLength = mono.frameLength
            for ch in 0..<Int(target.channelCount) {
                dst[ch].update(from: src[0], count: Int(mono.frameLength))
            }
            return out
        }

        // Anything else (e.g. stereo -> mono): converter with default channel map.
        return try resample(input, to: target)
    }

    private static func resample(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: target) else {
            throw AudioEngine.Failure.conversion("no converter \(input.format) -> \(target)")
        }
        converter.primeMethod = .none
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioEngine.Failure.bufferAllocation
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw AudioEngine.Failure.conversion(error?.localizedDescription ?? "unknown")
        }
        return out
    }
}
