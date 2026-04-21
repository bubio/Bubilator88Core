// MARK: - Peripherals Save State Serialization
//
// Serialization helpers for peripheral types that have private(set) properties
// which can only be set from within the Peripherals module.

import Foundation

// MARK: - UPD765A

extension UPD765A {

    /// Serialize all UPD765A state to a byte array.
    public func serializeState() -> [UInt8] {
        var buf: [UInt8] = []
        buf.reserveCapacity(1024)

        // Phase (enum -> UInt8)
        let phaseRaw: UInt8
        switch phase {
        case .idle: phaseRaw = 0
        case .command: phaseRaw = 1
        case .execution: phaseRaw = 2
        case .result: phaseRaw = 3
        }
        buf.append(phaseRaw)

        // Command (enum -> Int32)
        appendI64(&buf, Int64(command.rawValue))

        // Command bytes (variable-length)
        appendU32(&buf, UInt32(cmdBytes.count))
        buf.append(contentsOf: cmdBytes)
        appendI64(&buf, Int64(cmdBytesExpected))

        // Result bytes (variable-length)
        appendU32(&buf, UInt32(resultBytes.count))
        buf.append(contentsOf: resultBytes)
        appendI64(&buf, Int64(resultIndex))

        // Data buffer (variable-length)
        appendU32(&buf, UInt32(dataBuffer.count))
        buf.append(contentsOf: dataBuffer)
        appendI64(&buf, Int64(dataIndex))
        buf.append(readByteReady ? 1 : 0)
        appendI64(&buf, Int64(readByteWaitClocks))
        buf.append(writeByteReady ? 1 : 0)
        appendI64(&buf, Int64(writeByteWaitClocks))
        appendI64(&buf, Int64(dataBufferExpectedSize))

        // Command parameters
        buf.append(sk ? 1 : 0)
        buf.append(mf ? 1 : 0)
        buf.append(mt ? 1 : 0)
        appendI64(&buf, Int64(us))
        appendI64(&buf, Int64(hd))
        buf.append(chrn.c)
        buf.append(chrn.h)
        buf.append(chrn.r)
        buf.append(chrn.n)
        buf.append(eot)
        buf.append(gpl)
        buf.append(dtl)
        buf.append(sc)
        buf.append(fillByte)

        // Status registers
        buf.append(st0)
        buf.append(st1)
        buf.append(st2)
        buf.append(st3)

        // Per-drive state (4 drives, fixed)
        for i in 0..<4 { buf.append(pcn[i]) }
        for i in 0..<4 {
            let seekRaw: UInt8
            switch seekState[i] {
            case .stopped: seekRaw = 0
            case .moving: seekRaw = 1
            case .ended: seekRaw = 2
            case .interrupt: seekRaw = 3
            }
            buf.append(seekRaw)
        }
        for i in 0..<4 { buf.append(seekMoving[i] ? 1 : 0) }
        for i in 0..<4 { buf.append(seekTarget[i]) }
        for i in 0..<4 { appendI64(&buf, Int64(seekWait[i])) }

        // Specify parameters
        appendI64(&buf, Int64(srtClocks))
        appendI64(&buf, Int64(hutClocks))
        appendI64(&buf, Int64(hltClocks))
        buf.append(ndMode ? 1 : 0)

        // Terminal count & interrupt
        buf.append(tc ? 1 : 0)
        buf.append(interruptPending ? 1 : 0)

        // Format IDs (variable-length)
        appendU32(&buf, UInt32(formatIDs.count))
        for id in formatIDs {
            buf.append(id.c)
            buf.append(id.h)
            buf.append(id.r)
            buf.append(id.n)
        }
        appendI64(&buf, Int64(formatIDIndex))

        // Execution context
        appendI64(&buf, Int64(executionSectorSize))
        buf.append(executionStartR)
        buf.append(executionStartH)
        buf.append(executionMT ? 1 : 0)
        appendI64(&buf, Int64(executionHD))
        appendU32(&buf, UInt32(executionSectorSequence.count))
        for seq in executionSectorSequence {
            appendI64(&buf, Int64(seq.h))
            buf.append(seq.r)
        }
        buf.append(executionUsesLogicalSequence ? 1 : 0)

        return buf
    }

