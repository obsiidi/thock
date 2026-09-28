// Tools/promo.swift — renders the thock promo video: 1920x1080, 30 fps,
// H.264 + AAC, ~33 s. Pictures in the website's dot-matrix style, sound mixed
// from the bundled packs, in sync with what is typed on screen.
//
//   swiftc -O Tools/promo.swift -o /tmp/promo && /tmp/promo dist/thock-promo.mp4 [poster.png]
//
// Run from the repo root (reads packs/, mouse-packs/, site/fonts/).
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let W = 1920, H = 1080, FPS = 30, SR = 48_000
let total = 33.0
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "dist/thock-promo.mp4"
let posterPath: String? = args.count > 2 ? args[2] : nil

struct RNG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
}
var rng = RNG(s: 7)

// MARK: - Fonts and colours (site tokens)

for f in ["archivo-latin.woff2", "jetbrains-mono-latin.woff2"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "site/fonts/" + f) as CFURL, .process, nil)
}
func font(_ name: String, _ size: CGFloat) -> CTFont {
    let f = CTFontCreateWithName(name as CFString, size, nil)
    precondition(CTFontCopyPostScriptName(f) as String == name, "font \(name) missing: run from the repo root")
    return f
}
let heavy = "ArchivoRoman-ExtraBold", bold = "ArchivoRoman-Bold", mono = "JetBrainsMono-Regular"
func ink(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: 237 / 255, green: 237 / 255, blue: 231 / 255, alpha: a) }
let ink2 = CGColor(srgbRed: 201 / 255, green: 201 / 255, blue: 194 / 255, alpha: 1)
let ink3 = CGColor(srgbRed: 154 / 255, green: 154 / 255, blue: 146 / 255, alpha: 1)
let bg = CGColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
let panel = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

