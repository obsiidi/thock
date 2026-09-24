import Foundation

// thock — mechanical keyboard sounds for the built-in MacBook keyboard.
//
// Exit codes:
//   0 ok · 1 self-test failed · 2 missing permission · 3 tap creation failed
//   4 audio setup failed · 64 bad arguments

setvbuf(stdout, nil, _IOLBF, 0)

enum Mode {
    case help
    case app
    case run
    case diag
    case selftest
    case selftestTap
    case listPacks
    case map
    case autostart
    case diagMotion
    case motionSelftest
    case stats
    case statsCard
    case selftestStats
    case selftestPointer
}

var mode: Mode = .app
var printAll = false
var verbose = false
var autostartArg = "status"
var count: Int?
var burst: Int?
var idleSeconds = 60.0
var clickPath = Resources.clickURL.path
var packsDir = Resources.packsRoot.path
var packName: String?
let defaultPack = "topre-purple-hybrid-pbt"
var ioFrames: UInt32 = 128
var jitter: Float = 0.03
var velocity = true
var cardPath = "thock-week.png"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--help", "-h":
        mode = .help
    case "--headless":
        mode = .run
    case "--verbose":
        verbose = true
    case "--diag":
        mode = .diag
    case "--diag-motion":
        mode = .diagMotion
    case "--motion-selftest":
        mode = .motionSelftest
    case "--no-velocity":
        velocity = false
    case "--stats":
        mode = .stats
    case "--selftest-stats":
        mode = .selftestStats
    case "--selftest-pointer":
        mode = .selftestPointer
    case "--stats-card":
        guard let v = args.first else {
            stderrLine("thock: --stats-card needs an output path")
            exit(64)
        }
        args.removeFirst()
        cardPath = v
        mode = .statsCard
    case "--all":
        printAll = true
    case "--selftest":
        mode = .selftest
    case "--selftest-tap":
        mode = .selftestTap
    case "--count":
        guard let v = args.first, let n = Int(v), n > 0 else {
            stderrLine("thock: --count needs a positive integer")
            exit(64)
        }
        args.removeFirst()
        count = n
    case "--burst":
        guard let v = args.first, let n = Int(v), n > 0 else {
            stderrLine("thock: --burst needs a positive integer")
            exit(64)
        }
        args.removeFirst()
        burst = n
        mode = .selftest
    case "--io-frames":
        guard let v = args.first, let n = UInt32(v), n > 0 else {
            stderrLine("thock: --io-frames needs a positive integer")
            exit(64)
        }
        args.removeFirst()
        ioFrames = n
    case "--jitter":
        guard let v = args.first, let j = Float(v), j >= 0, j < 0.5 else {
            stderrLine("thock: --jitter needs a fraction in [0, 0.5)")
            exit(64)
        }
        args.removeFirst()
        jitter = j
    case "--idle":
        guard let v = args.first, let s = Double(v), s >= 0 else {
            stderrLine("thock: --idle needs a non-negative number of seconds")
            exit(64)
        }
        args.removeFirst()
        idleSeconds = s
    case "--click":
        guard let v = args.first else {
            stderrLine("thock: --click needs a path")
            exit(64)
        }
        args.removeFirst()
        clickPath = v
        packName = "click"
    case "--pack":
        guard let v = args.first else {
            stderrLine("thock: --pack needs a name or path")
            exit(64)
        }
        args.removeFirst()
        packName = v
    case "--packs-dir":
        guard let v = args.first else {
            stderrLine("thock: --packs-dir needs a path")
            exit(64)
        }
        args.removeFirst()
        packsDir = v
    case "--autostart":
        guard let v = args.first, ["on", "off", "status"].contains(v) else {
            stderrLine("thock: --autostart needs on|off|status")
            exit(64)
        }
        args.removeFirst()
        autostartArg = v
        mode = .autostart
    case "--list-packs":
        mode = .listPacks
    case "--map":
        mode = .map
    default:
        stderrLine("thock: unknown argument \(a)")
        exit(64)
    }
}

