import Logging

private let fdcLog = Logger(label: "EmulatorCore.UPD765A")

@inline(__always) private func hexByte(_ v: UInt8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count == 1 ? "0\(s)" : s
}

/// uPD765A FDC (Floppy Disk Controller) behavioral emulator.
///
/// Three-phase protocol: IDLE → C_PHASE → E_PHASE → R_PHASE → IDLE
///
/// Ports:
///   0xFA read  — Main Status Register
///   0xFB read  — Data Register (FDC → CPU)
///   0xFB write — Data Register (CPU → FDC)
///
/// Operates in NON-DMA mode (interrupt-driven byte transfer) as used by
/// the PC-8801 sub-CPU firmware.
public final class UPD765A {

    // MARK: - Phase Model

    public enum Phase {
        case idle
        case command   // C_PHASE: receiving command bytes
        case execution // E_PHASE: performing disk operation
        case result    // R_PHASE: sending result bytes
    }

    // MARK: - Command IDs

    package enum Command: Int {
        case readData = 1
        case readDeletedData = 2
        case readID = 4
        case writeData = 5
        case writeDeletedData = 6
        case writeID = 7      // Format Track
        case seek = 11
        case recalibrate = 12
        case senseIntStatus = 13
        case senseDriveStatus = 14
        case specify = 15
        case invalid = 16
    }

    // MARK: - Status Register Bits

    /// Main Status Register (port 0xFA)
    package static let RQM:  UInt8 = 0x80  // Request for Master (ready for transfer)
    package static let DIO:  UInt8 = 0x40  // Data direction: 1=FDC→CPU, 0=CPU→FDC
    package static let EXM:  UInt8 = 0x20  // Execution mode (NON-DMA)
    package static let CB:   UInt8 = 0x10  // FDC Busy

    /// ST0 bits
    package static let ST0_IC_NT: UInt8 = 0x00  // Normal termination
    package static let ST0_IC_AT: UInt8 = 0x40  // Abnormal termination
    package static let ST0_IC_IC: UInt8 = 0x80  // Invalid command
    package static let ST0_IC_AI: UInt8 = 0xC0  // Attention interrupt (seek end)
    package static let ST0_SE:    UInt8 = 0x20  // Seek end
    package static let ST0_NR:    UInt8 = 0x08  // Not ready
    package static let ST0_EC:    UInt8 = 0x10  // Equipment check

    /// ST1 bits
    package static let ST1_MA: UInt8 = 0x01  // Missing address mark
    package static let ST1_NW: UInt8 = 0x02  // Not writable
    package static let ST1_ND: UInt8 = 0x04  // No data
    package static let ST1_OR: UInt8 = 0x10  // Over run
    package static let ST1_DE: UInt8 = 0x20  // Data error
    package static let ST1_EN: UInt8 = 0x80  // End of cylinder

    /// ST2 bits
    package static let ST2_MD: UInt8 = 0x01  // Missing address mark in data
    package static let ST2_CM: UInt8 = 0x40  // Control mark (deleted data)

    // MARK: - State

    public package(set) var phase: Phase = .idle

    /// Current command being processed
    package var command: Command = .invalid

    /// Current command name (for diagnostics)
    public var currentCommandName: String {
        switch command {
        case .readData: return "ReadData"
        case .readDeletedData: return "ReadDelData"
        case .readID: return "ReadID"
        case .writeData: return "WriteData"
        case .writeDeletedData: return "WriteDelData"
        case .writeID: return "FormatTrack"
        case .seek: return "Seek"
        case .recalibrate: return "Recalibrate"
        case .senseIntStatus: return "SenseIntSt"
        case .senseDriveStatus: return "SenseDrvSt"
        case .specify: return "Specify"
        case .invalid: return "Invalid"
        }
    }

    /// Command parameter bytes received during C_PHASE
    package var cmdBytes: [UInt8] = []
    package var cmdBytesExpected: Int = 0

    /// Result bytes to send during R_PHASE
    public package(set) var resultBytes: [UInt8] = []
    public package(set) var resultIndex: Int = 0

    /// Data buffer for sector read/write during E_PHASE
    package var dataBuffer: [UInt8] = []
    package var dataIndex: Int = 0
    package var readByteReady: Bool = false
    package var readByteWaitClocks: Int = 0
    package var writeByteReady: Bool = false
    package var writeByteWaitClocks: Int = 0

    /// Command parameters (parsed from cmdBytes)
    package var sk: Bool = false   // Skip deleted data
    package var mf: Bool = false   // MFM mode
    package var mt: Bool = false   // Multi-track
    package var us: Int = 0        // Unit select (drive number)
    package var hd: Int = 0        // Head address
    package var chrn = (c: UInt8(0), h: UInt8(0), r: UInt8(0), n: UInt8(0))
    package var eot: UInt8 = 0     // End of track
    package var gpl: UInt8 = 0     // Gap length
    package var dtl: UInt8 = 0     // Data transfer length
    package var sc: UInt8 = 0      // Sectors per track (Format)
    package var fillByte: UInt8 = 0 // Fill byte (Format)

    /// Status registers (set during execution, returned in result)
    package var st0: UInt8 = 0
    package var st1: UInt8 = 0
    package var st2: UInt8 = 0
    package var st3: UInt8 = 0

    /// Per-drive state
    public var pcn: [UInt8] = [0, 0, 0, 0]  // Present cylinder number

    /// Seek state per drive
    package enum SeekState {
        case stopped
        case moving
        case ended
        case interrupt
    }
    package var seekState: [SeekState] = [.stopped, .stopped, .stopped, .stopped]
    /// Fast boolean flag for tick() hot path — mirrors seekState == .moving
    package var seekMoving: [Bool] = [false, false, false, false]

    /// True if any drive has an active seek in progress (needs tick() advancement).
    public var isSeeking: Bool {
        seekMoving[0] || seekMoving[1] || seekMoving[2] || seekMoving[3]
    }
    package var seekTarget: [UInt8] = [0, 0, 0, 0]  // Target cylinder
    package var seekWait: [Int] = [0, 0, 0, 0]       // Clocks until seek complete

    /// Specify parameters
    package var srtClocks: Int = 16000  // Step Rate Time in clocks (default 2ms)
    package var hutClocks: Int = 0
    package var hltClocks: Int = 0
    package var ndMode: Bool = true     // Non-DMA mode

    /// Disk exchange flags (per drive) — set when disk image is swapped.
    /// Causes the next Sense Drive Status to return without TS (Two-Sided) bit,
    /// signaling to software that the disk was changed. Cleared after one SDS query.
    /// (QUASI88: disk_ex_drv)
    public var diskExchanged: [Bool] = [false, false, false, false]

    /// Terminal Count signal
    public var tc: Bool = false

    /// Interrupt pending
    public var interruptPending: Bool = false

    /// FDC interrupt → sub CPU INT
    public var onInterrupt: (() -> Void)?

    /// Access to disk drives (via closure since D88Disk is a struct)
    public var drives: (() -> [D88Disk?])?

    /// Write sector back to disk (via closure)
    public var writeSector: ((_ drive: Int, _ track: Int, _ c: UInt8, _ h: UInt8, _ r: UInt8, _ data: [UInt8]) -> Bool)?

    /// Disk access indicator callback (drive number)
    public var onDiskAccess: ((_ drive: Int) -> Void)?

    /// Seek step callback — called each time the head moves one track (drive, currentTrack)
    public var onSeekStep: ((_ drive: Int, _ track: UInt8) -> Void)?

    /// Diagnostic: called on every readData() during execution phase.
    /// Parameters: (byte, wasReady, dataIndex, sectorIndex, bufferCount, seekMovingAny)
    public var onReadDataByte: ((_ byte: UInt8, _ wasReady: Bool, _ dataIndex: Int, _ sectorIndex: Int, _ bufferCount: Int, _ seekMovingAny: Bool) -> Void)?

    /// Rotating ReadID sector index per drive.
    /// Real hardware returns a different sector ID on each ReadID call because
    /// the head reads whichever ID header passes under it next. Some copy-protection
    /// routines (e.g. アニマルカルテット) depend on this rotation to enumerate
    /// all sector IDs on a track via a ReadID polling loop. Incremented after each
    /// successful ReadID and used modulo the current track's sector count.
    package var readIDIndex: [Int] = [0, 0, 0, 0]

