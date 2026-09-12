/// One key of the PC-8801 keyboard, named by its place in the 15-row scan
/// matrix (I/O ports 0x00-0x0E): `row` is the port, `bit` the bit within it.
///
/// The named keys are statics on the type, so `pc88.pressKey(.a)` works.
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
public struct PC88Key: Equatable, Hashable, Sendable {
  /// The scan-matrix row, 0x00-0x0E: the I/O port the key is read on.
  public let row: Int
  /// The bit within the row, 0-7.
  public let bit: Int
  /// The key at `row` / `bit`. Out-of-range values are accepted, and the
  /// machine ignores them.
  public init(_ row: Int, _ bit: Int) { self.row = row; self.bit = bit }
}

// MARK: - Named keys

extension PC88Key {
  // Row 0: Numpad
  public static let kp0 = PC88Key(0, 0)
  public static let kp1 = PC88Key(0, 1)
  public static let kp2 = PC88Key(0, 2)
  public static let kp3 = PC88Key(0, 3)
  public static let kp4 = PC88Key(0, 4)
  public static let kp5 = PC88Key(0, 5)
  public static let kp6 = PC88Key(0, 6)
  public static let kp7 = PC88Key(0, 7)

  // Row 1: Numpad continued
  public static let kp8 = PC88Key(1, 0)
  public static let kp9 = PC88Key(1, 1)
  public static let kpMultiply = PC88Key(1, 2)
  public static let kpPlus = PC88Key(1, 3)
  public static let kpEqual = PC88Key(1, 4)
  public static let kpComma = PC88Key(1, 5)
  public static let kpPeriod = PC88Key(1, 6)
  public static let kpReturn = PC88Key(1, 7)

  // Row 2: @ A-G
  public static let at = PC88Key(2, 0)
  public static let a = PC88Key(2, 1)
  public static let b = PC88Key(2, 2)
  public static let c = PC88Key(2, 3)
  public static let d = PC88Key(2, 4)
  public static let e = PC88Key(2, 5)
  public static let f = PC88Key(2, 6)
  public static let g = PC88Key(2, 7)

  // Row 3: H-O
  public static let h = PC88Key(3, 0)
  public static let i = PC88Key(3, 1)
  public static let j = PC88Key(3, 2)
  public static let k = PC88Key(3, 3)
  public static let l = PC88Key(3, 4)
  public static let m = PC88Key(3, 5)
  public static let n = PC88Key(3, 6)
  public static let o = PC88Key(3, 7)

  // Row 4: P-W
  public static let p = PC88Key(4, 0)
  public static let q = PC88Key(4, 1)
  public static let r = PC88Key(4, 2)
  public static let s = PC88Key(4, 3)
  public static let t = PC88Key(4, 4)
  public static let u = PC88Key(4, 5)
  public static let v = PC88Key(4, 6)
  public static let w = PC88Key(4, 7)

  // Row 5: X-Z, symbols
  public static let x = PC88Key(5, 0)
  public static let y = PC88Key(5, 1)
  public static let z = PC88Key(5, 2)
  public static let leftBracket = PC88Key(5, 3)
  public static let yen = PC88Key(5, 4)
  public static let rightBracket = PC88Key(5, 5)
  public static let caret = PC88Key(5, 6)
  public static let minus = PC88Key(5, 7)

  // Row 6: 0-7
  public static let key0 = PC88Key(6, 0)
  public static let key1 = PC88Key(6, 1)
  public static let key2 = PC88Key(6, 2)
  public static let key3 = PC88Key(6, 3)
  public static let key4 = PC88Key(6, 4)
  public static let key5 = PC88Key(6, 5)
  public static let key6 = PC88Key(6, 6)
  public static let key7 = PC88Key(6, 7)

  // Row 7: 8-9, symbols
  public static let key8 = PC88Key(7, 0)
  public static let key9 = PC88Key(7, 1)
  public static let colon = PC88Key(7, 2)
  public static let semicolon = PC88Key(7, 3)
  public static let comma = PC88Key(7, 4)
  public static let period = PC88Key(7, 5)
  public static let slash = PC88Key(7, 6)
  public static let underscore = PC88Key(7, 7)

  // Row 8: Control keys
  public static let clr = PC88Key(8, 0)
  public static let up = PC88Key(8, 1)
  public static let right = PC88Key(8, 2)
  public static let del = PC88Key(8, 3)
  public static let grph = PC88Key(8, 4)
  public static let kana = PC88Key(8, 5)
  public static let shift = PC88Key(8, 6)
  public static let ctrl = PC88Key(8, 7)

  // Row 9: Function keys, space, esc
  public static let stop = PC88Key(9, 0)
  public static let f1 = PC88Key(9, 1)
  public static let f2 = PC88Key(9, 2)
  public static let f3 = PC88Key(9, 3)
  public static let f4 = PC88Key(9, 4)
  public static let f5 = PC88Key(9, 5)
  public static let space = PC88Key(9, 6)
  public static let esc = PC88Key(9, 7)

  // Row 10: Tab, arrows, etc.
  public static let tab = PC88Key(0x0A, 0)
  public static let down = PC88Key(0x0A, 1)
  public static let left = PC88Key(0x0A, 2)
  public static let help = PC88Key(0x0A, 3)
  public static let copy = PC88Key(0x0A, 4)
  public static let kpMinus = PC88Key(0x0A, 5)
  public static let kpDivide = PC88Key(0x0A, 6)
  public static let capsLock = PC88Key(0x0A, 7)

  // Row 11: Roll
  public static let rollDown = PC88Key(0x0B, 0)
  public static let rollUp = PC88Key(0x0B, 1)

  // Row 12: F6-F10, editing
  public static let f6 = PC88Key(0x0C, 0)
  public static let f7 = PC88Key(0x0C, 1)
  public static let f8 = PC88Key(0x0C, 2)
  public static let f9 = PC88Key(0x0C, 3)
  public static let f10 = PC88Key(0x0C, 4)
  public static let bs = PC88Key(0x0C, 5)
  public static let ins = PC88Key(0x0C, 6)
  public static let del2 = PC88Key(0x0C, 7)

  // Row 13: Japanese input
  public static let henkan = PC88Key(0x0D, 0)
  public static let kettei = PC88Key(0x0D, 1)
  public static let pc = PC88Key(0x0D, 2)
  public static let zenkaku = PC88Key(0x0D, 3)
}
