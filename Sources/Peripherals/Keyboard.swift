/// PC-8801 Keyboard — 15-row scan matrix accessible via I/O ports 0x00-0x0E.
///
/// Each row returns 8 bits. A bit value of 0 means the key is pressed,
/// 1 means not pressed (active low).
///
/// Row layout:
/// ```
/// Row 00: KP0  KP1  KP2  KP3  KP4  KP5  KP6  KP7
/// Row 01: KP8  KP9  KP*  KP+  KP=  KP,  KP.  RETURN(KP)
/// Row 02: @    A    B    C    D    E    F    G
/// Row 03: H    I    J    K    L    M    N    O
/// Row 04: P    Q    R    S    T    U    V    W
/// Row 05: X    Y    Z    [    ¥    ]    ^    -
/// Row 06: 0    1    2    3    4    5    6    7
/// Row 07: 8    9    :    ;    ,    .    /    _
/// Row 08: CLR  UP   RIGHT DEL  GRPH KANA SHIFT CTRL
/// Row 09: STOP F1   F2   F3   F4   F5   SPACE ESC
/// Row 0A: TAB  DOWN LEFT HELP COPY KP-  KP/  CAPS
/// Row 0B: ROLLDOWN ROLLUP (unused...)
/// Row 0C: F6   F7   F8   F9   F10  BS   INS  DEL2
/// Row 0D: HENKAN KETTEI PC  ZENKAKU (unused...)
/// Row 0E: (model-specific, unused for FA)
/// ```
public final class Keyboard {

    /// 15 rows of keyboard state. 0xFF = no keys pressed (active low).
    public var matrix: [UInt8] = Array(repeating: 0xFF, count: 15)

    public init() {}

    public func reset() {
        matrix = Array(repeating: 0xFF, count: 15)
    }

    /// Read a keyboard row (port 0x00-0x0E).
    public func readRow(_ row: UInt8) -> UInt8 {
        let index = Int(row & 0x0F)
        guard index < 15 else { return 0xFF }
        return matrix[index]
    }

    /// Press a key (set bit to 0 = pressed, active low).
    public func pressKey(row: Int, bit: Int) {
        guard row < 15, bit < 8 else { return }
        matrix[row] &= ~UInt8(1 << bit)
    }

    /// Release a key (set bit to 1 = released, active low).
    public func releaseKey(row: Int, bit: Int) {
        guard row < 15, bit < 8 else { return }
        matrix[row] |= UInt8(1 << bit)
    }

    /// Release all keys.
    public func releaseAll() {
        matrix = Array(repeating: 0xFF, count: 15)
    }
}

// MARK: - Key Constants

extension Keyboard {

    /// PC-8801 key identifier: (row, bit).
    public struct Key: Equatable, Hashable, Sendable {
        public let row: Int
        public let bit: Int
        public init(_ row: Int, _ bit: Int) { self.row = row; self.bit = bit }
    }

    // Row 0: Numpad
    public static let kp0 = Key(0, 0)
    public static let kp1 = Key(0, 1)
    public static let kp2 = Key(0, 2)
    public static let kp3 = Key(0, 3)
    public static let kp4 = Key(0, 4)
    public static let kp5 = Key(0, 5)
    public static let kp6 = Key(0, 6)
    public static let kp7 = Key(0, 7)

    // Row 1: Numpad continued
    public static let kp8 = Key(1, 0)
    public static let kp9 = Key(1, 1)
    public static let kpMultiply = Key(1, 2)
    public static let kpPlus = Key(1, 3)
    public static let kpEqual = Key(1, 4)
    public static let kpComma = Key(1, 5)
    public static let kpPeriod = Key(1, 6)
    public static let kpReturn = Key(1, 7)

    // Row 2: @ A-G
    public static let at = Key(2, 0)
    public static let a = Key(2, 1)
    public static let b = Key(2, 2)
    public static let c = Key(2, 3)
    public static let d = Key(2, 4)
    public static let e = Key(2, 5)
    public static let f = Key(2, 6)
    public static let g = Key(2, 7)

