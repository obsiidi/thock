import Foundation

// thock — mechanical keyboard sounds for the built-in MacBook keyboard.
//
// Exit codes:
//   0 ok · 1 self-test failed · 2 missing permission · 3 tap creation failed
//   4 audio setup failed · 64 bad arguments

setvbuf(stdout, nil, _IOLBF, 0)

enum Mode {
    case help
    case run
    case diag
    case selftest
    case selftestTap
}

var mode: Mode = .run
var printAll = false
var count: Int?
var idleSeconds = 60.0
var samplePath = "Samples/click.wav"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--help", "-h":
        mode = .help
    case "--diag":
        mode = .diag
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
    case "--idle":
        guard let v = args.first, let s = Double(v), s >= 0 else {
            stderrLine("thock: --idle needs a non-negative number of seconds")
            exit(64)
        }
        args.removeFirst()
        idleSeconds = s
    case "--sample":
        guard let v = args.first else {
            stderrLine("thock: --sample needs a path")
            exit(64)
        }
        args.removeFirst()
        samplePath = v
    default:
        stderrLine("thock: unknown argument \(a)")
        exit(64)
    }
}

switch mode {
case .help:
    print("""
    usage: thock [options]

      (no mode)             play a click on every keyDown until Ctrl-C
      --diag                same, plus one log line per keyDown
        --all               also log keyUp and flagsChanged
      --selftest            post synthetic keystrokes, measure latency to
                            scheduleBuffer and prove render; exit 0/1
        --count N           keystrokes (default 50)
      --selftest-tap        capture-only self-test, no audio; exit 0/1
        --count N           keystrokes per burst (default 20)
        --idle S            seconds between the two bursts (default 60)
      --sample PATH         click WAV (default Samples/click.wav)
      --help                show this help
    """)
    exit(0)
case .run:
    exit(runMain(samplePath: samplePath, log: nil))
case .diag:
    exit(runMain(samplePath: samplePath, log: printAll ? .all : .keyDown))
case .selftest:
    exit(runSelftest(count: count ?? 50, samplePath: samplePath))
case .selftestTap:
    exit(runTapSelftest(count: count ?? 20, idleSeconds: idleSeconds))
}
