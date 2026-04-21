@_exported import Z80
import Foundation
import Logging

private let machineLog = Logger(label: "EmulatorCore.Machine")

/// Map the low-level numeric port id used by `PIO8255.PIOAccess`
/// (0=A / 1=B / 2=C) onto the debugger's labelled enum.
@inline(__always)
private func portIDToFlow(_ raw: UInt8) -> PIOFlowEntry.Port {
    switch raw {
    case 0:  return .a
    case 1:  return .b
    default: return .c
    }
}

@inline(__always) private func hex(_ v: UInt8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count == 1 ? "0\(s)" : s
}

@inline(__always) private func hex(_ v: UInt16) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 4 - s.count)) + s
}

/// Machine — top-level orchestrator for the PC-8801-FA emulator.
///
/// Owns all components. Drives time via tick().
/// Devices cannot advance independently.
public final class Machine: @unchecked Sendable {

    // MARK: - Components

    public let cpu: Z80
    public let bus: Pc88Bus
    public let interruptBox: InterruptControllerBox
    public let keyboard: Keyboard
    public let dma: DMAController
    public let crtc: CRTC
    public let fontROM: FontROM
    public let sound: YM2608
    public let subSystem: SubSystem
    public let calendar: UPD1990A
    public let usart: I8251
    public let cassette: CassetteDeck

    /// Total T-states elapsed since reset
    public var totalTStates: UInt64 = 0

    // MARK: - Trace

    /// Trace log entry for debugging boot issues
    public struct TraceEntry {
        public let pc: UInt16
        public let opcode: UInt8
        public let ioPort: UInt16?
        public let ioValue: UInt8?
        public let isWrite: Bool
    }

    /// Enable/disable execution trace logging
    public var traceEnabled: Bool = false {
        didSet {
            if traceEnabled {
                bus.onIOAccess = { [weak self] port, value, isWrite in
                    self?.pendingIOTraces.append((port: port, value: value, isWrite: isWrite))
                }
            } else {
                bus.onIOAccess = nil
            }
        }
    }

    /// Collected trace entries (capped at traceMaxEntries)
    public var traceLog: [TraceEntry] = []

    /// Maximum number of trace entries to keep
    public var traceMaxEntries: Int = 10_000

    /// Pending I/O accesses captured during current instruction
    private var pendingIOTraces: [(port: UInt16, value: UInt8, isWrite: Bool)] = []

    // MARK: - Debugger

    /// Attached debugger, or `nil` for full-speed normal execution.
    ///
    /// When `nil` the hot path is untouched. When set, `run(tStates:)`
    /// routes through `debugRun(tStates:)` which consults the debugger
    /// before every main-CPU instruction and installs a sub-CPU hook
    /// on ``SubSystem``.
    public var debugger: Debugger? {
        didSet {
            if let dbg = debugger {
                subSystem.subCPUStepHook = { [weak dbg] pc in
                    guard let dbg else { return true }
                    return dbg.shouldStepSub(pc: pc)
                }
                subSystem.onSubPreStep = { [weak dbg, weak self] in
                    guard let dbg, let self else { return }
                    let sub = self.subSystem.subCpu
                    dbg.recordSubTraceEntry(InstructionTraceEntry(
                        pc: sub.pc,
                        af: sub.af, bc: sub.bc, de: sub.de, hl: sub.hl,
                        ix: sub.ix, iy: sub.iy,
                        sp: sub.sp,
                        af2: sub.af2, bc2: sub.bc2, de2: sub.de2, hl2: sub.hl2,
                        i: sub.i, r: sub.r
                    ))
                }
                bus.onDebuggerMemRead  = { [weak dbg] addr in dbg?.noteMemoryRead(addr) }
                bus.onDebuggerMemWrite = { [weak dbg] addr, value in dbg?.noteMemoryWrite(addr, value: value) }
                bus.onDebuggerIORead   = { [weak dbg] port in dbg?.noteIORead(port) }
                bus.onDebuggerIOWrite  = { [weak dbg] port, value in dbg?.noteIOWrite(port, value: value) }
                subSystem.pio.onPIOAccess = { [weak dbg, weak self] event in
                    guard let dbg, let self else { return }
                    dbg.recordPIOFlow(PIOFlowEntry(
                        mainPC: self.cpu.pc,
                        subPC: self.subSystem.subCpu.pc,
                        side: event.side == .main ? .main : .sub,
                        port: portIDToFlow(event.port),
                        isWrite: event.isWrite,
                        value: event.value
                    ))
                }
                subSystem.pio.onPIOControlWrite = { [weak dbg, weak self] side, value in
                    guard let dbg, let self else { return }
                    dbg.recordPIOFlow(PIOFlowEntry(
                        mainPC: self.cpu.pc,
                        subPC: self.subSystem.subCpu.pc,
                        side: side == .main ? .main : .sub,
                        port: .control,
                        isWrite: true,
                        value: value
                    ))
                }
            } else {
                subSystem.subCPUStepHook = nil
                subSystem.onSubPreStep = nil
                bus.onDebuggerMemRead  = nil
                bus.onDebuggerMemWrite = nil
                bus.onDebuggerIORead   = nil
                bus.onDebuggerIOWrite  = nil
                subSystem.pio.onPIOAccess = nil
                subSystem.pio.onPIOControlWrite = nil
            }
        }
    }

