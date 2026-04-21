import Foundation
import Observation

/// Central debugger state for Bubilator88.
///
/// Owned by ``Machine``. When ``Machine/debugger`` is `nil` the hot
/// execution path is untouched; when set, Machine routes through the
/// per-instruction `tick()` loop and consults the debugger on each
/// main/sub instruction and each memory / I/O access.
///
/// ## Concurrency
/// `Debugger` is mutated from two threads: the main thread (UI button
/// handlers, breakpoint editing) and the emulator queue (hot-path BP
/// checks, run-state transitions on hit). The `@Observable` macro is
/// preserved so SwiftUI views can still bind directly to `runState` /
/// `breakpoints` / `lastHit`; observation notifications fire after the
/// lock is released so the lock never participates in SwiftUI updates.
///
/// ### Why not an `actor`?
/// The hot path (`shouldStepMain` / `shouldStepSub` / `noteMemoryRead`
/// etc.) is called from `Z80.step` which is **synchronous**. Wrapping
/// the state in an actor would force every call site to `await`, which
/// is impossible inside the synchronous CPU loop. We therefore use a
/// classic mutex.
///
/// ### Why `@unchecked Sendable`?
/// All mutable state is private and every access goes through one of
/// the explicit methods below, each of which acquires `lock` for the
/// duration of its critical section. As long as that contract is
/// honoured the type is data-race free. **Adding a new property must
/// either: (a) place it inside the locked region or (b) be immutable
/// and Sendable.**
@Observable
public final class Debugger: @unchecked Sendable {

    /// SAFETY: guards every mutable property below. Held only for the
    /// duration of the surrounding method; never while invoking
    /// arbitrary callbacks.
    @ObservationIgnored private let lock = NSLock()

    // MARK: - Types

    public enum RunState: Sendable, Equatable {
        /// Emulation runs normally; breakpoints still fire.
        case running
        /// Emulation is halted. `reason` explains why.
        case paused(reason: PauseReason)
    }

    public enum PauseReason: Sendable, Equatable {
        case userRequest
        case initialLaunch
        case breakpoint(Breakpoint.ID)
    }

    // MARK: - Observable state

    /// Current run state. UI binds to this for the Run/Pause button.
    public private(set) var runState: RunState = .running

    /// All configured breakpoints (value-typed, order-preserved for UI).
    public private(set) var breakpoints: [Breakpoint] = []

    /// Last breakpoint that caused a pause, if any. Useful for UI flashing.
    public private(set) var lastHit: Breakpoint.ID?

    // MARK: - Fast-lookup tables (non-observable)

    // These sets are rebuilt whenever `breakpoints` changes. Placed
    // outside `@ObservationIgnored` tracking by rebuilding via private
    // helper so SwiftUI doesn't over-invalidate on hot-path reads.
    @ObservationIgnored private var mainPCHits:   Set<UInt16> = []
    @ObservationIgnored private var subPCHits:    Set<UInt16> = []
    @ObservationIgnored private var memReadHits:  Set<UInt16> = []
    @ObservationIgnored private var memWriteHits: Set<UInt16> = []
    @ObservationIgnored private var ioReadHits:   Set<UInt16> = []
    @ObservationIgnored private var ioWriteHits:  Set<UInt16> = []

    // Reverse lookup: address → breakpoint id, for reporting which BP hit.
    @ObservationIgnored private var mainPCIndex:   [UInt16: Breakpoint.ID] = [:]
    @ObservationIgnored private var subPCIndex:    [UInt16: Breakpoint.ID] = [:]
    @ObservationIgnored private var memReadIndex:  [UInt16: Breakpoint.ID] = [:]
    @ObservationIgnored private var memWriteIndex: [UInt16: (Breakpoint.ID, UInt8?)] = [:]
    @ObservationIgnored private var ioReadIndex:   [UInt16: Breakpoint.ID] = [:]
    @ObservationIgnored private var ioWriteIndex:  [UInt16: (Breakpoint.ID, UInt8?)] = [:]

    // MARK: - Instruction trace (ring buffer)

