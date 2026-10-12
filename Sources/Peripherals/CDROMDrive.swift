import Foundation

/// The PC-8801MC's CD-ROM drive and its interface, ports 0x90-0x9F.
///
/// The drive is a SCSI target (ID 0) behind a simple bus interface; the CPU
/// is the initiator (ID 7) and drives the handshake through ports. All of
/// this is worked out from what the CD BIOS (CDBIOS.ROM) does with the
/// ports and with the bytes it gets back, plus the SCSI-2 standard for the
/// generic commands and ECMA-130 for the disc layout. Addresses in the
/// comments are in the BIOS's lower half.
///
/// Ports:
///
/// - 0x90 read: the bus control lines — BSY bit 7, REQ bit 6, MSG bit 5,
///   C/D bit 4, I/O bit 3. 0x00 is bus free (0x10B2 waits for exactly 0).
///   Bit 6 is REQ because the byte loop (0x1044) waits for it before every
///   byte; bit 7 is BSY because the stuck-target drain (0x112D) feeds 0xFF
///   while bit 6 comes and goes and stops once bit 7 drops.
/// - 0x90 write: bit 0 asserts SEL. Selection writes the two IDs (0x81) to
///   0x91, raises SEL, and drops it once REQ appears (0x10E1).
/// - 0x91: the data bus. Accessing it acknowledges the byte — the BIOS
///   never drives ACK itself, it just goes back to waiting for REQ. A write
///   acknowledges in the status and message phases too: that is how the
///   drain at 0x112D gets a target left holding the bus back to bus free,
///   feeding 0xFF until BSY drops. Mirrors relies on it, sending D9 without
///   reading the status and draining it before the next command.
/// - 0x94 write: bit 7 is RST, pulsed by BIOS function 0x0A (0x177E).
/// - 0x98 read: bit 7 toggles on its own; function 0 (0x1255) decides the
///   drive is there when it changes within ten reads.
/// - 0x98 write: the audio fader (BIOS function 3, 0x138E); see
///   `fadeLevel`.
/// - 0x9F write: bit 6 routes data-in bytes to DMA channel 1 during a READ
///   (0x15C2 writes 0x41 after programming the channel, 0x15C9 writes 0x01
///   afterwards). Bit 0's purpose is not known.
///
/// Ports 0x92/0x93/0x96/0x97, which BIOS function 4 (0x15CE) reads raw
/// subcode through, are not implemented.
package final class CDROMDrive {

  // MARK: - Wiring

  /// Whether the drive answers at all. Off, every port reads 0xFF.
  package var enabled = false

  /// CPU clock, for the timings below.
  package var cpuClockHz: Double = 7_987_248.0

  /// DMA controller; channel 1 carries READ data when port 0x9F bit 6 is on.
  package weak var dma: DMAController?

  /// Writes one DMA byte to memory.
  package var writeMemory: ((UInt16, UInt8) -> Void)?

  /// The disc in the tray.
  package private(set) var disc: CDDisc?

  /// Set by any command; cleared by `takeActivity()`. Feeds an access lamp.
  package private(set) var activity = false

  // MARK: - Bus state

  /// SCSI bus phase. The raw values are the MSG / C/D / I/O lines as port
  /// 0x90 shows them.
  enum Phase: UInt8 {
    case busFree = 0xFF
    case dataOut = 0x00
    case dataIn = 0x08
    case command = 0x10
    case status = 0x18
    case messageIn = 0x38
  }

  private(set) var phase: Phase = .busFree
  private(set) var req = false
  /// SEL as the initiator drives it.
  private var sel = false
  /// The data bus as last written by the initiator, or the byte the drive
  /// is presenting in an "in" phase.
  private var dataBus: UInt8 = 0xFF
  /// T-states until the drive answers a selection; -1 when not selecting.
  private var selectionDelay = -1
  /// T-states until the drive raises REQ for the next byte, or carries
  /// out the command it has just received; -1 when nothing is pending.
  private var nextEvent = -1
  /// What happens when `nextEvent` runs out.
  private enum Pending: UInt8 { case none, request, execute }
  private var pending: Pending = .none

  private var command: [UInt8] = []
  private var commandLength = 6
  private var dataIn: [UInt8] = []
  private var dataInIndex = 0
  /// Sectors still to stream into `dataIn` for a READ.
  private var readLBA = 0
  private var readRemaining = 0
  private var dataOut: [UInt8] = []
  private var dataOutLength = 0
  private var statusByte: UInt8 = 0

  /// Sense data for REQUEST SENSE: the key, and the NEC error code the BIOS
  /// takes from byte 9 (0x11E5).
  private var senseKey: UInt8 = 0
  private var senseCode: UInt8 = 0

  /// READ returns 2340 bytes a sector — everything after the 12 sync
  /// bytes — instead of the 2048 user bytes.
  private(set) var rawSectors = false

  /// Port 0x9F as last written.
  private var control: UInt8 = 0
  /// Port 0x98 as last written.
  private(set) var fader: UInt8 = 0x00

  /// Audio volume, 0 (silent) to `fadeFull`, after the fader.
  ///
  /// Inferred from the two programs that use it. Bit 1 is the level to go
  /// to, full (0) or silent (1); bit 2 makes the change gradual. Mirrors
  /// writes 2 at start-up and 0 before its first track, writes 7 and stops
  /// the track about 2.5 seconds later, starts the next and writes 5. The
  /// BIOS's CD player writes 0 before starting a track and 5 just after
  /// (0x3417, 0x3496), 6 just before stopping (0x33CA), and 7 before going
  /// on to the next track (0x3546).
  ///
  /// TODO: bit 0's purpose and the length of a fade are not known. A fade
  /// here takes `fadeSeconds`, inside the 2.5 seconds Mirrors allows.
  private(set) var fadeLevel = CDROMDrive.fadeFull
  static let fadeFull = 1 << 16
  static let fadeSeconds = 2.0
  /// Fractional progress of a fade, in T-states × `fadeFull`.
  private var fadeClock = 0

  /// Drives port 0x98 bit 7.
  private var clockPhase = 0
  private var clockBit = false

  // MARK: - Audio state

  /// What sub-Q byte 0 reports.
  enum AudioState: UInt8 {
    case playing = 0
    case paused = 1
    case stopped = 3
  }

  private(set) var audioState: AudioState = .stopped
  /// The sector being played, or where play will start.
  private(set) var audioLBA = 0
  /// Play stops before this sector.
  private var audioEnd = 0
  /// Next sample within the current sector, 0-587.
  private var audioSample = 0
  private var audioSector = [UInt8](repeating: 0, count: CDDisc.sectorBytes)
  private var audioSectorLoaded = -1
  /// Bresenham accumulator for the 44.1kHz sample clock.
  private var sampleClock = 0

  /// Samples waiting for the sound chip, which takes one per output frame
  /// at the same 44.1kHz. Capped so a muted sound chip cannot let it grow.
  private var samples: [Int32] = []
  private var samplesHead = 0
  private static let samplesCap = 8192

  package init() {}

  // MARK: - Timing

  /// T-states for a duration in microseconds at the current clock.
  private func tStates(microseconds: Double) -> Int {
    max(1, Int(cpuClockHz * microseconds / 1_000_000))
  }

  /// How long the drive takes to answer a selection. The BIOS checks BSY
  /// about 100 T-states after raising SEL and treats it already being set
  /// as a bus left busy (0x10EC), then waits on the order of 100,000
  /// T-states for REQ (0x10F4); 100µs is well inside that window.
  private var selectionTime: Int { tStates(microseconds: 100) }
  /// Between bytes of a command, status or message.
  private var handshakeTime: Int { tStates(microseconds: 2) }
  /// From the last command byte to the drive's answer.
  private var commandTime: Int { tStates(microseconds: 1000) }
  /// Between data bytes: a normal-speed drive delivers 75 sectors a second.
  private var dataByteTime: Int {
    let bytes = Double(CDDisc.sectorsPerSecond * (rawSectors ? 2340 : 2048))
    return tStates(microseconds: 1_000_000 / bytes)
  }

  // MARK: - Lifecycle

  package func reset() {
    resetBus()
    rawSectors = false
    senseKey = 0
    senseCode = 0
    control = 0
    fader = 0x00
    fadeLevel = Self.fadeFull
    fadeClock = 0
    stopAudio(.stopped)
    audioLBA = 0
    activity = false
  }

  /// RST, or power on: the bus goes free and any command is abandoned.
  private func resetBus() {
    phase = .busFree
    req = false
    sel = false
    selectionDelay = -1
    nextEvent = -1
    pending = .none
    command = []
    dataIn = []
    dataInIndex = 0
    readRemaining = 0
    dataOut = []
  }

  package func mount(_ disc: CDDisc) {
    self.disc = disc
    stopAudio(.stopped)
    audioLBA = 0
  }

  package func eject() {
    disc = nil
    stopAudio(.stopped)
    audioLBA = 0
  }

  package func takeActivity() -> Bool {
    defer { activity = false }
    return activity
  }

  // MARK: - Ports

  package func ioRead(_ port: UInt8) -> UInt8 {
    guard enabled else { return 0xFF }
    switch port {
    case 0x90:
      guard phase != .busFree else { return 0x00 }
      return 0x80 | (req ? 0x40 : 0) | phase.rawValue
    case 0x91:
      let value = dataBus
      if req && (phase == .dataIn || phase == .status || phase == .messageIn) {
        acknowledgeIn()
      }
      return value
    case 0x98:
      // TODO: only bit 7 is known; what the other bits read is not.
      return clockBit ? 0x80 : 0x00
    default:
      return 0xFF
    }
  }

  package func ioWrite(_ port: UInt8, value: UInt8) {
    guard enabled else { return }
    switch port {
    case 0x90:
      let newSel = value & 0x01 != 0
      // Our ID (bit 0) on the bus as SEL rises, with the bus free.
      if newSel && !sel && phase == .busFree && dataBus & 0x01 != 0 {
        selectionDelay = selectionTime
      }
      if !newSel { selectionDelay = -1 }
      sel = newSel
    case 0x91:
      guard req else {
        dataBus = value
        return
      }
      switch phase {
      case .command, .dataOut:
        dataBus = value
        acknowledgeOut(value)
      case .dataIn, .status, .messageIn:
        acknowledgeIn()
      case .busFree:
        break
      }
    case 0x94:
      if value & 0x80 != 0 {
        resetBus()
        stopAudio(.stopped)
      }
    case 0x98:
      fader = value
      if value & 0x04 == 0 {
        fadeLevel = value & 0x02 == 0 ? Self.fadeFull : 0
      }
    case 0x9F:
      control = value
    default:
      break
    }
  }

  // MARK: - Time

  package func tick(tStates: Int) {
    guard enabled else { return }

    clockPhase += tStates * 88_200
    let clock = Int(cpuClockHz)
    if clockPhase >= clock {
      // TODO: what drives port 0x98 bit 7 is not known. The BIOS only needs
      // it to change within ten reads of its detection loop; a 44.1kHz
      // square wave does.
      let toggles = clockPhase / clock
      clockPhase -= toggles * clock
      if toggles & 1 != 0 { clockBit.toggle() }
    }

    if selectionDelay >= 0 {
      selectionDelay -= tStates
      if selectionDelay < 0 { answerSelection() }
    }
    if nextEvent >= 0 {
      nextEvent -= tStates
      if nextEvent < 0 { runPending() }
    }
    if phase == .dataIn && dmaActive {
      runDMA(tStates: tStates)
    }
    advanceFade(tStates: tStates)
    advanceAudio(tStates: tStates)
  }

  /// Moves `fadeLevel` toward the fader's target, the whole range taking
  /// `fadeSeconds`.
  private func advanceFade(tStates: Int) {
    let target = fader & 0x02 == 0 ? Self.fadeFull : 0
    guard fadeLevel != target else { return }
    fadeClock += tStates * Self.fadeFull
    let perStep = Int(cpuClockHz * Self.fadeSeconds)
    let steps = fadeClock / perStep
    guard steps > 0 else { return }
    fadeClock -= steps * perStep
    fadeLevel = target > fadeLevel ? min(target, fadeLevel + steps) : max(target, fadeLevel - steps)
  }

  private func schedule(_ what: Pending, after t: Int) {
    pending = what
    nextEvent = t
  }

  private func runPending() {
    let what = pending
    pending = .none
    nextEvent = -1
    switch what {
    case .none: break
    case .request: raiseRequest()
    case .execute: execute()
    }
  }

  private func answerSelection() {
    selectionDelay = -1
    guard sel else { return }
    phase = .command
    command = []
    commandLength = 6
    req = true
  }

  /// REQ for the next byte of the current phase.
  private func raiseRequest() {
    switch phase {
    case .dataIn:
      if dataInIndex >= dataIn.count && !fillDataIn() {
        enterStatus()
        return
      }
      dataBus = dataIn[dataInIndex]
    case .status:
      dataBus = statusByte
    case .messageIn:
      dataBus = 0x00  // COMMAND COMPLETE
    default:
      break
    }
    req = true
  }

  /// The initiator wrote a byte in an "out" phase.
  private func acknowledgeOut(_ value: UInt8) {
    req = false
    switch phase {
    case .command:
      if command.isEmpty { commandLength = Self.commandLength(opcode: value) }
      command.append(value)
      if command.count >= commandLength {
        activity = true
        schedule(.execute, after: commandTime)
      } else {
        schedule(.request, after: handshakeTime)
      }
    case .dataOut:
      dataOut.append(value)
      if dataOut.count >= dataOutLength {
        finishDataOut()
      } else {
        schedule(.request, after: handshakeTime)
      }
    default:
      break
    }
  }

  /// The initiator read the byte of an "in" phase.
  private func acknowledgeIn() {
    req = false
    switch phase {
    case .dataIn:
      dataInIndex += 1
      schedule(.request, after: dataByteTime)
    case .status:
      phase = .messageIn
      schedule(.request, after: handshakeTime)
    case .messageIn:
      phase = .busFree
      dataBus = 0xFF
    default:
      break
    }
  }

  /// SCSI command groups: 0 is six bytes, 1, 2 and 6 ten (the NEC commands
  /// 0xD8-0xDE are group 6 and the BIOS sends ten), 5 twelve.
  static func commandLength(opcode: UInt8) -> Int {
    switch opcode >> 5 {
    case 0: return 6
    case 5: return 12
    default: return 10
    }
  }

  // MARK: - DMA

  private var dmaActive: Bool {
    guard control & 0x40 != 0, let dma else { return false }
    return dma.channels[1].enabled
  }

  /// Data-in bytes go to memory through channel 1 at the drive's rate.
  private var dmaClock = 0

  private func runDMA(tStates: Int) {
    guard let dma else { return }
    dmaClock += tStates
    let step = dataByteTime
    while dmaClock >= step && phase == .dataIn {
      dmaClock -= step
      if dataInIndex >= dataIn.count && !fillDataIn() {
        enterStatus()
        dmaClock = 0
        return
      }
      var channel = dma.channels[1]
      writeMemory?(channel.address, dataIn[dataInIndex])
      dataInIndex += 1
      channel.address &+= 1
      let count = channel.count & 0x3FFF
      channel.count = (channel.count & 0xC000) | ((count &- 1) & 0x3FFF)
      dma.channels[1] = channel
      if count == 0 {
        // Terminal count: with TC STOP (mode bit 5) the channel shuts off.
        dma.reachTerminalCount(channel: 1)
        if dma.modeRegister & 0x20 != 0 { dma.channels[1].enabled = false }
        if !dma.channels[1].enabled { return }
      }
    }
  }

  // MARK: - Commands

  private func execute() {
    statusByte = 0x00
    switch command[0] {
    case 0x00: testUnitReady()
    case 0x03: requestSense()
    case 0x08: read6()
    case 0x15: modeSelect6()
    case 0xD8: audioSearch()
    case 0xD9: audioPlay()
    case 0xDA: audioPause()
    case 0xDD: readSubQ()
    case 0xDE: readTOC()
    default: checkCondition(key: 0x05, code: 0x00)
    }
  }

  private func enterStatus() {
    phase = .status
    req = false
    schedule(.request, after: handshakeTime)
  }

  private func sendData(_ bytes: [UInt8]) {
    dataIn = bytes
    dataInIndex = 0
    readRemaining = 0
    phase = .dataIn
    schedule(.request, after: handshakeTime)
  }

  /// CHECK CONDITION with sense for REQUEST SENSE. The BIOS turns key and
  /// code into its error numbers at 0x11E0: key 2 with code 0x04 is 4 (not
  /// ready yet; the disc search at 0x1647 retries it), 0x0D is 7 (no disc;
  /// the CD player waits on it at 0x20ED), key 5 with a code below 0x0B is
  /// 2 (illegal request).
  private func checkCondition(key: UInt8, code: UInt8) {
    senseKey = key
    senseCode = code
    statusByte = 0x02
    enterStatus()
  }

  private func requireDisc() -> CDDisc? {
    guard let disc else {
      checkCondition(key: 0x02, code: 0x0D)
      return nil
    }
    return disc
  }

  private func testUnitReady() {
    guard requireDisc() != nil else { return }
    enterStatus()
  }

  /// The BIOS asks for ten bytes and reads the key from byte 2 and its
  /// error code from the low nibble of byte 9 (0x11E0).
  private func requestSense() {
    var sense = [UInt8](repeating: 0, count: 10)
    sense[2] = senseKey
    sense[9] = senseCode
    senseKey = 0
    senseCode = 0
    let length = command[4] == 0 ? 4 : Int(command[4])
    sendData(Array((sense + [UInt8](repeating: 0, count: max(0, length - 10))).prefix(length)))
  }

  /// READ(6): 21-bit LBA in bytes 1-3, sector count in byte 4 (0 is 256).
  /// The BIOS reads one sector at a time (0x1417).
  private func read6() {
    guard let disc = requireDisc() else { return }
    let lba = Int(command[1] & 0x1F) << 16 | Int(command[2]) << 8 | Int(command[3])
    let count = command[4] == 0 ? 256 : Int(command[4])
    guard lba + count <= disc.leadOut else {
      checkCondition(key: 0x05, code: 0x00)
      return
    }
    // One pickup: reading data ends audio play.
    if audioState != .stopped { stopAudio(.stopped) }
    dataIn = []
    dataInIndex = 0
    readLBA = lba
    readRemaining = count
    phase = .dataIn
    dmaClock = 0
    // Under DMA the bytes are paced by `runDMA`; REQ is for PIO.
    if !dmaActive { schedule(.request, after: dataByteTime) }
  }

  /// Loads the next sector of a READ into `dataIn`. False when done.
  private func fillDataIn() -> Bool {
    guard readRemaining > 0, let disc else { return false }
    var sector = [UInt8](repeating: 0, count: CDDisc.sectorBytes)
    guard disc.read(lba: readLBA, into: &sector) else { return false }
    // ECMA-130: 12 sync bytes, then the header and the user data.
    dataIn = rawSectors ? Array(sector[12..<2352]) : Array(sector[16..<(16 + 2048)])
    dataInIndex = 0
    readLBA += 1
    readRemaining -= 1
    activity = true
    return true
  }

  /// MODE SELECT(6). Before a READ with mode bit 7 clear or set the BIOS
  /// sends a parameter list (0x145F) whose only difference is byte 4, 0x03
  /// instead of 0x00, and with it the DMA count goes from 2048 to 2340
  /// bytes (0x13F4). So 0x03 there selects the 2340-byte sectors.
  ///
  /// The CDB gives the length as 10, but the BIOS sends 11 bytes, the last
  /// being its mode argument's low nibble, and then waits for the status
  /// phase (0x14C6). Were the drive to stop at 10, that eleventh write
  /// would acknowledge the status byte and leave the BIOS waiting for a
  /// status phase that has passed; so the drive takes one more byte than
  /// the CDB says. What the eleventh byte means is not known.
  private func modeSelect6() {
    dataOut = []
    guard command[4] > 0 else {
      enterStatus()
      return
    }
    dataOutLength = Int(command[4]) + 1
    phase = .dataOut
    schedule(.request, after: handshakeTime)
  }

  private func finishDataOut() {
    if command[0] == 0x15 {
      rawSectors = dataOut.count > 4 && dataOut[4] == 0x03
    }
    enterStatus()
  }

  // MARK: - Audio commands

  /// A position from a D8/D9 command. Byte 9 bits 7-6 say how bytes 2-5
  /// hold it: 0x40 is BCD minutes, seconds, frames of absolute time (the CD
  /// player's search, 0x2D0B); 0x80 is a BCD track number (0x2F06).
  ///
  /// TODO: 0x00 is not used by the BIOS or its player. It is taken here as
  /// a 32-bit LBA in bytes 2-5, unconfirmed.
  private func position(in disc: CDDisc, end: Bool) -> Int? {
    switch command[9] & 0xC0 {
    case 0x40:
      let frames = (Self.bcd(command[2]) * 60 + Self.bcd(command[3])) * CDDisc.sectorsPerSecond
        + Self.bcd(command[4])
      return frames - CDDisc.leadInFrames
    case 0x80:
      let number = Self.bcd(command[2])
      // As an end, track 0 means the end of the disc: the player asks for
      // it when the last track is playing (0x34FD).
      if end && (number == 0 || number > (disc.tracks.last?.number ?? 0)) {
        return disc.leadOut
      }
      return disc.track(number: number)?.start
    default:
      return Int(command[2]) << 24 | Int(command[3]) << 16 | Int(command[4]) << 8 | Int(command[5])
    }
  }

  /// D8: move to a position. The CD player always follows it with D9 to
  /// play (0x2D0B, 0x3480), with byte 1 bit 0 clear.
  ///
  /// TODO: byte 1 bit 0 (BIOS function 5's C bit 0) presumably starts play
  /// at once; taken that way, to the end of the disc, unconfirmed.
  private func audioSearch() {
    guard let disc = requireDisc() else { return }
    guard let lba = position(in: disc, end: false), lba >= 0, lba < disc.leadOut else {
      checkCondition(key: 0x05, code: 0x00)
      return
    }
    audioLBA = lba
    audioSample = 0
    if command[1] & 0x01 != 0 {
      audioEnd = disc.leadOut
      audioState = .playing
    } else {
      stopAudio(.paused)
    }
    enterStatus()
  }

  /// D9: play from the searched position up to an end position. BIOS
  /// function 1 sends byte 1 as 0 or 3 (0x1300); the player uses 3.
  ///
  /// TODO: what mode 0 does is not known; it is taken as stop.
  private func audioPlay() {
    guard let disc = requireDisc() else { return }
    guard let end = position(in: disc, end: true) else {
      checkCondition(key: 0x05, code: 0x00)
      return
    }
    if command[1] & 0x07 != 0 && end > audioLBA {
      audioEnd = min(end, disc.leadOut)
      audioState = .playing
    } else {
      stopAudio(.paused)
    }
    enterStatus()
  }

  /// DA: stop play where it is.
  private func audioPause() {
    if audioState == .playing { stopAudio(.paused) }
    enterStatus()
  }

  /// DD: ten bytes of sub-Q. What the CD player reads from it: byte 0 is
  /// the play state (3 when play has ended, 0x2162), byte 1 bit 6 a data
  /// track (0x2701), byte 2 the BCD track number (0x21AC), byte 5 the
  /// seconds it redraws on (0x22CD), bytes 7-8 the absolute minutes and
  /// seconds of its A-B repeat (0x2181). Byte 1 is control and ADR as on
  /// the disc, byte 3 the index, bytes 4-6 the time within the track and
  /// 7-9 the absolute time, all BCD.
  ///
  /// TODO: only byte 0's 3 is confirmed; 0 for playing and 1 for paused
  /// are assumed.
  private func readSubQ() {
    guard let disc = requireDisc() else { return }
    let lba = min(audioLBA, max(0, disc.leadOut - 1))
    let track = disc.track(at: lba)
    let relative = Self.msf(max(0, lba - track.start))
    let absolute = Self.msf(lba + CDDisc.leadInFrames)
    sendData([
      audioState.rawValue,
      (track.isAudio ? 0x00 : 0x40) | 0x01,
      Self.toBCD(track.number),
      0x01,
      relative.0, relative.1, relative.2,
      absolute.0, absolute.1, absolute.2,
    ])
  }

  /// DE: four bytes of table of contents, by byte 1. 0 is the first and
  /// last track numbers (0x2E1F); 2 is the start of the track numbered in
  /// byte 2, as absolute BCD minutes, seconds, frames, then a byte whose
  /// bit 2 marks a data track (0x1691) and which is 0 for an audio track
  /// (0x2E74); 1 is the lead-out, read as minutes and seconds (0x2ED0).
  private func readTOC() {
    guard let disc = requireDisc() else { return }
    switch command[1] {
    case 0x00:
      sendData([Self.toBCD(disc.tracks.first?.number ?? 1),
                Self.toBCD(disc.tracks.last?.number ?? 1), 0, 0])
    case 0x01:
      let t = Self.msf(disc.leadOut + CDDisc.leadInFrames)
      sendData([t.0, t.1, t.2, 0])
    case 0x02:
      guard let track = disc.track(number: Self.bcd(command[2])) else {
        checkCondition(key: 0x05, code: 0x00)
        return
      }
      let t = Self.msf(track.start + CDDisc.leadInFrames)
      sendData([t.0, t.1, t.2, track.isAudio ? 0x00 : 0x04])
    default:
      checkCondition(key: 0x05, code: 0x00)
    }
  }

  // MARK: - Audio

  private func stopAudio(_ state: AudioState) {
    audioState = state
    audioSample = 0
  }

  /// Plays at 44.1kHz in step with the CPU clock.
  private func advanceAudio(tStates: Int) {
    guard audioState == .playing, let disc else { return }
    sampleClock += tStates * 44_100
    let clock = Int(cpuClockHz)
    while sampleClock >= clock {
      sampleClock -= clock
      if audioLBA >= audioEnd || audioLBA >= disc.leadOut {
        stopAudio(.stopped)
        sampleClock = 0
        return
      }
      if audioSectorLoaded != audioLBA {
        if !disc.read(lba: audioLBA, into: &audioSector) {
          for i in 0..<audioSector.count { audioSector[i] = 0 }
        }
        audioSectorLoaded = audioLBA
      }
      let at = audioSample * 4
      let left = Int16(bitPattern: UInt16(audioSector[at]) | UInt16(audioSector[at + 1]) << 8)
      let right = Int16(bitPattern: UInt16(audioSector[at + 2]) | UInt16(audioSector[at + 3]) << 8)
      pushSample(left, right)
      audioSample += 1
      if audioSample == CDDisc.sectorBytes / 4 {
        audioSample = 0
        audioLBA += 1
      }
    }
  }

  private func pushSample(_ left: Int16, _ right: Int16) {
    if samples.count - samplesHead >= Self.samplesCap { samplesHead += 1 }
    if samplesHead > 4096 {
      samples.removeFirst(samplesHead)
      samplesHead = 0
    }
    samples.append(Int32(UInt16(bitPattern: left)) | Int32(UInt16(bitPattern: right)) << 16)
  }

  /// The next stereo sample for the sound chip, through the fader; silent
  /// when none is waiting.
  package func nextSample() -> (left: Int16, right: Int16) {
    guard samplesHead < samples.count else { return (0, 0) }
    let packed = samples[samplesHead]
    samplesHead += 1
    let left = Int(Int16(truncatingIfNeeded: packed)) * fadeLevel >> 16
    let right = Int(Int16(truncatingIfNeeded: packed >> 16)) * fadeLevel >> 16
    return (Int16(left), Int16(right))
  }

  // MARK: - Helpers

  static func bcd(_ value: UInt8) -> Int {
    Int(value >> 4) * 10 + Int(value & 0x0F)
  }

  static func toBCD(_ value: Int) -> UInt8 {
    UInt8((value / 10 % 10) << 4 | value % 10)
  }

  /// Minutes, seconds, frames in BCD.
  static func msf(_ frames: Int) -> (UInt8, UInt8, UInt8) {
    let f = frames % CDDisc.sectorsPerSecond
    let s = frames / CDDisc.sectorsPerSecond % 60
    let m = frames / CDDisc.sectorsPerSecond / 60
    return (toBCD(m), toBCD(s), toBCD(f))
  }
}

