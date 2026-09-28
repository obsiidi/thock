import AppKit
import CoreGraphics

// The laptop's screen, drawn per frame at 2560x1664 (MacBook Air 13"): a
// dark desktop, menu bar with the real thock icon, a text editor that fills
// with what is typed, the real popover (rendered by `thock --render-popover`)
// and the pointer.

final class Screen {
    static let SW = 2560, SH = 1664
    let menuH: CGFloat = 74
    let win = CGRect(x: 360, y: 230, width: 1500, height: 880)
    var iconX: CGFloat = 0
    var base: CGImage!
    var popovers: [CGImage] = []
    let popMargin: CGFloat = 90
    var popSize = CGSize.zero
    let editorFont = uiFont(50)

    init(popoverDir: String) {
        let icon = loadImage(popoverDir + "/statusicon.png")
        let contents = packInfos.map { loadImage(popoverDir + "/popover-\($0.id).png") }
        popSize = CGSize(width: contents[0].width, height: contents[0].height)
        base = makeBase(icon)
        popovers = contents.map(makePopover)
    }

    var popRect: CGRect {
        CGRect(x: iconX - popSize.width / 2, y: menuH + 16, width: popSize.width, height: popSize.height)
    }
    var iconPoint: CGPoint { CGPoint(x: iconX, y: menuH / 2) }
    /// The Sound picker inside the popover capture (2x pixels).
    var pickerPoint: CGPoint { CGPoint(x: popRect.minX + 330, y: popRect.minY + 107) }
    var editorPoint: CGPoint { CGPoint(x: win.minX + 820, y: win.minY + 330) }

    // MARK: static layers

