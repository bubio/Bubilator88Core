import Testing
@testable import FMSynthesis

/// SSG-EG output checked sample for sample against fmgen.
///
/// The golden hashes come from rendering the same channel with BubiC-8801MA's
/// `src/vm/fmgen/fmgen.cpp` (Chip ratio 161, `Channel4` with algorithm 7, only
/// operator 4 audible, key-off at sample 20000) and hashing 30000 `Calc()`
/// results with 64-bit FNV-1a over little-endian Int32. Before the fix the
/// SSG-EG path only refreshed the attenuation on phase changes, so every case
/// here diverged from fmgen.
///
/// Cases with AR below the SSG-EG threshold on types 10/11/13 are left out:
/// there the attenuation goes negative, which fmgen renders as silence and we
/// clamp to full scale (see fmgen-changes.md §4.1).
@Suite("FM SSG-EG matches fmgen")
struct FMSSGEGFmgenGoldenTests {

  private static let cases: [(ssgec: UInt8, ar: UInt32, dr: UInt32, sr: UInt32,
                              sl: UInt32, rr: UInt32, tl: UInt32, hash: UInt64)] = [
    (8, 62, 40, 40, 16, 30, 0, 0x17E78E798BB73222),
    (8, 58, 44, 24, 32, 42, 20, 0x8FE04FFA59BE0360),
    (9, 62, 40, 40, 16, 30, 0, 0xE670C6F02FF135E9),
    (9, 58, 44, 24, 32, 42, 20, 0x19BFBED1C0272600),
    (10, 62, 40, 40, 16, 30, 0, 0x93EB966AA3B861D4),
    (10, 58, 44, 24, 32, 42, 20, 0xB7C27D8B9D9A0FE5),
    (11, 62, 40, 40, 16, 30, 0, 0x4DE3B548AA89E35F),
    (11, 58, 44, 24, 32, 42, 20, 0x268124C7ECCAF311),
    (12, 62, 40, 40, 16, 30, 0, 0xB0F1DDF422BBA982),
    (12, 58, 44, 24, 32, 42, 20, 0x39F4B3A44F6C5D87),
    (13, 62, 40, 40, 16, 30, 0, 0x5A7AD26FAA22E50F),
    (13, 58, 44, 24, 32, 42, 20, 0x268124C7ECCAF311),
    (14, 62, 40, 40, 16, 30, 0, 0x4C24898A1DE10323),
    (14, 58, 44, 24, 32, 42, 20, 0xC4A70D033DD5D7A8),
    (15, 62, 40, 40, 16, 30, 0, 0xB250ADF82F8A4B39),
    (15, 58, 44, 24, 32, 42, 20, 0x19BFBED1C0272600),
  ]

  @Test("SSG-EG channel output is bit-identical to fmgen", arguments: 0..<cases.count)
  func matchesFmgen(index: Int) {
    let c = Self.cases[index]
    let synth = FMSynthesizer()
    #expect(synth.ratio == 161)

    var ch = FMCh()
    ch.reset()
    ch.setAlgorithm(7)
    ch.fb = feedbackShiftTable[0]
    for i in 0..<4 {
      ch.op[i].multiple = 1
      ch.op[i].setTL(i == 3 ? c.tl : 127, csm: false)
      ch.op[i].ar = c.ar
      ch.op[i].dr = c.dr
      ch.op[i].sr = c.sr
      ch.op[i].sl = c.sl
      ch.op[i].rr = c.rr
      ch.op[i].setSSGEC(i == 3 ? c.ssgec : 0)
    }
    ch.setFNum((4 << 11) | 0x26A)
    ch.op[3].doKeyOn(ratio: synth.ratio)

    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for n in 0..<30000 {
      if n == 20000 {
        for i in 0..<4 { ch.op[i].doKeyOff(ratio: synth.ratio) }
      }
      _ = ch.prepare(ratio: synth.ratio, multable: synth.multable)
      let sample = UInt32(truncatingIfNeeded: Int32(ch.calc(ratio: synth.ratio)))
      for shift in stride(from: 0, to: 32, by: 8) {
        hash ^= UInt64((sample >> UInt32(shift)) & 0xFF)
        hash = hash &* 0x0000_0100_0000_01B3
      }
    }
    #expect(hash == c.hash, "SSG-EC \(c.ssgec) AR \(c.ar)")
  }
}
