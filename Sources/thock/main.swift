import Foundation

// thock — mechanical keyboard sounds for the built-in MacBook keyboard.
// Phase 0 skeleton: argument parsing only, no functionality yet.

let args = CommandLine.arguments.dropFirst()

if args.contains("--help") || args.contains("-h") {
    print("""
    usage: thock [options]

      --diag       print one line per keystroke (Phase 0+)
      --selftest   run synthetic keystrokes, exit 0/1 (Phase 1+)
      --help       show this help
    """)
    exit(0)
}

print("thock: skeleton build, nothing implemented yet")
exit(0)
