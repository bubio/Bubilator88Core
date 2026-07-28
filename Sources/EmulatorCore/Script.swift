// Script.swift — model and parser for timeline operation scripts.
//
// A pure Swift implementation of the DRAFT specification in docs/SCRIPTING.md.
// It only converts text into [ScriptStep] and has no dependency on Machine;
// replaying the steps is ScriptPlayer's job.

// MARK: - Model

/// The action taken by the `key` verb.
public enum KeyAction: Equatable, Sendable {
  case down
  case up
  /// Presses the key and schedules an automatic release `hold` frames later.
  /// Defaults to 2.
  case tap(hold: Int)
}

/// Boot mode, expanded into a DIPSW1 / DIPSW2 pair. The values follow
/// docs/BOOTTESTER.md and docs/PERSISTENCE.md.
public enum BootMode: String, Equatable, Sendable, CaseIterable {
  case n88v2   = "n88-v2"
  case n88v1h  = "n88-v1h"
  case n88v1s  = "n88-v1s"
  case nbasic  = "n-basic"

  public var dipSw1: UInt8 {
    switch self {
    case .n88v2, .n88v1h, .n88v1s: return 0xC3
    case .nbasic:                  return 0xC2
    }
  }

  public var dipSw2: UInt8 {
    switch self {
    case .n88v2:  return 0x71
    case .n88v1h: return 0xF1
    case .n88v1s: return 0xB1
    case .nbasic: return 0x71
    }
  }
}

/// A single script step. Steps are held in the order they were written.
public enum ScriptStep: Equatable, Sendable {
  // --- setup ---
  case boot(BootMode)
  case clock(mhz: Int)                                  // 4 or 8
  case dipsw1(UInt8)
  case dipsw2(UInt8)
  case diskMount(drive: Int, path: String, image: Int)  // initial mount

  // --- timeline ---
  case wait(frames: Int)
  case key(Keyboard.Key, KeyAction)
  case diskSwap(drive: Int, path: String, image: Int)   // swap in a different file
  case diskSelect(drive: Int, image: Int)               // switch image within the same file
  case diskEject(drive: Int)
  case reset(preserveRAM: Bool)
}

/// A parse error. `line` is 1-based.
public struct ScriptError: Error, Equatable, Sendable {
  public let line: Int
  public let message: String
  public init(line: Int, message: String) {
    self.line = line
    self.message = message
  }
}

// MARK: - Parser

public enum ScriptParser {

  /// Parses script text into a [ScriptStep] timeline.
  public static func parse(_ text: String) throws -> [ScriptStep] {
    var steps: [ScriptStep] = []
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (idx, rawLine) in lines.enumerated() {
      let lineNo = idx + 1
      let tokens = try tokenize(String(rawLine), line: lineNo)
      guard !tokens.isEmpty else { continue }  // blank line, or comment only
      steps.append(try parseLine(tokens, line: lineNo))
    }
    return steps
  }

  // MARK: Tokenizer

  /// Tokenizes a line on whitespace. `"..."` stays one token; everything from
  /// `#` onwards is a comment.
  private static func tokenize(_ line: String, line lineNo: Int) throws -> [String] {
    var tokens: [String] = []
    var current = ""
    var inQuotes = false
    var hasCurrent = false
    var escaped = false  // `\` escape inside quotes

    for ch in line {
      if inQuotes {
        if escaped {
          current.append(ch)  // `\"` → `"`, `\\` → `\`, anything else stays literal
          escaped = false
        } else if ch == "\\" {
          escaped = true
        } else if ch == "\"" {
          inQuotes = false
        } else {
          current.append(ch)
        }
        continue
      }
      switch ch {
      case "\"":
        inQuotes = true
        hasCurrent = true  // `""` is a valid empty-string token
      case "#":
        // Start of a comment; ignore the rest of the line.
        if hasCurrent { tokens.append(current) }
        return tokens
      case " ", "\t", "\r":
        if hasCurrent { tokens.append(current); current = ""; hasCurrent = false }
      default:
        current.append(ch)
        hasCurrent = true
      }
    }
    if inQuotes {
      throw ScriptError(line: lineNo, message: "クォートが閉じていません")
    }
    if hasCurrent { tokens.append(current) }
    return tokens
  }

