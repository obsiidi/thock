import Foundation

// The script, on a 104 BPM grid (bars 1-based, at(bar, beat) in seconds).
//
//  1–2   a line-drawn MacBook builds itself      "Your Mac has a great keyboard." / "It just doesn't sound like one."
//  3–4   zoom into the menu bar: popover, pick NK Cream from the pack menu      "Pick a switch."
//  5–6   big keyboard, the headline is typed on it                              "Every key is a real recording."
//  7–8   F and J, light taps then firm hits (music steps back)                   "It hears how hard you hit."
//  9–10  seven pack cards, one per beat, each with its own sound                 "Seven real recordings."
//  11    trackpad taps                                                          "Clicks sound like a mouse again."
//  12–13 the stats window fills in                                              "Your typing, counted on your Mac."
//  14–15 dot wordmark, facts, address

let total = at(16) + 0.4

struct PackInfo { let id: String; let name: String; let menuName: String; let kind: String; let color: UInt32; let text: UInt32 }
let packInfos = [
    PackInfo(id: "cherrymx-blue-abs", name: "Cherry MX Blue", menuName: "CherryMX Blue - ABS keycaps", kind: "CLICKY", color: 0x3B6CF6, text: P.white),
    PackInfo(id: "cherrymx-brown-abs", name: "Cherry MX Brown", menuName: "CherryMX Brown - ABS keycaps", kind: "TACTILE", color: 0x9A6842, text: P.white),
    PackInfo(id: "cherrymx-red-abs", name: "Cherry MX Red", menuName: "CherryMX Red - ABS keycaps", kind: "LINEAR", color: 0xE8483B, text: P.white),
    PackInfo(id: "cherrymx-black-abs", name: "Cherry MX Black", menuName: "CherryMX Black - ABS keycaps", kind: "LINEAR · HEAVY", color: 0x141414, text: P.white),
    PackInfo(id: "holy-pandas", name: "Holy Pandas", menuName: "pandas", kind: "TACTILE", color: 0xF4B9C8, text: P.ink),
    PackInfo(id: "topre-purple-hybrid-pbt", name: "Topre", menuName: "Topre Purple Hybrid - PBT keycaps", kind: "ELECTRO-CAPACITIVE", color: 0x7C5CF2, text: P.white),
    PackInfo(id: "nk-cream", name: "NK Cream", menuName: "NK Cream (original by Ryan)", kind: "LINEAR · DEFAULT", color: 0xF3DFB2, text: P.ink),
]
let creamIndex = 6, topreIndex = 5
/// Order of the pack menu in the app (by folder name).
let menuOrder = [3, 0, 1, 2, 4, 6, 5]

struct Stroke { let t: Double; let key: String; let force: Double; let pack: Int }
var strokes: [Stroke] = []

// intro flourish: the keys pop in as a quick run
let introPops = (0..<14).map { 0.95 + Double($0) * 0.045 }

// scene 3: the headline is typed on sixteenths
let headline3 = "Every key is a real recording."
let typeTimes: [Double] = (0..<headline3.count).map { at(5, 0.25) + Double($0) * beat / 4 }

// scene 4: F and J — eight light taps, then firm hits and a roll
var forceHits: [Stroke] = []

// scene 5: seven cards, one per beat, NK Cream last
let cardOrder = [0, 1, 2, 3, 4, 5, 6]
let cardTimes = (0..<7).map { at(9, Double($0)) }

// scene 6: trackpad taps
struct Tap { let t: Double; let force: Double; let u: Double; let v: Double }
let taps = [
    Tap(t: at(11, 0), force: 0.35, u: 0.3, v: 0.45), Tap(t: at(11, 1), force: 0.95, u: 0.62, v: 0.4),
    Tap(t: at(11, 2), force: 0.3, u: 0.42, v: 0.68), Tap(t: at(11, 3), force: 0.9, u: 0.7, v: 0.62),
    Tap(t: at(11, 3.5), force: 0.9, u: 0.7, v: 0.62),
]

// UI clicks with the pointer (scene 2)
let iconClick = at(3, 1), pickerClick = at(3, 3), menuPick = at(4, 0.5), forceToggle = at(4, 2)
let uiClicks = [iconClick, pickerClick, menuPick, forceToggle]

// outro: the wordmark typed on eighths, then one last space bar
let wordTimes = (0..<5).map { at(14, Double($0) * 0.5) }
let finalHit = at(15)

// soft UI pops (music bus) where things spring in
var pops: [(t: Double, pitch: Double)] = []

func buildTimeline() {
    let keyOf: (Character) -> String = { ch in ch == " " ? "space" : (ch == "." ? "." : String(ch).uppercased()) }
    for (i, k) in ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "A", "S", "D", "F"].enumerated() {
        strokes.append(Stroke(t: introPops[i], key: k, force: 0.45, pack: creamIndex))
    }
    for (i, ch) in headline3.enumerated() {
        let t = typeTimes[i] + rng.range(-0.01, 0.01)
        if ch.isUppercase { strokes.append(Stroke(t: t - 0.05, key: "shiftL", force: 0.45, pack: creamIndex)) }
        strokes.append(Stroke(t: t, key: keyOf(ch), force: rng.range(0.6, 0.8), pack: creamIndex))
    }
    for k in 0..<8 { forceHits.append(Stroke(t: at(7, Double(k) * 0.5), key: k % 2 == 0 ? "F" : "J", force: rng.range(0.14, 0.28), pack: creamIndex)) }
    for k in 0..<3 { forceHits.append(Stroke(t: at(8, Double(k)), key: k % 2 == 0 ? "J" : "F", force: rng.range(0.9, 1), pack: creamIndex)) }
    for k in 0..<4 { forceHits.append(Stroke(t: at(8, 3 + Double(k) * 0.25), key: k % 2 == 0 ? "F" : "J", force: rng.range(0.85, 1), pack: creamIndex)) }
    strokes += forceHits
    for (i, t) in cardTimes.enumerated() {
        for (j, key) in ["F", "J", "K"].enumerated() {
            strokes.append(Stroke(t: t + 0.05 + Double(j) * beat / 4, key: key, force: rng.range(0.65, 0.85), pack: cardOrder[i]))
        }
    }
    for (i, ch) in "thock".enumerated() { strokes.append(Stroke(t: wordTimes[i], key: keyOf(ch), force: 0.75, pack: creamIndex)) }
    strokes.append(Stroke(t: finalHit, key: "space", force: 1, pack: creamIndex))
    strokes.sort { $0.t < $1.t }

    pops = [(at(1, 3.5), 1.0), (at(3, 1) + 0.05, 1.2)]
    for k in 0..<4 { pops.append((at(12, 0.5) + Double(k) * 0.18, 1 + Double(k) * 0.12)) }
    pops += [(at(12, 2), 1.4), (at(14, 3), 1.1), (at(15, 1), 1.3)]
}
