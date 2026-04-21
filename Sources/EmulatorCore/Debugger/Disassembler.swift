import Foundation

/// A single disassembled Z80 instruction.
public struct DisassembledInstruction: Sendable, Hashable {
    public let address: UInt16
    public let bytes: [UInt8]
    public let mnemonic: String

    /// Next address after this instruction.
    public var nextAddress: UInt16 {
        address &+ UInt16(bytes.count)
    }
}

/// Z80 disassembler — pure function, shared by Main and Sub CPU views.
///
/// Keeps a best-effort mnemonic database that covers the vast majority of
/// instructions encountered in PC-8801 ROMs and game code. Unknown opcodes
/// fall back to `DB xx` form so instruction length is always correct.
public enum Disassembler {

    /// Maximum Z80 instruction length (e.g. `DD CB d op`, `DD 36 d n`,
    /// `ED 43 nn nn`). We prefetch this many bytes and work on the
    /// buffer so the decoder stays a pure value-type transformation.
    private static let maxInstructionBytes = 4

    /// Decode one instruction starting at `address`.
    public static func decode(
        at address: UInt16,
        read: (UInt16) -> UInt8
    ) -> DisassembledInstruction {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(maxInstructionBytes)
        for i in 0..<maxInstructionBytes {
            buffer.append(read(address &+ UInt16(i)))
        }
        var cursor = Cursor(origin: address, source: buffer)
        let mnemonic = decodeRoot(cursor: &cursor)
        return DisassembledInstruction(
            address: address,
            bytes: Array(cursor.source.prefix(cursor.position)),
            mnemonic: mnemonic
        )
    }

    // MARK: - Byte reader

    fileprivate struct Cursor {
        let origin: UInt16
        let source: [UInt8]
        var position: Int = 0

        mutating func next() -> UInt8 {
            let b = source[position]
            position += 1
            return b
        }

        mutating func nextWord() -> UInt16 {
            let lo = UInt16(next())
            let hi = UInt16(next())
            return (hi << 8) | lo
        }

        mutating func nextSignedByte() -> Int8 {
            Int8(bitPattern: next())
        }
    }

    // MARK: - Root decode

    private static func decodeRoot(cursor: inout Cursor) -> String {
        let op = cursor.next()
        switch op {
        case 0xCB: return decodeCB(cursor: &cursor, indexPrefix: nil)
        case 0xED: return decodeED(cursor: &cursor)
        case 0xDD: return decodeIndex(cursor: &cursor, prefix: .ix)
        case 0xFD: return decodeIndex(cursor: &cursor, prefix: .iy)
        default:   return decodeUnprefixed(op: op, cursor: &cursor)
        }
    }

    // MARK: - Unprefixed (main 256)