    /// Remaining T-states before a pending ReadID transitions from .execution
    /// to .result phase. Models the rotational delay between sector ID
    /// headers passing under the head. Copy-protection loaders that poll
    /// ReadID from a HALT loop depend on this delay for their IRQ
    /// scheduling to settle — アニマルカルテット's sub-CPU driver at
    /// 0x70B0 can only clear its completion flag when ReadID completions
    /// are spaced roughly one sector's worth of rotation apart.
    /// Value ≈ 400 bytes × 128 T-states/byte at 2D MFM 250 kbps / 4 MHz.
    /// (The same 51200 figure also approximates the 8 MHz case well enough,
    /// since cross-CPU timing here is dominated by the disk's wall-clock
    /// rotation, not the CPU clock.)
    package var readIDWaitClocks: Int = 0
    package static let readIDBaseClocks: Int = 51200

    /// Format ID buffer for WriteID command
    package var formatIDs: [(c: UInt8, h: UInt8, r: UInt8, n: UInt8)] = []
    package var formatIDIndex: Int = 0

    // MARK: - Execution context (for CHRN calculation in finishExecution)
    package var executionSectorSize: Int = 256
    package var executionStartR: UInt8 = 0
    package var executionStartH: UInt8 = 0
    package var executionMT: Bool = false
    package var executionHD: Int = 0
    package var executionSectorSequence: [(h: Int, r: UInt8)] = []
    package var executionUsesLogicalSequence: Bool = false

    /// Full sector list for the active read command.
    /// `dataBuffer` holds only the *current* sector (see
    /// `executionCurrentSectorIndex`). When the host drains it, `readData()`
    /// advances synchronously to the next queued sector so the sub-CPU's
    /// HALT/INI loop never waits on a byte that cannot arrive. On the very
    /// last sector we instead arm `readCompletionGraceClocks` (see below) to
    /// let host software observe a brief tail of execution phase before the
    /// controller collapses into result phase. Magical DOS / LION.d88 loaders
    /// depend on that tail to keep their boot sequence on rails.
    package var executionReadSectors: [D88Disk.Sector] = []
    package var executionWriteSectors: [D88Disk.Sector] = []
    package var executionWriteTrack: Int = 0
    package var executionCurrentSectorIndex: Int = 0

    /// Countdown for the end-of-read grace period. Armed only after the host
    /// consumes the last byte of the LAST sector of a read (see `readData()`),
    /// never between sectors — those are advanced synchronously. While this
    /// is > 0 the FDC stays in execution phase with DIO/EXM/CB asserted but
    /// no RQM, so host software sees the read as still "in flight" for a
    /// brief moment after the final byte instead of an abrupt drop of DIO.
    /// Writes do not use this; they flush and finish eagerly at end-of-last-
    /// sector via `advanceExecutionWrite` / `finishWriteExecution`.
    package var readGraceClocks: Int = 0

    /// Grace-period duration in sub-CPU T-states. ~800 clocks is of the same
    /// order as the physical GAP3 traversal time between sectors on 250kbps
    /// PC-8801 media, and matches the effective inter-byte pacing BubiC
    /// applies before collapsing the read into result phase.
    package static let readCompletionGraceClocks: Int = 800

    package static let readByteClocks = 128

    // MARK: - Command Log (debugging)

    /// Log entry for FDC command tracing.
    public struct CommandLogEntry {
        public let command: String
        public let params: [UInt8]       // Raw command parameter bytes
        public let st0: UInt8
        public let st1: UInt8
        public let st2: UInt8
        public let dataSize: Int         // Bytes transferred in E_PHASE
        public let resultCHRN: (c: UInt8, h: UInt8, r: UInt8, n: UInt8)
    }

    /// Recent FDC commands (capped at commandLogMax).
    public var commandLog: [CommandLogEntry] = []

    /// Maximum command log entries.
    public var commandLogMax: Int = 200

    // MARK: - Init

    public init() {}

    public func reset() {
        phase = .idle
        command = .invalid
        cmdBytes = []
        cmdBytesExpected = 0
        resultBytes = []
        resultIndex = 0
        dataBuffer = []
        dataIndex = 0
        readByteReady = false
        readByteWaitClocks = 0
        writeByteReady = false
        writeByteWaitClocks = 0
        st0 = 0; st1 = 0; st2 = 0; st3 = 0
        pcn = [0, 0, 0, 0]
        seekState = [.stopped, .stopped, .stopped, .stopped]
        seekMoving = [false, false, false, false]
        seekTarget = [0, 0, 0, 0]
        seekWait = [0, 0, 0, 0]
        tc = false
        interruptPending = false
        diskExchanged = [false, false, false, false]
        formatIDs = []
        formatIDIndex = 0
        commandLog = []
        executionSectorSequence = []
        executionUsesLogicalSequence = false
        executionReadSectors = []
        executionWriteSectors = []
        executionWriteTrack = 0
        executionCurrentSectorIndex = 0
        readGraceClocks = 0
    }

    // MARK: - I/O Interface

    /// Read Main Status Register (port 0xFA).
    public func readStatus() -> UInt8 {
        var status: UInt8 = 0

        switch phase {
        case .idle:
            status = Self.RQM  // Ready for command

        case .command:
            status = Self.RQM | Self.CB  // Ready for next command byte

        case .execution:
            switch command {
            case .readData, .readDeletedData:
                // Read: one byte becomes ready every 128 T-states, matching QUASI88 CLOCK_BYTE().
                if dataIndex < dataBuffer.count {
                    status = Self.DIO | Self.EXM | Self.CB
                    if readByteReady {
                        status |= Self.RQM
                    }
                } else if readGraceClocks > 0 {
                    // Inside the inter-sector gap: host software should still
                    // see the read as in-execution (DIO asserted) with no byte
                    // currently ready. Matches BubiC/fmgen behavior between
                    // sectors and prevents a premature collapse into "FDC busy
                    // without DIO" that confuses Magical DOS / LION loaders.
                    status = Self.DIO | Self.EXM | Self.CB
                } else {
                    status = Self.CB
                }
            case .writeData, .writeDeletedData, .writeID:
                // Write: request one byte at a time in NON-DMA mode.
                if dataIndex < dataBufferExpectedSize {
                    status = Self.EXM | Self.CB
                    if writeByteReady {
                        status |= Self.RQM
                    }
                } else if readGraceClocks > 0 {
                    status = Self.EXM | Self.CB
                } else {
                    status = Self.CB
                }
            default:
                status = Self.CB
            }

        case .result:
            status = Self.RQM | Self.DIO | Self.CB
        }

        // Drive busy bits for seeking drives
        for i in 0..<4 {
            if case .moving = seekState[i] {
                status |= UInt8(1 << i)
            }
        }

        return status
    }

