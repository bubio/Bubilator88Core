import Foundation

/// A single entry in the instruction trace ring buffer.
///
/// Captured by `Machine.debugRun` immediately before each CPU
/// instruction executes, so the PC / register state reflects what
/// *led into* that opcode rather than the result afterwards.
///
/// The opcode itself is **not** stored: capturing it would require a
/// memory read at PC, which would spuriously trip any memory-read
/// breakpoint the user had set. The trace viewer disassembles lazily
/// from the live bus (via a snapshot) when rendering.
///
/// Both main and sub CPU traces share this type. Sub-CPU entries
/// still populate IX/IY/AF'/etc. even though PC-8801 software rarely
/// uses them on the sub side, so diffing across two adjacent rows
/// doesn't need to special-case sub vs main.
public struct InstructionTraceEntry: Sendable, Hashable {
    public let pc: UInt16
    public let af: UInt16
    public let bc: UInt16
    public let de: UInt16
    public let hl: UInt16
    public let ix: UInt16
    public let iy: UInt16
    public let sp: UInt16
    public let af2: UInt16
    public let bc2: UInt16
    public let de2: UInt16
    public let hl2: UInt16
    public let i: UInt8
    public let r: UInt8

    public init(
        pc: UInt16,
        af: UInt16,
        bc: UInt16,
        de: UInt16,
        hl: UInt16,
        ix: UInt16 = 0,
        iy: UInt16 = 0,
        sp: UInt16,
        af2: UInt16 = 0,
        bc2: UInt16 = 0,
        de2: UInt16 = 0,
        hl2: UInt16 = 0,
        i: UInt8 = 0,
        r: UInt8 = 0
    ) {
        self.pc = pc
        self.af = af
        self.bc = bc
        self.de = de
        self.hl = hl
        self.ix = ix
        self.iy = iy
        self.sp = sp
        self.af2 = af2
        self.bc2 = bc2
        self.de2 = de2
        self.hl2 = hl2
        self.i = i
        self.r = r
    }
}