    private static func decodeUnprefixed(op: UInt8, cursor: inout Cursor) -> String {
        // Fast paths for densely-packed register encodings.
        // 01xxxyyy — LD r,r'    (0x40-0x7F, 0x76 = HALT)
        if op & 0xC0 == 0x40 {
            if op == 0x76 { return "HALT" }
            let dst = reg8Name((op >> 3) & 0x07)
            let src = reg8Name(op & 0x07)
            return "LD \(dst),\(src)"
        }
        // 10xxxyyy — ALU A,r    (0x80-0xBF)
        if op & 0xC0 == 0x80 {
            let alu = aluName((op >> 3) & 0x07)
            let src = reg8Name(op & 0x07)
            return aluFormat(alu, src)
        }

        switch op {
        case 0x00: return "NOP"
        case 0x08: return "EX AF,AF'"
        case 0x10:
            let d = cursor.nextSignedByte()
            return "DJNZ \(relTarget(cursor: cursor, disp: d))"
        case 0x18:
            let d = cursor.nextSignedByte()
            return "JR \(relTarget(cursor: cursor, disp: d))"
        case 0x20, 0x28, 0x30, 0x38:
            let cc = ["NZ", "Z", "NC", "C"][Int((op >> 3) & 0x03)]
            let d = cursor.nextSignedByte()
            return "JR \(cc),\(relTarget(cursor: cursor, disp: d))"

        // LD rp,nn
        case 0x01: return "LD BC,\(hex(cursor.nextWord()))"
        case 0x11: return "LD DE,\(hex(cursor.nextWord()))"
        case 0x21: return "LD HL,\(hex(cursor.nextWord()))"
        case 0x31: return "LD SP,\(hex(cursor.nextWord()))"

        // LD (rp),A / LD A,(rp)
        case 0x02: return "LD (BC),A"
        case 0x0A: return "LD A,(BC)"
        case 0x12: return "LD (DE),A"
        case 0x1A: return "LD A,(DE)"

        // LD (nn),HL / LD HL,(nn) / LD (nn),A / LD A,(nn)
        case 0x22: return "LD (\(hex(cursor.nextWord()))),HL"
        case 0x2A: return "LD HL,(\(hex(cursor.nextWord())))"
        case 0x32: return "LD (\(hex(cursor.nextWord()))),A"
        case 0x3A: return "LD A,(\(hex(cursor.nextWord())))"

        // INC/DEC rp
        case 0x03: return "INC BC"
        case 0x13: return "INC DE"
        case 0x23: return "INC HL"
        case 0x33: return "INC SP"
        case 0x0B: return "DEC BC"
        case 0x1B: return "DEC DE"
        case 0x2B: return "DEC HL"
        case 0x3B: return "DEC SP"

        // INC/DEC r
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
            return "INC \(reg8Name((op >> 3) & 0x07))"
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
            return "DEC \(reg8Name((op >> 3) & 0x07))"

        // LD r,n
        case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E:
            let dst = reg8Name((op >> 3) & 0x07)
            return "LD \(dst),\(hex(cursor.next()))"

        // ADD HL,rp
        case 0x09: return "ADD HL,BC"
        case 0x19: return "ADD HL,DE"
        case 0x29: return "ADD HL,HL"
        case 0x39: return "ADD HL,SP"

        case 0x07: return "RLCA"
        case 0x0F: return "RRCA"
        case 0x17: return "RLA"
        case 0x1F: return "RRA"
        case 0x27: return "DAA"
        case 0x2F: return "CPL"
        case 0x37: return "SCF"
        case 0x3F: return "CCF"

        // RET cc / RET / POP rp / PUSH rp / CALL / JP
        case 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8:
            return "RET \(conditionName((op >> 3) & 0x07))"
        case 0xC9: return "RET"
        case 0xD9: return "EXX"
        case 0xC1: return "POP BC"
        case 0xD1: return "POP DE"
        case 0xE1: return "POP HL"
        case 0xF1: return "POP AF"
        case 0xC5: return "PUSH BC"
        case 0xD5: return "PUSH DE"
        case 0xE5: return "PUSH HL"
        case 0xF5: return "PUSH AF"

        case 0xC3: return "JP \(hex(cursor.nextWord()))"
        case 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA:
            let cc = conditionName((op >> 3) & 0x07)
            return "JP \(cc),\(hex(cursor.nextWord()))"
        case 0xCD: return "CALL \(hex(cursor.nextWord()))"
        case 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC:
            let cc = conditionName((op >> 3) & 0x07)
            return "CALL \(cc),\(hex(cursor.nextWord()))"

        case 0xE9: return "JP (HL)"
        case 0xF9: return "LD SP,HL"
        case 0xEB: return "EX DE,HL"
        case 0xE3: return "EX (SP),HL"
        case 0xF3: return "DI"
        case 0xFB: return "EI"

        // ALU n
        case 0xC6: return "ADD A,\(hex(cursor.next()))"
        case 0xCE: return "ADC A,\(hex(cursor.next()))"
        case 0xD6: return "SUB \(hex(cursor.next()))"
        case 0xDE: return "SBC A,\(hex(cursor.next()))"
        case 0xE6: return "AND \(hex(cursor.next()))"
        case 0xEE: return "XOR \(hex(cursor.next()))"
        case 0xF6: return "OR \(hex(cursor.next()))"
        case 0xFE: return "CP \(hex(cursor.next()))"

        // IN/OUT (n),A
        case 0xD3: return "OUT (\(hex(cursor.next()))),A"
        case 0xDB: return "IN A,(\(hex(cursor.next())))"

        // RST
        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:
            return String(format: "RST %02XH", op & 0x38)

        default:
            return String(format: "DB %02XH", op)
        }
    }