  // MARK: Line dispatch

  private static func parseLine(_ tokens: [String], line: Int) throws -> ScriptStep {
    let verb = tokens[0].lowercased()
    let args = Array(tokens.dropFirst())
    switch verb {
    case "wait":              return try parseWait(args, line: line)
    case "key":               return try parseKey(args, line: line)
    case "disk":              return try parseDisk(args, line: line)
    case "reset":             return try parseReset(args, line: line)
    case "boot", "bootmode":  return try parseBoot(args, line: line)
    case "clock":             return try parseClock(args, line: line)
    case "dipsw1":            return .dipsw1(try parseByte(args, verb: verb, line: line))
    case "dipsw2":            return .dipsw2(try parseByte(args, verb: verb, line: line))
    default:
      throw ScriptError(line: line, message: "未知の動詞: \(tokens[0])")
    }
  }

  private static func parseWait(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, message: "wait は引数 1 個 (例: wait 90 / wait 1.5s)")
    }
    return .wait(frames: try parseDuration(args[0], line: line))
  }

  private static func parseKey(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count >= 2 else {
      throw ScriptError(line: line, message: "key <name> <down|up|tap [hold]>")
    }
    let key = try resolveKey(args[0], line: line)
    let action = args[1].lowercased()
    switch action {
    case "down":
      guard args.count == 2 else { throw ScriptError(line: line, message: "key down に余分な引数") }
      return .key(key, .down)
    case "up":
      guard args.count == 2 else { throw ScriptError(line: line, message: "key up に余分な引数") }
      return .key(key, .up)
    case "tap":
      let hold: Int
      if args.count == 2 {
        hold = 2
      } else if args.count == 3 {
        guard let h = Int(args[2]), h >= 1 else {
          throw ScriptError(line: line, message: "tap の hold は 1 以上: \(args[2])")
        }
        hold = h
      } else {
        throw ScriptError(line: line, message: "key tap [hold]")
      }
      return .key(key, .tap(hold: hold))
    default:
      throw ScriptError(line: line, message: "不明な key アクション: \(args[1])")
    }
  }

  private static func parseDisk(_ args: [String], line: Int) throws -> ScriptStep {
    guard let first = args.first else {
      throw ScriptError(line: line, message: "disk の引数が不足")
    }
    switch first.lowercased() {
    case "swap":
      let (drive, path, image) = try parseDrivePathImage(Array(args.dropFirst()), line: line)
      return .diskSwap(drive: drive, path: path, image: image)
    case "select":
      let rest = Array(args.dropFirst())
      guard rest.count == 2 else {
        throw ScriptError(line: line, message: "disk select <drive> <index>")
      }
      return .diskSelect(drive: try parseDrive(rest[0], line: line),
                         image: try parseIndex(rest[1], line: line))
    case "eject":
      let rest = Array(args.dropFirst())
      guard rest.count == 1 else {
        throw ScriptError(line: line, message: "disk eject <drive>")
      }
      return .diskEject(drive: try parseDrive(rest[0], line: line))
    default:
      // Initial mount: disk <drive> <path> [image <index>]
      let (drive, path, image) = try parseDrivePathImage(args, line: line)
      return .diskMount(drive: drive, path: path, image: image)
    }
  }

  /// Parses `<drive> <path> [image <index>]`, shared by mount and swap.
  private static func parseDrivePathImage(_ args: [String], line: Int) throws -> (Int, String, Int) {
    guard args.count == 2 || args.count == 4 else {
      throw ScriptError(line: line, message: "<drive> <path> [image <index>]")
    }
    let drive = try parseDrive(args[0], line: line)
    let path = args[1]
    guard !path.isEmpty else {
      throw ScriptError(line: line, message: "ディスクパスが空です")
    }
    var image = 0
    if args.count == 4 {
      guard args[2].lowercased() == "image" else {
        throw ScriptError(line: line, message: "image キーワードが必要: \(args[2])")
      }
      image = try parseIndex(args[3], line: line)
    }
    return (drive, path, image)
  }

  private static func parseReset(_ args: [String], line: Int) throws -> ScriptStep {
    if args.isEmpty { return .reset(preserveRAM: false) }
    guard args.count == 1 else {
      throw ScriptError(line: line, message: "reset [cold|warm]")
    }
    switch args[0].lowercased() {
    case "cold": return .reset(preserveRAM: false)
    case "warm": return .reset(preserveRAM: true)
    default:     throw ScriptError(line: line, message: "reset は cold か warm: \(args[0])")
    }
  }

  private static func parseBoot(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, message: "boot <mode> (N88-V2 / N88-V1H / N88-V1S / N-BASIC)")
    }
    guard let mode = BootMode(rawValue: args[0].lowercased()) else {
      throw ScriptError(line: line, message: "未知のブートモード: \(args[0])")
    }
    return .boot(mode)
  }

  private static func parseClock(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1, let mhz = Int(args[0]), mhz == 4 || mhz == 8 else {
      throw ScriptError(line: line, message: "clock は 4 か 8")
    }
    return .clock(mhz: mhz)
  }

  // MARK: Scalar parsers

  /// Converts `90`, `90f` or `1.5s` into a frame count.
  private static func parseDuration(_ token: String, line: Int) throws -> Int {
    let t = token.lowercased()
    if t.hasSuffix("s") {
      let body = String(t.dropLast())
      guard let sec = Double(body), sec >= 0 else {
        throw ScriptError(line: line, message: "不正な秒指定: \(token)")
      }
      return Int((sec * 60).rounded())
    }
    let body = t.hasSuffix("f") ? String(t.dropLast()) : t
    guard let frames = Int(body), frames >= 0 else {
      throw ScriptError(line: line, message: "不正なフレーム指定: \(token)")
    }
    return frames
  }

  private static func parseDrive(_ token: String, line: Int) throws -> Int {
    guard let d = Int(token), d == 0 || d == 1 else {
      throw ScriptError(line: line, message: "ドライブは 0 か 1: \(token)")
    }
    return d
  }

  private static func parseIndex(_ token: String, line: Int) throws -> Int {
    guard let i = Int(token), i >= 0 else {
      throw ScriptError(line: line, message: "イメージ番号が不正: \(token)")
    }
    return i
  }

  private static func parseByte(_ args: [String], verb: String, line: Int) throws -> UInt8 {
    guard args.count == 1 else {
      throw ScriptError(line: line, message: "\(verb) <byte>")
    }
    let t = args[0].lowercased()
    let value: Int?
    if t.hasPrefix("0x") {
      value = Int(t.dropFirst(2), radix: 16)
    } else {
      value = Int(t)
    }
    guard let v = value, v >= 0, v <= 0xFF else {
      throw ScriptError(line: line, message: "\(verb) の値が不正 (0x00-0xFF): \(args[0])")
    }
    return UInt8(v)
  }

  // MARK: Key name resolution

  /// Resolves a key name (case-insensitive) or `row-bit` notation to a
  /// Keyboard.Key, or nil if it cannot be resolved. This is the shared entry
  /// point, also used from outside by BootTester.
  public static func key(named token: String) -> Keyboard.Key? {
    let name = token.lowercased()
    if let key = keyNameTable[name] { return key }
    return parseRowBit(name)  // row-bit notation, e.g. "2-1" or "0x0a-3"
  }

  /// Parser-internal: turns a failed lookup into an error carrying the line number.
  static func resolveKey(_ token: String, line: Int) throws -> Keyboard.Key {
    if let key = key(named: token) { return key }
    throw ScriptError(line: line, message: "未知のキー名: \(token)")
  }

  private static func parseRowBit(_ token: String) -> Keyboard.Key? {
    let parts = token.split(separator: "-", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    func num(_ s: Substring) -> Int? {
      let str = s.lowercased()
      if str.hasPrefix("0x") { return Int(str.dropFirst(2), radix: 16) }
      return Int(str)
    }
    guard let row = num(parts[0]), let bit = num(parts[1]),
          row >= 0, row < 15, bit >= 0, bit < 8 else { return nil }
    return Keyboard.Key(row, bit)
  }
}

