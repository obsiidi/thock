import Foundation

// Music for the motion video: 104 BPM, C major, light and bouncy. Intro with
// plucks only, drums from bar 3, a quiet breakdown for the key-force bars
// (7–8), full again from bar 9, a final chord in bar 15.

extension Music {
    func compose() {
        let cmaj7: [Double] = [60, 64, 67, 71], am7: [Double] = [57, 60, 64, 67], fmaj7: [Double] = [53, 57, 60, 64]
        let g6: [Double] = [55, 59, 62, 64], cmaj9: [Double] = [60, 64, 67, 71, 74]
        let loop: [(notes: [Double], root: Double)] = [(cmaj7, 48), (am7, 45), (fmaj7, 41), (g6, 43)]
        var chords = (0..<12).map { loop[$0 % 4] }
        chords += [(fmaj7, 41), (g6, 43), (cmaj9, 48)]
        let full = Set([3, 4, 5, 6, 9, 10, 11, 12, 13, 14])

        for b in 1...15 {
            let t0 = at(b), ch = chords[b - 1]
            if full.contains(b) {
                kick(at: t0, gain: 0.4); kick(at: t0 + 2 * beat, gain: 0.4)
                if b % 2 == 0 { kick(at: t0 + 2.75 * beat, gain: 0.2) }
                clap(at: t0 + beat, gain: 0.2); clap(at: t0 + 3 * beat, gain: 0.2)
                for e in 0..<16 {
                    hat(at: t0 + Double(e) * beat / 4 + 0.006, gain: e % 4 == 2 ? 0.05 : (e % 2 == 1 ? 0.022 : 0.032),
                        open: e == 14, pan: e % 2 == 0 ? -0.3 : 0.3)
                }
                let groove: [(Double, Double, Double)] = [(0, 0.45, 0), (0.75, 0.2, 0), (1.5, 0.45, 12), (2, 0.45, 0),
                                                          (2.75, 0.2, 7), (3.5, 0.4, 12)]
                for g in groove { bass(ch.root + g.2, at: t0 + g.0 * beat, len: g.1 * beat, gain: 0.17) }
            } else if b == 7 || b == 8 {
                bass(ch.root, at: t0, len: 3.6 * beat, gain: 0.1)
            } else if b == 15 {
                bass(ch.root, at: t0, len: 3 * beat, gain: 0.18)
            }
            // plucked arpeggio: eighths in the intro, sixteenths when it is full
            if b <= 2 || full.contains(b) {
                let tones = ch.notes.map { $0 + 12 }
                let order = [0, 2, 1, 3, 2, 0, 3, 1, 0, 2, 1, 3, 2, 3, 1, 2]
                let step = b <= 2 ? 2 : 1
                for s in stride(from: 0, to: 16, by: step) {
                    pluck(tones[order[s] % tones.count], at: t0 + Double(s) * beat / 4, gain: s % 4 == 0 ? 0.075 : 0.05,
                          pan: s % 8 < 4 ? -0.4 : 0.4)
                }
            }
        }
        riser(from: at(2, 2), to: at(3), gain: 0.18)
        riser(from: at(8, 2), to: at(9), gain: 0.2)
        impact(at: at(3), gain: 0.3); impact(at: at(9), gain: 0.28); impact(at: at(15), gain: 0.35)
        kick(at: at(15), gain: 0.5)
        for (t, d) in [(at(3, 0.2), 1.0), (at(5), -1.0), (at(7), 1.0), (at(9), -1.0), (at(11), 1.0), (at(12), -1.0), (at(14), 1.0)] {
            whoosh(peak: t, len: 0.6, gain: 0.1, dir: d)
        }

        // soft pad underneath, brighter as the video opens up
        var pL = [Double](repeating: 0, count: n), pR = pL
        for (b, c) in chords.enumerated() {
            pad(c.notes, from: at(b + 1), len: b == 14 ? bar * 1.3 : bar, gain: b == 14 ? 0.04 : 0.03, into: &pL, &pR)
        }
        var fl = SVF(), fr = SVF()
        for i in 0..<n {
            if i % 64 == 0 {
                let t = Double(i) / Double(SR)
                let cut = t < at(3) ? 600 * pow(5, t / at(3)) : (t >= at(7) && t < at(9) ? 1400 : 3200)
                fl.set(cut, 0.8); fr.set(cut, 0.8)
            }
            let l = fl.run(pL[i]).lp, r = fr.run(pR[i]).lp
            L[i] += l; R[i] += r; sL[i] += l * 0.4; sR[i] += r * 0.4
        }
        finish(fadeFrom: total - 1.6)
    }

    /// A short, round "pop" for things that spring in.
    func pop(at t0: Double, pitch: Double, gain: Double) {
        let i0 = idx(t0)
        var ph = 0.0
        for i in i0..<min(n, i0 + Int(0.12 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            ph += (520 + 700 * exp(-t / 0.018)) * pitch / Double(SR)
            add(i, sin(2 * .pi * ph) * exp(-t / 0.035) * min(1, t / 0.002) * gain, send: 0.15)
        }
    }
}
