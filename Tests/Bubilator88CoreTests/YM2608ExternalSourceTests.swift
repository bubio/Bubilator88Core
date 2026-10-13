import Testing
@testable import FMSynthesis

@Suite("YM2608 external source")
struct YM2608ExternalSourceTests {

  /// CD audio is not part of the chip, so the immersive output must carry it
  /// in a buffer of its own: without it, a host playing the stems hears no CD.
  @Test func immersiveOutputCarriesTheExternalSource() {
    let sound = YM2608()
    sound.reset()
    sound.immersiveOutputEnabled = true
    sound.externalSampleSource = { (left: 8000, right: -8000) }
    sound.tick(tStates: 80_000)

    let cd = sound.cdSpatialBuffer
    #expect(!cd.isEmpty)
    #expect(cd.count == sound.fmSpatialBuffer.count)
    #expect(cd.count == sound.audioBuffer.count)
    #expect(cd[0] > 0 && cd[1] < 0)
    #expect(cd[0] == -cd[1])
  }

  @Test func noExternalBufferWithoutImmersiveOutput() {
    let sound = YM2608()
    sound.reset()
    sound.externalSampleSource = { (left: 8000, right: 8000) }
    sound.tick(tStates: 80_000)
    #expect(!sound.audioBuffer.isEmpty)
    #expect(sound.cdSpatialBuffer.isEmpty)
  }
}
