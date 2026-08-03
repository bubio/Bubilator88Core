// MARK: - Audio Post Processor
//
// An optional output-shaping stage modelled on how PC-8801 game music was
// mastered for CD in the late 1980s: each source was recorded separately,
// treated, and mixed down. The parameters here were fitted by comparing the
// emulator's raw output against 古代祐三 / The Scheme —
// "I'll Save You All My Justice" (1989) using long-term average spectra and
// Side/Mid ratios per 1/3 octave.
//
// Two stages:
//
//   1. One-pole low-pass. The raw chip output is progressively brighter than
//      the CD above 5 kHz (+4.4 dB at 7 kHz, +6.5 dB at 9 kHz). A single
//      6 dB/oct low-pass at 5.4 kHz reconciles 1.6 kHz–10 kHz to within
//      1.4 dB. Note this is a *fit to one CD*, and that signal chain includes
//      the studio console, tape and 1989 mastering — it is not a measured
//      PC-8801 output-stage characteristic. Treat it as taste, not accuracy.
//
//   2. Schroeder stereo reverb on a mono send. Matches the CD's Side/Mid ratio
//      from 500 Hz to 10 kHz to within 2 dB.
//
// Below 160 Hz the CD is markedly wider than anything this stage produces
// (Side/Mid −11.8 dB vs −43 dB at 63–80 Hz). That implies the bass parts were
// panned during mixdown, which needs per-FM-channel stems to reproduce and is
// deliberately out of scope here.
//
// Not serialized: save states restore chip state only, so the delay lines
// start empty after a load. A brief reverb discontinuity there is expected.

import Foundation

/// One-pole filter: `y[n] = y[n-1] + a * (x[n] - y[n-1])`.
///
/// Used both as a low-pass (its own output) and as a high-pass
/// (`x[n] - y[n]`, see `AudioPostProcessor.process`).
struct OnePoleFilter {
  private let a: Float
  private var z: Float = 0

  init(cutoffHz: Float, sampleRate: Float) {
    a = 1 - expf(-2 * .pi * cutoffHz / sampleRate)
  }

  mutating func process(_ x: Float) -> Float {
    z += a * (x - z)
    return z
  }

  mutating func reset() { z = 0 }
}

/// Feedback comb filter with damping.
///
/// Damping state is **per delay-line phase** rather than a single shared
/// scalar: each of the `D` interleaved sub-streams carries its own one-pole.
/// This differs from textbook Freeverb, and is intentional — it is the
/// behaviour of the offline prototype whose output was approved by ear.
struct CombFilter {
  private var buffer: [Float]
  private var damping: [Float]
  private var pos: Int = 0
  private let g: Float
  private let a: Float

  init(delay: Int, feedback: Float, dampingHz: Float, sampleRate: Float) {
    buffer = [Float](repeating: 0, count: delay)
    damping = [Float](repeating: 0, count: delay)
    g = feedback
    a = 1 - expf(-2 * .pi * dampingHz / sampleRate)
  }

  mutating func process(_ x: Float) -> Float {
    let p = pos
    damping[p] += a * (buffer[p] - damping[p])
    let v = x + g * damping[p]
    buffer[p] = v
    pos = p + 1 == buffer.count ? 0 : p + 1
    return v
  }

  mutating func reset() {
    for i in buffer.indices { buffer[i] = 0; damping[i] = 0 }
    pos = 0
  }
}

/// Schroeder all-pass section.
struct AllpassFilter {
  private var buffer: [Float]
  private var pos: Int = 0
  private let g: Float

  init(delay: Int, gain: Float) {
    buffer = [Float](repeating: 0, count: delay)
    g = gain
  }

  mutating func process(_ x: Float) -> Float {
    let p = pos
    let buffered = buffer[p]
    let v = x + g * buffered
    buffer[p] = v
    pos = p + 1 == buffer.count ? 0 : p + 1
    return buffered - g * v
  }

  mutating func reset() {
    for i in buffer.indices { buffer[i] = 0 }
    pos = 0
  }
}

/// Four parallel combs into two series all-passes.
struct SchroederReverb {
  /// Base comb delays in samples at 44100 Hz (Schroeder/Freeverb lineage).
  static let combDelays = [1557, 1617, 1491, 1422]
  static let allpassDelays = [225, 556]

  /// Delay offsets that decorrelate the right channel from the left.
  static let rightCombOffset = 23
  static let rightAllpassOffset = 7

  private var combs: [CombFilter]
  private var allpasses: [AllpassFilter]

