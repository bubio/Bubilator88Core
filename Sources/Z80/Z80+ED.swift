/// Z80 ED-prefixed instructions (extended operations).
extension Z80 {

    /// Execute ED-prefixed instruction. Returns T-states (includes ED prefix).
    internal func executeED(bus: some Bus) -> Int {
        let opcode = fetchByte(bus: bus)
        incrementR()

        switch opcode {

        // IN r, (C) — port address is full BC
        case 0x40: b = inC(bus: bus); return 12
        case 0x48: c = inC(bus: bus); return 12
        case 0x50: d = inC(bus: bus); return 12
        case 0x58: e = inC(bus: bus); return 12
        case 0x60: h = inC(bus: bus); return 12
        case 0x68: l = inC(bus: bus); return 12
        case 0x70: _ = inC(bus: bus); return 12  // IN (C) — result discarded, flags set
        case 0x78: a = inC(bus: bus); return 12

        // OUT (C), r
        case 0x41: bus.ioWrite(bc, value: b); return 12
        case 0x49: bus.ioWrite(bc, value: c); return 12
        case 0x51: bus.ioWrite(bc, value: d); return 12
        case 0x59: bus.ioWrite(bc, value: e); return 12
        case 0x61: bus.ioWrite(bc, value: h); return 12
        case 0x69: bus.ioWrite(bc, value: l); return 12
        case 0x71: bus.ioWrite(bc, value: 0); return 12  // OUT (C), 0
        case 0x79: bus.ioWrite(bc, value: a); return 12

        // SBC HL, rr
        case 0x42: sbcHL(bc); return 15
        case 0x52: sbcHL(de); return 15
        case 0x62: sbcHL(hl); return 15
        case 0x72: sbcHL(sp); return 15

        // ADC HL, rr
        case 0x4A: adcHL(bc); return 15
        case 0x5A: adcHL(de); return 15
        case 0x6A: adcHL(hl); return 15
        case 0x7A: adcHL(sp); return 15

        // LD (nn), rr
        case 0x43:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: UInt8(bc & 0xFF))
            bus.memWrite(addr &+ 1, value: UInt8(bc >> 8))
            return 20
        case 0x53:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: UInt8(de & 0xFF))
            bus.memWrite(addr &+ 1, value: UInt8(de >> 8))
            return 20
        case 0x63:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: UInt8(hl & 0xFF))
            bus.memWrite(addr &+ 1, value: UInt8(hl >> 8))
            return 20
        case 0x73:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: UInt8(sp & 0xFF))
            bus.memWrite(addr &+ 1, value: UInt8(sp >> 8))
            return 20

        // LD rr, (nn)
        case 0x4B:
            let addr = fetchWord(bus: bus)
            let lo = UInt16(bus.memRead(addr))
            let hi = UInt16(bus.memRead(addr &+ 1))
            bc = (hi << 8) | lo
            return 20
        case 0x5B:
            let addr = fetchWord(bus: bus)
            let lo = UInt16(bus.memRead(addr))
            let hi = UInt16(bus.memRead(addr &+ 1))
            de = (hi << 8) | lo
            return 20
        case 0x6B:
            let addr = fetchWord(bus: bus)
            let lo = UInt16(bus.memRead(addr))
            let hi = UInt16(bus.memRead(addr &+ 1))
            hl = (hi << 8) | lo
            return 20
        case 0x7B:
            let addr = fetchWord(bus: bus)
            let lo = UInt16(bus.memRead(addr))
            let hi = UInt16(bus.memRead(addr &+ 1))
            sp = (hi << 8) | lo
            return 20

        // NEG
        case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C:
            let old = a
            a = 0
            sub8(old)
            return 8

        // RETN
        case 0x45, 0x55, 0x65, 0x75:
            iff1 = iff2
            pc = popWord(sp: &sp, bus: bus)
            return 14

        // RETI
        case 0x4D, 0x5D, 0x6D, 0x7D:
            iff1 = iff2
            pc = popWord(sp: &sp, bus: bus)
            return 14

        // IM 0
        case 0x46, 0x66: im = 0; return 8
        // IM 0 (undocumented aliases — real hardware behaves as IM 0)
        case 0x4E, 0x6E: im = 0; return 8
        // IM 1
        case 0x56, 0x76: im = 1; return 8
        // IM 2
        case 0x5E, 0x7E: im = 2; return 8

        // Undocumented NOP (explicit — consumed as 2-byte NOP)
        case 0x77, 0x7F: return 8

        // LD I, A
        case 0x47: i = a; return 9
        // LD R, A
        case 0x4F: r = a; return 9

        // LD A, I
        case 0x57:
            a = i
            f = (f & Self.flagC) | szFlags(a)
            if iff2 { f |= Self.flagPV }
            return 9

        // LD A, R
        case 0x5F:
            a = r
            f = (f & Self.flagC) | szFlags(a)
            if iff2 { f |= Self.flagPV }
            return 9

        // RRD
        case 0x67:
            let mem = bus.memRead(hl)
            let newMem = (a << 4) | (mem >> 4)
            a = (a & 0xF0) | (mem & 0x0F)
            bus.memWrite(hl, value: newMem)
            f = (f & Self.flagC) | szFlags(a)
            if parity(a) { f |= Self.flagPV }
            return 18

        // RLD
        case 0x6F:
            let mem = bus.memRead(hl)
            let newMem = (mem << 4) | (a & 0x0F)
            a = (a & 0xF0) | (mem >> 4)
            bus.memWrite(hl, value: newMem)
            f = (f & Self.flagC) | szFlags(a)
            if parity(a) { f |= Self.flagPV }
            return 18

        // LDI
        case 0xA0:
            let val = bus.memRead(hl)
            bus.memWrite(de, value: val)
            de &+= 1
            hl &+= 1
            bc &-= 1
            f &= ~(Self.flagH | Self.flagN | Self.flagPV)
            if bc != 0 { f |= Self.flagPV }
            let n = val &+ a
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            return 16

        // LDIR
        case 0xB0:
            let val = bus.memRead(hl)
            bus.memWrite(de, value: val)
            de &+= 1
            hl &+= 1
            bc &-= 1
            f &= ~(Self.flagH | Self.flagN | Self.flagPV)
            let n = val &+ a
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            if bc != 0 {
                f |= Self.flagPV
                pc &-= 2  // repeat
                return 21
            }
            return 16

        // LDD
        case 0xA8:
            let val = bus.memRead(hl)
            bus.memWrite(de, value: val)
            de &-= 1
            hl &-= 1
            bc &-= 1
            f &= ~(Self.flagH | Self.flagN | Self.flagPV)
            if bc != 0 { f |= Self.flagPV }
            let n = val &+ a
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            return 16

        // LDDR
        case 0xB8:
            let val = bus.memRead(hl)
            bus.memWrite(de, value: val)
            de &-= 1
            hl &-= 1
            bc &-= 1
            f &= ~(Self.flagH | Self.flagN | Self.flagPV)
            let n = val &+ a
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            if bc != 0 {
                f |= Self.flagPV
                pc &-= 2
                return 21
            }
            return 16

        // CPI
        case 0xA1:
            let val = bus.memRead(hl)
            let result = a &- val
            hl &+= 1
            bc &-= 1
            f = (f & Self.flagC) | szFlags(result) | Self.flagN
            if (a & 0x0F) < (val & 0x0F) { f |= Self.flagH }
            if bc != 0 { f |= Self.flagPV }
            let n = result &- (flagH ? 1 : 0)
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            return 16

        // CPIR
        case 0xB1:
            let val = bus.memRead(hl)
            let result = a &- val
            hl &+= 1
            bc &-= 1
            f = (f & Self.flagC) | szFlags(result) | Self.flagN
            if (a & 0x0F) < (val & 0x0F) { f |= Self.flagH }
            if bc != 0 { f |= Self.flagPV }
            let n = result &- (flagH ? 1 : 0)
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            if bc != 0 && result != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // CPD
        case 0xA9:
            let val = bus.memRead(hl)
            let result = a &- val
            hl &-= 1
            bc &-= 1
            f = (f & Self.flagC) | szFlags(result) | Self.flagN
            if (a & 0x0F) < (val & 0x0F) { f |= Self.flagH }
            if bc != 0 { f |= Self.flagPV }
            let n = result &- (flagH ? 1 : 0)
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            return 16

        // CPDR
        case 0xB9:
            let val = bus.memRead(hl)
            let result = a &- val
            hl &-= 1
            bc &-= 1
            f = (f & Self.flagC) | szFlags(result) | Self.flagN
            if (a & 0x0F) < (val & 0x0F) { f |= Self.flagH }
            if bc != 0 { f |= Self.flagPV }
            let n = result &- (flagH ? 1 : 0)
            f = (f & ~(Self.flagF5 | Self.flagF3)) | ((n & 0x02) != 0 ? Self.flagF5 : 0) | (n & Self.flagF3)
            if bc != 0 && result != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // INI
        case 0xA2:
            let val = bus.ioRead(bc)
            bus.memWrite(hl, value: val)
            hl &+= 1
            b &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(c &+ 1) &+ UInt16(val))
            return 16

        // INIR
        case 0xB2:
            let val = bus.ioRead(bc)
            bus.memWrite(hl, value: val)
            hl &+= 1
            b &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(c &+ 1) &+ UInt16(val))
            if b != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // IND
        case 0xAA:
            let val = bus.ioRead(bc)
            bus.memWrite(hl, value: val)
            hl &-= 1
            b &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(c &- 1) &+ UInt16(val))
            return 16

        // INDR
        case 0xBA:
            let val = bus.ioRead(bc)
            bus.memWrite(hl, value: val)
            hl &-= 1
            b &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(c &- 1) &+ UInt16(val))
            if b != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // OUTI
        case 0xA3:
            let val = bus.memRead(hl)
            b &-= 1
            bus.ioWrite(bc, value: val)
            hl &+= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(l) &+ UInt16(val))
            return 16

        // OTIR
        case 0xB3:
            let val = bus.memRead(hl)
            b &-= 1
            bus.ioWrite(bc, value: val)
            hl &+= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(l) &+ UInt16(val))
            if b != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // OUTD
        case 0xAB:
            let val = bus.memRead(hl)
            b &-= 1
            bus.ioWrite(bc, value: val)
            hl &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(l) &+ UInt16(val))
            return 16

        // OTDR
        case 0xBB:
            let val = bus.memRead(hl)
            b &-= 1
            bus.ioWrite(bc, value: val)
            hl &-= 1
            updateBlockIOFlags(ioValue: val, sum: UInt16(l) &+ UInt16(val))
            if b != 0 {
                pc &-= 2
                return 21
            }
            return 16

        // ED 08: EX AF, AF' (BubiC compatible).
        // BubiC's Z80 falls through ALL undocumented ED opcodes to the
        // unprefixed handler, but doing so for multi-byte instructions
        // (e.g. ED 01 → LD BC,nn) corrupts PC and registers.
        // Only ED 08 is known to be used intentionally by PC-8801 software
        // (あたしのぱぴぷぺぽ PIO handshake at 0x08A2).
        case 0x08: swap(&af, &af2); return 8

        default:
            // Undocumented ED opcodes act as NOP (2-byte NOP)
            return 8
        }
    }

    // MARK: - ED Helpers

    private func inC(bus: some Bus) -> UInt8 {
        let val = bus.ioRead(bc)
        f = (f & Self.flagC) | szFlags(val)
        if parity(val) { f |= Self.flagPV }
        return val
    }

    private func updateBlockIOFlags(ioValue: UInt8, sum: UInt16) {
        f = szFlags(b)
        if (ioValue & 0x80) != 0 {
            f |= Self.flagN
        }
        if sum > 0x00FF {
            f |= Self.flagH | Self.flagC
        }
        let paritySeed = UInt8(sum & 0x0007) ^ b
        if parity(paritySeed) {
            f |= Self.flagPV
        }
    }

    internal func sbcHL(_ value: UInt16) {
        let carry: UInt32 = flagC ? 1 : 0
        let result32 = UInt32(hl) &- UInt32(value) &- carry
        let result = UInt16(result32 & 0xFFFF)
        let halfBorrow = Int(hl & 0x0FFF) - Int(value & 0x0FFF) - Int(carry)
        let overflow = (hl ^ value) & (hl ^ result) & 0x8000

        f = Self.flagN
        if result == 0 { f |= Self.flagZ }
        if result & 0x8000 != 0 { f |= Self.flagS }
        if result32 > 0xFFFF { f |= Self.flagC }
        if halfBorrow < 0 { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        f |= UInt8(result >> 8) & (Self.flagF5 | Self.flagF3)
        hl = result
    }

    internal func adcHL(_ value: UInt16) {
        let carry: UInt32 = flagC ? 1 : 0
        let result32 = UInt32(hl) &+ UInt32(value) &+ carry
        let result = UInt16(result32 & 0xFFFF)
        let halfCarry = (hl & 0x0FFF) &+ (value & 0x0FFF) &+ UInt16(carry)
        let overflow = (hl ^ value ^ 0x8000) & (hl ^ result) & 0x8000

        f = 0
        if result == 0 { f |= Self.flagZ }
        if result & 0x8000 != 0 { f |= Self.flagS }
        if result32 > 0xFFFF { f |= Self.flagC }
        if halfCarry > 0x0FFF { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        f |= UInt8(result >> 8) & (Self.flagF5 | Self.flagF3)
        hl = result
    }
}