    /// Read Data Register (port 0xFB, FDC → CPU).
    public func readData() -> UInt8 {
        switch phase {
        case .execution:
            guard readByteReady, dataIndex < dataBuffer.count else {
                let seekAny = seekMoving[0] || seekMoving[1] || seekMoving[2] || seekMoving[3]
                onReadDataByte?(0xFF, false, dataIndex, executionCurrentSectorIndex, dataBuffer.count, seekAny)
                return 0xFF
            }
            let byte = dataBuffer[dataIndex]
            let seekAny2 = seekMoving[0] || seekMoving[1] || seekMoving[2] || seekMoving[3]
            onReadDataByte?(byte, true, dataIndex, executionCurrentSectorIndex, dataBuffer.count, seekAny2)
            dataIndex += 1
            readByteReady = false
            readByteWaitClocks = 0
            interruptPending = false
            if dataIndex >= dataBuffer.count {
                // End of the current sector's buffer.
                // - TC asserted mid-transfer → finish immediately.
                // - Another sector queued → advance synchronously so the
                //   sub-CPU's next HALT→IRQ wakeup has a byte to serve.
                //   If we deferred the advance, tick() could not fire the
                //   byte-ready IRQ (dataIndex == dataBuffer.count fails its
                //   guard) and the sub-CPU would deadlock in HALT. The
                //   synchronous advance bumps `executionCurrentSectorIndex`;
                //   `advanceCHRNForTC` then compensates when TC arrives at
                //   exactly the boundary (`dataIndex == 0` in the freshly
                //   loaded sector) so the result CHRN still points at the
                //   sector we actually finished reading.
                // - Final sector drained → arm the end-of-read grace period.
                //   While it counts down, readStatus() keeps DIO|EXM|CB
                //   asserted (see `readStatus()`), so host software does
                //   not see an abrupt DIO drop before the result phase.
                //   Magical DOS / LION.d88 loaders depend on this tail.
                if tc {
                    finishExecution()
                } else {
                    let nextIndex = executionCurrentSectorIndex + 1
                    if nextIndex < executionReadSectors.count {
                        loadExecutionReadSector(index: nextIndex)
                    } else {
                        readGraceClocks = Self.readCompletionGraceClocks
                    }
                }
            } else {
                // NON-DMA mode: next byte becomes ready after one byte time.
                readByteWaitClocks = Self.readByteClocks
            }
            return byte

        case .result:
            guard resultIndex < resultBytes.count else {
                phase = .idle
                return 0xFF
            }
            let byte = resultBytes[resultIndex]
            resultIndex += 1
            if resultIndex >= resultBytes.count {
                phase = .idle
            }
            return byte

        default:
            return 0xFF
        }
    }

    /// Write Data Register (port 0xFB, CPU → FDC).
    public func writeData(_ value: UInt8) {
        switch phase {
        case .idle:
            startCommand(value)

        case .command:
            cmdBytes.append(value)
            if cmdBytes.count >= cmdBytesExpected {
                parseAndExecute()
            }

        case .execution:
            // CPU providing data for write operation
            guard writeByteReady, dataIndex < dataBufferExpectedSize else { return }
            dataBuffer[dataIndex] = value
            dataIndex += 1
            writeByteReady = false
            writeByteWaitClocks = 0
            interruptPending = false
            if command == .writeID {
                handleFormatByte(value)
                if phase == .execution && dataIndex < dataBufferExpectedSize {
                    writeByteWaitClocks = Self.readByteClocks
                }
            } else if dataIndex >= dataBufferExpectedSize {
                // End of the current write sector. `advanceExecutionWrite`
                // flushes this sector to disk eagerly (the host has already
                // delivered the bytes and won't re-deliver) and then either
                // loads the next queued sector or calls `finishWriteExecution`.
                // Writes do not need an end-of-write grace period — unlike
                // reads they never assert DIO mid-transfer, so there is no
                // DIO edge for host software to misinterpret.
                advanceExecutionWrite(toNextIndex: executionCurrentSectorIndex + 1)
            } else {
                writeByteWaitClocks = Self.readByteClocks
            }

        default:
            break
        }
    }

    /// Expected size for write data buffer
    package var dataBufferExpectedSize: Int = 0

    /// Process Terminal Count signal (port 0xF8 read by sub CPU).
    public func terminalCount() {
        tc = true
        if phase == .execution {
            finishExecution()
        } else if phase == .result {
            if (command == .readData || command == .readDeletedData) &&
               (st0 & 0xC0 == Self.ST0_IC_AT) && (st1 & Self.ST1_EN != 0) {
                // TC arrived just after finishExecution — retroactively fix AT+EN to NT
                st0 = st0 & ~0xC0          // Clear IC bits → NT
                st1 = st1 & ~Self.ST1_EN   // Clear EN
                advanceCHRNForTC()          // CHRN: next sector position
                setResult7()                // Update result bytes
            }
            interruptPending = true
            onInterrupt?()
        }
    }

    // MARK: - Timing

    /// Advance FDC by T-states. Handles seek timing.
    public func tick(tStates: Int) {
        if phase == .execution &&
            (command == .readData || command == .readDeletedData) &&
            !readByteReady &&
            dataIndex < dataBuffer.count &&
            readByteWaitClocks > 0 {
            readByteWaitClocks -= tStates
            if readByteWaitClocks <= 0 {
                readByteWaitClocks = 0
                readByteReady = true
                interruptPending = true
                onInterrupt?()
            }
        }

        // End-of-read grace period countdown. Only armed after the last byte
        // of the LAST sector of a multi-sector read has been consumed (see
        // `readData()`). While this is > 0 the FDC stays in execution phase
        // with DIO+EXM+CB asserted (see `readStatus()`) so host software sees
        // the read as still "in flight", matching BubiC/fmgen behavior and
        // giving Magical DOS / LION.d88 loaders the small pause they expect
        // before the controller collapses into result phase.
        if phase == .execution &&
            (command == .readData || command == .readDeletedData) &&
            readGraceClocks > 0 &&
            dataIndex >= dataBuffer.count {
            readGraceClocks -= tStates
            if readGraceClocks <= 0 {
                readGraceClocks = 0
                finishExecution()
            }
        }

        // ReadID rotation delay: stay in execution phase until the simulated
        // next sector header rolls under the head, then transition to result.
        if phase == .execution && command == .readID && readIDWaitClocks > 0 {
            readIDWaitClocks -= tStates
            if readIDWaitClocks <= 0 {
                readIDWaitClocks = 0
                phase = .result
                interruptPending = true
                onInterrupt?()
            }
        }

        if phase == .execution &&
            (command == .writeData || command == .writeDeletedData || command == .writeID) &&
            !writeByteReady &&
            dataIndex < dataBufferExpectedSize &&
            writeByteWaitClocks > 0 {
            writeByteWaitClocks -= tStates
            if writeByteWaitClocks <= 0 {
                writeByteWaitClocks = 0
                writeByteReady = true
                interruptPending = true
                onInterrupt?()
            }
        }

        for i in 0..<4 {
            guard seekMoving[i] else { continue }
            seekWait[i] -= tStates
            while seekWait[i] <= 0 {
                if pcn[i] < seekTarget[i] {
                    pcn[i] += 1
                    onSeekStep?(i, pcn[i])
                } else if pcn[i] > seekTarget[i] {
                    pcn[i] -= 1
                    onSeekStep?(i, pcn[i])
                }

                if pcn[i] == seekTarget[i] {
                    seekState[i] = .interrupt
                    seekMoving[i] = false
                    // Suppress seek-completion interrupt while in execution phase.
                    // A spurious interrupt would wake the sub-CPU from its
                    // HALT→INI byte-read loop before the data byte is ready,
                    // causing readData() to return 0xFF (premature read).
                    // The pending seek interrupt is still recorded in seekState
                    // and will be reported by the next SenseIntStatus.
                    let inExecution = (phase == .execution)
                    if !inExecution {
                        interruptPending = true
                        onInterrupt?()
                    }
                    break
                }
                seekWait[i] += srtClocks
            }
        }
    }

    // MARK: - Command Dispatch

    private func startCommand(_ c0: UInt8) {
        // Clear TC from previous command — TC is a one-shot signal, not persistent state
        tc = false

        let cmdCode = c0 & 0x1F

        switch cmdCode {
        case 0x06: // Read Data
            command = .readData
            cmdBytesExpected = 8
        case 0x0C: // Read Deleted Data
            command = .readDeletedData
            cmdBytesExpected = 8
        case 0x05: // Write Data
            command = .writeData
            cmdBytesExpected = 8
        case 0x09: // Write Deleted Data
            command = .writeDeletedData
            cmdBytesExpected = 8
        case 0x02: // Read Diagnostic (Read Track)
            command = .readData  // treat similar
            cmdBytesExpected = 8
        case 0x0A: // Read ID
            command = .readID
            cmdBytesExpected = 1
        case 0x0D: // Write ID (Format Track)
            command = .writeID
            cmdBytesExpected = 5
        case 0x0F: // Seek
            command = .seek
            cmdBytesExpected = 2
        case 0x07: // Recalibrate
            command = .recalibrate
            cmdBytesExpected = 1
        case 0x08: // Sense Interrupt Status
            command = .senseIntStatus
            cmdBytesExpected = 0
        case 0x04: // Sense Drive Status
            command = .senseDriveStatus
            cmdBytesExpected = 1
        case 0x03: // Specify
            command = .specify
            cmdBytesExpected = 2
        default:
            // Invalid command
            command = .invalid
            st0 = Self.ST0_IC_IC
            resultBytes = [st0]
            resultIndex = 0
            phase = .result
            return
        }

        // Store c0 and extract common flags
        sk = (c0 & 0x20) != 0
        mf = (c0 & 0x40) != 0
        mt = (c0 & 0x80) != 0
        cmdBytes = []

        if cmdBytesExpected == 0 {
            parseAndExecute()
        } else {
            phase = .command
        }
    }

