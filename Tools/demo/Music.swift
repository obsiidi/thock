import Foundation

// The demo's music: 104 BPM, A minor, lo-fi electronic, in sections that
// follow the picture (see Timeline.swift).

extension Music {
    // MARK: arrangement

    func drums(_ chords: [(notes: [Double], root: Double)], _ full: Set<Int>) {
        for b in 1...15 {
            let t0 = at(b), root = chords[b - 1].root
            if full.contains(b) {
                kick(at: t0, gain: 0.55); kick(at: t0 + 2 * beat, gain: 0.55)
                kick(at: t0 + 1.5 * beat, gain: 0.25)
                if b == 6 || b == 14 { kick(at: t0 + 3.5 * beat, gain: 0.35) }
                clap(at: t0 + beat, gain: 0.3); clap(at: t0 + 3 * beat, gain: 0.3)
                for e in 0..<8 {
                    hat(at: t0 + Double(e) * beat / 2 + 0.008, gain: e % 2 == 1 ? 0.07 : 0.045,
                        open: e == 5, pan: e % 2 == 0 ? -0.25 : 0.25)
                }
                let groove: [(Double, Double, Double)] = [(0, 0.75, 0), (1.5, 0.35, 0), (2, 0.75, 0), (3, 0.35, 0), (3.5, 0.35, 12)]
                for g in groove { bass(root + g.2, at: t0 + g.0 * beat, len: g.1 * beat, gain: 0.2) }
            } else if b == 7 || b == 8 {
                bass(root, at: t0, len: 3.6 * beat, gain: 0.14)
            } else if b == 15 {
                bass(root, at: t0, len: 2.5 * beat, gain: 0.2)
            }
            // arpeggio: sixteenths over the chord, an octave up
            if [5, 6, 9, 10, 11, 12, 13, 14].contains(b) {
                let tones = chords[b - 1].notes.map { $0 + 12 }
                let order = [0, 1, 2, 3, 2, 1, 2, 3, 0, 2, 1, 3, 2, 1, 3, 2]
                for s in 0..<16 {
                    pluck(tones[order[s] % tones.count], at: t0 + Double(s) * beat / 4, gain: s % 4 == 0 ? 0.085 : 0.06,
                          pan: s % 2 == 0 ? -0.35 : 0.35)
                }
            }
        }
        riser(from: at(2, 1), to: at(3), gain: 0.28)
        riser(from: at(8, 1), to: at(9), gain: 0.28)
        impact(at: at(3), gain: 0.5); impact(at: at(9), gain: 0.45); impact(at: at(15), gain: 0.5)
        kick(at: at(15), gain: 0.6)
        // whooshes peak mid-way through each camera whip
        for (t, d) in [(at(3, 0.6), 1.0), (at(5, 0.5), -1.0), (at(7, 0.45), 1.0), (at(9, 0.5), -1.0), (at(11, 0.5), 1.0),
                       (at(12, 0.45), -1.0), (at(13, 1.0), 1.0)] {
            whoosh(peak: t, len: 0.8, gain: 0.16, dir: d)
        }

    }

    func compose() {
        let am7: [Double] = [57, 60, 64, 67], fmaj7: [Double] = [53, 57, 60, 64]
        let cmaj7: [Double] = [55, 60, 64, 71], g6: [Double] = [55, 59, 62, 64], am9: [Double] = [57, 60, 64, 67, 71]
        let loop = [(am7, 45.0), (fmaj7, 41.0), (cmaj7, 48.0), (g6, 43.0)]
        var chords: [(notes: [Double], root: Double)] = (0..<12).map { (notes: loop[$0 % 4].0, root: loop[$0 % 4].1) }
        chords += [(notes: fmaj7, root: 41), (notes: g6, root: 43), (notes: am9, root: 45)]
        let full = Set([3, 4, 5, 6, 9, 10, 11, 12, 13, 14])
        drums(chords, full)

        // pad bus, filtered with a cutoff that follows the sections
        var pL = [Double](repeating: 0, count: n), pR = pL
        for (b, c) in chords.enumerated() {
            let len = b == 14 ? bar * 1.4 : bar
            pad(c.notes, from: at(b + 1), len: len, gain: b == 14 ? 0.05 : 0.042, into: &pL, &pR)
        }
        func cutoff(_ t: Double) -> Double {
            if t < at(3) { return 300 * pow(8, t / at(3)) }
            if t < at(7) { return 2600 }
            if t < at(9) { return 1100 + 500 * sin(.pi * (t - at(7)) / (2 * bar)) }
            if t < at(13) { return 3000 }
            return 3200
        }
        var fl = SVF(), fr = SVF()
        for i in 0..<n {
            if i % 64 == 0 { let c = cutoff(Double(i) / Double(SR)); fl.set(c, 0.9); fr.set(c, 0.9) }
            let bn = Int(Double(i) / Double(SR) / bar) + 1
            let pump = full.contains(bn) ? 1 - 0.35 * pumpEnv[i] : 1
            let l = fl.run(pL[i]).lp * pump, r = fr.run(pR[i]).lp * pump
            L[i] += l; R[i] += r; sL[i] += l * 0.45; sR[i] += r * 0.45
        }

        finish(fadeFrom: total - 1.6)
    }
}