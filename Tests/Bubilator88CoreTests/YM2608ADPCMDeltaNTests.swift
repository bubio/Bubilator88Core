import Testing
@testable import FMSynthesis

/// Delta-N (ext reg 0x09/0x0A), the ADPCM-B playback rate divider.
///
/// fmgen keeps the two registers verbatim and derives `deltan` from them on
/// every write, flooring only the derived value at 256
/// (`deltan = adpcmreg[5]*256+adpcmreg[4]; deltan = Max(256, deltan)`).
/// Flooring the stored pair instead loses the low byte whenever software
/// writes the low register first with a value under 256, since 256 is 0x0100.
/// あたしのぱ・ぴ・ぷ・ぺ・ぽ writes 0x09=0xDD then 0x0A=0x24 and used to end
/// up at 0x2400, playing its ADPCM stream 2.3% slow against the 600Hz RTC
/// tick its animation counts.
@Suite("YM2608 ADPCM delta-N")
struct YM2608ADPCMDeltaNTests {

  private func writeExt(_ ym: YM2608, _ addr: UInt8, _ value: UInt8) {
    ym.writeExtAddr(addr)
    ym.writeExtData(value)
  }

  @Test("Low byte survives a high-byte write that follows it")
  func lowByteSurvivesLowFirstOrder() {
    let ym = YM2608()
    ym.reset()
    writeExt(ym, 0x09, 0xDD)
    writeExt(ym, 0x0A, 0x24)
    #expect(ym.adpcmDeltaN == 0x24DD)
  }

  @Test("High byte first reaches the same pair")
  func highByteFirstOrder() {
    let ym = YM2608()
    ym.reset()
    writeExt(ym, 0x0A, 0x24)
    writeExt(ym, 0x09, 0xDD)
    #expect(ym.adpcmDeltaN == 0x24DD)
  }

  /// The 256 floor still applies to the playback step, which is what fmgen
  /// clamps: adplbase = 8192 * (clock/72) / 44100 = 10303, so the smallest
  /// step is (256 * 10303) >> 16 = 40.
  @Test("A pair under 256 keeps its bytes but floors the playback step")
  func floorAppliesToStepNotRegisters() {
    let ym = YM2608()
    ym.reset()
    writeExt(ym, 0x09, 0xDD)
    #expect(ym.adpcmDeltaN == 0x00DD)
    #expect(ym.adpcmPlaybackDelta == (256 * 10303) >> 16)
  }
}