  init(rt60: Float, dampingHz: Float, sampleRate: Float, combOffset: Int, allpassOffset: Int) {
    combs = Self.combDelays.map { base in
      let d = base + combOffset
      // Feedback that decays 60 dB over rt60 seconds for this delay length.
      let feedback = powf(10, -3 * Float(d) / (rt60 * sampleRate))
      return CombFilter(delay: d, feedback: feedback, dampingHz: dampingHz, sampleRate: sampleRate)
    }
    allpasses = Self.allpassDelays.map {
      AllpassFilter(delay: $0 + allpassOffset, gain: 0.5)
    }
  }

  mutating func process(_ x: Float) -> Float {
    var acc: Float = 0
    for i in combs.indices { acc += combs[i].process(x) }
    acc /= Float(combs.count)
    for i in allpasses.indices { acc = allpasses[i].process(acc) }
    return acc
  }

  mutating func reset() {
    for i in combs.indices { combs[i].reset() }
    for i in allpasses.indices { allpasses[i].reset() }
  }
}

/// Optional "CD mix" output stage. Disabled by default; see the file header
/// for why these are presented as taste rather than hardware accuracy.
public struct AudioPostProcessor {

  /// Fitted parameters. See file header for provenance.
  public struct Parameters: Sendable, Equatable {
    /// Output low-pass corner. 0 disables the low-pass.
    public var lowpassHz: Float = 5400
    /// Reverb decay to −60 dB, in seconds.
    public var reverbRT60: Float = 1.2
    /// Reverb pre-delay in milliseconds.
    public var reverbPredelayMs: Float = 25
    /// Reverb in-loop damping corner.
    public var reverbDampingHz: Float = 7000
    /// High-pass on the reverb send, keeping bass out of the tail.
    public var reverbSendHighpassHz: Float = 150
    /// Wet level in dB relative to dry.
    public var reverbWetDb: Float = -9

    public init() {}

    public static let cdMix = Parameters()
  }

  private var lowpassL: OnePoleFilter
  private var lowpassR: OnePoleFilter
  private var sendHighpass: OnePoleFilter
  private var predelay: [Float]
  private var predelayPos: Int = 0
  private var reverbL: SchroederReverb
  private var reverbR: SchroederReverb

  private let lowpassEnabled: Bool
  private let wetGain: Float

  public init(parameters: Parameters = .cdMix, sampleRate: Float = 44100) {
    lowpassEnabled = parameters.lowpassHz > 0
    // Cutoff is unused when disabled, but the filter still needs a valid one.
    let lpHz = lowpassEnabled ? parameters.lowpassHz : sampleRate / 2
    lowpassL = OnePoleFilter(cutoffHz: lpHz, sampleRate: sampleRate)
    lowpassR = OnePoleFilter(cutoffHz: lpHz, sampleRate: sampleRate)

    sendHighpass = OnePoleFilter(cutoffHz: parameters.reverbSendHighpassHz, sampleRate: sampleRate)
    predelay = [Float](repeating: 0, count: max(1, Int(sampleRate * parameters.reverbPredelayMs / 1000)))

    reverbL = SchroederReverb(rt60: parameters.reverbRT60, dampingHz: parameters.reverbDampingHz,
                              sampleRate: sampleRate, combOffset: 0, allpassOffset: 0)
    reverbR = SchroederReverb(rt60: parameters.reverbRT60, dampingHz: parameters.reverbDampingHz,
                              sampleRate: sampleRate,
                              combOffset: SchroederReverb.rightCombOffset,
                              allpassOffset: SchroederReverb.rightAllpassOffset)

    wetGain = powf(10, parameters.reverbWetDb / 20)
  }

  /// Apply low-pass + reverb to one stereo frame.
  ///
  /// Pass `reverb: false` to run the low-pass alone — used by the immersive
  /// path, where each source is rendered to its own spatial node and a shared
  /// reverb bus has nowhere to sit.
  public mutating func process(left: Float, right: Float, reverb: Bool = true) -> (Float, Float) {
    var l = left
    var r = right
    if lowpassEnabled {
      l = lowpassL.process(l)
      r = lowpassR.process(r)
    }
    guard reverb else { return (l, r) }

    var send = (l + r) * 0.5
    send -= sendHighpass.process(send)

    let delayed = predelay[predelayPos]
    predelay[predelayPos] = send
    predelayPos = predelayPos + 1 == predelay.count ? 0 : predelayPos + 1

    return (l + wetGain * reverbL.process(delayed),
            r + wetGain * reverbR.process(delayed))
  }

  /// Clear all delay lines. Call on chip reset and after loading a save state.
  public mutating func reset() {
    lowpassL.reset(); lowpassR.reset(); sendHighpass.reset()
    for i in predelay.indices { predelay[i] = 0 }
    predelayPos = 0
    reverbL.reset(); reverbR.reset()
  }
}