    private func parseAndExecute() {
        switch command {
        case .readData, .readDeletedData:
            parseReadWrite()
            executeRead()
        case .writeData, .writeDeletedData:
            parseReadWrite()
            executeWrite()
        case .readID:
            parseReadID()
            executeReadID()
        case .writeID:
            parseFormatTrack()
            executeFormatTrack()
        case .seek:
            parseSeek()
            executeSeek()
        case .recalibrate:
            parseRecalibrate()
            executeRecalibrate()
        case .senseIntStatus:
            executeSenseIntStatus()
        case .senseDriveStatus:
            parseSenseDrive()
            executeSenseDriveStatus()
        case .specify:
            parseSpecify()
            // Specify has no execution or result phase
            phase = .idle
        case .invalid:
            st0 = Self.ST0_IC_IC
            resultBytes = [st0]
            resultIndex = 0
            phase = .result
        }
    }

    // MARK: - Parameter Parsing

    private func parseReadWrite() {
        guard cmdBytes.count >= 8 else { return }
        us = Int(cmdBytes[0] & 0x03)
        hd = Int((cmdBytes[0] >> 2) & 0x01)
        chrn.c = cmdBytes[1]
        chrn.h = cmdBytes[2]
        chrn.r = cmdBytes[3]
        chrn.n = cmdBytes[4]
        eot = cmdBytes[5]
        gpl = cmdBytes[6]
        dtl = cmdBytes[7]
    }

    private func parseReadID() {
        guard cmdBytes.count >= 1 else { return }
        us = Int(cmdBytes[0] & 0x03)
        hd = Int((cmdBytes[0] >> 2) & 0x01)
    }

    private func parseFormatTrack() {
        guard cmdBytes.count >= 5 else { return }
        us = Int(cmdBytes[0] & 0x03)
        hd = Int((cmdBytes[0] >> 2) & 0x01)
        chrn.n = cmdBytes[1]
        sc = cmdBytes[2]
        gpl = cmdBytes[3]
        fillByte = cmdBytes[4]
    }

    private func parseSeek() {
        guard cmdBytes.count >= 2 else { return }
        us = Int(cmdBytes[0] & 0x03)
        hd = Int((cmdBytes[0] >> 2) & 0x01)
        seekTarget[us] = cmdBytes[1]
    }

    private func parseRecalibrate() {
        guard cmdBytes.count >= 1 else { return }
        us = Int(cmdBytes[0] & 0x03)
        seekTarget[us] = 0
    }

    private func parseSenseDrive() {
        guard cmdBytes.count >= 1 else { return }
        us = Int(cmdBytes[0] & 0x03)
        hd = Int((cmdBytes[0] >> 2) & 0x01)
    }

    private func parseSpecify() {
        guard cmdBytes.count >= 2 else { return }
        let srt = Int((cmdBytes[0] >> 4) & 0x0F)
        let hut = Int(cmdBytes[0] & 0x0F)
        let hlt = Int((cmdBytes[1] >> 1) & 0x7F)
        ndMode = (cmdBytes[1] & 0x01) != 0

        // Convert to clock cycles (at 8MHz = 8000 clocks per ms)
        srtClocks = (16 - srt) * 2 * 8000
        hutClocks = hut * 32 * 8000
        hltClocks = hlt * 4 * 8000

        logCommand("Specify", dataSize: 0)
    }

    // MARK: - Command Execution

    private func executeRead() {
        guard let disks = drives?() else {
            abortNoReady()
            return
        }

        guard us < disks.count, let disk = disks[us] else {
            abortNoReady()
            return
        }

        onDiskAccess?(us)

        // Compatibility split:
        // - Normal reads select the physical track from the current PCN, then match the on-disk
        //   CHRN ID exactly. Some software depends on the current track position even when the
        //   sector ID fields are non-standard (Final Zone uses H=0x40 on track slot 2).
        // - Titles such as LUXSOR use EOT as a logical slot count on non-1-based sector IDs,
        //   so those reads must stay on the physical PCN track and follow the D88 sector order.
        // - Some loaders in the wild tolerate stale PCN and still expect the command cylinder to
        //   win. For normal R..EOT reads we evaluate both candidates and keep the longer sequence.
        let usesLogicalSlotOrdering = eot < chrn.r
        let physicalTrack = Int(pcn[us]) * 2 + hd
        let commandTrack = Int(chrn.c) * 2 + hd

        let selectedCandidate: (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)?
        if usesLogicalSlotOrdering {
            // LUXSOR-style logical slot read: EOT < start R. Normally we only
            // look at the physical track because titles like LUXSOR rely on
            // the current PCN to pick the right D88 slot. But some other
            // loaders (e.g. ヴァルナ.d88) issue eot<r reads with a command
            // cylinder that does NOT match the current head position, and
            // they still expect the sector to be found by its on-disk ID
            // (mirroring BubiC's behavior of reading from the last Seek
            // target rather than the physical position). Fall back to the
            // command track when the physical lookup misses.
            let physicalCandidate = resolveReadCandidate(
                disk: disk,
                track: physicalTrack,
                startC: chrn.c,
                startH: chrn.h,
                startR: chrn.r,
                startN: chrn.n,
                eot: eot
            )
            if physicalCandidate != nil || commandTrack == physicalTrack {
                selectedCandidate = physicalCandidate
            } else {
                selectedCandidate = resolveReadCandidate(
                    disk: disk,
                    track: commandTrack,
                    startC: chrn.c,
                    startH: chrn.h,
                    startR: chrn.r,
                    startN: chrn.n,
                    eot: eot
                )
            }
        } else {
            let physicalCandidate = resolveReadCandidate(
                disk: disk,
                track: physicalTrack,
                startC: chrn.c,
                startH: chrn.h,
                startR: chrn.r,
                startN: chrn.n,
                eot: eot
            )
            let commandCandidate: (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)?
            if commandTrack == physicalTrack {
                commandCandidate = physicalCandidate
            } else {
                commandCandidate = resolveReadCandidate(
                    disk: disk,
                    track: commandTrack,
                    startC: chrn.c,
                    startH: chrn.h,
                    startR: chrn.r,
                    startN: chrn.n,
                    eot: eot
                )
            }
            selectedCandidate = preferredReadCandidate(physicalCandidate, commandCandidate)
        }

        if let selectedCandidate {
            let sector = selectedCandidate.sector
            st0 = UInt8(us) | UInt8(hd << 2)
            st1 = 0
            st2 = 0

            // Check for deleted data mark
            if sector.deleted {
                st2 |= Self.ST2_CM
                if command == .readData && sk {
                    // Skip deleted — try next sector
                    // For simplicity, just return this sector
                }
            }

            // Check sector status from D88 image
            if sector.status != 0 {
                st1 |= Self.ST1_DE
                st0 |= Self.ST0_IC_AT
            }

            // N-mismatch: command's N disagreed with the selected sector's
            // recorded N. Real uPD765A pads the transfer from the gap and
            // fails CRC → ST1_DE. resolveReadCandidate already padded the
            // sector data to cmd size.
            if sector.n != chrn.n {
                st1 |= Self.ST1_DE
                st0 |= Self.ST0_IC_AT
            }

            executionReadSectors = selectedCandidate.sequence
            executionSectorSequence = selectedCandidate.sequence.map { (h: Int($0.h), r: $0.r) }
            executionUsesLogicalSequence = selectedCandidate.usedLogicalSlot

            // MT (Multi-Track): after reading head 0, continue with head 1
            if mt && hd == 0 && !tc {
                let d88TrackH1 = (selectedCandidate.track & ~1) | 1
                if d88TrackH1 < disk.tracks.count,
                   let head1Start = disk.tracks[d88TrackH1].first(where: { $0.c == chrn.c }) {
                    let head1Resolution = resolveReadSequence(
                        sectors: disk.tracks[d88TrackH1],
                        startC: chrn.c,
                        startH: head1Start.h,
                        startR: head1Start.r,
                        startN: head1Start.n,
                        eot: eot
                    )
                    executionReadSectors.append(contentsOf: head1Resolution.sectors)
                    executionSectorSequence.append(contentsOf: head1Resolution.sectors.map { (h: Int($0.h), r: $0.r) })
                    executionUsesLogicalSequence = executionUsesLogicalSequence || head1Resolution.usedLogicalSlot
                }
            }

            // Save execution context for CHRN calculation in finishExecution.
            // (`executionSectorSize` is re-derived from the currently loaded
            // sector inside `loadExecutionReadSector`, so we don't set it
            // here.)
            executionStartR = chrn.r
            executionStartH = chrn.h
            executionMT = mt
            executionHD = hd
            executionCurrentSectorIndex = 0
            readGraceClocks = 0

            phase = .execution
            // Per-sector buffering: load only the first sector into dataBuffer.
            // Subsequent sectors are loaded synchronously in `readData()` as
            // the host drains each buffer (see its end-of-sector branch).
            // `loadExecutionReadSector` already asserts RQM+interruptPending
            // and calls `onInterrupt`, so there is no extra wake-up to do.
            loadExecutionReadSector(index: 0)
            let totalBytes = executionReadSectors.reduce(0) { $0 + $1.data.count }
            logCommand("ReadData", dataSize: totalBytes)
            fdcLog.debug("FDC ReadData: drive=\(us) track=\(selectedCandidate.track) C=\(chrn.c) H=\(chrn.h) R=\(chrn.r) \(totalBytes) bytes across \(executionReadSectors.count) sector(s)")
        } else {
            // Sector not found. BubiC distinguishes:
            //   - cy == -1 (no sectors on track)      -> ST0_AT | ST1_MA
            //   - cy != id[0] (cylinder mismatch)     -> ST0_AT | ST1_ND | (ST2_BC|NC)
            //   - cy == id[0] (C matches, R/N miss)  -> ST0_AT | ST1_ND
            // F2グランプリSR's copy-protection probe distinguishes ST1=ND vs
            // ST1=ND|MA — returning MA here makes the protection reject the
            // disk. Match BubiC: ST1_ND only when the track has sectors but
            // no ID matches.
            st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT
            if disk.tracks.indices.contains(physicalTrack),
               !disk.tracks[physicalTrack].isEmpty {
                st1 = Self.ST1_ND
            } else {
                st1 = Self.ST1_MA
            }
            st2 = 0
            setResult7()
            phase = .result
            interruptPending = true
            onInterrupt?()
            logCommand("ReadData:NOTFOUND", dataSize: 0)
            fdcLog.warning("FDC ReadData: sector NOT FOUND drive=\(us) pcnTrack=\(physicalTrack) cmdTrack=\(commandTrack) C=\(chrn.c) H=\(chrn.h) R=\(chrn.r)")
        }
    }

