import Foundation

/// CGKeyCode (macOS virtual key codes, Carbon `kVK_*`) → Mechvibes key code.
///
/// Mechvibes packs are keyed by libuiohook codes: Windows set-1 scancodes,
/// with extended keys carrying a prefix byte (0x0E for right-hand modifiers,
/// nav cluster and keypad extras, 0xE0 for the arrow keys). Examples:
/// 57 space, 28 enter, 14 backspace, 3613 right ctrl, 3675 left cmd,
/// 57416 arrow up. Values are taken from uiohook.h, not guessed; keys that
/// libuiohook does not know (fn, media keys, JIS extras) map to -1 and fall
/// back to the pack's default sound.
///
/// Index = CGKeyCode (0...127). Fixed array, no hashing on the hot path.
enum Scancodes {
    static let unmapped: Int32 = -1

    static let table: [Int32] = {
        var t = [Int32](repeating: unmapped, count: 128)
        func set(_ cg: Int, _ code: Int32) { t[cg] = code }

        // Letters
        set(0, 0x1E)   // A
        set(1, 0x1F)   // S
        set(2, 0x20)   // D
        set(3, 0x21)   // F
        set(4, 0x23)   // H
        set(5, 0x22)   // G
        set(6, 0x2C)   // Z
        set(7, 0x2D)   // X
        set(8, 0x2E)   // C
        set(9, 0x2F)   // V
        set(11, 0x30)  // B
        set(12, 0x10)  // Q
        set(13, 0x11)  // W
        set(14, 0x12)  // E
        set(15, 0x13)  // R
        set(16, 0x15)  // Y
        set(17, 0x14)  // T
        set(31, 0x18)  // O
        set(32, 0x16)  // U
        set(34, 0x17)  // I
        set(35, 0x19)  // P
        set(37, 0x26)  // L
        set(38, 0x24)  // J
        set(40, 0x25)  // K
        set(45, 0x31)  // N
        set(46, 0x32)  // M

        // Number row
        set(18, 0x02)  // 1
        set(19, 0x03)  // 2
        set(20, 0x04)  // 3
        set(21, 0x05)  // 4
        set(23, 0x06)  // 5
        set(22, 0x07)  // 6
        set(26, 0x08)  // 7
        set(28, 0x09)  // 8
        set(25, 0x0A)  // 9
        set(29, 0x0B)  // 0
        set(27, 0x0C)  // -
        set(24, 0x0D)  // =

        // Punctuation
        set(50, 0x29)  // ` (ANSI) / ^ (ISO top-left)
        set(10, 0x56)  // ISO section key (<> left of Z/Y on ISO boards)
        set(33, 0x1A)  // [
        set(30, 0x1B)  // ]
        set(42, 0x2B)  // backslash
        set(41, 0x27)  // ;
        set(39, 0x28)  // '
        set(43, 0x33)  // ,
        set(47, 0x34)  // .
        set(44, 0x35)  // /

        // Whitespace / control
        set(36, 0x1C)  // return
        set(48, 0x0F)  // tab
        set(49, 0x39)  // space
        set(51, 0x0E)  // delete (backspace)
        set(53, 0x01)  // escape
        set(117, 0x0E53) // forward delete

        // Modifiers
        set(56, 0x2A)    // shift
        set(60, 0x36)    // right shift
        set(59, 0x1D)    // control
        set(62, 0x0E1D)  // right control
        set(58, 0x38)    // option
        set(61, 0x0E38)  // right option
        set(55, 0x0E5B)  // command
        set(54, 0x0E5C)  // right command
        set(57, 0x3A)    // caps lock
        set(110, 0x0E5D) // context menu (PC keyboards)

        // Function row
        set(122, 0x3B)   // F1
        set(120, 0x3C)   // F2
        set(99, 0x3D)    // F3
        set(118, 0x3E)   // F4
        set(96, 0x3F)    // F5
        set(97, 0x40)    // F6
        set(98, 0x41)    // F7
        set(100, 0x42)   // F8
        set(101, 0x43)   // F9
        set(109, 0x44)   // F10
        set(103, 0x57)   // F11
        set(111, 0x58)   // F12
        set(105, 0x5B)   // F13
        set(107, 0x5C)   // F14
        set(113, 0x5D)   // F15
        set(106, 0x63)   // F16
        set(64, 0x64)    // F17
        set(79, 0x65)    // F18
        set(80, 0x66)    // F19
        set(90, 0x67)    // F20

        // Navigation
        set(114, 0x0E52) // help / insert
        set(115, 0x0E47) // home
        set(119, 0x0E4F) // end
        set(116, 0x0E49) // page up
        set(121, 0x0E51) // page down
        set(123, 0xE04B) // left
        set(124, 0xE04D) // right
        set(125, 0xE050) // down
        set(126, 0xE048) // up

        // Keypad
        set(71, 0x45)    // clear / num lock
        set(81, 0x0E0D)  // =
        set(75, 0x0E35)  // /
        set(67, 0x37)    // *
        set(78, 0x4A)    // -
        set(69, 0x4E)    // +
        set(76, 0x0E1C)  // enter
        set(65, 0x53)    // .
        set(82, 0x52)    // 0
        set(83, 0x4F)    // 1
        set(84, 0x50)    // 2
        set(85, 0x51)    // 3
        set(86, 0x4B)    // 4
        set(87, 0x4C)    // 5
        set(88, 0x4D)    // 6
        set(89, 0x47)    // 7
        set(91, 0x48)    // 8
        set(92, 0x49)    // 9

        // Apple ISO boards (e.g. German) report the top-left key as 10 and
        // the key left of Z as 50 — swap so each gets its physical sound.
        if KeyboardLayout.isISO {
            t.swapAt(10, 50)
        }
        return t
    }()

