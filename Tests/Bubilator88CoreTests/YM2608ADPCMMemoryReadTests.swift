import Testing
@testable import FMSynthesis

/// ADPCM RAM read-back through reg 0x08 (memory-read mode).
///
/// The chip returns two dummy bytes before the data, as in fmgen (a two-byte
/// read pipeline) and ymfm (`m_dummy_read = 2`). DARK SHRINE's TROUBADOUR RAM
/// DISK relies on it: its sector read calls the byte reader twice and throws
/// the results away, then stores the next 256 (routine at 0xB48B in the
/// loaded image, relocated to 0xF3xx).
@Suite("YM2608 ADPCM memory read")
struct YM2608ADPCMMemoryReadTests {

  private func writeExt(_ ym: YM2608, _ addr: UInt8, _ value: UInt8) {
    ym.writeExtAddr(addr)
    ym.writeExtData(value)
  }

  private func readRAM(_ ym: YM2608) -> UInt8 {
    ym.writeExtAddr(0x08)
    return ym.readExtData()
  }

  /// Programs start/stop like TROUBADOUR (one 256-byte sector) and enters
  /// write or read mode with the given RAM layout.
  private func enterMode(_ ym: YM2608, control1: UInt8, control2: UInt8, start: UInt16, stop: UInt16) {
    writeExt(ym, 0x10, 0x00)
    writeExt(ym, 0x10, 0x80)
    writeExt(ym, 0x00, control1)
    writeExt(ym, 0x01, control2)
    writeExt(ym, 0x02, UInt8(start & 0xFF))
    writeExt(ym, 0x03, UInt8(start >> 8))
    writeExt(ym, 0x04, UInt8(stop & 0xFF))
    writeExt(ym, 0x05, UInt8(stop >> 8))
  }

  private func sector(seed: Int) -> [UInt8] {
    (0..<256).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ seed) }
  }

  @Test("Sector read returns two dummy bytes, then the data", arguments: [UInt8(0x02), UInt8(0x00)])
  func twoDummyReadsThenData(control2: UInt8) {
    let ym = YM2608()
    ym.reset()
    // 8-bit layout (control2 bit 1): 256 bytes = 8 units of 32 bytes.
    // 1-bit layout: 256 bytes = 64 units of 4 bytes.
    let units: UInt16 = control2 & 0x02 != 0 ? 8 : 64
    let start: UInt16 = 0x12E8
    let stop = start + units - 1
    let data = sector(seed: 5)

    enterMode(ym, control1: 0x60, control2: control2, start: start, stop: stop)
    for byte in data {
      ym.writeExtAddr(0x08)
      ym.writeExtData(byte)
    }

    enterMode(ym, control1: 0x20, control2: control2, start: start, stop: stop)
    let reads = (0..<258).map { _ in readRAM(ym) }

    #expect(Array(reads[2...]) == data)
  }

  @Test("Save state taken between reads keeps both pipeline stages")
  func saveStateMidReadKeepsPipeline() {
    let ym = YM2608()
    ym.reset()
    let data = sector(seed: 11)
    enterMode(ym, control1: 0x60, control2: 0x02, start: 0x1280, stop: 0x1287)
    for byte in data {
      ym.writeExtAddr(0x08)
      ym.writeExtData(byte)
    }
    enterMode(ym, control1: 0x20, control2: 0x02, start: 0x1280, stop: 0x1287)
    // Two dummies and the first data byte consumed; the pipeline now holds
    // data[1] and data[2].
    for _ in 0..<3 { _ = readRAM(ym) }

    let restored = YM2608()
    restored.reset()
    #expect(restored.deserializeState(ym.serializeState()))

    let rest = (0..<255).map { _ in readRAM(restored) }
    #expect(rest == Array(data[1...]))
  }
}
