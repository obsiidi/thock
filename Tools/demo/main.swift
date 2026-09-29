// Tools/demo — renders the thock demo video: a 3D laptop (SceneKit) with the
// real app on its screen, sweeping camera moves, original synthesised music
// and the real pack sounds in sync with every keystroke. 1920x1080, 30 fps,
// H.264 + AAC, ~35 s. Apple frameworks only.
//
//   swift build -c release && .build/release/thock --render-popover dist/popover
//   swiftc -O Tools/videokit/*.swift Tools/demo/*.swift -o /tmp/demo && /tmp/demo dist/thock-demo.mp4
//   /tmp/demo --stills 5.5,12,20 dist/stills      (single frames for checking)
//
// Run from the repo root (reads packs/, mouse-packs/, site/fonts/, dist/popover/).
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

registerFonts()
buildTimeline()
let args = Array(CommandLine.arguments.dropFirst())
let popDir = "dist/popover"
guard FileManager.default.fileExists(atPath: popDir + "/statusicon.png") else {
    print("demo: render the popover first: .build/release/thock --render-popover \(popDir)")
    exit(1)
}
let screen = Screen(popoverDir: popDir)
let stage = Stage(screen: screen)

func compose(_ t: Double, into c: CGContext) {
    draw(c, stage.frame(t), in: CGRect(x: 0, y: 0, width: W, height: H))
    overlay(c, t)
}
if args.first == "--stills" {
    writeStills(args[1].split(separator: ",").compactMap { Double($0) }, dir: args.count > 2 ? args[2] : "dist/stills") {
        compose($0, into: $1)
    }
    exit(0)
}
let outPath = args.first ?? "dist/thock-demo.mp4"

// MARK: sound

let packs = packInfos.map { Pack($0.id, $0.name) }
let mouseDown = loadMono("mouse-packs/mx-master-3s/down.wav"), mouseUp = loadMono("mouse-packs/mx-master-3s/up.wav")
let mixer = Mixer(seconds: total)
let codes: [String: Int] = ["space": 57, "shiftL": 42, ".": 52, ",": 51, "'": 40]
for s in strokes {
    let code = codes[s.key] ?? scan[Character(s.key.lowercased())] ?? 30
    let p = packs[packAt(s.t)]
    let pan = Double(stage.keyPos(s.key).x) / 0.13 * 0.45
    let db = -20 + 20 * s.force, cutoff: Double? = s.force > 0.95 ? nil : 900 * pow(22, s.force)
    let rate = rng.range(0.975, 1.025)
    mixer.play(p.press(code), at: s.t, db: db, pan: pan, cutoff: cutoff, rate: rate)
    mixer.play(p.release(code), at: s.t + rng.range(0.08, 0.11), db: db - 4, pan: pan, cutoff: cutoff, rate: rate)
}
for k in clicks {
    let db = -12 + 12 * k.force
    mixer.play(mouseDown, at: k.t, db: db, pan: 0.1, rate: rng.range(0.98, 1.02))
    mixer.play(mouseUp, at: k.t + 0.08, db: db - 3, pan: 0.1)
}
let music = Music(seconds: total)
music.compose()
// music sits under the keys, and steps well back in the key-force bars so light taps stay audible
for i in 0..<min(mixer.n, music.n) {
    let t = Double(i) / Double(SR)
    let breakdown = smooth((t - at(7) + 0.15) / 0.3) * (1 - smooth((t - at(9) + 0.05) / 0.1))
    let g = 0.2 * (1 - 0.72 * breakdown)
    mixer.muL[i] = Float(music.L[i] * g); mixer.muR[i] = Float(music.R[i] * g)
}
let (outL, outR) = mixer.master()

// MARK: encode

encodeVideo(to: outPath, seconds: total, audio: (outL, outR)) { compose($0, into: $1) }
let poster = canvas(W, H)
compose(at(14, 3), into: poster)
writePNG(poster.makeImage()!, outPath.replacingOccurrences(of: ".mp4", with: "-poster.png"))
print("wrote \(outPath): \(W)x\(H) \(FPS) fps, \(String(format: "%.1f", total)) s")