    // MARK: - CB prefix

    private static func decodeCB(cursor: inout Cursor, indexPrefix: IndexPrefix?) -> String {
        // DD CB d xx / FD CB d xx — displacement first, then opcode
        let displacement: Int8?
        if indexPrefix != nil {
            displacement = cursor.nextSignedByte()
        } else {
            displacement = nil
        }
        let op = cursor.next()

        let operation = (op >> 6) & 0x03
        let bitOrType = (op >> 3) & 0x07
        let reg = op & 0x07

        let target: String
        if let prefix = indexPrefix, let d = displacement {
            target = indexed(prefix, displacement: d)
        } else {
            target = reg8Name(reg)
        }

        switch operation {
        case 0:
            let rot = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL"][Int(bitOrType)]
            return "\(rot) \(target)"
        case 1: return "BIT \(bitOrType),\(target)"
        case 2: return "RES \(bitOrType),\(target)"
        case 3: return "SET \(bitOrType),\(target)"
        default: return String(format: "DB CB %02XH", op)
        }
    }

    // MARK: - ED prefix

    private static func decodeED(cursor: inout Cursor) -> String {
        let op = cursor.next()
        switch op {
        case 0x40: return "IN B,(C)"
        case 0x48: return "IN C,(C)"
        case 0x50: return "IN D,(C)"
        case 0x58: return "IN E,(C)"
        case 0x60: return "IN H,(C)"
        case 0x68: return "IN L,(C)"
        case 0x70: return "IN (C)"
        case 0x78: return "IN A,(C)"
        case 0x41: return "OUT (C),B"
        case 0x49: return "OUT (C),C"
        case 0x51: return "OUT (C),D"
        case 0x59: return "OUT (C),E"
        case 0x61: return "OUT (C),H"
        case 0x69: return "OUT (C),L"
        case 0x71: return "OUT (C),0"
        case 0x79: return "OUT (C),A"

        case 0x42: return "SBC HL,BC"
        case 0x52: return "SBC HL,DE"
        case 0x62: return "SBC HL,HL"
        case 0x72: return "SBC HL,SP"
        case 0x4A: return "ADC HL,BC"
        case 0x5A: return "ADC HL,DE"
        case 0x6A: return "ADC HL,HL"
        case 0x7A: return "ADC HL,SP"

        case 0x43: return "LD (\(hex(cursor.nextWord()))),BC"
        case 0x53: return "LD (\(hex(cursor.nextWord()))),DE"
        case 0x63: return "LD (\(hex(cursor.nextWord()))),HL"
        case 0x73: return "LD (\(hex(cursor.nextWord()))),SP"
        case 0x4B: return "LD BC,(\(hex(cursor.nextWord())))"
        case 0x5B: return "LD DE,(\(hex(cursor.nextWord())))"
        case 0x6B: return "LD HL,(\(hex(cursor.nextWord())))"
        case 0x7B: return "LD SP,(\(hex(cursor.nextWord())))"

        case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C: return "NEG"
        case 0x45, 0x55, 0x65, 0x75: return "RETN"
        case 0x4D, 0x5D, 0x6D, 0x7D: return "RETI"

        case 0x46, 0x4E, 0x66, 0x6E: return "IM 0"
        case 0x56, 0x76: return "IM 1"
        case 0x5E, 0x7E: return "IM 2"

        case 0x47: return "LD I,A"
        case 0x4F: return "LD R,A"
        case 0x57: return "LD A,I"
        case 0x5F: return "LD A,R"
        case 0x67: return "RRD"
        case 0x6F: return "RLD"

        case 0xA0: return "LDI"
        case 0xA1: return "CPI"
        case 0xA2: return "INI"
        case 0xA3: return "OUTI"
        case 0xA8: return "LDD"
        case 0xA9: return "CPD"
        case 0xAA: return "IND"
        case 0xAB: return "OUTD"
        case 0xB0: return "LDIR"
        case 0xB1: return "CPIR"
        case 0xB2: return "INIR"
        case 0xB3: return "OTIR"
        case 0xB8: return "LDDR"
        case 0xB9: return "CPDR"
        case 0xBA: return "INDR"
        case 0xBB: return "OTDR"

        default:
            return String(format: "DB ED %02XH", op)
        }
    }

