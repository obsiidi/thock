import AVFoundation
import CoreAudio

/// AVAudioEngine wrapper. Phase 1: one player node, one pre-decoded click.
/// Phase 2 replaces the single node with a round-robin voice pool.
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
        var presentationLatencyMs: Double
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Format every sample is decoded into: the main mixer's output format
    /// (hardware sample rate, float32, non-interleaved).
    let format: AVAudioFormat
    private var click: AVAudioPCMBuffer?
    private var configObserver: NSObjectProtocol?

    init() throws {
        // Touching mainMixerNode wires mixer -> output for the current device.
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard mixerFormat.channelCount > 0, mixerFormat.sampleRate > 0 else {
            throw Failure.noOutputFormat
        }
        format = mixerFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    deinit {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    func loadClick(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Failure.bufferAllocation
        }
        try file.read(into: raw)
        click = try SampleConverter.convert(raw, to: format)
    }

    var clickFrames: AVAudioFrameCount {
        click?.frameLength ?? 0
    }

    func start() throws {
        engine.prepare()
        try engine.start()
        player.play()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    /// Called from the trigger thread. `.interrupts` restarts the click
    /// instead of queueing it behind the one still playing.
    @inline(__always)
    func trigger() {
        guard let click = click else { return }
        player.scheduleBuffer(click, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// The engine stops itself when the output device changes (headphones
    /// plugged in, etc.). Bring it back; the mixer resamples if the new
    /// device runs at another rate.
    private func restartAfterConfigurationChange() {
        do {
            try engine.start()
            player.play()
        } catch {
            stderrLine("thock: audio restart after device change failed: \(error)")
        }
    }

    func deviceInfo() -> DeviceInfo {
        var info = DeviceInfo(
            name: "?",
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            bufferFrames: 0,
            presentationLatencyMs: engine.outputNode.presentationLatency * 1000
        )
        guard let au = engine.outputNode.audioUnit else { return info }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size
        )
        guard status == noErr, deviceID != 0 else { return info }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr {
            info.bufferFrames = frames
        }

        address.mSelector = kAudioObjectPropertyName
        address.mScope = kAudioObjectPropertyScopeGlobal
        var nameRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef) == noErr,
           let name = nameRef?.takeRetainedValue() {
            info.name = name as String
        }
        return info
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