    /// Maximum number of main-CPU instructions retained in the trace
    /// ring buffer. Capped on write; snapshot copies are bounded too.
    public static let traceCapacity: Int = 1024

    @ObservationIgnored private var traceBuffer: [InstructionTraceEntry] = []
    @ObservationIgnored private var traceWriteIndex: Int = 0

    @ObservationIgnored private var subTraceBuffer: [InstructionTraceEntry] = []
    @ObservationIgnored private var subTraceWriteIndex: Int = 0

    // MARK: - PIO data flow log (ring buffer)

    /// Maximum number of PIO data-flow entries retained. Larger than
    /// the instruction trace because a single disk sector transfer
    /// can produce hundreds of PIO events.
    public static let pioFlowCapacity: Int = 4096

    @ObservationIgnored private var pioFlowBuffer: [PIOFlowEntry] = []
    @ObservationIgnored private var pioFlowWriteIndex: Int = 0

    // MARK: - PIO flow streaming to file

    /// Whether an unbounded JSONL stream of every PIO event is
    /// currently being written to disk. Observable so the UI can
    /// flip a toggle button when it transitions.
    public private(set) var isStreamingPIOFlow: Bool = false

    @ObservationIgnored private var streamFileHandle: FileHandle? = nil
    @ObservationIgnored private var streamSeq: Int = 0
    @ObservationIgnored private var streamBuffer: Data = Data()
    @ObservationIgnored private let streamFlushThreshold: Int = 64 * 1024

    // MARK: - Init

    public init() {
        traceBuffer.reserveCapacity(Self.traceCapacity)
        subTraceBuffer.reserveCapacity(Self.traceCapacity)
        pioFlowBuffer.reserveCapacity(Self.pioFlowCapacity)
    }

    // MARK: - Breakpoint management

    public func add(_ breakpoint: Breakpoint) {
        lock.lock(); defer { lock.unlock() }
        breakpoints.append(breakpoint)
        rebuildLookupTablesLocked()
    }

    public func remove(id: Breakpoint.ID) {
        lock.lock(); defer { lock.unlock() }
        breakpoints.removeAll { $0.id == id }
        rebuildLookupTablesLocked()
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        breakpoints.removeAll()
        rebuildLookupTablesLocked()
    }