// MARK: - Audio: packs and an offline mix

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
    let short: String, full: String, kind: String
    var down: [Int: [Float]] = [:], up: [Int: [Float]] = [:]
    var generic: [[Float]] = [], genericUp: [Float]?

    init(_ dir: String, short: String, full: String, kind: String) {
        self.short = short; self.full = full; self.kind = kind
        let path = "packs/" + dir
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
        // level the packs against each other: typical letter key peaks at 0.55
        var peaks = (16...50).compactMap { down[$0] }.map { $0.reduce(Float(0)) { max($0, abs($1)) } }
        peaks += generic.map { $0.reduce(Float(0)) { max($0, abs($1)) } }
        peaks.sort()
        let ref = peaks.isEmpty ? 1 : peaks[peaks.count * 3 / 4]
        let g = ref > 0 ? 0.55 / ref : 1
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

final class Mouse {
    let down: [Float], up: [Float]
    init(_ dir: String) {
        down = loadMono("mouse-packs/\(dir)/down.wav"); up = loadMono("mouse-packs/\(dir)/up.wav")
    }
}

let blue = Pack("cherrymx-blue-abs", short: "Cherry MX Blue", full: "Cherry MX Blue – ABS", kind: "CLICKY")
let brown = Pack("cherrymx-brown-abs", short: "Cherry MX Brown", full: "Cherry MX Brown – ABS", kind: "TACTILE")
let red = Pack("cherrymx-red-abs", short: "Cherry MX Red", full: "Cherry MX Red – ABS", kind: "LINEAR")
let black = Pack("cherrymx-black-abs", short: "Cherry MX Black", full: "Cherry MX Black – ABS", kind: "LINEAR · HEAVY")
let topre = Pack("topre-purple-hybrid-pbt", short: "Topre", full: "Topre Purple Hybrid – PBT", kind: "ELECTRO-CAP")
let pandas = Pack("holy-pandas", short: "Holy Pandas", full: "Holy Pandas", kind: "TACTILE")
let cream = Pack("nk-cream", short: "NK Cream", full: "NK Cream", kind: "LINEAR")
let allPacks = [blue, brown, red, black, topre, pandas, cream]
let mouse = Mouse("mx-master-3s")

var mix = [Float](repeating: 0, count: Int(total * Double(SR)))
/// Mixes a sample in at `t` seconds: gain in dB, optional one-pole low-pass
/// (soft hits sound duller, as in the app), small pitch jitter via `rate`.
func play(_ s: [Float]?, at t: Double, db: Double = 0, cutoff: Double? = nil, rate: Double = 1) {
    guard let s, !s.isEmpty else { return }
    let g = Float(pow(10, db / 20))
    let a = cutoff.map { Float(1 - exp(-2 * Double.pi * $0 / Double(SR))) } ?? 1
    var y: Float = 0
    let start = Int(t * Double(SR))
    for j in 0..<Int(Double(s.count) / rate) {
        let x = Double(j) * rate, i = Int(x), f = Float(x - Double(i))
        let v = i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[s.count - 1]
        y += a * (v - y)
        let k = start + j
        if k >= 0 && k < mix.count { mix[k] += y * g }
    }
}
func jitter() -> Double { 0.975 + 0.05 * rng.next() }

// Windows scancodes (what Mechvibes packs map)
let scan: [Character: Int] = [
    "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23, "o": 24, "p": 25,
    "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38,
    "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52, " ": 57,
]
func key(_ p: Pack, _ ch: Character, at t: Double, db: Double = 0, cutoff: Double? = nil) {
    let code = scan[Character(ch.lowercased())] ?? 30
    let r = jitter()
    play(p.press(code), at: t, db: db, cutoff: cutoff, rate: r)
    play(p.release(code), at: t + 0.085 + 0.03 * rng.next(), db: db - 4, cutoff: cutoff, rate: r)
}

// MARK: - Timeline

// 1 · intro: "thock" typed letter by letter into the dot wordmark
let introTimes = [0.55, 0.74, 0.91, 1.08, 1.31]
for (i, ch) in "thock".enumerated() { key(topre, ch, at: introTimes[i], db: -1) }

// 2 · typing on real switches
let typedText = "Every key sounds like a real switch."
var typed: [(t: Double, ch: Character)] = []
var shiftAt: [Double] = []
do {
    var t = 5.0
    for ch in typedText {
        if ch.isUppercase { play(blue.press(42), at: t - 0.06, db: -6, rate: jitter()); shiftAt.append(t - 0.06) }
        typed.append((t, ch))
        key(blue, ch, at: t, db: -2 + 2 * rng.next())
        t += ch == " " ? 0.12 + 0.06 * rng.next() : 0.07 + 0.07 * rng.next()
    }
}

// 3 · key force: light taps, normal, firm hits, then alternating
var hits: [(t: Double, force: Double)] = []
do {
    var t = 12.0
    for _ in 0..<5 { hits.append((t, 0.16 + 0.12 * rng.next())); t += 0.21 + 0.05 * rng.next() }
    t += 0.3
    for _ in 0..<3 { hits.append((t, 0.5 + 0.1 * rng.next())); t += 0.22 }
    t += 0.3
    for _ in 0..<5 { hits.append((t, 0.86 + 0.14 * rng.next())); t += 0.2 + 0.04 * rng.next() }
    t += 0.35
    for i in 0..<6 { hits.append((t, i % 2 == 0 ? 0.2 + 0.08 * rng.next() : 0.92 + 0.08 * rng.next())); t += 0.26 }
    let letters = Array("asdfjkl")
    for h in hits {
        let f = h.force
        key(topre, letters[Int(rng.next() * 7) % 7], at: h.t, db: -20 + 20 * f, cutoff: f > 0.95 ? nil : 900 * pow(22, f))
    }
}

// 4 · seven packs, switched in the popover
let packStart = 18.55, packStep = 0.86
for (i, p) in allPacks.enumerated() {
    let t0 = packStart + Double(i) * packStep + 0.12
    for j in 0..<4 { key(p, Array("fjdk")[j], at: t0 + Double(j) * 0.105 + 0.02 * rng.next(), db: -1) }
}

// 5 · trackpad clicks with Force Touch pressure
let clicks: [(t: Double, force: Double, x: Double, y: Double)] = [
    (25.75, 0.35, 0.32, 0.42), (26.3, 0.95, 0.62, 0.55), (26.95, 0.3, 0.45, 0.7), (27.45, 0.9, 0.7, 0.35), (27.62, 0.9, 0.7, 0.35),
]
for c in clicks {
    let db = -12 + 12 * c.force
    play(mouse.down, at: c.t, db: db, rate: jitter())
    play(mouse.up, at: c.t + 0.08, db: db - 3, rate: jitter())
}

// 6 · end card
let outroHit = 29.0
play(topre.press(57), at: outroHit, db: 1)
play(topre.release(57), at: outroHit + 0.1, db: -3)

// soft limiter
for i in 0..<mix.count {
    let x = mix[i], a = abs(x)
    if a > 0.8 { mix[i] = (x < 0 ? -1 : 1) * (0.8 + 0.2 * Float(tanh(Double((a - 0.8) / 0.2)))) }
}

// MARK: - Drawing helpers (origin top-left)

enum Align { case left, center, right }
@discardableResult
func text(_ c: CGContext, _ s: String, _ f: CTFont, _ color: CGColor, x: CGFloat, y: CGFloat,
          align: Align = .left, kern: CGFloat = 0) -> CGFloat {
    var attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if kern != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let x0 = align == .left ? x : align == .center ? x - w / 2 : x - w
    c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    c.textPosition = CGPoint(x: x0, y: y)
    CTLineDraw(line, c)
    return w
}
func dot(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    guard r > 0.05, a > 0.004 else { return }
    c.setFillColor(ink(min(1, a)))
    c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, v)) }