    /// Sub-CPU fractional clock accumulator (BubiC `d_cpu[i].accum_clocks`).
    ///
    /// After each main opcode we add `subUpdateClocks × main_cycles` here, then
    /// shift right by 10 to extract whole sub-CPU cycles to dispatch. The
    /// residual sub-1024 remainder is preserved across opcodes so the main/sub
    /// speed ratio is honoured exactly over the long run.
    ///
    /// See `BubiC-8801MA/src/vm/event.cpp:205-231` (`accum_clocks`,
    /// `update_clocks`).
    package var subAccumClocks: Int = 0

    /// Sub-CPU over-run debt in sub cycles.
    ///
    /// Z80 opcodes are atomic, so a dispatch of 2 sub cycles can still execute
    /// a 4T NOP — we owe the scheduler 2 sub cycles. BubiC handles this via
    /// the sub Z80's carried-over `icount`; since our `SubSystem.runSubCPU`
    /// starts each call with a fresh budget, we instead track the debt
    /// explicitly and work it off before dispatching new work.
    package var subDebt: Int = 0

    /// Q10 main→sub scaling factor (BubiC `d_cpu[i].update_clocks`).
    ///
    /// `1024 × sub_clock / main_clock`. For PC-88 (sub=4MHz):
    /// - main 8MHz → 512
    /// - main 4MHz → 1024
    ///
    /// See `BubiC-8801MA/src/vm/event.cpp:152`.
    private var subUpdateClocks: Int {
        clock8MHz ? 512 : 1024
    }

    /// Clock mode: true = 8MHz, false = 4MHz
    public var clock8MHz: Bool = true {
        didSet {
            bus.cpuClock8MHz = clock8MHz
            sound.clock8MHz = clock8MHz
        }
    }

    /// T-states per VSYNC frame
    public var tStatesPerFrame: Int {
        clock8MHz ? 133_333 : 66_667  // 8MHz/60Hz or 4MHz/60Hz
    }

    /// T-states per scanline (dynamic based on CRTC mode)
    public var tStatesPerLine: Int {
        tStatesPerFrame / crtc.dynamicTotalScanlines
    }

    // MARK: - RTC Timing

    /// T-states accumulated toward next RTC tick
    package var rtcCounter: Int = 0

    /// T-states per RTC tick (600Hz)
    private var tStatesPerRTC: Int {
        clock8MHz ? 13_333 : 6_667  // 8MHz/600Hz or 4MHz/600Hz
    }

    // MARK: - Init

