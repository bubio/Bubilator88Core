import Foundation
import Testing
@testable import Bubilator88Core
@testable import Peripherals

@Suite("CD-ROM Tests")
struct CDROMTests {

  // MARK: - Fixtures

  /// A raw sector whose user data (or, on an audio track, every left and
  /// right sample) is derived from its LBA.
  static func sector(lba: Int, audio: Bool) -> [UInt8] {
    var s = [UInt8](repeating: 0, count: CDDisc.sectorBytes)
    if audio {
      for at in stride(from: 0, to: CDDisc.sectorBytes, by: 4) {
        let left = UInt16(bitPattern: Int16(lba * 10))
        let right = UInt16(bitPattern: Int16(-lba * 10))
        s[at] = UInt8(left & 0xFF); s[at + 1] = UInt8(left >> 8)
        s[at + 2] = UInt8(right & 0xFF); s[at + 3] = UInt8(right >> 8)
      }
    } else {
      for i in 1...10 { s[i] = 0xFF }  // sync
      s[15] = 0x01  // mode 1
      for i in 16..<(16 + 2048) { s[i] = UInt8(truncatingIfNeeded: lba) }
    }
    return s
  }

  /// Track 1 data (LBA 0-9), track 2 audio (10-19), track 3 audio (20-29).
  static func disc() throws -> CDDisc {
    var bytes: [UInt8] = []
    for lba in 0..<30 { bytes += sector(lba: lba, audio: lba >= 10) }
    return try CDDisc(store: CDMemoryStore(bytes), tracks: [
      CDTrack(number: 1, start: 0, isAudio: false),
      CDTrack(number: 2, start: 10, isAudio: true),
      CDTrack(number: 3, start: 20, isAudio: true),
    ])
  }

  static func drive(disc: CDDisc?) -> CDROMDrive {
    let drive = CDROMDrive()
    drive.reset()
    drive.enabled = true
    if let disc { drive.mount(disc) }
    return drive
  }

  /// Plays the CD BIOS's side of the bus.
  struct Initiator {
    let drive: CDROMDrive

    func run(_ t: Int) { drive.tick(tStates: t) }

    /// Waits for REQ, or for the bus to go free.
    @discardableResult
    func waitREQ() -> UInt8 {
      for _ in 0..<200_000 {
        let lines = drive.ioRead(0x90)
        if lines & 0x40 != 0 || lines == 0 { return lines }
        run(16)
      }
      Issue.record("no REQ")
      return 0
    }

    struct Result {
      var data: [UInt8] = []
      var status: UInt8 = 0xFF
      var message: UInt8 = 0xFF
    }

    /// Selects the drive, sends `cdb`, then `dataOut` if asked for, and
    /// collects whatever comes back up to bus free. With `dma` the data-in
    /// bytes are left alone and only the status is waited for.
    func command(_ cdb: [UInt8], dataOut: [UInt8] = [], dma: Bool = false) -> Result {
      drive.ioWrite(0x91, value: 0x81)
      drive.ioWrite(0x90, value: 0x01)
      run(100)
      #expect(drive.ioRead(0x90) & 0x80 == 0, "BSY too soon after SEL")
      // As 0x10F4: SEL stays up until REQ.
      for _ in 0..<10_000 where drive.ioRead(0x90) & 0x40 == 0 { run(16) }
      drive.ioWrite(0x90, value: 0x00)
      var result = Result()
      var out = dataOut[...]
      var sent = 0
      for _ in 0..<1_000_000 {
        let lines = waitREQ()
        if lines == 0 { break }
        switch lines & 0x38 {
        case 0x10:
          drive.ioWrite(0x91, value: cdb[sent]); sent += 1
        case 0x00:
          drive.ioWrite(0x91, value: out.popFirst() ?? 0)
        case 0x08:
          if dma { run(16); continue }
          result.data.append(drive.ioRead(0x91))
        case 0x18:
          result.status = drive.ioRead(0x91)
        default:
          result.message = drive.ioRead(0x91)
        }
        run(16)
      }
      #expect(sent == cdb.count)
      return result
    }

