import AVFoundation

/// A loaded Mechvibes pack: samples registered in the VoiceMixer plus two
/// fixed 128-entry tables mapping CGKeyCode → sample index (or -1).
final class Soundpack {
    struct SampleInfo {
        var source: String     // "[start+dur ms]" or file name, for --map
        var energy: Double     // sum of squares / channels, after normalization
        var frames: Int
    }

    let name: String
    let id: String
    let directory: URL
    let type: String
    let version: Int
    let keyDown: UnsafeMutablePointer<Int32>
    let keyUp: UnsafeMutablePointer<Int32>
    private(set) var samples: [SampleInfo] = []
    private(set) var directlyDefined = 0     // CG keys mapped through a define
    private(set) var byDefault = 0           // CG keys that fell back to a default

    init(name: String, id: String, directory: URL, type: String, version: Int) {
        self.name = name
        self.id = id
        self.directory = directory
        self.type = type
        self.version = version
        keyDown = .allocate(capacity: 128)
        keyDown.initialize(repeating: -1, count: 128)
        keyUp = .allocate(capacity: 128)
        keyUp.initialize(repeating: -1, count: 128)
    }

    deinit {
        keyDown.deallocate()
        keyUp.deallocate()
    }

    var hasKeyUp: Bool {
        (0..<128).contains { keyUp[$0] >= 0 }
    }

    fileprivate func setSamples(_ s: [SampleInfo]) { samples = s }
    fileprivate func setCounts(direct: Int, fallback: Int) {
        directlyDefined = direct
        byDefault = fallback
    }
}

enum SoundpackError: Error, CustomStringConvertible {
    case configMissing(String)
    case invalidConfig(String)
    case audio(String)
    case noSamples

    var description: String {
        switch self {
        case .configMissing(let p): return "no config.json in \(p)"
        case .invalidConfig(let m): return "invalid config.json: \(m)"
        case .audio(let m): return "audio: \(m)"
        case .noSamples: return "pack defines no playable sounds"
        }
    }
}

enum SoundpackLoader {
    /// Peak level every pack is normalized to (-6 dBFS).
    static let targetPeak: Float = 0.5

    private enum Define {
        case slice(startMs: Double, durMs: Double)
        case file(String)
        case none
    }

