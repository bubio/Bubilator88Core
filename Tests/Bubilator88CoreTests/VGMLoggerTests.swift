import CApi
import FMSynthesis
import Foundation
import Testing
@testable import Bubilator88Core

@Suite struct VGMLoggerTests {

  enum Command: Equatable {
    case write(secondary: Bool, register: UInt8, value: UInt8)
    case wait(Int)
    case adpcm(offset: Int, bytes: [UInt8])
  }

  static let hz4 = VGMLogger.cpuClockHz(eightMHz: false)
  static let hz8 = VGMLogger.cpuClockHz(eightMHz: true)

  static func u32(_ b: [UInt8], _ at: Int) -> Int {
    Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24
  }

  /// Parse the command stream, merging consecutive waits.
  static func commands(_ file: [UInt8]) -> [Command] {
    var p = 0x34 + u32(file, 0x34)
    var out: [Command] = []
    func wait(_ n: Int) {
      if case .wait(let m) = out.last { out[out.count - 1] = .wait(m + n) } else { out.append(.wait(n)) }
    }
    while p < file.count {
      let c = file[p]
      switch c {
      case 0x56, 0x57:
        out.append(.write(secondary: c == 0x57, register: file[p + 1], value: file[p + 2]))
        p += 3
      case 0x61: wait(Int(file[p + 1]) | Int(file[p + 2]) << 8); p += 3
      case 0x62: wait(735); p += 1
      case 0x63: wait(882); p += 1
      case 0x70...0x7F: wait(Int(c & 0x0F) + 1); p += 1
      case 0x67:
        #expect(file[p + 1] == 0x66 && file[p + 2] == 0x81)
        let size = u32(file, p + 3)
        #expect(u32(file, p + 7) == 0x40000)
        let offset = u32(file, p + 11)
        out.append(.adpcm(offset: offset, bytes: Array(file[(p + 15)..<(p + 7 + size)])))
        p += 7 + size
      case 0x66:
        return out
      default:
        Issue.record("unexpected command \(c)")
        return out
      }
    }
    Issue.record("no end command")
    return out
  }

  /// Commands after the initial register dump.
  static func body(_ file: [UInt8], from chip: YM2608) -> [Command] {
    let dump = commands(VGMLogger(chip: chip, tState: 0, cpuClockHz: hz4)
      .finish(tState: 0, cpuClockHz: hz4, gameName: ""))
    return Array(commands(file).dropFirst(dump.count))
  }

  static func freshChip() -> YM2608 {
    let chip = YM2608()
    chip.reset()
    return chip
  }

  @Test func headerDescribesOneYM2608() {
    let logger = VGMLogger(chip: Self.freshChip(), tState: 0, cpuClockHz: Self.hz4)
    let file = logger.finish(tState: UInt64(Self.hz4), cpuClockHz: Self.hz4, gameName: "ザナドゥ")

    #expect(Array(file[0..<4]) == Array("Vgm ".utf8))
    #expect(Self.u32(file, 0x04) == file.count - 4)
    #expect(Self.u32(file, 0x08) == 0x151)
    #expect(Self.u32(file, 0x18) == 44_100)
    #expect(Self.u32(file, 0x34) + 0x34 == 0x80)
    #expect(Self.u32(file, 0x48) == 7_987_248)
    // No other chip: BubiTunes refuses files that name one.
    for offset in stride(from: 0x0C, to: 0x80, by: 4)
      where ![0x14, 0x18, 0x1C, 0x20, 0x34, 0x48].contains(offset) && offset != 0x08 {
      #expect(Self.u32(file, offset) == 0, "offset 0x\(String(offset, radix: 16))")
    }

    let gd3 = 0x14 + Self.u32(file, 0x14)
    #expect(Array(file[gd3..<(gd3 + 4)]) == Array("Gd3 ".utf8))
    let text = String(decoding: file[(gd3 + 12)...].withUnsafeBytes {
      Array($0.bindMemory(to: UInt16.self))
    }, as: UTF16.self)
    #expect(text.components(separatedBy: "\0")[2] == "ザナドゥ")
  }

