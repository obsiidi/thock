import Foundation

// A small synthesiser for the videos' music: oscillators, noise, filters,
// delay and reverb (no samples, nothing to license). Each video adds its own
// arrangement in an extension.

func midiHz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

/// Zero-delay-feedback state variable filter (Simper).
struct SVF {
    var ic1 = 0.0, ic2 = 0.0
    var g = 0.0, k = 1.0, a1 = 0.0, a2 = 0.0, a3 = 0.0
    mutating func set(_ cutoff: Double, _ q: Double) {
        g = tan(Double.pi * min(cutoff, Double(SR) * 0.45) / Double(SR)); k = 1 / q
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }
    mutating func run(_ x: Double) -> (lp: Double, bp: Double, hp: Double) {
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }
}
func polyblep(_ t: Double, _ dt: Double) -> Double {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}
struct Noise {
    var s: UInt32 = 22222
    mutating func next() -> Double { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Double(s) / Double(UInt32.max) * 2 - 1 }
}

/// Stereo Freeverb (Jezar's tunings, scaled to 48 kHz).
struct Reverb {
    struct Comb { var buf: [Double]; var i = 0; var store = 0.0 }
    struct All { var buf: [Double]; var i = 0 }
    var cl: [Comb], cr: [Comb], al: [All], ar: [All]
    let feedback = 0.86, damp = 0.28
    init() {
        let s = Double(SR) / 44100
        let combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], alls = [556, 441, 341, 225]
        cl = combs.map { Comb(buf: [Double](repeating: 0, count: Int(Double($0) * s))) }
        cr = combs.map { Comb(buf: [Double](repeating: 0, count: Int(Double($0 + 23) * s))) }
        al = alls.map { All(buf: [Double](repeating: 0, count: Int(Double($0) * s))) }
        ar = alls.map { All(buf: [Double](repeating: 0, count: Int(Double($0 + 23) * s))) }
    }
    mutating func run(_ l: Double, _ r: Double) -> (Double, Double) {
        let input = (l + r) * 0.015
        var ol = 0.0, or = 0.0
        for j in 0..<cl.count {
            ol += Reverb.comb(&cl[j], input, feedback, damp)
            or += Reverb.comb(&cr[j], input, feedback, damp)
        }
        for j in 0..<al.count { ol = Reverb.allpass(&al[j], ol); or = Reverb.allpass(&ar[j], or) }
        return (ol, or)
    }
    static func comb(_ c: inout Comb, _ x: Double, _ fb: Double, _ damp: Double) -> Double {
        let out = c.buf[c.i]
        c.store = out * (1 - damp) + c.store * damp
        c.buf[c.i] = x + c.store * fb
        c.i = (c.i + 1) % c.buf.count
        return out
    }
    static func allpass(_ a: inout All, _ x: Double) -> Double {
        let b = a.buf[a.i]
        a.buf[a.i] = x + b * 0.5
        a.i = (a.i + 1) % a.buf.count
        return b - x
    }
}

final class Music {
    let n: Int
    var L: [Double], R: [Double]        // dry
    var sL: [Double], sR: [Double]      // reverb send
    var dL: [Double], dR: [Double]      // delay send (arp)
    var pumpEnv: [Double]               // kick sidechain
    var noise = Noise()

    init(seconds: Double) {
        n = Int(seconds * Double(SR))
        L = [Double](repeating: 0, count: n); R = L; sL = L; sR = L; dL = L; dR = L; pumpEnv = L
    }
    func idx(_ t: Double) -> Int { Int(t * Double(SR)) }
    func add(_ i: Int, _ v: Double, pan: Double = 0, send: Double = 0) {
        guard i >= 0 && i < n else { return }
        let gl = cos((pan + 1) * .pi / 4) * 1.414, gr = sin((pan + 1) * .pi / 4) * 1.414
        L[i] += v * gl; R[i] += v * gr
        if send > 0 { sL[i] += v * gl * send; sR[i] += v * gr * send }
    }

    // MARK: instruments

    /// Pad: three detuned band-limited saws per note, filtered later as a bus.
    func pad(_ notes: [Double], from t0: Double, len: Double, gain: Double, into bufL: inout [Double], _ bufR: inout [Double]) {
        let rel = 1.1, att = 0.45
        let i0 = idx(t0), i1 = min(n, idx(t0 + len + rel))
        for m in notes {
            for (d, pan) in [(-0.09, -0.7), (0.0, 0.0), (0.085, 0.7)] {
                let f = midiHz(m + d), dt = f / Double(SR)
                var ph = rng.next()
                let gl = cos((pan + 1) * .pi / 4), gr = sin((pan + 1) * .pi / 4)
                for i in i0..<i1 {
                    let t = Double(i - i0) / Double(SR)
                    let env = min(1, t / att) * (t > len ? exp(-(t - len) / (rel / 3)) : 1)
                    let s = (2 * ph - 1 - polyblep(ph, dt)) * env * gain
                    bufL[i] += s * gl; bufR[i] += s * gr
                    ph += dt; if ph >= 1 { ph -= 1 }
                }
            }
        }
    }

    func bass(_ m: Double, at t0: Double, len: Double, gain: Double) {
        let f = midiHz(m), i0 = idx(t0), i1 = min(n, idx(t0 + len + 0.08))
        var ph = 0.0
        for i in i0..<i1 {
            let t = Double(i - i0) / Double(SR)
            let env = min(1, t / 0.006) * (0.55 + 0.45 * exp(-t / 0.18)) * (t > len ? exp(-(t - len) / 0.025) : 1)
            let x = sin(2 * .pi * ph) + 0.35 * sin(4 * .pi * ph) + 0.5 * sin(.pi * ph)
            add(i, tanh(x * 1.3) * env * gain)
            ph += f / Double(SR); if ph >= 2 { ph -= 2 }
        }
    }