    public init() {
        self.cpu = Z80()
        self.bus = Pc88Bus()
        self.interruptBox = InterruptControllerBox()
        self.keyboard = Keyboard()
        self.dma = DMAController()
        self.crtc = CRTC()
        self.fontROM = FontROM()
        self.sound = YM2608()
        self.subSystem = SubSystem()
        self.calendar = UPD1990A()
        self.usart = I8251()
        self.cassette = CassetteDeck(usart: usart)

        // Wire up: Bus holds weak refs to components
        bus.keyboard = keyboard
        bus.dma = dma
        bus.interruptController = interruptBox
        bus.crtc = crtc
        bus.sound = sound
        bus.subSystem = subSystem
        bus.calendar = calendar
        bus.usart = usart
        bus.cassette = cassette

        // Wire CRTC VSYNC → interrupt controller + bus VRTC flag
        crtc.onVSYNC = { [weak self] in
            self?.interruptBox.controller.request(level: .vrtc)
            self?.bus.vrtcFlag = true
            self?.bus.performTextDMATransfer()
        }

        // Wire YM2608 timer IRQ → interrupt controller
        sound.onTimerIRQ = { [weak self] in
            self?.interruptBox.controller.request(level: .sound)
        }

        // Wire I8251 RxRDY line → i8214 level 0 (RS-232C / CMT). Matches
        // BubiC `SIG_PC88_USART_IRQ` semantics: raise on RxRDY 0→1, drop
        // on RxRDY 1→0 (data port read) so the next byte can re-fire.
        usart.onRxReady = { [weak self] in
            self?.interruptBox.controller.request(level: .rxrdy)
        }
        usart.onRxReadyCleared = { [weak self] in
            self?.interruptBox.controller.clearPending(level: .rxrdy)
        }

        // Re-request sound IRQ when SINTM is unmasked (port 0x32 bit 7: 1→0)
        bus.onSoundUnmask = { [weak self] in
            guard let self = self, self.sound.irqLineActive else { return }
            self.interruptBox.controller.request(level: .sound)
        }

        // Legacy sub-system command completion → INT3
        subSystem.onInterrupt = { [weak self] in
            self?.interruptBox.controller.request(level: .int3)
        }
    }

    /// Cold reset — restore all components to power-on state.
    public func reset() {
        cpu.reset()
        bus.reset()
        interruptBox.controller.reset()
        keyboard.reset()
        dma.reset()
        crtc.reset()
        sound.reset()
        subSystem.reset()
        calendar.reset()
        usart.reset()
        totalTStates = 0
        rtcCounter = 0
        subAccumClocks = 0
        subDebt = 0
        clock8MHz = true
        traceLog.removeAll()
        pendingIOTraces.removeAll()

        // Note: IM2 is set by the N88-BASIC ROM init code (IM 2 instruction).
        // Z80 reset leaves IM=0, which is correct — the ROM will set IM2 before EI.

        // Re-wire callbacks (reset may clear them)
        if traceEnabled {
            bus.onIOAccess = { [weak self] port, value, isWrite in
                self?.pendingIOTraces.append((port: port, value: value, isWrite: isWrite))
            }
        }
        crtc.onVSYNC = { [weak self] in
            self?.interruptBox.controller.request(level: .vrtc)
            self?.bus.vrtcFlag = true
            self?.bus.performTextDMATransfer()
        }
        sound.onTimerIRQ = { [weak self] in
            self?.interruptBox.controller.request(level: .sound)
        }
        bus.onSoundUnmask = { [weak self] in
            guard let self = self, self.sound.irqLineActive else { return }
            self.interruptBox.controller.request(level: .sound)
        }
        subSystem.onInterrupt = { [weak self] in
            self?.interruptBox.controller.request(level: .int3)
        }
        usart.onRxReady = { [weak self] in
            self?.interruptBox.controller.request(level: .rxrdy)
        }
        usart.onRxReadyCleared = { [weak self] in
            self?.interruptBox.controller.clearPending(level: .rxrdy)
        }
    }

