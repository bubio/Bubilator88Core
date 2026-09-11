// Script.swift — model and parser for timeline operation scripts.
//
// A pure Swift implementation of the DRAFT specification in docs/develop/SCRIPTING.md.
// It only converts text into [ScriptStep] and has no dependency on Machine;
// replaying the steps is ScriptPlayer's job.

import Foundation

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
/// docs/develop/BOOTTESTER.md and docs/develop/PERSISTENCE.md.
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

  /// Port 0x31's DIP bits. Bit 7 is SW4-S2 (0 = V2, 1 = V1) and bit 6 is
  /// SW3-S0 (0 = standard, 1 = high speed); BubiC derives both from the boot
  /// mode in `pc88.cpp` `read_io8` for port 0x31, and N-BASIC comes out as
  /// V1 + standard there — the same value as V1S.
  public var dipSw2: UInt8 {
    switch self {
    case .n88v2:  return 0x71
    case .n88v1h: return 0xF1
    case .n88v1s: return 0xB1
    case .nbasic: return 0xB1
    }
  }
}

/// A single script step. Steps are held in the order they were written.
public enum ScriptStep: Equatable, Sendable {
  // --- setup ---
  case boot(BootMode)
  case clock(mhz: Int)                                  // 4 or 8
  case monitor(MonitorType)
  case memoryWait(Bool)
  case dipsw1(UInt8)
  case dipsw2(UInt8)
  case diskMount(drive: Int, path: String, image: Int)  // initial mount

  // --- timeline ---
  case wait(frames: Int)
  case key(PC88Key, KeyAction)
  case diskSwap(drive: Int, path: String, image: Int)   // swap in a different file
  case diskSelect(drive: Int, image: Int)               // switch image within the same file
  case diskEject(drive: Int)
  case reset(preserveRAM: Bool)
}

/// A parse error. `line` is 1-based.
///
/// The message is split into an English format string and its arguments rather
/// than being pre-interpolated, so the app layer can localize it: `format` is
/// also the String Catalog key. EmulatorCore itself has no localization — it is
/// a platform-agnostic package, and BootTester wants the English text anyway.
public struct ScriptError: Error, Equatable, Sendable {
  public let line: Int

  /// English format string, using positional `%1$@`-style placeholders when
  /// there is more than one argument. Doubles as the String Catalog key.
  public let format: String

  /// Values substituted into `format`, already rendered as strings.
  public let arguments: [String]

  /// The English message, with `arguments` substituted in.
  public var message: String {
    arguments.isEmpty ? format : String(format: format, arguments: arguments)
  }

