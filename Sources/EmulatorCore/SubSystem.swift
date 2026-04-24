import Logging

private let subLog = Logger(label: "EmulatorCore.SubSystem")

/// SubSystem — disk subsystem with Z80 sub-CPU executing DISK.ROM firmware.
///
/// Architecture:
///   SubSystem owns subCpu (Z80), subBus (SubBus), pio (PIO8255), fdc (UPD765A).
///   The main CPU communicates via PIO ports 0xFC-0xFF.
///   CPU scheduling lives in Machine.driveSub: after every main opcode we
///   hand the sub CPU a budget proportional to the elapsed main time
///   (BubiC `event.cpp` `accum_clocks` / `update_clocks` model).
///   `runSubCPU(maxTStates:)` executes that budget, honouring FDC IRQ
///   delivery on HALT and advancing FDC timing during idle waits.
///
/// Fallback: if DISK.ROM is not loaded, legacy command-level emulation is used.
public final class SubSystem {

    // MARK: - Sub-CPU Components

    /// Z80 sub-CPU (4MHz)
    public let subCpu: Z80

    /// Sub-CPU bus (ROM/RAM/FDC/PIO)
    public let subBus: SubBus

    /// Cross-wired PIO pair
    public let pio: PIO8255

    /// uPD765A FDC
    public let fdc: UPD765A

    // MARK: - Drive State

    /// Mounted disk images (2 drives).
    public var drives: [D88Disk?] = [nil, nil]

    // MARK: - Access Indicators

    /// Disk access indicator per drive.
    public var diskAccess: [Bool] = [false, false]

    /// Total T-states executed by sub-CPU (for debugging).
    public var subCpuTStates: UInt64 = 0

    /// Number of FDC interrupts delivered to sub-CPU (for debugging).
    public var fdcInterruptDeliveredCount: Int = 0


    // MARK: - Interrupt Callback

    /// メインCPUへINT3を通知するコールバック。
    public var onInterrupt: (() -> Void)?

    // MARK: - Debugger hooks

    /// Consulted by `runSubCPUInternal` before each sub-CPU instruction.
    /// Return `false` to abort the run loop (e.g. sub-PC breakpoint hit).
    /// `nil` means "no debugger attached — always proceed" and keeps the
    /// hot path a single pointer comparison away from normal execution.
    public var subCPUStepHook: ((UInt16) -> Bool)?

    /// Called immediately before each sub-CPU instruction, after the
    /// breakpoint check has passed. Used by the debugger to record
    /// pre-execution trace entries without touching the hot path when
    /// no debugger is attached.
    public var onSubPreStep: (() -> Void)?

    // MARK: - Legacy Mode

    /// True when DISK.ROM is not loaded — use command-level fallback.
    public internal(set) var useLegacyMode: Bool = true

    // Legacy state (only used when useLegacyMode == true)
    package var legacyPortA: UInt8 = 0x00
    package var legacyPortB: UInt8 = 0x00
    package var legacyMainPortCH: UInt8 = 0x00
    package var legacySubPortCH: UInt8 = 0x02
    package var legacyPioControl: UInt8 = 0x00
    package var legacyExpectingCommand: Bool = false
    package var legacyCurrentCommand: UInt8 = 0
    package var legacyCommandParams: [UInt8] = []
    package var legacyExpectedParamCount: Int = 0
    package var legacyCollectingWriteData: Bool = false
    package var legacyWriteDataExpected: Int = 0
    package var legacyWriteDataBuffer: [UInt8] = []
    package var legacyReadBuffer: [UInt8] = []
    package var legacyResultStatus: UInt8 = 0x00
    package var legacySurfaceMode: UInt8 = 0x00
    package var legacyResponseQueue: [UInt8] = []
    package var legacyResponseIndex: Int = 0
    package var legacyMotorOn: [Bool] = [false, false]
    package var legacyCurrentTrack: [Int] = [0, 0]

    // MARK: - Init

