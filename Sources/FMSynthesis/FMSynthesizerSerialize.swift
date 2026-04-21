// MARK: - FMSynthesizer Save State Serialization
//
// This file must live in the FMSynthesis module to access internal types
// (FMOp, FMCh, RhythmChannel) and internal properties.

import Foundation

// MARK: - SaveState Writer/Reader (minimal subset for FMSynthesis module)

// Re-declare the minimal interface needed. The actual SaveState types are in EmulatorCore,
// but we cannot import EmulatorCore from FMSynthesis (circular dependency).
// Instead, FMSynthesizer serializes to/from raw byte arrays.

extension FMSynthesizer {

    // MARK: - FMOp serialization

    private static func writeFMOp(_ op: FMOp, to buf: inout [UInt8]) {
        appendUInt32(&buf, op.pgCount)
        appendUInt32(&buf, op.pgDiff)
        appendUInt32(&buf, op.pgDiffLfo)
        appendUInt32(&buf, op.dp)
        appendUInt32(&buf, op.bn)
        appendUInt32(&buf, op.detune)
        appendUInt32(&buf, op.detune2)
        appendUInt32(&buf, op.multiple)
        appendInt64(&buf, Int64(op.egLevel))
        appendInt64(&buf, Int64(op.egLevelOnNextPhase))
        appendInt64(&buf, Int64(op.egCount))
        appendInt64(&buf, Int64(op.egCountDiff))
        appendInt64(&buf, Int64(op.egOut))
        appendInt64(&buf, Int64(op.tlOut))
        appendInt64(&buf, Int64(op.egRate))
        appendInt64(&buf, Int64(op.egCurveCount))
        buf.append(UInt8(op.egPhase.rawValue))
        appendInt64(&buf, Int64(op.ssgOffset))
        appendInt64(&buf, Int64(op.ssgVector))
        appendInt64(&buf, Int64(op.ssgPhase))
        appendUInt32(&buf, op.ssgType)
        appendUInt32(&buf, op.keyScaleRate)
        appendUInt32(&buf, op.tl)
        appendUInt32(&buf, op.tlLatch)
        appendUInt32(&buf, op.ks)
        appendUInt32(&buf, op.ar)
        appendUInt32(&buf, op.dr)
        appendUInt32(&buf, op.sr)
        appendUInt32(&buf, op.sl)
        appendUInt32(&buf, op.rr)
        appendInt64(&buf, Int64(op.out))
        appendInt64(&buf, Int64(op.out2))
        buf.append(op.keyOn ? 1 : 0)
        buf.append(op.amon ? 1 : 0)
        appendUInt32(&buf, op.ms)
        appendInt64(&buf, Int64(op.amsIndex))
        buf.append(op.paramChanged ? 1 : 0)
    }

    private static func readFMOp(_ data: [UInt8], at pos: inout Int) -> FMOp {
        var op = FMOp()
        op.pgCount = readU32(data, at: &pos)
        op.pgDiff = readU32(data, at: &pos)
        op.pgDiffLfo = readU32(data, at: &pos)
        op.dp = readU32(data, at: &pos)
        op.bn = readU32(data, at: &pos)
        op.detune = readU32(data, at: &pos)
        op.detune2 = readU32(data, at: &pos)
        op.multiple = readU32(data, at: &pos)
        op.egLevel = Int(readI64(data, at: &pos))
        op.egLevelOnNextPhase = Int(readI64(data, at: &pos))
        op.egCount = Int(readI64(data, at: &pos))
        op.egCountDiff = Int(readI64(data, at: &pos))
        op.egOut = Int(readI64(data, at: &pos))
        op.tlOut = Int(readI64(data, at: &pos))
        op.egRate = Int(readI64(data, at: &pos))
        op.egCurveCount = Int(readI64(data, at: &pos))
        let egRaw = data[pos]; pos += 1
        op.egPhase = FMOp.EGPhase(rawValue: Int(egRaw)) ?? .off
        op.ssgOffset = Int(readI64(data, at: &pos))
        op.ssgVector = Int(readI64(data, at: &pos))
        op.ssgPhase = Int(readI64(data, at: &pos))
        op.ssgType = readU32(data, at: &pos)
        op.keyScaleRate = readU32(data, at: &pos)
        op.tl = readU32(data, at: &pos)
        op.tlLatch = readU32(data, at: &pos)
        op.ks = readU32(data, at: &pos)
        op.ar = readU32(data, at: &pos)
        op.dr = readU32(data, at: &pos)
        op.sr = readU32(data, at: &pos)
        op.sl = readU32(data, at: &pos)
        op.rr = readU32(data, at: &pos)
        op.out = Int(readI64(data, at: &pos))
        op.out2 = Int(readI64(data, at: &pos))
        op.keyOn = data[pos] != 0; pos += 1
        op.amon = data[pos] != 0; pos += 1
        op.ms = readU32(data, at: &pos)
        op.amsIndex = Int(readI64(data, at: &pos))
        op.paramChanged = data[pos] != 0; pos += 1
        return op
    }

    // MARK: - FMCh serialization

    private static func writeFMCh(_ ch: FMCh, to buf: inout [UInt8]) {
        for i in 0..<4 { writeFMOp(ch.op[i], to: &buf) }
        buf.append(ch.fb)
        appendInt64(&buf, Int64(ch.algo))
        buf.append(ch.panLeft ? 1 : 0)
        buf.append(ch.panRight ? 1 : 0)
        appendInt64(&buf, Int64(ch.pmsIndex))
    }

    private static func readFMCh(_ data: [UInt8], at pos: inout Int) -> FMCh {
        var ch = FMCh()
        for i in 0..<4 { ch.op[i] = readFMOp(data, at: &pos) }
        ch.fb = data[pos]; pos += 1
        ch.algo = Int(readI64(data, at: &pos))
        ch.panLeft = data[pos] != 0; pos += 1
        ch.panRight = data[pos] != 0; pos += 1
        ch.pmsIndex = Int(readI64(data, at: &pos))
        return ch
    }