    private func symbol(_ name: String, _ size: CGFloat) -> CGImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return nil }
        let w = Int(img.size.width.rounded(.up)), h = Int(img.size.height.rounded(.up))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        c.setBlendMode(.sourceAtop); c.setFillColor(gray(1, 0.92)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()
    }

    private func makeBase(_ icon: CGImage) -> CGImage {
        let c = canvas(Screen.SW, Screen.SH)
        let full = CGRect(x: 0, y: 0, width: Screen.SW, height: Screen.SH)
        // wallpaper: deep blue-grey gradient with two soft lights and a faint dot field
        let grad = CGGradient(colorsSpace: srgb, colors: [CGColor(srgbRed: 0.11, green: 0.13, blue: 0.19, alpha: 1),
                                                          CGColor(srgbRed: 0.03, green: 0.035, blue: 0.05, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 900, y: 1664), options: [])
        for (p, r, a) in [(CGPoint(x: 400, y: 300), 1200.0, 0.22), (CGPoint(x: 2300, y: 1500), 900.0, 0.12)] {
            let g = CGGradient(colorsSpace: srgb, colors: [CGColor(srgbRed: 0.35, green: 0.42, blue: 0.6, alpha: a),
                                                          CGColor(srgbRed: 0.35, green: 0.42, blue: 0.6, alpha: 0)] as CFArray,
                               locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: CGFloat(r), options: [])
        }
        for y in stride(from: 1000.0, to: 1664, by: 22) { for x in stride(from: 1300.0, to: 2560, by: 22) {
            let wave = sin(x / 260 + y / 180) * 0.5 + 0.5
            let a = CGFloat(0.05 * wave * smooth((y - 1000) / 400) * smooth((x - 1300) / 500))
            if a > 0.004 { c.setFillColor(gray(1, a)); c.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)) }
        } }

        // editor window with shadow
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 30), blur: 90, color: gray(0, 0.7))
        c.setFillColor(CGColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1))
        c.addPath(rounded(win, 22)); c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(rounded(win, 22)); c.clip()
        c.setFillColor(CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1))
        c.fill(CGRect(x: win.minX, y: win.minY, width: win.width, height: 64))
        c.setFillColor(gray(0, 0.5)); c.fill(CGRect(x: win.minX, y: win.minY + 64, width: win.width, height: 2))
        c.restoreGState()
        c.setStrokeColor(gray(1, 0.1)); c.setLineWidth(2); c.addPath(rounded(win.insetBy(dx: 1, dy: 1), 21)); c.strokePath()
        let lights = [CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                      CGColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (i, col) in lights.enumerated() {
            c.setFillColor(col); c.fillEllipse(in: CGRect(x: win.minX + 28 + CGFloat(i) * 40, y: win.minY + 20, width: 24, height: 24))
        }
        text(c, "Draft", uiFont(26, bold: true), gray(1, 0.75), x: win.midX, y: win.minY + 42, align: .center)

        // menu bar
        c.setFillColor(gray(0, 0.32)); c.fill(CGRect(x: 0, y: 0, width: CGFloat(Screen.SW), height: menuH))
        var x: CGFloat = 56
        for (i, item) in ["Editor", "File", "Edit", "Format", "View", "Window", "Help"].enumerated() {
            x += text(c, item, uiFont(27, bold: i == 0), gray(1, 0.93), x: x, y: 47) + 44
        }
        var r = CGFloat(Screen.SW) - 40
        r -= text(c, "Mon 28 Sep  9:41", uiFont(27), gray(1, 0.93), x: r, y: 47, align: .right) + 44
        for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
            guard let s = symbol(name, 30) else { continue }
            let w = CGFloat(s.width), h = CGFloat(s.height)
            draw(c, s, in: CGRect(x: r - w, y: menuH / 2 - h / 2, width: w, height: h))
            r -= w + 44
        }
        iconX = r - CGFloat(icon.width) / 2
        draw(c, icon, in: CGRect(x: iconX - CGFloat(icon.width) / 2, y: menuH / 2 - CGFloat(icon.height) / 2,
                                 width: CGFloat(icon.width), height: CGFloat(icon.height)))
        // notch
        let nw: CGFloat = 400, nh: CGFloat = 66
        let notch = CGMutablePath()
        let nx = CGFloat(Screen.SW) / 2 - nw / 2
        notch.move(to: CGPoint(x: nx - 12, y: 0))
        notch.addQuadCurve(to: CGPoint(x: nx, y: 12), control: CGPoint(x: nx, y: 0))
        notch.addLine(to: CGPoint(x: nx, y: nh - 22))
        notch.addQuadCurve(to: CGPoint(x: nx + 22, y: nh), control: CGPoint(x: nx, y: nh))
        notch.addLine(to: CGPoint(x: nx + nw - 22, y: nh))
        notch.addQuadCurve(to: CGPoint(x: nx + nw, y: nh - 22), control: CGPoint(x: nx + nw, y: nh))
        notch.addLine(to: CGPoint(x: nx + nw, y: 12))
        notch.addQuadCurve(to: CGPoint(x: nx + nw + 12, y: 0), control: CGPoint(x: nx + nw, y: 0))
        notch.closeSubpath()
        c.setFillColor(gray(0)); c.addPath(notch); c.fillPath()
        _ = full
        return c.makeImage()!
    }

    /// Popover chrome (dark material, arrow, border, shadow) around the captured content.
    private func makePopover(_ content: CGImage) -> CGImage {
        let m = popMargin, arrow: CGFloat = 16
        let w = Int(popSize.width + 2 * m), h = Int(popSize.height + 2 * m + arrow)
        let c = canvas(w, h)
        let body = CGRect(x: m, y: m + arrow, width: popSize.width, height: popSize.height)
        let shape = CGMutablePath()
        shape.addPath(rounded(body, 22))
        shape.move(to: CGPoint(x: body.midX - 26, y: body.minY))
        shape.addQuadCurve(to: CGPoint(x: body.midX, y: body.minY - arrow), control: CGPoint(x: body.midX - 8, y: body.minY - arrow))
        shape.addQuadCurve(to: CGPoint(x: body.midX + 26, y: body.minY), control: CGPoint(x: body.midX + 8, y: body.minY - arrow))
        shape.closeSubpath()
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: 22), blur: 60, color: gray(0, 0.65))
        c.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.98))
        c.addPath(shape); c.fillPath()
        c.restoreGState()
        c.setStrokeColor(gray(1, 0.13)); c.setLineWidth(2); c.addPath(shape); c.strokePath()
        draw(c, content, in: body)
        return c.makeImage()!
    }

    // MARK: pointer script

    struct Move { let t0: Double; let t1: Double; let to: CGPoint }
    lazy var moves: [Move] = {
        var m: [Move] = [
            Move(t0: 4.3, t1: at(3, 1.4), to: iconPoint),
            Move(t0: at(3, 3.2), t1: at(4, 1.6), to: pickerPoint),
            Move(t0: at(4, 2.4), t1: at(4, 3.8), to: editorPoint),
            Move(t0: at(8, 3.2), t1: at(8, 3.9), to: iconPoint),
            Move(t0: at(9, 0.15), t1: at(9, 0.8), to: pickerPoint),
            Move(t0: at(10, 3.1), t1: at(10, 3.9), to: editorPoint),
        ]
        for (i, k) in clicks.enumerated() {
            let p = CGPoint(x: win.minX + 300 + CGFloat(k.u) * 900, y: win.minY + 200 + CGFloat(k.v) * 450)
            m.append(Move(t0: k.t - (i == 0 ? 0.5 : 0.35), t1: k.t - 0.05, to: p))
        }
        m.append(Move(t0: at(12, 3.8), t1: at(12, 3.97), to: iconPoint))
        m.append(Move(t0: at(13, 1), t1: at(13, 3), to: CGPoint(x: 1450, y: 1150)))
        return m
    }()
    lazy var pointerClicks: [Double] = {
        [at(3, 2), at(4, 2), at(5)] + (1..<7).map { at(9, Double($0)) } + [at(9), at(11)] + clicks.map(\.t) + [at(13)]
    }()
    func pointer(_ t: Double) -> (p: CGPoint, visible: Bool, down: Bool) {
        var p = CGPoint(x: 1450, y: 1150)
        for m in moves where t >= m.t0 {
            let from = p
            let e = smoother((t - m.t0) / (m.t1 - m.t0))
            p = CGPoint(x: from.x + (m.to.x - from.x) * e, y: from.y + (m.to.y - from.y) * e)
        }
        // hidden while typing, as macOS does
        let hidden = (t > at(5, 0.6) && t < at(8, 3.1)) || (t > at(11, 0.3) && t < at(12) - 0.6) || t < 4.2
        let down = pointerClicks.contains { t >= $0 && t < $0 + 0.1 }
        return (p, !hidden, down)
    }

    // MARK: frame

    func render(_ t: Double) -> CGImage {
        let c = canvas(Screen.SW, Screen.SH)
        draw(c, base, in: CGRect(x: 0, y: 0, width: Screen.SW, height: Screen.SH))
        let pa = CGFloat(popoverAlpha(t))
        if pa > 0 {
            c.setFillColor(gray(1, 0.22 * pa))
            c.addPath(rounded(CGRect(x: iconX - 36, y: 9, width: 72, height: menuH - 18), 12)); c.fillPath()
        }
        // editor text and caret
        let shown = typed.filter { $0.t <= t }
        let lines = [String(shown.filter { $0.line == 0 }.map(\.ch)), String(shown.filter { $0.line == 1 }.map(\.ch))]
        let x0 = win.minX + 60
        var ends: [CGFloat] = []
        for (i, s) in lines.enumerated() {
            let y = win.minY + 175 + CGFloat(i) * 84
            ends.append(s.isEmpty ? 0 : text(c, s, editorFont, gray(1, 0.94), x: x0, y: y))
        }
        // the caret moves to line 2 when the editor is clicked before typing it
        let row = (t >= at(11) || !lines[1].isEmpty) ? 1 : 0
        let caret = CGPoint(x: x0 + ends[row] + 4, y: win.minY + 175 + CGFloat(row) * 84)
        let typingNow = typed.contains { abs($0.t - t) < 0.35 }
        if typingNow || Int(t * 1.9) % 2 == 0 {
            c.setFillColor(CGColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1))
            c.fill(CGRect(x: caret.x, y: caret.y - 44, width: 4, height: 56))
        }
        // popover
        if pa > 0 {
            let img = popovers[packAt(t)]
            let s = 0.97 + 0.03 * pa
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            let anchorY = menuH + 16 - popMargin * s - 16 * s
            draw(c, img, in: CGRect(x: iconX - w / 2, y: anchorY + (1 - s) * 16, width: w, height: h), alpha: pa)
        }
        // pointer
        let ptr = pointer(t)
        if ptr.visible {
            let k: CGFloat = ptr.down ? 1.9 : 2.1
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 30), (8, 23), (13, 35), (18, 33), (13, 21), (23, 21)]
            let path = CGMutablePath()
            path.move(to: ptr.p)
            for q in pts.dropFirst() { path.addLine(to: CGPoint(x: ptr.p.x + q.0 * k, y: ptr.p.y + q.1 * k)) }
            path.closeSubpath()
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: gray(0, 0.5))
            c.addPath(path); c.setFillColor(gray(0)); c.fillPath()
            c.restoreGState()
            c.addPath(path); c.setStrokeColor(gray(1)); c.setLineWidth(3.2); c.strokePath()
            c.addPath(path); c.setFillColor(gray(0)); c.fillPath()
        }
        return c.makeImage()!
    }
}