    /// Drive the sub-CPU on the elapsed main-CPU time window using BubiC's
    /// fractional accumulator (`event.cpp:205-231`).
    ///
    /// Called once per main opcode (after pending wait states have been
    /// folded in). Over-run debt is tracked because — unlike BubiC's sub
    /// Z80 which carries `icount` between calls — our `runSubCPU` starts
    /// each invocation with a fresh budget, so an atomic opcode consuming
    /// more than the requested budget would otherwise steal wall-clock
    /// time from the main CPU.
    @inline(__always)
    private func driveSub(mainCycles: Int) {
        guard !subSystem.useLegacyMode, mainCycles > 0 else { return }

        subAccumClocks += subUpdateClocks * mainCycles
        var subBudget = subAccumClocks >> 10
        guard subBudget > 0 else { return }
        subAccumClocks -= subBudget << 10

        if subDebt > 0 {
            let pay = subDebt < subBudget ? subDebt : subBudget
            subDebt -= pay
            subBudget -= pay
        }

        if subBudget > 0 {
            let executed = subSystem.runSubCPU(maxTStates: subBudget)
            if executed > subBudget {
                subDebt &+= executed - subBudget
            }
            // If the sub refused to run (returned 0, e.g. DI+HALT deadlock),
            // the budget is simply dropped — we must not re-accumulate it or
            // the scheduler would spin forever trying to advance a dead CPU.
        }
    }

    // MARK: - Execution

    /// Execute one CPU instruction and advance all devices.
    /// Returns the number of T-states consumed.
    @discardableResult
    public func tick() -> Int {
        let cycles: Int
        bus.debugMainPC = cpu.pc
        // Debugger trace ring buffer (captured BEFORE stepping so the
        // register snapshot reflects the state leading INTO the
        // instruction). Also triggered on direct tick() calls so
        // DebugSession.stepMain() feeds the trace correctly.
        if let dbg = debugger {
            dbg.recordTraceEntry(InstructionTraceEntry(
                pc: cpu.pc,
                af: cpu.af, bc: cpu.bc, de: cpu.de, hl: cpu.hl,
                ix: cpu.ix, iy: cpu.iy,
                sp: cpu.sp,
                af2: cpu.af2, bc2: cpu.bc2, de2: cpu.de2, hl2: cpu.hl2,
                i: cpu.i, r: cpu.r
            ))
        }
        if traceEnabled {
            let tracePC = cpu.pc
            pendingIOTraces.removeAll(keepingCapacity: true)
            cycles = cpu.step(bus: bus)
            if traceLog.count < traceMaxEntries {
                let opcode = bus.memRead(tracePC)
                if pendingIOTraces.isEmpty {
                    traceLog.append(TraceEntry(pc: tracePC, opcode: opcode, ioPort: nil, ioValue: nil, isWrite: false))
                } else {
                    for io in pendingIOTraces {
                        traceLog.append(TraceEntry(pc: tracePC, opcode: opcode, ioPort: io.port, ioValue: io.value, isWrite: io.isWrite))
                    }
                }
            }
        } else {
            cycles = cpu.step(bus: bus)
        }

        // Consume VRAM WAIT states accumulated during this instruction
        let waitCycles = bus.pendingWaitStates
        bus.pendingWaitStates = 0
        let totalCycles = cycles + waitCycles

        // Advance all timing-driven devices
        crtc.tick(tStates: totalCycles, tStatesPerLine: tStatesPerLine)
        sound.tick(tStates: totalCycles)
        cassette.tick(tStates: totalCycles)
        driveSub(mainCycles: totalCycles)

        // Sync VRTC flag from CRTC to bus
        bus.vrtcFlag = crtc.vrtcFlag

        // RTC (600Hz) — separate from CRTC
        rtcCounter += totalCycles
        if rtcCounter >= tStatesPerRTC {
            rtcCounter -= tStatesPerRTC
            interruptBox.controller.request(level: .rtc)
        }

        totalTStates += UInt64(totalCycles)

        // Interrupt dispatch
        if cpu.iff1, let irq = interruptBox.controller.resolve() {
            let ackCycles = cpu.interrupt(vector: irq.vectorOffset, bus: bus)
            interruptBox.controller.acknowledge(level: irq.level)

            // Advance devices by interrupt acknowledge cycles too
            crtc.tick(tStates: ackCycles, tStatesPerLine: tStatesPerLine)
            sound.tick(tStates: ackCycles)
            cassette.tick(tStates: ackCycles)
            totalTStates += UInt64(ackCycles)
            rtcCounter += ackCycles
        }

        return totalCycles
    }

