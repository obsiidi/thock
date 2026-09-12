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
var burst: Int?
var idleSeconds = 60.0
var samplePath = "Samples/click.wav"
var ioFrames: UInt32 = 128
var jitter: Float = 0.03

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
      --selftest            post synthetic keystrokes 100 ms apart, measure
                            latency and prove render per voice; exit 0/1
        --count N           keystrokes (default 50)
        --burst N           N keystrokes 10 ms apart instead (implies --selftest)
      --selftest-tap        capture-only self-test, no audio; exit 0/1
        --count N           keystrokes per burst (default 20)
        --idle S            seconds between the two bursts (default 60)
      --sample PATH         click WAV (default Samples/click.wav)
      --io-frames N         requested IO buffer size in frames (default 128)
      --jitter F            pitch jitter as a fraction of rate (default 0.03)
      --help                show this help
    """)
    exit(0)
case .run:
    exit(runMain(samplePath: samplePath, bufferFrames: ioFrames, jitter: jitter, log: nil))
case .diag:
    exit(runMain(samplePath: samplePath, bufferFrames: ioFrames, jitter: jitter, log: printAll ? .all : .keyDown))
case .selftest:
    if let n = burst {
        exit(runSelftest(SelftestOptions(
            count: n, spacingMicros: 10_000, samplePath: samplePath, bufferFrames: ioFrames, label: "burst",
            jitter: jitter, verbose: printAll)))
    }
    exit(runSelftest(SelftestOptions(
        count: count ?? 50, spacingMicros: 100_000, samplePath: samplePath, bufferFrames: ioFrames, label: "spaced",
        jitter: jitter, verbose: printAll)))
case .selftestTap:
    exit(runTapSelftest(count: count ?? 20, idleSeconds: idleSeconds))
}
