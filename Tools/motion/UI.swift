import CoreGraphics
import CoreText
import Foundation

// The app's popover, its pack menu and the stats window, redrawn as vectors in
// macOS light mode (same rows, labels and numbers as the real app) so every
// control can move: switches flip, sliders slide, numbers count, bars grow.
// All sizes are in points; `s` scales to video pixels.

let uiText = rgb(0x1D1D1F), uiSecondary = rgb(0x86868B), uiLink = rgb(0x2F6FEB)
let uiBlue: UInt32 = 0x3B7BF6

func sys(_ size: CGFloat, _ s: CGFloat, bold: Bool = false) -> CTFont { uiFont(size * s, bold: bold) }

func toggle(_ c: CGContext, x: CGFloat, y: CGFloat, on: Double, s: CGFloat) {
    let r = CGRect(x: x * s, y: y * s, width: 32 * s, height: 18 * s)
    fillRound(c, r, 9 * s, mixColor(0xE3E3E6, uiBlue, on))
    let kx = r.minX + (2 + CGFloat(on) * 14) * s
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 2 * s, color: rgb(0, 0.25))
    c.setFillColor(rgb(P.white)); c.fillEllipse(in: CGRect(x: kx, y: r.minY + 2 * s, width: 14 * s, height: 14 * s))
    c.restoreGState()
}
func slider(_ c: CGContext, x0: CGFloat, x1: CGFloat, y: CGFloat, value: Double, s: CGFloat, enabled: Bool = true) {
    let track = CGRect(x: x0 * s, y: (y - 2) * s, width: (x1 - x0) * s, height: 4 * s)
    fillRound(c, track, 2 * s, rgb(0xD5D5D8))
    let fx = (x0 + (x1 - x0) * CGFloat(value)) * s
    if enabled { fillRound(c, CGRect(x: track.minX, y: track.minY, width: fx - track.minX, height: track.height), 2 * s, rgb(uiBlue)) }
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 1 * s), blur: 3 * s, color: rgb(0, 0.3))
    c.setFillColor(rgb(P.white)); c.fillEllipse(in: CGRect(x: fx - 9 * s, y: (y - 9) * s, width: 18 * s, height: 18 * s))
    c.restoreGState()
}
func picker(_ c: CGContext, _ r: CGRect, _ label: String, s: CGFloat, enabled: Bool = true) {
    let rr = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    fillRound(c, rr, 5 * s, rgb(P.white))
    strokeRound(c, rr, 5 * s, rgb(0, 0.13), 1 * s)
    let f = sys(13, s)
    var shown = label
    while width(shown, f) > rr.width - 30 * s && shown.count > 3 { shown = String(shown.dropLast(2)) + "…" }
    text(c, shown, f, enabled ? uiText : uiSecondary, x: rr.minX + 9 * s, y: rr.midY + 4.5 * s)
    // up/down chevrons
    c.setStrokeColor(enabled ? uiText : uiSecondary); c.setLineWidth(1.4 * s); c.setLineCap(.round); c.setLineJoin(.round)
    let cx = rr.maxX - 12 * s, cy = rr.midY
    c.move(to: CGPoint(x: cx - 3 * s, y: cy - 1.5 * s)); c.addLine(to: CGPoint(x: cx, y: cy - 4.5 * s)); c.addLine(to: CGPoint(x: cx + 3 * s, y: cy - 1.5 * s))
    c.move(to: CGPoint(x: cx - 3 * s, y: cy + 1.5 * s)); c.addLine(to: CGPoint(x: cx, y: cy + 4.5 * s)); c.addLine(to: CGPoint(x: cx + 3 * s, y: cy + 1.5 * s))
    c.strokePath()
}
func button(_ c: CGContext, _ r: CGRect, _ label: String, s: CGFloat, primary: Bool = false) {
    let rr = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    if !primary { c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: 0.5 * s), blur: 1 * s, color: rgb(0, 0.2)) }
    fillRound(c, rr, 6 * s, primary ? rgb(uiBlue) : rgb(P.white))
    if !primary { c.restoreGState() }
    text(c, label, sys(13, s), primary ? rgb(P.white) : uiText, x: rr.midX, y: rr.midY + 4.5 * s, align: .center)
}