    /// Physical row of a key, for packs with per-row generic sounds
    /// (`GENERIC_R{0-4}`): 0 = number/function row … 4 = bottom row.
    static let row: [UInt8] = {
        var r = [UInt8](repeating: 2, count: 128)
        let row0: [Int] = [53, 50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51,
                           122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                           105, 107, 113, 106, 64, 79, 80, 90, 114, 115, 116, 71, 81, 75, 67]
        let row1: [Int] = [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42,
                           117, 119, 121, 89, 91, 92, 78]
        let row2: [Int] = [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36, 86, 87, 88, 69]
        let row3: [Int] = [56, 10, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60, 126, 83, 84, 85]
        let row4: [Int] = [63, 59, 58, 55, 49, 54, 61, 62, 110, 123, 125, 124, 82, 65, 76]
        for k in row0 { r[k] = 0 }
        for k in row1 { r[k] = 1 }
        for k in row2 { r[k] = 2 }
        for k in row3 { r[k] = 3 }
        for k in row4 { r[k] = 4 }
        return r
    }()

    /// Human-readable names for --map and --diag.
    static let names: [String] = {
        var n = [String](repeating: "", count: 128)
        let pairs: [(Int, String)] = [
            (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"), (5, "G"), (6, "Z"), (7, "X"), (8, "C"),
            (9, "V"), (10, "ISO<>"), (11, "B"), (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (16, "Y"),
            (17, "T"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="),
            (25, "9"), (26, "7"), (27, "-"), (28, "8"), (29, "0"), (30, "]"), (31, "O"), (32, "U"),
            (33, "["), (34, "I"), (35, "P"), (36, "Return"), (37, "L"), (38, "J"), (39, "'"), (40, "K"),
            (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "N"), (46, "M"), (47, "."), (48, "Tab"),
            (49, "Space"), (50, "`"), (51, "Backspace"), (53, "Esc"), (54, "RCmd"), (55, "Cmd"),
            (56, "Shift"), (57, "CapsLock"), (58, "Option"), (59, "Ctrl"), (60, "RShift"),
            (61, "ROption"), (62, "RCtrl"), (63, "Fn"), (64, "F17"), (65, "KP."), (67, "KP*"),
            (69, "KP+"), (71, "KPClear"), (72, "VolUp"), (73, "VolDown"), (74, "Mute"), (75, "KP/"),
            (76, "KPEnter"), (78, "KP-"), (79, "F18"), (80, "F19"), (81, "KP="), (82, "KP0"),
            (83, "KP1"), (84, "KP2"), (85, "KP3"), (86, "KP4"), (87, "KP5"), (88, "KP6"), (89, "KP7"),
            (90, "F20"), (91, "KP8"), (92, "KP9"), (96, "F5"), (97, "F6"), (98, "F7"), (99, "F3"),
            (100, "F8"), (101, "F9"), (103, "F11"), (105, "F13"), (106, "F16"), (107, "F14"),
            (109, "F10"), (110, "Menu"), (111, "F12"), (113, "F15"), (114, "Insert"), (115, "Home"),
            (116, "PageUp"), (117, "Delete"), (118, "F4"), (119, "End"), (120, "F2"), (121, "PageDown"),
            (122, "F1"), (123, "Left"), (124, "Right"), (125, "Down"), (126, "Up"),
        ]
        for (k, v) in pairs { n[k] = v }
        return n
    }()

    static func name(_ keyCode: Int) -> String {
        guard keyCode >= 0, keyCode < 128, !names[keyCode].isEmpty else { return "kc\(keyCode)" }
        return names[keyCode]
    }
}