    private func executeWrite() {
        guard let disks = drives?() else {
            abortNoReady()
            return
        }

        guard us < disks.count, let disk = disks[us] else {
            abortNoReady()
            return
        }

        onDiskAccess?(us)

        // Check write protection
        if disk.writeProtected {
            st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT
            st1 = Self.ST1_NW
            st2 = 0
            setResult7()
            phase = .result
            interruptPending = true
            onInterrupt?()
            logCommand("WriteData:WP", dataSize: 0)
            return
        }

        let d88Track = Int(chrn.c) * 2 + hd

        // Resolve the multi-sector write sequence via the same R..EOT walk as
        // reads, so duplicate/missing sector handling stays consistent.
        let writeCandidate = resolveWriteSequence(
            disk: disk,
            track: d88Track,
            startC: chrn.c,
            startH: UInt8(hd),
            startR: chrn.r,
            startN: chrn.n,
            eot: eot
        )
        if let writeCandidate {
            st0 = UInt8(us) | UInt8(hd << 2)
            st1 = 0; st2 = 0

            executionWriteTrack = writeCandidate.track
            executionWriteSectors = writeCandidate.sectors
            executionSectorSequence = writeCandidate.sectors.map { (h: Int($0.h), r: $0.r) }
            executionCurrentSectorIndex = 0
            executionStartR = chrn.r
            executionStartH = chrn.h
            executionMT = mt
            executionHD = hd
            readGraceClocks = 0
            phase = .execution
            // Per-sector buffering: accept bytes for one sector at a time.
            loadExecutionWriteSector(index: 0)
            let totalBytes = executionWriteSectors.reduce(0) { $0 + $1.data.count }
            logCommand("WriteData", dataSize: totalBytes)
            fdcLog.debug("FDC WriteData: drive=\(us) C=\(chrn.c) H=\(hd) R=\(chrn.r) expecting \(totalBytes) bytes across \(executionWriteSectors.count) sector(s)")
        } else {
            st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT
            st1 = Self.ST1_ND | Self.ST1_MA
            st2 = 0
            setResult7()
            phase = .result
            interruptPending = true
            onInterrupt?()
        }
    }

    /// Collect the list of sectors that a WriteData command should target,
    /// walking R..EOT on the physical track and tolerating duplicate R values
    /// with different N the same way the read path does.
    private func resolveWriteSequence(
        disk: D88Disk,
        track: Int,
        startC: UInt8,
        startH: UInt8,
        startR: UInt8,
        startN: UInt8,
        eot: UInt8
    ) -> (track: Int, sectors: [D88Disk.Sector])? {
        guard track >= 0, track < disk.tracks.count else { return nil }
        guard let first = disk.findSector(track: track, c: startC, h: startH, r: startR, n: startN) else {
            return nil
        }
        var sectors: [D88Disk.Sector] = [first]
        var nextR = startR
        while nextR < eot {
            nextR &+= 1
            if let next = disk.findSector(track: track, c: startC, h: startH, r: nextR, n: startN) {
                sectors.append(next)
            } else if let anyN = disk.findSector(track: track, c: startC, h: startH, r: nextR) {
                sectors.append(anyN)
            } else {
                break
            }
        }
        return (track, sectors)
    }

    /// Flush the just-filled write sector to the disk image and advance the
    /// write pipeline. If another sector is queued (and TC is not asserted)
    /// load it synchronously so host software observes one continuous write.
    /// Otherwise transition directly to result phase via
    /// `finishWriteExecution`. There is no end-of-write grace period — see
    /// the comment in `writeData()` for the rationale.
    private func advanceExecutionWrite(toNextIndex nextIndex: Int) {
        guard executionCurrentSectorIndex < executionWriteSectors.count else {
            finishWriteExecution()
            return
        }
        let sector = executionWriteSectors[executionCurrentSectorIndex]
        let sectorData = Array(dataBuffer.prefix(dataBufferExpectedSize))
        _ = writeSector?(
            us,
            executionWriteTrack,
            sector.c,
            sector.h,
            sector.r,
            sectorData
        )

        if nextIndex < executionWriteSectors.count && !tc {
            loadExecutionWriteSector(index: nextIndex)
        } else {
            finishWriteExecution()
        }
    }

    private func executeReadID() {
        guard let disks = drives?() else {
            abortNoReady()
            return
        }

        guard us < disks.count, let disk = disks[us] else {
            abortNoReady()
            return
        }

        let d88Track = Int(pcn[us]) * 2 + hd

        // Pick the next sector ID on the current track. Real hardware rotates
        // through IDs as the disk spins; some protection routines enumerate all
        // IDs by calling ReadID in a loop.
        guard d88Track < disk.tracks.count else {
            st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT
            st1 = Self.ST1_MA
            st2 = 0
            chrn = (c: pcn[us], h: UInt8(hd), r: 1, n: 1)
            setResult7()
            phase = .result
            interruptPending = true
            return
        }
        let sectors = disk.tracks[d88Track]
        guard !sectors.isEmpty else {
            st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT
            st1 = Self.ST1_MA
            st2 = 0
            chrn = (c: pcn[us], h: UInt8(hd), r: 1, n: 1)
            setResult7()
            phase = .result
            interruptPending = true
            return
        }
        let idx = readIDIndex[us] % sectors.count
        let sector = sectors[idx]
        readIDIndex[us] = (idx + 1) % sectors.count

        st0 = UInt8(us) | UInt8(hd << 2)
        st1 = 0; st2 = 0
        chrn = (c: sector.c, h: sector.h, r: sector.r, n: sector.n)
        setResult7()

        // Model rotation delay: sub-CPU loader loops may depend on the gap
        // between sector ID headers passing under the head. Enter execution
        // phase with a countdown; tick() completes the command later.
        phase = .execution
        readIDWaitClocks = Self.readIDBaseClocks
        logCommand("ReadID", dataSize: 0)
    }

