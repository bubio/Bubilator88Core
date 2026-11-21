import Bubilator88Core
import Testing

@Test func standaloneOPNARendering() throws {
  let synth = try YM2608Renderer(clockHz: 8_000_000)
  synth.write(port: .primary, register: 0, value: 100)
  synth.write(port: .primary, register: 7, value: 0x3E)
  synth.write(port: .primary, register: 8, value: 15)
  let first = synth.render(frames: 300)
  let second = synth.render(frames: 724)
  let reference = try YM2608Renderer(clockHz: 8_000_000)
  reference.write(port: .primary, register: 0, value: 100)
  reference.write(port: .primary, register: 7, value: 0x3E)
  reference.write(port: .primary, register: 8, value: 15)
  #expect(first.count == 600)
  #expect(second.count == 1448)
  #expect(first.contains { $0 != 0 })
  #expect(first + second == reference.render(frames: 1024))
}

@Test func standaloneOPNAClockChangesPitch() throws {
  func signChanges(clock: Int) throws -> Int {
    let synth = try YM2608Renderer(clockHz: clock)
    synth.write(port: .primary, register: 0, value: 100)
    synth.write(port: .primary, register: 7, value: 0x3E)
    synth.write(port: .primary, register: 8, value: 15)
    let pcm = synth.render(frames: 44_100)
    return stride(from: 2, to: pcm.count, by: 2).filter {
      (pcm[$0] > 0) != (pcm[$0 - 2] > 0)
    }.count
  }
  let low = try signChanges(clock: 4_000_000)
  let high = try signChanges(clock: 8_000_000)
  #expect(low > 0)
  #expect(abs(high - 2 * low) <= 2)
}

@Test func standaloneOPNARhythmAndADPCM() throws {
  let rhythm = try YM2608Renderer(clockHz: 8_000_000)
  try rhythm.loadRhythmSample(index: 0, samples: Array(repeating: 12_000, count: 128), sampleRate: 44_100)
  rhythm.write(port: .primary, register: 0x11, value: 0x3F)
  rhythm.write(port: .primary, register: 0x18, value: 0xDF)
  rhythm.write(port: .primary, register: 0x10, value: 1)
  #expect(rhythm.render(frames: 64).contains { $0 != 0 })

  let adpcm = try YM2608Renderer(clockHz: 8_000_000)
  try adpcm.loadADPCM(Array(repeating: 0x77, count: 64), at: 0)
  adpcm.write(port: .secondary, register: 1, value: 0xC0)
  adpcm.write(port: .secondary, register: 4, value: 15)
  adpcm.write(port: .secondary, register: 9, value: 0xFF)
  adpcm.write(port: .secondary, register: 10, value: 0xFF)
  adpcm.write(port: .secondary, register: 11, value: 0xFF)
  adpcm.write(port: .secondary, register: 0, value: 0xA0)
  #expect(adpcm.render(frames: 64).contains { $0 != 0 })
  #expect(throws: YM2608Renderer.ConfigurationError.self) {
    try adpcm.loadADPCM([0], at: YM2608Renderer.adpcmCapacity)
  }
}

@Test func standaloneOPNAFMRegistersGenerateStereo() throws {
  let synth = try YM2608Renderer(clockHz: 8_000_000)
  synth.write(port: .primary, register: 0xB0, value: 7)
  synth.write(port: .primary, register: 0xB4, value: 0x80)
  for offset: UInt8 in [0, 4, 8, 12] {
    synth.write(port: .primary, register: 0x30 + offset, value: 1)
    synth.write(port: .primary, register: 0x40 + offset, value: 0)
    synth.write(port: .primary, register: 0x50 + offset, value: 0x1F)
  }
  synth.write(port: .primary, register: 0xA4, value: 0x22)
  synth.write(port: .primary, register: 0xA0, value: 0x69)
  synth.write(port: .primary, register: 0x28, value: 0xF0)
  let pcm = synth.render(frames: 1024)
  #expect(stride(from: 0, to: pcm.count, by: 2).contains { pcm[$0] != 0 })
  #expect(stride(from: 1, to: pcm.count, by: 2).allSatisfy { pcm[$0] == 0 })
}