    func sense() -> (key: UInt8, code: UInt8) {
      let r = command([0x03, 0, 0, 0, 0x0A, 0])
      return (r.data[2], r.data[9])
    }
  }

  // MARK: - Sheets

  @Test func cueSheetWithFilesPerTrackAndAPregap() throws {
    let sheet = try CueSheet("""
    FILE "Game (Track 1).bin" BINARY
      TRACK 01 MODE1/2352
        INDEX 01 00:00:00
    FILE "Game (Track 2).bin" BINARY
      TRACK 02 AUDIO
        PREGAP 00:02:00
        INDEX 01 00:00:00
      TRACK 03 AUDIO
        INDEX 00 00:00:40
        INDEX 01 00:01:00
    """)
    var track1: [UInt8] = []
    for lba in 0..<100 { track1 += Self.sector(lba: lba, audio: false) }
    let audio = [UInt8](repeating: 0x11, count: 200 * CDDisc.sectorBytes)
    let disc = try sheet.disc(stores: ["Game (Track 1).bin": CDMemoryStore(track1),
                                       "Game (Track 2).bin": CDMemoryStore(audio)])
    // Track 2 follows track 1's 100 sectors and two seconds of silence.
    #expect(disc.tracks.map(\.start) == [0, 250, 325])
    #expect(disc.tracks.map(\.isAudio) == [false, true, true])
    #expect(disc.leadOut == 450)
    var buffer = [UInt8](repeating: 0xEE, count: CDDisc.sectorBytes)
    #expect(disc.read(lba: 120, into: &buffer))
    #expect(buffer.allSatisfy { $0 == 0 })
    #expect(disc.read(lba: 250, into: &buffer))
    #expect(buffer[0] == 0x11)
    #expect(!disc.read(lba: 450, into: &buffer))
  }

