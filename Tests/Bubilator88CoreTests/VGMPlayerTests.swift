import CApi
import Foundation
import Testing
@testable import Bubilator88Core

@Suite struct VGMPlayerTests {

  /// A minimal VGM 1.71 file around `commands`, at an 8MHz YM2608 clock.
  /// `loop` is a byte offset into `commands`.
  static func vgm(_ commands: [UInt8], loop: Int? = nil, version: UInt32 = 0x171) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x80)
    func put(_ value: UInt32, at offset: Int) {
      for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    put(0x206D_6756, at: 0)
    put(UInt32(0x80 + commands.count - 4), at: 4)
    put(version, at: 8)
    put(0x80 - 0x34, at: 0x34)
    put(8_000_000, at: 0x48)
    if let loop { put(UInt32(0x80 + loop - 0x1C), at: 0x1C) }
    return bytes + commands
  }

  @Test func parsesWritesWaitsAndLoop() throws {
    // write, wait 2, write, wait 3, end; loop starts at the second write.
    let file = try VGMFile(bytes: Self.vgm([0x56, 7, 0x3E, 0x71, 0x57, 0, 4, 0x72, 0x66], loop: 4))
    #expect(file.clockHz == 8_000_000)
    #expect(file.events == [
      .write(secondary: false, register: 7, value: 0x3E), .wait(2),
      .write(secondary: true, register: 0, value: 4), .wait(3),
    ])
    #expect(file.loopStart == 2)
    #expect(file.samples == 5)
    #expect(file.loopSamples == 3)
  }

  @Test func rejectsDamagedAndUnsupportedFiles() {
    #expect(throws: VGMFile.ReadError.self) { try VGMFile(bytes: Self.vgm([0x56, 7])) }
    #expect(throws: VGMFile.ReadError.self) { try VGMFile(bytes: Self.vgm([0x56, 7, 0, 0x66], loop: 1)) }
    #expect(throws: VGMFile.ReadError.self) { try VGMFile(bytes: Self.vgm([0x52, 0, 0, 0x66])) }
    #expect(throws: VGMFile.ReadError.self) {
      try VGMFile(bytes: Self.vgm([0x67, 0x66, 0x81, 8, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0x66]))
    }
    #expect(throws: VGMFile.ReadError.unsupported("version 150")) {
      try VGMFile(bytes: Self.vgm([0x66], version: 0x150))
    }
    // A YM2203 clock beside the YM2608 one.
    var twoChips = Self.vgm([0x66])
    twoChips[0x44] = 1
    #expect(throws: VGMFile.ReadError.unsupported("another sound chip")) {
      try VGMFile(bytes: twoChips)
    }
  }

  @Test func gd3PrefersEnglishThenJapanese() throws {
    var data = Self.vgm([0x70, 0x66])
    func bytes(_ word: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
    let text = ["", "曲名", "Game", "ゲーム", "", "", "Artist", "作者", "", "", ""].joined(separator: "\u{0}")
    let tags = text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    data.replaceSubrange(0x14..<0x18, with: bytes(UInt32(data.count - 0x14)))
    data += [0x47, 0x64, 0x33, 0x20] + bytes(0x100) + bytes(UInt32(tags.count)) + tags
    data.replaceSubrange(4..<8, with: bytes(UInt32(data.count - 4)))

    let file = try VGMFile(bytes: data)
    #expect(file.tags.track == "曲名")
    #expect(file.tags.game == "Game")
    #expect(file.tags.author == "Artist")
    #expect(file.tags.fields.count == 11)
  }

  @Test func playsTheLoopTheRequestedNumberOfTimes() throws {
    let file = try VGMFile(bytes: Self.vgm([0x56, 7, 0x3E, 0x71, 0x57, 0, 4, 0x72, 0x66], loop: 4))
    let once = try VGMPlayer(file: file, loops: 0)
    #expect(once.totalFrames == 5)
    let twice = try VGMPlayer(file: file, loops: 2)
    #expect(twice.totalFrames == 11)
    #expect(twice.render(maxFrames: 100).count == 22)
    #expect(twice.isFinished)
    #expect(twice.render(maxFrames: 100).isEmpty)
  }

  @Test func renderingInChunksMatchesRenderingAtOnce() throws {
    let file = try VGMFile(bytes: Self.vgm([0x56, 0, 100, 0x56, 7, 0x3E, 0x56, 8, 15,
                                            0x61, 0x10, 0x27, 0x56, 8, 0, 0x62, 0x66]))
    let whole = try VGMPlayer(file: file).render(maxFrames: .max)
    let chunked = try VGMPlayer(file: file)
    var pieces: [Float] = []
    while !chunked.isFinished { pieces += chunked.render(maxFrames: 333) }
    #expect(whole.count == file.samples * 2)
    #expect(whole.contains { $0 != 0 })
    #expect(pieces == whole)
  }

  /// What `VGMLogger` writes, `VGMFile` reads back: the same writes, the
  /// same length and the game name.
  @Test func readsWhatTheLoggerWrites() throws {
    let machine = Machine()
    machine.reset()
    machine.startVGMLogging()
    machine.totalTStates += UInt64(VGMLogger.cpuClockHz(eightMHz: true))  // one second
    machine.bus.currentTState = machine.totalTStates
    machine.bus.ioWrite(0x44, value: 0x08)
    machine.bus.ioWrite(0x45, value: 0x0F)
    machine.totalTStates += UInt64(VGMLogger.cpuClockHz(eightMHz: true)) / 2
    let bytes = try #require(machine.stopVGMLogging(gameName: "ザナドゥ"))

    let file = try VGMFile(bytes: bytes)
    #expect(file.clockHz == Int(VGMLogger.chipClock))
    #expect(file.samples == 44_100 + 22_050)
    #expect(file.loopStart == nil)
    #expect(file.tags.game == "ザナドゥ")
    #expect(file.tags.system == "NEC PC-8801")
    #expect(file.events.suffix(3) == [
      .wait(44_100), .write(secondary: false, register: 0x08, value: 0x0F), .wait(22_050),
    ])
    #expect(try VGMPlayer(file: file).render(maxFrames: .max).count == file.samples * 2)
  }

  @Test func cABIPlaysAFile() {
    let data = Self.vgm([0x56, 0, 100, 0x56, 7, 0x3E, 0x56, 8, 15, 0x61, 0x00, 0x01, 0x66])
    #expect(b88_vgm_player_open(nil, 0, 1) == nil)
    let player = b88_vgm_player_open(data, Int32(data.count), 1)
    #expect(player != nil)
    defer { b88_vgm_player_close(player) }
    #expect(b88_vgm_player_total_frames(player) == 256)
    let rhythm = [Int16](repeating: 1000, count: 64)
    #expect(b88_vgm_player_load_rhythm(player, 0, rhythm, 64, 44_100) == 1)
    #expect(b88_vgm_player_load_rhythm(player, 6, rhythm, 64, 44_100) == 0)
    var pcm = [Float](repeating: 0, count: 2 * 200)
    #expect(b88_vgm_player_render(player, &pcm, 200) == 200)
    #expect(b88_vgm_player_render(player, &pcm, 200) == 56)
    #expect(b88_vgm_player_render(player, &pcm, 200) == 0)
    #expect(b88_vgm_player_played_frames(player) == 256)
    #expect(b88_vgm_player_tag(player, 2, nil, 0) == 0)
    #expect(b88_vgm_player_tag(player, 11, nil, 0) == 0)
  }
}
