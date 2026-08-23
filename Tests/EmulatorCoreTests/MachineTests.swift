import Testing
import Foundation
@testable import EmulatorCore

@Suite("Machine Tests")
struct MachineTests {

  // MARK: - Initialization

  @Test func resetState() {
    let machine = Machine()
    machine.reset()

    #expect(machine.cpu.im == 0)  // Z80 reset: IM0, ROM will set IM2
    #expect(machine.cpu.pc == 0x0000)
    #expect(machine.cpu.iff1 == false)
    #expect(machine.totalTStates == 0)
  }

  // MARK: - Tick Execution

  @Test func tickExecutesOneInstruction() {
    let machine = Machine()
    machine.reset()

    // Load NOP at 0x0000 (no ROM, RAM mode, 4MHz to avoid memory wait)
    machine.bus.ramMode = true
    machine.bus.cpuClock8MHz = false
    machine.bus.mainRAM[0x0000] = 0x00  // NOP

    let cycles = machine.tick()
    #expect(cycles == 4)
    #expect(machine.cpu.pc == 0x0001)
    #expect(machine.totalTStates == 4)
  }

  @Test func tickAccumulatesTotalTStates() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.bus.cpuClock8MHz = false  // 4MHz: no memory wait

    // Load several NOPs
    for i in 0..<10 {
      machine.bus.mainRAM[i] = 0x00
    }