    // MARK: - RhythmChannel serialization

    private static func writeRhythmChannel(_ rc: RhythmChannel, to buf: inout [UInt8]) {
        appendInt64(&buf, Int64(rc.size))
        appendInt64(&buf, Int64(rc.pos))
        appendInt64(&buf, Int64(rc.step))
        buf.append(rc.pan)
        buf.append(UInt8(bitPattern: rc.level))
        appendInt64(&buf, Int64(rc.volumeL))
        appendInt64(&buf, Int64(rc.volumeR))
    }

    private static func readRhythmChannel(_ data: [UInt8], at pos: inout Int, existing: RhythmChannel) -> RhythmChannel {
        var rc = existing
        rc.size = Int(readI64(data, at: &pos))
        rc.pos = Int(readI64(data, at: &pos))
        rc.step = Int(readI64(data, at: &pos))
        rc.pan = data[pos]; pos += 1
        rc.level = Int8(bitPattern: data[pos]); pos += 1
        rc.volumeL = Int(readI64(data, at: &pos))
        rc.volumeR = Int(readI64(data, at: &pos))
        return rc
    }

    // MARK: - Public serialize/deserialize

    /// Serialize all FMSynthesizer state to a byte array.
    public func serializeState() -> [UInt8] {
        var buf: [UInt8] = []
        buf.reserveCapacity(8192)

        // 6 channels
        for i in 0..<6 { Self.writeFMCh(ch[i], to: &buf) }

        // Chip state
        Self.appendUInt32(&buf, ratio)
        for h in 0..<4 {
            for l in 0..<16 {
                Self.appendUInt32(&buf, multable[h][l])
            }
        }

        // LFO
        Self.appendUInt32(&buf, lfoCount)
        Self.appendUInt32(&buf, lfoDCount)
        buf.append(lfoEnabled ? 1 : 0)

        // Rhythm (6 channels)
        for i in 0..<6 { Self.writeRhythmChannel(rhythm[i], to: &buf) }
        buf.append(UInt8(bitPattern: rhythmTL))
        Self.appendInt64(&buf, Int64(rhythmVolL))
        Self.appendInt64(&buf, Int64(rhythmVolR))
        buf.append(rhythmKey)
        buf.append(extendedChannelsEnabled ? 1 : 0)

        // Output rate
        Self.appendInt64(&buf, Int64(chipClock))
        Self.appendInt64(&buf, Int64(outputRate))

        return buf
    }

    /// Deserialize FMSynthesizer state from a byte array.
    /// Returns true on success.
    @discardableResult
    public func deserializeState(_ data: [UInt8]) -> Bool {
        var pos = 0

        guard data.count >= 32 else { return false }

        // 6 channels
        for i in 0..<6 { ch[i] = Self.readFMCh(data, at: &pos) }

        // Chip state
        ratio = Self.readU32(data, at: &pos)
        for h in 0..<4 {
            for l in 0..<16 {
                multable[h][l] = Self.readU32(data, at: &pos)
            }
        }

        // LFO
        lfoCount = Self.readU32(data, at: &pos)
        lfoDCount = Self.readU32(data, at: &pos)
        lfoEnabled = data[pos] != 0; pos += 1

        // Rhythm
        for i in 0..<6 { rhythm[i] = Self.readRhythmChannel(data, at: &pos, existing: rhythm[i]) }
        rhythmTL = Int8(bitPattern: data[pos]); pos += 1
        rhythmVolL = Int(Self.readI64(data, at: &pos))
        rhythmVolR = Int(Self.readI64(data, at: &pos))
        rhythmKey = data[pos]; pos += 1
        extendedChannelsEnabled = data[pos] != 0; pos += 1

        // Output rate
        chipClock = Int(Self.readI64(data, at: &pos))
        outputRate = Int(Self.readI64(data, at: &pos))

        return true
    }

    // MARK: - Binary helpers

    private static func appendUInt32(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8(v >> 24))
    }

    private static func appendInt32(_ buf: inout [UInt8], _ v: Int32) {
        appendUInt32(&buf, UInt32(bitPattern: v))
    }

    private static func appendUInt64(_ buf: inout [UInt8], _ v: UInt64) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
        buf.append(UInt8((v >> 32) & 0xFF))
        buf.append(UInt8((v >> 40) & 0xFF))
        buf.append(UInt8((v >> 48) & 0xFF))
        buf.append(UInt8(v >> 56))
    }

    private static func appendInt64(_ buf: inout [UInt8], _ v: Int64) {
        appendUInt64(&buf, UInt64(bitPattern: v))
    }

    private static func readU32(_ data: [UInt8], at pos: inout Int) -> UInt32 {
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    private static func readI32(_ data: [UInt8], at pos: inout Int) -> Int32 {
        Int32(bitPattern: readU32(data, at: &pos))
    }

    private static func readU64(_ data: [UInt8], at pos: inout Int) -> UInt64 {
        let v = UInt64(data[pos])
            | (UInt64(data[pos + 1]) << 8)
            | (UInt64(data[pos + 2]) << 16)
            | (UInt64(data[pos + 3]) << 24)
            | (UInt64(data[pos + 4]) << 32)
            | (UInt64(data[pos + 5]) << 40)
            | (UInt64(data[pos + 6]) << 48)
            | (UInt64(data[pos + 7]) << 56)
        pos += 8
        return v
    }

    private static func readI64(_ data: [UInt8], at pos: inout Int) -> Int64 {
        Int64(bitPattern: readU64(data, at: &pos))
    }
}