// MARK: popover

struct PopState {
    var pack = topreIndex
    var on = 1.0, volume = 0.62, force = 0.0, sensitivity = 0.55
    var reveal = 1.0          // rows fade in top to bottom
}
let popSize = CGSize(width: 320, height: 366)

/// Draws the popover with its arrow tip at `tip` (video pixels).
func popover(_ c: CGContext, tip: CGPoint, st: PopState, s: CGFloat, open: Double) {
    guard open > 0.001 else { return }
    let k = CGFloat(open)
    c.saveGState()
    c.translateBy(x: tip.x, y: tip.y); c.scaleBy(x: 0.6 + 0.4 * k, y: 0.6 + 0.4 * k)
    c.setAlpha(min(1, k * 1.6))
    let w = popSize.width * s, h = popSize.height * s, arrow = 11 * s
    let body = CGRect(x: -w / 2, y: arrow, width: w, height: h)
    let shape = CGMutablePath()
    shape.addPath(rounded(body, 12 * s))
    shape.move(to: CGPoint(x: -16 * s, y: arrow)); shape.addLine(to: CGPoint(x: 0, y: 0)); shape.addLine(to: CGPoint(x: 16 * s, y: arrow))
    shape.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 14 * s), blur: 34 * s, color: rgb(0x3A3020, 0.22))
    c.setFillColor(rgb(0xF6F5F3)); c.addPath(shape); c.fillPath()
    c.restoreGState()
    c.setStrokeColor(rgb(0, 0.1)); c.setLineWidth(1 * s); c.addPath(shape); c.strokePath()
    c.translateBy(x: body.minX, y: body.minY)
    func row(_ i: Int) -> CGFloat { CGFloat(clamp(st.reveal * 11 - Double(i))) }
    func fade(_ i: Int, _ draw: () -> Void) {
        let a = row(i); guard a > 0 else { return }
        c.saveGState(); c.setAlpha(a); c.translateBy(x: 0, y: (1 - a) * 6 * s); draw(); c.restoreGState()
    }
    let f13 = sys(13, s), f11 = sys(11.5, s)
    fade(0) {
        keyboardGlyph(c, CGRect(x: 14 * s, y: 17 * s, width: 19 * s, height: 13 * s), uiText)
        text(c, "thock", sys(15, s, bold: true), uiText, x: 41 * s, y: 29 * s)
        c.setFillColor(mixColor(0xF0A742, 0x34C759, st.on)); c.fillEllipse(in: CGRect(x: 238 * s, y: 19 * s, width: 9 * s, height: 9 * s))
        toggle(c, x: 266, y: 14.5, on: st.on, s: s)
    }
    fade(1) {
        text(c, "Sound", f13, uiText, x: 14 * s, y: 61 * s)
        picker(c, CGRect(x: 62, y: 45, width: 206, height: 23), packInfos[st.pack].menuName, s: s)
        let plus = CGRect(x: 274 * s, y: 45 * s, width: 32 * s, height: 23 * s)
        fillRound(c, plus, 5 * s, rgb(P.white)); strokeRound(c, plus, 5 * s, rgb(0, 0.13), 1 * s)
        c.setStrokeColor(uiText); c.setLineWidth(1.4 * s)
        c.move(to: CGPoint(x: plus.midX - 5 * s, y: plus.midY)); c.addLine(to: CGPoint(x: plus.midX + 5 * s, y: plus.midY))
        c.move(to: CGPoint(x: plus.midX, y: plus.midY - 5 * s)); c.addLine(to: CGPoint(x: plus.midX, y: plus.midY + 5 * s)); c.strokePath()
    }
    fade(2) {
        // speaker
        c.setFillColor(uiText)
        let sp = CGMutablePath()
        sp.move(to: CGPoint(x: 15 * s, y: 81 * s)); sp.addLine(to: CGPoint(x: 18 * s, y: 81 * s)); sp.addLine(to: CGPoint(x: 23 * s, y: 76.5 * s))
        sp.addLine(to: CGPoint(x: 23 * s, y: 91.5 * s)); sp.addLine(to: CGPoint(x: 18 * s, y: 87 * s)); sp.addLine(to: CGPoint(x: 15 * s, y: 87 * s)); sp.closeSubpath()
        c.addPath(sp); c.fillPath()
        c.setStrokeColor(uiText); c.setLineWidth(1.3 * s)
        c.addArc(center: CGPoint(x: 23 * s, y: 84 * s), radius: 4.5 * s, startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false); c.strokePath()
        slider(c, x0: 36, x1: 262, y: 84, value: st.volume, s: s)
        text(c, "\(Int((st.volume * 100).rounded())) %", sys(12, s), uiText, x: 306 * s, y: 88.5 * s, align: .right)
    }
    fade(3) {
        text(c, "Key force", f13, uiText, x: 14 * s, y: 118 * s)
        toggle(c, x: 84, y: 104.5, on: st.force, s: s)
        text(c, "soft", sys(11, s), uiSecondary, x: 124 * s, y: 117 * s)
        slider(c, x0: 156, x1: 274, y: 113, value: st.sensitivity, s: s, enabled: st.force > 0.5)
        text(c, "hard", sys(11, s), uiSecondary, x: 306 * s, y: 117 * s, align: .right)
    }
    fade(4) { text(c, "Key-release sounds", f13, uiText, x: 14 * s, y: 150 * s); toggle(c, x: 146, y: 136.5, on: 1, s: s) }
    fade(5) {
        text(c, "Trackpad clicks", f13, uiText, x: 14 * s, y: 181 * s); toggle(c, x: 122, y: 167.5, on: 1, s: s)
        picker(c, CGRect(x: 162, y: 169, width: 144, height: 23), "MX Master 3S", s: s)
    }
    fade(6) { text(c, "Scroll ticks", f13, uiText, x: 14 * s, y: 211 * s); toggle(c, x: 96, y: 197.5, on: 0, s: s) }
    fade(7) { text(c, "Tip: turn on Silent clicking in Trackpad settings", sys(11, s), uiLink, x: 14 * s, y: 233 * s) }
    fade(8) { text(c, "Launch at login", f13, uiText, x: 14 * s, y: 261 * s); toggle(c, x: 122, y: 247.5, on: 1, s: s) }
    fade(9) {
        c.setFillColor(uiLink)
        for (i, hh) in [5.0, 8, 6, 10, 7].enumerated() {
            c.fill(CGRect(x: (15 + CGFloat(i) * 3.2) * s, y: (286 - hh) * s, width: 2 * s, height: CGFloat(hh) * s))
        }
        text(c, "Today 3,214 keys · 71 wpm peak · 6-day streak", f11, uiLink, x: 36 * s, y: 286 * s)
        text(c, "Active — \(packInfos[st.pack].menuName)", f11, uiSecondary, x: 14 * s, y: 309 * s)
    }
    fade(10) {
        c.setFillColor(rgb(0, 0.1)); c.fill(CGRect(x: 14 * s, y: 322 * s, width: 292 * s, height: 1 * s))
        var x = 14 * s
        x += text(c, "v0.7.1", f11, uiSecondary, x: x, y: 347 * s) + 11 * s
        for l in ["Setup", "Stats", "Packs", "Feedback"] { x += text(c, l, f11, uiLink, x: x, y: 347 * s) + 11 * s }
        button(c, CGRect(x: 266, y: 333, width: 40, height: 20), "Quit", s: s)
    }
    c.restoreGState()
}
/// Where the Sound picker sits relative to the popover tip (for the pointer).
func pickerOffset(_ s: CGFloat) -> CGPoint { CGPoint(x: (-popSize.width / 2 + 160) * s, y: (11 + 56) * s) }
func forceToggleOffset(_ s: CGFloat) -> CGPoint { CGPoint(x: (-popSize.width / 2 + 100) * s, y: (11 + 113) * s) }