    public func setEnabled(_ enabled: Bool, id: Breakpoint.ID) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = breakpoints.firstIndex(where: { $0.id == id }) else { return }
        breakpoints[idx].isEnabled = enabled
        rebuildLookupTablesLocked()
    }

    /// Insert or update (upsert). Uses `id` as identity.
    public func upsert(_ breakpoint: Breakpoint) {
        lock.lock(); defer { lock.unlock() }
        if let idx = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) {
            breakpoints[idx] = breakpoint
        } else {
            breakpoints.append(breakpoint)
        }
        rebuildLookupTablesLocked()
    }

    /// Caller must hold `lock`.
    private func rebuildLookupTablesLocked() {
        mainPCHits.removeAll(keepingCapacity: true)
        subPCHits.removeAll(keepingCapacity: true)
        memReadHits.removeAll(keepingCapacity: true)
        memWriteHits.removeAll(keepingCapacity: true)
        ioReadHits.removeAll(keepingCapacity: true)
        ioWriteHits.removeAll(keepingCapacity: true)
        mainPCIndex.removeAll(keepingCapacity: true)
        subPCIndex.removeAll(keepingCapacity: true)
        memReadIndex.removeAll(keepingCapacity: true)
        memWriteIndex.removeAll(keepingCapacity: true)
        ioReadIndex.removeAll(keepingCapacity: true)
        ioWriteIndex.removeAll(keepingCapacity: true)

        for bp in breakpoints where bp.isEnabled {
            switch bp.kind {
            case .mainPC(let a):
                mainPCHits.insert(a)
                mainPCIndex[a] = bp.id
            case .subPC(let a):
                subPCHits.insert(a)
                subPCIndex[a] = bp.id
            case .memoryRead(let a):
                memReadHits.insert(a)
                memReadIndex[a] = bp.id
            case .memoryWrite(let a):
                memWriteHits.insert(a)
                memWriteIndex[a] = (bp.id, bp.valueFilter)
            case .ioRead(let a):
                ioReadHits.insert(a & 0xFF)
                ioReadIndex[a & 0xFF] = bp.id
            case .ioWrite(let a):
                ioWriteHits.insert(a & 0xFF)
                ioWriteIndex[a & 0xFF] = (bp.id, bp.valueFilter)
            }
        }
    }

    // MARK: - Run control

    public func pauseRequest(reason: PauseReason = .userRequest) {
        lock.lock(); defer { lock.unlock() }
        runState = .paused(reason: reason)
    }

    public func resume() {
        lock.lock(); defer { lock.unlock() }
        lastHit = nil
        runState = .running
    }

    /// True if emulator is currently paused (any reason).
    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .paused = runState { return true }
        return false
    }

    // MARK: - Machine-facing hooks (hot path)

    /// Machine calls this before executing each main-CPU instruction.
    /// Returns `true` if the instruction should proceed; `false` if the
    /// caller must stop its loop (pause state has been entered).
    package func shouldStepMain(pc: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if mainPCHits.contains(pc) {
            hitLocked(id: mainPCIndex[pc])
            return false
        }
        return true
    }

    /// Machine calls this before executing each sub-CPU instruction.
    package func shouldStepSub(pc: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if subPCHits.contains(pc) {
            hitLocked(id: subPCIndex[pc])
            return false
        }
        return true
    }

    /// Called by Bus on every memory read. Updates paused state if
    /// a matching breakpoint is set. Return value is intentionally
    /// absent: a mid-instruction fetch cannot be unwound, so the
    /// Machine loop picks up the state change on its next iteration.
    package func noteMemoryRead(_ addr: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard memReadHits.contains(addr) else { return }
        hitLocked(id: memReadIndex[addr])
    }

    package func noteMemoryWrite(_ addr: UInt16, value: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard memWriteHits.contains(addr) else { return }
        guard let (id, filter) = memWriteIndex[addr] else { return }
        if let filter, filter != value { return }
        hitLocked(id: id)
    }

    package func noteIORead(_ port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        let p = port & 0xFF
        guard ioReadHits.contains(p) else { return }
        hitLocked(id: ioReadIndex[p])
    }

    package func noteIOWrite(_ port: UInt16, value: UInt8) {
        lock.lock(); defer { lock.unlock() }
        let p = port & 0xFF
        guard ioWriteHits.contains(p) else { return }
        guard let (id, filter) = ioWriteIndex[p] else { return }
        if let filter, filter != value { return }
        hitLocked(id: id)
    }

    /// Caller must hold `lock`.
    private func hitLocked(id: Breakpoint.ID?) {
        lastHit = id
        runState = .paused(reason: id.map(PauseReason.breakpoint) ?? .userRequest)
    }

    // MARK: - Instruction trace API

    /// Record one main-CPU instruction in the ring buffer. Called by
    /// `Machine.debugRun` immediately before each `cpu.step`.
    package func recordTraceEntry(_ entry: InstructionTraceEntry) {
        lock.lock(); defer { lock.unlock() }
        if traceBuffer.count < Self.traceCapacity {
            traceBuffer.append(entry)
        } else {
            traceBuffer[traceWriteIndex] = entry
            traceWriteIndex = (traceWriteIndex + 1) % Self.traceCapacity
        }
    }

    /// Chronological snapshot of the trace (oldest first).
    public func traceSnapshot() -> [InstructionTraceEntry] {
        lock.lock(); defer { lock.unlock() }
        if traceBuffer.count < Self.traceCapacity {
            return traceBuffer
        }
        return Array(traceBuffer[traceWriteIndex...] + traceBuffer[..<traceWriteIndex])
    }

    /// Drop every recorded instruction.
    public func clearTrace() {
        lock.lock(); defer { lock.unlock() }
        traceBuffer.removeAll(keepingCapacity: true)
        traceWriteIndex = 0
    }

    // MARK: - Sub-CPU instruction trace API

    /// Record one sub-CPU instruction in the sub ring buffer.
    package func recordSubTraceEntry(_ entry: InstructionTraceEntry) {
        lock.lock(); defer { lock.unlock() }
        if subTraceBuffer.count < Self.traceCapacity {
            subTraceBuffer.append(entry)
        } else {
            subTraceBuffer[subTraceWriteIndex] = entry
            subTraceWriteIndex = (subTraceWriteIndex + 1) % Self.traceCapacity
        }
    }

    /// Chronological snapshot of the sub-CPU trace (oldest first).
    public func subTraceSnapshot() -> [InstructionTraceEntry] {
        lock.lock(); defer { lock.unlock() }
        if subTraceBuffer.count < Self.traceCapacity {
            return subTraceBuffer
        }
        return Array(subTraceBuffer[subTraceWriteIndex...] + subTraceBuffer[..<subTraceWriteIndex])
    }

    public func clearSubTrace() {
        lock.lock(); defer { lock.unlock() }
        subTraceBuffer.removeAll(keepingCapacity: true)
        subTraceWriteIndex = 0
    }

    // MARK: - PIO data flow API

    package func recordPIOFlow(_ entry: PIOFlowEntry) {
        lock.lock(); defer { lock.unlock() }
        if pioFlowBuffer.count < Self.pioFlowCapacity {
            pioFlowBuffer.append(entry)
        } else {
            pioFlowBuffer[pioFlowWriteIndex] = entry
            pioFlowWriteIndex = (pioFlowWriteIndex + 1) % Self.pioFlowCapacity
        }
        // Parallel stream-to-file path. Uses the same lock so the
        // file handle's lifetime is safe against concurrent start/stop
        // from the UI thread.
        if streamFileHandle != nil {
            let line = PIOFlowJSONL.line(seq: streamSeq, entry: entry) + "\n"
            if let data = line.data(using: .utf8) {
                streamBuffer.append(data)
                if streamBuffer.count >= streamFlushThreshold {
                    flushStreamBufferLocked()
                }
            }
            streamSeq &+= 1
        }
    }

    /// Chronological snapshot of the PIO flow log (oldest first).
    public func pioFlowSnapshot() -> [PIOFlowEntry] {
        lock.lock(); defer { lock.unlock() }
        if pioFlowBuffer.count < Self.pioFlowCapacity {
            return pioFlowBuffer
        }
        return Array(pioFlowBuffer[pioFlowWriteIndex...] + pioFlowBuffer[..<pioFlowWriteIndex])
    }

    public func clearPIOFlow() {
        lock.lock(); defer { lock.unlock() }
        pioFlowBuffer.removeAll(keepingCapacity: true)
        pioFlowWriteIndex = 0
    }

    // MARK: - PIO flow streaming

    /// Start writing every subsequent PIO event to `url` as JSONL.
    /// Any existing stream is closed first. The sequence counter
    /// resets to 0 so line numbers in the output file reflect only
    /// events that occurred while streaming was active.
    public func startPIOFlowStream(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        closeStreamLocked()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        streamFileHandle = try FileHandle(forWritingTo: url)
        streamSeq = 0
        streamBuffer.removeAll(keepingCapacity: true)
        isStreamingPIOFlow = true
    }

    /// Stop streaming and flush any pending bytes. Safe to call when
    /// no stream is active.
    public func stopPIOFlowStream() {
        lock.lock(); defer { lock.unlock() }
        closeStreamLocked()
        isStreamingPIOFlow = false
    }

    /// Caller must hold `lock`.
    private func closeStreamLocked() {
        guard let fh = streamFileHandle else { return }
        flushStreamBufferLocked()
        try? fh.close()
        streamFileHandle = nil
    }

    /// Caller must hold `lock`.
    private func flushStreamBufferLocked() {
        guard let fh = streamFileHandle, !streamBuffer.isEmpty else { return }
        try? fh.write(contentsOf: streamBuffer)
        streamBuffer.removeAll(keepingCapacity: true)
    }
}
