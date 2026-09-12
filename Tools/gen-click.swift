// gen-click: deterministic synthetic keyboard click for testing.
//
//   swift Tools/gen-click.swift Samples/click.wav [--rate 48000]
//
// White noise (xorshift64*, fixed seed) -> RBJ band-pass 3 kHz, Q=2 ->
// exponential envelope with 6 ms time constant -> 50 ms, peak -6 dBFS,
// 16-bit mono WAV. Nothing is downloaded; the output is reproducible.

import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var outPath: String?
var sampleRate = 48_000.0
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--rate", let v = args.first, let r = Double(v) {
        args.removeFirst()
        sampleRate = r
    } else {
        outPath = a
    }
}
guard let outPath = outPath else {
    print("usage: swift Tools/gen-click.swift OUT.wav [--rate HZ]")
    exit(64)
}

let durationMs = 50.0
let centerHz = 3000.0
let q = 2.0
let tauSeconds = 0.006
let peakTarget = 0.5 // -6 dBFS

let n = Int(sampleRate * durationMs / 1000)

// xorshift64* — fixed seed so the file is identical on every run.
var state: UInt64 = 0x7404C4
func noise() -> Double {
    state ^= state >> 12
    state ^= state << 25
    state ^= state >> 27
    let v = state &* 2_685_821_657_736_338_717
    return Double(v >> 11) / Double(1 << 53) * 2 - 1
}

// RBJ cookbook band-pass, constant 0 dB peak gain.
let w0 = 2 * Double.pi * centerHz / sampleRate
let alpha = sin(w0) / (2 * q)
let a0 = 1 + alpha
let b0 = alpha / a0
let b2 = -alpha / a0
let a1 = (-2 * cos(w0)) / a0
let a2 = (1 - alpha) / a0

var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
var samples = [Double](repeating: 0, count: n)
for i in 0..<n {
    let x = noise()
    let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
    x2 = x1; x1 = x
    y2 = y1; y1 = y
    let t = Double(i) / sampleRate
    samples[i] = y * exp(-t / tauSeconds)
}

let rawPeak = samples.map { abs($0) }.max() ?? 1
for i in 0..<n {
    samples[i] *= peakTarget / rawPeak
}

func dbfs(_ v: Double) -> String {
    v <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(v))
}
let peak = samples.map { abs($0) }.max() ?? 0
let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(n))
let at40 = Int(0.040 * sampleRate)
let tailPeak = samples[at40...].map { abs($0) }.max() ?? 0

var data = Data()
func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

let byteRate = UInt32(sampleRate) * 2
ascii("RIFF"); le32(UInt32(36 + n * 2)); ascii("WAVE")
ascii("fmt "); le32(16); le16(1); le16(1); le32(UInt32(sampleRate)); le32(byteRate); le16(2); le16(16)
ascii("data"); le32(UInt32(n * 2))
for s in samples {
    let clamped = max(-32768.0, min(32767.0, (s * 32767).rounded()))
    le16(UInt16(bitPattern: Int16(clamped)))
}

do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    print("gen-click: write failed: \(error)")
    exit(1)
}

print("gen-click: wrote \(outPath)")
print("  rate=\(Int(sampleRate)) Hz  frames=\(n)  bytes=\(data.count)")
print("  peak=\(dbfs(peak)) dBFS  rms=\(dbfs(rms)) dBFS  tail@40ms=\(dbfs(tailPeak)) dBFS")