func smooth(_ v: Double) -> Double { let x = clamp(v); return x * x * (3 - 2 * x) }
func easeOutBack(_ v: Double) -> Double { let x = clamp(v) - 1; return 1 + 2.2 * x * x * x + 1.2 * x * x }
/// Fade in over `fi` after `a`, out over `fo` before `b`.
func envelope(_ t: Double, _ a: Double, _ b: Double, _ fi: Double = 0.35, _ fo: Double = 0.35) -> Double {
    smooth((t - a) / fi) * smooth((b - t) / fo)
}
func roundRect(_ c: CGContext, _ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// Dot wordmark like the site: text rendered to a bitmap, coverage sampled on a grid.
struct WDot { let x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat, letter: Int }
func wordmark(_ word: String, box: CGRect, step: CGFloat) -> [WDot] {
    let S: CGFloat = 2
    let w = Int(box.width * S), h = Int(box.height * S)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    func line(_ fs: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(heavy, fs),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): fs * 0.01,
        ]))
    }
    let probe = CTLineGetBoundsWithOptions(line(100), .useGlyphPathBounds)
    let fs = min(CGFloat(w) * 0.9 / probe.width * 100, CGFloat(h) * 0.95 / probe.height * 100)
    let l = line(fs)
    let b = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
    let x0 = (CGFloat(w) - b.width) / 2 - b.minX
    ctx.textPosition = CGPoint(x: x0, y: (CGFloat(h) - b.height) / 2 - b.minY)
    CTLineDraw(l, ctx)
    let bounds = (0...word.count).map { (x0 + CTLineGetOffsetForStringIndex(l, $0, nil)) / S }
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let cols = Int(box.width / step), rows = Int(box.height / step)
    let ox = (box.width - CGFloat(cols - 1) * step) / 2, oy = (box.height - CGFloat(rows - 1) * step) / 2
    var out: [WDot] = []
    for r in 0..<rows { for c in 0..<cols {
        let cx = ox + CGFloat(c) * step, cy = oy + CGFloat(r) * step
        var sum = 0.0
        for sy in 0..<3 { for sx in 0..<3 {
            let x = min(w - 1, max(0, Int((cx - step / 2 + (CGFloat(sx) + 0.5) * step / 3) * S)))
            let y = min(h - 1, max(0, Int((cy - step / 2 + (CGFloat(sy) + 0.5) * step / 3) * S)))
            sum += Double(px[y * w + x]) / 255
        } }
        let a = min(1, sum / 9 * 1.12)
        if a <= 0.035 { continue }
        let letter = max(0, min(word.count - 1, (bounds.firstIndex { $0 > cx } ?? word.count) - 1))
        out.append(WDot(x: box.minX + cx, y: box.minY + cy, r: step * 0.54 * CGFloat(pow(a, 0.58)),
                        a: CGFloat(0.28 + 0.72 * a), letter: letter))
    } }
    return out
}
let introMark = wordmark("thock", box: CGRect(x: 310, y: 250, width: 1300, height: 360), step: 13)
let outroMark = wordmark("thock", box: CGRect(x: 460, y: 250, width: 1000, height: 290), step: 11)