// MARK: - Save state

extension CDROMDrive {
  /// The drive's state. The disc is not included; it is mounted again by
  /// path.
  package func serializeState() -> [UInt8] {
    var w = ByteWriter()
    w.u8(1)  // layout version
    w.bool(enabled)
    w.u8(phase.rawValue)
    w.bool(req)
    w.bool(sel)
    w.u8(dataBus)
    w.int(selectionDelay)
    w.int(nextEvent)
    w.u8(pending.rawValue)
    w.bytes(command)
    w.int(commandLength)
    w.bytes(dataIn)
    w.int(dataInIndex)
    w.int(readLBA)
    w.int(readRemaining)
    w.bytes(dataOut)
    w.int(dataOutLength)
    w.u8(statusByte)
    w.u8(senseKey)
    w.u8(senseCode)
    w.bool(rawSectors)
    w.u8(control)
    w.u8(fader)
    w.int(fadeLevel)
    w.int(dmaClock)
    w.u8(audioState.rawValue)
    w.int(audioLBA)
    w.int(audioEnd)
    w.int(audioSample)
    return w.data
  }

  @discardableResult
  package func deserializeState(_ data: [UInt8]) -> Bool {
    var r = ByteReader(data)
    guard r.u8() == 1 else { return false }
    let enabled = r.bool()
    let phase = Phase(rawValue: r.u8()) ?? .busFree
    let req = r.bool()
    let sel = r.bool()
    let dataBus = r.u8()
    let selectionDelay = r.int()
    let nextEvent = r.int()
    let pending = Pending(rawValue: r.u8()) ?? .none
    let command = r.bytes()
    let commandLength = r.int()
    let dataIn = r.bytes()
    let dataInIndex = r.int()
    let readLBA = r.int()
    let readRemaining = r.int()
    let dataOut = r.bytes()
    let dataOutLength = r.int()
    let statusByte = r.u8()
    let senseKey = r.u8()
    let senseCode = r.u8()
    let rawSectors = r.bool()
    let control = r.u8()
    let fader = r.u8()
    let fadeLevel = r.int()
    let dmaClock = r.int()
    let audioState = AudioState(rawValue: r.u8()) ?? .stopped
    let audioLBA = r.int()
    let audioEnd = r.int()
    let audioSample = r.int()
    guard !r.failed, dataInIndex <= dataIn.count, (0..<588).contains(audioSample),
          pending != .execute || !command.isEmpty else { return false }

    self.enabled = enabled
    self.phase = phase
    self.req = req
    self.sel = sel
    self.dataBus = dataBus
    self.selectionDelay = selectionDelay
    self.nextEvent = nextEvent
    self.pending = pending
    self.command = command
    self.commandLength = commandLength
    self.dataIn = dataIn
    self.dataInIndex = dataInIndex
    self.readLBA = readLBA
    self.readRemaining = readRemaining
    self.dataOut = dataOut
    self.dataOutLength = dataOutLength
    self.statusByte = statusByte
    self.senseKey = senseKey
    self.senseCode = senseCode
    self.rawSectors = rawSectors
    self.control = control
    self.fader = fader
    self.fadeLevel = min(max(fadeLevel, 0), Self.fadeFull)
    fadeClock = 0
    self.dmaClock = dmaClock
    self.audioState = audioState
    self.audioLBA = audioLBA
    self.audioEnd = audioEnd
    self.audioSample = audioSample
    audioSectorLoaded = -1
    samples = []
    samplesHead = 0
    return true
  }

