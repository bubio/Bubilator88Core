import Testing
@testable import EmulatorCore
@testable import FMSynthesis

/// Golden-value tests for the CD-mix output stage.
///
/// The reference values come from the offline prototype the parameters were
/// fitted and approved with (float64 Python, sequential circular buffers).
/// The Swift port runs in Float32, so these assert perceptual equivalence
/// rather than bit equality — the point is to catch a transposed constant or
/// an off-by-one delay length, which is what actually goes wrong in this port.
@Suite("AudioPostProcessor")
struct AudioPostProcessorTests {

  /// Impulse response of the default (`.cdMix`) parameters.
  private func impulseResponse(count: Int = 8192) -> (l: [Float], r: [Float]) {
    var p = AudioPostProcessor()
    var l = [Float](); var r = [Float]()
    l.reserveCapacity(count); r.reserveCapacity(count)
    for i in 0..<count {
      let (a, b) = p.process(left: i == 0 ? 1 : 0, right: i == 0 ? 1 : 0)
      l.append(a); r.append(b)
    }
    return (l, r)
  }

  /// The first sample of the impulse response is the one-pole coefficient,
  /// so this pins the low-pass corner at 5400 Hz.
  @Test func lowpassCornerMatchesReference() {
    let ir = impulseResponse(count: 1)
    #expect(abs(ir.l[0] - 0.5366949699) < 1e-5)
  }

  /// The reverb must not appear before the pre-delay elapses. 25 ms at
  /// 44100 Hz is 1102 samples; an off-by-one in the pre-delay ring shows up
  /// here immediately.
  @Test func reverbStartsAfterPredelay() {
    let ir = impulseResponse(count: 1200)
    // Everything between the dry decay and the pre-delay must be silent-ish.
    for i in 400..<1102 {
      #expect(abs(ir.l[i]) < 1e-6, "unexpected energy at \(i): \(ir.l[i])")
    }
    #expect(abs(ir.l[1102] - 0.046600015570) < 1e-5)
    #expect(abs(ir.r[1102] - 0.046600015570) < 1e-5)
  }

  /// Each comb delay produces an echo at `predelay + delay`. This pins all
  /// four left-channel comb lengths at once.
  @Test func combEchoesLandAtExpectedOffsets() {
    let ir = impulseResponse()
    let predelay = 1102
    let expected: [(Int, Float)] = [
      (1422, 5.7605698346e-03),
      (1491, 5.6613145453e-03),
      (1557, 5.8444616689e-03),
      (1617, 5.5285005014e-03),
    ]
    for (delay, value) in expected {
      let got = ir.l[predelay + delay]
      #expect(abs(got - value) < 1e-5,
              "comb delay \(delay): expected \(value), got \(got)")
    }
  }

  /// The right channel is decorrelated from the left by the delay offsets.
  /// If the offsets were dropped, the two channels would be identical and the
  /// whole point of the stage — stereo width — would be lost.
  @Test func channelsAreDecorrelated() {
    let ir = impulseResponse()
    // The tail must differ; the leading edge legitimately matches.
    let differing = zip(ir.l, ir.r).dropFirst(2000).filter { abs($0 - $1) > 1e-6 }
    #expect(differing.count > 1000)
  }

  /// Total energy over the impulse response. Catches gain-staging mistakes
  /// (wet level, the `acc /= combs.count` normalisation) that the spot checks
  /// above would not.
  @Test func totalEnergyMatchesReference() {
    let ir = impulseResponse()
    func rms(_ x: [Float]) -> Double {
      (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }
    #expect(abs(rms(ir.l) - 7.1489810957e-03) < 1e-6)
    #expect(abs(rms(ir.r) - 7.1470136446e-03) < 1e-6)
  }

  /// `reverb: false` (the immersive path) must apply the low-pass and nothing
  /// else — no reverb tail should ever reach the spatial buffers.
  @Test func lowpassOnlyModeHasNoReverbTail() {
    var p = AudioPostProcessor()
    var tail: Float = 0
    for i in 0..<4000 {
      let (l, _) = p.process(left: i == 0 ? 1 : 0, right: i == 0 ? 1 : 0, reverb: false)
      if i > 200 { tail = max(tail, abs(l)) }
    }
    #expect(tail < 1e-6)
  }

  /// `reset()` must fully clear the delay lines, so a state load or a toggle
  /// cannot carry a tail across.
  @Test func resetClearsDelayLines() {
    var p = AudioPostProcessor()
    for _ in 0..<2000 { _ = p.process(left: 0.5, right: -0.5) }
    p.reset()
    let (l, r) = p.process(left: 0, right: 0)
    #expect(l == 0)
    #expect(r == 0)
  }

  /// Sustained-signal equivalence with the reference implementation.
  ///
  /// The impulse tests above only excite phase 0 of each comb, and the
  /// per-phase damping makes this stage periodically time-varying rather than
  /// strictly LTI — so a matching impulse response alone would not prove the
  /// port. Driving 200k samples of deterministic noise exercises every phase
  /// of every delay line.
  @Test func sustainedNoiseMatchesReference() {
    var p = AudioPostProcessor()
    var seed: UInt32 = 12345
    var sumL = 0.0, sumR = 0.0
    var lastL: Float = 0, lastR: Float = 0
    let count = 200_000
    for _ in 0..<count {
      seed = (seed &* 1103515245 &+ 12345) & 0x7FFF_FFFF
      let x = Float(Double(seed) / Double(0x7FFF_FFFF) * 2 - 1) * 0.25
      let (l, r) = p.process(left: x, right: x)
      sumL += Double(l) * Double(l)
      sumR += Double(r) * Double(r)
      lastL = l; lastR = r
    }
    let rmsL = (sumL / Double(count)).squareRoot()
    let rmsR = (sumR / Double(count)).squareRoot()
    #expect(abs(rmsL - 9.4007100339e-02) < 1e-5, "rmsL = \(rmsL)")
    #expect(abs(rmsR - 9.3893888740e-02) < 1e-5, "rmsR = \(rmsR)")
    // Final samples: any drift accumulated over 200k samples shows up here.
    #expect(abs(Double(lastL) - -1.3854261909e-01) < 1e-4, "lastL = \(lastL)")
    #expect(abs(Double(lastR) - -8.4876282009e-02) < 1e-4, "lastR = \(lastR)")
  }

  /// With the stage off, a silent chip must still emit exact zeros. Several
  /// existing tests assert `audioBuffer.allSatisfy { $0 == 0 }`, and a filter
  /// tail leaking in would break them — so this pins the opt-in default and
  /// the property those tests depend on, together.
  @Test func disabledByDefaultLeavesOutputUntouched() {
    let ym = YM2608()
    #expect(ym.cdMixEnabled == false)

    ym.reset()
    for _ in 0..<2000 { ym.tick(tStates: 100) }
    #expect(!ym.audioBuffer.isEmpty)
    #expect(ym.audioBuffer.allSatisfy { $0 == 0 })
  }
}