    private func executeFormatTrack() {
        // Receive 4 bytes per sector (C, H, R, N) × sc sectors
        formatIDs = []
        formatIDIndex = 0
        let expectedSize = Int(sc) * 4
        dataBuffer = [UInt8](repeating: 0, count: expectedSize)
        dataIndex = 0
        dataBufferExpectedSize = expectedSize
        phase = .execution
        writeByteReady = true
        writeByteWaitClocks = 0
        interruptPending = true
    }

    private func handleFormatByte(_ value: UInt8) {
        // Accumulate 4 bytes per sector ID
        if dataIndex % 4 == 0 && dataIndex > 0 {
            let base = dataIndex - 4
            formatIDs.append((
                c: dataBuffer[base],
                h: dataBuffer[base + 1],
                r: dataBuffer[base + 2],
                n: dataBuffer[base + 3]
            ))
        }
        if dataIndex >= dataBufferExpectedSize {
            // Parse last ID
            if dataIndex >= 4 {
                let base = dataIndex - 4
                formatIDs.append((
                    c: dataBuffer[base],
                    h: dataBuffer[base + 1],
                    r: dataBuffer[base + 2],
                    n: dataBuffer[base + 3]
                ))
            }
            finishFormatExecution()
        }
    }

    private func finishFormatExecution() {
        writeByteReady = false
        writeByteWaitClocks = 0
        st0 = UInt8(us) | UInt8(hd << 2)
        st1 = 0; st2 = 0
        chrn = formatIDs.last.map { (c: $0.c, h: $0.h, r: $0.r, n: $0.n) }
            ?? (c: 0, h: 0, r: 0, n: 0)
        // Format is not actually written to disk image (stub)
        setResult7()
        phase = .result
        interruptPending = true
        onInterrupt?()
    }

    private func executeSeek() {
        logCommand("Seek", dataSize: 0)
        fdcLog.debug("FDC Seek: drive=\(us) pcn=\(pcn[us])→\(seekTarget[us])")
        if seekTarget[us] == pcn[us] {
            // Already at target
            seekState[us] = .interrupt
            interruptPending = true
            onInterrupt?()
        } else {
            seekState[us] = .moving
            seekMoving[us] = true
            seekWait[us] = srtClocks
        }
        phase = .idle
    }

    private func executeRecalibrate() {
        logCommand("Recalibrate", dataSize: 0)
        fdcLog.debug("FDC Recalibrate: drive=\(us) pcn=\(pcn[us])")
        seekTarget[us] = 0
        if pcn[us] == 0 {
            seekState[us] = .interrupt
            interruptPending = true
            onInterrupt?()
        } else {
            seekState[us] = .moving
            seekMoving[us] = true
            seekWait[us] = srtClocks
        }
        phase = .idle
    }

    private func executeSenseIntStatus() {
        // Find drive with interrupt pending
        var foundDrive: Int? = nil
        for i in 0..<4 {
            if case .interrupt = seekState[i] {
                foundDrive = i
                break
            }
        }

        if let drv = foundDrive {
            seekState[drv] = .stopped
            // ST0: Seek End + unit
            st0 = UInt8(drv) | Self.ST0_SE
            resultBytes = [st0, pcn[drv]]
            // Only clear interruptPending if no other drives have pending interrupts
            var morePending = false
            for i in 0..<4 {
                if case .interrupt = seekState[i] { morePending = true; break }
            }
            if !morePending {
                interruptPending = false
            }
            fdcLog.debug("FDC SenseIntStatus: drive=\(drv) pcn=\(pcn[drv]) morePending=\(morePending)")
        } else {
            // No interrupt pending
            st0 = Self.ST0_IC_IC  // Invalid
            resultBytes = [st0, pcn[0]]
            fdcLog.debug("FDC SenseIntStatus: no pending interrupt")
        }

        logCommand("SenseIntStatus", dataSize: 0)
        resultIndex = 0
        phase = .result
    }

    private func executeSenseDriveStatus() {
        st3 = UInt8(us)
        if hd != 0 { st3 |= 0x04 }  // HD

        let disks = drives?() ?? []
        let diskInserted = us < disks.count && disks[us] != nil
        let writeProtected = diskInserted && (disks[us]?.writeProtected ?? false)

        if diskExchanged[us] {
            // Disk was just swapped — return Ready but WITHOUT Two-Sided/WP.
            // (QUASI88: disk_ex_drv toggle)
            diskExchanged[us] = false
            if diskInserted { st3 |= 0x20 }  // Ready
            if pcn[us] == 0 { st3 |= 0x10 }  // Track 0
        } else {
            // BubiC (upd765a.cpp:697): TS is always asserted when the drive
            // exists, regardless of disk presence. Real 2HD drives report TS
            // from the drive itself, not from the media. N-BASIC's cold-boot
            // Sense-Drive-Status poll hangs forever if TS is gated on media.
            st3 |= 0x08  // Two-sided (drive capability)
            if pcn[us] == 0 { st3 |= 0x10 }  // Track 0
            if diskInserted { st3 |= 0x20 }  // Ready
            if writeProtected { st3 |= 0x40 }
        }

        logCommand("SenseDriveStatus", dataSize: 0)
        resultBytes = [st3]
        resultIndex = 0
        phase = .result
    }

    // MARK: - Execution Completion

    private func finishExecution() {
        let wasTC = tc
        tc = false
        readByteReady = false
        readByteWaitClocks = 0
        writeByteReady = false
        writeByteWaitClocks = 0
        readGraceClocks = 0

        switch command {
        case .readData, .readDeletedData:
            if wasTC {
                // TC received: normal termination, advance CHRN to next sector
                advanceCHRNForTC()
            } else {
                // All data consumed (EOT reached): abnormal termination + End of Cylinder
                st0 |= Self.ST0_IC_AT
                st1 |= Self.ST1_EN
                advanceCHRNForEOT()
            }
            setResult7()
            phase = .result
            interruptPending = true
            fdcLog.debug("FDC finishExecution: ReadData complete, ST0=\(hexByte(st0)) ST1=\(hexByte(st1))")
            onInterrupt?()

        case .writeData, .writeDeletedData:
            finishWriteExecution()

        default:
            phase = .idle
        }
    }

    private func finishWriteExecution() {
        writeByteReady = false
        writeByteWaitClocks = 0
        readGraceClocks = 0

        // `finishWriteExecution` runs in two cases, both of which have
        // already committed their final sector before reaching us:
        //
        //   1. Normal completion: `writeData` drained the last sector, called
        //      `advanceExecutionWrite`, which flushed the sector to disk and
        //      then called us.
        //   2. TC mid-command: `terminalCount` → `finishExecution` →
        //      `finishWriteExecution`. If the host happened to land TC right
        //      at a sector boundary (dataIndex == dataBufferExpectedSize),
        //      `writeData` had already flushed via `advanceExecutionWrite`
        //      in the same synchronous step. If TC landed mid-sector, the
        //      partial buffer is discarded (matches the "host wants done now"
        //      semantics of TC — partial sector writes are not well defined).
        //
        // So we just mark the sector we stopped on in `chrn` for the result
        // bytes and transition to result phase. No redundant re-flush.
        if !executionWriteSectors.isEmpty {
            let idx = min(executionCurrentSectorIndex, executionWriteSectors.count - 1)
            let sector = executionWriteSectors[idx]
            chrn = (c: sector.c, h: sector.h, r: sector.r, n: sector.n)
        }

        st0 = UInt8(us) | UInt8(hd << 2)
        st1 = 0; st2 = 0
        setResult7()
        phase = .result
        interruptPending = true
        onInterrupt?()
    }