    for _ in 0..<10 {
      machine.tick()
    }
    #expect(machine.totalTStates == 40)  // 10 * 4 T-states
  }

  // MARK: - Interrupt Delivery

  @Test func interruptDeliveredWhenEnabled() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true

    // Set up CPU for interrupts
    machine.cpu.iff1 = true
    machine.cpu.iff2 = true
    machine.cpu.im = 2
    machine.cpu.i = 0x80
    machine.cpu.sp = 0xFF00
    machine.cpu.pc = 0x0100

    // Set up vector table: Level 1 (VRTC) → vector offset 0x02
    // Vector address = 0x8002 → mainRAM (ramMode=true → text window disabled)
    machine.bus.mainRAM[0x8002] = 0x00  // ISR low
    machine.bus.mainRAM[0x8003] = 0x20  // ISR high = 0x2000

    // ISR at 0x2000: RETI (ED 4D)
    machine.bus.mainRAM[0x2000] = 0xED
    machine.bus.mainRAM[0x2001] = 0x4D

    // NOP at current PC
    machine.bus.mainRAM[0x0100] = 0x00

    // Enable VRTC and request interrupt
    machine.interruptBox.controller.maskVRTC = false
    machine.interruptBox.controller.request(level: .vrtc)

    // Tick — should execute NOP then service interrupt
    machine.tick()

    // After interrupt: PC should be at ISR (0x2000) or past it
    // The interrupt is serviced after the instruction
    #expect(machine.cpu.pc == 0x2000)
    #expect(machine.cpu.iff1 == false)  // Cleared by interrupt
  }

  @Test func subCpuInterruptFiresAfterInitialize() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.cpu.iff1 = true
    machine.cpu.im = 2
    machine.cpu.i = 0x80
    machine.cpu.sp = 0xFF00

    // INT3 vector (level=3, vectorOffset=0x06) → address 0x8006
    // ramMode=true disables the text window, so the vector goes in mainRAM
    machine.bus.mainRAM[0x8006] = 0x00  // ISR low
    machine.bus.mainRAM[0x8007] = 0x40  // ISR high = 0x4000
    machine.bus.mainRAM[0x4000] = 0xED   // RETI
    machine.bus.mainRAM[0x4001] = 0x4D
    machine.bus.mainRAM[0x0000] = 0x00   // NOP
    machine.cpu.pc = 0x0000

    // Sending the sub-CPU Initialize (0x00) command should fire onInterrupt at once
    // ATN rising edge (mainPortCH bit 3 set) → command mode
    machine.subSystem.pioWrite(port: 0xFF, value: 0x0F)  // set bit 3 (ATN)
    // Write command byte to Port B
    machine.subSystem.pioWrite(port: 0xFD, value: 0x00)  // Initialize (no params)

    // INT3 should now be pending
    #expect(machine.interruptBox.controller.pendingLevels & (1 << 3) != 0)
  }

  @Test func maskedInterruptNotDelivered() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true

    machine.cpu.iff1 = true
    machine.cpu.im = 2
    machine.cpu.pc = 0x0100
    machine.bus.mainRAM[0x0100] = 0x00  // NOP

    // Mask VRTC and request it
    machine.interruptBox.controller.maskVRTC = true
    machine.interruptBox.controller.request(level: .vrtc)

    machine.tick()

    // Interrupt should NOT be delivered
    #expect(machine.cpu.pc == 0x0101)  // Just past NOP
  }

  // MARK: - Clock Switching

  @Test func clockSwitchSyncsBus() {
    let machine = Machine()
    machine.monitorType = .khz24
    machine.reset()

    // 24kHz reset geometry is 448 lines, so a frame is 448 / 24,826.13 s.
    // Not 1/60 — see `Machine.tStatesPerFrame`.
    machine.clock8MHz = true
    #expect(machine.bus.cpuClock8MHz == true)
    #expect(machine.tStatesPerFrame == 144_134)

    machine.clock8MHz = false
    #expect(machine.bus.cpuClock8MHz == false)
    #expect(machine.tStatesPerFrame == 72_067)
  }

  /// The whole point of Step 3: the VSYNC period follows the monitor and the
  /// CRTC, not a hardcoded 60Hz.
  @Test func frameRateFollowsMonitorType() {
    let machine = Machine()

    machine.monitorType = .khz24
    machine.reset()
    #expect(abs(machine.frameRate - 55.42) < 0.01)

    machine.monitorType = .khz15
    machine.reset()
    #expect(machine.crtc.dynamicTotalScanlines == 256)
    #expect(abs(machine.frameRate - 62.42) < 0.01)
  }

  /// SHG (port 0x40 bit 1) is the read-back for the monitor DIP. `.khz24`
  /// stays the default so software sees exactly what it saw before 1.5.0.
  @Test func monitorTypeSurfacesOnPort40() {
    let machine = Machine()

    machine.monitorType = .khz24
    machine.reset()
    #expect((machine.bus.ioRead(0x40) & 0x02) == 0)

    machine.monitorType = .khz15
    machine.reset()
    #expect((machine.bus.ioRead(0x40) & 0x02) == 0x02)
  }

  @Test func subCpuRunsAtHalfSpeedWhenMainIs8MHz() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.clock8MHz = true

    machine.loadDiskROM(Array(repeating: 0x00, count: 0x2000))
    for i in 0..<32 {
      machine.bus.mainRAM[i] = 0x00
      machine.subSystem.subBus.romram[i] = 0x00
    }

    machine.subSystem.subCpu.pc = 0x0000
    for _ in 0..<10 {
      machine.tick()
    }

    // 10 NOPs × 5T (4T + 1T 8MHz RAM wait) = 50T main → 25T sub budget at
    // 2:1 main/sub ratio. 25T / 4T per NOP = 6.25 NOPs, and the BubiC-style
    // over-run debt rounds up to 7 (the final over-run is owed to the
    // scheduler and deducted from the next main opcode).
    #expect(machine.subSystem.subCpu.pc == 0x0007)
  }

  @Test func subCpuRunsAtSameSpeedWhenMainIs4MHz() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.clock8MHz = false

    machine.loadDiskROM(Array(repeating: 0x00, count: 0x2000))
    for i in 0..<32 {
      machine.bus.mainRAM[i] = 0x00
      machine.subSystem.subBus.romram[i] = 0x00
    }

    machine.subSystem.subCpu.pc = 0x0000
    for _ in 0..<10 {
      machine.tick()
    }

    #expect(machine.subSystem.subCpu.pc == 0x000A)
  }

  @Test func haltedSubCpuDoesNotBankCatchUpBudget() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.clock8MHz = false

    machine.loadDiskROM(Array(repeating: 0x00, count: 0x2000))
    for i in 0..<256 {
      machine.bus.mainRAM[i] = 0x00
      machine.subSystem.subBus.romram[i] = 0x00
    }

    machine.subSystem.subCpu.pc = 0x0000
    machine.subSystem.subCpu.halted = true
    machine.subSystem.subCpu.iff1 = false

    for _ in 0..<100 {
      machine.tick()
    }

    machine.subSystem.subCpu.halted = false
    machine.tick()

    #expect(machine.subSystem.subCpu.pc == 0x0001)
  }

  // MARK: - ROM Loading

  @Test func romLoadedAndAccessible() {
    let machine = Machine()
    machine.reset()

    var rom = Array(repeating: UInt8(0x00), count: 32768)
    rom[0] = 0xC3  // JP
    rom[1] = 0x00
    rom[2] = 0x80
    machine.loadN88BasicROM(rom)

    // Default: ROM mode, N88-BASIC
    #expect(machine.bus.memRead(0x0000) == 0xC3)
  }

  // MARK: - Component Integration

  @Test func crtcWiredToMachine() {
    let machine = Machine()
    machine.reset()

    // CRTC should be accessible
    #expect(machine.crtc.scanline == 0)
    #expect(machine.crtc.vrtcFlag == false)
  }

  @Test func ym2608TimerGeneratesInterrupt() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true

    // Enable interrupts
    machine.cpu.iff1 = true
    machine.cpu.iff2 = true
    machine.cpu.im = 2
    machine.cpu.i = 0x80
    machine.cpu.sp = 0xFF00

    // Set up vector table for Sound (level 4, offset 0x08)
    // Vector address = 0x8008 → mainRAM[0x8008] (ramMode=true)
    machine.bus.mainRAM[0x8008] = 0x00
    machine.bus.mainRAM[0x8009] = 0x30  // ISR at 0x3000
    machine.bus.mainRAM[0x3000] = 0xED  // RETI
    machine.bus.mainRAM[0x3001] = 0x4D

    // Configure YM2608 Timer A for fast overflow
    machine.sound.writeAddr(0x24)
    machine.sound.writeData(0xFF)  // Timer A = 1023
    machine.sound.writeAddr(0x25)
    machine.sound.writeData(0x03)
    machine.sound.writeAddr(0x27)
    machine.sound.writeData(0x05)  // Start + IRQ enable

    // Fill memory with NOPs
    for i in 0..<200 {
      machine.bus.mainRAM[i] = 0x00
    }

    // Run enough to trigger timer
    machine.run(tStates: 200)

    // Timer should have overflowed
    #expect(machine.sound.timerAOverflow == true)
  }

  @Test func soundInterruptReRequestsOnSINTMUnmask() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.cpu.iff1 = false
    machine.bus.mainRAM[0x0000] = 0x00  // NOP

    // Unmask sound so the initial timer overflow request goes through
    machine.interruptBox.controller.maskSound = false

    // Set Timer A to minimum period and enable with IRQ
    machine.sound.writeAddr(0x24)
    machine.sound.writeData(0xFF)
    machine.sound.writeAddr(0x25)
    machine.sound.writeData(0x03)
    machine.sound.writeAddr(0x27)
    machine.sound.writeData(0x05)

    machine.sound.tick(tStates: 144)

    #expect(machine.sound.irqLineActive == true)
    #expect(machine.interruptBox.controller.pendingLevels & (1 << 4) != 0)

    // Acknowledge clears pending bit
    machine.interruptBox.controller.acknowledge(level: 4)
    #expect(machine.interruptBox.controller.pendingLevels & (1 << 4) == 0)

    // Re-mask sound, then unmask: should re-request since OPNA line is still high
    machine.interruptBox.controller.maskSound = true
    machine.bus.ioWrite(0x32, value: 0x00)  // SINTM=0 (unmask)
    #expect(machine.interruptBox.controller.pendingLevels & (1 << 4) != 0)
  }

  @Test func ym2608PortsRoutedViaBus() {
    let machine = Machine()
    machine.reset()

    // Write YM2608 address via bus I/O
    machine.bus.ioWrite(0x44, value: 0x30)
    machine.bus.ioWrite(0x45, value: 0xAB)

    // Read back
    machine.sound.writeAddr(0x30)
    #expect(machine.bus.ioRead(0x45) == 0xAB)
  }

  @Test func crtcPortsRoutedViaBus() {
    let machine = Machine()
    machine.reset()

    // Start display via port 0x51
    machine.bus.ioWrite(0x51, value: 0x20)
    #expect(machine.crtc.displayEnabled == true)

    // Read status
    machine.crtc.vrtcFlag = true
    let status = machine.bus.ioRead(0x51)
    #expect(status & 0x20 != 0)  // VRTC flag
  }

  @Test func subSystemPIORoutedViaBus() {
    let machine = Machine()
    machine.reset()

    // Write to PIO Port B via bus
    machine.bus.ioWrite(0xFD, value: 0x42)
    #expect(machine.subSystem.portB == 0x42)

    // Read PIO Port C via bus (handshake status)
    let portC = machine.bus.ioRead(0xFE)
    #expect(portC & 0x02 != 0)  // OBF_B = 1 (empty, sub read it)
  }

  @Test func diskMountViaMachine() {
    let machine = Machine()
    machine.reset()

    var disk = D88Disk()
    disk.name = "GAME"
    machine.mountDisk(drive: 0, disk: disk)
    #expect(machine.subSystem.hasDisk(drive: 0) == true)

    machine.ejectDisk(drive: 0)
    #expect(machine.subSystem.hasDisk(drive: 0) == false)
  }

  // MARK: - Run

  @Test func runExecutesApproximateTStates() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true

    // Fill with NOPs
    for i in 0..<1000 {
      machine.bus.mainRAM[i] = 0x00
    }

    let executed = machine.run(tStates: 100)
    #expect(executed >= 100)
    #expect(executed <= 104)  // May overshoot by one instruction
  }

  // MARK: - Trace

  @Test func traceDisabledByDefault() {
    let machine = Machine()
    machine.reset()
    #expect(machine.traceEnabled == false)
    #expect(machine.traceLog.isEmpty)
  }

  @Test func traceRecordsInstructions() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.traceEnabled = true

    // NOP at 0x0000
    machine.bus.mainRAM[0x0000] = 0x00
    machine.bus.mainRAM[0x0001] = 0x00

    machine.tick()
    machine.tick()

    #expect(machine.traceLog.count == 2)
    #expect(machine.traceLog[0].pc == 0x0000)
    #expect(machine.traceLog[0].opcode == 0x00)
    #expect(machine.traceLog[0].ioPort == nil)
    #expect(machine.traceLog[1].pc == 0x0001)
  }

  @Test func traceRecordsIOAccess() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.traceEnabled = true

    // OUT (0x5C), A → selects blue GVRAM plane
    machine.bus.mainRAM[0x0000] = 0xD3  // OUT (n), A
    machine.bus.mainRAM[0x0001] = 0x5C  // port 0x5C

    machine.tick()

    #expect(machine.traceLog.count >= 1)
    let entry = machine.traceLog.first { $0.ioPort != nil }
    #expect(entry != nil)
    #expect(entry?.ioPort == 0x5C)
    #expect(entry?.isWrite == true)
  }

  @Test func traceRespectsMaxEntries() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.traceEnabled = true
    machine.traceMaxEntries = 5

    // Fill with NOPs
    for i in 0..<20 {
      machine.bus.mainRAM[i] = 0x00
    }

    for _ in 0..<20 {
      machine.tick()
    }

    #expect(machine.traceLog.count == 5)
  }

  @Test func saveStateRoundTripsCassette() throws {
    let src = Machine()
    src.reset()
    let tapeBytes: [UInt8] = Array(repeating: 0x9C, count: 8) + [0xAA, 0xBB]
    src.mountTape(data: Data(tapeBytes))
    src.cassette.primeDelayTStates = 0
    src.cassette.motorOn = true
    src.cassette.cmtSelected = true
    src.cassette.tick(tStates: src.cassette.bytePeriodTStates * 3)
    let blob = src.createSaveState()

    let dst = Machine()
    dst.reset()
    try dst.loadSaveState(blob)

    #expect(dst.cassette.buffer == tapeBytes)
    #expect(dst.cassette.bufPtr == src.cassette.bufPtr)
    #expect(dst.cassette.motorOn)
    #expect(dst.cassette.cmtSelected)
  }

  @Test func saveStateEjectsTapeWhenNoneSaved() throws {
    let src = Machine()
    src.reset()
    let blob = src.createSaveState()

    let dst = Machine()
    dst.reset()
    dst.mountTape(data: Data([0x01, 0x02, 0x03]))
    #expect(dst.cassette.isLoaded)
    try dst.loadSaveState(blob)
    #expect(!dst.cassette.isLoaded)
  }

  // MARK: - Save State Sections

  @Test func saveStateCarriesExtraSections() throws {
    let src = Machine()
    src.reset()
    let tag = SaveStateFile.fourCC("AMTA")
    let payload = Array("{\"bootMode\":\"v2\"}".utf8)
    let blob = src.createSaveState(extraSections: [(tag: tag, data: payload)])

    let sections = try SaveStateFile.parse(blob)
    #expect(sections[tag] == payload)
    // Sections the emulator itself writes are unaffected.
    #expect(sections[SaveStateFile.fourCC("MAIN")] != nil)
    #expect(sections[SaveStateFile.fourCC("META")] != nil)
  }

  /// Unknown tags must not break loading: that is what lets the app layer add
  /// a section without a format version bump.
  @Test func saveStateWithUnknownSectionStillLoads() throws {
    let src = Machine()
    src.reset()
    src.bus.mainRAM[0x9000] = 0x5A
    let blob = src.createSaveState(extraSections: [
      (tag: SaveStateFile.fourCC("ZZZZ"), data: [0xDE, 0xAD, 0xBE, 0xEF]),
    ])

    let dst = Machine()
    dst.reset()
    try dst.loadSaveState(blob)
    #expect(dst.bus.mainRAM[0x9000] == 0x5A)
  }

  @Test func saveStateStoresThumbnail() throws {
    let src = Machine()
    src.reset()
    let thumb: [UInt8] = Array(repeating: 0x7F, count: 64)
    let blob = src.createSaveState(thumbnail: thumb)

    let sections = try SaveStateFile.parse(blob)
    #expect(sections[SaveStateFile.fourCC("THMB")] == thumb)
  }

  /// `parseSectionTable` is what the app layer and the Quick Look extension
  /// use to seek to one section without reading the whole file, so it must
  /// agree with `parse` while only needing the leading bytes.
  @Test func parseSectionTableMatchesFullParse() throws {
    let src = Machine()
    src.reset()
    let blob = src.createSaveState(thumbnail: Array(repeating: 0x11, count: 32),
                                   extraSections: [(tag: SaveStateFile.fourCC("AMTA"),
                                                    data: Array("{}".utf8))])
    let sections = try SaveStateFile.parse(blob)
    let entries = try SaveStateFile.parseSectionTable(blob)

    #expect(entries.count == sections.count)
    for entry in entries {
      let expected = try #require(sections[entry.tag])
      #expect(entry.size == expected.count)
      #expect(Array(blob[entry.offset..<(entry.offset + entry.size)]) == expected)
    }

    // Only the header plus the table is needed.
    let prefixLength = SaveStateFile.headerSize + entries.count * SaveStateFile.sectionEntrySize
    let fromPrefix = try SaveStateFile.parseSectionTable(Array(blob[0..<prefixLength]))
    #expect(fromPrefix.map(\.tag) == entries.map(\.tag))
    #expect(fromPrefix.map(\.offset) == entries.map(\.offset))
  }

  @Test func parseSectionTableRejectsForeignData() {
    #expect(throws: (any Error).self) {
      try SaveStateFile.parseSectionTable(Array(repeating: 0x00, count: 128))
    }
  }

  @Test func traceResetClearsLog() {
    let machine = Machine()
    machine.reset()
    machine.bus.ramMode = true
    machine.traceEnabled = true

    machine.bus.mainRAM[0x0000] = 0x00
    machine.tick()
    #expect(!machine.traceLog.isEmpty)

    machine.reset()
    #expect(machine.traceLog.isEmpty)
  }
}
