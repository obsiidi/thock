import CoreGraphics
import CoreText
import Foundation

// Eight scenes on one continuous canvas. Shapes hand over between scenes:
// the laptop screen becomes the desktop, F and J become the big keys, J
// becomes the first pack card, the last card the trackpad, the trackpad the
// stats window.

func grouped(_ n: Int) -> String {
    let s = String(n); var out = ""
    for (i, ch) in s.reversed().enumerated() { if i > 0 && i % 3 == 0 { out.append(",") }; out.append(ch) }
    return String(out.reversed())
}
func centered(_ words: [String], _ f: CTFont) -> CGFloat {
    let w = words.map { width($0, f) }.reduce(0, +) + width(" ", f) * CGFloat(words.count - 1)
    return (CGFloat(W) - w) / 2
}
func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
func beatsFrom(_ t0: Double, _ n: Int, step: Double = 0.5) -> [Double] { (0..<n).map { t0 + Double($0) * step * beat } }

// MARK: laptop (scene 1) and desktop (scene 2)

let lid = CGRect(x: 580, y: 280, width: 760, height: 449)
let screenR = CGRect(x: 600, y: 302, width: 720, height: 405)     // 16:9, becomes the full frame
let baseTopY: CGFloat = 729, baseBotY: CGFloat = 985

struct KeyBox { let label: String; let rect: CGRect }
/// US layout, five rows, laid out in `r`; rows can taper for perspective.
func keyboardLayout(_ r: CGRect, taper: CGFloat = 0, gap: CGFloat = 10) -> [KeyBox] {
    let rows: [[(String, Double)]] = [
        ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { ($0, 1) } + [("delete", 1.5)],
        [("tab", 1.5)] + ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"].map { ($0, 1) },
        [("caps", 1.75)] + ["A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'"].map { ($0, 1) } + [("return", 1.75)],
        [("shiftL", 2.25)] + ["Z", "X", "C", "V", "B", "N", "M", ",", ".", "/"].map { ($0, 1) } + [("shiftR", 2.25)],
        [("fn", 1), ("control", 1), ("option", 1), ("command", 1.25), ("space", 5), ("command ", 1.25), ("option ", 1),
         ("←", 1), ("↑↓", 1), ("→", 1)],
    ]
    var out: [KeyBox] = []
    let rh = r.height / 5
    for (ri, row) in rows.enumerated() {
        let k = CGFloat(ri) / 4
        let rw = r.width * (1 - taper * (1 - k)), x0 = r.midX - rw / 2
        let unit = rw / 14.5
        var x = x0
        for (label, u) in row {
            let kw = CGFloat(u) * unit
            out.append(KeyBox(label: label, rect: CGRect(x: x + gap / 2, y: r.minY + CGFloat(ri) * rh + gap / 2,
                                                        width: kw - gap, height: rh - gap)))
            x += kw
        }
    }
    return out
}
func capLabel(_ l: String) -> String {
    ["shiftL": "shift", "shiftR": "shift", "command ": "command", "option ": "option", "space": ""][l] ?? l
}

