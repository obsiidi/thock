import Foundation

// thock — mechanical keyboard sounds for the built-in MacBook keyboard.
//
// Phase 0: keystroke capture only. Exit codes:
//   0 ok · 1 self-test failed · 2 missing permission · 3 tap creation failed

setvbuf(stdout, nil, _IOLBF, 0)

enum Mode {
    case help
    case diag
    case selftestTap
}

var mode: Mode = .diag
var printAll = false
var count = 20
var idleSeconds = 60.0

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
    default:
        stderrLine("thock: unknown argument \(a)")
        exit(64)
    }
}

switch mode {
case .help:
    print("""
    usage: thock [options]

      --diag                one line per keyDown (default mode)
        --all               also print keyUp and flagsChanged
      --selftest-tap        post synthetic keystrokes, verify capture, exit 0/1
        --count N           keystrokes per burst (default 20)
        --idle S            seconds to idle between the two bursts (default 60)
      --help                show this help
    """)
    exit(0)
case .diag:
    exit(runDiag(printAll: printAll))
case .selftestTap:
    exit(runTapSelftest(count: count, idleSeconds: idleSeconds))
}