func eyebrow(_ c: CGContext, _ s: String, y: CGFloat = 190) {
    text(c, s, font(mono, 22), ink3, x: 160, y: y, kern: 4.4)
}

// MacBook keyboard (ANSI), 14.5 units per row
let kbRows: [[(String, Double)]] = [
    ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { ($0, 1) } + [("delete", 1.5)],
    [("tab", 1.5)] + ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]"].map { ($0, 1) } + [("\\", 1)],
    [("caps", 1.75)] + ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'"].map { ($0, 1) } + [("return", 1.75)],
    [("shift", 2.25)] + ["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"].map { ($0, 1) } + [("shift ", 2.25)],
    [("fn", 1), ("control", 1), ("option", 1), ("command", 1.25), ("space", 5), ("command ", 1.25), ("option ", 1),
     ("←", 0.75), ("↑", 0.75), ("↓", 0.75), ("→", 0.75)],
]
var keyPresses: [String: [Double]] = [:]
for e in typed {
    let label = e.ch == " " ? "space" : String(e.ch).uppercased()
    keyPresses[label, default: []].append(e.t)
}
keyPresses["shift", default: []] += shiftAt

func glow(_ times: [Double]?, _ t: Double, decay: Double = 0.32) -> Double {
    guard let times else { return 0 }
    var g = 0.0
    for s in times where s <= t && t - s < 1.5 { g = max(g, exp(-(t - s) / decay)) }
    return g
}

// MARK: - Scenes

func sceneIntro(_ c: CGContext, _ t: Double) {
    for d in introMark {
        let ti = introTimes[d.letter]
        guard t >= ti else { continue }
        let pop = easeOutBack((t - ti) / 0.22), flash = exp(-(t - ti) / 0.25)
        dot(c, d.x, d.y, d.r * CGFloat(pop) * CGFloat(1 + 0.25 * flash), d.a + (1 - d.a) * CGFloat(flash))
    }
    c.saveGState(); c.setAlpha(CGFloat(smooth((t - 1.8) / 0.6)))
    text(c, "Mechanical keyboard sounds for your Mac.", font(mono, 38), ink2, x: 960, y: 740, align: .center)
    c.restoreGState()
    c.saveGState(); c.setAlpha(CGFloat(smooth((t - 2.5) / 0.6)))
    text(c, "They follow how hard you type.", font(mono, 38), ink3, x: 960, y: 800, align: .center)
    c.restoreGState()
}