    // MARK: - CHRN Advancement

    private func resolveReadSequence(
        sectors: [D88Disk.Sector],
        startC: UInt8,
        startH: UInt8,
        startR: UInt8,
        startN: UInt8,
        eot: UInt8
    ) -> (sectors: [D88Disk.Sector], usedLogicalSlot: Bool) {
        // LUXSOR-style "logical slot" reads (eot < startR) treat EOT as a slot
        // index and tolerate N mismatch — the loader relies on the FDC to pick
        // the nth sector on the track regardless of its recorded size.
        //
        // Prefer exact C/H/R/N match; fall back to C/H/R-only match (N
        // mismatch) so that copy-protection probes (F2グランプリSR: R=2 N=2 on
        // R=2 N=1 disk, マイト&マジック: R=1 N=3 on R=1 N=1 track) enter the
        // execution phase — real uPD765A reads whatever data sits at the
        // matched sector, pads the transfer to 2^(cmdN+7) bytes, and fails
        // CRC. The caller (resolveReadCandidate/executeRead) marks ST1_DE.
        let allowNMismatch = eot < startR
        guard !tc,
              let startIndex = sectors.firstIndex(where: {
                  $0.c == startC && $0.h == startH && $0.r == startR && $0.n == startN
              }) ?? sectors.firstIndex(where: {
                  $0.c == startC && $0.h == startH && $0.r == startR
              }) else {
            let startSector = sectors.first(where: {
                $0.c == startC && $0.h == startH && $0.r == startR && $0.n == startN
            }).map { [$0] } ?? []
            return (startSector, false)
        }

        let startSector = sectors[startIndex]

        if allowNMismatch {
            // Logical slot path: consume D88 sectors in physical order.
            let logicalEndIndex = min(Int(eot) - 1, sectors.count - 1)
            guard logicalEndIndex >= startIndex else {
                return ([startSector], false)
            }
            return (Array(sectors[startIndex...logicalEndIndex]), true)
        }

        var sequence = [startSector]
        // Use Int for loop variable to avoid UInt8 overflow when eot == 0xFF
        // (some loaders, e.g. LION.d88, pass eot=0xFF as "read to end of track").
        var nextR = Int(startR) + 1
        while nextR <= Int(eot) {
            let r = UInt8(nextR)
            if let nextSector = sectors.first(where: {
                $0.c == startC && $0.h == startH && $0.r == r && $0.n == startN
            }) {
                sequence.append(nextSector)
            } else {
                break
            }
            nextR += 1
        }
        return (sequence, false)
    }

    private func resolveReadCandidate(
        disk: D88Disk,
        track: Int,
        startC: UInt8,
        startH: UInt8,
        startR: UInt8,
        startN: UInt8,
        eot: UInt8
    ) -> (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)? {
        let allowNMismatch = eot < startR
        guard track >= 0, track < disk.tracks.count else { return nil }
        // Prefer an exact C/H/R/N match. Fall back to C/H/R-only (N
        // mismatch) so copy-protection probes enter the execution phase —
        // real uPD765A can't infer data-field length from the ID alone, so
        // it reads anyway, pads the transfer with post-data gap bytes up to
        // 2^(cmdN+7), and fails CRC. executeRead marks ST1_DE when the
        // selected sector's N differs from the command's N.
        let exactMatch = disk.tracks[track].first(where: {
            $0.c == startC && $0.h == startH && $0.r == startR && $0.n == startN
        })
        let sector: D88Disk.Sector?
        if let exactMatch {
            sector = exactMatch
        } else if allowNMismatch {
            sector = disk.findSector(track: track, c: startC, h: startH, r: startR, n: startN)
        } else if let chrMatch = disk.tracks[track].first(where: {
            $0.c == startC && $0.h == startH && $0.r == startR
        }) {
            let cmdSize = 0x80 << min(Int(startN), 7)
            if chrMatch.data.count < cmdSize {
                var padded = chrMatch
                let synth = rawTrackContinuationBytes(
                    sectors: disk.tracks[track],
                    diskType: disk.diskType,
                    startSector: chrMatch,
                    targetByteCount: cmdSize
                )
                padded.data = synth ?? chrMatch.data + [UInt8](repeating: 0xFF, count: cmdSize - chrMatch.data.count)
                sector = padded
            } else {
                sector = chrMatch
            }
        } else {
            sector = nil
        }
        guard let sector else { return nil }
        let resolution = resolveReadSequence(
            sectors: disk.tracks[track],
            startC: startC,
            startH: startH,
            startR: startR,
            startN: startN,
            eot: eot
        )
        guard !resolution.sectors.isEmpty else { return nil }
        // When we padded the starting sector, substitute the padded copy into
        // the sequence so readByte() transfers the full cmd-N length.
        var sequence = resolution.sectors
        if sequence.first?.data.count != sector.data.count {
            sequence[0] = sector
        }
        return (track, sector, sequence, resolution.usedLogicalSlot)
    }

    // When a command reads with N larger than the recorded data field, a real
    // uPD765A keeps clocking post-data gap/ID/next-sector bytes until the
    // transfer length is met, then reports CRC error. Might & Magic's copy-
    // protection probe on track 79 relies on that continuation pattern. D88
    // does not store raw track bytes, so we synthesize a plausible MFM layout
    // (IDAM + CHRN + CRC + gap2 + DAM + data + CRC + gap3) from the sector
    // list and read forward from the matched sector's data field.
    private func rawTrackContinuationBytes(
        sectors: [D88Disk.Sector],
        diskType: D88Disk.DiskType,
        startSector: D88Disk.Sector,
        targetByteCount: Int
    ) -> [UInt8]? {
        guard targetByteCount > 0 else { return [] }
        guard let startIndex = sectors.firstIndex(where: {
            $0.c == startSector.c && $0.h == startSector.h && $0.r == startSector.r && $0.n == startSector.n
        }) else { return nil }
        let layout = synthesizeMFMTrack(sectors: sectors, diskType: diskType)
        guard startIndex < layout.dataPositions.count, !layout.bytes.isEmpty else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(targetByteCount)
        var position = layout.dataPositions[startIndex]
        while bytes.count < targetByteCount {
            bytes.append(layout.bytes[position])
            position += 1
            if position >= layout.bytes.count { position = 0 }
        }
        return bytes
    }

    private struct SyntheticTrack {
        var bytes: [UInt8]
        var dataPositions: [Int]
    }

    private func synthesizeMFMTrack(sectors: [D88Disk.Sector], diskType: D88Disk.DiskType) -> SyntheticTrack {
        let syncSize = 12
        let amSize = 3
        let gap0Size = 80
        let gap1Size = 50
        let gap2Size = 22
        let gapData: UInt8 = 0x4E
        let trackSize = diskType == .twoHD ? 10410 : 6250
        let refSize = sectors.last?.data.count ?? 0
        let gap3Size = estimatedGap3(diskType: diskType, sectorSize: refSize, sectorCount: sectors.count)

        var dataPositions = Array(repeating: 0, count: sectors.count)
        let preamble = gap0Size + syncSize + (amSize + 1) + gap1Size
        var total = preamble
        for (index, sector) in sectors.enumerated() {
            total += syncSize + (amSize + 1) + 4 + 2 + gap2Size
            if sector.data.count > 0 {
                total += syncSize + (amSize + 1)
                dataPositions[index] = total
                total += sector.data.count + 2 + gap3Size
            } else {
                dataPositions[index] = total
            }
        }

        var bytes = [UInt8](repeating: gapData, count: max(total, trackSize))

        var q = gap0Size
        for _ in 0..<syncSize { bytes[q] = 0x00; q += 1 }
        for _ in 0..<amSize { bytes[q] = 0xC2; q += 1 }
        bytes[q] = 0xFC

        var p = preamble
        for sector in sectors {
            for _ in 0..<syncSize { bytes[p] = 0x00; p += 1 }
            var crc: UInt16 = 0xFFFF
            for _ in 0..<amSize { bytes[p] = 0xA1; p += 1; crc = crc16(crc, 0xA1) }
            bytes[p] = 0xFE; p += 1; crc = crc16(crc, 0xFE)
            for byte in [sector.c, sector.h, sector.r, sector.n] {
                bytes[p] = byte; p += 1; crc = crc16(crc, byte)
            }
            bytes[p] = UInt8(crc >> 8); p += 1
            bytes[p] = UInt8(crc & 0xFF); p += 1
            p += gap2Size

            guard sector.data.count > 0 else { continue }

            for _ in 0..<syncSize { bytes[p] = 0x00; p += 1 }
            crc = 0xFFFF
            for _ in 0..<amSize { bytes[p] = 0xA1; p += 1; crc = crc16(crc, 0xA1) }
            let dam: UInt8 = sector.deleted ? 0xF8 : 0xFB
            bytes[p] = dam; p += 1; crc = crc16(crc, dam)
            for byte in sector.data {
                bytes[p] = byte; p += 1; crc = crc16(crc, byte)
            }
            bytes[p] = UInt8(crc >> 8); p += 1
            bytes[p] = UInt8(crc & 0xFF); p += 1
            p += gap3Size
        }

        return SyntheticTrack(bytes: bytes, dataPositions: dataPositions)
    }

