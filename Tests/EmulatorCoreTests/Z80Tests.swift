import Testing
@testable import EmulatorCore

@Suite("Z80 Core Tests")
struct Z80Tests {

    // MARK: - Reset

    @Test func resetSetsCorrectInitialState() {
        let cpu = Z80()
        cpu.reset()

        #expect(cpu.pc == 0x0000)
        #expect(cpu.sp == 0x0000)
        #expect(cpu.af == 0x0040)
        #expect(cpu.bc == 0x0000)
        #expect(cpu.de == 0x0000)
        #expect(cpu.hl == 0x0000)
        #expect(cpu.ix == 0xFFFF)
        #expect(cpu.iy == 0xFFFF)
        #expect(cpu.i == 0x00)
        #expect(cpu.r == 0x00)
        #expect(cpu.iff1 == false)
        #expect(cpu.iff2 == false)
        #expect(cpu.im == 0)
        #expect(cpu.halted == false)
    }

    // MARK: - Register Accessors

    @Test func eightBitRegisterAccessors() {
        let cpu = Z80()
        cpu.af = 0x1234
        #expect(cpu.a == 0x12)
        #expect(cpu.f == 0x34)

        cpu.a = 0xAB
        #expect(cpu.af == 0xAB34)
        cpu.f = 0xCD
        #expect(cpu.af == 0xABCD)

        cpu.bc = 0x5678
        #expect(cpu.b == 0x56)
        #expect(cpu.c == 0x78)

        cpu.de = 0x9ABC
        #expect(cpu.d == 0x9A)
        #expect(cpu.e == 0xBC)

        cpu.hl = 0xDEF0
        #expect(cpu.h == 0xDE)
        #expect(cpu.l == 0xF0)
    }

    // MARK: - NOP

    @Test func nopTakes4TStates() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        bus.load(at: 0x0000, data: [0x00])  // NOP