    /// Deserialize all UPD765A state from a byte array.
    @discardableResult
    public func deserializeState(_ data: [UInt8]) -> Bool {
        var pos = 0
        guard data.count >= 16 else { return false }

        // Phase
        let phaseRaw = data[pos]; pos += 1
        switch phaseRaw {
        case 0: phase = .idle
        case 1: phase = .command
        case 2: phase = .execution
        case 3: phase = .result
        default: phase = .idle
        }

        // Command
        let cmdRaw = Int(readI64(data, at: &pos))
        command = Command(rawValue: cmdRaw) ?? .invalid

        // Command bytes
        let cmdCount = Int(readU32(data, at: &pos))
        cmdBytes = Array(data[pos..<(pos + cmdCount)]); pos += cmdCount
        cmdBytesExpected = Int(readI64(data, at: &pos))

        // Result bytes
        let resCount = Int(readU32(data, at: &pos))
        resultBytes = Array(data[pos..<(pos + resCount)]); pos += resCount
        resultIndex = Int(readI64(data, at: &pos))

        // Data buffer
        let dataCount = Int(readU32(data, at: &pos))
        dataBuffer = Array(data[pos..<(pos + dataCount)]); pos += dataCount
        dataIndex = Int(readI64(data, at: &pos))
        readByteReady = data[pos] != 0; pos += 1
        readByteWaitClocks = Int(readI64(data, at: &pos))
        writeByteReady = data[pos] != 0; pos += 1
        writeByteWaitClocks = Int(readI64(data, at: &pos))
        dataBufferExpectedSize = Int(readI64(data, at: &pos))

        // Command parameters
        sk = data[pos] != 0; pos += 1
        mf = data[pos] != 0; pos += 1
        mt = data[pos] != 0; pos += 1
        us = Int(readI64(data, at: &pos))
        hd = Int(readI64(data, at: &pos))
        chrn.c = data[pos]; pos += 1
        chrn.h = data[pos]; pos += 1
        chrn.r = data[pos]; pos += 1
        chrn.n = data[pos]; pos += 1
        eot = data[pos]; pos += 1
        gpl = data[pos]; pos += 1
        dtl = data[pos]; pos += 1
        sc = data[pos]; pos += 1
        fillByte = data[pos]; pos += 1

        // Status registers
        st0 = data[pos]; pos += 1
        st1 = data[pos]; pos += 1
        st2 = data[pos]; pos += 1
        st3 = data[pos]; pos += 1

        // Per-drive state
        for i in 0..<4 { pcn[i] = data[pos]; pos += 1 }
        for i in 0..<4 {
            let seekRaw = data[pos]; pos += 1
            switch seekRaw {
            case 0: seekState[i] = .stopped
            case 1: seekState[i] = .moving
            case 2: seekState[i] = .ended
            case 3: seekState[i] = .interrupt
            default: seekState[i] = .stopped
            }
        }
        for i in 0..<4 { seekMoving[i] = data[pos] != 0; pos += 1 }
        for i in 0..<4 { seekTarget[i] = data[pos]; pos += 1 }
        for i in 0..<4 { seekWait[i] = Int(readI64(data, at: &pos)) }

        // Specify parameters
        srtClocks = Int(readI64(data, at: &pos))
        hutClocks = Int(readI64(data, at: &pos))
        hltClocks = Int(readI64(data, at: &pos))
        ndMode = data[pos] != 0; pos += 1

        // Terminal count & interrupt
        tc = data[pos] != 0; pos += 1
        interruptPending = data[pos] != 0; pos += 1

        // Format IDs
        let idCount = Int(readU32(data, at: &pos))
        formatIDs = []
        for _ in 0..<idCount {
            let c = data[pos]; pos += 1
            let h = data[pos]; pos += 1
            let rv = data[pos]; pos += 1
            let n = data[pos]; pos += 1
            formatIDs.append((c: c, h: h, r: rv, n: n))
        }
        formatIDIndex = Int(readI64(data, at: &pos))

        // Execution context
        executionSectorSize = Int(readI64(data, at: &pos))
        executionStartR = data[pos]; pos += 1
        executionStartH = data[pos]; pos += 1
        executionMT = data[pos] != 0; pos += 1
        executionHD = Int(readI64(data, at: &pos))
        let seqCount = Int(readU32(data, at: &pos))
        executionSectorSequence = []
        for _ in 0..<seqCount {
            let h = Int(readI64(data, at: &pos))
            let rv = data[pos]; pos += 1
            executionSectorSequence.append((h: h, r: rv))
        }
        executionUsesLogicalSequence = data[pos] != 0; pos += 1

        return true
    }

    // MARK: - Binary helpers

    private func appendU32(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8(v >> 24))
    }

    private func appendI32(_ buf: inout [UInt8], _ v: Int32) {
        appendU32(&buf, UInt32(bitPattern: v))
    }

    private func appendU64(_ buf: inout [UInt8], _ v: UInt64) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
        buf.append(UInt8((v >> 32) & 0xFF))
        buf.append(UInt8((v >> 40) & 0xFF))
        buf.append(UInt8((v >> 48) & 0xFF))
        buf.append(UInt8(v >> 56))
    }

    private func appendI64(_ buf: inout [UInt8], _ v: Int64) {
        appendU64(&buf, UInt64(bitPattern: v))
    }

    private func readU32(_ data: [UInt8], at pos: inout Int) -> UInt32 {
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    private func readI32(_ data: [UInt8], at pos: inout Int) -> Int32 {
        Int32(bitPattern: readU32(data, at: &pos))
    }

    private func readU64(_ data: [UInt8], at pos: inout Int) -> UInt64 {
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

    private func readI64(_ data: [UInt8], at pos: inout Int) -> Int64 {
        Int64(bitPattern: readU64(data, at: &pos))
    }
}