    private func estimatedGap3(diskType: D88Disk.DiskType, sectorSize: Int, sectorCount: Int) -> Int {
        switch (diskType, sectorSize, sectorCount) {
        case (.twoHD, 256, 26): return 54
        case (.twoHD, 512, 15): return 84
        case (.twoHD, 1024, 8): return 116
        case (_, 256, 16): return 51
        case (_, 512, 9): return 80
        case (_, 1024, 5): return 116
        default: return 32
        }
    }

    private func crc16(_ crc: UInt16, _ byte: UInt8) -> UInt16 {
        var c = crc ^ (UInt16(byte) << 8)
        for _ in 0..<8 {
            c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1
        }
        return c
    }

    private func preferredReadCandidate(
        _ lhs: (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)?,
        _ rhs: (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)?
    ) -> (track: Int, sector: D88Disk.Sector, sequence: [D88Disk.Sector], usedLogicalSlot: Bool)? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            let lhsBytes = lhs.sequence.reduce(0) { $0 + $1.data.count }
            let rhsBytes = rhs.sequence.reduce(0) { $0 + $1.data.count }
            return lhsBytes >= rhsBytes ? lhs : rhs
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    /// Advance CHRN when TC is received during read (QUASI88 fdc_next_chrn(TRUE) equivalent).
    /// Advance CHRN after TC — matches QUASI88 fdc_next_chrn(TRUE).
    /// TC terminates at the current sector; result CHRN points to the NEXT sector.
    /// In the per-sector model we synchronously advance
    /// `executionCurrentSectorIndex` when the host drains the current buffer
    /// (to avoid a byte-ready deadlock), so the "current" index can actually
    /// point one sector past the one that was just finished if TC arrives
    /// right at that boundary (dataIndex == 0 in the freshly loaded sector).
    /// Detect that case and step the effective sector index back by one.
    private func advanceCHRNForTC() {
        var sectorIndex = max(0, executionCurrentSectorIndex)
        if dataIndex == 0 && sectorIndex > 0 {
            sectorIndex -= 1
        }

        if !executionSectorSequence.isEmpty {
            let currentIndex = min(sectorIndex, executionSectorSequence.count - 1)
            if currentIndex + 1 < executionSectorSequence.count {
                let next = executionSectorSequence[currentIndex + 1]
                chrn.h = UInt8(next.h)
                chrn.r = next.r
            } else {
                if executionUsesLogicalSequence {
                    chrn.c += 1
                    chrn.h = executionMT ? UInt8(executionHD ^ 1) : executionStartH
                    chrn.r = 1
                    return
                }
            }
            if executionUsesLogicalSequence {
                return
            }
        }

        var currentR = Int(executionStartR) + sectorIndex
        var currentH = executionHD

        // MT: if we've passed head 0's EOT, we're on head 1
        if executionMT && executionHD == 0 {
            let head0Max = Int(eot) - Int(executionStartR) + 1
            if sectorIndex >= head0Max {
                currentH = 1
                currentR = sectorIndex - head0Max + 1
            }
        }

        // Advance to NEXT sector (QUASI88: fdc_next_chrn with_TC=TRUE)
        if !executionMT {
            // Non-MT
            if currentR >= Int(eot) {
                chrn.c += 1
                chrn.r = 1
            } else {
                chrn.r = UInt8(currentR + 1)
            }
            chrn.h = executionStartH
        } else {
            // MT mode
            if currentH == 0 {
                if currentR >= Int(eot) {
                    // Head 0 at EOT: switch to head 1, R=1
                    chrn.h = UInt8(executionHD ^ 1)
                    chrn.r = 1
                } else {
                    chrn.h = UInt8(currentH)
                    chrn.r = UInt8(currentR + 1)
                }
            } else {
                // Head 1
                if currentR >= Int(eot) {
                    chrn.h = UInt8(currentH ^ 1)
                    chrn.c += 1
                    chrn.r = 1
                } else {
                    chrn.h = UInt8(currentH)
                    chrn.r = UInt8(currentR + 1)
                }
            }
        }
    }

    /// Set CHRN after EOT (all data consumed, no TC).
    /// QUASI88: fdc_next_chrn(FALSE) at R==EOT leaves R unchanged.
    private func advanceCHRNForEOT() {
        if executionUsesLogicalSequence, let last = executionSectorSequence.last {
            chrn.h = UInt8(last.h)
            chrn.r = last.r
            return
        }
        if executionMT && executionHD == 0 {
            // MT read started on head 0: ended on head 1 at EOT
            chrn.h = 1
        }
        chrn.r = eot
    }

    // MARK: - Helpers

    /// Set 7-byte result: ST0, ST1, ST2, C, H, R, N
    private func setResult7() {
        resultBytes = [st0, st1, st2, chrn.c, chrn.h, chrn.r, chrn.n]
        resultIndex = 0
    }

    /// Load one sector from `executionReadSectors` into `dataBuffer` for NON-DMA
    /// transfer to the host. Called at the start of a read command and again
    /// after each inter-sector gap. Fires a byte-ready IRQ because the first
    /// byte of the new sector is immediately available.
    private func loadExecutionReadSector(index: Int) {
        guard index >= 0, index < executionReadSectors.count else {
            dataBuffer = []
            dataIndex = 0
            readByteReady = false
            readByteWaitClocks = 0
            return
        }
        executionCurrentSectorIndex = index
        let sector = executionReadSectors[index]
        dataBuffer = sector.data
        dataIndex = 0
        executionSectorSize = max(1, sector.data.count)
        readByteReady = !dataBuffer.isEmpty
        readByteWaitClocks = 0
        interruptPending = true
        onInterrupt?()
    }

    /// Load one sector's worth of target storage into `dataBuffer` for NON-DMA
    /// transfer from the host. Mirrors `loadExecutionReadSector` for writes.
    private func loadExecutionWriteSector(index: Int) {
        guard index >= 0, index < executionWriteSectors.count else {
            dataBuffer = []
            dataIndex = 0
            dataBufferExpectedSize = 0
            writeByteReady = false
            writeByteWaitClocks = 0
            return
        }
        executionCurrentSectorIndex = index
        let sector = executionWriteSectors[index]
        dataBuffer = [UInt8](repeating: 0, count: sector.data.count)
        dataIndex = 0
        dataBufferExpectedSize = sector.data.count
        writeByteReady = true
        writeByteWaitClocks = 0
        interruptPending = true
        onInterrupt?()
    }

    private func logCommand(_ name: String, dataSize: Int) {
        guard commandLog.count < commandLogMax else { return }
        commandLog.append(CommandLogEntry(
            command: name,
            params: cmdBytes,
            st0: st0, st1: st1, st2: st2,
            dataSize: dataSize,
            resultCHRN: chrn
        ))
    }

    private func abortNoReady() {
        st0 = UInt8(us) | UInt8(hd << 2) | Self.ST0_IC_AT | Self.ST0_NR
        st1 = 0; st2 = 0
        setResult7()
        phase = .result
        interruptPending = true
        onInterrupt?()
    }
}