// MARK: - Key name table

extension ScriptParser {
  /// String to Keyboard.Key. The single key-name table shared by timeline
  /// scripts and BootTester's BOOTTEST_KEY_EVENTS; the Keyboard constants are
  /// the source of truth.
  static let keyNameTable: [String: Keyboard.Key] = [
    // Return / control
    "return": Keyboard.kpReturn, "enter": Keyboard.kpReturn,
    "space": Keyboard.space,
    "esc": Keyboard.esc, "escape": Keyboard.esc,
    "stop": Keyboard.stop, "tab": Keyboard.tab,
    "help": Keyboard.help, "copy": Keyboard.copy,
    // Modifiers
    "shift": Keyboard.shift, "ctrl": Keyboard.ctrl,
    "grph": Keyboard.grph, "kana": Keyboard.kana,
    // Arrows
    "up": Keyboard.up, "down": Keyboard.down,
    "left": Keyboard.left, "right": Keyboard.right,
    // Function keys
    "f1": Keyboard.f1, "f2": Keyboard.f2, "f3": Keyboard.f3, "f4": Keyboard.f4,
    "f5": Keyboard.f5, "f6": Keyboard.f6, "f7": Keyboard.f7, "f8": Keyboard.f8,
    "f9": Keyboard.f9, "f10": Keyboard.f10,
    // Digits
    "0": Keyboard.key0, "1": Keyboard.key1, "2": Keyboard.key2, "3": Keyboard.key3,
    "4": Keyboard.key4, "5": Keyboard.key5, "6": Keyboard.key6, "7": Keyboard.key7,
    "8": Keyboard.key8, "9": Keyboard.key9,
    // Letters
    "a": Keyboard.a, "b": Keyboard.b, "c": Keyboard.c, "d": Keyboard.d,
    "e": Keyboard.e, "f": Keyboard.f, "g": Keyboard.g, "h": Keyboard.h,
    "i": Keyboard.i, "j": Keyboard.j, "k": Keyboard.k, "l": Keyboard.l,
    "m": Keyboard.m, "n": Keyboard.n, "o": Keyboard.o, "p": Keyboard.p,
    "q": Keyboard.q, "r": Keyboard.r, "s": Keyboard.s, "t": Keyboard.t,
    "u": Keyboard.u, "v": Keyboard.v, "w": Keyboard.w, "x": Keyboard.x,
    "y": Keyboard.y, "z": Keyboard.z,
    // Symbols
    "at": Keyboard.at,
    "leftbracket": Keyboard.leftBracket, "rightbracket": Keyboard.rightBracket,
    "yen": Keyboard.yen, "caret": Keyboard.caret, "minus": Keyboard.minus,
    "colon": Keyboard.colon, "semicolon": Keyboard.semicolon,
    "comma": Keyboard.comma, "period": Keyboard.period,
    "slash": Keyboard.slash, "underscore": Keyboard.underscore,
    // Numeric keypad
    "kp0": Keyboard.kp0, "kp1": Keyboard.kp1, "kp2": Keyboard.kp2, "kp3": Keyboard.kp3,
    "kp4": Keyboard.kp4, "kp5": Keyboard.kp5, "kp6": Keyboard.kp6, "kp7": Keyboard.kp7,
    "kp8": Keyboard.kp8, "kp9": Keyboard.kp9,
    "kpreturn": Keyboard.kpReturn, "kpenter": Keyboard.kpReturn,
    "kpplus": Keyboard.kpPlus, "kpminus": Keyboard.kpMinus,
    "kpmultiply": Keyboard.kpMultiply, "kpdivide": Keyboard.kpDivide,
    "kpequal": Keyboard.kpEqual, "kpcomma": Keyboard.kpComma,
    "kpperiod": Keyboard.kpPeriod,
    // Editing / paging / conversion
    "clr": Keyboard.clr, "del": Keyboard.del, "bs": Keyboard.bs,
    "ins": Keyboard.ins, "del2": Keyboard.del2, "capslock": Keyboard.capsLock,
    "rollup": Keyboard.rollUp, "rolldown": Keyboard.rollDown,
    "henkan": Keyboard.henkan, "kettei": Keyboard.kettei,
    "pc": Keyboard.pc, "zenkaku": Keyboard.zenkaku,
  ]
}