    public init() {
        self.subCpu = Z80()
        self.subBus = SubBus()
        self.pio = PIO8255()
        self.fdc = UPD765A()

        // Wire SubBus references
        subBus.pio = pio
        subBus.fdc = fdc

        // Wire FDC drive access via closure
        fdc.drives = { [weak self] in
            guard let self = self else { return [nil, nil] }
            return self.drives
        }
        fdc.writeSector = { [weak self] drive, track, c, h, r, data in
            guard let self = self, drive < self.drives.count else { return false }
            return self.drives[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
        }
        fdc.onDiskAccess = { [weak self] drive in
            guard let self = self, drive < 2 else { return }
            self.diskAccess[drive] = true
        }
        fdc.onSeekStep = { [weak self] drive, _ in
            guard let self = self, drive < 2 else { return }
            self.diskAccess[drive] = true
        }

        // FDC interrupt is handled via fdc.interruptPending in runSubCPUUntilSwitch.
        // Do NOT force subCpu.iff1 — DISK.ROM controls EI/DI.
    }

    /// Load DISK.ROM firmware. Switches to Z80 sub-CPU mode.
    public func loadDiskROM(_ data: [UInt8]) {
        subBus.loadROM(data)
        useLegacyMode = false
        subLog.debug("SubSystem: DISK.ROM loaded (\(data.count) bytes), Z80 sub-CPU mode")
    }

    /// Reset to power-on state.
    public func reset() {
        subCpu.reset()
        subBus.reset()
        pio.reset()
        fdc.reset()
        // Note: drives are intentionally NOT cleared — disks persist across reset.
        diskAccess = [false, false]
        subCpuTStates = 0

        // Re-wire callbacks (may be cleared by component reset)
        // FDC interrupt handled via fdc.interruptPending — no callback needed
        fdc.drives = { [weak self] in
            guard let self = self else { return [nil, nil] }
            return self.drives
        }
        fdc.writeSector = { [weak self] drive, track, c, h, r, data in
            guard let self = self, drive < self.drives.count else { return false }
            return self.drives[drive]?.writeSector(track: track, c: c, h: h, r: r, data: data) ?? false
        }

        // Legacy reset
        legacyPortA = 0x00
        legacyPortB = 0x00
        legacyMainPortCH = 0x00
        legacySubPortCH = 0x02
        legacyPioControl = 0x00
        legacyExpectingCommand = false
        legacyCurrentCommand = 0
        legacyCommandParams = []
        legacyExpectedParamCount = 0
        legacyCollectingWriteData = false
        legacyWriteDataExpected = 0
        legacyWriteDataBuffer = []
        legacyReadBuffer = []
        legacyResultStatus = 0x00
        legacySurfaceMode = 0x00
        legacyResponseQueue = []
        legacyResponseIndex = 0
        legacyMotorOn = [false, false]
        legacyCurrentTrack = [0, 0]
    }

    // MARK: - PIO Port I/O (Main CPU side)

    /// Read PIO port (main CPU reading from sub-CPU).
    public func pioRead(port: UInt8) -> UInt8 {


        if useLegacyMode {
            return legacyPioRead(port: port)
        }

        switch port {
        case 0xFC:
            return pio.readAB(side: .main, port: .portA)
        case 0xFD:
            return pio.readAB(side: .main, port: .portB)
        case 0xFE:
            return pio.readC(side: .main)
        case 0xFF:
            return 0xFF  // Control register (not typically read)
        default:
            return 0xFF
        }
    }

    /// Write PIO port (main CPU writing to sub-CPU).
    public func pioWrite(port: UInt8, value: UInt8) {


        if useLegacyMode {
            legacyPioWrite(port: port, value: value)
            return
        }

        switch port {
        case 0xFC:
            pio.writeAB(side: .main, port: .portA, data: value)
        case 0xFD:
            pio.writeAB(side: .main, port: .portB, data: value)
        case 0xFE:
            pio.writePortC(side: .main, data: value)
        case 0xFF:
            pio.writeControl(side: .main, data: value)
        default:
            break
        }
    }

    // MARK: - Sub-CPU Execution

    /// Run the sub-CPU for the given T-state budget without forcing a Port C poll switch.
    /// Returns T-states consumed.
    @discardableResult
    public func runSubCPU(maxTStates: Int) -> Int {
        runSubCPUInternal(maxTStates: maxTStates, stopOnPortCPoll: false)
    }

    /// Run sub-CPU until it reads Port C (polling → CPU switch) or maxTStates.
    /// Returns T-states consumed.
    @discardableResult
    public func runSubCPUUntilSwitch(maxTStates: Int = 100_000) -> Int {
        runSubCPUInternal(maxTStates: maxTStates, stopOnPortCPoll: true)
    }

    @discardableResult
    private func runSubCPUInternal(maxTStates: Int, stopOnPortCPoll: Bool) -> Int {
        guard !useLegacyMode else { return 0 }

        // Temporarily set a flag that tracks when sub-CPU reads Port C
        var subReadPortC = false
        let originalCallback = pio.onCPUSwitch
        if stopOnPortCPoll {
            pio.onCPUSwitch = {
                subReadPortC = true
            }
        }

        var executed = 0
        while executed < maxTStates && (!stopOnPortCPoll || !subReadPortC) {
            // Check for FDC interrupt → sub-CPU interrupt
            // CRITICAL: Only deliver when sub-CPU is HALTed — matches QUASI88's break_if_halt=TRUE.
            // The IM0 NOP interrupt just disables IFF without changing PC. If delivered while
            // running, the interrupt is "consumed" invisibly, and by the time sub-CPU reaches
            // EI+HALT again, interruptPending is already false → permanent stall.
            if fdc.interruptPending && subCpu.iff1 && subCpu.halted {
                fdc.interruptPending = false
                fdcInterruptDeliveredCount += 1
                let ackCycles = subCpu.interrupt(vector: 0x00, bus: subBus)
                executed += ackCycles
                fdc.tick(tStates: ackCycles)
                continue
            }

            // Optimization: if sub-CPU is HALTed and no interrupt can wake it, exit early.
            // This avoids burning maxTStates on idle HALT cycles.
            if subCpu.halted {
                if fdc.interruptPending && !subCpu.iff1 {
                    // HALTed with pending interrupt but interrupts disabled — deadlock
                    break
                }
                if !fdc.interruptPending && !subCpu.iff1 {
                    // HALTed with interrupts disabled and no pending interrupt — stuck
                    break
                }
                if !fdc.interruptPending && subCpu.iff1 {
                    // HALTed with interrupts enabled but no interrupt pending —
                    // sub-CPU is waiting for an event. Advance FDC timing for remaining
                    // budget to check if seek/operation completes, then exit.
                    let remaining = maxTStates - executed
                    fdc.tick(tStates: remaining)
                    executed += remaining
                    // Re-check if FDC now has an interrupt
                    if fdc.interruptPending && subCpu.iff1 {
                        fdc.interruptPending = false
                        fdcInterruptDeliveredCount += 1
                        let ackCycles = subCpu.interrupt(vector: 0x00, bus: subBus)
                        executed += ackCycles
                        fdc.tick(tStates: ackCycles)
                        continue
                    }
                    break
                }
            }

            subBus.currentSubPC = subCpu.pc
            if let hook = subCPUStepHook, !hook(subCpu.pc) {
                break  // debugger breakpoint on sub PC
            }
            onSubPreStep?()
            let cycles = subCpu.step(bus: subBus)
            executed += cycles
            fdc.tick(tStates: cycles)
        }

        subCpuTStates += UInt64(executed)

        // Restore callback
        if stopOnPortCPoll {
            pio.onCPUSwitch = originalCallback
        }

        return executed
    }

    // MARK: - Disk Operations

    /// Mount a D88 disk image in the specified drive.
    public func mountDisk(drive: Int, disk: D88Disk) {
        guard drive >= 0 && drive < 2 else { return }
        // If a disk was already mounted, signal disk exchange to the FDC
        // so Sense Drive Status can report the change (QUASI88: disk_ex_drv).
        if drives[drive] != nil {
            fdc.diskExchanged[drive] = true
        }
        drives[drive] = disk
    }

    /// Eject disk from the specified drive.
    public func ejectDisk(drive: Int) {
        guard drive >= 0 && drive < 2 else { return }
        drives[drive] = nil
    }

    /// Toggle or set the write-protect flag on the currently mounted disk.
    /// No-op if no disk is mounted on the drive.
    public func setWriteProtect(drive: Int, protected: Bool) {
        guard drive >= 0 && drive < 2 else { return }
        drives[drive]?.writeProtected = protected
    }

    /// Return the write-protect flag for the mounted disk (false if empty).
    public func isWriteProtected(drive: Int) -> Bool {
        guard drive >= 0 && drive < 2 else { return false }
        return drives[drive]?.writeProtected ?? false
    }

    /// Check if a drive has a disk mounted.
    public func hasDisk(drive: Int) -> Bool {
        guard drive >= 0 && drive < 2 else { return false }
        return drives[drive] != nil
    }

    // MARK: - Timing

    /// Advance sub-system by T-states (for FDC seek timing).
    public func tick(tStates: Int) {
        if !useLegacyMode {
            fdc.tick(tStates: tStates)
        }
    }

    // =================================================================
    // MARK: - Legacy Command-Level Emulation (DISK.ROM not loaded)
    // =================================================================

    /// Legacy Port C read (combined cross-wired value).
    public var legacyPortCValue: UInt8 {
        return (legacyMainPortCH << 4) | (legacySubPortCH & 0x0F)
    }

    private func legacyPioRead(port: UInt8) -> UInt8 {
        switch port {
        case 0xFC: return legacyPortA
        case 0xFD: return legacyPortB
        case 0xFE: return legacyPortCValue
        case 0xFF: return legacyPioControl
        default: return 0xFF
        }
    }

    private func legacyPioWrite(port: UInt8, value: UInt8) {
        switch port {
        case 0xFC:
            break  // Port A not writable by main CPU
        case 0xFD:
            legacyWritePortB(value)
        case 0xFE:
            legacyMainPortCH = (value >> 4) & 0x0F
        case 0xFF:
            if value & 0x80 != 0 {
                legacyPioControl = value
                legacyMainPortCH = 0x00
                legacySubPortCH = 0x02
            } else {
                let isHighNibble = (value & 0x08) != 0
                let bitPos = Int((value >> 1) & 0x03)
                let bitSet = (value & 0x01) != 0
                if isHighNibble {
                    let oldCH = legacyMainPortCH
                    if bitSet {
                        legacyMainPortCH |= UInt8(1 << bitPos)
                    } else {
                        legacyMainPortCH &= ~UInt8(1 << bitPos)
                    }
                    legacyHandleMainCHChange(old: oldCH, new: legacyMainPortCH)
                }
            }
        default:
            break
        }
    }

    private func legacyHandleMainCHChange(old: UInt8, new: UInt8) {
        if old & 0x08 == 0 && new & 0x08 != 0 {
            legacyExpectingCommand = true
            legacySubPortCH |= 0x02
        }
        if old & 0x01 != 0 && new & 0x01 == 0 {
            legacySubPortCH &= ~0x04
        }
        if old & 0x02 == 0 && new & 0x02 != 0 {
            if legacyResponseIndex < legacyResponseQueue.count {
                legacyPortA = legacyResponseQueue[legacyResponseIndex]
                legacySubPortCH |= 0x01
            }
        }
        if old & 0x04 == 0 && new & 0x04 != 0 {
            legacySubPortCH &= ~0x01
            legacyResponseIndex += 1
            if legacyResponseIndex >= legacyResponseQueue.count {
                legacyResponseQueue = []
                legacyResponseIndex = 0
            }
        }
    }

    private func legacyWritePortB(_ value: UInt8) {
        legacyPortB = value

        if legacyExpectingCommand {
            legacyExpectingCommand = false
            legacyStartCommand(value)
        } else if legacyCollectingWriteData {
            legacyWriteDataBuffer.append(value)
            if legacyWriteDataBuffer.count >= legacyWriteDataExpected {
                legacyCompleteWriteData()
            }
        } else if legacyCommandParams.count < legacyExpectedParamCount {
            legacyCommandParams.append(value)
            if legacyCommandParams.count >= legacyExpectedParamCount {
                legacyExecuteSubCommand()
            }
        }

        legacySubPortCH |= 0x04  // sub DAC
    }

    private func legacyQueueResponse(_ bytes: [UInt8]) {
        legacyResponseQueue = bytes
        legacyResponseIndex = 0
    }

    private func legacyStartCommand(_ cmd: UInt8) {
        legacyCurrentCommand = cmd
        legacyCommandParams = []
        legacyCollectingWriteData = false
        legacyWriteDataExpected = 0
        legacyWriteDataBuffer = []
        legacyExpectedParamCount = legacySubCommandParamCount(cmd)
        if legacyExpectedParamCount == 0 {
            legacyExecuteSubCommand()
        }
    }

    private func legacySubCommandParamCount(_ cmd: UInt8) -> Int {
        switch cmd {
        case 0x00: return 0; case 0x01: return 4; case 0x02: return 4
        case 0x03: return 0; case 0x05: return 1; case 0x06: return 0
        case 0x07: return 0; case 0x08: return 0; case 0x09: return 4
        case 0x0B: return 4; case 0x10: return 0; case 0x11: return 4
        case 0x12: return 0; case 0x13: return 0; case 0x14: return 1
        case 0x17: return 1; case 0x18: return 0; case 0x19: return 0
        case 0x1A: return 0; case 0x23: return 1
        default: return 0
        }
    }

    private func legacyExecuteSubCommand() {
        switch legacyCurrentCommand {
        case 0x00: legacyExecInitialize()
        case 0x01, 0x11: legacyExecWriteDataHeader()
        case 0x02: legacyExecReadData()
        case 0x03, 0x12: legacyExecSendData()
        case 0x06: legacyExecSendResultStatus()
        case 0x07: legacyExecSendDriveStatus()
        case 0x08: legacyQueueResponse([0x80]); onInterrupt?()
        case 0x09: legacyExecSendMemory()
        case 0x0B: legacyExecSendMemory2()
        case 0x10: legacyExecLoadAndGo()
        case 0x13: legacyQueueResponse([0, 0, 0, 0, 0, 0, 0, 0]); onInterrupt?()
        case 0x14: legacyExecSenseDeviceStatus()
        case 0x17: legacySurfaceMode = legacyCommandParams[0]; legacyResultStatus = 0x80; onInterrupt?()
        case 0x18: legacyQueueResponse([legacySurfaceMode]); onInterrupt?()
        case 0x23: legacyExecDriveReadyCheck()
        default: legacyResultStatus = 0x80; onInterrupt?()
        }
    }

    private func legacyExecInitialize() {
        legacyMotorOn = [true, true]
        legacyCurrentTrack = [0, 0]
        legacyResultStatus = 0x80
        onInterrupt?()
    }

    private func legacyExecReadData() {
        guard legacyCommandParams.count >= 4 else { legacyResultStatus = 0x81; onInterrupt?(); return }
        let sectorCount = Int(legacyCommandParams[0])
        let driveNo = Int(legacyCommandParams[1])
        let trackNo = Int(legacyCommandParams[2])
        let sectorNo = Int(legacyCommandParams[3])
        if driveNo < 2 { diskAccess[driveNo] = true }
        guard driveNo < 2, let disk = drives[driveNo] else {
            legacyResultStatus = 0x81; legacyReadBuffer = []; onInterrupt?(); return
        }
        let d88Track = legacyD88TrackIndex(drive: driveNo, trackNo: trackNo)
        let c = UInt8(d88Track / 2); let h = UInt8(d88Track & 1)
        var allData: [UInt8] = []; var foundAll = true
        for i in 0..<sectorCount {
            if let sector = disk.findSector(track: d88Track, c: c, h: h, r: UInt8(sectorNo + i)) {
                allData.append(contentsOf: sector.data)
            } else { foundAll = false; break }
        }
        if foundAll && !allData.isEmpty {
            legacyReadBuffer = allData; legacyResultStatus = 0xC0; legacyCurrentTrack[driveNo] = trackNo
        } else {
            legacyReadBuffer = []; legacyResultStatus = 0x81
        }
        onInterrupt?()
    }

    private func legacyExecWriteDataHeader() {
        guard legacyCommandParams.count >= 4 else { legacyResultStatus = 0x81; onInterrupt?(); return }
        let sectorCount = Int(legacyCommandParams[0]); let driveNo = Int(legacyCommandParams[1])
        var sectorSize = 256
        if driveNo < 2, let disk = drives[driveNo] {
            let d88Track = legacyD88TrackIndex(drive: driveNo, trackNo: Int(legacyCommandParams[2]))
            if !disk.tracks[d88Track].isEmpty { sectorSize = disk.tracks[d88Track][0].dataSize }
        }
        legacyWriteDataExpected = sectorCount * sectorSize
        legacyWriteDataBuffer = []; legacyCollectingWriteData = true
    }

    private func legacyCompleteWriteData() {
        legacyCollectingWriteData = false
        let driveNo = Int(legacyCommandParams[1])
        if driveNo < 2 { diskAccess[driveNo] = true }
        let trackNo = Int(legacyCommandParams[2]); let sectorNo = Int(legacyCommandParams[3])
        guard driveNo < 2, drives[driveNo] != nil else { legacyResultStatus = 0x81; onInterrupt?(); return }
        let d88Track = legacyD88TrackIndex(drive: driveNo, trackNo: trackNo)
        let c = UInt8(d88Track / 2); let h = UInt8(d88Track & 1)
        var offset = 0; var allOk = true
        let sectorCount = Int(legacyCommandParams[0])
        for i in 0..<sectorCount {
            let r = UInt8(sectorNo + i)
            if let sector = drives[driveNo]!.findSector(track: d88Track, c: c, h: h, r: r) {
                let size = sector.data.count
                let end = min(offset + size, legacyWriteDataBuffer.count)
                if !drives[driveNo]!.writeSector(track: d88Track, c: c, h: h, r: r,
                                                  data: Array(legacyWriteDataBuffer[offset..<end])) {
                    allOk = false; break
                }
                offset += size
            } else { allOk = false; break }
        }
        legacyResultStatus = allOk ? 0x80 : 0x81
        legacyCurrentTrack[driveNo] = trackNo
        onInterrupt?()
    }

    private func legacyExecSendData() {
        if !legacyReadBuffer.isEmpty {
            legacyQueueResponse(legacyReadBuffer); legacyReadBuffer = []
        } else {
            legacyQueueResponse([])
        }
        onInterrupt?()
    }

    private func legacyExecSendResultStatus() {
        legacyQueueResponse([legacyResultStatus]); onInterrupt?()
    }

    private func legacyExecSendDriveStatus() {
        var status: UInt8 = 0x00
        if drives[0] != nil { status |= 0x10 }
        if drives[1] != nil { status |= 0x20 }
        legacyQueueResponse([status]); onInterrupt?()
    }

    private func legacyExecSendMemory() {
        guard legacyCommandParams.count >= 4 else { legacyResultStatus = 0x81; onInterrupt?(); return }
        let startAddr = (Int(legacyCommandParams[0]) << 8) | Int(legacyCommandParams[1])
        let endAddr = (Int(legacyCommandParams[2]) << 8) | Int(legacyCommandParams[3])
        let count = max(0, endAddr - startAddr + 1)
        var data: [UInt8] = []
        for i in 0..<count { data.append(subBus.memRead(UInt16(startAddr + i))) }
        legacyQueueResponse(data); onInterrupt?()
    }

    private func legacyExecSendMemory2() {
        guard legacyCommandParams.count >= 4 else { legacyResultStatus = 0x81; onInterrupt?(); return }
        let addr = (Int(legacyCommandParams[0]) << 8) | Int(legacyCommandParams[1])
        let count = (Int(legacyCommandParams[2]) << 8) | Int(legacyCommandParams[3])
        var data: [UInt8] = []
        for i in 0..<count { data.append(subBus.memRead(UInt16(addr + i))) }
        legacyQueueResponse(data); onInterrupt?()
    }

    private func legacyExecLoadAndGo() {
        legacyMotorOn = [true, true]; legacyCurrentTrack = [0, 0]
        if let disk = drives[0], let sector = disk.findSector(track: 0, c: 0, h: 0, r: 1) {
            legacyReadBuffer = sector.data; legacyResultStatus = 0xC0
        } else {
            legacyReadBuffer = []; legacyResultStatus = 0x81
        }
        onInterrupt?()
    }

    private func legacyExecSenseDeviceStatus() {
        let driveNo = Int(legacyCommandParams[0] & 0x03)
        var st3: UInt8 = UInt8(driveNo)
        if driveNo < 2 {
            st3 |= 0x20 | 0x08
            if legacyCurrentTrack[driveNo] == 0 { st3 |= 0x10 }
            if let disk = drives[driveNo], disk.writeProtected { st3 |= 0x40 }
        }
        legacyQueueResponse([st3]); onInterrupt?()
    }

    private func legacyExecDriveReadyCheck() {
        let driveNo = Int(legacyCommandParams[0] & 0x03)
        let status: UInt8 = (driveNo < 2 && drives[driveNo] != nil) ? 0x00 : 0xFF
        legacyQueueResponse([status]); onInterrupt?()
    }

    private func legacyD88TrackIndex(drive: Int, trackNo: Int) -> Int {
        let isDoubleSided = (legacySurfaceMode >> drive) & 1 != 0
        return isDoubleSided ? trackNo : trackNo * 2
    }

    // MARK: - Legacy Compatibility Properties

    /// Port B value (for tests checking legacy behavior).
    public var portB: UInt8 {
        if useLegacyMode { return legacyPortB }
        return pio.portAB[PIO8255.Side.main.rawValue][PIO8255.PortABIndex.portB.rawValue].data
    }

    /// Port C combined value (for tests).
    public var portC: UInt8 {
        if useLegacyMode { return legacyPortCValue }
        return pio.readC(side: .main)
    }

    /// Current track per drive (for tests).
    public var currentTrack: [Int] {
        get {
            if useLegacyMode { return legacyCurrentTrack }
            return [Int(fdc.pcn[0]), Int(fdc.pcn[1])]
        }
        set {
            if useLegacyMode {
                legacyCurrentTrack = newValue
            } else {
                for i in 0..<min(newValue.count, 4) {
                    fdc.pcn[i] = UInt8(newValue[i])
                }
            }
        }
    }

    /// Motor on flags (for tests).
    public var motorOn: [Bool] {
        get {
            if useLegacyMode { return legacyMotorOn }
            return [subBus.motorOn[0], subBus.motorOn[1]]
        }
        set {
            if useLegacyMode {
                legacyMotorOn = newValue
            } else {
                for i in 0..<min(newValue.count, subBus.motorOn.count) {
                    subBus.motorOn[i] = newValue[i]
                }
            }
        }
    }

    /// Total number of sub-CPU commands received (for debugging).
    public var commandCount: Int = 0

    /// Last command received (for debugging).
    public var lastCommand: UInt8 = 0xFF

    // Legacy diskROM property (kept for Machine.loadDiskROM compatibility)
    public var diskROM: [UInt8]? {
        get { return nil }
        set {
            if let data = newValue {
                loadDiskROM(data)
            }
        }
    }
}