  @Test func initialDumpSkipsKeyOnAndTimers() {
    let chip = Self.freshChip()
    chip.writeAddr(0x28); chip.writeData(0xF0)
    chip.writeAddr(0xA4); chip.writeData(0x22)
    chip.writeAddr(0xA0); chip.writeData(0x69)
    let all = Self.commands(VGMLogger(chip: chip, tState: 0, cpuClockHz: Self.hz4)
      .finish(tState: 0, cpuClockHz: Self.hz4, gameName: ""))
    let registers = all.compactMap { c -> UInt8? in
      if case .write(false, let r, _) = c { return r } else { return nil }
    }
    #expect(!registers.contains(0x28))
    #expect(!registers.contains(0x10))
    #expect(!registers.contains(0x24))
    // The F-number high byte latches, so it must precede the low byte.
    let high = all.firstIndex(of: .write(secondary: false, register: 0xA4, value: 0x22))!
    let low = all.firstIndex(of: .write(secondary: false, register: 0xA0, value: 0x69))!
    #expect(high < low)
    #expect(!all.contains { if case .adpcm = $0 { true } else { false } })
  }

  /// An OPN program never writes the pan registers; the chip resets them to
  /// L+R, so the dump must too or the player mutes every FM channel.
  @Test func initialDumpUsesResetDefaultsNotTheRegisterFile() {
    let all = Self.commands(VGMLogger(chip: Self.freshChip(), tState: 0, cpuClockHz: Self.hz4)
      .finish(tState: 0, cpuClockHz: Self.hz4, gameName: ""))
    for secondary in [false, true] {
      for r: UInt8 in 0xB4...0xB6 {
        #expect(all.contains(.write(secondary: secondary, register: r, value: 0xC0)))
      }
    }
    #expect(all.contains(.write(secondary: false, register: 0x07, value: 0xFF)))
    #expect(all.contains(.write(secondary: true, register: 0x01, value: 0xC0)))
  }

  @Test func waitsCarryTheFractionAndFollowTheClock() {
    let chip = Self.freshChip()
    let logger = VGMLogger(chip: chip, tState: 0, cpuClockHz: Self.hz4)
    // 1000 writes at 100 T-states each: 100,000 T-states at 4MHz.
    for i in 1...1000 {
      logger.log(secondary: false, register: 0x08, value: 0, tState: UInt64(i * 100), cpuClockHz: Self.hz4)
    }
    // Then one second at 8MHz.
    let end = UInt64(100_000 + Self.hz8)
    let file = logger.finish(tState: end, cpuClockHz: Self.hz8, gameName: "")
    let expected = 100_000 * 44_100 / Self.hz4 + 44_100
    #expect(Self.u32(file, 0x18) == expected)
    let waits = Self.body(file, from: chip).reduce(0) { sum, c in
      if case .wait(let n) = c { sum + n } else { sum }
    }
    #expect(waits == expected)
  }

  @Test func waitEncodings() {
    let chip = Self.freshChip()
    let logger = VGMLogger(chip: chip, tState: 0, cpuClockHz: 44_100)
    var t: UInt64 = 0
    for n in [1, 16, 17, 735, 882, 70_000] {
      t += UInt64(n)
      logger.log(secondary: true, register: 0x0B, value: 0xFF, tState: t, cpuClockHz: 44_100)
    }
    let body = Self.body(logger.finish(tState: t, cpuClockHz: 44_100, gameName: ""), from: chip)
    let waits = body.compactMap { c -> Int? in if case .wait(let n) = c { n } else { nil } }
    #expect(waits == [1, 16, 17, 735, 882, 70_000])
  }

