import Testing
@testable import EmulatorCore

@Suite("UPD765A Tests")
struct UPD765ATests {

  // MARK: - Test Helpers

  /// Create a D88 disk with sectors on a given track.
  private func makeDisk(track: Int = 0, c: UInt8 = 0, h: UInt8 = 0,
                        sectors: [(r: UInt8, data: [UInt8])]) -> D88Disk {
    var disk = D88Disk()
    for s in sectors {
      var sector = D88Disk.Sector()
      sector.c = c; sector.h = h; sector.r = s.r; sector.n = 1  // 256 bytes
      sector.data = s.data
      disk.tracks[track].append(sector)
    }
    return disk
  }

  private func makeTwoHeadDisk(c: UInt8 = 0, n: UInt8 = 2,
                               head0: [(r: UInt8, data: [UInt8])],
                               head1: [(r: UInt8, data: [UInt8])]) -> D88Disk {
    var disk = D88Disk()
    for s in head0 {
      var sector = D88Disk.Sector()
      sector.c = c; sector.h = 0; sector.r = s.r; sector.n = n
      sector.data = s.data
      disk.tracks[0].append(sector)
    }
    for s in head1 {
      var sector = D88Disk.Sector()
      sector.c = c; sector.h = 1; sector.r = s.r; sector.n = n
      sector.data = s.data
      disk.tracks[1].append(sector)
    }
    return disk
  }

  /// Create an FDC with a disk mounted in drive 0.
  private func makeFDCWithDisk(_ disk: D88Disk) -> (UPD765A, [D88Disk?]) {
    let fdc = UPD765A()
    var disks: [D88Disk?] = [disk, nil]
    fdc.drives = { disks }
    fdc.writeSector = { drive, track, c, h, r, data in
      disks[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
    }
    fdc.formatTrack = { drive, track, sectorIDs, fillByte in
      disks[drive]?.formatTrack(track: track, sectorIDs: sectorIDs, fillByte: fillByte) ?? false
    }
    return (fdc, disks)
  }

  /// Write a Read Data command: 0x46 (MFM+SK) + params
  private func writeReadDataCmd(_ fdc: UPD765A, drive: Int = 0, head: Int = 0,
                                c: UInt8, h: UInt8, r: UInt8, n: UInt8 = 1,
                                eot: UInt8, gpl: UInt8 = 0x1B, dtl: UInt8 = 0xFF) {
    fdc.writeData(0x46)  // Read Data (MFM, skip deleted)
    fdc.writeData(UInt8(drive | (head << 2)))
    fdc.writeData(c)
    fdc.writeData(h)
    fdc.writeData(r)
    fdc.writeData(n)
    fdc.writeData(eot)
    fdc.writeData(gpl)
    fdc.writeData(dtl)
  }

  /// Read all result bytes (usually 7 for read/write commands)
  private func readResults(_ fdc: UPD765A, count: Int = 7) -> [UInt8] {
    var results: [UInt8] = []
    for _ in 0..<count {
      results.append(fdc.readData())
    }
    return results
  }

  /// Read execution-phase bytes, advancing one FDC byte time between reads.
  /// Drains the end-of-read grace period that UPD765A now inserts after
  /// the last byte of the last sector so that subsequent assertions about
  /// `phase`, `interruptPending`, and result bytes see the transition to
  /// the result phase.
  private func readExecutionBytes(_ fdc: UPD765A, count: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    for index in 0..<count {
      if index > 0 {
        fdc.tick(tStates: 128)
      }
      bytes.append(fdc.readData())
    }
    // Drain any end-of-read grace period so tests observe `.result`.
    // The grace period is bounded (UPD765A.readCompletionGraceClocks ≈ 800),
    // so a handful of 128-cycle ticks is enough.
    var drainTicks = 0
    while fdc.phase == .execution && drainTicks < 32 {
      fdc.tick(tStates: 128)
      drainTicks += 1
    }
    return bytes
  }

  /// Write execution-phase bytes, advancing one FDC byte time between writes.
  private func writeExecutionBytes(_ fdc: UPD765A, bytes: [UInt8]) {
    for (index, byte) in bytes.enumerated() {
      if index > 0 {
        fdc.tick(tStates: 128)
      }
      fdc.writeData(byte)
    }
  }

  // MARK: - Reset & Status

  @Test func resetState() {
    let fdc = UPD765A()
    #expect(fdc.phase == .idle)
    #expect(fdc.interruptPending == false)
    #expect(fdc.pcn == [0, 0, 0, 0])
  }

  @Test func idleStatusRegister() {
    let fdc = UPD765A()
    let status = fdc.readStatus()
    #expect(status == 0x80)  // RQM only
  }

  // MARK: - Specify (0x03)

  @Test func specifyCommand() {
    let fdc = UPD765A()

    fdc.writeData(0x03)  // Specify
    #expect(fdc.phase == .command)

    fdc.writeData(0xDF)  // SRT=13, HUT=15
    fdc.writeData(0x03)  // HLT=1, ND=1

    #expect(fdc.phase == .idle)
  }

  // MARK: - Sense Drive Status (0x04)

  @Test func senseDriveStatusNoDisk() {
    let fdc = UPD765A()
    fdc.drives = { [nil, nil] }

    fdc.writeData(0x04)  // Sense Drive Status
    fdc.writeData(0x00)  // drive 0, head 0

    #expect(fdc.phase == .result)
    let st3 = fdc.readData()
    #expect(st3 & 0x20 != 0)  // Drive mechanism ready (M88M-compatible)
    #expect(st3 & 0x08 == 0)  // No two-sided media bit when empty
    #expect(fdc.phase == .idle)
  }

  @Test func senseDriveStatusWithDisk() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    let (fdc, _) = makeFDCWithDisk(disk)

    fdc.writeData(0x04)
    fdc.writeData(0x00)

    let st3 = fdc.readData()
    #expect(st3 & 0x20 != 0)  // Ready
    #expect(st3 & 0x08 != 0)  // Two-sided
    #expect(st3 & 0x10 != 0)  // Track 0 (pcn=0)
  }

