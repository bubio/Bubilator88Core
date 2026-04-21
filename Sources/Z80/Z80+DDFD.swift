/// Z80 DD/FD-prefixed instructions (IX/IY index register operations).
///
/// DD and FD prefixes work identically, substituting IX or IY for HL.
/// This is implemented as a shared method with a register parameter.
extension Z80 {

    /// Execute DD-prefixed instruction. Returns T-states.
    internal func executeDD(bus: some Bus) -> Int {
        return executeIndexed(bus: bus, indexReg: &ix)
    }

    /// Execute FD-prefixed instruction. Returns T-states.
    internal func executeFD(bus: some Bus) -> Int {
        return executeIndexed(bus: bus, indexReg: &iy)
    }

    /// Shared IX/IY instruction execution.
    private func executeIndexed(bus: some Bus, indexReg: inout UInt16) -> Int {
        let opcode = fetchByte(bus: bus)
        incrementR()

        switch opcode {

        // LD IX/IY, nn
        case 0x21:
            indexReg = fetchWord(bus: bus)
            return 14

        // LD (nn), IX/IY
        case 0x22:
            let addr = fetchWord(bus: bus)
            bus.memWrite(addr, value: UInt8(indexReg & 0xFF))
            bus.memWrite(addr &+ 1, value: UInt8(indexReg >> 8))
            return 20

        // INC IX/IY
        case 0x23:
            indexReg &+= 1
            return 10

        // DEC IX/IY
        case 0x2B:
            indexReg &-= 1
            return 10

        // LD IX/IY, (nn)
        case 0x2A:
            let addr = fetchWord(bus: bus)
            let lo = UInt16(bus.memRead(addr))
            let hi = UInt16(bus.memRead(addr &+ 1))
            indexReg = (hi << 8) | lo
            return 20

        // ADD IX/IY, rr
        case 0x09: addIndex(&indexReg, bc); return 15
        case 0x19: addIndex(&indexReg, de); return 15
        case 0x29: addIndex(&indexReg, indexReg); return 15
        case 0x39: addIndex(&indexReg, sp); return 15

        // INC (IX/IY+d)
        case 0x34:
            let d = Int8(bitPattern: fetchByte(bus: bus))
            let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
            let val = inc8(bus.memRead(addr))
            bus.memWrite(addr, value: val)
            return 23

        // DEC (IX/IY+d)
        case 0x35:
            let d = Int8(bitPattern: fetchByte(bus: bus))
            let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
            let val = dec8(bus.memRead(addr))
            bus.memWrite(addr, value: val)
            return 23

        // LD (IX/IY+d), n
        case 0x36:
            let d = Int8(bitPattern: fetchByte(bus: bus))
            let n = fetchByte(bus: bus)
            let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
            bus.memWrite(addr, value: n)
            return 19

        // INC IXH/IYH (undocumented)
        case 0x24:
            var hi = UInt8(indexReg >> 8)
            hi = inc8(hi)
            indexReg = (UInt16(hi) << 8) | (indexReg & 0xFF)
            return 8

        // DEC IXH/IYH (undocumented)
        case 0x25:
            var hi = UInt8(indexReg >> 8)
            hi = dec8(hi)
            indexReg = (UInt16(hi) << 8) | (indexReg & 0xFF)
            return 8

        // LD IXH/IYH, n (undocumented)
        case 0x26:
            let n = fetchByte(bus: bus)
            indexReg = (UInt16(n) << 8) | (indexReg & 0xFF)
            return 11

        // INC IXL/IYL (undocumented)
        case 0x2C:
            var lo = UInt8(indexReg & 0xFF)
            lo = inc8(lo)
            indexReg = (indexReg & 0xFF00) | UInt16(lo)
            return 8

        // DEC IXL/IYL (undocumented)
        case 0x2D:
            var lo = UInt8(indexReg & 0xFF)
            lo = dec8(lo)
            indexReg = (indexReg & 0xFF00) | UInt16(lo)
            return 8

        // LD IXL/IYL, n (undocumented)
        case 0x2E:
            let n = fetchByte(bus: bus)
            indexReg = (indexReg & 0xFF00) | UInt16(n)
            return 11

        // LD r, (IX/IY+d) — 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E
        case 0x46, 0x4E, 0x56, 0x5E, 0x66, 0x6E, 0x7E:
            let d = Int8(bitPattern: fetchByte(bus: bus))
            let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
            let val = bus.memRead(addr)
            let dst = (opcode >> 3) & 0x07
            writeReg8(dst, value: val)
            return 19

        // LD (IX/IY+d), r — 0x70-0x77 (except 0x76 = HALT)
        case 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x77:
            let d = Int8(bitPattern: fetchByte(bus: bus))
            let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
            let src = opcode & 0x07
            bus.memWrite(addr, value: readReg8(src))
            return 19

        // ALU A, (IX/IY+d) — 0x86, 0x8E, 0x96, 0x9E, 0xA6, 0xAE, 0xB6, 0xBE
        case 0x86:
            let val = readIndexed(indexReg, bus: bus)
            add8(val); return 19
        case 0x8E:
            let val = readIndexed(indexReg, bus: bus)
            adc8(val); return 19
        case 0x96:
            let val = readIndexed(indexReg, bus: bus)
            sub8(val); return 19
        case 0x9E:
            let val = readIndexed(indexReg, bus: bus)
            sbc8(val); return 19
        case 0xA6:
            let val = readIndexed(indexReg, bus: bus)
            and8(val); return 19
        case 0xAE:
            let val = readIndexed(indexReg, bus: bus)
            xor8(val); return 19
        case 0xB6:
            let val = readIndexed(indexReg, bus: bus)
            or8(val); return 19
        case 0xBE:
            let val = readIndexed(indexReg, bus: bus)
            cp8(val); return 19

        // LD r, r' with IXH/IXL or IYH/IYL substitution.
        case 0x40...0x7F where opcode != 0x76:
            let dst = UInt8((opcode >> 3) & 0x07)
            let src = UInt8(opcode & 0x07)
            if dst != 6 && src != 6 {
                let value = readIndexedReg8(src, indexReg: indexReg)
                writeIndexedReg8(dst, value: value, indexReg: &indexReg)
                return 8
            }
            pc &-= 1
            return 4

        // ALU A, r with IXH/IXL or IYH/IYL substitution.
        case 0x80...0xBF:
            let src = UInt8(opcode & 0x07)
            if src != 6 {
                let value = readIndexedReg8(src, indexReg: indexReg)
                switch opcode >> 3 {
                case 0x10: add8(value)
                case 0x11: adc8(value)
                case 0x12: sub8(value)
                case 0x13: sbc8(value)
                case 0x14: and8(value)
                case 0x15: xor8(value)
                case 0x16: or8(value)
                case 0x17: cp8(value)
                default: break
                }
                return 8
            }
            pc &-= 1
            return 4

        // POP IX/IY
        case 0xE1:
            indexReg = popWord(sp: &sp, bus: bus)
            return 14

        // PUSH IX/IY
        case 0xE5:
            pushWord(sp: &sp, value: indexReg, bus: bus)
            return 15

        // EX (SP), IX/IY
        case 0xE3:
            let lo = bus.memRead(sp)
            let hi = bus.memRead(sp &+ 1)
            bus.memWrite(sp, value: UInt8(indexReg & 0xFF))
            bus.memWrite(sp &+ 1, value: UInt8(indexReg >> 8))
            indexReg = (UInt16(hi) << 8) | UInt16(lo)
            return 23

        // JP (IX/IY)
        case 0xE9:
            pc = indexReg
            return 8

        // LD SP, IX/IY
        case 0xF9:
            sp = indexReg
            return 10

        // DDCB / FDCB — indexed bit operations
        case 0xCB:
            return executeIndexedCB(indexReg: indexReg, bus: bus)

        default:
            // Unrecognized DD/FD opcode: treat as NOP prefix, re-execute opcode
            // The opcode is consumed but acts as if only the prefix was a NOP
            pc &-= 1  // re-execute the opcode without prefix
            return 4
        }
    }

