import CoreGraphics
import Foundation

// Titles on top of the 3D picture, in the website's type: Archivo for
// headlines, JetBrains Mono for small print, the dot wordmark at the end.

struct Caption {
    let a: Double, b: Double
    let eyebrow: String?, title: String, sub: String?
}

let captions: [Caption] = [
    Caption(a: at(3, 2.3), b: at(5) - 0.15, eyebrow: "MENU BAR APP", title: "Pick a switch.", sub: nil),
    Caption(a: at(5, 1.6), b: at(7) - 0.15, eyebrow: "REAL RECORDINGS", title: "Every key is a real switch.", sub: nil),
    Caption(a: at(7, 0.6), b: at(9) - 0.15, eyebrow: "KEY FORCE", title: "It hears how hard you hit.",
            sub: "The MacBook's motion sensor, read 800 times a second."),
    Caption(a: at(12, 0.4), b: at(13) - 0.15, eyebrow: "TRACKPAD", title: "Clicks sound like a mouse again.",
            sub: "Force Touch pressure sets the loudness."),
]

let heroMark = wordmark("thock", box: CGRect(x: 110, y: 330, width: 760, height: 250), step: 9)

func overlay(_ c: CGContext, _ t: Double) {
    // intro lines, centred
    for (a, b, s) in [(0.5, at(2) - 0.1, "Your Mac has a great keyboard."), (at(2) + 0.05, at(3) - 0.05, "It just doesn't sound like one.")] {
        let k = window(t, a, b, 0.35)
        guard k > 0 else { continue }
        c.saveGState(); c.setAlpha(CGFloat(k))
        let rise = CGFloat(18 * (1 - easeOutCubic((t - a) / 0.5)))
        text(c, s, font(heavy, 74), ink(), x: CGFloat(W) / 2, y: 190 + rise, align: .center)
        c.restoreGState()
    }

    // section captions, lower left, over a soft shade
    for cap in captions {
        let k = window(t, cap.a, cap.b, 0.3)
        guard k > 0 else { continue }
        shade(c, CGFloat(k))
        c.saveGState(); c.setAlpha(CGFloat(k))
        let rise = CGFloat(24 * (1 - easeOutCubic((t - cap.a) / 0.45)))
        if let e = cap.eyebrow { text(c, e, font(mono, 22), ink3, x: 120, y: 842 + rise, kern: 4.4) }
        text(c, cap.title, font(heavy, 80), ink(), x: 116, y: 930 + rise)
        if let s = cap.sub { text(c, s, font(mono, 26), ink2, x: 120, y: 984 + rise) }
        c.restoreGState()
    }

    // key force: one dot column per hit, height = force
    let fk = window(t, at(7, 0.6), at(9) - 0.15, 0.3)
    if fk > 0 {
        c.saveGState(); c.setAlpha(CGFloat(fk))
        let x0: CGFloat = 1250, base: CGFloat = 985, pitch: CGFloat = 11
        for x in stride(from: x0, through: 1800, by: pitch) { dot(c, x, base, 1.6, 0.15) }
        for (i, h) in forceHits.enumerated() where t >= h.t {
            let age = t - h.t
            let n = max(1, Int((h.force * 16).rounded()))
            let shown = Int(Double(n) * clamp(easeOutBack(age / 0.14), 0, 1.15))
            let a = CGFloat(0.4 + 0.5 * h.force + 0.3 * exp(-age / 0.25))
            for j in 0..<shown { for col in 0..<2 {
                dot(c, x0 + CGFloat(i) * 37 + CGFloat(col) * pitch, base - CGFloat(j + 1) * pitch, 3.4, a)
            } }
        }
        c.restoreGState()
    }

    // seven packs: the name pops in on every beat
    let pk = window(t, at(9, 0.05), at(11) - 0.15, 0.2)
    if pk > 0 {
        shade(c, CGFloat(pk))
        let i = packAt(t)
        let since = t - (packSwitches.last { $0.t <= t }?.t ?? 0)
        c.saveGState(); c.setAlpha(CGFloat(pk))
        text(c, "SEVEN PACKS  ·  \(i + 1)/7", font(mono, 22), ink3, x: 120, y: 842, kern: 4.4)
        c.saveGState()
        let s = CGFloat(0.9 + 0.1 * easeOutBack(since / 0.18))
        c.translateBy(x: 116, y: 930); c.scaleBy(x: s, y: s)
        text(c, packInfos[i].name, font(heavy, 88), ink(CGFloat(0.6 + 0.4 * smooth(since / 0.12))), x: 0, y: 0)
        c.restoreGState()
        text(c, packInfos[i].kind, font(mono, 26), ink2, x: 120, y: 984)
        c.restoreGState()
    }

    // hero: dot wordmark typed letter by letter, then the facts
    if t > wordmarkTimes[0] - 0.1 {
        for d in heroMark {
            let ti = wordmarkTimes[d.letter]
            guard t >= ti else { continue }
            let pop = easeOutBack((t - ti) / 0.22), flash = exp(-(t - ti) / 0.25)
            dot(c, d.x, d.y, d.r * CGFloat(pop) * CGFloat(1 + 0.25 * flash), d.a + (1 - d.a) * CGFloat(flash))
        }
        for (a, s, f, col, y) in [(at(14, 0.5), "Mechanical keyboard sounds for your Mac.", font(mono, 30), ink2, 660.0),
                                  (at(14, 1.5), "Free  ·  open source  ·  no account  ·  macOS 13+", font(mono, 26), ink3, 712.0)] {
            let k = smooth((t - a) / 0.5)
            c.saveGState(); c.setAlpha(CGFloat(k))
            text(c, s, f, col, x: 124, y: CGFloat(y) + CGFloat(12 * (1 - k)))
            c.restoreGState()
        }
        let k = smooth((t - at(14, 2.5)) / 0.5)
        c.saveGState(); c.setAlpha(CGFloat(k))
        text(c, "thock-ecru.vercel.app", font(bold, 46), ink(), x: 122, y: 800 + CGFloat(12 * (1 - k)))
        c.restoreGState()
    }

    // fade to black at the very end
    let out = smooth((t - (total - 1.3)) / 1.2)
    if out > 0 { c.setFillColor(gray(0, CGFloat(out))); c.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
    let fadeIn = 1 - smooth(t / 0.6)
    if fadeIn > 0 { c.setFillColor(gray(0, CGFloat(fadeIn))); c.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
}

/// Dark gradient in the lower left so captions stay readable over the scene.
func shade(_ c: CGContext, _ k: CGFloat) {
    let g = CGGradient(colorsSpace: srgb, colors: [gray(0, 0.6 * k), gray(0, 0)] as CFArray, locations: [0, 1])!
    c.saveGState()
    c.clip(to: CGRect(x: 0, y: 700, width: 1400, height: 380))
    c.drawRadialGradient(g, startCenter: CGPoint(x: 300, y: 1080), startRadius: 0,
                         endCenter: CGPoint(x: 300, y: 1080), endRadius: 1000, options: [])
    c.restoreGState()
}
