import FMSynthesis

/// Standalone OPNA synthesizer with interleaved stereo Float32 output.
public final class YM2608Renderer {
  public enum Port {
    case primary
    case secondary
  }

  public enum ConfigurationError: Error {
    case invalidClock
    case invalidADPCMRange
    case invalidRhythmSample
  }

  public static let sampleRate = 44_100
  public static let adpcmCapacity = 0x40000

  private let chip = YM2608()
  private let clockHz: Int
  private var cycles = 0

  /// The input clock is the external master clock in Hz.
  public init(clockHz: Int) throws {
    guard (Self.sampleRate...16_000_000).contains(clockHz) else { throw ConfigurationError.invalidClock }
    self.clockHz = clockHz
    chip.reset()
    chip.configureStandaloneClock(clockHz)
  }

  public func write(port: Port, register: UInt8, value: UInt8) {
    switch port {
    case .primary:
      chip.writeAddr(register)
      chip.writeData(value)
    case .secondary:
      chip.writeExtAddr(register)
      chip.writeExtData(value)
    }
  }

  public func loadADPCM(_ bytes: [UInt8], at offset: Int) throws {
    guard offset >= 0, offset <= Self.adpcmCapacity, bytes.count <= Self.adpcmCapacity - offset else {
      throw ConfigurationError.invalidADPCMRange
    }
    chip.adpcmRAM.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
  }

  public func loadRhythmSample(index: Int, samples: [Int16], sampleRate: Int) throws {
    guard (0..<6).contains(index), !samples.isEmpty, (1...192_000).contains(sampleRate) else {
      throw ConfigurationError.invalidRhythmSample
    }
    chip.loadRhythmSample(index: index, data: samples, sampleRate: sampleRate)
  }

  /// Advance by one output frame at a time to preserve chip event ordering.
  public func render(frames: Int) -> [Float] {
    guard frames > 0 else { return [] }
    chip.audioBuffer.reserveCapacity(frames * 2)
    for _ in 0..<frames {
      let needed = clockHz - cycles
      let ticks = (needed + Self.sampleRate - 1) / Self.sampleRate
      var remaining = ticks
      while remaining > 0 {
        let step = min(remaining, chip.fmTStatesPerSample)
        chip.tick(tStates: step)
        remaining -= step
      }
      cycles += ticks * Self.sampleRate - clockHz
    }
    let pcm = chip.audioBuffer
    chip.audioBuffer = []
    return pcm
  }
}