/// The Sound picker's menu: the seven packs, a check at the current one, a
/// blue highlight on the hovered row.
func packMenu(_ c: CGContext, origin: CGPoint, s: CGFloat, open: Double, checked: Int, hover: Double) {
    guard open > 0.001 else { return }
    let rowH: CGFloat = 22, w: CGFloat = 250
    let h = CGFloat(menuOrder.count) * rowH + 10
    c.saveGState()
    c.translateBy(x: origin.x, y: origin.y)
    c.scaleBy(x: 1, y: CGFloat(0.85 + 0.15 * open)); c.setAlpha(CGFloat(min(1, open * 1.5)))
    let box = CGRect(x: 0, y: 0, width: w * s, height: h * s)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 26 * s, color: rgb(0x3A3020, 0.25))
    fillRound(c, box, 8 * s, rgb(0xFBFAF8))
    c.restoreGState()
    strokeRound(c, box, 8 * s, rgb(0, 0.1), 1 * s)
    // highlight glides between rows
    let hy = (5 + CGFloat(hover) * rowH) * s
    fillRound(c, CGRect(x: 5 * s, y: hy, width: (w - 10) * s, height: rowH * s), 5 * s, rgb(uiBlue))
    for (i, p) in menuOrder.enumerated() {
        let y = (5 + CGFloat(i) * rowH + 15.5) * s
        let lit = abs(Double(i) - hover) < 0.5
        let col = lit ? rgb(P.white) : uiText
        if p == checked { text(c, "✓", sys(12, s, bold: true), col, x: 12 * s, y: y) }
        text(c, packInfos[p].menuName, sys(13, s), col, x: 30 * s, y: y)
    }
    c.restoreGState()
}