func drawDesktop(_ c: CGContext, _ t: Double, menuIconLit: Double) {
    c.setFillColor(rgb(P.bg)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (p, r, col, a) in [(CGPoint(x: 1450, y: 820), 760.0, P.orange, 0.2), (CGPoint(x: 330, y: 250), 640.0, P.blue, 0.14)] {
        let g = CGGradient(colorsSpace: srgb, colors: [rgb(col, CGFloat(a)), rgb(col, 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: CGFloat(r), options: [])
    }
    for y in stride(from: 640.0, to: 1080, by: 26) { for x in stride(from: 40.0, to: 820, by: 26) {
        let a = 0.07 * smooth((y - 640) / 300) * smooth((820 - x) / 400)
        if a > 0.005 { c.setFillColor(rgb(P.ink, CGFloat(a))); c.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)) }
    } }
    // menu bar
    c.setFillColor(rgb(P.white, 0.6)); c.fill(CGRect(x: 0, y: 0, width: W, height: 40))
    c.setFillColor(rgb(P.ink, 0.06)); c.fill(CGRect(x: 0, y: 40, width: CGFloat(W), height: 1))
    var x: CGFloat = 26
    for (i, item) in ["Editor", "File", "Edit", "View", "Window", "Help"].enumerated() {
        x += text(c, item, uiFont(17, bold: i == 0), rgb(P.ink, 0.88), x: x, y: 27) + 26
    }
    text(c, "Mon 29 Sep  9:41", uiFont(17), rgb(P.ink, 0.88), x: 1894, y: 27, align: .right)
    // battery, wifi, thock
    let bx: CGFloat = 1700
    strokeRound(c, CGRect(x: bx, y: 13, width: 30, height: 14), 4, rgb(P.ink, 0.8), 1.6)
    fillRound(c, CGRect(x: bx + 3, y: 16, width: 19, height: 8), 2, rgb(P.ink, 0.8))
    fillRound(c, CGRect(x: bx + 31.5, y: 17.5, width: 2.5, height: 5), 1, rgb(P.ink, 0.8))
    c.setStrokeColor(rgb(P.ink, 0.8)); c.setLineWidth(2.2); c.setLineCap(.round)
    for (i, r) in [12.0, 8, 4].enumerated() {
        c.addArc(center: CGPoint(x: 1660, y: 30), radius: CGFloat(r), startAngle: -.pi * 0.75, endAngle: -.pi * 0.25, clockwise: false)
        if i < 3 { c.strokePath() }
    }
    c.fillEllipse(in: CGRect(x: 1658, y: 28, width: 4, height: 4))
    if menuIconLit > 0 { fillRound(c, CGRect(x: iconP.x - 24, y: 5, width: 48, height: 30), 7, rgb(P.ink, 0.12 * CGFloat(menuIconLit))) }
    keyboardGlyph(c, CGRect(x: iconP.x - 13, y: 12, width: 26, height: 17), rgb(P.ink, 0.85))
}
let iconP = CGPoint(x: 1560, y: 20)

func drawLaptop(_ c: CGContext, _ t: Double) {
    let build = { (a: Double, d: Double) in clamp((t - a) / d) }
    // outlines draw themselves
    let lidPath = rounded(lid, 26)
    let base = CGMutablePath()
    base.move(to: CGPoint(x: 560, y: baseTopY)); base.addLine(to: CGPoint(x: 1360, y: baseTopY))
    base.addLine(to: CGPoint(x: 1478, y: baseBotY - 18)); base.addQuadCurve(to: CGPoint(x: 1460, y: baseBotY), control: CGPoint(x: 1480, y: baseBotY))
    base.addLine(to: CGPoint(x: 460, y: baseBotY)); base.addQuadCurve(to: CGPoint(x: 442, y: baseBotY - 18), control: CGPoint(x: 440, y: baseBotY))
    base.closeSubpath()
    let fillIn = CGFloat(smooth((t - 0.75) / 0.4))
    if fillIn > 0 {
        c.setFillColor(rgb(0xE9E6DF, fillIn)); c.addPath(base); c.fillPath()
        c.setFillColor(rgb(0x1E1E20, fillIn)); c.addPath(lidPath); c.fillPath()
    }
    drawOn(c, lidPath, length: perimeter(lid, 26), k: easeInOut(build(0.05, 0.75)), color: rgb(P.ink), width: 4)
    drawOn(c, base, length: 2 * 1040 + 2 * 290, k: easeInOut(build(0.3, 0.7)), color: rgb(P.ink), width: 4)
    // screen: the desktop, shown through the lid
    let sc = CGFloat(smooth((t - 1.0) / 0.5))
    if sc > 0 {
        c.saveGState()
        c.addPath(rounded(screenR, 6)); c.clip()
        c.setAlpha(sc)
        c.translateBy(x: screenR.minX, y: screenR.minY)
        c.scaleBy(x: screenR.width / CGFloat(W), y: screenR.height / CGFloat(H))
        drawDesktop(c, t, menuIconLit: 0)
        c.restoreGState()
    }
    // keys pop in as a wave, the trackpad last
    let kb = keyboardLayout(CGRect(x: 600, y: 748, width: 720, height: 160), taper: 0.08, gap: 5)
    for (i, k) in kb.enumerated() {
        let t0 = 0.95 + Double(k.rect.midX - 600) / 720 * 0.6 + Double(i % 3) * 0.01
        let s = spring(t, t0, freq: 3, damping: 0.45)
        guard s > 0.01 else { continue }
        let r = k.rect.insetBy(dx: k.rect.width * CGFloat(1 - s) / 2, dy: k.rect.height * CGFloat(1 - s) / 2)
        fillRound(c, r, 3, rgb(P.ink, 0.85))
    }
    let tp = spring(t, 1.55, freq: 2.5, damping: 0.5)
    if tp > 0.01 {
        let r = CGRect(x: 820, y: 918, width: 280, height: 52)
        strokeRound(c, r.insetBy(dx: r.width * CGFloat(1 - tp) / 2, dy: r.height * CGFloat(1 - tp) / 2), 8, rgb(P.ink, 0.5), 3)
    }
}

// MARK: scene helpers

func headline(_ c: CGContext, eyebrow: String?, lines: [String], x: CGFloat, y: CGFloat, size: CGFloat, t: Double, start: Double,
              out: Double, sub: String? = nil, subY: CGFloat? = nil, accent: [Int: [Int: CGColor]] = [:]) {
    let f = font(heavy, size)
    if let e = eyebrow {
        let a = CGFloat(smooth((t - start) / 0.3) * (1 - smooth((t - out) / 0.25)))
        c.saveGState(); c.setAlpha(a); eyebrowText(c, e, x: x + 4, y: y - size * 1.05); c.restoreGState()
    }
    var n = 0
    for (li, l) in lines.enumerated() {
        let ws = words(l)
        springWords(c, ws, f, rgb(P.ink), x: x, y: y + CGFloat(li) * size * 1.02,
                    starts: (0..<ws.count).map { start + Double(n + $0) * beat / 4 }, t: t, out: out, highlight: accent[li] ?? [:])
        n += ws.count
    }
    if let s = sub {
        let a = CGFloat(smooth((t - start - 0.5) / 0.4) * (1 - smooth((t - out) / 0.25)))
        c.saveGState(); c.setAlpha(a)
        text(c, s, font(mono, 26), rgb(P.mute), x: x + 4, y: subY ?? (y + CGFloat(lines.count) * size * 1.02 + 20))
        c.restoreGState()
    }
}
func strokeState(_ key: String, _ t: Double, in list: [Stroke]) -> (press: Double, flash: Double, age: Double, force: Double)? {
    guard let s = list.last(where: { $0.key == key && $0.t <= t + 0.02 && t - $0.t < 0.8 }) else { return nil }
    let dt = t - s.t
    let press = dt < 0 ? (dt + 0.02) / 0.02 : max(0, 1 - dt / 0.12)
    return (press, exp(-max(0, dt) / 0.22), dt, s.force)
}
/// Circle wipe: an accent disc grows over `at - d`…`at`, then opens from the centre over `at`…`at + d`.
func circleWipe(_ c: CGContext, _ t: Double, at t0: Double, from p: CGPoint, color: UInt32, d: Double = 0.34) {
    let far = hypot(CGFloat(W), CGFloat(H)) * 1.05
    if t >= t0 - d && t < t0 {
        let r = far * CGFloat(easeIn((t - t0 + d) / d))
        c.setFillColor(rgb(color)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    } else if t >= t0 && t < t0 + d {
        let r = far * CGFloat(easeOutCubic((t - t0) / d))
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: W, height: H))
        let q = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
        path.addEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
        c.setFillColor(rgb(color)); c.addPath(path); c.fillPath(using: .evenOdd)
    }
}