    /// Directories under `root` that contain a config.json, sorted by name.
    static func listPacks(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Built-in fallback: one click for every key, no key-up sound.
    static func builtInClick(url: URL, mixer: VoiceMixer, format: AVAudioFormat) throws -> Soundpack {
        let buffer = try decode(url, format: format)
        normalize([buffer])
        let index = mixer.register(buffer)
        guard index >= 0 else { throw SoundpackError.noSamples }
        let pack = Soundpack(name: "built-in click", id: "builtin", directory: url.deletingLastPathComponent(),
                             type: "single", version: 0)
        for k in 0..<128 { pack.keyDown[k] = index }
        pack.setSamples([Soundpack.SampleInfo(source: url.lastPathComponent, energy: energy(of: buffer),
                                              frames: Int(buffer.frameLength))])
        pack.setCounts(direct: 0, fallback: 128)
        return pack
    }

    static func load(directory: URL, mixer: VoiceMixer, format: AVAudioFormat) throws -> Soundpack {
        let configURL = directory.appendingPathComponent("config.json")
        guard let data = FileManager.default.contents(atPath: configURL.path) else {
            throw SoundpackError.configMissing(directory.path)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SoundpackError.invalidConfig("top level is not an object")
        }
        let name = obj["name"] as? String ?? directory.lastPathComponent
        let id = obj["id"] as? String ?? directory.lastPathComponent
        let type = obj["key_define_type"] as? String ?? "single"
        let version = obj["version"] as? Int ?? 1
        let soundField = obj["sound"] as? String
        let soundUpField = obj["soundup"] as? String
        let rawDefines = obj["defines"] as? [String: Any] ?? [:]

        // "57" -> down define, "57-up" -> up define
        var downDefines: [Int32: Define] = [:]
        var upDefines: [Int32: Define] = [:]
        for (key, value) in rawDefines {
            let isUp = key.hasSuffix("-up")
            let codeText = isUp ? String(key.dropLast(3)) : key
            guard let code = Int32(codeText) else { continue }
            let define = parseDefine(value)
            if isUp { upDefines[code] = define } else { downDefines[code] = define }
        }

        let pack = Soundpack(name: name, id: id, directory: directory, type: type, version: version)
        var buffers: [AVAudioPCMBuffer] = []
        var infos: [Soundpack.SampleInfo] = []
        var registry: [String: Int32] = [:]       // dedupe key -> sample index

        func register(_ buffer: AVAudioPCMBuffer, key: String, source: String) -> Int32 {
            if let existing = registry[key] { return existing }
            let index = mixer.register(buffer)
            guard index >= 0 else { return -1 }
            registry[key] = index
            buffers.append(buffer)
            infos.append(Soundpack.SampleInfo(source: source, energy: 0, frames: Int(buffer.frameLength)))
            return index
        }

        // Whole-file decode cache for single packs and multi files.
        var decoded: [String: AVAudioPCMBuffer] = [:]
        func decodeCached(_ relative: String) throws -> AVAudioPCMBuffer {
            if let b = decoded[relative] { return b }
            let b = try decodeWithFallback(directory.appendingPathComponent(relative), format: format)
            decoded[relative] = b
            return b
        }

        func resolve(_ define: Define) -> Int32 {
            switch define {
            case .none:
                return -1
            case .slice(let start, let dur):
                guard type == "single", let file = soundField else { return -1 }
                guard let whole = try? decodeCached(file) else { return -1 }
                let key = "slice:\(start):\(dur)"
                if let existing = registry[key] { return existing }
                guard let piece = slice(whole, startMs: start, durMs: dur) else { return -1 }
                return register(piece, key: key, source: "[\(Int(start))+\(Int(dur)) ms]")
            case .file(let relative):
                if let existing = registry["file:" + relative] { return existing }
                guard let b = try? decodeCached(relative) else { return -1 }
                return register(b, key: "file:" + relative, source: relative)
            }
        }

        // Defines by Mechvibes code.
        // Sorted so sample indices are stable from run to run.
        var codeDown: [Int32: Int32] = [:]
        var codeUp: [Int32: Int32] = [:]
        for code in downDefines.keys.sorted() {
            let s = resolve(downDefines[code]!)
            if s >= 0 { codeDown[code] = s }
        }
        for code in upDefines.keys.sorted() {
            let s = resolve(upDefines[code]!)
            if s >= 0 { codeUp[code] = s }
        }

        // Generic sounds: v2 "GENERIC_R{0-4}.mp3" per row, or a plain file.
        var rowDefault = [Int32](repeating: -1, count: 5)
        if type == "multi", let pattern = soundField {
            let expanded = expandRowPattern(pattern)
            for (row, file) in expanded.enumerated() where row < 5 {
                rowDefault[row] = resolve(.file(file))
            }
        }
        var upDefault: Int32 = -1
        if let up = soundUpField {
            upDefault = resolve(.file(expandRowPattern(up).first ?? up))
        }
        // Otherwise: the most used down sample of the pack.
        var modeDefault: Int32 = -1
        if rowDefault.allSatisfy({ $0 < 0 }) {
            var counts: [Int32: Int] = [:]
            for s in codeDown.values { counts[s, default: 0] += 1 }
            modeDefault = counts.max { a, b in (a.value, b.key) < (b.value, a.key) }?.key ?? -1
        }

        // CGKeyCode tables.
        var direct = 0
        var fallback = 0
        for cg in 0..<128 {
            let code = Scancodes.table[cg]
            if code >= 0, let s = codeDown[code] {
                pack.keyDown[cg] = s
                direct += 1
            } else {
                let row = Int(Scancodes.row[cg])
                let d = rowDefault[row] >= 0 ? rowDefault[row] : modeDefault
                pack.keyDown[cg] = d
                if d >= 0 { fallback += 1 }
            }
            if code >= 0, let s = codeUp[code] {
                pack.keyUp[cg] = s
            } else {
                pack.keyUp[cg] = upDefault
            }
        }
        guard !buffers.isEmpty, (0..<128).contains(where: { pack.keyDown[$0] >= 0 }) else {
            throw SoundpackError.noSamples
        }

        normalize(buffers)
        for i in infos.indices {
            infos[i].energy = energy(of: buffers[i])
        }
        pack.setSamples(infos)
        pack.setCounts(direct: direct, fallback: fallback)
        return pack
    }

    // MARK: helpers

    private static func parseDefine(_ value: Any) -> Define {
        if let arr = value as? [Any], arr.count >= 2,
           let start = (arr[0] as? NSNumber)?.doubleValue, let dur = (arr[1] as? NSNumber)?.doubleValue {
            return .slice(startMs: start, durMs: dur)
        }
        if let s = value as? String, !s.isEmpty {
            return .file(s)
        }
        return .none
    }

    /// "GENERIC_R{0-4}.mp3" -> ["GENERIC_R0.mp3", ..., "GENERIC_R4.mp3"]
    private static func expandRowPattern(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"), let close = pattern.firstIndex(of: "}"), open < close else {
            return [pattern]
        }
        let inner = pattern[pattern.index(after: open)..<close]
        let parts = inner.split(separator: "-")
        guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo <= hi else {
            return [pattern]
        }
        let prefix = pattern[..<open]
        let suffix = pattern[pattern.index(after: close)...]
        return (lo...hi).map { "\(prefix)\($0)\(suffix)" }
    }

    static func decode(_ url: URL, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SoundpackError.audio("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard file.length > 0, let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                          frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SoundpackError.audio("empty or unreadable \(url.lastPathComponent)")
        }
        do {
            try file.read(into: raw)
            return try SampleConverter.convert(raw, to: format)
        } catch {
            throw SoundpackError.audio("cannot decode \(url.lastPathComponent): \(error)")
        }
    }

    /// Vorbis needs a recent macOS; if an .ogg fails, look for a sibling
    /// .wav / .flac / .m4a / .mp3 with the same base name.
    private static func decodeWithFallback(_ url: URL, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        do {
            return try decode(url, format: format)
        } catch let original {
            let base = url.deletingPathExtension()
            for ext in ["wav", "flac", "m4a", "mp3", "aiff", "caf"] {
                let alt = base.appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: alt.path), let b = try? decode(alt, format: format) {
                    return b
                }
            }
            throw original
        }
    }

    /// Copies a [start, duration] window out of a decoded file with short
    /// fades so arbitrary cut points do not click.
    private static func slice(_ whole: AVAudioPCMBuffer, startMs: Double, durMs: Double) -> AVAudioPCMBuffer? {
        let rate = whole.format.sampleRate
        let total = Int(whole.frameLength)
        let start = max(0, min(total, Int(startMs / 1000 * rate)))
        let length = max(0, min(total - start, Int(durMs / 1000 * rate)))
        guard length > 2, let src = whole.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: whole.format, frameCapacity: AVAudioFrameCount(length)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(length)
        let channels = Int(whole.format.channelCount)
        let fadeIn = min(length / 2, Int(rate * 0.0005))
        let fadeOut = min(length / 2, Int(rate * 0.002))
        for ch in 0..<channels {
            dst[ch].update(from: src[ch] + start, count: length)
            for i in 0..<fadeIn {
                dst[ch][i] *= Float(i) / Float(fadeIn)
            }
            for i in 0..<fadeOut {
                dst[ch][length - 1 - i] *= Float(i) / Float(fadeOut)
            }
        }
        return out
    }

    /// Scales all buffers by one factor so the loudest peak sits at
    /// `targetPeak`; relative loudness between keys is preserved.
    private static func normalize(_ buffers: [AVAudioPCMBuffer]) {
        var peak: Float = 0
        for b in buffers {
            guard let data = b.floatChannelData else { continue }
            for ch in 0..<Int(b.format.channelCount) {
                for i in 0..<Int(b.frameLength) {
                    peak = max(peak, abs(data[ch][i]))
                }
            }
        }
        guard peak > 0 else { return }
        let gain = targetPeak / peak
        for b in buffers {
            guard let data = b.floatChannelData else { continue }
            for ch in 0..<Int(b.format.channelCount) {
                for i in 0..<Int(b.frameLength) {
                    data[ch][i] *= gain
                }
            }
        }
    }
}