  @Test func cueSheetRefusesCookedSectors() {
    #expect(throws: CDImageError.unsupportedTrackMode("MODE1/2048")) {
      _ = try CueSheet("FILE \"a.iso\" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n")
    }
  }

  @Test func cloneCDSheet() throws {
    let tracks = try CDDisc.parseCCD("""
    [CloneCD]
    Version=3
    [Entry 0]
    Point=0xa0
    Control=0x04
    PMin=1
    [Entry 1]
    Point=0x01
    Control=0x04
    PLBA=0
    [Entry 2]
    Point=0x02
    Control=0x00
    PMin=2
    PSec=0
    PFrame=0
    """)
    #expect(tracks == [CDTrack(number: 1, start: 0, isAudio: false),
                       CDTrack(number: 2, start: 2 * 60 * 75 - 150, isAudio: true)])
  }

  // MARK: - Bus and generic commands

  @Test func noDiscIsNotReady() {
    let bus = Initiator(drive: Self.drive(disc: nil))
    let r = bus.command([0, 0, 0, 0, 0, 0])
    #expect(r.status == 0x02)
    #expect(r.message == 0x00)
    // Key 2, code 0x0D: the BIOS's error 7, "no disc".
    #expect(bus.sense() == (0x02, 0x0D))
    #expect(bus.sense() == (0x00, 0x00))
  }

  @Test func testUnitReadyWithADisc() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    #expect(bus.command([0, 0, 0, 0, 0, 0]).status == 0x00)
  }

  @Test func unknownCommandIsIllegal() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    #expect(bus.command([0x1B, 0, 0, 0, 0, 0]).status == 0x02)
    #expect(bus.sense().key == 0x05)
  }

  @Test func readReturnsUserData() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    let r = bus.command([0x08, 0x00, 0x00, 0x05, 0x02, 0x00])
    #expect(r.status == 0x00)
    #expect(r.data.count == 4096)
    #expect(r.data.prefix(2048).allSatisfy { $0 == 5 })
    #expect(r.data.suffix(2048).allSatisfy { $0 == 6 })
  }

  @Test func modeSelectSwitchesTo2340ByteSectors() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    // As the BIOS sends it for a READ with mode bit 7 set.
    let list: [UInt8] = [0, 0, 0, 0, 0x03, 0, 0, 0, 0, 0, 0x0F]
    #expect(bus.command([0x15, 0, 0, 0, 0x0A, 0], dataOut: list).status == 0x00)
    let raw = bus.command([0x08, 0x00, 0x00, 0x05, 0x01, 0x00])
    #expect(raw.data.count == 2340)
    #expect(raw.data[3] == 0x01)  // header: mode byte
    #expect(raw.data[4] == 5)  // first user byte
    // Byte 4 back to 0 restores 2048.
    _ = bus.command([0x15, 0, 0, 0, 0x0A, 0], dataOut: [UInt8](repeating: 0, count: 11))
    #expect(bus.command([0x08, 0, 0, 5, 1, 0]).data.count == 2048)
  }

  /// Mirrors sends D9 and returns without reading the status; before its
  /// next command the drain (0x112D in the BIOS, copied into the game)
  /// writes 0xFF on each REQ until BSY drops.
  @Test func drainingAStatusLeftUnread() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    drive.ioWrite(0x91, value: 0x81)
    drive.ioWrite(0x90, value: 0x01)
    for _ in 0..<10_000 where drive.ioRead(0x90) & 0x40 == 0 { bus.run(16) }
    drive.ioWrite(0x90, value: 0x00)
    for byte: UInt8 in [0xD9, 1, 0x19, 0x19, 0, 0, 0, 0, 0, 0x40] {
      bus.waitREQ()
      drive.ioWrite(0x91, value: byte)
      bus.run(16)
    }
    bus.waitREQ()
    #expect(drive.ioRead(0x90) == 0xD8)  // BSY, REQ, status
    var writes = 0
    while drive.ioRead(0x90) & 0x80 != 0 && writes < 10 {
      if drive.ioRead(0x90) & 0x40 != 0 {
        drive.ioWrite(0x91, value: 0xFF)
        writes += 1
      }
      bus.run(16)
    }
    #expect(writes == 2)  // status, then message
    #expect(drive.ioRead(0x90) == 0x00)
    #expect(bus.command([0, 0, 0, 0, 0, 0]).status == 0x00)
  }

  @Test func readPastTheEndIsIllegal() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    #expect(bus.command([0x08, 0x00, 0x00, 29, 0x02, 0x00]).status == 0x02)
  }

  @Test func readThroughDMAChannel1() throws {
    let drive = Self.drive(disc: try Self.disc())
    let dma = DMAController()
    drive.dma = dma
    var memory = [UInt8](repeating: 0, count: 0x10000)
    drive.writeMemory = { memory[Int($0)] = $1 }
    // What the BIOS does before a READ (0x15A5).
    dma.ioWrite(0x62, value: 0x00); dma.ioWrite(0x62, value: 0x98)
    dma.ioWrite(0x63, value: 0x00); dma.ioWrite(0x63, value: 0x48)
    dma.ioWrite(0x68, value: 0xAE)
    drive.ioWrite(0x9F, value: 0x41)
    let r = Initiator(drive: drive).command([0x08, 0, 0, 7, 1, 0], dma: true)
    #expect(r.status == 0x00)
    #expect(r.data.isEmpty)
    #expect(memory[0x9800..<0xA000].allSatisfy { $0 == 7 })
    #expect(memory[0xA000] == 0)
    #expect(dma.channels[1].address == 0xA000)
  }

  // MARK: - Table of contents

  @Test func tableOfContents() throws {
    let bus = Initiator(drive: Self.drive(disc: try Self.disc()))
    #expect(bus.command([0xDE, 0, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0x01, 0x03, 0, 0])
    // Track 2 at LBA 10 is absolute 00:02:10; an audio track has 0.
    #expect(bus.command([0xDE, 2, 0x02, 0, 0, 0, 0, 0, 0, 0]).data == [0x00, 0x02, 0x10, 0x00])
    #expect(bus.command([0xDE, 2, 0x01, 0, 0, 0, 0, 0, 0, 0]).data == [0x00, 0x02, 0x00, 0x04])
    // Lead-out at LBA 30.
    #expect(bus.command([0xDE, 1, 0, 0, 0, 0, 0, 0, 0, 0]).data == [0x00, 0x02, 0x30, 0x00])
    #expect(bus.command([0xDE, 2, 0x09, 0, 0, 0, 0, 0, 0, 0]).status == 0x02)
  }

  // MARK: - Audio

  static func samples(_ drive: CDROMDrive, _ count: Int) -> [(Int16, Int16)] {
    // One sample's worth of CPU time, then take it.
    (0..<count).map { _ in
      drive.tick(tStates: Int(drive.cpuClockHz / 44_100) + 1)
      return drive.nextSample()
    }
  }

  @Test func searchByTrackThenPlayToTheNextTrack() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    // The CD player's sequence: D8 by track, D9 to the next track (0x3480).
    #expect(bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80]).status == 0x00)
    #expect(drive.audioState == .paused)
    #expect(bus.command([0xD9, 3, 0x03, 0, 0, 0, 0, 0, 0, 0x80]).status == 0x00)
    #expect(drive.audioState == .playing)
    let first = Self.samples(drive, 1)
    #expect(first[0] == (100, -100))

    let q = bus.command([0xDD, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0]).data
    #expect(q.count == 10)
    #expect(q[0] == 0x00)
    #expect(q[1] == 0x01)
    #expect(q[2] == 0x02)
    #expect(Array(q[7...8]) == [0x00, 0x02])

    // Ten sectors later the track has ended.
    _ = Self.samples(drive, 588 * 10 + 10)
    #expect(drive.audioState == .stopped)
    #expect(bus.command([0xDD, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0]).data[0] == 0x03)
  }

  @Test func searchByTimeAndPlayToTheEndOfTheDisc() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    // 00:02:25 is LBA 25; track 0 as an end is the end of the disc.
    _ = bus.command([0xD8, 0, 0x00, 0x02, 0x25, 0, 0, 0, 0, 0x40])
    _ = bus.command([0xD9, 3, 0x00, 0, 0, 0, 0, 0, 0, 0x80])
    #expect(Self.samples(drive, 1)[0] == (250, -250))
    _ = Self.samples(drive, 588 * 5)
    #expect(drive.audioState == .stopped)
  }

  @Test func modeOneRepeatsFromTheSearchedPosition() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    // Mirrors' sequence: D8 by time, D9 mode 1 to a time.
    _ = bus.command([0xD8, 0, 0x00, 0x02, 0x22, 0, 0, 0, 0, 0x40])
    _ = bus.command([0xD9, 1, 0x00, 0x02, 0x24, 0, 0, 0, 0, 0x40])
    #expect(Self.samples(drive, 1)[0] == (220, -220))
    _ = Self.samples(drive, 588 * 2 - 1)
    #expect(drive.audioState == .playing)
    #expect(Self.samples(drive, 1)[0] == (220, -220))
    #expect(drive.audioLBA == 22)
  }

  @Test func modeZeroStops() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 0, 0x03, 0, 0, 0, 0, 0, 0, 0x80])
    #expect(drive.audioState == .stopped)
  }

  @Test func pauseKeepsThePosition() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x03, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 3, 0x00, 0, 0, 0, 0, 0, 0, 0x80])
    _ = Self.samples(drive, 588 * 2)
    _ = bus.command([0xDA, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(drive.audioState == .paused)
    #expect(drive.audioLBA >= 22)
    let q = bus.command([0xDD, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0]).data
    #expect(q[0] == 0x02)
    #expect(q[2] == 0x03)
  }

  @Test func faderMutesAndFades() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 3, 0x03, 0, 0, 0, 0, 0, 0, 0x80])
    #expect(Self.samples(drive, 1)[0] == (100, -100))
    // 2: silent at once (Mirrors at start-up); 0: full at once.
    drive.ioWrite(0x98, value: 0x02)
    #expect(Self.samples(drive, 1)[0] == (0, 0))
    drive.ioWrite(0x98, value: 0x00)
    #expect(Self.samples(drive, 1)[0] == (100, -100))
    // 7: fades out (Mirrors stops the track 2.5 seconds later).
    drive.ioWrite(0x98, value: 0x07)
    drive.tick(tStates: Int(drive.cpuClockHz * CDROMDrive.slowFadeSeconds / 2))
    #expect(abs(drive.fadeLevel - CDROMDrive.fadeFull / 2) < CDROMDrive.fadeFull / 100)
    drive.tick(tStates: Int(drive.cpuClockHz * CDROMDrive.slowFadeSeconds))
    #expect(drive.fadeLevel == 0)
    // 0 then 5, the CD player's start of a track: 5 fades in from silence.
    drive.ioWrite(0x98, value: 0x00)
    drive.ioWrite(0x98, value: 0x05)
    #expect(drive.fadeLevel == 0)
    drive.tick(tStates: Int(drive.cpuClockHz * CDROMDrive.slowFadeSeconds) + 1)
    #expect(drive.fadeLevel == CDROMDrive.fadeFull)
    // 6: a fast fade out, before the player stops.
    drive.ioWrite(0x98, value: 0x06)
    drive.tick(tStates: Int(drive.cpuClockHz * CDROMDrive.fastFadeSeconds) + 1)
    #expect(drive.fadeLevel == 0)
  }

  @Test func lbaPositions() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    // Byte 9 = 0x00: LBA in bytes 2-4 for D8, 3-5 for D9.
    _ = bus.command([0xD8, 0, 0, 0, 12, 0, 0, 0, 0, 0x00])
    _ = bus.command([0xD9, 3, 0, 0, 0, 13, 0, 0, 0, 0x00])
    #expect(Self.samples(drive, 1)[0] == (120, -120))
    _ = Self.samples(drive, 588)
    #expect(drive.audioState == .stopped)
  }

  @Test func dataReadEndsAudio() throws {
    let drive = Self.drive(disc: try Self.disc())
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 3, 0x00, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0x08, 0, 0, 1, 1, 0])
    #expect(drive.audioState == .stopped)
  }

  @Test func saveStateKeepsThePlayPosition() throws {
    let disc = try Self.disc()
    let drive = Self.drive(disc: disc)
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 3, 0x00, 0, 0, 0, 0, 0, 0, 0x80])
    _ = Self.samples(drive, 588 * 3 + 7)
    let state = drive.serializeState()

    let restored = Self.drive(disc: disc)
    #expect(restored.deserializeState(state))
    #expect(restored.audioState == .playing)
    #expect(restored.audioLBA == drive.audioLBA)
    #expect(Self.samples(restored, 1)[0] == (130, -130))
    #expect(!restored.deserializeState([2]))
  }

  // MARK: - Machine

  static func machine(drive: Bool) -> Machine {
    let m = Machine()
    var bios = [UInt8](repeating: 0x11, count: 0x10000)
    for i in 0x8000..<0x10000 { bios[i] = 0x22 }
    m.loadN88BasicROM([UInt8](repeating: 0x33, count: 0x8000))
    m.loadNBasicROM([UInt8](repeating: 0x44, count: 0x8000))
    m.loadCDBios(bios)
    m.cdDriveInstalled = drive
    m.reset()
    return m
  }

  @Test func cdBiosIsThereAtResetAndPort99SwitchesIt() {
    let m = Self.machine(drive: true)
    #expect(m.cdrom.enabled)
    #expect(m.bus.memRead(0x0000) == 0x11)
    #expect(m.bus.memRead(0x7FFF) == 0x11)
    m.bus.romModeN88 = false
    #expect(m.bus.memRead(0x0000) == 0x22)
    m.bus.romModeN88 = true
    m.bus.ioWrite(0x99, value: 0x00)
    #expect(m.bus.memRead(0x0000) == 0x33)
    m.bus.ioWrite(0x99, value: 0x10)
    #expect(m.bus.memRead(0x0000) == 0x11)
    m.bus.ioWrite(0x99, value: 0x11)
    #expect(m.bus.memRead(0x0000) == 0x33)
    // RAM mode still wins.
    m.bus.ioWrite(0x99, value: 0x10)
    m.bus.ramMode = true
    #expect(m.bus.memRead(0x0000) != 0x11)
  }

  @Test func withoutTheDriveNothingChanges() {
    let m = Self.machine(drive: false)
    #expect(!m.cdrom.enabled)
    #expect(m.bus.memRead(0x0000) == 0x33)
    m.bus.ioWrite(0x99, value: 0x10)
    #expect(m.bus.memRead(0x0000) == 0x33)
    #expect(m.bus.ioRead(0x90) == 0xFF)
    #expect(m.bus.ioRead(0x98) == 0xFF)
  }

  @Test func unloadingTheBiosTakesTheDriveOutAtReset() {
    let m = Self.machine(drive: true)
    m.unloadCDBios()
    #expect(m.cdrom.enabled)
    m.reset()
    #expect(!m.cdrom.enabled)
    #expect(m.bus.memRead(0x0000) == 0x33)
  }

  @Test func driveDetectionClockToggles() {
    let m = Self.machine(drive: true)
    var seen = Set<UInt8>()
    // The BIOS gives up after ten reads (0x1255); a read is ~50 T-states.
    for _ in 0..<10 {
      seen.insert(m.bus.ioRead(0x98) & 0x80)
      m.cdrom.tick(tStates: 50)
    }
    #expect(seen.count == 2)
  }

  @Test func cdBootStaysOnDiskBoot() {
    let m = Self.machine(drive: false)
    m.applyBootStrap(base: 0x71)
    #expect(m.bus.dipSw2 & 0x08 != 0)
    m.cdDriveInstalled = true
    m.applyBootStrap(base: 0x71)
    #expect(m.bus.dipSw2 & 0x08 == 0)
  }

  @Test func reattachKeepsThePlayPosition() throws {
    let disc = try Self.disc()
    let drive = Self.drive(disc: disc)
    let bus = Initiator(drive: drive)
    _ = bus.command([0xD8, 0, 0x02, 0, 0, 0, 0, 0, 0, 0x80])
    _ = bus.command([0xD9, 3, 0x00, 0, 0, 0, 0, 0, 0, 0x80])
    _ = Self.samples(drive, 588 * 2)
    let restored = Self.drive(disc: nil)
    #expect(restored.deserializeState(drive.serializeState()))
    restored.attach(disc)
    #expect(restored.audioState == .playing)
    #expect(restored.audioLBA == drive.audioLBA)
  }

  @Test func saveStateCarriesTheMapping() throws {
    let m = Self.machine(drive: true)
    m.bus.ioWrite(0x99, value: 0x00)
    let state = m.createSaveState()
    let n = Self.machine(drive: true)
    try n.loadSaveState(state)
    #expect(!n.bus.cdBiosMapped)
    #expect(n.cdrom.enabled)

    let plain = Self.machine(drive: false)
    try n.loadSaveState(plain.createSaveState())
    #expect(!n.cdrom.enabled)
  }
}
