/// Z80 CPU emulator — pure Swift, step-based execution.
///
/// Communicates with the outside world exclusively through Bus protocol.
/// Returns consumed T-states from each step() call.
public final class Z80 {

    // MARK: - Register Pairs

    /// Main register set stored as 16-bit pairs for efficient access.
    /// Individual 8-bit registers are accessed via computed properties.
    public var af: UInt16 = 0xFFFF
    public var bc: UInt16 = 0x0000
    public var de: UInt16 = 0x0000
    public var hl: UInt16 = 0x0000

    /// Alternate register set (EXX / EX AF,AF')
    public var af2: UInt16 = 0xFFFF
    public var bc2: UInt16 = 0x0000
    public var de2: UInt16 = 0x0000
    public var hl2: UInt16 = 0x0000

    /// Index registers
    public var ix: UInt16 = 0x0000
    public var iy: UInt16 = 0x0000

    /// Stack pointer
    public var sp: UInt16 = 0xFFFF

    /// Program counter
    public var pc: UInt16 = 0x0000

    /// Interrupt vector base register (high byte for IM2 vector table)
    public var i: UInt8 = 0x00

    /// Memory refresh counter (incremented on each M1 cycle)
    public var r: UInt8 = 0x00

    /// Interrupt flip-flops
    public var iff1: Bool = false
    public var iff2: Bool = false

    /// Interrupt mode (0, 1, or 2). PC-8801 uses IM2.
    public var im: UInt8 = 0

    /// HALT state — CPU executes NOPs until interrupt
    public var halted: Bool = false

    /// EI delay — interrupts are enabled after the NEXT instruction following EI
    package var eiPending: Bool = false

    // MARK: - 8-bit Register Accessors

    public var a: UInt8 {
        get { UInt8(af >> 8) }
        set { af = (UInt16(newValue) << 8) | (af & 0x00FF) }
    }

    public var f: UInt8 {
        get { UInt8(af & 0x00FF) }
        set { af = (af & 0xFF00) | UInt16(newValue) }
    }

    public var b: UInt8 {
        get { UInt8(bc >> 8) }
        set { bc = (UInt16(newValue) << 8) | (bc & 0x00FF) }
    }

    public var c: UInt8 {
        get { UInt8(bc & 0x00FF) }
        set { bc = (bc & 0xFF00) | UInt16(newValue) }
    }

    public var d: UInt8 {
        get { UInt8(de >> 8) }
        set { de = (UInt16(newValue) << 8) | (de & 0x00FF) }
    }

    public var e: UInt8 {
        get { UInt8(de & 0x00FF) }
        set { de = (de & 0xFF00) | UInt16(newValue) }
    }

    public var h: UInt8 {
        get { UInt8(hl >> 8) }
        set { hl = (UInt16(newValue) << 8) | (hl & 0x00FF) }
    }

    public var l: UInt8 {
        get { UInt8(hl & 0x00FF) }
        set { hl = (hl & 0xFF00) | UInt16(newValue) }
    }

    public var ixh: UInt8 {
        get { UInt8(ix >> 8) }
        set { ix = (UInt16(newValue) << 8) | (ix & 0x00FF) }
    }

    public var ixl: UInt8 {
        get { UInt8(ix & 0x00FF) }
        set { ix = (ix & 0xFF00) | UInt16(newValue) }
    }

    public var iyh: UInt8 {
        get { UInt8(iy >> 8) }
        set { iy = (UInt16(newValue) << 8) | (iy & 0x00FF) }
    }

    public var iyl: UInt8 {
        get { UInt8(iy & 0x00FF) }
        set { iy = (iy & 0xFF00) | UInt16(newValue) }
    }

    // MARK: - Flag Accessors

    /// Flag bit positions
    public static let flagC: UInt8  = 0x01  // bit 0: Carry
    public static let flagN: UInt8  = 0x02  // bit 1: Subtract
    public static let flagPV: UInt8 = 0x04  // bit 2: Parity/Overflow
    public static let flagF3: UInt8 = 0x08  // bit 3: undocumented (copy of bit 3)
    public static let flagH: UInt8  = 0x10  // bit 4: Half carry
    public static let flagF5: UInt8 = 0x20  // bit 5: undocumented (copy of bit 5)
    public static let flagZ: UInt8  = 0x40  // bit 6: Zero
    public static let flagS: UInt8  = 0x80  // bit 7: Sign

