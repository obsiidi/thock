import Carbon
import Foundation

/// Physical MacBook keyboard geometry and the labels printed on the keys
/// for the user's current input layout (QWERTZ shows Z where QWERTY shows Y).
enum KeyboardLayout {
    struct Key: Hashable {
        let code: Int
        let width: Double      // in key units
    }

    /// Apple ISO boards report the top-left key as kVK_ISO_Section (10) and
    /// the key left of Z as kVK_ANSI_Grave (50) — the reverse of ANSI.
    static var isISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == UInt32(kKeyboardISO)
    }

    /// Five rows of a MacBook keyboard (function row omitted).
    static var rows: [[Key]] {
        func k(_ c: Int, _ w: Double = 1) -> Key { Key(code: c, width: w) }
        let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { k($0) }
        let top = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { k($0) }
        let home = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { k($0) }
        let bottom = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { k($0) }
        // every row adds up to 14.5 units so the edges line up
        let space = [k(63), k(59), k(58), k(55, 1.25), k(49, 5), k(54, 1.25), k(61),
                     k(123, 0.75), k(126, 0.75), k(125, 0.75), k(124, 0.75)]
        if isISO {
            return [
                [k(10)] + digits + [k(51, 1.5)],
                [k(48, 1.5)] + top + [k(36, 1)],
                [k(57, 1.75)] + home + [k(42), k(36, 0.75)],
                [k(56, 1.25), k(50)] + bottom + [k(60, 2.25)],
                space,
            ]
        }
        return [
            [k(50)] + digits + [k(51, 1.5)],
            [k(48, 1.5)] + top + [k(42, 1)],
            [k(57, 1.75)] + home + [k(36, 1.75)],
            [k(56, 2.25)] + bottom + [k(60, 2.25)],
            space,
        ]
    }

    private static let specials: [Int: String] = [
        36: "⏎", 48: "⇥", 49: "space", 51: "⌫", 53: "esc", 56: "⇧", 60: "⇧", 57: "⇪",
        59: "⌃", 62: "⌃", 58: "⌥", 61: "⌥", 55: "⌘", 54: "⌘", 63: "fn",
        123: "←", 124: "→", 125: "↓", 126: "↑", 117: "⌦",
    ]

    /// Key-cap labels for all 128 key codes, from the active input layout.
    static func labels() -> [String] {
        var out = (0..<128).map { specials[$0] ?? Scancodes.name($0) }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return out
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<128 where specials[code] == nil {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, 4, &length, &chars)
                guard status == noErr, length > 0 else { continue }
                let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty, s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    // "ß".uppercased() is "SS" — keep characters that grow
                    out[code] = s.uppercased().count == s.count ? s.uppercased() : s
                }
            }
        }
        return out
    }
}
