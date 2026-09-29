// Tools/motion — renders the light motion-design demo of thock: kinetic type,
// springy shapes, the popover with its pack menu, the stats window, real pack
// sounds (NK Cream by default) in sync with every keystroke, original music.
// 1920x1080, 30 fps, H.264 + AAC, ~35 s. Apple frameworks only.
//
//   swiftc -O Tools/videokit/*.swift Tools/motion/*.swift -o /tmp/motion && /tmp/motion dist/thock-motion.mp4
//   /tmp/motion --stills 2,6,11,16 dist/stills        (single frames for checking)
//
// Run from the repo root (reads packs/, mouse-packs/, site/fonts/).
import CoreGraphics
import Foundation

registerFonts()
buildTimeline()
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--stills" {
    writeStills(args[1].split(separator: ",").compactMap { Double($0) }, dir: args.count > 2 ? args[2] : "dist/stills") {
        render($1, $0)
    }
    exit(0)
}
let outPath = args.first ?? "dist/thock-motion.mp4"

// MARK: sound

let packs = packInfos.map { Pack($0.id, $0.name) }
let mouseDown = loadMono("mouse-packs/mx-master-3s/down.wav"), mouseUp = loadMono("mouse-packs/mx-master-3s/up.wav")
let mixer = Mixer(seconds: total)
let codes: [String: Int] = ["space": 57, "shiftL": 42, ".": 52, ",": 51, "'": 40]
for s in strokes {
    let code = codes[s.key] ?? scan[Character(s.key.lowercased())] ?? 30
    let p = packs[s.pack]
    let db = -18 + 18 * s.force, cutoff: Double? = s.force > 0.95 ? nil : 900 * pow(22, s.force)
    let rate = rng.range(0.975, 1.025), pan = rng.range(-0.25, 0.25)
    mixer.play(p.press(code), at: s.t, db: db, pan: pan, cutoff: cutoff, rate: rate)
    mixer.play(p.release(code), at: s.t + rng.range(0.08, 0.11), db: db - 4, pan: pan, cutoff: cutoff, rate: rate)
}
for t in uiClicks {
    mixer.play(mouseDown, at: t, db: -9, pan: 0.3)
    mixer.play(mouseUp, at: t + 0.07, db: -12, pan: 0.3)
}
for k in taps {
    let db = -12 + 12 * k.force
    mixer.play(mouseDown, at: k.t, db: db, pan: 0.2, rate: rng.range(0.98, 1.02))
    mixer.play(mouseUp, at: k.t + 0.08, db: db - 3, pan: 0.2)
}
let music = Music(seconds: total)
for p in pops { music.pop(at: p.t, pitch: p.pitch, gain: 0.35) }
music.compose()
// music under the keys; it steps back in the key-force bars so light taps stay audible
for i in 0..<min(mixer.n, music.n) {
    let t = Double(i) / Double(SR)
    let breakdown = smooth((t - at(7) + 0.15) / 0.3) * (1 - smooth((t - at(9) + 0.05) / 0.1))
    let g = 0.24 * (1 - 0.7 * breakdown)
    mixer.muL[i] = Float(music.L[i] * g); mixer.muR[i] = Float(music.R[i] * g)
}
let (outL, outR) = mixer.master()

encodeVideo(to: outPath, seconds: total, audio: (outL, outR)) { render($1, $0) }
let poster = canvas(W, H)
render(poster, at(15, 3))
writePNG(poster.makeImage()!, outPath.replacingOccurrences(of: ".mp4", with: "-poster.png"))
print("wrote \(outPath): \(W)x\(H) \(FPS) fps, \(String(format: "%.1f", total)) s")