    public var flagC: Bool {
        get { f & Self.flagC != 0 }
        set { if newValue { f |= Self.flagC } else { f &= ~Self.flagC } }
    }

    public var flagN: Bool {
        get { f & Self.flagN != 0 }
        set { if newValue { f |= Self.flagN } else { f &= ~Self.flagN } }
    }

    public var flagPV: Bool {
        get { f & Self.flagPV != 0 }
        set { if newValue { f |= Self.flagPV } else { f &= ~Self.flagPV } }
    }

    public var flagH: Bool {
        get { f & Self.flagH != 0 }
        set { if newValue { f |= Self.flagH } else { f &= ~Self.flagH } }
    }

    public var flagZ: Bool {
        get { f & Self.flagZ != 0 }
        set { if newValue { f |= Self.flagZ } else { f &= ~Self.flagZ } }
    }

    public var flagS: Bool {
        get { f & Self.flagS != 0 }
        set { if newValue { f |= Self.flagS } else { f &= ~Self.flagS } }
    }

    /// Per-instruction pre-execution trace hook, enabled by setting a closure.
    /// Called immediately before fetching the next opcode (CPU state reflects
    /// the state at the top of `step()`, before any register changes from the
    /// upcoming instruction). Designed for cross-emulator diff workflows —
    /// dump the same format from BubiC and compare line-by-line to find the
    /// first divergent instruction.
    public var onInstructionTrace: ((Z80) -> Void)?

    // MARK: - Initialization

    public init() {}

    /// Cold reset — restores CPU to power-on state.
    public func reset() {
        // Align with BubiC (z80.cpp special_reset + reset):
        //   PC=SP=0, AF=ZF only (A=0, F=0x40), BC/DE/HL=0,
        //   shadow regs all 0, IX=IY=0xFFFF, I=R=0, IFF=0, IM=0.
        pc = 0x0000
        sp = 0x0000
        af = 0x0040
        bc = 0x0000
        de = 0x0000
        hl = 0x0000
        af2 = 0x0000
        bc2 = 0x0000
        de2 = 0x0000
        hl2 = 0x0000
        ix = 0xFFFF
        iy = 0xFFFF
        i = 0x00
        r = 0x00
        iff1 = false
        iff2 = false
        im = 0
        halted = false
        eiPending = false
    }

    // MARK: - Execution

    /// Execute one instruction and return consumed T-states.
    public func step(bus: some Bus) -> Int {
        onInstructionTrace?(self)

        // Handle EI delay: if EI was executed last instruction, now enable interrupts
        if eiPending {
            iff1 = true
            iff2 = true
            eiPending = false
        }

        if halted {
            // HALT: execute NOP, R increments, but PC stays
            incrementR()
            return 4  // NOP T-states
        }

        let opcode = fetchByte(bus: bus)
        incrementR()

        return executeUnprefixed(opcode: opcode, bus: bus)
    }

    /// Service a maskable interrupt (IM2). Returns consumed T-states.
    /// `vector` is the low byte provided by the interrupting device.
    public func interrupt(vector: UInt8, bus: some Bus) -> Int {
        guard iff1 else { return 0 }

        iff1 = false
        iff2 = false

        if halted {
            halted = false
            pc &+= 1
        }

        switch im {
        case 0:
            // IM0: The interrupting device places an instruction byte on the data bus.
            // On the PC-8801 sub-CPU, the FDC sends 0xFF (RST 7 → CALL 0x0038).
            // Decode RST instructions: 11xxx111 → push PC, jump to xxx*8.
            if vector & 0xC7 == 0xC7 {
                // RST n: push PC, jump to n*8
                let rstAddr = UInt16(vector & 0x38)
                pushWord(sp: &sp, value: pc, bus: bus)
                pc = rstAddr
                return 11  // RST takes 11 T-states
            }
            // Other IM0 bytes: treat as NOP (acknowledge only)
            return 6

        case 1:
            // IM1: Jump to 0x0038
            pushWord(sp: &sp, value: pc, bus: bus)
            pc = 0x0038
            return 13

        case 2:
            // IM2: Vector table lookup
            let tableAddr = (UInt16(i) << 8) | UInt16(vector)
            pushWord(sp: &sp, value: pc, bus: bus)
            let lo = UInt16(bus.memRead(tableAddr))
            let hi = UInt16(bus.memRead(tableAddr &+ 1))
            pc = (hi << 8) | lo
            return 19

        default:
            return 0
        }
    }