    /// Run for approximately the given number of T-states.
    /// Returns actual T-states executed.
    @discardableResult
    public func run(tStates target: Int) -> Int {
        // Debugger path: honour pause state, check PC breakpoints, and
        // enforce step-one-instruction semantics. Tick-based for clarity.
        if let debugger {
            return debugRun(tStates: target, debugger: debugger)
        }
        // Fast path: when trace is disabled, inline the hot loop to avoid per-instruction
        // function call overhead from tick().
        guard !traceEnabled else {
            var executed = 0
            while executed < target {
                executed += tick()
            }
            return executed
        }

        let _tStatesPerLine = tStatesPerLine
        let _tStatesPerRTC = tStatesPerRTC
        let _soundBatchThreshold = sound.fmTStatesPerSample  // 144 at 8MHz, 72 at 4MHz
        var executed = 0
        var soundAccum = 0

        while executed < target {
            let cycles = cpu.step(bus: bus)

            let waitCycles = bus.pendingWaitStates
            bus.pendingWaitStates = 0
            let totalCycles = cycles + waitCycles

            crtc.tick(tStates: totalCycles, tStatesPerLine: _tStatesPerLine)
            cassette.tick(tStates: totalCycles)
            soundAccum += totalCycles
            if soundAccum >= _soundBatchThreshold {
                sound.tick(tStates: soundAccum)
                soundAccum = 0
            }
            driveSub(mainCycles: totalCycles)
            bus.vrtcFlag = crtc.vrtcFlag

            rtcCounter += totalCycles
            if rtcCounter >= _tStatesPerRTC {
                rtcCounter -= _tStatesPerRTC
                interruptBox.controller.request(level: .rtc)
            }

            totalTStates += UInt64(totalCycles)
            executed += totalCycles

            if cpu.iff1, let irq = interruptBox.controller.resolve() {
                let ackCycles = cpu.interrupt(vector: irq.vectorOffset, bus: bus)
                interruptBox.controller.acknowledge(level: irq.level)
                crtc.tick(tStates: ackCycles, tStatesPerLine: _tStatesPerLine)
                cassette.tick(tStates: ackCycles)
                soundAccum += ackCycles
                totalTStates += UInt64(ackCycles)
                rtcCounter += ackCycles
                executed += ackCycles
            }
        }

        // Flush remaining accumulated sound T-states
        if soundAccum > 0 {
            sound.tick(tStates: soundAccum)
        }

        return executed
    }

    /// Debugger-aware run loop.
    ///
    /// - If already paused, returns 0 immediately.
    /// - Before each instruction: consults `shouldStepMain(pc:)` for
    ///   PC breakpoints, then captures a trace ring-buffer entry.
    /// - If a memory/IO/sub-PC breakpoint fires mid-instruction, the
    ///   post-tick check breaks the loop.
    ///
    /// Single-stepping is no longer handled here: the debugger's UI
    /// layer stops Metal, calls `tick()` directly, and resumes Metal
    /// later. This keeps the hot path simpler and matches the
    /// "stop-step-render" model used by X88000-class debuggers.
    private func debugRun(tStates target: Int, debugger: Debugger) -> Int {
        if debugger.isPaused { return 0 }
        var executed = 0
        while executed < target {
            if !debugger.shouldStepMain(pc: cpu.pc) {
                break  // PC breakpoint on the next instruction
            }
            // Trace capture is done inside tick() when the debugger
            // is attached, so the direct-tick step path and this
            // normal run path share the same code.
            executed += tick()
            if debugger.isPaused {
                break  // mid-frame breakpoint (mem/io/sub-PC) fired
            }
        }
        return executed
    }

