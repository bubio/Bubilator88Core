// ScriptWriter.swift — serializes [ScriptStep] into canonical script text.
//
// The inverse of `ScriptParser`. Writes the [ScriptStep] timeline assembled by
// the recorder (ScriptRecorder) out as `.b88script` text, guaranteeing the
// round-trip `ScriptParser.parse(write(steps)) == steps`. A pure function with
// no dependency on Machine.

public enum ScriptWriter {

  /// [ScriptStep] to canonical script text: one step per line, with a trailing
  /// newline. Only emits notation that `ScriptParser.parse` can read back.
  public static func write(_ steps: [ScriptStep]) -> String {
    var out = steps.map(line(for:)).joined(separator: "\n")
    if !out.isEmpty { out += "\n" }
    return out
  }

  /// The canonical key name for a `Keyboard.Key`, the inverse of
  /// `ScriptParser.key(named:)`. Keys without a name fall back to row-bit
  /// notation, `"\(row)-\(bit)"`.
  public static func keyName(for key: Keyboard.Key) -> String {
    if let name = canonicalNames[key] { return name }
    return "\(key.row)-\(key.bit)"
  }

  // MARK: - Per-step serialization

  private static func line(for step: ScriptStep) -> String {
    switch step {
    case .boot(let mode):                return "boot \(mode.rawValue)"
    case .clock(let mhz):                return "clock \(mhz)"
    case .dipsw1(let v):                 return "dipsw1 0x\(hex2(v))"
    case .dipsw2(let v):                 return "dipsw2 0x\(hex2(v))"
    case .diskMount(let d, let p, let i): return diskLine("disk \(d)", path: p, image: i)
    case .wait(let frames):              return "wait \(frames)"
    case .key(let key, let action):      return keyLine(key, action)
    case .diskSwap(let d, let p, let i): return diskLine("disk swap \(d)", path: p, image: i)
    case .diskSelect(let d, let i):      return "disk select \(d) \(i)"
    case .diskEject(let d):              return "disk eject \(d)"
    case .reset(let preserveRAM):        return preserveRAM ? "reset warm" : "reset cold"
    }
  }

  /// `<prefix> "<path>" [image <i>]`. `image == 0` is omitted, since that is
  /// the parser's default.
  private static func diskLine(_ prefix: String, path: String, image: Int) -> String {
    let base = "\(prefix) \"\(escapeQuoted(path))\""
    return image != 0 ? "\(base) image \(image)" : base
  }

  /// Escapes `\` and `"` inside a quoted string with `\`, without depending on
  /// Foundation. The tokenizer reads `\\` back as `\` and `\"` as `"`.
  private static func escapeQuoted(_ s: String) -> String {
    var out = ""
    for ch in s {
      if ch == "\\" || ch == "\"" { out.append("\\") }
      out.append(ch)
    }
    return out
  }

  private static func keyLine(_ key: Keyboard.Key, _ action: KeyAction) -> String {
    let name = keyName(for: key)
    switch action {
    case .down:           return "key \(name) down"
    case .up:             return "key \(name) up"
    case .tap(let hold):  return hold == 2 ? "key \(name) tap" : "key \(name) tap \(hold)"
    }
  }

  /// Two-digit uppercase hex, without depending on Foundation.
  private static func hex2(_ v: UInt8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count == 1 ? "0\(s)" : s
  }

  // MARK: - Canonical reverse key-name table

  /// `Keyboard.Key` to its canonical name. `ScriptParser.keyNameTable` is not
  /// injective — esc/escape, and return/enter/kpreturn/kpenter, map to the same
  /// key — so colliding keys get an explicit canonical name seeded up front and
  /// the rest are reversed one-to-one. Every alias parses back to the same key,
  /// so the round-trip holds whichever name is chosen; these match
  /// docs/develop/BOOTTESTER.md for readability.
  private static let canonicalNames: [Keyboard.Key: String] = {
    var rev: [Keyboard.Key: String] = [
      Keyboard.kpReturn: "return",
      Keyboard.esc: "esc",
    ]
    for (name, key) in ScriptParser.keyNameTable where rev[key] == nil {
      rev[key] = name
    }
    return rev
  }()
}
