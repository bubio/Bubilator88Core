import Testing
@testable import FMSynthesis

/// `audioOutputEnabled = false` skips synthesis for headless runs. It must not
/// change anything the CPU can observe: the status ports, the timer IRQ line
/// and ADPCM end-of-sample.
@Suite("YM2608 audio output switch")
struct YM2608AudioOutputTests {

  private func configure(_ ym: YM2608) {
    ym.reset()
    // Timer A, period 1024 - 0x3F0, with its flag and IRQ enabled.
    ym.writeAddr(0x24); ym.writeData(0xFC)
    ym.writeAddr(0x25); ym.writeData(0x00)
    ym.writeAddr(0x27); ym.writeData(0x15)
    // An FM note and an SSG tone, so synthesis has work to skip.
    ym.writeAddr(0xA4); ym.writeData(0x22)
    ym.writeAddr(0xA0); ym.writeData(0x69)
    ym.writeAddr(0x28); ym.writeData(0xF0)
    ym.writeAddr(0x07); ym.writeData(0x3E)
    ym.writeAddr(0x08); ym.writeData(0x0F)
    // A short ADPCM sample from RAM, played to its end.
    let ext: [(UInt8, UInt8)] = [
      (0x01, 0xC0), (0x02, 0x00), (0x03, 0x00), (0x04, 0x01), (0x05, 0x00),
      (0x09, 0xFF), (0x0A, 0xFF), (0x0B, 0xFF), (0x00, 0xA0),
    ]
    for (addr, value) in ext {
      ym.writeExtAddr(addr)
      ym.writeExtData(value)
    }
  }

  @Test("Status, IRQ and ADPCM EOS match with synthesis off")
  func cpuVisibleStateMatches() {
    let on = YM2608()
    let off = YM2608()
    configure(on)
    configure(off)
    off.audioOutputEnabled = false

    var sawEOS = false
    for _ in 0..<4000 {
      on.tick(tStates: 97)
      off.tick(tStates: 97)
      #expect(on.readStatus() == off.readStatus())
      #expect(on.readExtStatus() == off.readExtStatus())
      #expect(on.irqLineActive == off.irqLineActive)
      if on.adpcmStatusFlags & 0x04 != 0 { sawEOS = true }
    }
    #expect(sawEOS, "the ADPCM sample should have reached its end")
    #expect(!on.audioBuffer.isEmpty)
    #expect(off.audioBuffer.isEmpty)
  }
}