// MARK: stats window

let statsSize = CGSize(width: 720, height: 670)
let daily: [Double] = [820, 1450, 1900, 0, 2650, 1900, 3050, 0, 1750, 2980, 3420, 2210, 2760, 3214]
let keyWeight: [String: Double] = [
    "E": 12.7, "T": 9.1, "A": 8.2, "O": 7.5, "I": 7.0, "N": 6.7, "S": 6.3, "H": 6.1, "R": 6.0, "D": 4.3, "L": 4.0,
    "C": 2.8, "U": 2.8, "M": 2.4, "W": 2.4, "F": 2.2, "G": 2.0, "Y": 2.0, "P": 1.9, "B": 1.5, "V": 1.0, "K": 0.8,
    "J": 0.2, "X": 0.2, "Q": 0.1, "Z": 0.1, "space": 16, "delete": 3.5, "shiftL": 2, "shiftR": 1, "return": 1.6,
    ".": 1.1, ",": 1.0, "'": 0.4, "1": 0.3, "2": 0.3, "0": 0.3, "command": 0.8, "tab": 0.3,
]

struct StatsAnim { var count = 1.0, heat = 1.0, bars = 1.0, records = 1.0 }

func statsWindow(_ c: CGContext, origin: CGPoint, s: CGFloat, a: StatsAnim, t: Double) {
    c.saveGState()
    c.translateBy(x: origin.x, y: origin.y)
    let W0 = statsSize.width * s, H0 = statsSize.height * s
    let win = CGRect(x: 0, y: 0, width: W0, height: H0)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 26 * s), blur: 50 * s, color: rgb(0x3A3020, 0.2))
    fillRound(c, win, 12 * s, rgb(0xF4F3F1))
    c.restoreGState()
    strokeRound(c, win, 12 * s, rgb(0, 0.12), 1 * s)
    for (i, col) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        c.setFillColor(rgb(UInt32(col))); c.fillEllipse(in: CGRect(x: (14 + CGFloat(i) * 20) * s, y: 14 * s, width: 12 * s, height: 12 * s))
    }
    text(c, "thock — Typing stats", sys(13, s, bold: true), rgb(0, 0.7), x: 82 * s, y: 25 * s)

    text(c, "Your typing", sys(17, s, bold: true), uiText, x: 21 * s, y: 72 * s)
    let seg = CGRect(x: 546 * s, y: 55 * s, width: 121 * s, height: 24 * s)
    fillRound(c, seg, 6 * s, rgb(0, 0.06))
    fillRound(c, CGRect(x: seg.minX, y: seg.minY, width: 60 * s, height: seg.height), 6 * s, rgb(uiBlue))
    text(c, "Today", sys(13, s), rgb(P.white), x: seg.minX + 30 * s, y: seg.midY + 4.5 * s, align: .center)
    text(c, "7 days", sys(13, s), uiText, x: seg.minX + 91 * s, y: seg.midY + 4.5 * s, align: .center)

    // tiles with numbers counting up
    let k = easeOutCubic(a.count)
    let tiles: [(String, String)] = [
        (grouped(Int(3214 * k)), "KEYSTROKES"),
        ("\(Int(71 * k))", "WPM PEAK"), ("\(Int(24 * k)) min", "TYPING TIME"), ("\(Int((6 * k).rounded(.down))) d", "STREAK"),
    ]
    for (i, tile) in tiles.enumerated() {
        let r = CGRect(x: (21 + CGFloat(i) * 172) * s, y: 97 * s, width: 159 * s, height: 70 * s)
        fillRound(c, r, 8 * s, rgb(P.white, 0.85))
        text(c, tile.0, sys(26, s, bold: true), uiText, x: r.minX + 12 * s, y: r.minY + 38 * s)
        text(c, tile.1, sys(10.5, s, bold: true), uiSecondary, x: r.minX + 12 * s, y: r.minY + 57 * s, kern: 1.2 * s)
    }

    // keyboard heatmap (US layout), filling in as a wave from the left
    let rows: [[(String, Double)]] = [
        ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { ($0, 1) } + [("delete", 1.5)],
        [("tab", 1.5)] + ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"].map { ($0, 1) },
        [("caps", 1.75)] + ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'"].map { ($0, 1) } + [("return", 1.75)],
        [("shiftL", 2.25)] + ["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"].map { ($0, 1) } + [("shiftR", 2.25)],
        [("fn", 1), ("control", 1), ("option", 1), ("command", 1.25), ("space", 5), ("command ", 1.25), ("option ", 1),
         ("←", 1), ("↑↓", 1), ("→", 1)],
    ]
    let unit: CGFloat = 605 / 14.5, top: CGFloat = 186
    let maxW = keyWeight.values.max()!
    for (ri, row) in rows.enumerated() {
        var x: CGFloat = 56
        for (label, u) in row {
            let r = CGRect(x: (x + 2.5) * s, y: (top + CGFloat(ri) * 42 + 2.5) * s, width: (CGFloat(u) * unit - 5) * s, height: 37 * s)
            let wgt = (keyWeight[label] ?? 0) / maxW
            let wave = clamp(a.heat * 1.6 - Double(x / 661))
            let v = pow(wgt, 0.55) * 0.92 * smooth(wave * 3)
            fillRound(c, r, 5 * s, rgb(P.ink, CGFloat(max(0.06, v))))
            var shown = label.trimmingCharacters(in: .whitespaces)
            shown = ["shiftL": "⇧", "shiftR": "⇧", "delete": "⌫", "return": "↩", "tab": "⇥", "caps": "⇪", "command": "⌘",
                     "option": "⌥", "control": "⌃"][shown] ?? shown
            text(c, shown, sys(11, s, bold: true), v > 0.55 ? rgb(0xF4F3F1) : rgb(P.ink, 0.72), x: r.midX, y: r.midY + 4 * s, align: .center)
            x += CGFloat(u) * unit
        }
    }

    // last 14 days
    text(c, "Last 14 days", sys(13, s, bold: true), uiText, x: 21 * s, y: 426 * s)
    let chart = CGRect(x: 58 * s, y: 440 * s, width: 385 * s, height: 118 * s)
    for (i, v) in [0, 1000, 2000, 3000, 4000].enumerated() {
        let y = chart.maxY - chart.height * CGFloat(i) / 4
        c.setFillColor(rgb(0, 0.08)); c.fill(CGRect(x: chart.minX, y: y, width: chart.width, height: 1 * s))
        text(c, grouped(v), sys(10.5, s), uiSecondary,
             x: chart.minX - 6 * s, y: y + 4 * s, align: .right)
    }
    let bw = chart.width / 14
    for (i, v) in daily.enumerated() {
        let grow = spring(a.bars * 2.2, Double(i) * 0.08, freq: 2.2, damping: 0.5)
        let hgt = chart.height * CGFloat(v / 4000 * grow)
        let r = CGRect(x: chart.minX + CGFloat(i) * bw + bw * 0.18, y: chart.maxY - hgt, width: bw * 0.64, height: hgt)
        if hgt > 0.5 { fillRound(c, r, 2 * s, i == 13 ? rgb(uiBlue) : rgb(P.ink, 0.28)) }
        text(c, "\(16 + i)", sys(10.5, s), uiSecondary, x: r.midX, y: chart.maxY + 15 * s, align: .center)
    }

    // records
    text(c, "Records", sys(13, s, bold: true), uiText, x: 467 * s, y: 426 * s)
    for (i, rec) in [("Best day", "3,420 keys"), ("Best speed", "84 wpm"), ("All time", "48,230 keys"), ("Clicks", "1,204")].enumerated() {
        let e = CGFloat(clamp(a.records * 5 - Double(i)))
        c.saveGState(); c.setAlpha(e)
        text(c, rec.0, sys(13, s), uiSecondary, x: 467 * s, y: (452 + CGFloat(i) * 21) * s)
        text(c, rec.1, sys(13, s), uiText, x: 697 * s, y: (452 + CGFloat(i) * 21) * s, align: .right)
        c.restoreGState()
    }

    text(c, "Counts only — never what you type. Stored on this Mac in ~/Library/Application Support/thock/stats.json.",
         sys(11, s), uiSecondary, x: 21 * s, y: 606 * s)
    let cb = CGRect(x: 21 * s, y: 628 * s, width: 16 * s, height: 16 * s)
    fillRound(c, cb, 4 * s, rgb(uiBlue))
    c.setStrokeColor(rgb(P.white)); c.setLineWidth(2 * s); c.setLineCap(.round); c.setLineJoin(.round)
    c.move(to: CGPoint(x: cb.minX + 4 * s, y: cb.midY)); c.addLine(to: CGPoint(x: cb.minX + 7 * s, y: cb.maxY - 4 * s))
    c.addLine(to: CGPoint(x: cb.maxX - 3.5 * s, y: cb.minY + 4 * s)); c.strokePath()
    text(c, "Keep typing stats", sys(13, s), uiText, x: 44 * s, y: 641 * s)
    button(c, CGRect(x: 160, y: 626, width: 66, height: 21), "Reset…", s: s)
    button(c, CGRect(x: 437, y: 626, width: 84, height: 21), "Copy image", s: s)
    button(c, CGRect(x: 529, y: 626, width: 94, height: 21), "Save image…", s: s)
    let pulse = 1 + 0.06 * max(0, sin((t - at(13, 2)) * 2 * .pi / beat)) * window(t, at(13, 2), at(14), 0.1)
    c.saveGState()
    c.translateBy(x: 665 * s, y: 636.5 * s); c.scaleBy(x: CGFloat(pulse), y: CGFloat(pulse)); c.translateBy(x: -665 * s, y: -636.5 * s)
    button(c, CGRect(x: 631, y: 626, width: 68, height: 21), "Share…", s: s, primary: true)
    c.restoreGState()
    c.restoreGState()
}