/// Resolves --pack: "click" = built-in, a path with "/" or an existing
/// directory = that directory, otherwise a folder name under --packs-dir.
/// Without --pack: the default pack if present, else the built-in click.
func resolvePack() -> PackSelection {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: packsDir)
    if let name = packName {
        if name == "click" { return .builtIn(clickPath: clickPath) }
        if fm.fileExists(atPath: URL(fileURLWithPath: name).appendingPathComponent("config.json").path) {
            return .directory(URL(fileURLWithPath: name))
        }
        let candidate = root.appendingPathComponent(name)
        if fm.fileExists(atPath: candidate.appendingPathComponent("config.json").path) {
            return .directory(candidate)
        }
        stderrLine("thock: pack \"\(name)\" not found (looked in \(root.path)); see --list-packs")
        exit(64)
    }
    let candidate = root.appendingPathComponent(defaultPack)
    if fm.fileExists(atPath: candidate.appendingPathComponent("config.json").path) {
        return .directory(candidate)
    }
    stderrLine("thock: default pack \(defaultPack) not found, using built-in click")
    return .builtIn(clickPath: clickPath)
}

switch mode {
case .help:
    print("""
    usage: thock [options]

      (no mode)             menu bar app (status item + popover)
        --verbose           log every key event to stdout while the app runs
      --headless            no UI: play the pack's sounds on every key until Ctrl-C
      --diag                same, plus one log line per keyDown
        --all               also log keyUp and modifier (flagsChanged) events
      --selftest            post synthetic keystrokes 100 ms apart, measure
                            latency and prove render per voice; exit 0/1
        --count N           keystrokes (default 50)
        --burst N           N keystrokes 10 ms apart instead (implies --selftest)
      --diag-motion         accelerometer vs. key events: timing and force per
                            keystroke (no key codes logged); Ctrl-C = summary
      --motion-selftest     10 light + 10 hard hits, PASS if clearly separated
      --no-velocity         ignore the accelerometer (fixed loudness)
      --stats               print the local typing stats summary
      --stats-card PATH     render this week's share card as PNG
      --selftest-stats      synthetic keystrokes -> stats counters and file; exit 0/1
      --selftest-pointer    synthetic clicks and scrolls -> mouse sounds; exit 0/1
      --selftest-tap        capture-only self-test, no audio; exit 0/1
        --count N           keystrokes per burst (default 20)
        --idle S            seconds between the two bursts (default 60)
      --list-packs          list packs under --packs-dir (default packs/)
      --map                 print key -> scancode -> sample table for the pack
      --pack NAME|PATH      pack to use (default \(defaultPack)); "click" = built-in
      --packs-dir DIR       where packs live (default packs)
      --click PATH          built-in click WAV (default Samples/click.wav)
      --io-frames N         requested IO buffer size in frames (default 128)
      --jitter F            pitch jitter as a fraction of rate (default 0.03)
      --autostart on|off|status
                            login item via SMAppService (run from inside thock.app)
      --help                show this help
    """)
    exit(0)
case .app:
    runApp(verbose: verbose, bufferFrames: ioFrames)
case .run:
    exit(runMain(resolvePack(), bufferFrames: ioFrames, jitter: jitter, velocity: velocity, log: nil))
case .diag:
    exit(runMain(resolvePack(), bufferFrames: ioFrames, jitter: jitter, velocity: velocity, log: printAll ? .all : .keyDown))
case .diagMotion:
    exit(runDiagMotion())
case .motionSelftest:
    exit(runMotionSelftest(hitsPerGroup: count ?? 10))
case .stats:
    exit(runStats())
case .statsCard:
    exit(runStatsCard(path: cardPath))
case .selftestStats:
    exit(runStatsSelftest(count: count ?? 30))
case .selftestPointer:
    exit(runPointerSelftest(clicks: count ?? 20))
case .autostart:
    exit(runAutostart(autostartArg))
case .listPacks:
    exit(runListPacks(root: URL(fileURLWithPath: packsDir), bufferFrames: ioFrames))
case .map:
    exit(runMap(resolvePack(), bufferFrames: ioFrames))
case .selftest:
    if let n = burst {
        exit(runSelftest(SelftestOptions(
            count: n, spacingMicros: 10_000, selection: resolvePack(), bufferFrames: ioFrames, label: "burst",
            jitter: jitter, verbose: printAll)))
    }
    exit(runSelftest(SelftestOptions(
        count: count ?? 50, spacingMicros: 100_000, selection: resolvePack(), bufferFrames: ioFrames, label: "spaced",
        jitter: jitter, verbose: printAll)))
case .selftestTap:
    exit(runTapSelftest(count: count ?? 20, idleSeconds: idleSeconds))
}