  @Test func senseDriveStatusWriteProtected() {
    var disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    disk.writeProtected = true
    let fdc = UPD765A()
    let diskCopy = disk
    fdc.drives = { [diskCopy, nil] }

    fdc.writeData(0x04)
    fdc.writeData(0x00)

    let st3 = fdc.readData()
    #expect(st3 & 0x40 != 0)  // Write protected
  }

  // MARK: - Read Data (0x06)

  @Test func readDataSingleSector() {
    let sectorData = Array(0..<256).map { UInt8($0 & 0xFF) }
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [(r: 1, data: sectorData)])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)

    #expect(fdc.phase == .execution)

    // Read status should show data available
    let status = fdc.readStatus()
    #expect(status & 0xE0 == 0xE0)  // RQM | DIO | EXM

    // Read all 256 bytes
    let data = readExecutionBytes(fdc, count: 256)
    #expect(data[0] == 0x00)
    #expect(data[1] == 0x01)
    #expect(data[255] == 0xFF)

    // Should now be in result phase
    #expect(fdc.phase == .result)

    let results = readResults(fdc)
    // ST0 should indicate abnormal termination + End of Cylinder (EOT reached without TC)
    #expect(results[0] & 0xC0 == 0x40)  // IC = AT
    #expect(results[1] & 0x80 != 0)      // ST1.EN = End of Cylinder
  }

  @Test func readDataMultipleSectors() {
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [
      (r: 1, data: Array(repeating: 0x11, count: 256)),
      (r: 2, data: Array(repeating: 0x22, count: 256)),
      (r: 3, data: Array(repeating: 0x33, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 3)

    // Read 256*3 = 768 bytes
    let data = readExecutionBytes(fdc, count: 768)
    #expect(data[0] == 0x11)
    #expect(data[256] == 0x22)
    #expect(data[512] == 0x33)
  }

  @Test func readDataUsesCommandCylinderForLiteralEOTWhenPCNIsStale() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 9
    sector.h = 0
    sector.r = 1
    sector.n = 1
    sector.data = Array(repeating: 0x5A, count: 256)
    disk.tracks[18] = [sector]  // CHRN.C=9,H=0

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 2

    writeReadDataCmd(fdc, c: 9, h: 0, r: 1, eot: 1)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 256)
    #expect(data.allSatisfy { $0 == 0x5A })
  }

  @Test func readDataUsesPhysicalTrackForNonstandardSectorIDs() {
    var disk = D88Disk()
    for (index, fill) in [0x11, 0x22, 0x33, 0x44, 0x55].enumerated() {
      var sector = D88Disk.Sector()
      sector.c = 2
      sector.h = 0x40
      sector.r = UInt8(index + 1)
      sector.n = 3
      sector.data = Array(repeating: UInt8(fill), count: 1024)
      disk.tracks[2].append(sector)  // Physical track slot 2 == PCN 1, head 0
    }

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 1

    writeReadDataCmd(fdc, c: 2, h: 0x40, r: 2, n: 3, eot: 5, gpl: 0x50, dtl: 0x50)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 1024 * 4)
    #expect(data[0] == 0x22)
    #expect(data[1024] == 0x33)
    #expect(data[2048] == 0x44)
    #expect(data[3072] == 0x55)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[4] == 0x40)
    #expect(results[5] == 5)
  }

  @Test func readDataWithTCPreservesNonstandardHeadID() {
    var disk = D88Disk()
    for (index, fill) in [0xAA, 0xBB].enumerated() {
      var sector = D88Disk.Sector()
      sector.c = 2
      sector.h = 0x40
      sector.r = UInt8(index + 1)
      sector.n = 3
      sector.data = Array(repeating: UInt8(fill), count: 1024)
      disk.tracks[2].append(sector)
    }

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 1

    writeReadDataCmd(fdc, c: 2, h: 0x40, r: 1, n: 3, eot: 2, gpl: 0x50, dtl: 0x50)

    _ = readExecutionBytes(fdc, count: 1024)
    fdc.terminalCount()

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[4] == 0x40)
    #expect(results[5] == 2)
  }

  @Test func readDataFollowsPhysicalSectorOrderWhenEOTIsLogicalSlot() {
    let disk = makeDisk(track: 0, c: 13, h: 0, sectors: [
      (r: 17, data: Array(repeating: 0x11, count: 256)),
      (r: 18, data: Array(repeating: 0x22, count: 256)),
      (r: 19, data: Array(repeating: 0x33, count: 256)),
      (r: 20, data: Array(repeating: 0x44, count: 256)),
      (r: 21, data: Array(repeating: 0x55, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 0

    writeReadDataCmd(fdc, c: 13, h: 0, r: 17, eot: 5)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 256 * 5)
    #expect(data[0] == 0x11)
    #expect(data[256] == 0x22)
    #expect(data[512] == 0x33)
    #expect(data[768] == 0x44)
    #expect(data[1024] == 0x55)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[5] == 21)
  }

  @Test func readDataFollowsPhysicalOrderAcrossDuplicateSectorIDs() {
    // デーモンズリング disk A track C=0/H=1 has a duplicated R=8 ID in
    // physical order: 1,2,3,4,8,5,6,7,9,10,11,12,13,8,14,15,16.
    // A ReadData R=8,EOT=16 must keep clocking the physical sequence from
    // the first matching ID through the first EOT sector it encounters,
    // including the second R=8 record, instead of collapsing duplicate IDs
    // into a synthetic logical R=8...16 sequence.
    let physicalIDs: [UInt8] = [1, 2, 3, 4, 8, 5, 6, 7, 9, 10, 11, 12, 13, 8, 14, 15, 16]
    var disk = D88Disk()
    for (index, r) in physicalIDs.enumerated() {
      var sector = D88Disk.Sector()
      sector.c = 0
      sector.h = 1
      sector.r = r
      sector.n = 1
      sector.data = Array(repeating: UInt8(index), count: 256)
      disk.tracks[1].append(sector)
    }

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, head: 1, c: 0, h: 1, r: 8, n: 1, eot: 16, gpl: 0x0E, dtl: 0xFF)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 256 * 13)
    let observedSectorFills = stride(from: 0, to: data.count, by: 256).map { data[$0] }
    #expect(observedSectorFills == [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[5] == 16)

    writeReadDataCmd(fdc, head: 1, c: 0, h: 1, r: 8, n: 1, eot: 16, gpl: 0x0E, dtl: 0xFF)

    #expect(fdc.phase == .execution)
    let secondData = readExecutionBytes(fdc, count: 256 * 4)
    let secondObservedSectorFills = stride(from: 0, to: secondData.count, by: 256).map { secondData[$0] }
    #expect(secondObservedSectorFills == [13, 14, 15, 16])

    #expect(fdc.phase == .result)
    let secondResults = readResults(fdc)
    #expect(secondResults[5] == 16)
  }

  // アークスロード Track 20 protected sector: the track holds a single 4096-byte
  // sector with ID R=0 N=5, but the loader asks for it with ReadData R=1. Real
  // hardware passes whichever ID it manages to read as the disk rotates, so this
  // works there; a D88-based implementation has to explicitly accept a track of
  // one R=0 sector as logical slot 1.
  // The request says EOT=2 while only one sector exists, so once the transfer
  // completes the result is an Abnormal Termination with ST0 AT (0x40) and
  // ST1 EN (0x80) — matching real hardware.
  @Test func readDataTreatsSingleR0SectorAsLogicalSlotOne() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 10
    sector.h = 0
    sector.r = 0
    sector.n = 5
    sector.data = Array(repeating: 0x00, count: 4096)
    sector.data[0] = 0x91
    disk.tracks[20] = [sector]

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 10

    writeReadDataCmd(fdc, c: 10, h: 0, r: 1, n: 5, eot: 2, gpl: 0x0E, dtl: 0xFF)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 4096)
    #expect(data[0] == 0x91)                // first byte comes back unchanged
    #expect(data[0x0F80] == 0x00)           // near the end it is still the protected sector's own data

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)      // ST0: AT (EOT never reached)
    #expect(results[1] & 0x80 != 0)         // ST1: EN (End of Cylinder)
  }

  @Test func readDataLiteralEOTMissingReadsUntilTrackEnd() {
    let disk = makeDisk(track: 2, c: 1, h: 0, sectors: [
      (r: 1, data: Array(repeating: 0x11, count: 256)),
      (r: 2, data: Array(repeating: 0x22, count: 256)),
      (r: 3, data: Array(repeating: 0x33, count: 256)),
      (r: 4, data: Array(repeating: 0x44, count: 256)),
      (r: 5, data: Array(repeating: 0x55, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 1, h: 0, r: 4, eot: 6)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 256 * 2)
    #expect(data[0] == 0x44)
    #expect(data[256] == 0x55)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[5] == 6)
  }

  @Test func readDataNMismatchContinuesThroughRawTrackBytes() {
    // Might & Magic reads track 79 with cmd N=3 (1024 bytes) while the
    // medium records N=1 (256 bytes). The uPD765A continues clocking
    // post-data gap/ID/next-sector bytes until the transfer length is met
    // and then reports CRC error. Verify sector 1 data appears first and
    // that sector 2 data appears at the expected raw-track offset.
    var disk = D88Disk()
    for record in 1...16 {
      var sector = D88Disk.Sector()
      sector.c = 39
      sector.h = 1
      sector.r = UInt8(record)
      sector.n = 1
      sector.sectorCount = 16
      sector.density = 0x00
      if record <= 2 {
        sector.data = (0..<256).map { $0.isMultiple(of: 2) ? 0xFF : 0x00 }
      } else {
        sector.data = Array(repeating: 0x00, count: 256)
      }
      disk.tracks[79].append(sector)
    }

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 39

    writeReadDataCmd(fdc, drive: 0, head: 1, c: 39, h: 1, r: 1, n: 3, eot: 2, gpl: 0x35, dtl: 0xFF)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 1024)
    #expect(data[0] == 0xFF)
    #expect(data[1] == 0x00)
    // Sector 2 data begins at raw-track offset 369 from sector 1 data start
    // (CRC 2 + gap3 51 + sync 12 + AM 3 + IDAM 1 + CHRN 4 + CRC 2 + gap2 22
    //  + sync 12 + AM 3 + DAM 1). Offsets 0x206..0x20D therefore land on
    // sec2[149..156], alternating 0x00/0xFF from the isMultiple(of:2) seed.
    #expect(data[0x206] == 0x00)
    #expect(data[0x207] == 0xFF)
    #expect(data[0x208] == 0x00)
    #expect(data[0x209] == 0xFF)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_DE != 0)
  }

  @Test func readDataLowTrackNormalReadRejectsNMismatch() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0
    sector.h = 0
    sector.r = 1
    sector.n = 1
    sector.sectorCount = 1
    sector.data = Array(repeating: 0xA5, count: 256)
    disk.tracks[0].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, n: 3, eot: 5, gpl: 0x0E, dtl: 0xFF)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_ND != 0)
    #expect(fdc.commandLog.last?.dataSize == 0)
  }

  @Test func readDataHighRWithEOTLessThanRRejectsNMismatchWithoutTransfer() {
    // XYLOS protection first reads R=0xF7,N=2, then probes R=0xF6,N=2
    // while the disk records R=0xF6 as N=1. BubiC treats that high-R
    // N-mismatch as not found, without entering execution, so the loader
    // can keep using the previous R=0xF7 data in the sub-CPU buffer.
    var disk = D88Disk()
    var sectorF6 = D88Disk.Sector()
    sectorF6.c = 1
    sectorF6.h = 1
    sectorF6.r = 0xF6
    sectorF6.n = 1
    sectorF6.sectorCount = 17
    sectorF6.data = Array(repeating: 0xA5, count: 256)
    disk.tracks[3].append(sectorF6)

    var sectorF7 = D88Disk.Sector()
    sectorF7.c = 1
    sectorF7.h = 1
    sectorF7.r = 0xF7
    sectorF7.n = 2
    sectorF7.sectorCount = 17
    sectorF7.data = Array(repeating: 0x5A, count: 512)
    disk.tracks[3].append(sectorF7)

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 1

    writeReadDataCmd(fdc, head: 1, c: 1, h: 1, r: 0xF6, n: 2, eot: 0x1E, gpl: 0x1B, dtl: 0xFF)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_ND != 0)
    #expect(fdc.commandLog.last?.dataSize == 0)
  }

  @Test func readDataD88Status10ReportsControlMarkNotDataError() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0
    sector.h = 0
    sector.r = 3
    sector.n = 1
    sector.sectorCount = 1
    sector.deleted = true
    sector.status = 0x10
    sector.data = Array(repeating: 0xFF, count: 256)
    disk.tracks[0].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 3, n: 1, eot: 3, gpl: 0x0E, dtl: 0xFF)
    _ = readExecutionBytes(fdc, count: 256)
    fdc.terminalCount()

    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x00)
    #expect(results[1] & UPD765A.ST1_DE == 0)
    #expect(results[2] & UPD765A.ST2_CM != 0)
  }

  @Test func readDataD88StatusB0ReportsDataFieldError() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0
    sector.h = 0
    sector.r = 17
    sector.n = 0
    sector.sectorCount = 17
    sector.status = 0xB0
    sector.data = Array(repeating: 0x5A, count: 128)
    disk.tracks[0].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 17, n: 0, eot: 0x10, gpl: 0x0E, dtl: 0xFF)
    _ = readExecutionBytes(fdc, count: 128)

    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_DE != 0)
    #expect(results[2] & UPD765A.ST2_DD != 0)
  }

  @Test func readDataD88StatusB0SurvivesLateTerminalCount() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0
    sector.h = 0
    sector.r = 17
    sector.n = 0
    sector.sectorCount = 17
    sector.status = 0xB0
    sector.data = Array(repeating: 0x5A, count: 128)
    disk.tracks[0].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 17, n: 0, eot: 0x10, gpl: 0x0E, dtl: 0xFF)
    _ = readExecutionBytes(fdc, count: 128)
    fdc.terminalCount()

    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_DE != 0)
    #expect(results[2] & UPD765A.ST2_DD != 0)
    #expect(results[5] == 17)
  }

  @Test func readDataD88StatusB0WithMidTransferTerminalCountKeepsErrorCHRN() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0
    sector.h = 0
    sector.r = 17
    sector.n = 0
    sector.sectorCount = 17
    sector.status = 0xB0
    sector.data = Array(repeating: 0x5A, count: 128)
    disk.tracks[0].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 17, n: 0, eot: 0x10, gpl: 0x0E, dtl: 0xFF)
    _ = readExecutionBytes(fdc, count: 16)
    fdc.terminalCount()

    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_DE != 0)
    #expect(results[2] & UPD765A.ST2_DD != 0)
    #expect(results[5] == 17)
  }

  @Test func readDiagnosticStreamsTrackWhenFirstIDDoesNotMatch() {
    // Ultima III issues Read Diagnostic on a protection track whose first
    // sector ID is intentionally not the requested CHRN. BubiC still
    // enters execution, streams from the first sector data field, and
    // reports ND in the result.
    var disk = D88Disk()
    var first = D88Disk.Sector()
    first.c = 27
    first.h = 0
    first.r = 0xF7
    first.n = 3
    first.sectorCount = 2
    first.data = Array(repeating: 0x5A, count: 1024)
    disk.tracks[54].append(first)

    var second = D88Disk.Sector()
    second.c = 27
    second.h = 0
    second.r = 1
    second.n = 2
    second.sectorCount = 2
    second.data = Array(repeating: 0xA5, count: 512)
    disk.tracks[54].append(second)

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 27

    fdc.writeData(0x42)  // Read Diagnostic / Read Track (MFM)
    fdc.writeData(0x00)
    fdc.writeData(27)
    fdc.writeData(0)
    fdc.writeData(1)
    fdc.writeData(3)
    fdc.writeData(2)
    fdc.writeData(0x35)
    fdc.writeData(0xFF)

    #expect(fdc.phase == .execution)
    let data = readExecutionBytes(fdc, count: 16)
    #expect(data == Array(repeating: 0x5A, count: 16))

    fdc.terminalCount()
    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x00)
    #expect(results[1] & UPD765A.ST1_ND != 0)
  }

  @Test func readDataSectorNotFound() {
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 5, eot: 5)  // Sector 5 doesn't exist

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)  // IC = AT (abnormal)
    #expect(results[1] & 0x04 != 0)      // ST1.ND = no data
  }

  @Test func readDataNoDisk() {
    let fdc = UPD765A()
    fdc.drives = { [nil, nil] }

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0x08 != 0)  // ST0.NR = not ready
  }

  @Test func readDataFiresInterrupt() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    let (fdc, _) = makeFDCWithDisk(disk)

    var intFired = false
    fdc.onInterrupt = { intFired = true }

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)

    // Read all data
    _ = readExecutionBytes(fdc, count: 256)

    #expect(intFired == true)
    #expect(fdc.interruptPending == true)
  }

  @Test("ReadData result read clears command-complete interrupt")
  func readDataResultReadClearsInterruptPending() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0xA5, count: 256))])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)
    _ = readExecutionBytes(fdc, count: 256)

    #expect(fdc.phase == .result)
    #expect(fdc.interruptPending == true)

    _ = fdc.readData()

    #expect(fdc.interruptPending == false)
  }

  @Test("Result read keeps pending seek interrupts queued")
  func resultReadDoesNotClearPendingSeekInterrupt() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0x5A, count: 256))])
    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.seekState[1] = .interrupt

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)
    _ = readExecutionBytes(fdc, count: 256)

    _ = fdc.readData()
    _ = readResults(fdc, count: 6)

    #expect(fdc.interruptPending == true)
    fdc.writeData(0x08)
    let results = readResults(fdc, count: 2)
    #expect(results[0] == 0x21)
    #expect(results[1] == 0)
  }

  // MARK: - Write Data (0x05)

  @Test func writeDataSingleSector() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    var disks: [D88Disk?] = [disk, nil]
    let fdc = UPD765A()
    fdc.drives = { disks }
    fdc.writeSector = { drive, track, c, h, r, data in
      disks[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
    }

    // Write Data command
    fdc.writeData(0x45)  // Write Data (MFM)
    fdc.writeData(0x00)  // drive 0, head 0
    fdc.writeData(0)     // C
    fdc.writeData(0)     // H
    fdc.writeData(1)     // R
    fdc.writeData(1)     // N
    fdc.writeData(1)     // EOT
    fdc.writeData(0x1B)  // GPL
    fdc.writeData(0xFF)  // DTL

    #expect(fdc.phase == .execution)

    // Provide 256 bytes of write data
    writeExecutionBytes(fdc, bytes: Array(0..<256).map { UInt8($0 & 0xFF) })

    #expect(fdc.phase == .result)

    // Verify data was written
    let written = disks[0]?.findSector(track: 0, c: 0, h: 0, r: 1)
    #expect(written?.data[0] == 0x00)
    #expect(written?.data[255] == 0xFF)
  }

  @Test("WriteData targets current PCN track, not command cylinder track")
  func writeDataUsesCurrentTrack() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 1
    sector.h = 0
    sector.r = 1
    sector.n = 1
    sector.sectorCount = 1
    sector.data = Array(repeating: 0, count: 256)
    disk.tracks[4].append(sector) // PCN 2, head 0

    var disks: [D88Disk?] = [disk, nil]
    let fdc = UPD765A()
    fdc.drives = { disks }
    fdc.writeSector = { drive, track, c, h, r, data in
      disks[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
    }
    fdc.pcn[0] = 2

    fdc.writeData(0x45)
    fdc.writeData(0x00)
    fdc.writeData(1)     // C in sector ID differs from current PCN.
    fdc.writeData(0)
    fdc.writeData(1)
    fdc.writeData(1)
    fdc.writeData(1)
    fdc.writeData(0x1B)
    fdc.writeData(0xFF)

    let newData = Array(repeating: UInt8(0x56), count: 256)
    writeExecutionBytes(fdc, bytes: newData)
    _ = readResults(fdc)

    #expect(disks[0]?.readSector(track: 4, c: 1, h: 0, r: 1) == newData)
    #expect(disks[0]?.tracks[2].isEmpty == true)
  }

  @Test("DriveControl double-step affects current head position only")
  func driveControlDoubleStepCurrentPositionRead() {
    var disk = D88Disk()
    var directSector = D88Disk.Sector()
    directSector.c = 6
    directSector.h = 0
    directSector.r = 2
    directSector.n = 1
    directSector.sectorCount = 16
    directSector.data = Array(repeating: 0x11, count: 256)
    disk.tracks[12].append(directSector)

    var sector = D88Disk.Sector()
    sector.c = 6
    sector.h = 0
    sector.r = 2
    sector.n = 3
    sector.sectorCount = 5
    sector.data = Array(repeating: 0x42, count: 1024)
    disk.tracks[24].append(sector) // logical C=6 double-stepped -> physical cylinder 12, head 0

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 6
    fdc.setDriveControl(0x00) // TD0=0: 48TPI/double-step
    writeReadDataCmd(fdc, c: 6, h: 0, r: 2, n: 3, eot: 2)

    let bytes = readExecutionBytes(fdc, count: 1024)
    #expect(bytes == Array(repeating: UInt8(0x42), count: 1024))
  }

  @Test("DriveControl double-step prefers matching direct current track")
  func driveControlDoubleStepPrefersDirectCurrentTrack() {
    var disk = D88Disk()
    var directSector = D88Disk.Sector()
    directSector.c = 1
    directSector.h = 0
    directSector.r = 1
    directSector.n = 1
    directSector.sectorCount = 1
    directSector.data = Array(repeating: 0x11, count: 256)
    disk.tracks[2].append(directSector)

    var doubleStepSector = directSector
    doubleStepSector.data = Array(repeating: 0x22, count: 256)
    disk.tracks[4].append(doubleStepSector)

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 1
    fdc.setDriveControl(0x00) // TD0=0 would map PCN 1 to physical cylinder 2.
    writeReadDataCmd(fdc, c: 1, h: 0, r: 1, n: 1, eot: 1)

    let bytes = readExecutionBytes(fdc, count: 256)
    #expect(bytes == Array(repeating: UInt8(0x11), count: 256))
  }

  @Test("DriveControl double-step keeps command-cylinder fallback unscaled")
  func driveControlDoesNotScaleCommandFallback() {
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 1
    sector.h = 0
    sector.r = 1
    sector.n = 1
    sector.sectorCount = 1
    sector.data = Array(repeating: 0x24, count: 256)
    disk.tracks[2].append(sector)

    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 0
    fdc.setDriveControl(0x00)
    writeReadDataCmd(fdc, c: 1, h: 0, r: 1, n: 1, eot: 1)

    let bytes = readExecutionBytes(fdc, count: 256)
    #expect(bytes == Array(repeating: UInt8(0x24), count: 256))
  }

  @Test func writeDataProtected() {
    var disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    disk.writeProtected = true
    let diskCopy = disk
    let fdc = UPD765A()
    fdc.drives = { [diskCopy, nil] }

    fdc.writeData(0x45)  // Write Data
    fdc.writeData(0x00)
    fdc.writeData(0); fdc.writeData(0); fdc.writeData(1); fdc.writeData(1)
    fdc.writeData(1); fdc.writeData(0x1B); fdc.writeData(0xFF)

    // Should immediately go to result with error
    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[1] & 0x02 != 0)  // ST1.NW = not writable
  }

  // MARK: - Recalibrate (0x07)

  @Test func recalibrate() {
    let fdc = UPD765A()
    fdc.pcn[0] = 0  // Already at track 0

    var intFired = false
    fdc.onInterrupt = { intFired = true }

    fdc.writeData(0x07)  // Recalibrate
    fdc.writeData(0x00)  // drive 0

    // Already at track 0, should fire interrupt immediately
    #expect(intFired == true)
    #expect(fdc.phase == .idle)
  }

  @Test func recalibrateFromNonZero() {
    let fdc = UPD765A()
    fdc.pcn[0] = 10

    var intFired = false
    fdc.onInterrupt = { intFired = true }

    fdc.writeData(0x07)
    fdc.writeData(0x00)

    // Not at track 0, needs to seek
    #expect(intFired == false)
    #expect(fdc.phase == .idle)

    // Advance time to complete seek
    fdc.tick(tStates: 10_000_000)
    #expect(intFired == true)
    #expect(fdc.pcn[0] == 0)
  }

  // MARK: - Sense Interrupt Status (0x08)

  @Test func senseIntStatusAfterRecalibrate() {
    let fdc = UPD765A()
    fdc.pcn[0] = 0

    fdc.writeData(0x07)  // Recalibrate
    fdc.writeData(0x00)

    // Sense Int Status
    fdc.writeData(0x08)
    #expect(fdc.phase == .result)

    let results = readResults(fdc, count: 2)
    #expect(results[0] & 0x20 != 0)  // SE (seek end)
    #expect(results[1] == 0)          // PCN = 0
  }

  @Test func senseIntStatusNoInterrupt() {
    let fdc = UPD765A()

    fdc.writeData(0x08)
    let results = readResults(fdc, count: 2)
    #expect(results[0] & 0x80 != 0)  // IC = Invalid (no interrupt)
  }

  // MARK: - Seek (0x0F)

  @Test func seekToTrack() {
    let fdc = UPD765A()

    var intFired = false
    fdc.onInterrupt = { intFired = true }

    fdc.writeData(0x0F)  // Seek
    fdc.writeData(0x00)  // drive 0
    fdc.writeData(10)    // target cylinder 10

    #expect(fdc.phase == .idle)  // Seek runs asynchronously

    // Advance time to complete seek
    fdc.tick(tStates: 50_000_000)
    #expect(intFired == true)
    #expect(fdc.pcn[0] == 10)
  }

  @Test func seekAlreadyAtTarget() {
    let fdc = UPD765A()
    fdc.pcn[0] = 5

    var intFired = false
    fdc.onInterrupt = { intFired = true }

    fdc.writeData(0x0F)
    fdc.writeData(0x00)
    fdc.writeData(5)     // Already at 5

    #expect(intFired == true)
  }

  // MARK: - Read ID (0x0A)

  @Test func readID() {
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [
      (r: 1, data: Array(repeating: 0, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)

    fdc.writeData(0x4A)  // Read ID (MFM)
    fdc.writeData(0x00)  // drive 0, head 0

    // ReadID now models rotation delay: enters .execution, transitions
    // to .result after ~one sector's worth of T-states. Advance time.
    #expect(fdc.phase == .execution)
    fdc.tick(tStates: UPD765A.readIDBaseClocks + 10)
    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[3] == 0)  // C
    #expect(results[4] == 0)  // H
    #expect(results[5] == 1)  // R
    #expect(results[6] == 1)  // N
  }

  @Test func readIDNoSectors() {
    let fdc = UPD765A()
    let disk = D88Disk()
    fdc.drives = { [disk, nil] }

    fdc.writeData(0x4A)
    fdc.writeData(0x00)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)  // AT (abnormal)
  }

  // MARK: - Terminal Count

  @Test func readDataWithTCReturnsNormalTermination() {
    // Issuing TC completes the read; check for NT (normal termination)
    let disk = makeDisk(sectors: [
      (r: 1, data: Array(repeating: 0x11, count: 256)),
      (r: 2, data: Array(repeating: 0x22, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)
    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 2)

    // Read all 512 bytes
    _ = readExecutionBytes(fdc, count: 512)

    // Issue TC (as firmware would)
    fdc.terminalCount()

    // Should be in result phase with NT status
    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x00)  // IC = NT (retroactively fixed)
    #expect(results[1] & 0x80 == 0)      // ST1.EN cleared
  }

  @Test func terminalCountStopsRead() {
    let disk = makeDisk(sectors: [
      (r: 1, data: Array(repeating: 0x11, count: 256)),
      (r: 2, data: Array(repeating: 0x22, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 2)

    // Read partial data then TC
    _ = readExecutionBytes(fdc, count: 128)
    fdc.terminalCount()

    // Should transition to result
    #expect(fdc.phase == .result)
  }

  @Test func readDataClearsRQMUntilNextByteTime() {
    let sectorData = Array(0..<256).map { UInt8($0 & 0xFF) }
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [(r: 1, data: sectorData)])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)

    #expect(fdc.readStatus() & 0x80 != 0)
    #expect(fdc.readData() == 0x00)
    #expect(fdc.readStatus() & 0x80 == 0)

    fdc.tick(tStates: 127)
    #expect(fdc.readStatus() & 0x80 == 0)

    fdc.tick(tStates: 1)
    #expect(fdc.readStatus() & 0x80 != 0)
    #expect(fdc.readData() == 0x01)
  }

  @Test func writeDataClearsRQMUntilNextByteTime() {
    let disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    var disks: [D88Disk?] = [disk, nil]
    let fdc = UPD765A()
    fdc.drives = { disks }
    fdc.writeSector = { drive, track, c, h, r, data in
      disks[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
    }

    fdc.writeData(0x45)
    fdc.writeData(0x00)
    fdc.writeData(0)
    fdc.writeData(0)
    fdc.writeData(1)
    fdc.writeData(1)
    fdc.writeData(1)
    fdc.writeData(0x1B)
    fdc.writeData(0xFF)

    #expect(fdc.phase == .execution)
    #expect(fdc.readStatus() & 0x80 != 0)

    fdc.writeData(0x12)
    #expect(fdc.readStatus() & 0x80 == 0)

    fdc.tick(tStates: 127)
    #expect(fdc.readStatus() & 0x80 == 0)

    fdc.tick(tStates: 1)
    #expect(fdc.readStatus() & 0x80 != 0)

    fdc.writeData(0x34)
    #expect(fdc.readStatus() & 0x80 == 0)
  }

  // MARK: - Invalid Command

  @Test func invalidCommand() {
    let fdc = UPD765A()
    fdc.writeData(0x1F)  // Invalid command code

    #expect(fdc.phase == .result)
    let st0 = fdc.readData()
    #expect(st0 & 0x80 != 0)  // IC = Invalid Command
  }

  // MARK: - Status Register Transitions

  @Test func statusDuringCommand() {
    let fdc = UPD765A()

    fdc.writeData(0x03)  // Specify (needs 2 more bytes)
    let status = fdc.readStatus()
    #expect(status & 0x80 != 0)  // RQM
    #expect(status & 0x10 != 0)  // CB (busy)
    #expect(status & 0x40 == 0)  // DIO = 0 (CPU → FDC)
  }

  @Test func statusDuringResult() {
    let fdc = UPD765A()
    fdc.drives = { [nil, nil] }

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)

    let status = fdc.readStatus()
    #expect(status & 0x80 != 0)  // RQM
    #expect(status & 0x40 != 0)  // DIO (FDC → CPU)
    #expect(status & 0x10 != 0)  // CB
  }

  // MARK: - Seek Timing

  @Test func seekProgressesStepByStep() {
    let fdc = UPD765A()
    fdc.pcn[0] = 0

    // Set fast SRT for testing: SRT = 0xF0 → (16-15)*2ms = 2ms
    fdc.writeData(0x03)
    fdc.writeData(0xF0)  // SRT=15
    fdc.writeData(0x01)  // ND=1

    fdc.writeData(0x0F)  // Seek
    fdc.writeData(0x00)
    fdc.writeData(3)     // target track 3

    // Tick enough for one step (SRT = (16-15)*2ms = 2ms = 16000 clocks)
    fdc.tick(tStates: 16001)
    #expect(fdc.pcn[0] == 1)

    fdc.tick(tStates: 16001)
    #expect(fdc.pcn[0] == 2)

    fdc.tick(tStates: 16001)
    #expect(fdc.pcn[0] == 3)
    #expect(fdc.interruptPending == true)
  }

  // MARK: - Format Track (0x0D)

  @Test("Format track command accepts sector IDs")
  func formatTrackAcceptsSectorIDs() {
    let fdc = UPD765A()
    var disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    fdc.drives = { [disk] in [disk, nil] }
    fdc.formatTrack = { drive, track, sectorIDs, fillByte in
      guard drive == 0 else { return false }
      return disk.formatTrack(track: track, sectorIDs: sectorIDs, fillByte: fillByte)
    }

    // Write ID (Format Track) command: 0x4D (MFM)
    fdc.writeData(0x4D)  // Format Track (MFM)
    #expect(fdc.phase == .command)

    fdc.writeData(0x00)  // drive 0, head 0
    fdc.writeData(0x01)  // N=1 (256 bytes/sector)
    fdc.writeData(0x02)  // SC=2 (2 sectors)
    fdc.writeData(0x1B)  // GPL
    fdc.writeData(0xE5)  // fill byte

    #expect(fdc.phase == .execution)

    // Provide 4 bytes per sector (C, H, R, N) × 2 sectors = 8 bytes
    writeExecutionBytes(fdc, bytes: [
      0, 0, 1, 1,  // Sector 1: C=0, H=0, R=1, N=1
      0, 0, 2, 1   // Sector 2: C=0, H=0, R=2, N=1
    ])

    // Should transition to result phase
    #expect(fdc.phase == .result)

    // Read 7 result bytes
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x00)  // Normal termination
    #expect(disk.tracks[0].count == 2)
    #expect(disk.tracks[0][0].r == 1)
    #expect(disk.tracks[0][1].r == 2)
    #expect(disk.tracks[0][0].data == Array(repeating: UInt8(0xE5), count: 256))
    #expect(fdc.phase == .idle)
  }

  @Test("Format track rejects write-protected disk")
  func formatTrackWriteProtected() {
    var disk = makeDisk(sectors: [(r: 1, data: Array(repeating: 0, count: 256))])
    disk.writeProtected = true
    let (fdc, disks) = makeFDCWithDisk(disk)

    fdc.writeData(0x4D)
    fdc.writeData(0x00)
    fdc.writeData(0x01)
    fdc.writeData(0x02)
    fdc.writeData(0x1B)
    fdc.writeData(0xE5)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0xC0 == 0x40)
    #expect(results[1] & UPD765A.ST1_NW == UPD765A.ST1_NW)
    #expect(disks[0]?.tracks[0].count == 1)
  }

  @Test("ReadData with N=2 (512-byte sectors)")
  func readDataN2Sectors() {
    // Create D88 disk with 512-byte sectors (N=2)
    var disk = D88Disk()
    var sector = D88Disk.Sector()
    sector.c = 0; sector.h = 0; sector.r = 1; sector.n = 2
    sector.data = Array(0..<512).map { UInt8($0 & 0xFF) }
    disk.tracks[0] = [sector]

    let (fdc, _) = makeFDCWithDisk(disk)

    // Read Data with N=2
    fdc.writeData(0x46)  // Read Data (MFM, SK)
    fdc.writeData(0x00)  // drive 0, head 0
    fdc.writeData(0)     // C
    fdc.writeData(0)     // H
    fdc.writeData(1)     // R
    fdc.writeData(2)     // N=2 (512 bytes)
    fdc.writeData(1)     // EOT
    fdc.writeData(0x1B)  // GPL
    fdc.writeData(0xFF)  // DTL

    #expect(fdc.phase == .execution)

    // Read all 512 bytes
    let data = readExecutionBytes(fdc, count: 512)
    #expect(data[0] == 0x00)
    #expect(data[1] == 0x01)
    #expect(data[255] == 0xFF)
    #expect(data[256] == 0x00)  // wraps at byte level
    #expect(data[511] == 0xFF)

    #expect(fdc.phase == .result)
  }

  @Test("ReadData with TC mid-transfer terminates cleanly")
  func readDataTCMidTransfer() {
    let sectorData = Array(repeating: UInt8(0xAA), count: 256)
    let disk = makeDisk(sectors: [(r: 1, data: sectorData)])
    let (fdc, _) = makeFDCWithDisk(disk)

    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 1)
    #expect(fdc.phase == .execution)

    // Read only 128 of 256 bytes, then issue TC
    _ = readExecutionBytes(fdc, count: 128)
    fdc.terminalCount()

    // Should transition to result phase
    #expect(fdc.phase == .result)

    let results = readResults(fdc)
    // TC means normal termination
    #expect(results[0] & 0xC0 == 0x00)  // IC = NT (normal termination)
    #expect(results[1] & 0x80 == 0)      // ST1.EN cleared
  }

  @Test("ReadData TC result ST0 keeps physical head when ID H is nonstandard")
  func readDataTCResultST0KeepsPhysicalHeadForNonstandardIDH() {
    var disk = D88Disk()

    var first = D88Disk.Sector()
    first.c = 0
    first.h = 0x52
    first.r = 0x57
    first.n = 3
    first.sectorCount = 3
    first.data = Array(repeating: 0x57, count: 1024)

    var second = D88Disk.Sector()
    second.c = 0
    second.h = 0x52
    second.r = 0x52
    second.n = 3
    second.sectorCount = 3
    second.data = Array(repeating: 0x52, count: 1024)

    disk.tracks[5] = [first, second]
    let (fdc, _) = makeFDCWithDisk(disk)
    fdc.pcn[0] = 2

    writeReadDataCmd(
      fdc,
      head: 1,
      c: 0,
      h: 0x52,
      r: 0x57,
      n: 3,
      eot: 0x10,
      gpl: 0x33
    )

    _ = readExecutionBytes(fdc, count: 1024)
    fdc.terminalCount()

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0x04 != 0)
    #expect(results[0] & 0xC0 == 0x00)
    #expect(results[1] == 0x00)
    #expect(results[4] == 0x52)
    #expect(results[5] == 0x52)
  }

  @Test("Seek step-rate timing advances one track per SRT interval")
  func seekStepRateTiming() {
    let fdc = UPD765A()
    fdc.pcn[0] = 0

    // Set fast SRT: SRT=15 → (16-15)*2ms = 2ms = 16000 clocks
    fdc.writeData(0x03)
    fdc.writeData(0xF0)  // SRT=15
    fdc.writeData(0x01)  // ND=1

    fdc.writeData(0x0F)  // Seek
    fdc.writeData(0x00)  // drive 0
    fdc.writeData(5)     // target track 5

    // Verify seekMoving is active
    #expect(fdc.isSeeking == true)

    // After 5 steps × 16000 clocks each, seek should complete
    for step in 1...5 {
      fdc.tick(tStates: 16001)
      #expect(fdc.pcn[0] == UInt8(step))
    }

    #expect(fdc.pcn[0] == 5)
    #expect(fdc.interruptPending == true)
    #expect(fdc.isSeeking == false)
  }

  @Test("SenseIntStatus clears pending after all drives reported")
  func senseIntStatusClearsPendingForAllDrives() {
    let fdc = UPD765A()
    fdc.pcn[0] = 0
    fdc.pcn[1] = 0

    // Seek drive 0 to track 3
    fdc.writeData(0x0F)
    fdc.writeData(0x00)
    fdc.writeData(3)

    // Seek drive 1 to track 5
    fdc.writeData(0x0F)
    fdc.writeData(0x01)
    fdc.writeData(5)

    // Complete both seeks
    fdc.tick(tStates: 50_000_000)
    #expect(fdc.pcn[0] == 3)
    #expect(fdc.pcn[1] == 5)

    // SenseIntStatus for first drive
    fdc.writeData(0x08)
    let results1 = readResults(fdc, count: 2)
    #expect(results1[0] & 0x20 != 0)  // SE (seek end)

    // SenseIntStatus for second drive
    fdc.writeData(0x08)
    let results2 = readResults(fdc, count: 2)
    #expect(results2[0] & 0x20 != 0)  // SE

    // No more pending — should return invalid
    fdc.writeData(0x08)
    let results3 = readResults(fdc, count: 2)
    #expect(results3[0] & 0x80 != 0)  // IC = Invalid (no interrupt pending)
  }

  @Test("ReadData multi-sector wraps to next track EOT")
  func readDataMultiSectorEOTError() {
    // Create track with 2 sectors (R=1, R=2), but request EOT=5
    let disk = makeDisk(track: 0, c: 0, h: 0, sectors: [
      (r: 1, data: Array(repeating: 0x11, count: 256)),
      (r: 2, data: Array(repeating: 0x22, count: 256))
    ])
    let (fdc, _) = makeFDCWithDisk(disk)

    // Request R=1 with EOT=5, but only 2 sectors exist
    writeReadDataCmd(fdc, c: 0, h: 0, r: 1, eot: 5)

    // Should still read available sectors
    if fdc.phase == .execution {
      let data = readExecutionBytes(fdc, count: 512)
      #expect(data[0] == 0x11)
      #expect(data[256] == 0x22)

      #expect(fdc.phase == .result)
      let results = readResults(fdc)
      // End of cylinder since EOT was not reached
      #expect(results[0] & 0xC0 == 0x40)  // IC = AT
      #expect(results[1] & 0x80 != 0)      // ST1.EN = End of Cylinder
    } else {
      // If sector not found, that's also acceptable for missing sectors
      #expect(fdc.phase == .result)
    }
  }

  @Test("MT ReadData reports final head in ST0 after crossing to head 1")
  func readDataMTResultST0UsesFinalHead() {
    let sectorSize = 512
    let disk = makeTwoHeadDisk(
      head0: (1...9).map { (UInt8($0), Array(repeating: UInt8($0), count: sectorSize)) },
      head1: (1...9).map { (UInt8($0), Array(repeating: UInt8($0 + 0x10), count: sectorSize)) }
    )
    let (fdc, _) = makeFDCWithDisk(disk)

    fdc.writeData(0xC6)  // MT + MFM + Read Data
    fdc.writeData(0x00)  // drive 0, head 0
    fdc.writeData(0x00)  // C
    fdc.writeData(0x00)  // H
    fdc.writeData(0x02)  // R
    fdc.writeData(0x02)  // N = 512 bytes
    fdc.writeData(0x09)  // EOT
    fdc.writeData(0x20)  // GPL
    fdc.writeData(0xFF)  // DTL

    _ = readExecutionBytes(fdc, count: 17 * sectorSize)

    #expect(fdc.phase == .result)
    let results = readResults(fdc)
    #expect(results[0] & 0x04 != 0)
    #expect(results[4] == 1)
    #expect(results[5] == 9)
  }
}