func sceneTyping(_ c: CGContext, _ t: Double) {
    eyebrow(c, "REAL SWITCHES")
    let shown = String(typed.filter { $0.t <= t }.map(\.ch))
    let f = font(mono, 64)
    let w = text(c, shown, f, ink(), x: 160, y: 300)
    if Int(t * 2.2) % 2 == 0 || typed.contains(where: { abs($0.t - t) < 0.4 }) {
        c.setFillColor(ink(0.9)); c.fill(CGRect(x: 164 + w, y: 248, width: 30, height: 62))
    }
    c.saveGState(); c.setAlpha(CGFloat(smooth((t - 9.3) / 0.5)))
    text(c, "Recorded from real keyboards. About 5 ms from key to sound.", font(mono, 28), ink3, x: 160, y: 372)
    c.restoreGState()

    // keyboard of dots
    let unit: CGFloat = 1500 / 14.5, top: CGFloat = 460, rowH: CGFloat = 100, gap: CGFloat = 9
    let lf = font(mono, 17)
    for (ri, row) in kbRows.enumerated() {
        var x: CGFloat = 210
        for (label, units) in row {
            let kw = CGFloat(units) * unit
            let r = CGRect(x: x + gap / 2, y: top + CGFloat(ri) * rowH + gap / 2, width: kw - gap, height: rowH - gap)
            let name = label.trimmingCharacters(in: .whitespaces)   // trailing space marks right-hand twins
            let g = CGFloat(glow(keyPresses[name], t))
            c.setStrokeColor(ink(0.14 + 0.5 * g)); c.setLineWidth(1.2)
            c.addPath(roundRect(c, r, 10)); c.strokePath()
            let pitch: CGFloat = 11
            let nx = Int((r.width - 10) / pitch), ny = Int((r.height - 10) / pitch)
            let ox = r.minX + (r.width - CGFloat(nx - 1) * pitch) / 2, oy = r.minY + (r.height - CGFloat(ny - 1) * pitch) / 2
            for iy in 0..<ny { for ix in 0..<nx {
                dot(c, ox + CGFloat(ix) * pitch, oy + CGFloat(iy) * pitch, 1.9 + 1.4 * g, 0.14 + 0.86 * g)
            } }
            if name != "space" {
                text(c, name, lf, g > 0.5 ? bg : (name.count > 1 ? ink3 : ink2), x: r.minX + 12, y: r.minY + 26)
            }
            x += kw
        }
    }
}

func sceneForce(_ c: CGContext, _ t: Double) {
    eyebrow(c, "KEY FORCE")
    text(c, "It hears how hard you hit.", font(heavy, 96), ink(), x: 160, y: 300)
    text(c, "MacBooks feel each keystroke through the chassis. thock reads the motion", font(mono, 26), ink3, x: 160, y: 372)
    text(c, "sensor ~800 times a second: firm hits louder and brighter, light taps softer.", font(mono, 26), ink3, x: 160, y: 410)

    // one column of dots per keystroke, filling left to right, height = force
    let right: CGFloat = 1760, left: CGFloat = 160, base: CGFloat = 900, pitch: CGFloat = 15, maxDots = 22
    let slot = (right - left) / CGFloat(hits.count)
    for x in stride(from: left, through: right, by: pitch) { dot(c, x, base, 2, 0.12) }
    var latest: Double?
    for (i, h) in hits.enumerated() where h.t <= t {
        let age = t - h.t
        let x = left + slot * (CGFloat(i) + 0.5) - pitch
        latest = h.force
        let n = max(1, Int((h.force * Double(maxDots)).rounded()))
        let rise = easeOutBack(age / 0.16), flash = exp(-age / 0.3)
        let a = 0.35 + 0.55 * h.force + 0.35 * flash
        for k in 0..<Int(Double(n) * clamp(rise, 0, 1.2)) {
            for col in 0..<3 {
                dot(c, x + CGFloat(col) * pitch, base - CGFloat(k + 1) * pitch, 4 + 1.2 * CGFloat(flash), CGFloat(a))
            }
        }
    }
    if let f = latest {
        let label = f < 0.4 ? "light tap  ·  quieter, duller" : f < 0.75 ? "normal" : "firm hit  ·  louder, brighter"
        text(c, label, font(mono, 30), f < 0.75 ? ink2 : ink(), x: left, y: 980)
        text(c, String(format: "force %.2f", f), font(mono, 30), ink3, x: right, y: 980, align: .right)
    }
}

