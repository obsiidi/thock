// Tools/dotart.swift — renders photos in the dot-matrix style of site/portrait.png.
// site/bust.png:
//   swift Tools/dotart.swift IN.webp site/bust.png --crop 14,2,1174,1172 --patch 1052,907,122,116,112 \
//     --patch 1052,1039,118,118,112 --width 880 --pitch 6.5 --black 0.15 --wp 0.6 --gamma 0.8 --contrast 1.1 --sharpen 1.5 --white 1.0
import CoreGraphics
import Foundation
import ImageIO
// Turns a picture into the dot-matrix look of the David artwork:
// round dots on a square lattice, brightness as ordered-dither density,
// a second half-offset lattice fills in highlights. White dots on a
// transparent background (alpha = brightness).
//
// bitmap IN OUT --crop x,y,w,h --patch x,y,w,h[,dy] ... --width PX --pitch P --gamma G --contrast C
var a = Array(CommandLine.arguments.dropFirst())
let inPath = a.removeFirst(), outPath = a.removeFirst()
var crop: CGRect?; var patches: [(CGRect, Int)] = []
var outW = 880; var pitch = 6.5; var gamma = 1.4; var contrast = 1.15; var lift = 0.0
var sharpen = 0.9; var white = 0.9; var black = 0.0; var whitePoint = 1.0
while !a.isEmpty {
    let k = a.removeFirst(), v = a.removeFirst()
    let n = v.split(separator: ",").compactMap { Double($0) }
    switch k {
    case "--crop": crop = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    case "--patch": patches.append((CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), n.count > 4 ? Int(n[4]) : 110))
    case "--width": outW = Int(v)!
    case "--pitch": pitch = Double(v)!
    case "--gamma": gamma = Double(v)!
    case "--contrast": contrast = Double(v)!
    case "--lift": lift = Double(v)!
    case "--sharpen": sharpen = Double(v)!
    case "--white": white = Double(v)!
    case "--black": black = Double(v)!
    case "--wp": whitePoint = Double(v)!
    default: fatalError("unknown \(k)")
    }
}
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil)!
let full = CGImageSourceCreateImageAtIndex(src, 0, nil)!
// grayscale copy of the whole screenshot, patches filled from above
let fw = full.width, fh = full.height
let g = CGContext(data: nil, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
g.draw(full, in: CGRect(x: 0, y: 0, width: fw, height: fh))
let gp = g.data!.assumingMemoryBound(to: UInt8.self)
for (r, dy) in patches {       // top-left origin; copy texture from dy pixels above
    for y in Int(r.minY)..<min(fh, Int(r.maxY)) {
        for x in Int(r.minX)..<min(fw, Int(r.maxX)) { gp[y * fw + x] = gp[max(0, y - dy) * fw + x] }
    }
}
let cleaned = g.makeImage()!
let c = crop ?? CGRect(x: 0, y: 0, width: fw, height: fh)
let art = cleaned.cropping(to: c)!
let outH = Int((Double(outW) * c.height / c.width).rounded())
let cols = Int(Double(outW) / pitch), rows = Int(Double(outH) / pitch)
let ox = (Double(outW) - Double(cols - 1) * pitch) / 2, oy = (Double(outH) - Double(rows - 1) * pitch) / 2
// area-average the art onto a 2x lattice (primary + half-offset samples)
func sampleGrid(_ cw: Int, _ ch: Int) -> [Double] {
    let s = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    s.interpolationQuality = .high
    s.draw(art, in: CGRect(x: 0, y: 0, width: cw, height: ch))
    let p = s.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<(cw * ch)).map { Double(p[$0]) / 255 }
}
let fine = sampleGrid(cols * 2, rows * 2)          // index (2r+j)*(2cols) + (2c+i)
func lum(_ fx: Int, _ fy: Int) -> Double {
    let x = min(cols * 2 - 1, max(0, fx)), y = min(rows * 2 - 1, max(0, fy))
    var v = fine[y * cols * 2 + x]
    v = (v - 0.5) * contrast + 0.5 + lift
    return pow(min(1, max(0, v)), gamma)
}
let bayer: [Double] = [0,32,8,40,2,34,10,42, 48,16,56,24,50,18,58,26, 12,44,4,36,14,46,6,38, 60,28,52,20,62,30,54,22,
                       3,35,11,43,1,33,9,41, 51,19,59,27,49,17,57,25, 15,47,7,39,13,45,5,37, 63,31,55,23,61,29,53,21].map { ($0 + 0.5) / 64 }