        let cycles = cpu.step(bus: bus)
        #expect(cycles == 4)
        #expect(cpu.pc == 0x0001)
    }

    // MARK: - LD r, n (immediate)

    @Test func ldRegImmediate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD B, 0x42
        bus.load(at: 0x0000, data: [0x06, 0x42])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 7)
        #expect(cpu.b == 0x42)

        // LD A, 0xFF
        bus.load(at: 0x0002, data: [0x3E, 0xFF])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
    }

    // MARK: - LD rr, nn (16-bit immediate)

    @Test func ldRegPairImmediate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD BC, 0x1234
        bus.load(at: 0x0000, data: [0x01, 0x34, 0x12])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 10)
        #expect(cpu.bc == 0x1234)

        // LD DE, 0x5678
        bus.load(at: 0x0003, data: [0x11, 0x78, 0x56])
        _ = cpu.step(bus: bus)
        #expect(cpu.de == 0x5678)

        // LD HL, 0x9ABC
        bus.load(at: 0x0006, data: [0x21, 0xBC, 0x9A])
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x9ABC)

        // LD SP, 0xDEF0
        bus.load(at: 0x0009, data: [0x31, 0xF0, 0xDE])
        _ = cpu.step(bus: bus)
        #expect(cpu.sp == 0xDEF0)
    }

    // MARK: - LD r, r' (register to register)

    @Test func ldRegToReg() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.a = 0x42

        // LD B, A (0x47)
        bus.load(at: 0x0000, data: [0x47])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 4)
        #expect(cpu.b == 0x42)
    }

    // MARK: - Memory loads

    @Test func ldIndirectMemory() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD (HL), A with HL=0x8000, A=0x55
        cpu.hl = 0x8000
        cpu.a = 0x55
        bus.load(at: 0x0000, data: [0x77])  // LD (HL), A
        let cycles1 = cpu.step(bus: bus)
        #expect(cycles1 == 7)
        #expect(bus.memory[0x8000] == 0x55)

        // LD A, (HL) with (HL)=0x55
        cpu.a = 0x00
        bus.load(at: 0x0001, data: [0x7E])  // LD A, (HL)
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x55)
    }

    // MARK: - INC / DEC (8-bit)

    @Test func incDec8Bit() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // INC B from 0
        cpu.b = 0x00
        bus.load(at: 0x0000, data: [0x04])  // INC B
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x01)
        #expect(cpu.flagZ == false)
        #expect(cpu.flagN == false)

        // INC B from 0xFF -> overflow to 0
        cpu.b = 0xFF
        bus.load(at: 0x0001, data: [0x04])
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x00)
        #expect(cpu.flagZ == true)
        #expect(cpu.flagH == true)

        // INC B from 0x7F -> overflow flag
        cpu.b = 0x7F
        bus.load(at: 0x0002, data: [0x04])
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x80)
        #expect(cpu.flagPV == true)  // overflow
        #expect(cpu.flagS == true)   // negative

        // DEC A from 1
        cpu.a = 0x01
        bus.load(at: 0x0003, data: [0x3D])  // DEC A
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagZ == true)
        #expect(cpu.flagN == true)
    }

    // MARK: - INC / DEC (16-bit)

    @Test func incDec16Bit() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.bc = 0x00FF
        bus.load(at: 0x0000, data: [0x03])  // INC BC
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 6)
        #expect(cpu.bc == 0x0100)

        cpu.de = 0x0000
        bus.load(at: 0x0001, data: [0x1B])  // DEC DE
        _ = cpu.step(bus: bus)
        #expect(cpu.de == 0xFFFF)
    }

    // MARK: - ADD / SUB

    @Test func add8Bit() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x10
        cpu.b = 0x20
        bus.load(at: 0x0000, data: [0x80])  // ADD A, B
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 4)
        #expect(cpu.a == 0x30)
        #expect(cpu.flagC == false)
        #expect(cpu.flagZ == false)
        #expect(cpu.flagN == false)
    }

    @Test func addOverflow() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x7F
        cpu.b = 0x01
        bus.load(at: 0x0000, data: [0x80])  // ADD A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x80)
        #expect(cpu.flagPV == true)  // overflow
        #expect(cpu.flagS == true)
    }

    @Test func addCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0xFF
        cpu.b = 0x01
        bus.load(at: 0x0000, data: [0x80])  // ADD A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagC == true)
        #expect(cpu.flagZ == true)
    }

    @Test func sub8Bit() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x30
        cpu.b = 0x10
        bus.load(at: 0x0000, data: [0x90])  // SUB B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x20)
        #expect(cpu.flagN == true)
        #expect(cpu.flagC == false)
    }

    @Test func subBorrow() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x00
        cpu.b = 0x01
        bus.load(at: 0x0000, data: [0x90])  // SUB B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
        #expect(cpu.flagC == true)
    }

    // MARK: - AND / OR / XOR / CP

    @Test func logicOps() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // AND
        cpu.a = 0xFF
        cpu.b = 0x0F
        bus.load(at: 0x0000, data: [0xA0])  // AND B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x0F)
        #expect(cpu.flagH == true)

        // XOR A (self) -> zero
        bus.load(at: 0x0001, data: [0xAF])  // XOR A
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagZ == true)

        // OR
        cpu.a = 0xF0
        cpu.b = 0x0F
        bus.load(at: 0x0002, data: [0xB0])  // OR B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
    }

    @Test func cpInstruction() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x42
        cpu.b = 0x42
        bus.load(at: 0x0000, data: [0xB8])  // CP B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x42)  // A unchanged
        #expect(cpu.flagZ == true)
        #expect(cpu.flagN == true)

        cpu.b = 0x43
        bus.load(at: 0x0001, data: [0xB8])  // CP B
        _ = cpu.step(bus: bus)
        #expect(cpu.flagC == true)  // A < B
    }

    // MARK: - Jumps

    @Test func jumpAbsolute() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // JP 0x1234
        bus.load(at: 0x0000, data: [0xC3, 0x34, 0x12])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 10)
        #expect(cpu.pc == 0x1234)
    }

    @Test func jumpRelative() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // JR +5 (from PC=2 after fetching opcode+displacement)
        bus.load(at: 0x0000, data: [0x18, 0x05])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 12)
        #expect(cpu.pc == 0x0007)  // 0x0002 + 5

        // JR -3 (backward jump)
        cpu.pc = 0x0010
        bus.load(at: 0x0010, data: [0x18, 0xFD])  // -3
        _ = cpu.step(bus: bus)
        #expect(cpu.pc == 0x000F)  // 0x0012 - 3
    }

    @Test func jumpConditional() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // JP NZ, 0x1000 — with Z=false, should jump
        cpu.f = 0x00  // Z flag clear
        bus.load(at: 0x0000, data: [0xC2, 0x00, 0x10])
        _ = cpu.step(bus: bus)
        #expect(cpu.pc == 0x1000)

        // JP NZ, 0x2000 — with Z=true, should not jump
        cpu.f = Z80.flagZ
        bus.load(at: 0x1000, data: [0xC2, 0x00, 0x20])
        _ = cpu.step(bus: bus)
        #expect(cpu.pc == 0x1003)  // just past the instruction
    }

    // MARK: - CALL / RET

    @Test func callAndRet() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.sp = 0xFF00

        // CALL 0x1234
        bus.load(at: 0x0000, data: [0xCD, 0x34, 0x12])
        let callCycles = cpu.step(bus: bus)
        #expect(callCycles == 17)
        #expect(cpu.pc == 0x1234)
        #expect(cpu.sp == 0xFEFE)
        // Return address (0x0003) pushed on stack
        #expect(bus.memory[0xFEFE] == 0x03)  // low byte
        #expect(bus.memory[0xFEFF] == 0x00)  // high byte

        // RET
        bus.load(at: 0x1234, data: [0xC9])
        let retCycles = cpu.step(bus: bus)
        #expect(retCycles == 10)
        #expect(cpu.pc == 0x0003)
        #expect(cpu.sp == 0xFF00)
    }

    // MARK: - PUSH / POP

    @Test func pushPop() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.sp = 0xFF00
        cpu.bc = 0x1234

        // PUSH BC
        bus.load(at: 0x0000, data: [0xC5])
        _ = cpu.step(bus: bus)
        #expect(cpu.sp == 0xFEFE)
        #expect(bus.memory[0xFEFF] == 0x12)  // B
        #expect(bus.memory[0xFEFE] == 0x34)  // C

        // POP DE
        bus.load(at: 0x0001, data: [0xD1])
        _ = cpu.step(bus: bus)
        #expect(cpu.de == 0x1234)
        #expect(cpu.sp == 0xFF00)
    }

    // MARK: - HALT

    @Test func haltBehavior() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        bus.load(at: 0x0000, data: [0x76])  // HALT
        _ = cpu.step(bus: bus)
        #expect(cpu.halted == true)
        #expect(cpu.pc == 0x0000)  // PC stays on HALT

        // Subsequent steps still return 4 T-states (NOP) and PC stays
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 4)
        #expect(cpu.pc == 0x0000)
    }

    // MARK: - EI / DI

    @Test func eiDiInterruptControl() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // DI
        cpu.iff1 = true
        cpu.iff2 = true
        bus.load(at: 0x0000, data: [0xF3])  // DI
        _ = cpu.step(bus: bus)
        #expect(cpu.iff1 == false)
        #expect(cpu.iff2 == false)

        // EI — should be delayed by one instruction
        bus.load(at: 0x0001, data: [0xFB, 0x00])  // EI, NOP
        _ = cpu.step(bus: bus)  // EI executed
        #expect(cpu.iff1 == false)  // not yet enabled
        _ = cpu.step(bus: bus)  // NOP — now EI takes effect
        #expect(cpu.iff1 == true)
        #expect(cpu.iff2 == true)
    }

    // MARK: - Interrupt (IM2)

    @Test func im2InterruptVector() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.iff1 = true
        cpu.iff2 = true
        cpu.im = 2
        cpu.i = 0x80
        cpu.sp = 0xFF00
        cpu.pc = 0x1000

        // Set up vector table at 0x800C (I=0x80, vector=0x0C)
        bus.memory[0x800C] = 0x00  // ISR address low
        bus.memory[0x800D] = 0x20  // ISR address high = 0x2000

        let cycles = cpu.interrupt(vector: 0x0C, bus: bus)
        #expect(cycles == 19)
        #expect(cpu.pc == 0x2000)
        #expect(cpu.iff1 == false)
        #expect(cpu.iff2 == false)
        #expect(cpu.sp == 0xFEFE)
        // Return address on stack
        #expect(bus.memory[0xFEFE] == 0x00)  // low byte of 0x1000
        #expect(bus.memory[0xFEFF] == 0x10)  // high byte of 0x1000
    }

    @Test func interruptRejectedWhenDisabled() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.iff1 = false
        cpu.pc = 0x1000

        let cycles = cpu.interrupt(vector: 0x0C, bus: bus)
        #expect(cycles == 0)
        #expect(cpu.pc == 0x1000)  // unchanged
    }

    @Test func interruptWakesFromHalt() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.iff1 = true
        cpu.im = 2
        cpu.i = 0x80
        cpu.sp = 0xFF00
        cpu.halted = true
        cpu.pc = 0x0050

        bus.memory[0x800C] = 0x00
        bus.memory[0x800D] = 0x30

        let cycles = cpu.interrupt(vector: 0x0C, bus: bus)
        #expect(cycles == 19)
        #expect(cpu.halted == false)
        #expect(cpu.pc == 0x3000)
    }

    // MARK: - Rotate/Shift

    @Test func rlcaRotate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x85  // 10000101
        bus.load(at: 0x0000, data: [0x07])  // RLCA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x0B)  // 00001011
        #expect(cpu.flagC == true)  // bit 7 was 1
    }

    @Test func rrcaRotate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x85  // 10000101
        bus.load(at: 0x0000, data: [0x0F])  // RRCA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xC2)  // 11000010 + bit0(1)→bit7
        #expect(cpu.flagC == true)
    }

    // MARK: - EX / EXX

    @Test func exchangeOperations() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.af = 0x1234
        cpu.af2 = 0x5678
        bus.load(at: 0x0000, data: [0x08])  // EX AF, AF'
        _ = cpu.step(bus: bus)
        #expect(cpu.af == 0x5678)
        #expect(cpu.af2 == 0x1234)

        cpu.bc = 0xAAAA
        cpu.de = 0xBBBB
        cpu.hl = 0xCCCC
        cpu.bc2 = 0x1111
        cpu.de2 = 0x2222
        cpu.hl2 = 0x3333
        bus.load(at: 0x0001, data: [0xD9])  // EXX
        _ = cpu.step(bus: bus)
        #expect(cpu.bc == 0x1111)
        #expect(cpu.de == 0x2222)
        #expect(cpu.hl == 0x3333)
        #expect(cpu.bc2 == 0xAAAA)
        #expect(cpu.de2 == 0xBBBB)
        #expect(cpu.hl2 == 0xCCCC)
    }

    // MARK: - DJNZ

    @Test func djnzLoop() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.b = 3
        // DJNZ -2 (loop back to itself)
        bus.load(at: 0x0000, data: [0x10, 0xFE])

        let c1 = cpu.step(bus: bus)
        #expect(c1 == 13)  // branch taken
        #expect(cpu.b == 2)
        #expect(cpu.pc == 0x0000)

        let c2 = cpu.step(bus: bus)
        #expect(c2 == 13)
        #expect(cpu.b == 1)
        #expect(cpu.pc == 0x0000)

        let c3 = cpu.step(bus: bus)
        #expect(c3 == 8)  // branch not taken (B=0)
        #expect(cpu.b == 0)
        #expect(cpu.pc == 0x0002)
    }

    // MARK: - RST

    @Test func rstInstruction() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.sp = 0xFF00
        cpu.pc = 0x0100

        bus.load(at: 0x0100, data: [0xCF])  // RST 08h
        _ = cpu.step(bus: bus)
        #expect(cpu.pc == 0x0008)
        #expect(cpu.sp == 0xFEFE)
    }

    // MARK: - CB prefix (bit operations)

    @Test func cbBitTest() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x80  // bit 7 set
        // BIT 7, A (CB 7F)
        bus.load(at: 0x0000, data: [0xCB, 0x7F])
        _ = cpu.step(bus: bus)
        #expect(cpu.flagZ == false)  // bit 7 is set

        // BIT 0, A (CB 47)
        bus.load(at: 0x0002, data: [0xCB, 0x47])
        _ = cpu.step(bus: bus)
        #expect(cpu.flagZ == true)  // bit 0 is clear
    }

    @Test func cbSetRes() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x00
        // SET 3, A (CB DF)
        bus.load(at: 0x0000, data: [0xCB, 0xDF])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x08)

        // RES 3, A (CB 9F)
        bus.load(at: 0x0002, data: [0xCB, 0x9F])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
    }

    @Test func cbRotateShift() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // SLA B (CB 20): shift left arithmetic
        cpu.b = 0x85  // 10000101
        bus.load(at: 0x0000, data: [0xCB, 0x20])
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x0A)  // 00001010
        #expect(cpu.flagC == true)

        // SRL B (CB 38): shift right logical
        cpu.b = 0x81
        bus.load(at: 0x0002, data: [0xCB, 0x38])
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x40)
        #expect(cpu.flagC == true)
    }

    // MARK: - ED prefix

    @Test func edIM2() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        bus.load(at: 0x0000, data: [0xED, 0x5E])  // IM 2
        _ = cpu.step(bus: bus)
        #expect(cpu.im == 2)
    }

    @Test func edLdIR() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD I, A
        cpu.a = 0x80
        bus.load(at: 0x0000, data: [0xED, 0x47])
        _ = cpu.step(bus: bus)
        #expect(cpu.i == 0x80)

        // LD A, I
        cpu.a = 0x00
        cpu.iff2 = true
        bus.load(at: 0x0002, data: [0xED, 0x57])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x80)
        #expect(cpu.flagPV == true)  // IFF2 is set
    }

    @Test func edLDIR() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Set up: copy 3 bytes from 0x1000 to 0x2000
        cpu.hl = 0x1000
        cpu.de = 0x2000
        cpu.bc = 0x0003
        bus.memory[0x1000] = 0xAA
        bus.memory[0x1001] = 0xBB
        bus.memory[0x1002] = 0xCC

        // LDIR
        bus.load(at: 0x0000, data: [0xED, 0xB0])

        // First iteration: BC=3->2, repeats
        let c1 = cpu.step(bus: bus)
        #expect(c1 == 21)
        #expect(bus.memory[0x2000] == 0xAA)
        #expect(cpu.bc == 0x0002)

        // Second iteration: BC=2->1, repeats
        let c2 = cpu.step(bus: bus)
        #expect(c2 == 21)
        #expect(bus.memory[0x2001] == 0xBB)

        // Third iteration: BC=1->0, done
        let c3 = cpu.step(bus: bus)
        #expect(c3 == 16)
        #expect(bus.memory[0x2002] == 0xCC)
        #expect(cpu.bc == 0x0000)
        #expect(cpu.pc == 0x0002)  // moves past LDIR
    }

    @Test func edIOInC() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.bc = 0x0044  // B=0x00, C=0x44
        bus.ioPorts[0x44] = 0xAB

        // IN A, (C) — ED 78
        bus.load(at: 0x0000, data: [0xED, 0x78])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xAB)
    }

    @Test func edNeg() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x01
        bus.load(at: 0x0000, data: [0xED, 0x44])  // NEG
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
        #expect(cpu.flagC == true)
        #expect(cpu.flagN == true)
    }

    @Test func daaSubtractMatchesReferenceFlags() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x15
        cpu.f = Z80.flagN | Z80.flagH
        bus.load(at: 0x0000, data: [0x27])  // DAA

        _ = cpu.step(bus: bus)

        #expect(cpu.a == 0x0F)
        #expect(cpu.flagN == true)
        #expect(cpu.flagH == true)
        #expect(cpu.flagC == false)
        #expect(cpu.flagPV == true)
    }

    @Test("DAA matches x88 reference for all C/N/H inputs")
    func daaMatchesReferenceAllStates() {
        func referenceDAA(a: UInt8, f: UInt8) -> (UInt8, UInt8) {
            let hadCarry = (f & Z80.flagC) != 0
            let subtract = (f & Z80.flagN) != 0
            let hadHalfCarry = (f & Z80.flagH) != 0

            var adjusted = Int(a)
            var outF = f & Z80.flagN
            var setCarry = false
            var setHalfCarry = false

            if !subtract {
                if (adjusted & 0x0F) > 0x09 || hadHalfCarry {
                    if (adjusted & 0x0F) > 0x09 {
                        setHalfCarry = true
                    }
                    adjusted += 0x06
                }
                if adjusted > 0x9F || hadCarry {
                    setCarry = true
                    adjusted += 0x60
                }
            } else {
                if adjusted > 0x99 || hadCarry {
                    setCarry = true
                }
                if (adjusted & 0x0F) > 0x09 || hadHalfCarry {
                    if (adjusted & 0x0F) < 0x06 {
                        setHalfCarry = true
                    }
                    adjusted -= 0x06
                }
                if adjusted > 0x9F || hadCarry {
                    adjusted -= 0x60
                }
            }

            let result = UInt8(truncatingIfNeeded: adjusted)
            if result & 0x80 != 0 { outF |= Z80.flagS }
            if result == 0 { outF |= Z80.flagZ }
            if result.nonzeroBitCount.isMultiple(of: 2) { outF |= Z80.flagPV }
            outF |= result & (Z80.flagF5 | Z80.flagF3)
            if setCarry { outF |= Z80.flagC }
            if setHalfCarry { outF |= Z80.flagH }
            return (result, outF)
        }

        let cpu = Z80()
        let bus = TestBus()
        bus.load(at: 0x0000, data: [0x27])  // DAA

        for a in UInt8.min...UInt8.max {
            for flags in 0..<8 {
                var f: UInt8 = 0
                if (flags & 0b001) != 0 { f |= Z80.flagC }
                if (flags & 0b010) != 0 { f |= Z80.flagN }
                if (flags & 0b100) != 0 { f |= Z80.flagH }

                cpu.a = a
                cpu.f = f
                cpu.pc = 0x0000
                _ = cpu.step(bus: bus)

                let expected = referenceDAA(a: a, f: f)
                #expect(
                    (cpu.a, cpu.f) == expected,
                    "DAA mismatch for A=\(String(format: "%02X", a)) F=\(String(format: "%02X", f)): got \(String(format: "%02X/%02X", cpu.a, cpu.f)) expected \(String(format: "%02X/%02X", expected.0, expected.1))"
                )
            }
        }
    }

    @Test func edIniFlagsMatchReference() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.bc = 0x02FF
        cpu.hl = 0x2000
        bus.ioPorts[0xFF] = 0x81
        bus.load(at: 0x0000, data: [0xED, 0xA2])  // INI

        _ = cpu.step(bus: bus)

        #expect(bus.memory[0x2000] == 0x81)
        #expect(cpu.bc == 0x01FF)
        #expect(cpu.hl == 0x2001)
        #expect(cpu.flagN == true)
        #expect(cpu.flagPV == true)
        #expect(cpu.flagH == false)
        #expect(cpu.flagC == false)
    }

    @Test func edOutiFlagsMatchReference() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.bc = 0x0201
        cpu.hl = 0x10FE
        bus.memory[0x10FE] = 0x81
        bus.load(at: 0x0000, data: [0xED, 0xA3])  // OUTI

        _ = cpu.step(bus: bus)

        #expect(cpu.bc == 0x0101)
        #expect(cpu.hl == 0x10FF)
        #expect(bus.ioWriteLog.last?.port == 0x0101)
        #expect(bus.ioWriteLog.last?.value == 0x81)
        #expect(cpu.flagN == true)
        #expect(cpu.flagH == true)
        #expect(cpu.flagC == true)
        #expect(cpu.flagPV == false)
    }

    // MARK: - DD/FD prefix (IX/IY)

    @Test func ddLdIXImmediate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD IX, 0x1234
        bus.load(at: 0x0000, data: [0xDD, 0x21, 0x34, 0x12])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 14)
        #expect(cpu.ix == 0x1234)
    }

    @Test func ddIndexedMemAccess() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1000
        bus.memory[0x1005] = 0x42

        // LD A, (IX+5) — DD 7E 05
        bus.load(at: 0x0000, data: [0xDD, 0x7E, 0x05])
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 19)
        #expect(cpu.a == 0x42)
    }

    @Test func fdLdIYImmediate() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // LD IY, 0xABCD
        bus.load(at: 0x0000, data: [0xFD, 0x21, 0xCD, 0xAB])
        _ = cpu.step(bus: bus)
        #expect(cpu.iy == 0xABCD)
    }

    @Test func ddLdAIXH() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1234
        bus.load(at: 0x0000, data: [0xDD, 0x7C])  // LD A, IXH

        let cycles = cpu.step(bus: bus)
        #expect(cycles == 8)
        #expect(cpu.a == 0x12)
    }

    @Test func ddLdIXHFromB() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1234
        cpu.b = 0xAB
        bus.load(at: 0x0000, data: [0xDD, 0x60])  // LD IXH, B

        let cycles = cpu.step(bus: bus)
        #expect(cycles == 8)
        #expect(cpu.ix == 0xAB34)
    }

    @Test func ddAddAIXL() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1234
        cpu.a = 0x10
        bus.load(at: 0x0000, data: [0xDD, 0x85])  // ADD A, IXL

        let cycles = cpu.step(bus: bus)
        #expect(cycles == 8)
        #expect(cpu.a == 0x44)
        #expect(cpu.flagC == false)
    }

    @Test func fdLdIYLFromE() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.iy = 0xABCD
        cpu.e = 0x42
        bus.load(at: 0x0000, data: [0xFD, 0x6B])  // LD IYL, E

        let cycles = cpu.step(bus: bus)
        #expect(cycles == 8)
        #expect(cpu.iy == 0xAB42)
    }

    // MARK: - ADD HL, rr

    @Test func addHL() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.hl = 0x1000
        cpu.bc = 0x2000
        bus.load(at: 0x0000, data: [0x09])  // ADD HL, BC
        let cycles = cpu.step(bus: bus)
        #expect(cycles == 11)
        #expect(cpu.hl == 0x3000)
        #expect(cpu.flagN == false)
    }

    @Test func addHLCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.hl = 0xFFFF
        cpu.bc = 0x0001
        bus.load(at: 0x0000, data: [0x09])  // ADD HL, BC
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x0000)
        #expect(cpu.flagC == true)
    }

    // MARK: - R register

    @Test func rRegisterIncrements() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.r = 0x00

        // Execute 3 NOPs
        bus.load(at: 0x0000, data: [0x00, 0x00, 0x00])
        _ = cpu.step(bus: bus)
        _ = cpu.step(bus: bus)
        _ = cpu.step(bus: bus)
        #expect(cpu.r == 0x03)

        // R bit 7 is preserved
        cpu.r = 0x80
        bus.load(at: 0x0003, data: [0x00])
        _ = cpu.step(bus: bus)
        #expect(cpu.r == 0x81)
    }

    // MARK: - SCF / CCF / CPL

    @Test func scfCcfCpl() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // SCF
        cpu.f = 0x00
        bus.load(at: 0x0000, data: [0x37])
        _ = cpu.step(bus: bus)
        #expect(cpu.flagC == true)

        // CCF (complement carry)
        bus.load(at: 0x0001, data: [0x3F])
        _ = cpu.step(bus: bus)
        #expect(cpu.flagC == false)
        #expect(cpu.flagH == true)  // old carry becomes H

        // CPL
        cpu.a = 0x55
        bus.load(at: 0x0002, data: [0x2F])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xAA)
        #expect(cpu.flagH == true)
        #expect(cpu.flagN == true)
    }

    // MARK: - I/O

    @Test func outIn() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x42
        // OUT (0x30), A
        bus.load(at: 0x0000, data: [0xD3, 0x30])
        _ = cpu.step(bus: bus)
        #expect(bus.ioPorts[0x30] == 0x42)

        // IN A, (0x30)
        cpu.a = 0x00
        bus.load(at: 0x0002, data: [0xDB, 0x30])
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x42)
    }

    // MARK: - Undocumented ED Instructions

    @Test("ED 4E/6E set IM 0 (undocumented aliases)")
    func undocumentedIMx() {
        let cpu = Z80()
        let bus = TestBus()

        // Set IM 2 first, then verify ED 4E resets to IM 0
        cpu.im = 2
        bus.load(at: 0x0000, data: [0xED, 0x4E])
        let t1 = cpu.step(bus: bus)
        #expect(cpu.im == 0)
        #expect(t1 == 8)

        // ED 6E also sets IM 0
        cpu.im = 1
        bus.load(at: 0x0002, data: [0xED, 0x6E])
        let t2 = cpu.step(bus: bus)
        #expect(cpu.im == 0)
        #expect(t2 == 8)
    }

    @Test("ED 77/7F are explicit undocumented NOPs (8 T-states)")
    func undocumentedEDNops() {
        let cpu = Z80()
        let bus = TestBus()

        let pcBefore = cpu.pc
        bus.load(at: 0x0000, data: [0xED, 0x77])
        let t1 = cpu.step(bus: bus)
        #expect(t1 == 8)
        #expect(cpu.pc == pcBefore + 2)

        bus.load(at: 0x0002, data: [0xED, 0x7F])
        let t2 = cpu.step(bus: bus)
        #expect(t2 == 8)
        #expect(cpu.pc == pcBefore + 4)
    }

    // MARK: - ADC/SBC 8-bit with flags

    @Test("ADC A, B includes carry in result and sets flags")
    func adcABWithCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Case 1: A=0x10, B=0x20, carry=1 → A=0x31
        cpu.a = 0x10
        cpu.b = 0x20
        cpu.flagC = true
        bus.load(at: 0x0000, data: [0x88])  // ADC A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x31)
        #expect(cpu.flagC == false)
        #expect(cpu.flagN == false)

        // Case 2: A=0xFF, B=0x00, carry=1 → A=0x00, carry=1, zero=1
        cpu.a = 0xFF
        cpu.b = 0x00
        cpu.flagC = true
        bus.load(at: 0x0001, data: [0x88])  // ADC A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagC == true)
        #expect(cpu.flagZ == true)
    }

    @Test("SBC A, B includes carry in result and sets flags")
    func sbcABWithCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Case 1: A=0x30, B=0x10, carry=1 → A=0x1F, H=1, N=1
        cpu.a = 0x30
        cpu.b = 0x10
        cpu.flagC = true
        bus.load(at: 0x0000, data: [0x98])  // SBC A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x1F)
        #expect(cpu.flagH == true)
        #expect(cpu.flagN == true)

        // Case 2: A=0x00, B=0x00, carry=1 → A=0xFF, carry=1, N=1
        cpu.a = 0x00
        cpu.b = 0x00
        cpu.flagC = true
        bus.load(at: 0x0001, data: [0x98])  // SBC A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
        #expect(cpu.flagC == true)
        #expect(cpu.flagN == true)
    }

    // MARK: - SBC HL, rr and ADC HL, rr (16-bit)

    @Test("SBC HL, BC subtracts with carry and sets flags")
    func sbcHLBC() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Case 1: HL=0x1000, BC=0x0800, carry=0 → HL=0x0800, N=1
        cpu.hl = 0x1000
        cpu.bc = 0x0800
        cpu.flagC = false
        bus.load(at: 0x0000, data: [0xED, 0x42])  // SBC HL, BC
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x0800)
        #expect(cpu.flagN == true)
        #expect(cpu.flagZ == false)

        // Case 2: HL=0x1000, BC=0x1000, carry=0 → HL=0x0000, Z=1, N=1
        cpu.hl = 0x1000
        cpu.bc = 0x1000
        cpu.flagC = false
        bus.load(at: 0x0002, data: [0xED, 0x42])  // SBC HL, BC
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x0000)
        #expect(cpu.flagZ == true)
        #expect(cpu.flagN == true)
    }

    @Test("ADC HL, DE adds with carry and sets flags")
    func adcHLDE() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // HL=0x8000, DE=0x8000, carry=0 → HL=0x0000, carry=1, PV=1 (overflow)
        cpu.hl = 0x8000
        cpu.de = 0x8000
        cpu.flagC = false
        bus.load(at: 0x0000, data: [0xED, 0x5A])  // ADC HL, DE
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x0000)
        #expect(cpu.flagC == true)
        #expect(cpu.flagPV == true)
        #expect(cpu.flagZ == true)
    }

    // MARK: - Rotate/Shift (CB prefix)

    @Test("RLA and RRA rotate through carry")
    func rlaRra() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // RLA: A=0x80, carry=0 → A=0x00, carry=1
        cpu.a = 0x80
        cpu.flagC = false
        bus.load(at: 0x0000, data: [0x17])  // RLA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagC == true)

        // RRA: A=0x01, carry=0 → A=0x00, carry=1
        cpu.a = 0x01
        cpu.flagC = false
        bus.load(at: 0x0001, data: [0x1F])  // RRA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagC == true)
    }

    @Test("RLC r rotates left circular with full flags")
    func rlcR() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // CB 00 (RLC B): B=0x85 → B=0x0B, carry=1
        cpu.b = 0x85
        bus.load(at: 0x0000, data: [0xCB, 0x00])  // RLC B
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x0B)
        #expect(cpu.flagC == true)
    }

    @Test("SRA preserves sign bit")
    func sraPreservesSign() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // CB 28 (SRA B): B=0x80 → B=0xC0, carry=0
        cpu.b = 0x80
        bus.load(at: 0x0000, data: [0xCB, 0x28])  // SRA B
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0xC0)
        #expect(cpu.flagC == false)
        #expect(cpu.flagS == true)
    }

    @Test("SLL sets bit 0 (undocumented)")
    func sllUndocumented() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // CB 30 (SLL B): B=0x80 → B=0x01, carry=1
        cpu.b = 0x80
        bus.load(at: 0x0000, data: [0xCB, 0x30])  // SLL B
        _ = cpu.step(bus: bus)
        #expect(cpu.b == 0x01)
        #expect(cpu.flagC == true)
    }

    // MARK: - Block operations

    @Test("LDI copies one byte and decrements BC")
    func ldi() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // (HL)=0x42, DE=0x5000, BC=3
        cpu.hl = 0x1000
        cpu.de = 0x5000
        cpu.bc = 0x0003
        bus.memory[0x1000] = 0x42
        bus.load(at: 0x0000, data: [0xED, 0xA0])  // LDI
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x5000] == 0x42)
        #expect(cpu.hl == 0x1001)
        #expect(cpu.de == 0x5001)
        #expect(cpu.bc == 0x0002)
        #expect(cpu.flagPV == true)  // BC != 0
    }

    @Test("LDD copies backward and decrements BC")
    func ldd() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.hl = 0x1002
        cpu.de = 0x5002
        cpu.bc = 0x0003
        bus.memory[0x1002] = 0x55
        bus.load(at: 0x0000, data: [0xED, 0xA8])  // LDD
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x5002] == 0x55)
        #expect(cpu.hl == 0x1001)
        #expect(cpu.de == 0x5001)
        #expect(cpu.bc == 0x0002)
        #expect(cpu.flagPV == true)  // BC != 0
    }

    @Test("LDDR repeats LDD until BC=0")
    func lddr() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Set up 3 bytes to copy backward
        bus.memory[0x1000] = 0xAA
        bus.memory[0x1001] = 0xBB
        bus.memory[0x1002] = 0xCC
        cpu.hl = 0x1002
        cpu.de = 0x5002
        cpu.bc = 0x0003
        bus.load(at: 0x0000, data: [0xED, 0xB8])  // LDDR

        // LDDR repeats: each iteration that has BC>0 goes back to re-execute
        // It runs until BC=0
        var totalCycles = 0
        while cpu.bc != 0 || cpu.pc == 0x0000 {
            totalCycles += cpu.step(bus: bus)
            if totalCycles > 1000 { break }  // safety
        }
        #expect(bus.memory[0x5002] == 0xCC)
        #expect(bus.memory[0x5001] == 0xBB)
        #expect(bus.memory[0x5000] == 0xAA)
        #expect(cpu.bc == 0x0000)
        #expect(cpu.flagPV == false)  // BC == 0
    }

    @Test("CPI compares and advances")
    func cpi() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // A=0x42, memory has 0x42 at (HL), BC=2
        cpu.a = 0x42
        cpu.hl = 0x2000
        cpu.bc = 0x0002
        bus.memory[0x2000] = 0x42
        bus.load(at: 0x0000, data: [0xED, 0xA1])  // CPI
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0x2001)
        #expect(cpu.bc == 0x0001)
        #expect(cpu.flagZ == true)   // match found
        #expect(cpu.flagPV == true)  // BC != 0
        #expect(cpu.flagN == true)
    }

    @Test("CPIR repeats until match or BC=0")
    func cpir() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // A=0x42, search block [0x41, 0x42, 0x43]
        cpu.a = 0x42
        cpu.hl = 0x2000
        cpu.bc = 0x0003
        bus.memory[0x2000] = 0x41
        bus.memory[0x2001] = 0x42
        bus.memory[0x2002] = 0x43
        bus.load(at: 0x0000, data: [0xED, 0xB1])  // CPIR

        var totalCycles = 0
        // CPIR repeats until match or BC=0
        repeat {
            totalCycles += cpu.step(bus: bus)
            if totalCycles > 1000 { break }
        } while !cpu.flagZ && cpu.bc != 0 && cpu.pc == 0x0000

        #expect(cpu.hl == 0x2002)  // points past match
        #expect(cpu.bc == 0x0001)
        #expect(cpu.flagZ == true)   // match found
        #expect(cpu.flagPV == true)  // BC != 0
    }

    // MARK: - RRD and RLD (decimal rotate)

    @Test("RRD rotates right decimal between A and (HL)")
    func rrd() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // A=0x12, (HL)=0x34 → A=0x14, (HL)=0x23
        cpu.a = 0x12
        cpu.hl = 0x3000
        bus.memory[0x3000] = 0x34
        bus.load(at: 0x0000, data: [0xED, 0x67])  // RRD
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x14)
        #expect(bus.memory[0x3000] == 0x23)
    }

    @Test("RLD rotates left decimal between A and (HL)")
    func rld() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // A=0x12, (HL)=0x34 → A=0x13, (HL)=0x42
        cpu.a = 0x12
        cpu.hl = 0x3000
        bus.memory[0x3000] = 0x34
        bus.load(at: 0x0000, data: [0xED, 0x6F])  // RLD
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x13)
        #expect(bus.memory[0x3000] == 0x42)
    }

    // MARK: - DAA comprehensive

    @Test("DAA adjusts after addition")
    func daaAfterAddition() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // ADD A, B: A=0x09, B=0x09 → A=0x12, H=1. DAA → A=0x18
        cpu.a = 0x09
        cpu.b = 0x09
        bus.load(at: 0x0000, data: [0x80])  // ADD A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x12)
        #expect(cpu.flagH == true)

        bus.load(at: 0x0001, data: [0x27])  // DAA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x18)
        #expect(cpu.flagN == false)
    }

    @Test("DAA adjusts after subtraction")
    func daaAfterSubtraction() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // SUB B: A=0x18, B=0x09 → A=0x0F, N=1
        cpu.a = 0x18
        cpu.b = 0x09
        bus.load(at: 0x0000, data: [0x90])  // SUB B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x0F)
        #expect(cpu.flagN == true)

        bus.load(at: 0x0001, data: [0x27])  // DAA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x09)
    }

    @Test("DAA with carry from high nibble")
    func daaHighNibbleCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // ADD A, B: A=0x90, B=0x90 → A=0x20, C=1
        cpu.a = 0x90
        cpu.b = 0x90
        bus.load(at: 0x0000, data: [0x80])  // ADD A, B
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x20)
        #expect(cpu.flagC == true)

        bus.load(at: 0x0001, data: [0x27])  // DAA
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x80)
        #expect(cpu.flagC == true)  // carry preserved
    }

    // MARK: - Conditional jumps/calls/returns

    @Test("JR Z takes branch when zero flag set")
    func jrZTaken() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.flagZ = true
        bus.load(at: 0x0000, data: [0x28, 0x05])  // JR Z, +5
        let cycles = cpu.step(bus: bus)
        #expect(cpu.pc == 0x0007)  // 0x0002 + 5
        #expect(cycles == 12)  // taken branch
    }

    @Test("JR NZ falls through when zero flag set")
    func jrNZNotTaken() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.flagZ = true
        bus.load(at: 0x0000, data: [0x20, 0x05])  // JR NZ, +5
        let cycles = cpu.step(bus: bus)
        #expect(cpu.pc == 0x0002)  // falls through
        #expect(cycles == 7)  // not taken
    }

    @Test("CALL Z pushes and jumps when flag set, skips when not")
    func callZConditional() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Case 1: Z set → call taken
        cpu.sp = 0xFFFE
        cpu.flagZ = true
        bus.load(at: 0x0000, data: [0xCC, 0x00, 0x50])  // CALL Z, 0x5000
        let cycles1 = cpu.step(bus: bus)
        #expect(cpu.pc == 0x5000)
        #expect(cycles1 == 17)  // taken
        // Stack should contain return address 0x0003
        #expect(bus.memory[0xFFFC] == 0x03)
        #expect(bus.memory[0xFFFD] == 0x00)

        // Case 2: Z clear → call not taken
        cpu.reset()
        cpu.sp = 0xFFFE
        cpu.flagZ = false
        bus.load(at: 0x0000, data: [0xCC, 0x00, 0x50])  // CALL Z, 0x5000
        let cycles2 = cpu.step(bus: bus)
        #expect(cpu.pc == 0x0003)  // skipped
        #expect(cycles2 == 10)  // not taken
    }

    @Test("RET NZ returns when zero flag clear")
    func retNZConditional() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Case 1: Z=0, RET NZ → pops and returns (11T)
        cpu.sp = 0xFFFC
        bus.memory[0xFFFC] = 0x34
        bus.memory[0xFFFD] = 0x12
        cpu.flagZ = false
        bus.load(at: 0x0000, data: [0xC0])  // RET NZ
        let cycles1 = cpu.step(bus: bus)
        #expect(cpu.pc == 0x1234)
        #expect(cycles1 == 11)

        // Case 2: Z=1, RET NZ → does not return (5T)
        cpu.reset()
        cpu.sp = 0xFFFC
        cpu.flagZ = true
        bus.load(at: 0x0000, data: [0xC0])  // RET NZ
        let cycles2 = cpu.step(bus: bus)
        #expect(cpu.pc == 0x0001)
        #expect(cycles2 == 5)
    }

    // MARK: - EX instructions

    @Test("EX DE, HL swaps register pairs")
    func exDEHL() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.de = 0x1234
        cpu.hl = 0x5678
        bus.load(at: 0x0000, data: [0xEB])  // EX DE, HL
        _ = cpu.step(bus: bus)
        #expect(cpu.de == 0x5678)
        #expect(cpu.hl == 0x1234)
    }

    @Test("EX (SP), HL exchanges HL with stack top")
    func exSPHL() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.hl = 0xAAAA
        cpu.sp = 0xFFFC
        bus.memory[0xFFFC] = 0xBB  // low byte
        bus.memory[0xFFFD] = 0xBB  // high byte → 0xBBBB
        bus.load(at: 0x0000, data: [0xE3])  // EX (SP), HL
        _ = cpu.step(bus: bus)
        #expect(cpu.hl == 0xBBBB)
        #expect(bus.memory[0xFFFC] == 0xAA)
        #expect(bus.memory[0xFFFD] == 0xAA)
    }

    // MARK: - IX/IY indexed operations

    @Test("LD (IX+d), r stores register at indexed address")
    func ldIXdR() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1000
        cpu.b = 0x42
        // DD 70 05 = LD (IX+5), B
        bus.load(at: 0x0000, data: [0xDD, 0x70, 0x05])
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x1005] == 0x42)
    }

    @Test("INC (IY+d) increments indexed memory with flags")
    func incIYd() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.iy = 0x2000
        bus.memory[0x2003] = 0x0F
        // FD 34 03 = INC (IY+3)
        bus.load(at: 0x0000, data: [0xFD, 0x34, 0x03])
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x2003] == 0x10)
        #expect(cpu.flagH == true)
    }

    @Test("DDCB: SET 3, (IX+d) with register copy")
    func ddcbSet3IXd() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.ix = 0x1000
        bus.memory[0x1005] = 0x00
        // DD CB 05 DB = SET 3, (IX+5) → copy to E (undocumented)
        bus.load(at: 0x0000, data: [0xDD, 0xCB, 0x05, 0xDB])
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x1005] == 0x08)  // bit 3 set
        #expect(cpu.e == 0x08)  // undocumented copy to E
    }

    // MARK: - IX/IY displacement wrap-around (regression for UInt16 overflow trap)

    /// IX+d wraps at the 16-bit boundary. IX=0xFFFF + d=+1 must address 0x0000,
    /// not trap the runtime. Regression for the `UInt16(Int(ix) &+ Int(d))` bug
    /// where `&+` wrapped at Int width (64-bit) and the UInt16 cast then trapped.
    @Test("LD r,(IX+d) wraps IX at 16-bit boundary (IX=0xFFFF, d=+1 → 0x0000)")
    func ldRIXdWrapsHigh() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.ix = 0xFFFF
        bus.memory[0x0000] = 0xAA  // target after wrap
        // DD 7E 01 = LD A,(IX+1)
        bus.load(at: 0x8000, data: [0xDD, 0x7E, 0x01])
        cpu.pc = 0x8000
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xAA)
    }

    @Test("LD r,(IY+d) wraps IY at 16-bit boundary with negative d (IY=0x0000, d=-1 → 0xFFFF)")
    func ldRIYdWrapsLow() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.iy = 0x0000
        bus.memory[0xFFFF] = 0x55  // target after wrap
        // FD 7E FF = LD A,(IY-1)
        bus.load(at: 0x8000, data: [0xFD, 0x7E, 0xFF])
        cpu.pc = 0x8000
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x55)
    }

    @Test("LD (IX+d),r wraps for IX=0xFFFF, d=+2 → 0x0001")
    func ldIXdRWrapsStore() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.ix = 0xFFFF
        cpu.b = 0x7E
        // DD 70 02 = LD (IX+2), B  → addr = 0xFFFF + 2 = 0x0001 (wrap)
        bus.load(at: 0x8000, data: [0xDD, 0x70, 0x02])
        cpu.pc = 0x8000
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x0001] == 0x7E)
    }

    @Test("INC (IX+d) wraps for IX=0xFFFE, d=+3 → 0x0001")
    func incIXdWraps() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.ix = 0xFFFE
        bus.memory[0x0001] = 0x10
        // DD 34 03 = INC (IX+3)
        bus.load(at: 0x8000, data: [0xDD, 0x34, 0x03])
        cpu.pc = 0x8000
        _ = cpu.step(bus: bus)
        #expect(bus.memory[0x0001] == 0x11)
    }

    @Test("BIT n,(IX+d) wraps at 16-bit boundary")
    func bitIXdWraps() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()
        cpu.ix = 0xFFFF
        bus.memory[0x0004] = 0x08  // bit 3 set
        // DD CB 05 5E = BIT 3,(IX+5) → addr = 0xFFFF + 5 = 0x0004 (wrap)
        bus.load(at: 0x8000, data: [0xDD, 0xCB, 0x05, 0x5E])
        cpu.pc = 0x8000
        _ = cpu.step(bus: bus)
        #expect(cpu.flagZ == false)  // bit 3 is set → Z clear
    }

    // MARK: - Parity function

    @Test("Parity calculation for known values")
    func parityCalculation() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // XOR A with immediate → PV = parity
        // 0x00 XOR 0x00 = 0x00 → even parity → PV=1
        cpu.a = 0x00
        bus.load(at: 0x0000, data: [0xEE, 0x00])  // XOR 0x00
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x00)
        #expect(cpu.flagPV == true)  // even parity

        // 0x00 XOR 0x01 = 0x01 → odd parity → PV=0
        cpu.a = 0x00
        bus.load(at: 0x0002, data: [0xEE, 0x01])  // XOR 0x01
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x01)
        #expect(cpu.flagPV == false)  // odd parity

        // 0x00 XOR 0xFF = 0xFF → even parity (8 bits set) → PV=1
        cpu.a = 0x00
        bus.load(at: 0x0004, data: [0xEE, 0xFF])  // XOR 0xFF
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0xFF)
        #expect(cpu.flagPV == true)  // even parity

        // 0x00 XOR 0x80 = 0x80 → odd parity (1 bit set) → PV=0
        cpu.a = 0x00
        bus.load(at: 0x0006, data: [0xEE, 0x80])  // XOR 0x80
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x80)
        #expect(cpu.flagPV == false)  // odd parity

        // 0x00 XOR 0x03 = 0x03 → even parity (2 bits set) → PV=1
        cpu.a = 0x00
        bus.load(at: 0x0008, data: [0xEE, 0x03])  // XOR 0x03
        _ = cpu.step(bus: bus)
        #expect(cpu.a == 0x03)
        #expect(cpu.flagPV == true)  // even parity
    }

    // MARK: - NMI

    @Test("NMI pushes PC and jumps to 0x0066")
    func nmiTest() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.pc = 0x1234
        cpu.sp = 0xFFFE
        cpu.iff1 = true
        cpu.iff2 = true

        let cycles = cpu.nmi(bus: bus)
        #expect(cpu.pc == 0x0066)
        #expect(cycles == 11)
        // Stack has old PC
        #expect(bus.memory[0xFFFC] == 0x34)  // low byte
        #expect(bus.memory[0xFFFD] == 0x12)  // high byte
        // IFF1 disabled, IFF2 preserves old IFF1
        #expect(cpu.iff1 == false)
        #expect(cpu.iff2 == true)
    }

    // MARK: - IM 0 interrupt

    @Test("IM 0 interrupt with RST vector")
    func im0InterruptRST() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // IM=0, vector=0xFF → RST 38h → PC=0x0038
        cpu.im = 0
        cpu.iff1 = true
        cpu.iff2 = true
        cpu.pc = 0x1000
        cpu.sp = 0xFFFE
        let cycles1 = cpu.interrupt(vector: 0xFF, bus: bus)
        #expect(cpu.pc == 0x0038)
        #expect(cycles1 == 11)
        #expect(cpu.iff1 == false)

        // IM=0, vector=0xC7 → RST 00h → PC=0x0000
        cpu.reset()
        cpu.im = 0
        cpu.iff1 = true
        cpu.iff2 = true
        cpu.pc = 0x2000
        cpu.sp = 0xFFFE
        let cycles2 = cpu.interrupt(vector: 0xC7, bus: bus)
        #expect(cpu.pc == 0x0000)
        #expect(cycles2 == 11)
    }

    // MARK: - RETN vs RETI

    @Test("RETN restores IFF1 from IFF2")
    func retnRestoresIFF() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        // Set up return address on stack
        cpu.sp = 0xFFFC
        bus.memory[0xFFFC] = 0x00
        bus.memory[0xFFFD] = 0x10  // return to 0x1000
        cpu.iff1 = false
        cpu.iff2 = true

        // ED 45 = RETN
        bus.load(at: 0x0000, data: [0xED, 0x45])
        _ = cpu.step(bus: bus)
        #expect(cpu.iff1 == true)  // restored from IFF2
        #expect(cpu.pc == 0x1000)
    }

    // MARK: - SUB E regression (RIGLAS decrypt)

    @Test func addE_halfCarry() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x7E
        cpu.de = 0x40BD  // E=0xBD
        bus.load(at: 0x0000, data: [0x83])  // ADD A,E
        _ = cpu.step(bus: bus)

        #expect(cpu.a == 0x3B, "0x7E + 0xBD = 0x13B, A=0x3B")
        #expect(cpu.flagC == true, "carry from overflow")
        #expect(cpu.flagH == true, "half-carry: 0x0E + 0x0D = 0x1B > 0x0F")
    }

    @Test func subE_7C_minus_3B() {
        let cpu = Z80()
        let bus = TestBus()
        cpu.reset()

        cpu.a = 0x7C
        cpu.de = 0x403B  // D=0x40, E=0x3B
        cpu.f = 0x28     // preserve initial flags
        bus.load(at: 0x0000, data: [0x93])  // SUB E
        _ = cpu.step(bus: bus)

        #expect(cpu.a == 0x41, "0x7C - 0x3B = 0x41")
        #expect(cpu.flagC == false, "no borrow")
        #expect(cpu.flagN == true, "SUB sets N")
    }
}
