import AVFoundation
import Foundation

// Sound packs from the repo and a stereo offline mix with two buses: effects
// (keys, clicks) and music, so the music can duck under the keys.

func loadMono(_ path: String) -> [Float] {
    let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buf)
    let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
    var m = [Float](repeating: 0, count: n)
    for c in 0..<ch { let p = buf.floatChannelData![c]; for i in 0..<n { m[i] += p[i] / Float(ch) } }
    let ratio = fmt.sampleRate / Double(SR)
    if abs(ratio - 1) < 1e-9 { return m }
    return (0..<Int(Double(n) / ratio)).map { j in
        let x = Double(j) * ratio, i = Int(x), f = Float(x - Double(i))
        return i + 1 < n ? m[i] * (1 - f) + m[i + 1] * f : m[n - 1]
    }
}

/// A Mechvibes pack: Windows scancode -> sample (key down / key up).
final class Pack {
    let id: String, short: String
    var down: [Int: [Float]] = [:], up: [Int: [Float]] = [:]
    var generic: [[Float]] = [], genericUp: [Float]?

    init(_ id: String, _ short: String) {
        self.id = id; self.short = short
        let path = "packs/" + id
        let cfg = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path + "/config.json"))) as! [String: Any]
        let defines = cfg["defines"] as? [String: Any] ?? [:]
        func put(_ key: String, _ s: [Float]) {
            if key.hasSuffix("-up") { if let c = Int(key.dropLast(3)) { up[c] = s } } else if let c = Int(key) { down[c] = s }
        }
        if (cfg["key_define_type"] as? String) == "single" {
            let all = loadMono(path + "/" + (cfg["sound"] as! String))
            for (k, v) in defines {
                guard let a = v as? [Any], a.count >= 2, let s = (a[0] as? NSNumber)?.doubleValue,
                      let d = (a[1] as? NSNumber)?.doubleValue else { continue }
                let i0 = Int(s * Double(SR) / 1000), i1 = min(all.count, i0 + Int(d * Double(SR) / 1000))
                if i0 < i1 { put(k, Array(all[i0..<i1])) }
            }
        } else {
            var cache: [String: [Float]] = [:]
            func file(_ n: String) -> [Float]? {
                if let c = cache[n] { return c }
                guard FileManager.default.fileExists(atPath: path + "/" + n) else { return nil }
                let s = loadMono(path + "/" + n); cache[n] = s; return s
            }
            for (k, v) in defines { if let n = v as? String, let s = file(n) { put(k, s) } }
            if let snd = cfg["sound"] as? String {
                if let r = snd.range(of: #"\{\d+-\d+\}"#, options: .regularExpression) {
                    let nums = snd[r].dropFirst().dropLast().split(separator: "-").compactMap { Int($0) }
                    for i in nums[0]...nums[1] { if let s = file(snd.replacingCharacters(in: r, with: String(i))) { generic.append(s) } }
                } else if let s = file(snd) { generic.append(s) }
            }
            if let su = cfg["soundup"] as? String { genericUp = file(su) }
        }
        // level the packs: a typical letter key peaks at 0.5
        var peaks = (16...50).compactMap { down[$0] }.map { $0.reduce(Float(0)) { max($0, abs($1)) } }
        peaks += generic.map { $0.reduce(Float(0)) { max($0, abs($1)) } }
        peaks.sort()
        let ref = peaks.isEmpty ? 1 : peaks[peaks.count * 3 / 4]
        let g = ref > 0 ? 0.5 / ref : 1
        down = down.mapValues { $0.map { $0 * g } }; up = up.mapValues { $0.map { $0 * g } }
        generic = generic.map { $0.map { $0 * g } }; genericUp = genericUp.map { $0.map { $0 * g } }
    }
    func press(_ code: Int) -> [Float]? {
        if let s = down[code] { return s }
        if !generic.isEmpty { return generic[Int(rng.next() * Double(generic.count)) % generic.count] }
        return down[30]
    }
    func release(_ code: Int) -> [Float]? { up[code] ?? genericUp }
}

final class Mixer {
    let n: Int
    var fxL: [Float], fxR: [Float], muL: [Float], muR: [Float]
    init(seconds: Double) {
        n = Int(seconds * Double(SR))
        fxL = [Float](repeating: 0, count: n); fxR = fxL; muL = fxL; muR = fxL
    }
    /// Mixes a mono sample into the effects bus at `t`: gain in dB, pan -1…1,
    /// optional one-pole low-pass (soft hits sound duller, as in the app),
    /// pitch jitter via `rate`.
    func play(_ s: [Float]?, at t: Double, db: Double = 0, pan: Double = 0, cutoff: Double? = nil, rate: Double = 1) {
        guard let s, !s.isEmpty else { return }
        let g = Float(pow(10, db / 20))
        let gl = g * Float(cos((pan + 1) * .pi / 4)) * 1.414, gr = g * Float(sin((pan + 1) * .pi / 4)) * 1.414
        let a = cutoff.map { Float(1 - exp(-2 * Double.pi * $0 / Double(SR))) } ?? 1
        var y: Float = 0
        let start = Int(t * Double(SR))
        for j in 0..<Int(Double(s.count) / rate) {
            let x = Double(j) * rate, i = Int(x), f = Float(x - Double(i))
            let v = i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[s.count - 1]
            y += a * (v - y)
            let k = start + j
            if k >= 0 && k < n { fxL[k] += y * gl; fxR[k] += y * gr }
        }
    }
    /// Final stereo mix: music ducks under the effects bus, then a soft limiter.
    func master() -> (L: [Float], R: [Float]) {
        var env: Float = 0
        let att: Float = 1 - exp(-1 / (0.004 * Float(SR))), rel: Float = 1 - exp(-1 / (0.18 * Float(SR)))
        var L = [Float](repeating: 0, count: n), R = L
        for i in 0..<n {
            let lvl = max(abs(fxL[i]), abs(fxR[i]))
            env += (lvl > env ? att : rel) * (lvl - env)
            let duck = 1 - min(0.55, env * 1.4)
            L[i] = fxL[i] + muL[i] * duck
            R[i] = fxR[i] + muR[i] * duck
        }
        // the loudest keystroke lands just under the ceiling; AAC needs ~1 dB of headroom
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(fxL[i]), abs(fxR[i])) }
        let pre: Float = peak > 0 ? 0.95 / peak : 1
        func soft(_ x: Float) -> Float {
            let a = abs(x)
            return a < 0.55 ? x : (x < 0 ? -1 : 1) * (0.55 + 0.15 * Float(tanh(Double((a - 0.55) / 0.15))))
        }
        for i in 0..<n { L[i] = soft(L[i] * pre); R[i] = soft(R[i] * pre) }
        return (L, R)
    }
}

// Windows scancodes (what Mechvibes packs map)
let scan: [Character: Int] = [
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23, "o": 24, "p": 25,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38,
    "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52, " ": 57, "'": 40, "-": 12,
]