var alpha = [Double](repeating: 0, count: outW * outH)
func dot(_ cx: Double, _ cy: Double, _ r: Double, _ level: Double) {
    let x0 = max(0, Int(cx - r - 1)), x1 = min(outW - 1, Int(cx + r + 1))
    let y0 = max(0, Int(cy - r - 1)), y1 = min(outH - 1, Int(cy + r + 1))
    if x0 > x1 || y0 > y1 { return }
    for y in y0...y1 { for x in x0...x1 {
        let d = ((Double(x) + 0.5 - cx) * (Double(x) + 0.5 - cx) + (Double(y) + 0.5 - cy) * (Double(y) + 0.5 - cy)).squareRoot()
        let cov = min(1, max(0, r + 0.5 - d)) * level
        if cov > alpha[y * outW + x] { alpha[y * outW + x] = cov }
    } }
}
// Tone per lattice cell: unsharp mask on the fine grid (keeps chainmail and
// engraving), contrast, gamma, highlight compression.
let fw2 = cols * 2, fh2 = rows * 2
func raw(_ x: Int, _ y: Int) -> Double { fine[min(fh2 - 1, max(0, y)) * fw2 + min(fw2 - 1, max(0, x))] }
func toned(_ fx: Int, _ fy: Int) -> Double {
    var blur = 0.0
    for dy in -2...2 { for dx in -2...2 { blur += raw(fx + dx, fy + dy) } }
    blur /= 25
    var v = raw(fx, fy) + sharpen * (raw(fx, fy) - blur)
    // black point: everything at or below it is pure background
    v = (v - black) / max(0.01, whitePoint - black)
    if v <= 0 { return 0 }
    v = (v - 0.5) * contrast + 0.5 + lift
    return pow(min(1, max(0, v)), gamma) * white
}
// Floyd–Steinberg error diffusion on the primary lattice (serpentine)
var level = [Double](repeating: 0, count: cols * rows)
for row in 0..<rows { for col in 0..<cols { level[row * cols + col] = toned(col * 2, row * 2) } }
var onGrid = [Bool](repeating: false, count: cols * rows)
for row in 0..<rows {
    let ltr = row % 2 == 0
    for k in 0..<cols {
        let col = ltr ? k : cols - 1 - k
        let i = row * cols + col
        let v = level[i]
        // very dark cells stay empty and do not spread their error, so the
        // background is clean black like the reference artwork
        if toned(col * 2, row * 2) < 0.04 { continue }
        let q: Double = v >= 0.5 ? 1 : 0
        onGrid[i] = q == 1
        let err = v - q
        let dir = ltr ? 1 : -1
        func add(_ c: Int, _ r: Int, _ w: Double) {
            if c >= 0 && c < cols && r < rows { level[r * cols + c] += err * w }
        }
        add(col + dir, row, 7.0 / 16); add(col - dir, row + 1, 3.0 / 16)
        add(col, row + 1, 5.0 / 16); add(col + dir, row + 1, 1.0 / 16)
    }
}
var on = 0
let r = pitch * 0.25
for row in 0..<rows { for col in 0..<cols {
    let v = toned(col * 2, row * 2)
    if onGrid[row * cols + col] { dot(ox + Double(col) * pitch, oy + Double(row) * pitch, r, 0.7 + 0.3 * min(1, v / white)); on += 1 }
    // half-offset lattice: only in strong highlights
    let v2 = toned(col * 2 + 1, row * 2 + 1)
    if v2 > (0.74 + 0.26 * bayer[((row + 4) % 8) * 8 + ((col + 4) % 8)]) * white {
        dot(ox + (Double(col) + 0.5) * pitch, oy + (Double(row) + 0.5) * pitch, r * 0.9, 0.62 + 0.3 * min(1, v2 / white))
    }
} }
let out = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let op = out.data!.assumingMemoryBound(to: UInt8.self)
for i in 0..<(outW * outH) { let v = UInt8(min(255, alpha[i] * 255)); op[i*4] = v; op[i*4+1] = v; op[i*4+2] = v; op[i*4+3] = v }
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, out.makeImage()!, nil); CGImageDestinationFinalize(d)
print("wrote \(outPath) \(outW)x\(outH) lattice \(cols)x\(rows) dots=\(on)")
