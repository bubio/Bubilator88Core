/// Z80 CB-prefixed instructions (bit operations, rotates, shifts).
extension Z80 {

    /// Execute CB-prefixed instruction. Returns T-states (includes the CB prefix fetch).
    internal func executeCB(bus: some Bus) -> Int {
        let opcode = fetchByte(bus: bus)
        incrementR()

        let reg = opcode & 0x07
        let op = opcode >> 3

        // Read source value
        var value: UInt8
        let isMemHL = reg == 6
        if isMemHL {
            value = bus.memRead(hl)
        } else {
            value = readReg8(reg)
        }

        switch opcode & 0xC0 {
        case 0x00:
            // Rotate/shift operations (op = 0-7)
            switch op {
            case 0: value = rlcOp(value)    // RLC
            case 1: value = rrcOp(value)    // RRC
            case 2: value = rlOp(value)     // RL
            case 3: value = rrOp(value)     // RR
            case 4: value = slaOp(value)    // SLA
            case 5: value = sraOp(value)    // SRA
            case 6: value = sllOp(value)    // SLL (undocumented)
            case 7: value = srlOp(value)    // SRL
            default: break
            }
            if isMemHL {
                bus.memWrite(hl, value: value)
                return 15
            } else {
                writeReg8(reg, value: value)
                return 8
            }

        case 0x40:
            // BIT b, r
            let bit = (op & 0x07)
            bitOp(value, bit: bit, isMemHL: isMemHL)
            return isMemHL ? 12 : 8

        case 0x80:
            // RES b, r
            let bit = (op & 0x07)
            value &= ~(1 << bit)
            if isMemHL {
                bus.memWrite(hl, value: value)
                return 15
            } else {
                writeReg8(reg, value: value)
                return 8
            }

        case 0xC0:
            // SET b, r
            let bit = (op & 0x07)
            value |= (1 << bit)
            if isMemHL {
                bus.memWrite(hl, value: value)
                return 15
            } else {
                writeReg8(reg, value: value)
                return 8
            }

        default:
            return 8
        }
    }

    // MARK: - Register Read/Write by Index

    /// Read 8-bit register by index (0=B, 1=C, 2=D, 3=E, 4=H, 5=L, 6=(HL), 7=A)
    internal func readReg8(_ index: UInt8) -> UInt8 {
        switch index {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        case 6: return 0  // Should use bus.memRead(hl) — caller handles
        case 7: return a
        default: return 0
        }
    }

    /// Write 8-bit register by index
    internal func writeReg8(_ index: UInt8, value: UInt8) {
        switch index {
        case 0: b = value
        case 1: c = value
        case 2: d = value
        case 3: e = value
        case 4: h = value
        case 5: l = value
        case 6: break  // Should use bus.memWrite(hl) — caller handles
        case 7: a = value
        default: break
        }
    }

    // MARK: - Rotate/Shift Operations (full flag set)

    internal func rlcOp(_ value: UInt8) -> UInt8 {
        let bit7 = value >> 7
        let result = (value << 1) | bit7
        f = szFlags(result)
        if bit7 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func rrcOp(_ value: UInt8) -> UInt8 {
        let bit0 = value & 1
        let result = (value >> 1) | (bit0 << 7)
        f = szFlags(result)
        if bit0 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func rlOp(_ value: UInt8) -> UInt8 {
        let oldCarry: UInt8 = flagC ? 1 : 0
        let bit7 = value >> 7
        let result = (value << 1) | oldCarry
        f = szFlags(result)
        if bit7 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func rrOp(_ value: UInt8) -> UInt8 {
        let oldCarry: UInt8 = flagC ? 0x80 : 0
        let bit0 = value & 1
        let result = (value >> 1) | oldCarry
        f = szFlags(result)
        if bit0 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func slaOp(_ value: UInt8) -> UInt8 {
        let bit7 = value >> 7
        let result = value << 1
        f = szFlags(result)
        if bit7 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func sraOp(_ value: UInt8) -> UInt8 {
        let bit0 = value & 1
        let result = (value >> 1) | (value & 0x80)  // preserve bit 7
        f = szFlags(result)
        if bit0 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    /// SLL — undocumented: shift left, bit 0 = 1
    internal func sllOp(_ value: UInt8) -> UInt8 {
        let bit7 = value >> 7
        let result = (value << 1) | 0x01
        f = szFlags(result)
        if bit7 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    internal func srlOp(_ value: UInt8) -> UInt8 {
        let bit0 = value & 1
        let result = value >> 1
        f = szFlags(result)
        if bit0 != 0 { f |= Self.flagC }
        if parity(result) { f |= Self.flagPV }
        return result
    }

    // MARK: - BIT test

    internal func bitOp(_ value: UInt8, bit: UInt8, isMemHL: Bool) {
        let mask: UInt8 = 1 << bit
        let result = value & mask

        f = (f & Self.flagC) | Self.flagH
        if result == 0 { f |= Self.flagZ | Self.flagPV }
        if bit == 7 && result != 0 { f |= Self.flagS }

        if isMemHL {
            // F5/F3 from high byte of memptr (undocumented) — simplified
        } else {
            f |= value & (Self.flagF5 | Self.flagF3)
        }
    }
}
