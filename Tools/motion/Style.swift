import CoreGraphics
import CoreText
import Foundation

// Look and motion vocabulary of the light video: warm cream, near-black ink,
// orange and blue accents; springs with overshoot, words that jump in.

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
enum P {
    static let bg: UInt32 = 0xF5F3EE, ink: UInt32 = 0x141414, orange: UInt32 = 0xFF5A1F, blue: UInt32 = 0x3B6CF6
    static let card: UInt32 = 0xEAE6DC, line: UInt32 = 0xD9D4C8, mute: UInt32 = 0x8A857B, white: UInt32 = 0xFFFFFF
}
func mixColor(_ a: UInt32, _ b: UInt32, _ t: Double, _ alpha: CGFloat = 1) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 255) / 255 }
    let k = clamp(t)
    return CGColor(srgbRed: CGFloat(ch(a, 16) + (ch(b, 16) - ch(a, 16)) * k), green: CGFloat(ch(a, 8) + (ch(b, 8) - ch(a, 8)) * k),
                   blue: CGFloat(ch(a, 0) + (ch(b, 0) - ch(a, 0)) * k), alpha: alpha)
}

// MARK: motion curves

/// Damped spring from 0 to 1 starting at `t0`; overshoots, then settles.
func spring(_ t: Double, _ t0: Double, freq: Double = 2.4, damping: Double = 0.42) -> Double {
    let x = t - t0
    if x <= 0 { return 0 }
    let w = 2 * Double.pi * freq, zeta = damping, wd = w * (1 - zeta * zeta).squareRoot()
    return 1 - exp(-zeta * w * x) * (cos(wd * x) + zeta * w / wd * sin(wd * x))
}
func easeInOut(_ v: Double) -> Double { let x = clamp(v); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeIn(_ v: Double) -> Double { let x = clamp(v); return x * x * x }
func lerpR(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    let k = CGFloat(t)
    return CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                  width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
}
func lerpC(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

// MARK: kinetic type

/// Words that spring up one after another from their baseline.
func springWords(_ c: CGContext, _ words: [String], _ f: CTFont, _ color: CGColor, x: CGFloat, y: CGFloat,
                 starts: [Double], t: Double, out: Double? = nil, highlight: [Int: CGColor] = [:]) {
    var cx = x
    let space = width(" ", f)
    for (i, w) in words.enumerated() {
        let ww = width(w, f)
        let s = spring(t, starts[min(i, starts.count - 1)], freq: 2.2, damping: 0.5)
        var dy = CGFloat(1 - s) * CTFontGetSize(f) * 0.7
        var a = CGFloat(clamp(s * 3))
        if let o = out {
            let e = easeInOut((t - o - Double(i) * 0.03) / 0.3)
            dy -= CGFloat(e) * CTFontGetSize(f) * 0.8; a *= CGFloat(1 - e)
        }
        if a > 0.01 {
            c.saveGState()
            c.setAlpha(a)
            let sc = CGFloat(0.7 + 0.3 * min(1.2, s))
            c.translateBy(x: cx, y: y + dy); c.scaleBy(x: sc, y: sc)
            text(c, w, f, highlight[i] ?? color, x: 0, y: 0)
            c.restoreGState()
        }
        cx += ww + space
    }
}
/// Characters typed one by one, each popping in; returns the caret x.
@discardableResult
func typedLine(_ c: CGContext, _ s: String, _ f: CTFont, _ color: CGColor, x: CGFloat, y: CGFloat,
               times: [Double], t: Double, caret: Bool = true) -> CGFloat {
    var cx = x
    for (i, ch) in s.enumerated() where i < times.count && t >= times[i] {
        let str = String(ch)
        let w = width(str, f)
        let k = spring(t, times[i], freq: 3, damping: 0.45)
        c.saveGState()
        c.translateBy(x: cx + w / 2, y: y); c.scaleBy(x: CGFloat(0.4 + 0.6 * k), y: CGFloat(0.4 + 0.6 * k))
        text(c, str, f, color, x: -w / 2, y: 0)
        c.restoreGState()
        cx += w
    }
    if caret && (Int(t * 2.2) % 2 == 0 || times.contains { abs($0 - t) < 0.3 }) {
        c.setFillColor(rgb(P.orange))
        c.fill(CGRect(x: cx + 6, y: y - CTFontGetSize(f) * 0.74, width: max(4, CTFontGetSize(f) * 0.07), height: CTFontGetSize(f) * 0.86))
    }
    return cx
}
func eyebrowText(_ c: CGContext, _ s: String, x: CGFloat, y: CGFloat, color: CGColor = rgb(P.mute)) {
    text(c, s, font(mono, 22), color, x: x, y: y, kern: 4.4)
}

// MARK: shapes

func fillRound(_ c: CGContext, _ r: CGRect, _ rad: CGFloat, _ col: CGColor) {
    c.setFillColor(col); c.addPath(rounded(r, rad)); c.fillPath()
}
func strokeRound(_ c: CGContext, _ r: CGRect, _ rad: CGFloat, _ col: CGColor, _ w: CGFloat) {
    c.setStrokeColor(col); c.setLineWidth(w); c.addPath(rounded(r, rad)); c.strokePath()
}
func softShadow(_ c: CGContext, _ r: CGRect, _ rad: CGFloat, blur: CGFloat = 40, dy: CGFloat = 18, a: CGFloat = 0.14) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: rgb(0x3A3020, a))
    c.setFillColor(rgb(P.white)); c.addPath(rounded(r, rad)); c.fillPath()
    c.restoreGState()
}
/// Expanding "sound" rings from a point.
func rings(_ c: CGContext, at p: CGPoint, age: Double, size: CGFloat, color: CGColor, count: Int = 2) {
    for k in 0..<count {
        let a = age - Double(k) * 0.08
        guard a > 0 && a < 0.6 else { continue }
        let e = easeOutCubic(a / 0.6)
        let r = size * CGFloat(0.3 + 0.9 * e)
        c.setStrokeColor(color.copy(alpha: CGFloat(1 - e) * 0.9)!)
        c.setLineWidth(CGFloat(8 * (1 - e)) + 1.5)
        c.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
}
/// Partially drawn outline: `k` of the path's length (dash trick).
func drawOn(_ c: CGContext, _ path: CGPath, length: CGFloat, k: Double, color: CGColor, width w: CGFloat) {
    guard k > 0 else { return }
    c.saveGState()
    c.setStrokeColor(color); c.setLineWidth(w); c.setLineCap(.round)
    if k < 1 { c.setLineDash(phase: 0, lengths: [length * CGFloat(k), length * 2]) }
    c.addPath(path); c.strokePath()
    c.restoreGState()
}
func perimeter(_ r: CGRect, _ rad: CGFloat) -> CGFloat { 2 * (r.width + r.height) - (8 - 2 * .pi) * rad }

/// A light keycap: white face on a darker base; `press` 0…1 sinks it, `flash` tints it.
func keycap(_ c: CGContext, _ r: CGRect, label: String, press: Double, flash: Double, flashColor: UInt32 = P.orange,
            labelSize: CGFloat? = nil, radius: CGFloat? = nil) {
    let depth = r.height * 0.07, rad = radius ?? r.height * 0.16
    let base = CGRect(x: r.minX, y: r.minY + depth, width: r.width, height: r.height - depth)
    fillRound(c, base, rad, rgb(P.line))
    let sink = CGFloat(press) * depth * 0.85
    let face = CGRect(x: r.minX, y: r.minY + sink, width: r.width, height: r.height - depth)
    fillRound(c, face, rad, mixColor(P.white, flashColor, flash))
    strokeRound(c, face, rad, rgb(P.ink, 0.07), 1.5)
    if !label.isEmpty {
        let fs = labelSize ?? min(face.height * 0.36, 40)
        let f = label.count > 1 ? font(mono, fs * 0.55) : font(bold, fs)
        let col = mixColor(P.ink, P.white, flash)
        if label.count > 1 {
            text(c, label, f, col.copy(alpha: 0.75)!, x: face.minX + face.height * 0.16, y: face.maxY - face.height * 0.18)
        } else {
            text(c, label, f, col, x: face.midX, y: face.midY + fs * 0.36, align: .center)
        }
    }
}

/// macOS pointer arrow, drawn at `p` with scale `k`.
func pointer(_ c: CGContext, _ p: CGPoint, _ k: CGFloat) {
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 30), (8, 23), (13, 35), (18, 33), (13, 21), (23, 21)]
    let path = CGMutablePath()
    path.move(to: p)
    for q in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + q.0 * k, y: p.y + q.1 * k)) }
    path.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 3 * k), blur: 6 * k, color: rgb(0, 0.35))
    c.addPath(path); c.setFillColor(rgb(P.ink)); c.fillPath()
    c.restoreGState()
    c.addPath(path); c.setStrokeColor(rgb(P.white)); c.setLineWidth(1.6 * k); c.strokePath()
    c.addPath(path); c.setFillColor(rgb(P.ink)); c.fillPath()
}

/// Small keyboard glyph like the menu bar icon.
func keyboardGlyph(_ c: CGContext, _ r: CGRect, _ col: CGColor) {
    c.setStrokeColor(col); c.setLineWidth(max(1.2, r.height * 0.09))
    c.addPath(rounded(r, r.height * 0.18)); c.strokePath()
    c.setFillColor(col)
    let rows = [5, 5, 3]
    for (ri, n) in rows.enumerated() {
        let y = r.minY + r.height * (0.3 + 0.2 * CGFloat(ri))
        let span = r.width * (ri == 2 ? 0.46 : 0.7), x0 = r.midX - span / 2
        for k in 0..<n {
            let x = x0 + span * CGFloat(k) / CGFloat(max(1, n - 1))
            let d = r.height * (ri == 2 && n == 3 && k == 1 ? 0.1 : 0.1)
            if ri == 2 && k == 1 {
                c.fill(CGRect(x: x - r.width * 0.12, y: y - d / 2, width: r.width * 0.24, height: d))
            } else {
                c.fill(CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
            }
        }
    }
}