  public init(line: Int, format: String, arguments: [String] = []) {
    self.line = line
    self.format = format
    self.arguments = arguments
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
      throw ScriptError(line: lineNo, format: "Unclosed quote.")
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
    case "monitor":           return try parseMonitor(args, line: line)
    case "memwait":           return try parseMemWait(args, line: line)
    case "dipsw1":            return .dipsw1(try parseByte(args, verb: verb, line: line))
    case "dipsw2":            return .dipsw2(try parseByte(args, verb: verb, line: line))
    default:
      throw ScriptError(line: line, format: "Unknown verb: %@", arguments: [tokens[0]])
    }
  }

  private static func parseWait(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "wait takes exactly one argument (e.g. wait 90, wait 1.5s).")
    }
    return .wait(frames: try parseDuration(args[0], line: line))
  }

  private static func parseKey(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count >= 2 else {
      throw ScriptError(line: line, format: "key <name> <down|up|tap [hold]>")
    }
    let key = try resolveKey(args[0], line: line)
    let action = args[1].lowercased()
    switch action {
    case "down":
      guard args.count == 2 else { throw ScriptError(line: line, format: "key down takes no extra arguments.") }
      return .key(key, .down)
    case "up":
      guard args.count == 2 else { throw ScriptError(line: line, format: "key up takes no extra arguments.") }
      return .key(key, .up)
    case "tap":
      let hold: Int
      if args.count == 2 {
        hold = 2
      } else if args.count == 3 {
        guard let h = Int(args[2]), h >= 1 else {
          throw ScriptError(line: line, format: "tap hold must be at least 1: %@", arguments: [args[2]])
        }
        hold = h
      } else {
        throw ScriptError(line: line, format: "key tap [hold]")
      }
      return .key(key, .tap(hold: hold))
    default:
      throw ScriptError(line: line, format: "Unknown key action: %@", arguments: [args[1]])
    }
  }

  private static func parseDisk(_ args: [String], line: Int) throws -> ScriptStep {
    guard let first = args.first else {
      throw ScriptError(line: line, format: "disk is missing arguments.")
    }
    switch first.lowercased() {
    case "swap":
      let (drive, path, image) = try parseDrivePathImage(Array(args.dropFirst()), line: line)
      return .diskSwap(drive: drive, path: path, image: image)
    case "select":
      let rest = Array(args.dropFirst())
      guard rest.count == 2 else {
        throw ScriptError(line: line, format: "disk select <drive> <index>")
      }
      return .diskSelect(drive: try parseDrive(rest[0], line: line),
                         image: try parseIndex(rest[1], line: line))
    case "eject":
      let rest = Array(args.dropFirst())
      guard rest.count == 1 else {
        throw ScriptError(line: line, format: "disk eject <drive>")
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
      throw ScriptError(line: line, format: "<drive> <path> [image <index>]")
    }
    let drive = try parseDrive(args[0], line: line)
    let path = args[1]
    guard !path.isEmpty else {
      throw ScriptError(line: line, format: "The disk path is empty.")
    }
    var image = 0
    if args.count == 4 {
      guard args[2].lowercased() == "image" else {
        throw ScriptError(line: line, format: "Expected the image keyword: %@", arguments: [args[2]])
      }
      image = try parseIndex(args[3], line: line)
    }
    return (drive, path, image)
  }

  private static func parseReset(_ args: [String], line: Int) throws -> ScriptStep {
    if args.isEmpty { return .reset(preserveRAM: false) }
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "reset [cold|warm]")
    }
    switch args[0].lowercased() {
    case "cold": return .reset(preserveRAM: false)
    case "warm": return .reset(preserveRAM: true)
    default:     throw ScriptError(line: line, format: "reset must be cold or warm: %@", arguments: [args[0]])
    }
  }

  private static func parseBoot(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "boot <mode> (N88-V2 / N88-V1H / N88-V1S / N-BASIC)")
    }
    guard let mode = BootMode(rawValue: args[0].lowercased()) else {
      throw ScriptError(line: line, format: "Unknown boot mode: %@", arguments: [args[0]])
    }
    return .boot(mode)
  }

  private static func parseClock(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1, let mhz = Int(args[0]), mhz == 4 || mhz == 8 else {
      throw ScriptError(line: line, format: "clock must be 4 or 8.")
    }
    return .clock(mhz: mhz)
  }

  private static func parseMonitor(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "monitor must be 15k or 24k.")
    }
    switch args[0].lowercased() {
    case "15k": return .monitor(.khz15)
    case "24k": return .monitor(.khz24)
    default:    throw ScriptError(line: line, format: "monitor must be 15k or 24k.")
    }
  }

  private static func parseMemWait(_ args: [String], line: Int) throws -> ScriptStep {
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "memwait must be on or off.")
    }
    switch args[0].lowercased() {
    case "on":  return .memoryWait(true)
    case "off": return .memoryWait(false)
    default:    throw ScriptError(line: line, format: "memwait must be on or off.")
    }
  }

  // MARK: Scalar parsers

  /// Converts `90`, `90f` or `1.5s` into a frame count.
  private static func parseDuration(_ token: String, line: Int) throws -> Int {
    let t = token.lowercased()
    if t.hasSuffix("s") {
      let body = String(t.dropLast())
      guard let sec = Double(body), sec >= 0 else {
        throw ScriptError(line: line, format: "Invalid duration in seconds: %@", arguments: [token])
      }
      return Int((sec * 60).rounded())
    }
    let body = t.hasSuffix("f") ? String(t.dropLast()) : t
    guard let frames = Int(body), frames >= 0 else {
      throw ScriptError(line: line, format: "Invalid frame count: %@", arguments: [token])
    }
    return frames
  }

  private static func parseDrive(_ token: String, line: Int) throws -> Int {
    guard let d = Int(token), d == 0 || d == 1 else {
      throw ScriptError(line: line, format: "Drive must be 0 or 1: %@", arguments: [token])
    }
    return d
  }

  private static func parseIndex(_ token: String, line: Int) throws -> Int {
    guard let i = Int(token), i >= 0 else {
      throw ScriptError(line: line, format: "Invalid image index: %@", arguments: [token])
    }
    return i
  }

  private static func parseByte(_ args: [String], verb: String, line: Int) throws -> UInt8 {
    guard args.count == 1 else {
      throw ScriptError(line: line, format: "%@ <byte>", arguments: [verb])
    }
    let t = args[0].lowercased()
    let value: Int?
    if t.hasPrefix("0x") {
      value = Int(t.dropFirst(2), radix: 16)
    } else {
      value = Int(t)
    }
    guard let v = value, v >= 0, v <= 0xFF else {
      throw ScriptError(line: line, format: "Invalid value for %1$@ (0x00-0xFF): %2$@", arguments: [verb, args[0]])
    }
    return UInt8(v)
  }

  // MARK: Key name resolution

  /// Resolves a key name (case-insensitive) or `row-bit` notation to a
  /// PC88Key, or nil if it cannot be resolved. This is the shared entry
  /// point, also used from outside by BootTester.
  public static func key(named token: String) -> PC88Key? {
    let name = token.lowercased()
    if let key = keyNameTable[name] { return key }
    return parseRowBit(name)  // row-bit notation, e.g. "2-1" or "0x0a-3"
  }

  /// Parser-internal: turns a failed lookup into an error carrying the line number.
  static func resolveKey(_ token: String, line: Int) throws -> PC88Key {
    if let key = key(named: token) { return key }
    throw ScriptError(line: line, format: "Unknown key name: %@", arguments: [token])
  }

  private static func parseRowBit(_ token: String) -> PC88Key? {
    let parts = token.split(separator: "-", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    func num(_ s: Substring) -> Int? {
      let str = s.lowercased()
      if str.hasPrefix("0x") { return Int(str.dropFirst(2), radix: 16) }
      return Int(str)
    }
    guard let row = num(parts[0]), let bit = num(parts[1]),
          row >= 0, row < 15, bit >= 0, bit < 8 else { return nil }
    return PC88Key(row, bit)
  }
}