// MARK: scene 3/4 geometry

let bigKB = keyboardLayout(CGRect(x: 210, y: 470, width: 1500, height: 505), gap: 12)
func bigKey(_ l: String) -> CGRect { bigKB.first { $0.label == l }?.rect ?? .zero }
let giantF = CGRect(x: 230, y: 470, width: 320, height: 320), giantJ = CGRect(x: 600, y: 470, width: 320, height: 320)
let cardRect = CGRect(x: 820, y: 250, width: 960, height: 560)
let padRect = CGRect(x: 860, y: 280, width: 880, height: 560)
let statsOrigin = CGPoint(x: 850, y: 72), statsScale: CGFloat = 1.4
let popScale: CGFloat = 1.85
var statsRect: CGRect { CGRect(origin: statsOrigin, size: CGSize(width: statsSize.width * statsScale, height: statsSize.height * statsScale)) }

// MARK: frame

func render(_ c: CGContext, _ t: Double) {
    c.setFillColor(rgb(P.bg)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let s1 = at(2, 3.3), s2 = at(3, 0.5)
    if t < s2 { scene1(c, t, zoomFrom: s1, zoomTo: s2) }
    else if t < at(5) { scene2(c, t) }
    else if t < at(7) + 0.2 { scene3(c, t) }
    else if t < at(9) + 0.15 { scene4(c, t) }
    else if t < at(11) + 0.15 { scene5(c, t) }
    else if t < at(12) + 0.2 { scene6(c, t) }
    else if t < at(14) { scene7(c, t) }
    else { scene8(c, t) }
    circleWipe(c, t, at: at(5), from: pointerPos(at(5) - 0.34), color: P.orange)
    circleWipe(c, t, at: at(14), from: CGPoint(x: statsRect.maxX - 60, y: statsRect.maxY - 30), color: P.blue)
}

func scene1(_ c: CGContext, _ t: Double, zoomFrom: Double, zoomTo: Double) {
    let z = easeInOut((t - zoomFrom) / (zoomTo - zoomFrom))
    c.saveGState()
    if z > 0 {
        // camera: the screen grows until it is the whole frame
        let target = lerpR(screenR, CGRect(x: 0, y: 0, width: W, height: H), z)
        let k = target.width / screenR.width
        c.translateBy(x: target.minX, y: target.minY); c.scaleBy(x: k, y: k); c.translateBy(x: -screenR.minX, y: -screenR.minY)
    }
    drawLaptop(c, t)
    c.restoreGState()
    // headlines
    let f = font(heavy, 78)
    let l1 = words("Your Mac has a great keyboard."), l2 = words("It just doesn't sound like one.")
    springWords(c, l1, f, rgb(P.ink), x: centered(l1, f), y: 186, starts: beatsFrom(at(1, 2), l1.count), t: t, out: at(2, 1.6))
    springWords(c, l2, f, rgb(P.ink), x: centered(l2, f), y: 186, starts: beatsFrom(at(2, 2), l2.count, step: 0.25), t: t,
                out: zoomFrom - 0.1, highlight: [3: rgb(P.orange)])
}

func pointerPos(_ t: Double) -> CGPoint {
    let s: CGFloat = popScale
    let tip = CGPoint(x: iconP.x, y: 46)
    let picker = CGPoint(x: tip.x + pickerOffset(s).x, y: tip.y + pickerOffset(s).y)
    let menuTop = CGPoint(x: tip.x - popSize.width / 2 * s + 62 * s, y: tip.y + (11 + 71) * s)
    let row = { (i: Double) in CGPoint(x: menuTop.x + 90 * s, y: menuTop.y + (5 + 11 + CGFloat(i) * 22) * s) }
    let force = CGPoint(x: tip.x + forceToggleOffset(s).x, y: tip.y + forceToggleOffset(s).y)
    let keys: [(Double, CGPoint)] = [
        (at(3, 0.3), CGPoint(x: 1150, y: 640)), (iconClick - 0.06, CGPoint(x: iconP.x + 2, y: 22)),
        (pickerClick - 0.06, picker), (pickerClick + 0.25, row(0)), (menuPick - 0.1, row(5)), (menuPick, row(5)),
        (forceToggle - 0.08, force), (at(5), CGPoint(x: force.x - 40, y: force.y + 120)),
    ]
    if t <= keys[0].0 { return keys[0].1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        let e = easeInOut((t - keys[i - 1].0) / (keys[i].0 - keys[i - 1].0))
        return CGPoint(x: keys[i - 1].1.x + (keys[i].1.x - keys[i - 1].1.x) * CGFloat(e),
                       y: keys[i - 1].1.y + (keys[i].1.y - keys[i - 1].1.y) * CGFloat(e))
    }
    return keys.last!.1
}

func scene2(_ c: CGContext, _ t: Double) {
    let s: CGFloat = popScale
    let open = spring(t, iconClick + 0.02, freq: 2.2, damping: 0.55)
    // gentle push-in towards the popover
    let push = 1 + 0.05 * CGFloat(smooth((t - at(3, 0.5)) / 3.5))
    c.saveGState()
    c.translateBy(x: 1560, y: 330); c.scaleBy(x: push, y: push); c.translateBy(x: -1560, y: -330)
    drawDesktop(c, t, menuIconLit: min(1, open * 1.5))
    var st = PopState()
    st.pack = t < menuPick ? topreIndex : creamIndex
    st.force = spring(t, forceToggle, freq: 3, damping: 0.6)
    st.sensitivity = 0.55
    st.reveal = clamp((t - iconClick - 0.05) / 0.5)
    let tip = CGPoint(x: iconP.x, y: 46)
    popover(c, tip: tip, st: st, s: s, open: open)
    let menuOpen = spring(t, pickerClick + 0.02, freq: 3, damping: 0.7) * (1 - smooth((t - menuPick) / 0.08))
    let hover = 5 * easeInOut((t - pickerClick - 0.25) / (menuPick - 0.1 - pickerClick - 0.25))
    packMenu(c, origin: CGPoint(x: tip.x - popSize.width / 2 * s + 62 * s, y: tip.y + (11 + 71) * s), s: s,
             open: menuOpen, checked: t < menuPick ? topreIndex : creamIndex, hover: hover)
    let clickDown = uiClicks.contains { t >= $0 && t < $0 + 0.1 }
    pointer(c, pointerPos(t), clickDown ? 1.7 : 1.9)
    c.restoreGState()
    headline(c, eyebrow: "MENU BAR APP", lines: ["Pick a", "switch."], x: 150, y: 560, size: 120, t: t, start: at(3, 1.5),
             out: at(5) - 0.45, sub: "One icon. Seven real keyboards.", accent: [1: [0: rgb(P.orange)]])
}

func scene3(_ c: CGContext, _ t: Double) {
    let morph = easeInOut((t - (at(7) - 0.3)) / 0.5)     // hand-over to the giant F and J
    let push = 1 + 0.035 * CGFloat(smooth((t - at(5)) / 4.6))
    c.saveGState()
    c.translateBy(x: 960, y: 700); c.scaleBy(x: push, y: push); c.translateBy(x: -960, y: -700)
    for (i, k) in bigKB.enumerated() {
        let appear = spring(t, at(5) + 0.05 + Double(abs(k.rect.midX - 960)) / 960 * 0.35 + Double(i % 4) * 0.01, freq: 2.6, damping: 0.5)
        guard appear > 0.01 else { continue }
        let isFJ = k.label == "F" || k.label == "J"
        var r = k.rect
        if isFJ && morph > 0 { r = lerpR(k.rect, k.label == "F" ? giantF : giantJ, morph) }
        let a = isFJ ? 1 : CGFloat(1 - morph)
        guard a > 0.01 else { continue }
        let st = strokeState(k.label, t, in: strokes)
        c.saveGState(); c.setAlpha(a)
        let sc = CGFloat(appear)
        let rr = r.insetBy(dx: r.width * (1 - sc) / 2, dy: r.height * (1 - sc) / 2)
        keycap(c, rr, label: capLabel(k.label), press: st?.press ?? 0, flash: (st?.flash ?? 0) * 0.9,
               flashColor: P.orange, labelSize: isFJ ? lerpC(34, 120, morph) : nil)
        c.restoreGState()
        if let st, morph < 0.5 {
            rings(c, at: CGPoint(x: r.midX, y: r.midY), age: st.age, size: 130, color: rgb(i % 2 == 0 ? P.orange : P.blue))
        }
    }
    c.restoreGState()
    c.saveGState(); c.setAlpha(CGFloat(1 - morph))
    eyebrowText(c, "REAL RECORDINGS", x: 214, y: 214)
    typedLine(c, headline3, font(heavy, 92), rgb(P.ink), x: 210, y: 330, times: typeTimes, t: t)
    text(c, "Default sound: NK Cream, recorded from a real keyboard.", font(mono, 26), rgb(P.mute), x: 214, y: 398)
    c.restoreGState()
}

func scene4(_ c: CGContext, _ t: Double) {
    let leave = easeInOut((t - (at(9) - 0.3)) / 0.45)    // J becomes the first card
    // force meter: one dot column per hit
    c.saveGState(); c.setAlpha(CGFloat(1 - leave))
    let x0: CGFloat = 1080, base: CGFloat = 790
    for x in stride(from: x0, through: 1760, by: 17) { dot2(c, x, base + 22, 3, rgb(P.ink, 0.12)) }
    for (i, h) in forceHits.enumerated() where t >= h.t {
        let n = max(1, Int((h.force * 17).rounded()))
        let grow = spring(t, h.t, freq: 3, damping: 0.5)
        let shown = Int(Double(n) * min(1.15, grow))
        let col = rgb(h.force > 0.6 ? P.orange : P.blue)
        for j in 0..<shown { for k in 0..<2 { dot2(c, x0 + CGFloat(i) * 46 + CGFloat(k) * 16, base - CGFloat(j) * 17, 6, col) } }
    }
    let softA = CGFloat(smooth((t - at(7)) / 0.3)), hardA = CGFloat(smooth((t - at(8)) / 0.3))
    // CG alpha is absolute, so nested fades multiply by hand
    let fadeOut = CGFloat(1 - leave)
    c.saveGState(); c.setAlpha(softA * fadeOut); text(c, "soft", font(mono, 24), rgb(P.blue), x: x0, y: base + 64); c.restoreGState()
    c.saveGState(); c.setAlpha(hardA * fadeOut); text(c, "hard", font(mono, 24), rgb(P.orange), x: x0 + 8 * 46, y: base + 64); c.restoreGState()
    c.restoreGState()
    var shake = CGPoint.zero
    for h in forceHits where h.force > 0.8 && t >= h.t && t < h.t + 0.4 {
        let k = exp(-(t - h.t) / 0.07)
        shake.x += CGFloat(sin((t - h.t) * 90) * 9 * k); shake.y += CGFloat(cos((t - h.t) * 75) * 6 * k)
    }
    c.saveGState(); c.translateBy(x: shake.x, y: shake.y)
    for (label, rect) in [("F", giantF), ("J", giantJ)] {
        let st = strokeState(label, t, in: forceHits)
        let f = st?.force ?? 0
        var r = rect
        if label == "J" && leave > 0 { r = lerpR(giantJ, cardRect, leave) }
        let squash = CGFloat((st?.press ?? 0) * (0.03 + 0.12 * f))
        r = CGRect(x: r.minX - r.width * squash * 0.3, y: r.minY + r.height * squash, width: r.width * (1 + squash * 0.6),
                   height: r.height * (1 - squash))
        let a = label == "F" ? CGFloat(1 - leave) : 1
        c.saveGState(); c.setAlpha(a)
        if label == "J" && leave > 0 {
            fillRound(c, r, lerpC(r.height * 0.16, 44, leave), mixColor(P.white, packInfos[0].color, leave))
        } else {
            keycap(c, r, label: label, press: st?.press ?? 0, flash: (st?.flash ?? 0) * (0.35 + 0.65 * f),
                   flashColor: f > 0.6 ? P.orange : P.blue, labelSize: 120, radius: 44)
        }
        c.restoreGState()
        if let st, leave < 0.3 {
            rings(c, at: CGPoint(x: rect.midX, y: rect.midY), age: st.age, size: CGFloat(170 + 330 * f),
                  color: rgb(f > 0.6 ? P.orange : P.blue), count: f > 0.6 ? 3 : 2)
        }
    }
    c.restoreGState()
    headline(c, eyebrow: "KEY FORCE", lines: ["It hears how hard you hit."], x: 150, y: 250, size: 88, t: t, start: at(7, 0.25),
             out: at(9) - 0.35, sub: "The MacBook's motion sensor, read 800 times a second.", subY: 320, accent: [0: [4: rgb(P.orange)]])
}
func dot2(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: CGColor) {
    c.setFillColor(col); c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

func card(_ c: CGContext, _ i: Int, _ r: CGRect, t: Double, burst: Double) {
    let p = packInfos[cardOrder[i]]
    fillRound(c, r, 44, rgb(p.color))
    let tc = rgb(p.text), sub = rgb(p.text, 0.7)
    text(c, String(format: "%02d / 07", i + 1), font(mono, 24), sub, x: r.minX + 56, y: r.minY + 76, kern: 3)
    var f = font(heavy, 112)
    if width(p.name, f) > r.width - 112 { f = font(heavy, 112 * (r.width - 112) / width(p.name, f)) }
    text(c, p.name, f, tc, x: r.minX + 52, y: r.minY + 250)
    text(c, p.kind, font(mono, 26), sub, x: r.minX + 58, y: r.minY + 306, kern: 3)
    if cardOrder[i] == creamIndex {
        let pill = CGRect(x: r.maxX - 230, y: r.minY + 44, width: 180, height: 50)
        fillRound(c, pill, 25, rgb(P.orange))
        text(c, "DEFAULT", font(mono, 22), rgb(P.white), x: pill.midX, y: pill.midY + 8, align: .center, kern: 3)
    }
    // dot waveform that dances with the burst
    var g = RNG(s: UInt64(7 + i * 31))
    for k in 0..<34 {
        let hgt = 0.25 + 0.75 * g.next()
        let e = burst * (0.5 + 0.5 * sin(Double(k) * 0.9 + t * 20))
        let n = max(1, Int((2 + 7 * hgt * (0.35 + 0.65 * e)).rounded()))
        for j in 0..<n { dot2(c, r.minX + 60 + CGFloat(k) * 25.5, r.maxY - 60 - CGFloat(j) * 16, 5.5, rgb(p.text, 0.55)) }
    }
}

func scene5(_ c: CGContext, _ t: Double) {
    let leave = easeInOut((t - (at(11) - 0.3)) / 0.45)   // the last card becomes the trackpad
    let cur = max(0, (cardTimes.lastIndex { $0 <= t } ?? 0))
    // the first card arrives as J's morph, so it is already in place
    let enterOf = { (i: Int) in i == 0 ? 1 : spring(t, cardTimes[i], freq: 2.4, damping: 0.55) }
    let ec = enterOf(cur)
    for d in stride(from: 3, through: 0, by: -1) {
        let i = cur - d
        guard i >= 0 else { continue }
        let enter = enterOf(i)
        // older cards slide back one step while the new one lands
        let depth = d == 0 ? 0 : CGFloat(Double(d) - (1 - ec))
        c.saveGState()
        let cx = cardRect.midX, cy = cardRect.midY
        c.translateBy(x: cx, y: cy + CGFloat(1 - enter) * 160 - depth * 30)
        c.rotate(by: CGFloat((1 - enter) * 0.07 - Double(depth) * 0.035))
        let sc = CGFloat(0.9 + 0.1 * enter) * (1 - depth * 0.05)
        c.scaleBy(x: sc, y: sc)
        c.translateBy(x: -cx, y: -cy)
        c.setAlpha(CGFloat(min(1, enter * 2)) * (d == 0 ? 1 : max(0, 1 - depth * 0.22)) * (d == 0 ? 1 : CGFloat(1 - leave)))
        if d == 0 && leave > 0 {
            let r = lerpR(cardRect, padRect, leave)
            fillRound(c, r, lerpC(44, 40, leave), mixColor(packInfos[cardOrder[i]].color, P.white, leave))
            c.setAlpha(CGFloat(1 - leave * 2.5))
            card(c, i, cardRect, t: t, burst: 0)
        } else {
            let since = t - cardTimes[i]
            let burst = d == 0 ? exp(-max(0, since - 0.05) / 0.35) * min(1, since / 0.03) : 0
            card(c, i, cardRect, t: t, burst: burst)
            if d > 0 { fillRound(c, cardRect, 44, rgb(P.bg, 0.25 * depth)) }
        }
        c.restoreGState()
    }
    headline(c, eyebrow: "SEVEN PACKS", lines: ["Seven real", "recordings."], x: 150, y: 470, size: 96, t: t, start: at(9, 0.25),
             out: at(11) - 0.35, sub: "Or drop in your own Mechvibes pack.", subY: 640)
}

func scene6(_ c: CGContext, _ t: Double) {
    let leave = easeInOut((t - (at(12) - 0.3)) / 0.5)    // the trackpad becomes the stats window
    let r = lerpR(padRect, statsRect, leave)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 20), blur: 44, color: rgb(0x3A3020, 0.14))
    fillRound(c, r, lerpC(40, 15, leave), mixColor(P.white, 0xF4F3F1, leave))
    c.restoreGState()
    strokeRound(c, r, lerpC(40, 15, leave), rgb(P.ink, 0.1), 2)
    if leave > 0.5 {
        c.saveGState(); c.setAlpha(CGFloat((leave - 0.5) * 2))
        statsWindow(c, origin: statsOrigin, s: statsScale, a: StatsAnim(count: 0, heat: 0, bars: 0, records: 0), t: t)
        c.restoreGState()
    }
    if leave < 0.99 {
        c.saveGState(); c.setAlpha(CGFloat(1 - leave * 2))
        let pitch: CGFloat = 26
        for y in stride(from: padRect.minY + 30, to: padRect.maxY - 20, by: pitch) {
            for x in stride(from: padRect.minX + 30, to: padRect.maxX - 20, by: pitch) {
                var b = 0.0, col = P.blue
                for k in taps where t >= k.t && t - k.t < 1.0 {
                    let age = t - k.t
                    let px = padRect.minX + CGFloat(k.u) * padRect.width, py = padRect.minY + CGFloat(k.v) * padRect.height
                    let d = Double(hypot(x - px, y - py)), ring = 30 + age * 620
                    let v = k.force * exp(-pow((d - ring) / 30, 2)) * (1 - age)
                    if v > b { b = v; col = k.force > 0.6 ? P.orange : P.blue }
                }
                dot2(c, x, y, CGFloat(3 + 5 * b), b > 0.05 ? rgb(col, CGFloat(0.3 + 0.7 * b)) : rgb(P.ink, 0.07))
            }
        }
        // the finger
        var fp = CGPoint(x: padRect.midX, y: padRect.maxY + 40)
        for (i, k) in taps.enumerated() {
            let prevT = i == 0 ? at(11) - 0.2 : taps[i - 1].t
            let from = i == 0 ? CGPoint(x: padRect.midX, y: padRect.maxY - 40)
                : CGPoint(x: padRect.minX + CGFloat(taps[i - 1].u) * padRect.width, y: padRect.minY + CGFloat(taps[i - 1].v) * padRect.height)
            let to = CGPoint(x: padRect.minX + CGFloat(k.u) * padRect.width, y: padRect.minY + CGFloat(k.v) * padRect.height)
            if t >= prevT {
                let e = easeInOut((t - prevT - 0.05) / max(0.08, k.t - prevT - 0.12))
                fp = CGPoint(x: from.x + (to.x - from.x) * CGFloat(e), y: from.y + (to.y - from.y) * CGFloat(e))
            }
        }
        let pressed = taps.contains { t >= $0.t && t < $0.t + 0.1 }
        let fr: CGFloat = pressed ? 30 : 36
        c.setFillColor(rgb(P.ink, 0.1)); c.fillEllipse(in: CGRect(x: fp.x - fr, y: fp.y - fr, width: 2 * fr, height: 2 * fr))
        c.setStrokeColor(rgb(P.ink, 0.45)); c.setLineWidth(3); c.strokeEllipse(in: CGRect(x: fp.x - fr, y: fp.y - fr, width: 2 * fr, height: 2 * fr))
        if let k = taps.last(where: { $0.t <= t }), t - k.t < 0.7 {
            c.saveGState(); c.setAlpha(CGFloat(1 - (t - k.t) / 0.7) * CGFloat(max(0, 1 - leave * 2)))
            text(c, k.force > 0.6 ? "firm click" : "light click", font(mono, 26), rgb(k.force > 0.6 ? P.orange : P.blue),
                 x: fp.x + 50, y: fp.y - 40)
            c.restoreGState()
        }
        c.restoreGState()
    }
    headline(c, eyebrow: "TRACKPAD", lines: ["Clicks sound", "like a mouse", "again."], x: 150, y: 430, size: 88, t: t,
             start: at(11, 0.1), out: at(12) - 0.3, sub: "Force Touch pressure sets the loudness.", subY: 690)
}