    // MARK: - Indexed Helpers

    private func readIndexed(_ indexReg: UInt16, bus: some Bus) -> UInt8 {
        let d = Int8(bitPattern: fetchByte(bus: bus))
        let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
        return bus.memRead(addr)
    }

    private func readIndexedReg8(_ index: UInt8, indexReg: UInt16) -> UInt8 {
        switch index {
        case 4: return UInt8(indexReg >> 8)
        case 5: return UInt8(indexReg & 0xFF)
        default: return readReg8(index)
        }
    }

    private func writeIndexedReg8(_ index: UInt8, value: UInt8, indexReg: inout UInt16) {
        switch index {
        case 4:
            indexReg = (UInt16(value) << 8) | (indexReg & 0x00FF)
        case 5:
            indexReg = (indexReg & 0xFF00) | UInt16(value)
        default:
            writeReg8(index, value: value)
        }
    }

    private func addIndex(_ indexReg: inout UInt16, _ value: UInt16) {
        let result32 = UInt32(indexReg) &+ UInt32(value)
        let halfCarry = (indexReg & 0x0FFF) &+ (value & 0x0FFF)

        f = (f & (Self.flagS | Self.flagZ | Self.flagPV))
        if result32 > 0xFFFF { f |= Self.flagC }
        if halfCarry > 0x0FFF { f |= Self.flagH }
        indexReg = UInt16(result32 & 0xFFFF)
        f |= UInt8(indexReg >> 8) & (Self.flagF5 | Self.flagF3)
    }

    // MARK: - DDCB/FDCB — Indexed Bit Operations

    /// DDCB/FDCB prefix: displacement comes before opcode.
    private func executeIndexedCB(indexReg: UInt16, bus: some Bus) -> Int {
        let d = Int8(bitPattern: fetchByte(bus: bus))
        let opcode = fetchByte(bus: bus)
        let addr = UInt16(truncatingIfNeeded: Int(indexReg) &+ Int(d))
        var value = bus.memRead(addr)

        let op = opcode >> 3
        let reg = opcode & 0x07

        switch opcode & 0xC0 {
        case 0x00:
            // Rotate/shift
            switch op {
            case 0: value = rlcOp(value)
            case 1: value = rrcOp(value)
            case 2: value = rlOp(value)
            case 3: value = rrOp(value)
            case 4: value = slaOp(value)
            case 5: value = sraOp(value)
            case 6: value = sllOp(value)
            case 7: value = srlOp(value)
            default: break
            }
            bus.memWrite(addr, value: value)
            if reg != 6 { writeReg8(reg, value: value) }
            return 23

        case 0x40:
            // BIT b, (IX/IY+d)
            let bit = op & 0x07
            bitOp(value, bit: bit, isMemHL: true)
            return 20

        case 0x80:
            // RES b, (IX/IY+d)
            let bit = op & 0x07
            value &= ~(1 << bit)
            bus.memWrite(addr, value: value)
            if reg != 6 { writeReg8(reg, value: value) }
            return 23

        case 0xC0:
            // SET b, (IX/IY+d)
            let bit = op & 0x07
            value |= (1 << bit)
            bus.memWrite(addr, value: value)
            if reg != 6 { writeReg8(reg, value: value) }
            return 23

        default:
            return 23
        }
    }
}
