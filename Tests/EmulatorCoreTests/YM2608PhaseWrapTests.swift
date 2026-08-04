import Testing
import Foundation
@testable import EmulatorCore
@testable import FMSynthesis

/// F-Number 0 combined with a negative DT1 underflows the hardware's 17-bit
/// phase-step adder, so the operator runs at close to the maximum step instead
/// of standing still at DC. Xanadu Scenario II's level 4 BGM uses this on
/// purpose for a high "keen" chime. Stock fmgen keeps the step negative and
/// stays silent there; see FMSynthesizer.prepare() for which cores do what.
@Suite("YM2608 phase step wrap")
struct YM2608PhaseWrapTests {

  /// Renders FM channel 1 alone and returns the dominant frequency.
  private func dominantFrequency(detune: UInt8, fnumLow: UInt8, blockFnumHigh: UInt8) -> Double {
    let ym = YM2608()
    ym.reset()
    ym.debugOutputMask = .fm

    func write(_ addr: UInt8, _ value: UInt8) {
      ym.writeAddr(addr)
      ym.writeData(value)
    }

    // Algorithm 7 (all four operators are carriers), full panning.
    write(0xB0, 0x07)
    write(0xB4, 0xC0)
    for slot in 0..<4 {
      let offset = UInt8(slot * 4)
      write(0x30 + offset, (detune << 4) | 0x01)  // DT1 / MUL=1
      write(0x40 + offset, slot == 0 ? 0x00 : 0x7F)  // only slot 0 audible
      write(0x50 + offset, 0x1F)  // AR max
      write(0x60 + offset, 0x00)  // DR 0
      write(0x70 + offset, 0x00)  // SR 0
      write(0x80 + offset, 0x0F)  // SL 0 / RR max
    }
    write(0xA4, blockFnumHigh)
    write(0xA0, fnumLow)
    write(0x28, 0xF0)  // key on channel 1, all slots

    // Render ~0.19 s and drop the attack.
    let frames = 8192
    let warmup = 2048
    ym.audioBuffer.removeAll()
    let tStatesPerSample = 3_993_624 / YM2608.sampleRate
    while ym.audioBuffer.count < (frames + warmup) * 2 {
      ym.tick(tStates: tStatesPerSample)
    }

    var samples = [Double]()
    for i in warmup..<(warmup + frames) {
      samples.append(Double(ym.audioBuffer[i * 2]))
    }

    // Hann-windowed DFT peak, interpolated across the neighbouring bins.
    let n = samples.count
    for i in 0..<n {
      samples[i] *= 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
    }
    var magnitudes = [Double](repeating: 0, count: n / 2)
    for k in 1..<(n / 2) {
      var re = 0.0, im = 0.0
      let w = -2 * Double.pi * Double(k) / Double(n)
      for i in 0..<n {
        re += samples[i] * cos(w * Double(i))
        im += samples[i] * sin(w * Double(i))
      }
      magnitudes[k] = (re * re + im * im).squareRoot()
    }
    let peak = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }) ?? 0
    return Double(peak) * Double(YM2608.sampleRate) / Double(n)
  }

  /// F-Number 0, block 5, DT1 = 7 — the exact register pair the Xanadu driver
  /// writes (0xA4 = 0x28, 0xA0 = 0x00). Hardware wraps to ~6933 Hz.
  @Test func fnumZeroWithNegativeDetuneWrapsToHighTone() {
    let f = dominantFrequency(detune: 7, fnumLow: 0x00, blockFnumHigh: 0x28)
    #expect(abs(f - 6933) < 80, "expected ~6933 Hz, got \(f) Hz")
  }

  /// The same registers with a non-negative DT1 leave the step at zero, so the
  /// operator really is silent. Guards against the mask firing too eagerly.
  @Test func fnumZeroWithPositiveDetuneStaysAtDC() {
    let f = dominantFrequency(detune: 3, fnumLow: 0x00, blockFnumHigh: 0x28)
    #expect(f < 200, "expected near-DC output, got \(f) Hz")
  }

  /// A normal note must be untouched by the mask: F-Number 1040 / block 4 is
  /// concert A. 2047 << 7 + 44 still fits in 18 bits, so nothing wraps.
  @Test func normalNoteIsUnaffectedByTheMask() {
    // block 4, fnum 1040 → 0xA4 = 0x24, 0xA0 = 0x10
    let f = dominantFrequency(detune: 0, fnumLow: 0x10, blockFnumHigh: 0x24)
    #expect(abs(f - 440) < 12, "expected ~440 Hz, got \(f) Hz")
  }
}