    /// Service a non-maskable interrupt. Returns consumed T-states.
    public func nmi(bus: some Bus) -> Int {
        iff2 = iff1
        iff1 = false

        if halted {
            halted = false
            pc &+= 1
        }

        pushWord(sp: &sp, value: pc, bus: bus)
        pc = 0x0066
        return 11
    }

    // MARK: - Internal Helpers

    internal func fetchByte(bus: some Bus) -> UInt8 {
        let value = bus.memRead(pc)
        pc &+= 1
        return value
    }

    internal func fetchWord(bus: some Bus) -> UInt16 {
        let lo = UInt16(bus.memRead(pc))
        pc &+= 1
        let hi = UInt16(bus.memRead(pc))
        pc &+= 1
        return (hi << 8) | lo
    }

    internal func incrementR() {
        // R register: bit 7 is preserved, bits 0-6 increment
        r = (r & 0x80) | ((r &+ 1) & 0x7F)
    }

    internal func pushWord(sp: inout UInt16, value: UInt16, bus: some Bus) {
        sp &-= 1
        bus.memWrite(sp, value: UInt8(value >> 8))
        sp &-= 1
        bus.memWrite(sp, value: UInt8(value & 0xFF))
    }

    internal func popWord(sp: inout UInt16, bus: some Bus) -> UInt16 {
        let lo = UInt16(bus.memRead(sp))
        sp &+= 1
        let hi = UInt16(bus.memRead(sp))
        sp &+= 1
        return (hi << 8) | lo
    }

    // MARK: - Flag Helpers

    /// Compute Sign, Zero, and undocumented F5/F3 flags from 8-bit result.
    internal func szFlags(_ result: UInt8) -> UInt8 {
        var flags: UInt8 = 0
        if result & 0x80 != 0 { flags |= Self.flagS }
        if result == 0 { flags |= Self.flagZ }
        flags |= result & (Self.flagF5 | Self.flagF3)  // undocumented bits
        return flags
    }

    /// Compute parity flag (true = even parity).
    internal func parity(_ value: UInt8) -> Bool {
        var v = value
        v ^= v >> 4
        v ^= v >> 2
        v ^= v >> 1
        return v & 1 == 0
    }

    // MARK: - Instruction Execution (Unprefixed)

    /// Execute an unprefixed opcode. Returns T-states consumed.
    internal func executeUnprefixed(opcode: UInt8, bus: some Bus) -> Int {
        switch opcode {
        // NOP
        case 0x00:
            return 4

        // LD rr, nn — 16-bit immediate loads
        case 0x01: bc = fetchWord(bus: bus); return 10
        case 0x11: de = fetchWord(bus: bus); return 10
        case 0x21: hl = fetchWord(bus: bus); return 10
        case 0x31: sp = fetchWord(bus: bus); return 10

        // LD (BC), A
        case 0x02: bus.memWrite(bc, value: a); return 7
        // LD (DE), A
        case 0x12: bus.memWrite(de, value: a); return 7
        // LD (HL), n
        case 0x36: bus.memWrite(hl, value: fetchByte(bus: bus)); return 10

        // LD A, (BC)
        case 0x0A: a = bus.memRead(bc); return 7
        // LD A, (DE)
        case 0x1A: a = bus.memRead(de); return 7

        // LD (nn), HL
        case 0x22:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: l)
            bus.memWrite(addr &+ 1, value: h)
            return 16

        // LD HL, (nn)
        case 0x2A:
            let addr = fetchWord(bus: bus)
            l = bus.memRead(addr)
            h = bus.memRead(addr &+ 1)
            return 16

        // LD (nn), A
        case 0x32:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: a)
            return 13

        // LD A, (nn)
        case 0x3A:
            let addr = fetchWord(bus: bus)
            a = bus.memRead(addr)
            return 13

