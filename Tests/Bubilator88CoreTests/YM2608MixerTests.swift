import Testing
import FMSynthesis

@Suite("YM2608 SSG mixer gates")
struct YM2608MixerTests {

  @Test("Tones above the step limit use the disabled-tone gate for every mixer setting")
  func highFrequencyToneGate() {
    for mixer in UInt8(0)..<64 {
      let filtered = YM2608()
      let disabled = YM2608()
      for sound in [filtered, disabled] {
        sound.reset()
        for channel in UInt8(0)..<3 {
          sound.writeAddr(channel * 2)
          sound.writeData(1)
          sound.writeAddr(8 + channel)
          sound.writeData(15 - channel)
        }
        sound.writeAddr(6)
        sound.writeData(3)
      }
      filtered.writeAddr(7)
      filtered.writeData(mixer)
      disabled.writeAddr(7)
      disabled.writeData(mixer | 0x07)
      filtered.tick(tStates: 80_000)
      disabled.tick(tStates: 80_000)
      #expect(!filtered.audioBuffer.isEmpty)
      #expect(filtered.audioBuffer == disabled.audioBuffer)
    }
  }
}
