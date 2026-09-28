import Foundation

// The script: every keystroke, click, pack switch and popover state, on the
// music grid (104 BPM). Bars are 1-based; at(bar, beat) gives seconds.
//
//  1–2  intro, camera sweeps in                 "Your Mac has a great keyboard." / "It just doesn't sound like one."
//  3–4  drop: push into the menu bar, popover   "Pick a switch."
//  5–6  swoop to the keyboard, typing line 1    "Every key is a real recording."
//  7–8  macro on the keys: soft vs. hard        "It hears how hard you hit."   (music breaks down)
//  9–10 up to the popover: seven packs, a beat each
//  11   typing line 2 on Topre
//  12   trackpad clicks                          "Clicks sound like a mouse again."
//  13–15 hero shot, wordmark, end card

struct PackInfo { let id: String; let name: String; let kind: String }
let packInfos = [
    PackInfo(id: "cherrymx-blue-abs", name: "Cherry MX Blue", kind: "clicky"),
    PackInfo(id: "cherrymx-brown-abs", name: "Cherry MX Brown", kind: "tactile"),
    PackInfo(id: "cherrymx-red-abs", name: "Cherry MX Red", kind: "linear"),
    PackInfo(id: "cherrymx-black-abs", name: "Cherry MX Black", kind: "linear, heavy"),
    PackInfo(id: "holy-pandas", name: "Holy Pandas", kind: "tactile"),
    PackInfo(id: "nk-cream", name: "NK Cream", kind: "linear"),
    PackInfo(id: "topre-purple-hybrid-pbt", name: "Topre", kind: "electro-capacitive"),
]
let topreIndex = 6

/// Physical key press for the 3D keyboard and the sound.
struct Stroke { let t: Double; let key: String; let force: Double }
/// A character appearing in the editor.
struct Typed { let t: Double; let ch: Character; let line: Int }

let line1 = "This is a MacBook keyboard."
let line2 = "Now it sounds like this."

var strokes: [Stroke] = []
var typed: [Typed] = []

func keyName(_ ch: Character) -> String {
    switch ch {
    case " ": return "space"
    case ".": return "."
    case ",": return ","
    case "'": return "'"
    default: return String(ch).uppercased()
    }
}
func typeLine(_ s: String, line: Int, from t0: Double, step: Double) {
    var t = t0
    for ch in s {
        let tt = t + rng.range(-0.012, 0.012)
        if ch.isUppercase { strokes.append(Stroke(t: tt - 0.05, key: "shiftL", force: 0.5)) }
        strokes.append(Stroke(t: tt, key: keyName(ch), force: rng.range(0.55, 0.8)))
        typed.append(Typed(t: tt, ch: ch, line: line))
        t += step
    }
}

var forceHits: [Stroke] = []
var packSwitches: [(t: Double, pack: Int)] = [(0, topreIndex), (at(4, 2), 0)]

/// Fills the event lists; call once before rendering.
func buildTimeline() {
    // line 1 on sixteenths, line 2 a little faster
    typeLine(line1, line: 0, from: at(5, 1), step: beat / 4)
    typeLine(line2, line: 1, from: at(11) + 0.05, step: 0.094)

    // key force: eight light taps, then firm hits and a roll into the drop
    for k in 0..<8 { forceHits.append(Stroke(t: at(7, Double(k) * 0.5), key: k % 2 == 0 ? "F" : "J", force: rng.range(0.14, 0.3))) }
    for k in 0..<3 { forceHits.append(Stroke(t: at(8, Double(k)), key: k % 2 == 0 ? "J" : "F", force: rng.range(0.9, 1))) }
    for k in 0..<4 { forceHits.append(Stroke(t: at(8, 3 + Double(k) * 0.25), key: ["F", "J", "F", "J"][k], force: rng.range(0.85, 1))) }
    strokes += forceHits

    // seven packs, one per beat, three keys each
    for k in 0..<7 {
        let t = at(9, Double(k))
        packSwitches.append((t, k))
        for (j, key) in ["F", "J", "K"].enumerated() {
            strokes.append(Stroke(t: t + 0.04 + Double(j) * beat / 4, key: key, force: rng.range(0.6, 0.85)))
        }
    }
    for (i, ch) in "thock".enumerated() { strokes.append(Stroke(t: wordmarkTimes[i], key: keyName(ch), force: 0.8)) }
    strokes.append(Stroke(t: finalHit, key: "space", force: 1))
    strokes.sort { $0.t < $1.t }
}

func packAt(_ t: Double) -> Int { packSwitches.last { $0.t <= t }?.pack ?? topreIndex }

// hero: the wordmark typed on eighths, then one last space bar
let wordmarkTimes = (0..<5).map { at(13, 2 + Double($0) * 0.5) }
let finalHit = at(15)

// trackpad clicks: light, firm, light, firm-firm
struct Click { let t: Double; let force: Double; let u: Double; let v: Double }
let clicks = [
    Click(t: at(12, 0), force: 0.35, u: 0.35, v: 0.45), Click(t: at(12, 1), force: 0.95, u: 0.6, v: 0.55),
    Click(t: at(12, 2), force: 0.3, u: 0.45, v: 0.7), Click(t: at(12, 3), force: 0.9, u: 0.66, v: 0.38),
    Click(t: at(12, 3.5), force: 0.9, u: 0.66, v: 0.38),
]

// popover open intervals (clicks on the menu bar icon / into the editor)
let popoverSpans: [(open: Double, close: Double)] = [(at(3, 2), at(5)), (at(9), at(11)), (at(13), 99)]
func popoverAlpha(_ t: Double) -> Double {
    for s in popoverSpans where t >= s.open - 0.01 && t < s.close + 0.2 {
        return smooth((t - s.open) / 0.12) * (1 - smooth((t - s.close) / 0.12))
    }
    return 0
}