  @Test func timerWritesAreFilteredExceptCH3Mode() {
    let chip = Self.freshChip()
    let logger = VGMLogger(chip: chip, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: false, register: 0x24, value: 0x12, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: false, register: 0x27, value: 0x15, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: false, register: 0x27, value: 0x55, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: false, register: 0x27, value: 0x5F, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: false, register: 0x0E, value: 0x00, tState: 0, cpuClockHz: Self.hz4)
    logger.log(secondary: true, register: 0x24, value: 0x34, tState: 0, cpuClockHz: Self.hz4)
    let body = Self.body(logger.finish(tState: 0, cpuClockHz: Self.hz4, gameName: ""), from: chip)
    #expect(body == [
      .write(secondary: false, register: 0x27, value: 0x40),
      .write(secondary: true, register: 0x24, value: 0x34),
    ])
  }

  @Test func adpcmRAMIsDumpedAndResyncSendsOnlyTheChange() {
    let chip = Self.freshChip()
    chip.adpcmRAM[0x10] = 0xAA
    chip.adpcmRAM[0x13] = 0xBB
    let logger = VGMLogger(chip: chip, tState: 0, cpuClockHz: Self.hz4)
    let before = chip.adpcmRAM
    chip.adpcmRAM[0x2000] = 0xCC
    chip.adpcmRAM[0x2002] = 0xDD
    logger.resync(chip: chip, previousADPCM: before, tState: 0, cpuClockHz: Self.hz4)
    let blocks = Self.commands(logger.finish(tState: 0, cpuClockHz: Self.hz4, gameName: ""))
      .compactMap { c -> Command? in if case .adpcm = c { c } else { nil } }
    #expect(blocks == [
      .adpcm(offset: 0, bytes: Array(repeating: 0, count: 0x10) + [0xAA, 0, 0, 0xBB]),
      .adpcm(offset: 0x2000, bytes: [0xCC, 0, 0xDD]),
    ])
  }

  @Test func machineLogsPortWritesInEmulatedTime() {
    let machine = Machine()
    machine.reset()
    machine.startVGMLogging()
    machine.totalTStates += UInt64(Self.hz8)  // one second
    machine.bus.currentTState = machine.totalTStates
    machine.bus.ioWrite(0x44, value: 0x08)
    machine.bus.ioWrite(0x45, value: 0x0F)
    machine.bus.ioWrite(0x46, value: 0x0B)
    machine.bus.ioWrite(0x47, value: 0x80)
    let file = machine.stopVGMLogging(gameName: "")!
    #expect(!machine.isVGMLogging)
    #expect(Self.body(file, from: machine.sound) == [
      .wait(44_100),
      .write(secondary: false, register: 0x08, value: 0x0F),
      .write(secondary: true, register: 0x0B, value: 0x80),
    ])
  }

  @Test func resetKeepsTheLogGoing() {
    let machine = Machine()
    machine.reset()
    machine.startVGMLogging()
    machine.totalTStates += 1_000_000
    machine.reset()
    #expect(machine.isVGMLogging)
    machine.bus.ioWrite(0x44, value: 0x08)
    machine.bus.ioWrite(0x45, value: 0x0F)
    let commands = Self.commands(machine.stopVGMLogging(gameName: "")!)
    #expect(commands.last == .write(secondary: false, register: 0x08, value: 0x0F))
    // The only wait is the time played before the reset.
    let waits = commands.compactMap { c -> Int? in if case .wait(let n) = c { n } else { nil } }
    #expect(waits == [1_000_000 * 44_100 / Self.hz8])
  }

  /// The time between the last write and a reset belongs in the log: a note
  /// held up to a reset or state load keeps its length.
  @Test func timeBeforeAResetIsKept() {
    let machine = Machine()
    machine.reset()
    machine.startVGMLogging()
    machine.totalTStates += UInt64(Self.hz8)  // one second at 8MHz
    machine.reset()
    let file = machine.stopVGMLogging(gameName: "")!
    #expect(Self.u32(file, 0x18) == 44_100)
  }

  /// Time before a clock switch is measured at the rate it ran at.
  @Test func timeBeforeAClockSwitchUsesTheOldRate() {
    let machine = Machine()
    machine.reset()
    machine.startVGMLogging()
    machine.totalTStates += UInt64(Self.hz8)  // one second at 8MHz
    machine.clock8MHz = false
    machine.totalTStates += UInt64(Self.hz4)  // one second at 4MHz
    let file = machine.stopVGMLogging(gameName: "")!
    #expect(Self.u32(file, 0x18) == 88_200)
  }

  @Test func cABIRoundTrip() {
    let handle = b88_create()
    defer { b88_destroy(handle) }
    #expect(b88_vgm_stop(handle, nil) == 0)
    b88_vgm_start(handle)
    #expect(b88_vgm_is_logging(handle) == 1)
    let length = b88_vgm_stop(handle, "Game")
    #expect(length > 0x80)
    #expect(b88_vgm_is_logging(handle) == 0)
    var buffer = [UInt8](repeating: 0, count: Int(length))
    #expect(b88_vgm_read(handle, &buffer, length) == length)
    #expect(Array(buffer[0..<4]) == Array("Vgm ".utf8))
  }
}