    // Row 3: H-O
    public static let h = Key(3, 0)
    public static let i = Key(3, 1)
    public static let j = Key(3, 2)
    public static let k = Key(3, 3)
    public static let l = Key(3, 4)
    public static let m = Key(3, 5)
    public static let n = Key(3, 6)
    public static let o = Key(3, 7)

    // Row 4: P-W
    public static let p = Key(4, 0)
    public static let q = Key(4, 1)
    public static let r = Key(4, 2)
    public static let s = Key(4, 3)
    public static let t = Key(4, 4)
    public static let u = Key(4, 5)
    public static let v = Key(4, 6)
    public static let w = Key(4, 7)

    // Row 5: X-Z, symbols
    public static let x = Key(5, 0)
    public static let y = Key(5, 1)
    public static let z = Key(5, 2)
    public static let leftBracket = Key(5, 3)
    public static let yen = Key(5, 4)
    public static let rightBracket = Key(5, 5)
    public static let caret = Key(5, 6)
    public static let minus = Key(5, 7)

    // Row 6: 0-7
    public static let key0 = Key(6, 0)
    public static let key1 = Key(6, 1)
    public static let key2 = Key(6, 2)
    public static let key3 = Key(6, 3)
    public static let key4 = Key(6, 4)
    public static let key5 = Key(6, 5)
    public static let key6 = Key(6, 6)
    public static let key7 = Key(6, 7)

    // Row 7: 8-9, symbols
    public static let key8 = Key(7, 0)
    public static let key9 = Key(7, 1)
    public static let colon = Key(7, 2)
    public static let semicolon = Key(7, 3)
    public static let comma = Key(7, 4)
    public static let period = Key(7, 5)
    public static let slash = Key(7, 6)
    public static let underscore = Key(7, 7)

    // Row 8: Control keys
    public static let clr = Key(8, 0)
    public static let up = Key(8, 1)
    public static let right = Key(8, 2)
    public static let del = Key(8, 3)
    public static let grph = Key(8, 4)
    public static let kana = Key(8, 5)
    public static let shift = Key(8, 6)
    public static let ctrl = Key(8, 7)

    // Row 9: Function keys, space, esc
    public static let stop = Key(9, 0)
    public static let f1 = Key(9, 1)
    public static let f2 = Key(9, 2)
    public static let f3 = Key(9, 3)
    public static let f4 = Key(9, 4)
    public static let f5 = Key(9, 5)
    public static let space = Key(9, 6)
    public static let esc = Key(9, 7)

    // Row 10: Tab, arrows, etc.
    public static let tab = Key(0x0A, 0)
    public static let down = Key(0x0A, 1)
    public static let left = Key(0x0A, 2)
    public static let help = Key(0x0A, 3)
    public static let copy = Key(0x0A, 4)
    public static let kpMinus = Key(0x0A, 5)
    public static let kpDivide = Key(0x0A, 6)
    public static let capsLock = Key(0x0A, 7)

    // Row 11: Roll
    public static let rollDown = Key(0x0B, 0)
    public static let rollUp = Key(0x0B, 1)

    // Row 12: F6-F10, editing
    public static let f6 = Key(0x0C, 0)
    public static let f7 = Key(0x0C, 1)
    public static let f8 = Key(0x0C, 2)
    public static let f9 = Key(0x0C, 3)
    public static let f10 = Key(0x0C, 4)
    public static let bs = Key(0x0C, 5)
    public static let ins = Key(0x0C, 6)
    public static let del2 = Key(0x0C, 7)

    // Row 13: Japanese input
    public static let henkan = Key(0x0D, 0)
    public static let kettei = Key(0x0D, 1)
    public static let pc = Key(0x0D, 2)
    public static let zenkaku = Key(0x0D, 3)
}