    /// Frame counter for freeze detection
    private var diagFrameCount: Int = 0
    public private(set) var diagFreezeDetected = false
    private var diagFreezePC: UInt16 = 0
    private var diagFreezeCount: Int = 0


    /// Run for one frame (1/60th second worth of T-states).
    @discardableResult
    public func runFrame() -> Int {
        diagFrameCount += 1
        // Detect freeze: same PC for 3 consecutive checks (every ~1s)
        if diagFrameCount % 60 == 0 {
            let pc = cpu.pc
            if pc == diagFreezePC {
                diagFreezeCount += 1
            } else {
                diagFreezePC = pc
                diagFreezeCount = 1
            }
            if diagFreezeCount == 3 && !diagFreezeDetected {
                diagFreezeDetected = true
                machineLog.warning("FREEZE detected at PC=0x\(hex(pc))")
            }
        }
        return run(tStates: tStatesPerFrame)
    }

    // MARK: - ROM Loading

    /// Load N88-BASIC ROM from data.
    public func loadN88BasicROM(_ data: [UInt8]) {
        bus.n88BasicROM = data
    }

    /// Load N-BASIC ROM from data.
    public func loadNBasicROM(_ data: [UInt8]) {
        bus.nBasicROM = data
    }

    /// Load N88 extended ROM bank (0-3, 8KB each).
    public func loadN88ExtROM(bank: Int, data: [UInt8]) {
        if bus.n88ExtROM == nil {
            bus.n88ExtROM = Array(repeating: Array(repeating: 0x00, count: 0x2000), count: 4)
        }
        guard bank >= 0 && bank < 4 else { return }
        let size = min(data.count, 0x2000)
        bus.n88ExtROM![bank] = Array(data.prefix(size)) + Array(repeating: 0x00, count: max(0, 0x2000 - size))
    }

    /// Load font ROM from data (256 chars × 8 bytes = 2048 bytes).
    public func loadFontROM(_ data: [UInt8]) {
        fontROM.load(data)
    }

    /// Load Kanji ROM Level 1 data (128KB).
    public func loadKanjiROM1(_ data: [UInt8]) {
        bus.kanjiROM1 = data
    }

    /// Load Kanji ROM Level 2 data (128KB).
    public func loadKanjiROM2(_ data: [UInt8]) {
        bus.kanjiROM2 = data
    }

    /// Load DISK.ROM firmware for sub-CPU (8KB).
    public func loadDiskROM(_ data: [UInt8]) {
        subSystem.diskROM = data
    }

    /// Load rhythm WAV sample data for YM2608 (signed 16-bit PCM).
    public func loadRhythmSample(index: Int, data: [Int16], sampleRate: Int) {
        sound.loadRhythmSample(index: index, data: data, sampleRate: sampleRate)
    }

    /// Install extended RAM (cards × banks × 32KB).
    /// Default: 1 card, 4 banks = 128KB.
    public func installExtRAM(cards: Int = 1, banksPerCard: Int = 4) {
        let bank = Array(repeating: UInt8(0x00), count: 0x8000) // 32KB
        let card = Array(repeating: bank, count: banksPerCard)
        bus.extRAM = Array(repeating: card, count: cards)
    }

    // MARK: - Disk Operations

    /// Mount a D88 disk image in the specified drive.
    public func mountDisk(drive: Int, disk: D88Disk) {
        subSystem.mountDisk(drive: drive, disk: disk)
    }

    /// Eject disk from the specified drive.
    public func ejectDisk(drive: Int) {
        subSystem.ejectDisk(drive: drive)
    }

    // MARK: - Tape Operations

    /// Mount a cassette image. Accepts T88 or raw CMT; the format is
    /// detected from the 24-byte T88 signature.
    @discardableResult
    public func mountTape(data: Data) -> CassetteDeck.Format {
        return cassette.load(data: data)
    }

    /// Eject the cassette.
    public func ejectTape() {
        cassette.eject()
    }

    public func rewindTape() {
        cassette.rewindToStart()
    }
}