func scenePacks(_ c: CGContext, _ t: Double) {
    let idx = min(allPacks.count - 1, max(0, Int((t - packStart) / packStep)))
    let cur = allPacks[idx]
    let since = t - (packStart + Double(idx) * packStep)
    eyebrow(c, "SEVEN PACKS", y: 170)
    text(c, "Seven real", font(heavy, 96), ink(), x: 160, y: 280)
    text(c, "recordings.", font(heavy, 96), ink(), x: 160, y: 380)
    for (i, p) in allPacks.enumerated() {
        let y = 500 + CGFloat(i) * 56
        let on = i == idx
        if on { dot(c, 172, y - 11, 7, 1) }
        let w = text(c, p.short, font(mono, 32), on ? ink() : ink(0.4), x: 200, y: y)
        text(c, p.kind, font(mono, 18), on ? ink3 : ink(0.25), x: 200 + w + 18, y: y - 2, kern: 2)
    }

    // the menu bar popover (same mock-up as the website)
    let x0: CGFloat = 1130, y0: CGFloat = 180, w: CGFloat = 600, h: CGFloat = 690
    let box = CGRect(x: x0, y: y0, width: w, height: h)
    c.setFillColor(panel); c.addPath(roundRect(c, box, 24)); c.fillPath()
    c.setStrokeColor(ink(0.16)); c.setLineWidth(1.5); c.addPath(roundRect(c, box, 24)); c.strokePath()
    text(c, "thock", font(heavy, 34), ink(), x: x0 + 32, y: y0 + 62)
    dot(c, x0 + w - 40, y0 + 50, 7, 1)
    c.setFillColor(ink(0.1)); c.fill(CGRect(x: x0, y: y0 + 92, width: w, height: 1.5))

    text(c, "SOUND", font(mono, 18), ink3, x: x0 + 32, y: y0 + 146, kern: 2)
    let sel = CGRect(x: x0 + 32, y: y0 + 164, width: w - 64, height: 62)
    let flash = exp(-since / 0.35)
    c.setStrokeColor(ink(0.24 + 0.6 * flash)); c.setLineWidth(1.5); c.addPath(roundRect(c, sel, 12)); c.strokePath()
    text(c, cur.full, font(mono, 27), ink(), x: sel.minX + 22, y: sel.minY + 41)
    c.setFillColor(ink(0.8))
    c.move(to: CGPoint(x: sel.maxX - 38, y: sel.midY - 5)); c.addLine(to: CGPoint(x: sel.maxX - 22, y: sel.midY - 5))
    c.addLine(to: CGPoint(x: sel.maxX - 30, y: sel.midY + 5)); c.closePath(); c.fillPath()

    func meter(_ label: String, _ value: String, _ frac: Double, _ y: CGFloat) {
        text(c, label, font(mono, 18), ink3, x: x0 + 32, y: y, kern: 2)
        text(c, value, font(mono, 22), ink2, x: x0 + w - 32, y: y, align: .right)
        let n = 30, span = w - 64
        for i in 0..<n {
            let on = Double(i) < frac * Double(n)
            dot(c, x0 + 32 + 5 + CGFloat(i) * (span - 10) / CGFloat(n - 1), y + 30, on ? 5.5 : 4.5, on ? 0.95 : 0.16)
        }
    }
    meter("VOLUME", "62 %", 0.62, y0 + 290)
    meter("KEY FORCE", "firm", 0.74, y0 + 380)
    let toggles = [("Key-release sounds", true), ("Trackpad clicks", true), ("Launch at login", false)]
    for (i, tg) in toggles.enumerated() {
        let y = y0 + 480 + CGFloat(i) * 50
        text(c, tg.0, font(mono, 24), ink2, x: x0 + 32, y: y)
        let sw = CGRect(x: x0 + w - 32 - 56, y: y - 22, width: 56, height: 30)
        if tg.1 {
            c.setFillColor(ink(0.92)); c.addPath(roundRect(c, sw, 15)); c.fillPath()
            c.setFillColor(bg); c.fillEllipse(in: CGRect(x: sw.maxX - 27, y: sw.minY + 3, width: 24, height: 24))
        } else {
            c.setStrokeColor(ink(0.3)); c.setLineWidth(1.5); c.addPath(roundRect(c, sw, 15)); c.strokePath()
            c.setFillColor(ink3); c.fillEllipse(in: CGRect(x: sw.minX + 4, y: sw.minY + 4, width: 22, height: 22))
        }
    }
    c.setFillColor(ink(0.1)); c.fill(CGRect(x: x0, y: y0 + h - 70, width: w, height: 1.5))
    dot(c, x0 + 38, y0 + h - 34, 5, 1)
    text(c, "Active — \(cur.short)", font(mono, 22), ink3, x: x0 + 56, y: y0 + h - 26)
    text(c, "v0.7.1", font(mono, 22), ink3, x: x0 + w - 32, y: y0 + h - 26, align: .right)
}