    // MARK: - DD / FD prefix

    private enum IndexPrefix {
        case ix, iy
        var nameHL: String { self == .ix ? "IX" : "IY" }
    }

    private static func decodeIndex(cursor: inout Cursor, prefix: IndexPrefix) -> String {
        let op = cursor.next()
        if op == 0xCB {
            return decodeCB(cursor: &cursor, indexPrefix: prefix)
        }

        switch op {
        case 0x21: return "LD \(prefix.nameHL),\(hex(cursor.nextWord()))"
        case 0x22: return "LD (\(hex(cursor.nextWord()))),\(prefix.nameHL)"
        case 0x2A: return "LD \(prefix.nameHL),(\(hex(cursor.nextWord())))"
        case 0x23: return "INC \(prefix.nameHL)"
        case 0x2B: return "DEC \(prefix.nameHL)"
        case 0x09: return "ADD \(prefix.nameHL),BC"
        case 0x19: return "ADD \(prefix.nameHL),DE"
        case 0x29: return "ADD \(prefix.nameHL),\(prefix.nameHL)"
        case 0x39: return "ADD \(prefix.nameHL),SP"
        case 0xE1: return "POP \(prefix.nameHL)"
        case 0xE5: return "PUSH \(prefix.nameHL)"
        case 0xE9: return "JP (\(prefix.nameHL))"
        case 0xF9: return "LD SP,\(prefix.nameHL)"
        case 0xE3: return "EX (SP),\(prefix.nameHL)"

        case 0x34:
            let d = cursor.nextSignedByte()
            return "INC \(indexed(prefix, displacement: d))"
        case 0x35:
            let d = cursor.nextSignedByte()
            return "DEC \(indexed(prefix, displacement: d))"
        case 0x36:
            let d = cursor.nextSignedByte()
            let n = cursor.next()
            return "LD \(indexed(prefix, displacement: d)),\(hex(n))"

        default:
            // Unsupported IX/IY sub-form — tag and fall through by
            // decoding the base instruction so instruction length
            // stays correct.
            let base = decodeUnprefixed(op: op, cursor: &cursor)
            return "[\(prefix.nameHL)] \(base)"
        }
    }

    // MARK: - Helpers

    private static func reg8Name(_ bits: UInt8) -> String {
        switch bits & 0x07 {
        case 0: return "B"
        case 1: return "C"
        case 2: return "D"
        case 3: return "E"
        case 4: return "H"
        case 5: return "L"
        case 6: return "(HL)"
        case 7: return "A"
        default: return "?"
        }
    }

    private static func conditionName(_ bits: UInt8) -> String {
        ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"][Int(bits & 0x07)]
    }

    private static func aluName(_ bits: UInt8) -> String {
        ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"][Int(bits & 0x07)]
    }

    private static func aluFormat(_ alu: String, _ src: String) -> String {
        switch alu {
        case "ADD", "ADC", "SBC": return "\(alu) A,\(src)"
        default: return "\(alu) \(src)"
        }
    }

    private static func indexed(_ prefix: IndexPrefix, displacement d: Int8) -> String {
        let sign = d < 0 ? "-" : "+"
        let mag = Int(d.magnitude)
        return String(format: "(\(prefix.nameHL)\(sign)%02XH)", mag)
    }

    private static func relTarget(cursor: Cursor, disp: Int8) -> String {
        let next = cursor.origin &+ UInt16(cursor.position)
        let target = UInt16(truncatingIfNeeded: Int(next) &+ Int(disp))
        return hex(target)
    }

    private static func hex(_ v: UInt16) -> String {
        String(format: "%04XH", v)
    }

    private static func hex(_ v: UInt8) -> String {
        String(format: "%02XH", v)
    }
}