  /// A state from before the drive existed: power-on, drive off.
  package func restoreAbsent() {
    reset()
    enabled = false
  }
}

/// Little-endian writer for the drive's state.
private struct ByteWriter {
  var data: [UInt8] = []
  mutating func u8(_ v: UInt8) { data.append(v) }
  mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
  mutating func int(_ v: Int) {
    let u = UInt64(bitPattern: Int64(v))
    for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: u >> (8 * UInt64(i)))) }
  }
  mutating func bytes(_ v: [UInt8]) {
    int(v.count)
    data += v
  }
}

private struct ByteReader {
  let data: [UInt8]
  var position = 0
  var failed = false
  init(_ data: [UInt8]) { self.data = data }
  mutating func u8() -> UInt8 {
    guard position < data.count else { failed = true; return 0 }
    defer { position += 1 }
    return data[position]
  }
  mutating func bool() -> Bool { u8() != 0 }
  mutating func int() -> Int {
    var u: UInt64 = 0
    for i in 0..<8 { u |= UInt64(u8()) << (8 * UInt64(i)) }
    return Int(Int64(bitPattern: u))
  }
  mutating func bytes() -> [UInt8] {
    let count = int()
    guard !failed, count >= 0, position + count <= data.count else {
      failed = true
      return []
    }
    defer { position += count }
    return Array(data[position..<(position + count)])
  }
}
