import Foundation

/// Incremental romaji → **half-width katakana** converter (a minimal host-side
/// IME for the PC-8801 emulator).
///
/// Output is deliberately **half-width katakana** (U+FF61–FF9F, long-vowel
/// U+FF70) because the downstream `TextPasteQueue.enqueue(_:)` converts its
/// input to Shift-JIS and **silently drops multi-byte (full-width) characters**.
/// Full-width `カ` (U+30AB) would be lost; half-width `ｶ` (U+FF76 → SJIS 0xB6)
/// routes through the existing kana table. Voiced/semi-voiced sounds are emitted
/// as a base kana followed by a **standalone** `ﾞ`/`ﾟ` (e.g. `ga` → `ｶﾞ`), which
/// is how the PC-8801 kana keyboard produces them.
///
/// The converter keeps a small buffer of un-committed roman letters. `feed`
/// returns the katakana that became final as a result of the new character;
/// `pending` exposes the still-ambiguous tail for an on-screen indicator.
public struct RomajiKanaConverter {

  /// Un-committed roman letters (always lowercased). Exposed via `pending`.
  private var buffer: String = ""

  public init() {}

  /// The roman letters typed so far that have not yet resolved to kana.
  /// Used to render the IME-style pending overlay.
  public var pending: String { buffer }

  /// Feed one typed character. Returns any katakana that became final.
  /// Characters outside a–z and `-` are not expected here (callers filter
  /// them and use `flush()` first); if one arrives it is dropped.
  public mutating func feed(_ c: Character) -> String {
    let lower = Character(c.lowercased())
    guard lower.isLetter || lower == "-" else { return "" }
    buffer.append(lower)
    return process()
  }

  /// Commit the trailing un-committed buffer (called when input switches to a
  /// non-romaji key, or the mode turns off). A lone `n` becomes `ﾝ`; an exact
  /// table match commits; anything else (an incomplete cluster like `ky`) is
  /// discarded.
  public mutating func flush() -> String {
    defer { buffer = "" }
    if buffer == "n" { return "ﾝ" }
    if let kana = Self.table[buffer] { return kana }
    return ""
  }

  /// Delete the last un-committed roman letter. Returns true if something was
  /// removed (so the caller swallows the Backspace instead of sending it to
  /// the emulator).
  public mutating func backspace() -> Bool {
    guard !buffer.isEmpty else { return false }
    buffer.removeLast()
    return true
  }

  /// Discard the pending buffer without emitting anything.
  public mutating func reset() { buffer = "" }

  // MARK: - Core state machine

  private mutating func process() -> String {
    var out = ""
    while let first = buffer.first {
      // Sokuon (っ): a doubled consonant emits ｯ and keeps one copy.
      // 'n' is excluded (handled below); vowels never double into sokuon.
      if buffer.count >= 2 {
        let chars = Array(buffer)
        if chars[0] == chars[1], Self.isConsonant(chars[0]), chars[0] != "n" {
          out += "ｯ"
          buffer.removeFirst()
          continue
        }
      }

      // Syllabic ん. A leading "n" followed by any consonant (including a
      // second "n") that is not "y" promotes to ﾝ and KEEPS the following
      // consonant, so "konnichiha" → ｺﾝﾆﾁﾊ and "onna" → ｵﾝﾅ. A vowel or
      // "y" after "n" falls through so na/ni/nya can form. A trailing lone
      // "n" is resolved by flush().
      if first == "n", buffer.count >= 2 {
        let second = Array(buffer)[1]
        if second != "y", !Self.isVowel(second) {
          out += "ﾝ"
          buffer.removeFirst()
          continue
        }
      }

      if let kana = Self.table[buffer] {
        // An exact match that is also a strict prefix of a longer key
        // (e.g. "ki" vs none, but "n"/"ky" cases) must wait for more.
        if Self.strictPrefixes.contains(buffer) { break }
        out += kana
        buffer = ""
        continue
      }

      // Not a key. If it could still grow into one, wait; otherwise the
      // lead char is unmatchable — drop it and reprocess the remainder.
      if Self.strictPrefixes.contains(buffer) { break }
      buffer.removeFirst()
    }
    return out
  }

  private static func isVowel(_ c: Character) -> Bool {
    "aiueo".contains(c)
  }

  private static func isConsonant(_ c: Character) -> Bool {
    c.isLetter && !isVowel(c)
  }

  // MARK: - Tables

  /// All strict prefixes of table keys (length 1 ..< key.count). Used to
  /// decide whether the buffer should wait for more input.
  static let strictPrefixes: Set<String> = {
    var set = Set<String>()
    for key in table.keys {
      let chars = Array(key)
      if chars.count < 2 { continue }
      for len in 1..<chars.count {
        set.insert(String(chars[0..<len]))
      }
    }
    return set
  }()