func scene7(_ c: CGContext, _ t: Double) {
    let a = StatsAnim(count: clamp((t - at(12, 0.4)) / 1.3), heat: clamp((t - at(12, 1)) / 1.5),
                      bars: clamp((t - at(12, 1.6)) / 1.2), records: clamp((t - at(13, 0.2)) / 0.8))
    let reveal: CGFloat = 1
    let push = 1 + 0.03 * CGFloat(smooth((t - at(12)) / 4.6))
    c.saveGState()
    c.translateBy(x: statsRect.midX, y: statsRect.midY); c.scaleBy(x: push, y: push); c.translateBy(x: -statsRect.midX, y: -statsRect.midY)
    c.setAlpha(reveal)
    statsWindow(c, origin: statsOrigin, s: statsScale, a: a, t: t)
    c.restoreGState()
    headline(c, eyebrow: "TYPING STATS", lines: ["Your typing,", "counted on", "your Mac."], x: 100, y: 430, size: 80, t: t,
             start: at(12, 0.3), out: at(14) - 0.3, sub: "Counts only. Never what you type.", subY: 680,
             accent: [2: [1: rgb(P.orange)]])
}

let outroMark = wordmark("thock", box: CGRect(x: 460, y: 250, width: 1000, height: 330), step: 15)
func scene8(_ c: CGContext, _ t: Double) {
    for d in outroMark {
        let ti = wordTimes[d.letter]
        let s = spring(t, ti, freq: 2.6, damping: 0.45)
        guard s > 0.01 else { continue }
        let flash = exp(-(t - ti) / 0.25)
        dot2(c, d.x, d.y, d.r * CGFloat(s), mixColor(P.ink, P.orange, flash * 0.9, d.a))
    }
    for (i, ti) in wordTimes.enumerated() where t >= ti {
        rings(c, at: CGPoint(x: 560 + CGFloat(i) * 200, y: 415), age: t - ti, size: 180, color: rgb(i % 2 == 0 ? P.orange : P.blue))
    }
    if t >= finalHit { rings(c, at: CGPoint(x: 960, y: 415), age: t - finalHit, size: 700, color: rgb(P.orange), count: 3) }
    let tag = words("Mechanical keyboard sounds for your Mac.")
    let tf = font(bold, 50)
    springWords(c, tag, tf, rgb(P.ink), x: centered(tag, tf), y: 690, starts: beatsFrom(at(14, 2.75), tag.count, step: 0.25), t: t)
    let facts = "Free  ·  open source  ·  macOS 13+"
    let fa = CGFloat(smooth((t - finalHit) / 0.4))
    c.saveGState(); c.setAlpha(fa)
    text(c, facts, font(mono, 30), rgb(P.mute), x: 960, y: 758 + (1 - fa) * 14, align: .center, kern: 1)
    c.restoreGState()
    let pill = spring(t, at(15, 1), freq: 2.4, damping: 0.5)
    if pill > 0.01 {
        let uf = font(bold, 40)
        let w = width("thock-ecru.vercel.app", uf) + 80
        c.saveGState()
        c.translateBy(x: 960, y: 855); c.scaleBy(x: CGFloat(pill), y: CGFloat(pill))
        fillRound(c, CGRect(x: -w / 2, y: -40, width: w, height: 80), 40, rgb(P.orange))
        text(c, "thock-ecru.vercel.app", uf, rgb(P.white), x: 0, y: 14, align: .center)
        c.restoreGState()
    }
}
