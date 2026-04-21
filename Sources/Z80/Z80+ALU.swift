/// Z80 ALU (Arithmetic Logic Unit) operations.
extension Z80 {

    // MARK: - 8-bit Arithmetic

    internal func add8(_ value: UInt8) {
        let result16 = UInt16(a) &+ UInt16(value)
        let result = UInt8(result16 & 0xFF)
        let halfCarry = (a & 0x0F) &+ (value & 0x0F)
        let overflow = (a ^ value ^ 0x80) & (a ^ result) & 0x80

        f = szFlags(result)
        if result16 > 0xFF { f |= Self.flagC }
        if halfCarry > 0x0F { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        // N = 0 (add)
        a = result
    }

    internal func adc8(_ value: UInt8) {
        let carry: UInt8 = flagC ? 1 : 0
        let result16 = UInt16(a) &+ UInt16(value) &+ UInt16(carry)
        let result = UInt8(result16 & 0xFF)
        let halfCarry = (a & 0x0F) &+ (value & 0x0F) &+ carry
        let overflow = (a ^ value ^ 0x80) & (a ^ result) & 0x80

        f = szFlags(result)
        if result16 > 0xFF { f |= Self.flagC }
        if halfCarry > 0x0F { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        a = result
    }

    internal func sub8(_ value: UInt8) {
        let result16 = UInt16(a) &- UInt16(value)
        let result = UInt8(result16 & 0xFF)
        let halfBorrow = Int(a & 0x0F) - Int(value & 0x0F)
        let overflow = (a ^ value) & (a ^ result) & 0x80

        f = szFlags(result) | Self.flagN
        if result16 > 0xFF { f |= Self.flagC }
        if halfBorrow < 0 { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        a = result
    }

    internal func sbc8(_ value: UInt8) {
        let carry: UInt8 = flagC ? 1 : 0
        let result16 = UInt16(a) &- UInt16(value) &- UInt16(carry)
        let result = UInt8(result16 & 0xFF)
        let halfBorrow = Int(a & 0x0F) - Int(value & 0x0F) - Int(carry)
        let overflow = (a ^ value) & (a ^ result) & 0x80

        f = szFlags(result) | Self.flagN
        if result16 > 0xFF { f |= Self.flagC }
        if halfBorrow < 0 { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
        a = result
    }

    internal func and8(_ value: UInt8) {
        a &= value
        f = szFlags(a) | Self.flagH
        if parity(a) { f |= Self.flagPV }
    }

    internal func xor8(_ value: UInt8) {
        a ^= value
        f = szFlags(a)
        if parity(a) { f |= Self.flagPV }
    }

    internal func or8(_ value: UInt8) {
        a |= value
        f = szFlags(a)
        if parity(a) { f |= Self.flagPV }
    }

    internal func cp8(_ value: UInt8) {
        let result16 = UInt16(a) &- UInt16(value)
        let result = UInt8(result16 & 0xFF)
        let halfBorrow = Int(a & 0x0F) - Int(value & 0x0F)
        let overflow = (a ^ value) & (a ^ result) & 0x80

        // F5/F3 come from the operand, not the result, for CP
        f = (szFlags(result) & ~(Self.flagF5 | Self.flagF3)) | Self.flagN
        f |= value & (Self.flagF5 | Self.flagF3)
        if result16 > 0xFF { f |= Self.flagC }
        if halfBorrow < 0 { f |= Self.flagH }
        if overflow != 0 { f |= Self.flagPV }
    }

    internal func inc8(_ value: UInt8) -> UInt8 {
        let result = value &+ 1
        let halfCarry = (value & 0x0F) &+ 1

        f = (f & Self.flagC) | szFlags(result)
        if halfCarry > 0x0F { f |= Self.flagH }
        if value == 0x7F { f |= Self.flagPV }  // overflow: 0x7F→0x80
        // N = 0
        return result
    }

    internal func dec8(_ value: UInt8) -> UInt8 {
        let result = value &- 1
        let halfBorrow = Int(value & 0x0F) - 1

        f = (f & Self.flagC) | szFlags(result) | Self.flagN
        if halfBorrow < 0 { f |= Self.flagH }
        if value == 0x80 { f |= Self.flagPV }  // overflow: 0x80→0x7F
        return result
    }

    // MARK: - 16-bit Arithmetic

    internal func addHL(_ value: UInt16) {
        let result32 = UInt32(hl) &+ UInt32(value)
        let halfCarry = (hl & 0x0FFF) &+ (value & 0x0FFF)

        f = (f & (Self.flagS | Self.flagZ | Self.flagPV))  // preserve S, Z, PV
        if result32 > 0xFFFF { f |= Self.flagC }
        if halfCarry > 0x0FFF { f |= Self.flagH }
        // N = 0
        hl = UInt16(result32 & 0xFFFF)
        f |= UInt8((hl >> 8)) & (Self.flagF5 | Self.flagF3)  // undocumented from high byte
    }

    // MARK: - Rotate/Shift (accumulator)

    internal func rlca() {
        let bit7 = a >> 7
        a = (a << 1) | bit7
        f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
            (bit7 != 0 ? Self.flagC : 0) |
            (a & (Self.flagF5 | Self.flagF3))
    }

    internal func rrca() {
        let bit0 = a & 1
        a = (a >> 1) | (bit0 << 7)
        f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
            (bit0 != 0 ? Self.flagC : 0) |
            (a & (Self.flagF5 | Self.flagF3))
    }

    internal func rla() {
        let oldCarry: UInt8 = flagC ? 1 : 0
        let bit7 = a >> 7
        a = (a << 1) | oldCarry
        f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
            (bit7 != 0 ? Self.flagC : 0) |
            (a & (Self.flagF5 | Self.flagF3))
    }

    internal func rra() {
        let oldCarry: UInt8 = flagC ? 0x80 : 0
        let bit0 = a & 1
        a = (a >> 1) | oldCarry
        f = (f & (Self.flagS | Self.flagZ | Self.flagPV)) |
            (bit0 != 0 ? Self.flagC : 0) |
            (a & (Self.flagF5 | Self.flagF3))
    }

    // MARK: - DAA

    internal func daa() {
        let oldA = a
        let oldF = f
        let subtract = (oldF & Self.flagN) != 0
        let hadCarry = (oldF & Self.flagC) != 0
        let hadHalfCarry = (oldF & Self.flagH) != 0

        var adjusted = Int(oldA)
        var setCarry = false
        var setHalfCarry = false

        // Match the PC-88 reference emulators' table-driven DAA behavior.
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
        var newFlags = (oldF & Self.flagN) | szFlags(result)
        if setCarry { newFlags |= Self.flagC }
        if setHalfCarry { newFlags |= Self.flagH }
        if parity(result) { newFlags |= Self.flagPV }

        a = result
        f = newFlags
    }
}