  /// romaji → half-width katakana. Voiced kana use standalone ﾞ/ﾟ.
  static let table: [String: String] = [
    // Long vowel mark
    "-": "ｰ",

    // Vowels
    "a": "ｱ", "i": "ｲ", "u": "ｳ", "e": "ｴ", "o": "ｵ",

    // K
    "ka": "ｶ", "ki": "ｷ", "ku": "ｸ", "ke": "ｹ", "ko": "ｺ",
    "kya": "ｷｬ", "kyu": "ｷｭ", "kyo": "ｷｮ",

    // S
    "sa": "ｻ", "si": "ｼ", "shi": "ｼ", "su": "ｽ", "se": "ｾ", "so": "ｿ",
    "sha": "ｼｬ", "shu": "ｼｭ", "sho": "ｼｮ",
    "sya": "ｼｬ", "syu": "ｼｭ", "syo": "ｼｮ",

    // T
    "ta": "ﾀ", "ti": "ﾁ", "chi": "ﾁ", "tu": "ﾂ", "tsu": "ﾂ", "te": "ﾃ", "to": "ﾄ",
    "cha": "ﾁｬ", "chu": "ﾁｭ", "cho": "ﾁｮ",
    "tya": "ﾁｬ", "tyu": "ﾁｭ", "tyo": "ﾁｮ",

    // N
    "na": "ﾅ", "ni": "ﾆ", "nu": "ﾇ", "ne": "ﾈ", "no": "ﾉ",
    "nya": "ﾆｬ", "nyu": "ﾆｭ", "nyo": "ﾆｮ",

    // H / F
    "ha": "ﾊ", "hi": "ﾋ", "hu": "ﾌ", "fu": "ﾌ", "he": "ﾍ", "ho": "ﾎ",
    "hya": "ﾋｬ", "hyu": "ﾋｭ", "hyo": "ﾋｮ",

    // M
    "ma": "ﾏ", "mi": "ﾐ", "mu": "ﾑ", "me": "ﾒ", "mo": "ﾓ",
    "mya": "ﾐｬ", "myu": "ﾐｭ", "myo": "ﾐｮ",

    // Y
    "ya": "ﾔ", "yu": "ﾕ", "yo": "ﾖ",

    // R
    "ra": "ﾗ", "ri": "ﾘ", "ru": "ﾙ", "re": "ﾚ", "ro": "ﾛ",
    "rya": "ﾘｬ", "ryu": "ﾘｭ", "ryo": "ﾘｮ",

    // W (final ん is produced by the promotion rule / flush, not a table key)
    "wa": "ﾜ", "wo": "ｦ",

    // G
    "ga": "ｶﾞ", "gi": "ｷﾞ", "gu": "ｸﾞ", "ge": "ｹﾞ", "go": "ｺﾞ",
    "gya": "ｷﾞｬ", "gyu": "ｷﾞｭ", "gyo": "ｷﾞｮ",

    // Z / J
    "za": "ｻﾞ", "zi": "ｼﾞ", "ji": "ｼﾞ", "zu": "ｽﾞ", "ze": "ｾﾞ", "zo": "ｿﾞ",
    "ja": "ｼﾞｬ", "ju": "ｼﾞｭ", "jo": "ｼﾞｮ",
    "jya": "ｼﾞｬ", "jyu": "ｼﾞｭ", "jyo": "ｼﾞｮ",

    // D
    "da": "ﾀﾞ", "di": "ﾁﾞ", "du": "ﾂﾞ", "de": "ﾃﾞ", "do": "ﾄﾞ",

    // B
    "ba": "ﾊﾞ", "bi": "ﾋﾞ", "bu": "ﾌﾞ", "be": "ﾍﾞ", "bo": "ﾎﾞ",
    "bya": "ﾋﾞｬ", "byu": "ﾋﾞｭ", "byo": "ﾋﾞｮ",

    // P
    "pa": "ﾊﾟ", "pi": "ﾋﾟ", "pu": "ﾌﾟ", "pe": "ﾍﾟ", "po": "ﾎﾟ",
    "pya": "ﾋﾟｬ", "pyu": "ﾋﾟｭ", "pyo": "ﾋﾟｮ",

    // V
    "va": "ｳﾞｧ", "vi": "ｳﾞｨ", "vu": "ｳﾞ", "ve": "ｳﾞｪ", "vo": "ｳﾞｫ",

    // Small kana (explicit)
    "xa": "ｧ", "xi": "ｨ", "xu": "ｩ", "xe": "ｪ", "xo": "ｫ",
    "la": "ｧ", "li": "ｨ", "lu": "ｩ", "le": "ｪ", "lo": "ｫ",
    "xya": "ｬ", "xyu": "ｭ", "xyo": "ｮ",
    "xtu": "ｯ", "ltu": "ｯ", "xtsu": "ｯ",
  ]
}