func sceneTrackpad(_ c: CGContext, _ t: Double) {
    eyebrow(c, "TRACKPAD")
    text(c, "Clicks sound like a mouse again.", font(heavy, 84), ink(), x: 160, y: 296)
    text(c, "Real mouse recordings. Force Touch pressure sets how loud each click is.", font(mono, 26), ink3, x: 160, y: 372)
    let pad = CGRect(x: 560, y: 450, width: 800, height: 500)
    c.setStrokeColor(ink(0.22)); c.setLineWidth(1.5); c.addPath(roundRect(c, pad, 34)); c.strokePath()
    let pitch: CGFloat = 16
    let nx = Int((pad.width - 40) / pitch), ny = Int((pad.height - 40) / pitch)
    let ox = pad.minX + (pad.width - CGFloat(nx - 1) * pitch) / 2, oy = pad.minY + (pad.height - CGFloat(ny - 1) * pitch) / 2
    for iy in 0..<ny { for ix in 0..<nx {
        let x = ox + CGFloat(ix) * pitch, y = oy + CGFloat(iy) * pitch
        var boost = 0.0
        for k in clicks where k.t <= t && t - k.t < 1.2 {
            let age = t - k.t
            let cx = pad.minX + CGFloat(k.x) * pad.width, cy = pad.minY + CGFloat(k.y) * pad.height
            let d = Double(hypot(x - cx, y - cy)), ring = 30 + age * 520
            boost = max(boost, k.force * exp(-pow((d - ring) / 26, 2)) * (1 - age / 1.2))
            boost = max(boost, k.force * exp(-d / 24) * exp(-age / 0.25))
        }
        dot(c, x, y, 2.2 + 2.4 * CGFloat(boost), 0.1 + 0.9 * CGFloat(boost))
    } }
    // pointer glides to each click
    var px = 0.2, py = 0.3
    for (i, k) in clicks.enumerated() {
        let prev = i == 0 ? (t: 25.1, x: 0.2, y: 0.3) : (t: clicks[i - 1].t, x: clicks[i - 1].x, y: clicks[i - 1].y)
        if t >= prev.t {
            let e = smooth((t - prev.t - 0.05) / max(0.1, k.t - prev.t - 0.12))
            px = prev.x + (k.x - prev.x) * e; py = prev.y + (k.y - prev.y) * e
        }
    }
    let cx = pad.minX + CGFloat(px) * pad.width, cy = pad.minY + CGFloat(py) * pad.height
    let arrow = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 30), (8, 23), (13, 35), (18, 33), (13, 21), (23, 21)]
    arrow.move(to: CGPoint(x: cx, y: cy))
    for p in pts.dropFirst() { arrow.addLine(to: CGPoint(x: cx + p.0 * 1.3, y: cy + p.1 * 1.3)) }
    arrow.closeSubpath()
    c.addPath(arrow); c.setFillColor(ink()); c.fillPath()
    c.addPath(arrow); c.setStrokeColor(bg); c.setLineWidth(2.5); c.strokePath()
    if let k = clicks.last(where: { $0.t <= t }), t - k.t < 0.9 {
        c.saveGState(); c.setAlpha(CGFloat(1 - (t - k.t) / 0.9))
        text(c, k.force < 0.5 ? "light click" : "firm click", font(mono, 26), k.force < 0.5 ? ink2 : ink(), x: cx + 44, y: cy + 60)
        c.restoreGState()
    }
}

