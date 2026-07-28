import Testing
@testable import EmulatorCore

@Suite("RomajiKanaConverter Tests")
struct RomajiKanaConverterTests {

  /// Feed every character then flush, concatenating all committed output.
  /// Mirrors how the ViewModel drives the converter for a full word.
  private func convert(_ romaji: String) -> String {
    var conv = RomajiKanaConverter()
    var out = ""
    for c in romaji { out += conv.feed(c) }
    out += conv.flush()
    return out
  }

  // MARK: - Basic syllables

  @Test func vowels() {
    #expect(convert("aiueo") == "ｱｲｳｴｵ")
  }

  @Test func kaGyo() {
    #expect(convert("ka") == "ｶ")
    #expect(convert("kakikukeko") == "ｶｷｸｹｺ")
  }

  @Test func shiVariants() {
    #expect(convert("shi") == "ｼ")
    #expect(convert("si") == "ｼ")
    #expect(convert("tsu") == "ﾂ")
    #expect(convert("tu") == "ﾂ")
    #expect(convert("chi") == "ﾁ")
  }

  // MARK: - Youon (拗音, contracted sounds)

  @Test func youon() {
    #expect(convert("kya") == "ｷｬ")
    #expect(convert("sha") == "ｼｬ")
    #expect(convert("sya") == "ｼｬ")
    #expect(convert("cha") == "ﾁｬ")
    #expect(convert("nyu") == "ﾆｭ")
    #expect(convert("ryo") == "ﾘｮ")
  }

  // MARK: - Voiced / semi-voiced use standalone ﾞ / ﾟ

  @Test func dakuten() {
    #expect(convert("ga") == "ｶﾞ")
    #expect(convert("za") == "ｻﾞ")
    #expect(convert("ji") == "ｼﾞ")
    #expect(convert("da") == "ﾀﾞ")
    #expect(convert("ba") == "ﾊﾞ")
  }

  @Test func handakuten() {
    #expect(convert("pa") == "ﾊﾟ")
    #expect(convert("po") == "ﾎﾟ")
    // The semi-voiced mark must be a *standalone* half-width ﾟ (U+FF9F).
    #expect(convert("pa").unicodeScalars.contains("\u{FF9F}"))
  }

  // MARK: - Sokuon (促音, the small ﾂ)

  @Test func sokuon() {
    #expect(convert("tta") == "ｯﾀ")
    #expect(convert("kko") == "ｯｺ")
    #expect(convert("gakkou") == "ｶﾞｯｺｳ")
    #expect(convert("cchi") == "ｯﾁ")
  }

  // MARK: - Syllabic ん handling

  @Test func nBeforeConsonantKeepsIt() {
    // ん followed by に: the second n starts "ni", so ｺﾝﾆﾁﾊ, not ｺﾝｲﾁﾊ.
    #expect(convert("konnichiha") == "ｺﾝﾆﾁﾊ")
    // ん followed by な: "onna" → ｵﾝﾅ.
    #expect(convert("onna") == "ｵﾝﾅ")
    // ん followed by a consonant other than n: promote and keep the consonant.
    #expect(convert("hon") == "ﾎﾝ")
    #expect(convert("genki") == "ｹﾞﾝｷ")
  }

  @Test func nBeforeVowelIsSyllable() {
    #expect(convert("na") == "ﾅ")
    #expect(convert("nya") == "ﾆｬ")
  }

  @Test func trailingNFlushes() {
    // A lone trailing "n" resolves to ﾝ on flush.
    #expect(convert("un") == "ｳﾝ")
  }

  // MARK: - Long vowel

  @Test func longVowelMark() {
    #expect(convert("ra-men") == "ﾗｰﾒﾝ")
    #expect(convert("-").unicodeScalars.first == "\u{FF70}")
  }

  // MARK: - Output is always half-width (so TextPasteQueue won't drop it)

  @Test func outputIsHalfWidthKana() {
    let out = convert("konnichiha")
    for scalar in out.unicodeScalars {
      let v = scalar.value
      let isHalfKana = (0xFF61...0xFF9F).contains(v)
      #expect(isHalfKana, "\(scalar) (U+\(String(v, radix: 16))) is not half-width kana")
    }
  }

  /// Every table value routes through TextPasteQueue's single-byte kana path
  /// (Shift-JIS 0xA1–0xDF) or the standalone marks — i.e. no full-width kana
  /// leaks in, which enqueue() would silently drop.
  @Test func everyTableValueIsHalfWidth() {
    for (_, kana) in RomajiKanaConverter.table {
      for scalar in kana.unicodeScalars {
        #expect((0xFF61...0xFF9F).contains(scalar.value),
                "table value \(kana) contains non-half-width \(scalar)")
      }
    }
  }

  // MARK: - Pending buffer / overlay support

  @Test func pendingReflectsUncommittedRomaji() {
    var conv = RomajiKanaConverter()
    _ = conv.feed("k")
    #expect(conv.pending == "k")
    _ = conv.feed("y")
    #expect(conv.pending == "ky")
    let out = conv.feed("a")
    #expect(out == "ｷｬ")
    #expect(conv.pending == "")
  }

  // MARK: - Backspace

  @Test func backspacePopsPending() {
    var conv = RomajiKanaConverter()
    _ = conv.feed("k")
    _ = conv.feed("y")
    #expect(conv.backspace() == true)
    #expect(conv.pending == "k")
    #expect(conv.backspace() == true)
    #expect(conv.pending == "")
    // Nothing left to delete → returns false so the host sends Backspace on.
    #expect(conv.backspace() == false)
  }

  // MARK: - reset

  @Test func resetClearsPending() {
    var conv = RomajiKanaConverter()
    _ = conv.feed("k")
    conv.reset()
    #expect(conv.pending == "")
    #expect(conv.flush() == "")
  }
}