        // INC rr
        case 0x03: bc &+= 1; return 6
        case 0x13: de &+= 1; return 6
        case 0x23: hl &+= 1; return 6
        case 0x33: sp &+= 1; return 6

        // DEC rr
        case 0x0B: bc &-= 1; return 6
        case 0x1B: de &-= 1; return 6
        case 0x2B: hl &-= 1; return 6
        case 0x3B: sp &-= 1; return 6

        // INC r (8-bit)
        case 0x04: b = inc8(b); return 4
        case 0x0C: c = inc8(c); return 4
        case 0x14: d = inc8(d); return 4
        case 0x1C: e = inc8(e); return 4
        case 0x24: h = inc8(h); return 4
        case 0x2C: l = inc8(l); return 4
        case 0x34:
            let val = inc8(bus.memRead(hl))
            bus.memWrite(hl, value: val)
            return 11
        case 0x3C: a = inc8(a); return 4

        // DEC r (8-bit)
        case 0x05: b = dec8(b); return 4
        case 0x0D: c = dec8(c); return 4
        case 0x15: d = dec8(d); return 4
        case 0x1D: e = dec8(e); return 4
        case 0x25: h = dec8(h); return 4
        case 0x2D: l = dec8(l); return 4
        case 0x35:
            let val = dec8(bus.memRead(hl))
            bus.memWrite(hl, value: val)
            return 11
        case 0x3D: a = dec8(a); return 4

        // LD r, n (8-bit immediate)
        case 0x06: b = fetchByte(bus: bus); return 7
        case 0x0E: c = fetchByte(bus: bus); return 7
        case 0x16: d = fetchByte(bus: bus); return 7
        case 0x1E: e = fetchByte(bus: bus); return 7
        case 0x26: h = fetchByte(bus: bus); return 7
        case 0x2E: l = fetchByte(bus: bus); return 7
        case 0x3E: a = fetchByte(bus: bus); return 7

        // RLCA, RRCA, RLA, RRA
        case 0x07: rlca(); return 4
        case 0x0F: rrca(); return 4
        case 0x17: rla(); return 4
        case 0x1F: rra(); return 4

        // DAA
        case 0x27: daa(); return 4

        // CPL
        case 0x2F:
            a = ~a
            f = (f & (Self.flagS | Self.flagZ | Self.flagPV | Self.flagC)) |
                Self.flagH | Self.flagN |
                (a & (Self.flagF5 | Self.flagF3))
            return 4

        // SCF
        case 0x37:
            f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
                Self.flagC |
                (a & (Self.flagF5 | Self.flagF3))
            return 4

        // CCF
        case 0x3F:
            let oldC = f & Self.flagC
            f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
                (oldC != 0 ? Self.flagH : 0) |
                (oldC != 0 ? 0 : Self.flagC) |
                (a & (Self.flagF5 | Self.flagF3))
            return 4

        // ADD HL, rr
        case 0x09: addHL(bc); return 11
        case 0x19: addHL(de); return 11
        case 0x29: addHL(hl); return 11
        case 0x39: addHL(sp); return 11

        // EX AF, AF'
        case 0x08: swap(&af, &af2); return 4

