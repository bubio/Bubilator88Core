import Testing
@testable import FMSynthesis

@Suite("YM2608 pseudo-stereo gating")
struct YM2608PseudoStereoTests {

  /// SSG tone on channel A, loud enough that the Haas delay shows up as a
  /// left/right difference in the mixed output.
  private func makeSSGTone(pseudoStereo: Bool) -> YM2608 {
    let sound = YM2608()
    sound.reset()
    sound.pseudoStereoEnabled = pseudoStereo
    sound.writeAddr(0x00); sound.writeData(0x40)  // tone period low
    sound.writeAddr(0x01); sound.writeData(0x01)  // tone period high
    sound.writeAddr(0x07); sound.writeData(0x3E)  // mixer: tone A only
    sound.writeAddr(0x08); sound.writeData(0x0F)  // channel A volume
    return sound
  }

  private func hasStereoDifference(_ sound: YM2608) -> Bool {
    stride(from: 0, to: sound.audioBuffer.count - 1, by: 2).contains {
      sound.audioBuffer[$0] != sound.audioBuffer[$0 + 1]
    }
  }

  /// Writes a non-centre pan to FM channel 1 (register 0xB4, right only).
  private func panChannel1Right(_ sound: YM2608) {
    sound.writeAddr(0xB4)
    sound.writeData(0x40)
  }

  @Test("SSG output is widened while no FM channel is panned")
  func ssgWidenedWhenCentred() {
    let sound = makeSSGTone(pseudoStereo: true)
    sound.tick(tStates: 80_000)
    #expect(!sound.audioBuffer.isEmpty)
    #expect(hasStereoDifference(sound))
  }

  @Test("SSG widening stops once the program pans an FM channel")
  func ssgFollowsFMPanDetection() {
    let sound = makeSSGTone(pseudoStereo: true)
    panChannel1Right(sound)
    #expect(sound.fmPanDetected)
    sound.tick(tStates: 80_000)
    #expect(!sound.audioBuffer.isEmpty)
    #expect(!hasStereoDifference(sound))
  }

  @Test("Pan detection runs even while pseudo-stereo is off")
  func panDetectedWithPseudoStereoDisabled() {
    let sound = makeSSGTone(pseudoStereo: false)
    panChannel1Right(sound)
    #expect(sound.fmPanDetected)
  }

  @Test("A save state load rebuilds the pan latch from the restored channels")
  func panLatchSurvivesSaveStateRoundTrip() {
    let source = makeSSGTone(pseudoStereo: true)
    panChannel1Right(source)
    let state = source.serializeState()

    let restored = makeSSGTone(pseudoStereo: true)
    #expect(!restored.fmPanDetected)
    #expect(restored.deserializeState(state))
    #expect(restored.fmPanDetected)
  }

  @Test("A save state taken before any pan write leaves the latch clear")
  func centredStateLoadsWithLatchClear() {
    let source = makeSSGTone(pseudoStereo: true)
    let state = source.serializeState()

    let restored = makeSSGTone(pseudoStereo: true)
    panChannel1Right(restored)
    #expect(restored.deserializeState(state))
    #expect(!restored.fmPanDetected)
  }
}