// MARK: - Key name table

extension ScriptParser {
  /// String to PC88Key. The single key-name table shared by timeline
  /// scripts and BootTester's BOOTTEST_KEY_EVENTS; the Keyboard constants are
  /// the source of truth.
  static let keyNameTable: [String: PC88Key] = [
    // Return / control
    "return": PC88Key.kpReturn, "enter": PC88Key.kpReturn,
    "space": PC88Key.space,
    "esc": PC88Key.esc, "escape": PC88Key.esc,
    "stop": PC88Key.stop, "tab": PC88Key.tab,
    "help": PC88Key.help, "copy": PC88Key.copy,
    // Modifiers
    "shift": PC88Key.shift, "ctrl": PC88Key.ctrl,
    "grph": PC88Key.grph, "kana": PC88Key.kana,
    // Arrows
    "up": PC88Key.up, "down": PC88Key.down,
    "left": PC88Key.left, "right": PC88Key.right,
    // Function keys
    "f1": PC88Key.f1, "f2": PC88Key.f2, "f3": PC88Key.f3, "f4": PC88Key.f4,
    "f5": PC88Key.f5, "f6": PC88Key.f6, "f7": PC88Key.f7, "f8": PC88Key.f8,
    "f9": PC88Key.f9, "f10": PC88Key.f10,
    // Digits
    "0": PC88Key.key0, "1": PC88Key.key1, "2": PC88Key.key2, "3": PC88Key.key3,
    "4": PC88Key.key4, "5": PC88Key.key5, "6": PC88Key.key6, "7": PC88Key.key7,
    "8": PC88Key.key8, "9": PC88Key.key9,
    // Letters
    "a": PC88Key.a, "b": PC88Key.b, "c": PC88Key.c, "d": PC88Key.d,
    "e": PC88Key.e, "f": PC88Key.f, "g": PC88Key.g, "h": PC88Key.h,
    "i": PC88Key.i, "j": PC88Key.j, "k": PC88Key.k, "l": PC88Key.l,
    "m": PC88Key.m, "n": PC88Key.n, "o": PC88Key.o, "p": PC88Key.p,
    "q": PC88Key.q, "r": PC88Key.r, "s": PC88Key.s, "t": PC88Key.t,
    "u": PC88Key.u, "v": PC88Key.v, "w": PC88Key.w, "x": PC88Key.x,
    "y": PC88Key.y, "z": PC88Key.z,
    // Symbols
    "at": PC88Key.at,
    "leftbracket": PC88Key.leftBracket, "rightbracket": PC88Key.rightBracket,
    "yen": PC88Key.yen, "caret": PC88Key.caret, "minus": PC88Key.minus,
    "colon": PC88Key.colon, "semicolon": PC88Key.semicolon,
    "comma": PC88Key.comma, "period": PC88Key.period,
    "slash": PC88Key.slash, "underscore": PC88Key.underscore,
    // Numeric keypad
    "kp0": PC88Key.kp0, "kp1": PC88Key.kp1, "kp2": PC88Key.kp2, "kp3": PC88Key.kp3,
    "kp4": PC88Key.kp4, "kp5": PC88Key.kp5, "kp6": PC88Key.kp6, "kp7": PC88Key.kp7,
    "kp8": PC88Key.kp8, "kp9": PC88Key.kp9,
    "kpreturn": PC88Key.kpReturn, "kpenter": PC88Key.kpReturn,
    "kpplus": PC88Key.kpPlus, "kpminus": PC88Key.kpMinus,
    "kpmultiply": PC88Key.kpMultiply, "kpdivide": PC88Key.kpDivide,
    "kpequal": PC88Key.kpEqual, "kpcomma": PC88Key.kpComma,
    "kpperiod": PC88Key.kpPeriod,
    // Editing / paging / conversion
    "clr": PC88Key.clr, "del": PC88Key.del, "bs": PC88Key.bs,
    "ins": PC88Key.ins, "del2": PC88Key.del2, "capslock": PC88Key.capsLock,
    "rollup": PC88Key.rollUp, "rolldown": PC88Key.rollDown,
    "henkan": PC88Key.henkan, "kettei": PC88Key.kettei,
    "pc": PC88Key.pc, "zenkaku": PC88Key.zenkaku,
  ]
}