        // DJNZ d
        case 0x10:
            let offset = Int8(bitPattern: fetchByte(bus: bus))
            b &-= 1
            if b != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 13
            }
            return 8

        // JR d
        case 0x18:
            let offset = Int8(bitPattern: fetchByte(bus: bus))
            pc = pc &+ UInt16(bitPattern: Int16(offset))
            return 12

        // JR cc, d
        case 0x20: return jumpRelativeConditional(!flagZ, bus: bus)     // JR NZ
        case 0x28: return jumpRelativeConditional(flagZ, bus: bus)      // JR Z
        case 0x30: return jumpRelativeConditional(!flagC, bus: bus)     // JR NC
        case 0x38: return jumpRelativeConditional(flagC, bus: bus)      // JR C

        // LD r, r' — 8-bit register-to-register (0x40-0x7F block, excluding HALT)
        case 0x40: /* LD B,B */ return 4
        case 0x41: b = c; return 4
        case 0x42: b = d; return 4
        case 0x43: b = e; return 4
        case 0x44: b = h; return 4
        case 0x45: b = l; return 4
        case 0x46: b = bus.memRead(hl); return 7
        case 0x47: b = a; return 4
        case 0x48: c = b; return 4
        case 0x49: /* LD C,C */ return 4
        case 0x4A: c = d; return 4
        case 0x4B: c = e; return 4
        case 0x4C: c = h; return 4
        case 0x4D: c = l; return 4
        case 0x4E: c = bus.memRead(hl); return 7
        case 0x4F: c = a; return 4
        case 0x50: d = b; return 4
        case 0x51: d = c; return 4
        case 0x52: /* LD D,D */ return 4
        case 0x53: d = e; return 4
        case 0x54: d = h; return 4
        case 0x55: d = l; return 4
        case 0x56: d = bus.memRead(hl); return 7
        case 0x57: d = a; return 4
        case 0x58: e = b; return 4
        case 0x59: e = c; return 4
        case 0x5A: e = d; return 4
        case 0x5B: /* LD E,E */ return 4
        case 0x5C: e = h; return 4
        case 0x5D: e = l; return 4
        case 0x5E: e = bus.memRead(hl); return 7
        case 0x5F: e = a; return 4
        case 0x60: h = b; return 4
        case 0x61: h = c; return 4
        case 0x62: h = d; return 4
        case 0x63: h = e; return 4
        case 0x64: /* LD H,H */ return 4
        case 0x65: h = l; return 4
        case 0x66: h = bus.memRead(hl); return 7
        case 0x67: h = a; return 4
        case 0x68: l = b; return 4
        case 0x69: l = c; return 4
        case 0x6A: l = d; return 4
        case 0x6B: l = e; return 4
        case 0x6C: l = h; return 4
        case 0x6D: /* LD L,L */ return 4
        case 0x6E: l = bus.memRead(hl); return 7
        case 0x6F: l = a; return 4
        case 0x70: bus.memWrite(hl, value: b); return 7
        case 0x71: bus.memWrite(hl, value: c); return 7
        case 0x72: bus.memWrite(hl, value: d); return 7
        case 0x73: bus.memWrite(hl, value: e); return 7
        case 0x74: bus.memWrite(hl, value: h); return 7
        case 0x75: bus.memWrite(hl, value: l); return 7

        // HALT
        case 0x76:
            halted = true
            pc &-= 1  // PC stays on HALT opcode
            return 4

        case 0x77: bus.memWrite(hl, value: a); return 7
        case 0x78: a = b; return 4
        case 0x79: a = c; return 4
        case 0x7A: a = d; return 4
        case 0x7B: a = e; return 4
        case 0x7C: a = h; return 4
        case 0x7D: a = l; return 4
        case 0x7E: a = bus.memRead(hl); return 7
        case 0x7F: /* LD A,A */ return 4

        // ALU operations with register (0x80-0xBF)
        case 0x80: add8(b); return 4
        case 0x81: add8(c); return 4
        case 0x82: add8(d); return 4
        case 0x83: add8(e); return 4
        case 0x84: add8(h); return 4
        case 0x85: add8(l); return 4
        case 0x86: add8(bus.memRead(hl)); return 7
        case 0x87: add8(a); return 4

        case 0x88: adc8(b); return 4
        case 0x89: adc8(c); return 4
        case 0x8A: adc8(d); return 4
        case 0x8B: adc8(e); return 4
        case 0x8C: adc8(h); return 4
        case 0x8D: adc8(l); return 4
        case 0x8E: adc8(bus.memRead(hl)); return 7
        case 0x8F: adc8(a); return 4

        case 0x90: sub8(b); return 4
        case 0x91: sub8(c); return 4
        case 0x92: sub8(d); return 4
        case 0x93: sub8(e); return 4
        case 0x94: sub8(h); return 4
        case 0x95: sub8(l); return 4
        case 0x96: sub8(bus.memRead(hl)); return 7
        case 0x97: sub8(a); return 4

        case 0x98: sbc8(b); return 4
        case 0x99: sbc8(c); return 4
        case 0x9A: sbc8(d); return 4
        case 0x9B: sbc8(e); return 4
        case 0x9C: sbc8(h); return 4
        case 0x9D: sbc8(l); return 4
        case 0x9E: sbc8(bus.memRead(hl)); return 7
        case 0x9F: sbc8(a); return 4

        case 0xA0: and8(b); return 4
        case 0xA1: and8(c); return 4
        case 0xA2: and8(d); return 4
        case 0xA3: and8(e); return 4
        case 0xA4: and8(h); return 4
        case 0xA5: and8(l); return 4
        case 0xA6: and8(bus.memRead(hl)); return 7
        case 0xA7: and8(a); return 4

        case 0xA8: xor8(b); return 4
        case 0xA9: xor8(c); return 4
        case 0xAA: xor8(d); return 4
        case 0xAB: xor8(e); return 4
        case 0xAC: xor8(h); return 4
        case 0xAD: xor8(l); return 4
        case 0xAE: xor8(bus.memRead(hl)); return 7
        case 0xAF: xor8(a); return 4

        case 0xB0: or8(b); return 4
        case 0xB1: or8(c); return 4
        case 0xB2: or8(d); return 4
        case 0xB3: or8(e); return 4
        case 0xB4: or8(h); return 4
        case 0xB5: or8(l); return 4
        case 0xB6: or8(bus.memRead(hl)); return 7
        case 0xB7: or8(a); return 4

        case 0xB8: cp8(b); return 4
        case 0xB9: cp8(c); return 4
        case 0xBA: cp8(d); return 4
        case 0xBB: cp8(e); return 4
        case 0xBC: cp8(h); return 4
        case 0xBD: cp8(l); return 4
        case 0xBE: cp8(bus.memRead(hl)); return 7
        case 0xBF: cp8(a); return 4

        // ALU operations with immediate
        case 0xC6: add8(fetchByte(bus: bus)); return 7
        case 0xCE: adc8(fetchByte(bus: bus)); return 7
        case 0xD6: sub8(fetchByte(bus: bus)); return 7
        case 0xDE: sbc8(fetchByte(bus: bus)); return 7
        case 0xE6: and8(fetchByte(bus: bus)); return 7
        case 0xEE: xor8(fetchByte(bus: bus)); return 7
        case 0xF6: or8(fetchByte(bus: bus)); return 7
        case 0xFE: cp8(fetchByte(bus: bus)); return 7

        // RET cc
        case 0xC0: return retConditional(!flagZ, bus: bus)   // RET NZ
        case 0xC8: return retConditional(flagZ, bus: bus)    // RET Z
        case 0xD0: return retConditional(!flagC, bus: bus)   // RET NC
        case 0xD8: return retConditional(flagC, bus: bus)    // RET C
        case 0xE0: return retConditional(!flagPV, bus: bus)  // RET PO
        case 0xE8: return retConditional(flagPV, bus: bus)   // RET PE
        case 0xF0: return retConditional(!flagS, bus: bus)   // RET P
        case 0xF8: return retConditional(flagS, bus: bus)    // RET M

        // RET
        case 0xC9:
            pc = popWord(sp: &sp, bus: bus)
            return 10

        // POP rr
        case 0xC1: bc = popWord(sp: &sp, bus: bus); return 10
        case 0xD1: de = popWord(sp: &sp, bus: bus); return 10
        case 0xE1: hl = popWord(sp: &sp, bus: bus); return 10
        case 0xF1: af = popWord(sp: &sp, bus: bus); return 10

        // PUSH rr
        case 0xC5: pushWord(sp: &sp, value: bc, bus: bus); return 11
        case 0xD5: pushWord(sp: &sp, value: de, bus: bus); return 11
        case 0xE5: pushWord(sp: &sp, value: hl, bus: bus); return 11
        case 0xF5: pushWord(sp: &sp, value: af, bus: bus); return 11

        // JP cc, nn
        case 0xC2: return jumpConditional(!flagZ, bus: bus)   // JP NZ
        case 0xCA: return jumpConditional(flagZ, bus: bus)    // JP Z
        case 0xD2: return jumpConditional(!flagC, bus: bus)   // JP NC
        case 0xDA: return jumpConditional(flagC, bus: bus)    // JP C
        case 0xE2: return jumpConditional(!flagPV, bus: bus)  // JP PO
        case 0xEA: return jumpConditional(flagPV, bus: bus)   // JP PE
        case 0xF2: return jumpConditional(!flagS, bus: bus)   // JP P
        case 0xFA: return jumpConditional(flagS, bus: bus)    // JP M

        // JP nn
        case 0xC3:
            pc = fetchWord(bus: bus)
            return 10

        // CALL cc, nn
        case 0xC4: return callConditional(!flagZ, bus: bus)   // CALL NZ
        case 0xCC: return callConditional(flagZ, bus: bus)    // CALL Z
        case 0xD4: return callConditional(!flagC, bus: bus)   // CALL NC
        case 0xDC: return callConditional(flagC, bus: bus)    // CALL C
        case 0xE4: return callConditional(!flagPV, bus: bus)  // CALL PO
        case 0xEC: return callConditional(flagPV, bus: bus)   // CALL PE
        case 0xF4: return callConditional(!flagS, bus: bus)   // CALL P
        case 0xFC: return callConditional(flagS, bus: bus)    // CALL M

        // CALL nn
        case 0xCD:
            let addr = fetchWord(bus: bus)
            pushWord(sp: &sp, value: pc, bus: bus)
            pc = addr
            return 17

        // RST
        case 0xC7: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x00; return 11
        case 0xCF: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x08; return 11
        case 0xD7: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x10; return 11
        case 0xDF: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x18; return 11
        case 0xE7: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x20; return 11
        case 0xEF: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x28; return 11
        case 0xF7: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x30; return 11
        case 0xFF: pushWord(sp: &sp, value: pc, bus: bus); pc = 0x38; return 11

        // OUT (n), A
        case 0xD3:
            let port = fetchByte(bus: bus)
            bus.ioWrite(UInt16(port) | (UInt16(a) << 8), value: a)
            return 11

        // IN A, (n)
        case 0xDB:
            let port = fetchByte(bus: bus)
            a = bus.ioRead(UInt16(port) | (UInt16(a) << 8))
            return 11

        // EX (SP), HL
        case 0xE3:
            let lo = bus.memRead(sp)
            let hi = bus.memRead(sp &+ 1)
            bus.memWrite(sp, value: l)
            bus.memWrite(sp &+ 1, value: h)
            l = lo
            h = hi
            return 19

        // JP (HL)
        case 0xE9:
            pc = hl
            return 4

        // EX DE, HL
        case 0xEB: swap(&de, &hl); return 4

        // LD SP, HL
        case 0xF9: sp = hl; return 6

        // DI
        case 0xF3:
            iff1 = false
            iff2 = false
            return 4

        // EI
        case 0xFB:
            // Delay: IFF set after next instruction
            eiPending = true
            return 4

        // EXX
        case 0xD9:
            swap(&bc, &bc2)
            swap(&de, &de2)
            swap(&hl, &hl2)
            return 4

        // Prefix CB — bit operations
        case 0xCB:
            return executeCB(bus: bus)

        // Prefix DD — IX instructions
        case 0xDD:
            return executeDD(bus: bus)

        // Prefix ED — extended instructions
        case 0xED:
            return executeED(bus: bus)

        // Prefix FD — IY instructions
        case 0xFD:
            return executeFD(bus: bus)

        default:
            // Treat unknown opcodes as NOP
            return 4
        }
    }

    // MARK: - Conditional helpers

    private func jumpRelativeConditional(_ condition: Bool, bus: some Bus) -> Int {
        let offset = Int8(bitPattern: fetchByte(bus: bus))
        if condition {
            pc = pc &+ UInt16(bitPattern: Int16(offset))
            return 12
        }
        return 7
    }

    private func jumpConditional(_ condition: Bool, bus: some Bus) -> Int {
        let addr = fetchWord(bus: bus)
        if condition {
            pc = addr
        }
        return 10
    }

    private func callConditional(_ condition: Bool, bus: some Bus) -> Int {
        let addr = fetchWord(bus: bus)
        if condition {
            pushWord(sp: &sp, value: pc, bus: bus)
            pc = addr
            return 17
        }
        return 10
    }

    private func retConditional(_ condition: Bool, bus: some Bus) -> Int {
        if condition {
            pc = popWord(sp: &sp, bus: bus)
            return 11
        }
        return 5
    }
}