    func kick(at t0: Double, gain: Double) {
        let i0 = idx(t0)
        var ph = 0.0
        for i in i0..<min(n, i0 + Int(0.6 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            let f = 46 + 110 * exp(-t / 0.032)
            ph += f / Double(SR)
            let env = exp(-t / 0.26) * min(1, t / 0.001)
            add(i, tanh(sin(2 * .pi * ph) * 1.6) * env * gain + (t < 0.004 ? noise.next() * 0.25 * gain : 0))
            pumpEnv[i] = max(pumpEnv[i], exp(-t / 0.16))
        }
    }

    func clap(at t0: Double, gain: Double) {
        var f = SVF(); f.set(1500, 0.9)
        let i0 = idx(t0)
        for i in i0..<min(n, i0 + Int(0.35 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            var env = exp(-t / 0.11)
            for b in [0.0, 0.011, 0.022] where t >= b && t < b + 0.01 { env = max(env, exp(-(t - b) / 0.004)) }
            let v = f.run(noise.next()).bp * env * gain * 3
            add(i, v, pan: 0.05, send: 0.5)
        }
    }

    func hat(at t0: Double, gain: Double, open: Bool = false, pan: Double = 0) {
        var f = SVF(); f.set(8500, 0.7)
        let i0 = idx(t0), dec = open ? 0.16 : 0.028
        for i in i0..<min(n, i0 + Int(dec * 6 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            add(i, f.run(noise.next()).hp * exp(-t / dec) * gain, pan: pan, send: 0.1)
        }
    }

    func pluck(_ m: Double, at t0: Double, gain: Double, pan: Double) {
        var f = SVF(); f.set(3200, 0.8)
        let fr = midiHz(m), dt = fr / Double(SR), i0 = idx(t0)
        var ph = 0.0
        for i in i0..<min(n, i0 + Int(0.5 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            let saw = 2 * ph - 1 - polyblep(ph, dt), tri = 1 - 4 * abs(ph - 0.5)
            let v = f.run(0.55 * saw + 0.45 * tri).lp * exp(-t / 0.12) * min(1, t / 0.002) * gain
            add(i, v, pan: pan, send: 0.25)
            if i < n { dL[i] += v * 0.8; dR[i] += v * 0.8 }
            ph += dt; if ph >= 1 { ph -= 1 }
        }
    }

    /// Filtered noise swelling into a drop.
    func riser(from t0: Double, to t1: Double, gain: Double) {
        var fl = SVF(), fr = SVF()
        let i0 = idx(t0), i1 = min(n, idx(t1))
        for i in i0..<i1 {
            let x = Double(i - i0) / Double(i1 - i0)
            if (i - i0) % 32 == 0 { let c = 350 * pow(28, x); fl.set(c, 2.2); fr.set(c * 1.08, 2.2) }
            let env = x * x * gain
            add(i, fl.run(noise.next()).bp * env, pan: -0.6, send: 0.4)
            add(i, fr.run(noise.next()).bp * env, pan: 0.6, send: 0.4)
        }
    }

    /// Camera whoosh: band-passed noise sweeping up and down, panned across.
    func whoosh(peak t: Double, len: Double = 0.6, gain: Double, dir: Double = 1) {
        var f = SVF()
        let i0 = idx(t - len * 0.55), i1 = min(n, idx(t + len * 0.45))
        for i in max(0, i0)..<i1 {
            let x = Double(i - i0) / Double(i1 - i0)
            if (i - i0) % 32 == 0 { f.set(300 * pow(14, sin(.pi * x)), 1.4) }
            let env = pow(sin(.pi * x), 2) * gain
            add(i, f.run(noise.next()).bp * env * 2, pan: dir * (x * 1.4 - 0.7), send: 0.2)
        }
    }

    func impact(at t0: Double, gain: Double) {
        var f = SVF(); f.set(700, 0.7)
        let i0 = idx(t0)
        var ph = 0.0
        for i in i0..<min(n, i0 + Int(2.2 * Double(SR))) {
            let t = Double(i - i0) / Double(SR)
            ph += (36 + 30 * exp(-t / 0.25)) / Double(SR)
            let sub = sin(2 * .pi * ph) * exp(-t / 0.9)
            let body = f.run(noise.next()).lp * exp(-t / 0.22)
            add(i, (sub * 0.9 + body * 0.8) * gain * min(1, t / 0.002), send: 0.35)
        }
    }

    /// Dotted-eighth ping-pong delay for the plucks, reverb, then fades.
    func finish(fadeFrom: Double) {
        // dotted-eighth ping-pong delay for the arp, then reverb, then pump and fade
        let dly = Int(0.75 * beat * Double(SR))
        var bl = [Double](repeating: 0, count: n), br = bl
        for i in 0..<n {
            let fbL = i >= dly ? br[i - dly] * 0.38 : 0, fbR = i >= dly ? bl[i - dly] * 0.38 : 0
            bl[i] = dL[i] * 0.5 + fbL; br[i] = fbR
            L[i] += bl[i] * 0.55; R[i] += br[i] * 0.55
            sL[i] += bl[i] * 0.2; sR[i] += br[i] * 0.2
        }
        var rev = Reverb()
        for i in 0..<n {
            let (l, r) = rev.run(sL[i], sR[i])
            L[i] += l * 2.2; R[i] += r * 2.2
        }
        for i in 0..<n {
            let t = Double(i) / Double(SR)
            let fade = t > fadeFrom ? max(0, 1 - (t - fadeFrom) / 1.6) : 1
            let fadeIn = min(1, t / 0.4)
            L[i] *= fade * fadeIn; R[i] *= fade * fadeIn
        }
    }
}