func sceneOutro(_ c: CGContext, _ t: Double) {
    let center = CGPoint(x: 960, y: 395)
    for d in outroMark {
        let delay = Double(hypot(d.x - center.x, d.y - center.y)) / 2600
        let age = t - outroHit - delay
        guard age >= 0 else { continue }
        let flash = exp(-age / 0.35)
        dot(c, d.x, d.y, d.r * CGFloat(easeOutBack(age / 0.25)) * CGFloat(1 + 0.2 * flash), d.a + (1 - d.a) * CGFloat(flash))
    }
    c.saveGState(); c.setAlpha(CGFloat(smooth((t - 29.5) / 0.6)))
    text(c, "Free  ·  open source  ·  no account  ·  macOS 13+", font(mono, 32), ink2, x: 960, y: 650, align: .center)
    c.restoreGState()
    c.saveGState(); c.setAlpha(CGFloat(smooth((t - 29.9) / 0.6)))
    text(c, "thock-ecru.vercel.app", font(bold, 52), ink(), x: 960, y: 760, align: .center)
    text(c, "Nothing you type leaves your Mac.", font(mono, 26), ink3, x: 960, y: 830, align: .center)
    c.restoreGState()
}

let scenes: [(a: Double, b: Double, draw: (CGContext, Double) -> Void)] = [
    (0, 4.3, sceneIntro), (4.3, 11.3, sceneTyping), (11.3, 18.2, sceneForce),
    (18.2, 25.0, scenePacks), (25.0, 28.6, sceneTrackpad), (28.6, total, sceneOutro),
]
func render(_ c: CGContext, _ t: Double) {
    c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for s in scenes where t >= s.a && t < s.b {
        c.saveGState()
        c.setAlpha(CGFloat(envelope(t, s.a, s.b, s.a == 0 ? 0.01 : 0.35, s.b == total ? 0.8 : 0.35)))
        s.draw(c, t)
        c.restoreGState()
    }
}
func makeContext(_ data: UnsafeMutableRawPointer?, _ bytesPerRow: Int) -> CGContext {
    let c = CGContext(data: data, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: CGFloat(H)); c.scaleBy(x: 1, y: -1)
    return c
}

// MARK: - Poster frame

if let posterPath {
    let c = makeContext(nil, 0)
    render(c, 31.2)
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: posterPath) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
}

// MARK: - Encode

try? FileManager.default.removeItem(atPath: outPath)
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = try! AVAssetWriter(outputURL: URL(fileURLWithPath: outPath), fileType: .mp4)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 16_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: FPS * 2,
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
vIn.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
])
aIn.expectsMediaDataInRealTime = false
writer.add(vIn); writer.add(aIn)
guard writer.startWriting() else { fatalError("writer: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(mSampleRate: Double(SR), mFormatID: kAudioFormatLinearPCM,
                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                       mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
var audioFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                               magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
func audioChunk(_ start: Int, _ n: Int) -> CMSampleBuffer {
    var inter = [Float](repeating: 0, count: n * 2)
    for i in 0..<n { let v = start + i < mix.count ? mix[start + i] : 0; inter[2 * i] = v; inter[2 * i + 1] = v }
    let bytes = n * 8
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                       blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                       dataLength: bytes, flags: 0, blockBufferOut: &block)
    inter.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block!,
                                                         formatDescription: audioFormat!, sampleCount: n,
                                                         presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(SR)),
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

let frames = Int(total * Double(FPS)), perFrame = SR / FPS
var vf = 0, af = 0
while vf < frames || af < frames {
    var progressed = false
    if vf < frames && vIn.isReadyForMoreMediaData {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        render(makeContext(CVPixelBufferGetBaseAddress(pb!), CVPixelBufferGetBytesPerRow(pb!)), Double(vf) / Double(FPS))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(vf), timescale: CMTimeScale(FPS)))
        vf += 1; progressed = true
        if vf == frames { vIn.markAsFinished() }
    }
    if af < frames && aIn.isReadyForMoreMediaData {
        aIn.append(audioChunk(af * perFrame, perFrame))
        af += 1; progressed = true
        if af == frames { aIn.markAsFinished() }
    }
    if !progressed { usleep(500) }
}
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("writer: \(String(describing: writer.error))") }
print("wrote \(outPath): \(W)x\(H) \(FPS) fps, \(total) s")
