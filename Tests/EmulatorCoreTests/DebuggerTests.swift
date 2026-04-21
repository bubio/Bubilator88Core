import Foundation
import Testing
@testable import EmulatorCore

@Suite("Debugger Tests")
struct DebuggerTests {

    // MARK: - Breakpoint bookkeeping

    @Test func addAndRemoveMainPCBreakpoint() {
        let dbg = Debugger()
        let bp = Breakpoint(kind: .mainPC(0x1234))

        dbg.add(bp)
        #expect(dbg.breakpoints.count == 1)
        #expect(dbg.shouldStepMain(pc: 0x1234) == false)
        #expect(dbg.shouldStepMain(pc: 0x1235) == true)

        dbg.remove(id: bp.id)
        #expect(dbg.breakpoints.isEmpty)
        // After removal the address should no longer trip the hot path.
        // Reset the paused state from the previous hit before re-checking.
        dbg.resume()
        #expect(dbg.shouldStepMain(pc: 0x1234) == true)
    }

    @Test func disabledBreakpointDoesNotFire() {
        let dbg = Debugger()
        let bp = Breakpoint(kind: .mainPC(0x2000), isEnabled: false)
        dbg.add(bp)
        #expect(dbg.shouldStepMain(pc: 0x2000) == true)

        dbg.setEnabled(true, id: bp.id)
        #expect(dbg.shouldStepMain(pc: 0x2000) == false)
    }

