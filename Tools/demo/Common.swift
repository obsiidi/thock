import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Shared constants and helpers for the demo video.

let W = 1920, H = 1080, FPS = 30, SR = 48_000
let BPM = 104.0
let beat = 60 / BPM
let bar = beat * 4
/// Start time of bar `n` (1-based), plus `b` beats.
func at(_ n: Int, _ b: Double = 0) -> Double { Double(n - 1) * bar + b * beat }
let total = at(16) + 0.2

struct RNG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}
var rng = RNG(s: 11)

func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, v)) }
func smooth(_ v: Double) -> Double { let x = clamp(v); return x * x * (3 - 2 * x) }
func smoother(_ v: Double) -> Double { let x = clamp(v); return x * x * x * (x * (x * 6 - 15) + 10) }
func easeOutCubic(_ v: Double) -> Double { let x = 1 - clamp(v); return 1 - x * x * x }
func easeOutBack(_ v: Double) -> Double { let x = clamp(v) - 1; return 1 + 2.2 * x * x * x + 1.2 * x * x }
func mixd(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
/// 0 before `a`, 1 inside, fading over `f` at both ends of [a, b].
func window(_ t: Double, _ a: Double, _ b: Double, _ f: Double = 0.3) -> Double {
    smooth((t - a) / f) * smooth((b - t) / f)
}

// Site colour tokens
func ink(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: 237 / 255, green: 237 / 255, blue: 231 / 255, alpha: a) }
let ink2 = CGColor(srgbRed: 201 / 255, green: 201 / 255, blue: 194 / 255, alpha: 1)
let ink3 = CGColor(srgbRed: 154 / 255, green: 154 / 255, blue: 146 / 255, alpha: 1)
func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Fonts: the site's own (OFL) plus the system UI font for the macOS screen.
func registerFonts() {
    for f in ["archivo-latin.woff2", "jetbrains-mono-latin.woff2"] {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "site/fonts/" + f) as CFURL, .process, nil)
    }
}
func font(_ name: String, _ size: CGFloat) -> CTFont {
    let f = CTFontCreateWithName(name as CFString, size, nil)
    precondition(CTFontCopyPostScriptName(f) as String == name, "font \(name) missing: run from the repo root")
    return f
}
func uiFont(_ size: CGFloat, bold: Bool = false) -> CTFont {
    let f = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    return f
}
let heavy = "ArchivoRoman-ExtraBold", bold = "ArchivoRoman-Bold", mono = "JetBrainsMono-Regular"

enum Align { case left, center, right }
func line(_ s: String, _ f: CTFont, _ color: CGColor, kern: CGFloat = 0) -> CTLine {
    var attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if kern != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
}
func width(_ s: String, _ f: CTFont, kern: CGFloat = 0) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line(s, f, gray(1), kern: kern), nil, nil, nil))
}
/// Draws one line of text in a top-left (flipped) context at baseline `y`.
@discardableResult
func text(_ c: CGContext, _ s: String, _ f: CTFont, _ color: CGColor, x: CGFloat, y: CGFloat,
          align: Align = .left, kern: CGFloat = 0) -> CGFloat {
    let l = line(s, f, color, kern: kern)
    let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    let x0 = align == .left ? x : align == .center ? x - w / 2 : x - w
    c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    c.textPosition = CGPoint(x: x0, y: y)
    CTLineDraw(l, c)
    return w
}
func dot(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a: CGFloat) {
    guard r > 0.05, a > 0.004 else { return }
    c.setFillColor(ink(min(1, a)))
    c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(rad, r.width / 2), cornerHeight: min(rad, r.height / 2), transform: nil)
}
/// Bitmap context with a top-left origin.
func canvas(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
    let c = CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: srgb,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
    return c
}
func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("missing \(path)") }
    return img
}
/// Draws an image upright into a flipped context.
func draw(_ c: CGContext, _ img: CGImage, in r: CGRect, alpha: CGFloat = 1) {
    c.saveGState()
    c.setAlpha(alpha)
    c.translateBy(x: r.minX, y: r.maxY); c.scaleBy(x: 1, y: -1)
    c.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    c.restoreGState()
}

// Dot wordmark like the site: text rendered to a bitmap, coverage sampled on a grid.
struct WDot { let x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat, letter: Int }
func wordmark(_ word: String, box: CGRect, step: CGFloat) -> [WDot] {
    let S: CGFloat = 2
    let w = Int(box.width * S), h = Int(box.height * S)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    func mk(_ fs: CGFloat) -> CTLine { line(word, font(heavy, fs), CGColor(gray: 1, alpha: 1), kern: fs * 0.01) }
    let probe = CTLineGetBoundsWithOptions(mk(100), .useGlyphPathBounds)
    let fs = min(CGFloat(w) * 0.9 / probe.width * 100, CGFloat(h) * 0.95 / probe.height * 100)
    let l = mk(fs)
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