    @Test func subPCBreakpoint() {
        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .subPC(0x0040)))
        #expect(dbg.shouldStepSub(pc: 0x0040) == false)
        #expect(dbg.isPaused)
    }

    // MARK: - Run state transitions

    @Test func initialStateIsRunning() {
        let dbg = Debugger()
        #expect(dbg.runState == .running)
        #expect(!dbg.isPaused)
    }

    @Test func pauseAndResume() {
        let dbg = Debugger()
        dbg.pauseRequest()
        #expect(dbg.isPaused)
        dbg.resume()
        #expect(!dbg.isPaused)
    }

    @Test func singleTickAdvancesByExactlyOneInstructionWhenPaused() {
        // Single-stepping is now a UI-layer concern: the app stops
        // the Metal/audio run loop and then calls machine.tick()
        // directly for one instruction. Verify that calling tick()
        // once with the debugger attached runs exactly one opcode.
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false
        for i in 0..<16 {
            machine.bus.mainRAM[i] = 0x00  // NOP sled
        }

        let dbg = Debugger()
        machine.debugger = dbg
        dbg.pauseRequest()  // Machine.run returns 0 from now on

        _ = machine.tick()
        #expect(machine.cpu.pc == 0x0001)  // exactly one NOP executed
        #expect(dbg.isPaused)  // pause state survives the tick
    }

    // MARK: - Machine integration

    @Test func machineStopsAtMainPCBreakpoint() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        // NOP; NOP; NOP; NOP; ...
        for i in 0..<16 {
            machine.bus.mainRAM[i] = 0x00
        }

        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .mainPC(0x0003)))
        machine.debugger = dbg

        // Ask to run enough T-states for many NOPs.
        _ = machine.run(tStates: 1000)

        // Should have stopped at PC = 0x0003 after executing 3 NOPs.
        #expect(machine.cpu.pc == 0x0003)
        #expect(dbg.isPaused)
    }

    @Test func pauseRequestFreezesMachineRun() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false
        for i in 0..<16 {
            machine.bus.mainRAM[i] = 0x00  // NOPs
        }

        let dbg = Debugger()
        machine.debugger = dbg
        dbg.pauseRequest()

        let consumed = machine.run(tStates: 1000)

        #expect(consumed == 0)
        #expect(machine.cpu.pc == 0x0000)  // nothing executed
        #expect(dbg.isPaused)
    }

    @Test func machineStopsAtMemoryWriteBreakpoint() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        // LD A,42; LD (0x8000),A; NOP; NOP; ...
        machine.bus.mainRAM[0x0000] = 0x3E  // LD A,n
        machine.bus.mainRAM[0x0001] = 0x42
        machine.bus.mainRAM[0x0002] = 0x32  // LD (nn),A
        machine.bus.mainRAM[0x0003] = 0x00
        machine.bus.mainRAM[0x0004] = 0x80
        for i in 5..<16 {
            machine.bus.mainRAM[i] = 0x00
        }

        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .memoryWrite(0x8000)))
        machine.debugger = dbg

        _ = machine.run(tStates: 1000)

        #expect(dbg.isPaused)
        // PC should be at or just past the LD (nn),A instruction (0x0005).
        #expect(machine.cpu.pc == 0x0005)
        #expect(machine.bus.mainRAM[0x8000] == 0x42)  // write landed
    }

    @Test func memoryWriteBreakpointWithValueFilterOnlyFiresOnMatch() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        // LD A,10H ; LD (8000h),A ; LD A,42H ; LD (8000h),A ; NOP ...
        let prog: [UInt8] = [
            0x3E, 0x10,             // LD A,10H
            0x32, 0x00, 0x80,       // LD (8000h),A
            0x3E, 0x42,             // LD A,42H
            0x32, 0x00, 0x80,       // LD (8000h),A
            0x00, 0x00, 0x00, 0x00  // NOPs
        ]
        for (i, b) in prog.enumerated() {
            machine.bus.mainRAM[i] = b
        }

        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .memoryWrite(0x8000), valueFilter: 0x42))
        machine.debugger = dbg

        _ = machine.run(tStates: 2000)

        // Should stop on the SECOND write (value 0x42), not the first (0x10).
        #expect(dbg.isPaused)
        #expect(machine.bus.mainRAM[0x8000] == 0x42)
        // PC should be at or just past the second LD (nn),A — 0x000A.
        #expect(machine.cpu.pc == 0x000A)
    }

    @Test func memoryWriteBreakpointWithoutFilterFiresOnAnyValue() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        machine.bus.mainRAM[0x0000] = 0x3E  // LD A,10H
        machine.bus.mainRAM[0x0001] = 0x10
        machine.bus.mainRAM[0x0002] = 0x32  // LD (8000h),A
        machine.bus.mainRAM[0x0003] = 0x00
        machine.bus.mainRAM[0x0004] = 0x80

        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .memoryWrite(0x8000)))  // no filter
        machine.debugger = dbg

        _ = machine.run(tStates: 1000)

        #expect(dbg.isPaused)
        #expect(machine.bus.mainRAM[0x8000] == 0x10)
    }

    @Test func machineStopsAtMemoryReadBreakpoint() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        // LD A,(0x8000); NOP; ...
        machine.bus.mainRAM[0x0000] = 0x3A  // LD A,(nn)
        machine.bus.mainRAM[0x0001] = 0x00
        machine.bus.mainRAM[0x0002] = 0x80
        for i in 3..<16 {
            machine.bus.mainRAM[i] = 0x00
        }
        machine.bus.mainRAM[0x8000] = 0x7E

        let dbg = Debugger()
        dbg.add(Breakpoint(kind: .memoryRead(0x8000)))
        machine.debugger = dbg

        _ = machine.run(tStates: 1000)

        #expect(dbg.isPaused)
        #expect(machine.cpu.a == 0x7E)  // load completed
    }

    // MARK: - Instruction trace

    @Test func traceCapturesRunInstructions() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false
        for i in 0..<16 {
            machine.bus.mainRAM[i] = 0x00  // NOP sled
        }

        let dbg = Debugger()
        machine.debugger = dbg

        // Run a few NOPs by calling tick() directly (the UI-layer
        // equivalent of pressing Step 5 times).
        for _ in 0..<5 {
            _ = machine.tick()
        }

        let trace = dbg.traceSnapshot()
        #expect(trace.count == 5)
        #expect(trace[0].pc == 0x0000)
        #expect(trace[1].pc == 0x0001)
        #expect(trace[4].pc == 0x0004)
    }

    @Test func traceRingBufferWrapsAtCapacity() {
        let dbg = Debugger()
        let cap = Debugger.traceCapacity

        // Append cap + 10 entries with distinct PCs.
        for i in 0..<(cap + 10) {
            dbg.recordTraceEntry(InstructionTraceEntry(
                pc: UInt16(truncatingIfNeeded: i),
                af: 0, bc: 0, de: 0, hl: 0, sp: 0
            ))
        }

        let trace = dbg.traceSnapshot()
        #expect(trace.count == cap)
        // Oldest preserved is entry #10 (the first 10 were overwritten).
        #expect(trace.first?.pc == 10)
        #expect(trace.last?.pc == UInt16(truncatingIfNeeded: cap + 9))
    }

    @Test func clearTraceDropsAllEntries() {
        let dbg = Debugger()
        for i in 0..<5 {
            dbg.recordTraceEntry(InstructionTraceEntry(
                pc: UInt16(i), af: 0, bc: 0, de: 0, hl: 0, sp: 0
            ))
        }
        #expect(dbg.traceSnapshot().count == 5)
        dbg.clearTrace()
        #expect(dbg.traceSnapshot().isEmpty)
    }

    @Test func traceCapturesFullZ80State() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false

        // LD IX,1234H ; NOP ; NOP
        machine.bus.mainRAM[0x0000] = 0xDD
        machine.bus.mainRAM[0x0001] = 0x21
        machine.bus.mainRAM[0x0002] = 0x34
        machine.bus.mainRAM[0x0003] = 0x12
        machine.bus.mainRAM[0x0004] = 0x00
        machine.bus.mainRAM[0x0005] = 0x00

        let dbg = Debugger()
        machine.debugger = dbg

        for _ in 0..<3 {
            _ = machine.tick()
        }

        let trace = dbg.traceSnapshot()
        #expect(trace.count == 3)
        // Entry[0] is the state *before* LD IX,1234H → IX still at reset value (0xFFFF).
        #expect(trace[0].ix == 0xFFFF)
        // Entries[1] and [2] come after the load, so IX is populated.
        #expect(trace[1].ix == 0x1234)
        #expect(trace[2].ix == 0x1234)
    }

    // MARK: - Sub-CPU trace

    @Test func subTraceRingBufferWrapsAtCapacity() {
        let dbg = Debugger()
        let cap = Debugger.traceCapacity

        for i in 0..<(cap + 10) {
            dbg.recordSubTraceEntry(InstructionTraceEntry(
                pc: UInt16(truncatingIfNeeded: i),
                af: 0, bc: 0, de: 0, hl: 0, sp: 0
            ))
        }

        let trace = dbg.subTraceSnapshot()
        #expect(trace.count == cap)
        #expect(trace.first?.pc == 10)
        #expect(trace.last?.pc == UInt16(truncatingIfNeeded: cap + 9))
    }

    // MARK: - Instruction trace JSONL export

    @Test func instructionTraceJSONLSingleLine() {
        let entry = InstructionTraceEntry(
            pc: 0x1000,
            af: 0x00C4, bc: 0x0011, de: 0x2233, hl: 0x4455,
            ix: 0x6677, iy: 0x8899,
            sp: 0xFFEE,
            af2: 0x1122, bc2: 0x3344, de2: 0x5566, hl2: 0x7788,
            i: 0x0A, r: 0x7F
        )
        let line = InstructionTraceJSONL.line(seq: 3, entry: entry)
        #expect(line == #"{"seq":3,"pc":"1000","af":"00C4","bc":"0011","de":"2233","hl":"4455","ix":"6677","iy":"8899","sp":"FFEE","af2":"1122","bc2":"3344","de2":"5566","hl2":"7788","i":"0A","r":"7F"}"#)
    }

    @Test func instructionTraceJSONLRenderMultipleLines() {
        let entries = [
            InstructionTraceEntry(pc: 0x1000, af: 0, bc: 0, de: 0, hl: 0, sp: 0),
            InstructionTraceEntry(pc: 0x1003, af: 0, bc: 0, de: 0, hl: 0, sp: 0),
        ]
        let text = InstructionTraceJSONL.render(entries)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)  // 2 entries + trailing empty line
        #expect(lines[0].contains("\"seq\":0"))
        #expect(lines[0].contains("\"pc\":\"1000\""))
        #expect(lines[1].contains("\"seq\":1"))
        #expect(lines[1].contains("\"pc\":\"1003\""))
    }

    @Test func mainAndSubTracesAreIndependent() {
        let dbg = Debugger()
        dbg.recordTraceEntry(InstructionTraceEntry(
            pc: 0x1000, af: 0, bc: 0, de: 0, hl: 0, sp: 0
        ))
        dbg.recordSubTraceEntry(InstructionTraceEntry(
            pc: 0x0700, af: 0, bc: 0, de: 0, hl: 0, sp: 0
        ))

        #expect(dbg.traceSnapshot().count == 1)
        #expect(dbg.subTraceSnapshot().count == 1)
        #expect(dbg.traceSnapshot().first?.pc == 0x1000)
        #expect(dbg.subTraceSnapshot().first?.pc == 0x0700)

        dbg.clearTrace()
        #expect(dbg.traceSnapshot().isEmpty)
        #expect(dbg.subTraceSnapshot().count == 1)  // sub side preserved

        dbg.clearSubTrace()
        #expect(dbg.subTraceSnapshot().isEmpty)
    }

    // MARK: - PIO flow log

    @Test func pioFlowRingBufferWrapsAtCapacity() {
        let dbg = Debugger()
        let cap = Debugger.pioFlowCapacity

        for i in 0..<(cap + 5) {
            dbg.recordPIOFlow(PIOFlowEntry(
                mainPC: UInt16(truncatingIfNeeded: i),
                subPC: 0,
                side: .main,
                port: .a,
                isWrite: i % 2 == 0,
                value: UInt8(truncatingIfNeeded: i)
            ))
        }

        let flow = dbg.pioFlowSnapshot()
        #expect(flow.count == cap)
        #expect(flow.first?.mainPC == 5)  // first 5 overwritten
        #expect(flow.last?.mainPC == UInt16(truncatingIfNeeded: cap + 4))
    }

    @Test func machineRecordsPIOFlowOnPortAccess() {
        let machine = Machine()
        machine.reset()

        let dbg = Debugger()
        machine.debugger = dbg

        // Direct PIO access from the main CPU side: port A write.
        machine.subSystem.pio.writeAB(side: .main, port: .portA, data: 0x5A)

        let flow = dbg.pioFlowSnapshot()
        #expect(flow.count == 1)
        #expect(flow[0].side == .main)
        #expect(flow[0].port == .a)
        #expect(flow[0].isWrite == true)
        #expect(flow[0].value == 0x5A)
    }

    @Test func clearPIOFlowDropsAllEntries() {
        let dbg = Debugger()
        dbg.recordPIOFlow(PIOFlowEntry(
            mainPC: 0, subPC: 0, side: .main, port: .a,
            isWrite: true, value: 0
        ))
        #expect(dbg.pioFlowSnapshot().count == 1)
        dbg.clearPIOFlow()
        #expect(dbg.pioFlowSnapshot().isEmpty)
    }

    // MARK: - PIO flow JSONL export (cross-emulator diff format)

    @Test func pioFlowJSONLSingleLine() {
        let entry = PIOFlowEntry(
            mainPC: 0x1C5A, subPC: 0x6830,
            side: .sub, port: .b, isWrite: true, value: 0x3B
        )
        let line = PIOFlowJSONL.line(seq: 42, entry: entry)
        #expect(line == #"{"seq":42,"mainPC":"1C5A","subPC":"6830","side":"sub","port":"B","op":"W","val":"3B"}"#)
    }

    @Test func pioFlowJSONLRenderMultipleLines() {
        let entries = [
            PIOFlowEntry(mainPC: 0x1000, subPC: 0x0000,
                         side: .main, port: .a, isWrite: false, value: 0x00),
            PIOFlowEntry(mainPC: 0x1003, subPC: 0x6650,
                         side: .sub,  port: .b, isWrite: true,  value: 0xFF),
        ]
        let text = PIOFlowJSONL.render(entries)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)  // 2 entries + trailing empty line
        #expect(lines[0].contains("\"seq\":0"))
        #expect(lines[0].contains("\"side\":\"main\""))
        #expect(lines[1].contains("\"seq\":1"))
        #expect(lines[1].contains("\"val\":\"FF\""))
    }

    // MARK: - PIO flow streaming to file

    @Test func pioFlowStreamWritesEveryEvent() throws {
        let dbg = Debugger()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pioflow-stream-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try dbg.startPIOFlowStream(to: tmp)
        #expect(dbg.isStreamingPIOFlow)

        // Feed far more entries than the ring buffer capacity so
        // we prove the stream bypasses it entirely.
        let count = Debugger.pioFlowCapacity + 50
        for i in 0..<count {
            dbg.recordPIOFlow(PIOFlowEntry(
                mainPC: UInt16(truncatingIfNeeded: i),
                subPC: 0,
                side: .main,
                port: .a,
                isWrite: i % 2 == 0,
                value: UInt8(truncatingIfNeeded: i)
            ))
        }

        dbg.stopPIOFlowStream()
        #expect(!dbg.isStreamingPIOFlow)

        let text = try String(contentsOf: tmp, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == count)
        #expect(lines.first!.contains("\"seq\":0"))
        #expect(lines.last!.contains("\"seq\":\(count - 1)"))
    }

    @Test func pioFlowJSONLRendersControlPort() {
        // BSR on main side: bit 7 = 0 (BSR), bit 0 = 1 (SET), bits 1-3 = 100 (bit 4)
        // → 0x09 = set bit 4 of port C
        let entry = PIOFlowEntry(
            mainPC: 0x1CBB, subPC: 0x06DF,
            side: .main, port: .control, isWrite: true, value: 0x09
        )
        let line = PIOFlowJSONL.line(seq: 0, entry: entry)
        #expect(line == #"{"seq":0,"mainPC":"1CBB","subPC":"06DF","side":"main","port":"FF","op":"W","val":"09"}"#)
    }

    @Test func pioFlowStreamSequenceIndependentOfRingBuffer() throws {
        let dbg = Debugger()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pioflow-stream-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Record some events WITHOUT streaming (fill ring buffer a bit).
        for i in 0..<5 {
            dbg.recordPIOFlow(PIOFlowEntry(
                mainPC: UInt16(i), subPC: 0, side: .main, port: .a,
                isWrite: true, value: 0xAA
            ))
        }

        // Now start streaming; the stream seq should start from 0
        // even though the ring buffer already has 5 entries.
        try dbg.startPIOFlowStream(to: tmp)
        for i in 0..<3 {
            dbg.recordPIOFlow(PIOFlowEntry(
                mainPC: UInt16(i), subPC: 0, side: .sub, port: .b,
                isWrite: false, value: 0xBB
            ))
        }
        dbg.stopPIOFlowStream()

        let text = try String(contentsOf: tmp, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3)
        #expect(lines[0].contains("\"seq\":0"))
        #expect(lines[2].contains("\"seq\":2"))
    }

    @Test func machinePausedIsFrozen() {
        let machine = Machine()
        machine.reset()
        machine.bus.ramMode = true
        machine.bus.cpuClock8MHz = false
        machine.bus.mainRAM[0] = 0x00

        let dbg = Debugger()
        machine.debugger = dbg
        dbg.pauseRequest()

        let consumed = machine.run(tStates: 1000)
        #expect(consumed == 0)
        #expect(machine.cpu.pc == 0x0000)
    }

    // MARK: - Disassembler

    @Test func disassembleNOP() {
        let inst = Disassembler.decode(at: 0x0000) { _ in 0x00 }
        #expect(inst.mnemonic == "NOP")
        #expect(inst.bytes == [0x00])
    }

    @Test func disassembleLDAn() {
        // 3E 42  →  LD A,42H
        let bytes: [UInt8] = [0x3E, 0x42, 0x00, 0x00]
        let inst = Disassembler.decode(at: 0x1000) { addr in
            bytes[Int(addr - 0x1000)]
        }
        #expect(inst.mnemonic == "LD A,42H")
        #expect(inst.bytes == [0x3E, 0x42])
        #expect(inst.nextAddress == 0x1002)
    }

    @Test func disassembleJPnn() {
        // C3 34 12 → JP 1234H
        let bytes: [UInt8] = [0xC3, 0x34, 0x12, 0x00]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "JP 1234H")
        #expect(inst.bytes.count == 3)
    }

    @Test func disassembleCALLnn() {
        // CD 00 80 → CALL 8000H
        let bytes: [UInt8] = [0xCD, 0x00, 0x80, 0x00]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "CALL 8000H")
    }

    @Test func disassembleLDRR() {
        // 78 → LD A,B
        let inst = Disassembler.decode(at: 0x0000) { _ in 0x78 }
        #expect(inst.mnemonic == "LD A,B")
    }

    @Test func disassembleJRrelative() {
        // 18 FE → JR 0000H  (infinite loop at 0000)
        let bytes: [UInt8] = [0x18, 0xFE, 0x00, 0x00]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "JR 0000H")
    }

    @Test func disassembleEDLdir() {
        // ED B0 → LDIR
        let bytes: [UInt8] = [0xED, 0xB0, 0x00, 0x00]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "LDIR")
        #expect(inst.bytes.count == 2)
    }

    @Test func disassembleCBBIT() {
        // CB 7F → BIT 7,A
        let bytes: [UInt8] = [0xCB, 0x7F, 0x00, 0x00]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "BIT 7,A")
    }

    @Test func disassembleDDLdIXnn() {
        // DD 21 00 80 → LD IX,8000H
        let bytes: [UInt8] = [0xDD, 0x21, 0x00, 0x80]
        let inst = Disassembler.decode(at: 0x0000) { addr in bytes[Int(addr)] }
        #expect(inst.mnemonic == "LD IX,8000H")
        #expect(inst.bytes.count == 4)
    }
}
