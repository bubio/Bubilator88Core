#if canImport(Foundation)
import Foundation
#endif

/// Cassette tape playback deck (CMT).
///
/// Holds the linear byte stream of a loaded tape image and pumps one byte
/// at a time into the attached I8251 receiver while the motor is on and
/// the USART is routed to CMT. T88 and raw CMT are both supported; T88 is
/// detected by the `"PC-8801 Tape Image(T88)"` signature.
///
/// Timing: one byte per `bytePeriodTStates` T-states (default 5000, matches
/// BubiC-8801MA behavior — roughly 1.7× real 1200 bps). DCD is asserted as
/// long as there is remaining data and the drive is engaged; we do not
/// model the brief carrier gaps between header and body blocks.
public final class CassetteDeck {

    public static let t88Signature: [UInt8] = Array("PC-8801 Tape Image(T88)".utf8)

    public var bytePeriodTStates: Int = 5000

    /// T-states that must elapse after the motor engages before the first
    /// byte is injected into the USART. Real hardware needs a sync-run
    /// delay before data starts arriving, and BASIC's `LOAD "NAME"`
    /// handler depends on this gap to set up its receive loop. BubiC uses
    /// 1,000,000 cycles (~125 ms @ 8MHz); without the delay, the first
    /// bytes arrive before BASIC is ready and the sync-pattern scan never
    /// catches on — LOAD appears to hang indefinitely.
    public var primeDelayTStates: Int = 1_000_000

    public private(set) var buffer: [UInt8] = []
    public private(set) var bufPtr: Int = 0
    /// Positions in `buffer` where a data carrier starts. T88 sources
    /// populate this from tag 0x0102/0x0103; raw CMT sources scan for
    /// sync patterns after load.
    public private(set) var dataCarriers: [Int] = []
    /// O(1) lookup mirror of `dataCarriers` for the hot path in `tick()`.
    private var dataCarrierSet: Set<Int> = []

    public var motorOn: Bool = false {
        didSet {
            if !motorOn {
                tickAccum = 0
                phase = .carrierPrime
            }
        }
    }
    public var cmtSelected: Bool = false

    /// Playback state machine. BubiC `EVENT_CMT_SEND` / `EVENT_CMT_DCD`:
    /// each carrier boundary asserts DCD=high for `primeDelayTStates`,
    /// then streaming asserts DCD=low between bytes, and tape exhaustion
    /// parks DCD=high (Jackie-Chan-no-Spartan-X compatibility note in
    /// BubiC pc88.cpp:2726).
    private enum Phase { case carrierPrime, streaming, exhausted }
    private var phase: Phase = .carrierPrime

    /// True when a tape image has been loaded (buffer is non-empty).
    public var isLoaded: Bool { !buffer.isEmpty }

    /// Playback position as 0.0–1.0 (0 when no tape is loaded).
    public var progress: Double {
        buffer.isEmpty ? 0 : Double(bufPtr) / Double(buffer.count)
    }

    private weak var usart: I8251?
    private var tickAccum: Int = 0

    public init(usart: I8251? = nil) {
        self.usart = usart
    }

    public func attach(usart: I8251) {
        self.usart = usart
    }

    // MARK: - Loading

    public enum Format { case t88, cmt }

    @discardableResult
    public func load(data: Data) -> Format {
        if isT88(data) {
            loadT88(data: data)
            return .t88
        } else {
            loadCMT(data: data)
            return .cmt
        }
    }

    public func loadT88(data: Data) {
        buffer.removeAll(keepingCapacity: false)
        dataCarriers.removeAll(keepingCapacity: false)
        bufPtr = 0
        tickAccum = 0
        phase = .carrierPrime

        // Signature is 23 bytes of ASCII followed by 0x1A; skip 24.
        var p = 24
        let bytes = Array(data)
        while p + 4 <= bytes.count {
            let tag = UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8)
            let len = Int(UInt16(bytes[p + 2]) | (UInt16(bytes[p + 3]) << 8))
            p += 4
            if tag == 0x0000 { break }
            let payloadEnd = p + len
            if payloadEnd > bytes.count { break }
            switch tag {
            case 0x0101:
                // First 12 bytes of payload are meta (length, position,
                // flags in the T88 spec); skip them and append the rest.
                if len > 12 {
                    buffer.append(contentsOf: bytes[(p + 12)..<payloadEnd])
                }
            case 0x0102, 0x0103:
                // Data carrier marker — records the start of the next
                // data block in the output buffer.
                dataCarriers.append(buffer.count)
            default:
                break
            }
            p = payloadEnd
        }
        dataCarrierSet = Set(dataCarriers)
    }

    public func loadCMT(data: Data) {
        buffer = Array(data)
        dataCarriers = CassetteDeck.scanCarriers(buffer)
        dataCarrierSet = Set(dataCarriers)
        bufPtr = 0
        tickAccum = 0
        phase = .carrierPrime
    }

    /// Rewind tape to the beginning without unloading.
    public func rewindToStart() {
        bufPtr = 0
        tickAccum = 0
        phase = .carrierPrime
    }

    /// Eject / unload.
    public func eject() {
        buffer.removeAll(keepingCapacity: false)
        dataCarriers.removeAll(keepingCapacity: false)
        dataCarrierSet.removeAll()
        bufPtr = 0
        tickAccum = 0
        phase = .carrierPrime
        motorOn = false
    }

    private func isT88(_ data: Data) -> Bool {
        guard data.count >= CassetteDeck.t88Signature.count else { return false }
        for (i, b) in CassetteDeck.t88Signature.enumerated() {
            if data[data.startIndex.advanced(by: i)] != b { return false }
        }
        return true
    }

    // MARK: - Data carrier scan

    /// Scans a CMT raw stream for sync runs (`0xD3` × ≥10 for BASIC
    /// headers, `0x9C` × ≥6 for machine-language headers) and returns the
    /// byte offsets at which each run begins.
    public static func scanCarriers(_ bytes: [UInt8]) -> [Int] {
        var result: [Int] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0xD3 || b == 0x9C {
                var j = i
                while j < bytes.count && bytes[j] == b { j += 1 }
                let runLen = j - i
                let threshold = (b == 0xD3) ? 10 : 6
                if runLen >= threshold {
                    result.append(i)
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Time progression

    /// Pumps bytes into the USART. Called from the main loop with the
    /// T-states elapsed since the previous call. Does nothing when the
    /// motor is off, CMT is not the selected USART channel, or the tape
    /// is exhausted.
    public func tick(tStates: Int) {
        guard motorOn, cmtSelected, let usart = usart else { return }
        tickAccum += tStates
        while true {
            switch phase {
            case .carrierPrime:
                // DCD is high during the carrier-detect window; wait it
                // out so BASIC's LOAD handler has time to set up its
                // receive loop before the first byte arrives.
                if tickAccum < primeDelayTStates { return }
                tickAccum -= primeDelayTStates
                phase = .streaming
            case .streaming:
                if tickAccum < bytePeriodTStates { return }
                // Back-pressure: don't send the next byte until the CPU
                // has consumed the previous one. Without this, bufPtr
                // races ahead of the CPU's actual reads and the
                // high-speed loader (readByte) starts at the wrong
                // position. QUASI88 only advances the tape when the CPU
                // explicitly calls sio_getc; this check approximates
                // that by pausing whenever RxRDY is still asserted.
                if usart.isRxReady {
                    // Cap to avoid burst-delivery when the CPU finally reads.
                    tickAccum = min(tickAccum, bytePeriodTStates)
                    return
                }
                tickAccum -= bytePeriodTStates
                guard bufPtr < buffer.count else {
                    phase = .exhausted
                    tickAccum = 0
                    return
                }
                usart.receiveByte(buffer[bufPtr])
                bufPtr += 1
                // Entering a new intra-tape data carrier returns to the
                // prime phase so BASIC sees DCD rise between blocks.
                if dataCarrierSet.contains(bufPtr) {
                    phase = .carrierPrime
                }
            case .exhausted:
                return
            }
        }
    }

    // MARK: - Direct byte consumption (Hudson high-speed loader)

    /// Set `bufPtr` to an absolute position. Used by the high-speed
    /// loader to backtrack after a failed header-checksum test so that
    /// the bytes consumed during the test don't mask a valid 0x3A that
    /// happened to be among them.
    public func seek(to position: Int) {
        bufPtr = max(0, min(position, buffer.count))
    }

    /// Consume and return the next byte from the tape buffer, advancing
    /// `bufPtr`. Returns `nil` if the tape is exhausted. Bypasses the
    /// USART / streaming phase machine — used by the QUASI88-compatible
    /// high-speed loader triggered from port 0x00 write, which reads
    /// bytes directly out of the tape as fast as Hudson's boot monitor
    /// asks for them.
    public func readByte() -> UInt8? {
        guard bufPtr < buffer.count else { return nil }
        let b = buffer[bufPtr]
        bufPtr += 1
        return b
    }

    // MARK: - Status surfaced on port 0x40 bit 2

    /// True when a data carrier is detected at the current playback
    /// position. Matches BubiC's `usart_dcd`: HIGH during carrier-detect
    /// windows (before the first byte of each block) and after tape
    /// exhaustion; LOW while bytes are actively streaming; LOW when the
    /// drive is idle.
    public var dcd: Bool {
        guard motorOn, cmtSelected else { return false }
        switch phase {
        case .carrierPrime: return true
        case .streaming:    return false
        case .exhausted:    return true  // BubiC pc88.cpp:2726
        }
    }

    // MARK: - Save state

    /// Serialize cassette deck state (including the full loaded buffer).
    /// Layout (little-endian):
    ///   version(u8)=1, motorOn(u8), cmtSelected(u8),
    ///   bytePeriodTStates(i64), bufPtr(i64), tickAccum(i64),
    ///   bufferLen(u32), buffer[bufferLen],
    ///   carrierCount(u32), carriers[carrierCount] (each i64).
    /// Serialize cassette deck state (including the full loaded buffer).
    /// Version 2 layout (little-endian):
    ///   version(u8)=2, motorOn(u8), cmtSelected(u8), phase(u8),
    ///   bytePeriodTStates(i64), primeDelayTStates(i64),
    ///   bufPtr(i64), tickAccum(i64),
    ///   bufferLen(u32), buffer[bufferLen],
    ///   carrierCount(u32), carriers[carrierCount] (each i64).
    public func serializeState() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(64 + buffer.count + dataCarriers.count * 8)
        out.append(2)  // version
        out.append(motorOn ? 1 : 0)
        out.append(cmtSelected ? 1 : 0)
        out.append(serializePhase())
        CassetteDeck.appendI64(&out, Int64(bytePeriodTStates))
        CassetteDeck.appendI64(&out, Int64(primeDelayTStates))
        CassetteDeck.appendI64(&out, Int64(bufPtr))
        CassetteDeck.appendI64(&out, Int64(tickAccum))
        CassetteDeck.appendU32(&out, UInt32(buffer.count))
        out.append(contentsOf: buffer)
        CassetteDeck.appendU32(&out, UInt32(dataCarriers.count))
        for c in dataCarriers { CassetteDeck.appendI64(&out, Int64(c)) }
        return out
    }

    public func deserializeState(_ data: [UInt8]) {
        let version = data.first ?? 0
        switch version {
        case 2:  deserializeV2(data)
        case 1:  deserializeV1(data)
        default: return
        }
    }

    private func deserializeV2(_ data: [UInt8]) {
        // version(1) + motor(1) + cmt(1) + phase(1) + 4×i64 + u32 = 40
        guard data.count >= 40 else { return }
        var p = 1
        // Set motorOn last to avoid didSet side effects during restore.
        let savedMotor = data[p] != 0; p += 1
        cmtSelected = data[p] != 0; p += 1
        phase = deserializePhase(data[p]); p += 1
        bytePeriodTStates = Int(CassetteDeck.readI64(data, at: &p))
        primeDelayTStates = Int(CassetteDeck.readI64(data, at: &p))
        let rawBufPtr = Int(CassetteDeck.readI64(data, at: &p))
        tickAccum = Int(CassetteDeck.readI64(data, at: &p))
        let bufLen = Int(CassetteDeck.readU32(data, at: &p))
        guard p + bufLen <= data.count else { return }
        buffer = Array(data[p..<(p + bufLen)])
        p += bufLen
        bufPtr = max(0, min(rawBufPtr, buffer.count))
        guard p + 4 <= data.count else { motorOn = savedMotor; return }
        let carrierCount = Int(CassetteDeck.readU32(data, at: &p))
        guard p + carrierCount * 8 <= data.count else { motorOn = savedMotor; return }
        var carriers: [Int] = []
        carriers.reserveCapacity(carrierCount)
        for _ in 0..<carrierCount {
            carriers.append(Int(CassetteDeck.readI64(data, at: &p)))
        }
        dataCarriers = carriers
        dataCarrierSet = Set(carriers)
        motorOn = savedMotor
    }

    private func deserializeV1(_ data: [UInt8]) {
        // v1: version(1) + motor(1) + cmt(1) + 3×i64 + u32 = 31
        guard data.count >= 31, data[0] == 1 else { return }
        var p = 1
        let savedMotor = data[p] != 0; p += 1
        cmtSelected = data[p] != 0; p += 1
        bytePeriodTStates = Int(CassetteDeck.readI64(data, at: &p))
        let rawBufPtr = Int(CassetteDeck.readI64(data, at: &p))
        tickAccum = Int(CassetteDeck.readI64(data, at: &p))
        phase = rawBufPtr > 0 ? .streaming : .carrierPrime
        let bufLen = Int(CassetteDeck.readU32(data, at: &p))
        guard p + bufLen <= data.count else { return }
        buffer = Array(data[p..<(p + bufLen)])
        p += bufLen
        bufPtr = max(0, min(rawBufPtr, buffer.count))
        guard p + 4 <= data.count else { motorOn = savedMotor; return }
        let carrierCount = Int(CassetteDeck.readU32(data, at: &p))
        guard p + carrierCount * 8 <= data.count else { motorOn = savedMotor; return }
        var carriers: [Int] = []
        carriers.reserveCapacity(carrierCount)
        for _ in 0..<carrierCount {
            carriers.append(Int(CassetteDeck.readI64(data, at: &p)))
        }
        dataCarriers = carriers
        dataCarrierSet = Set(carriers)
        motorOn = savedMotor
    }

    private func serializePhase() -> UInt8 {
        switch phase {
        case .carrierPrime: return 0
        case .streaming:    return 1
        case .exhausted:    return 2
        }
    }

    private func deserializePhase(_ v: UInt8) -> Phase {
        switch v {
        case 1:  return .streaming
        case 2:  return .exhausted
        default: return .carrierPrime
        }
    }

    private static func appendU32(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8(v >> 24))
    }

    private static func appendI64(_ buf: inout [UInt8], _ v: Int64) {
        let u = UInt64(bitPattern: v)
        for i in 0..<8 { buf.append(UInt8((u >> (8 * i)) & 0xFF)) }
    }

    private static func readU32(_ data: [UInt8], at pos: inout Int) -> UInt32 {
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    private static func readI64(_ data: [UInt8], at pos: inout Int) -> Int64 {
        var u: UInt64 = 0
        for i in 0..<8 { u |= UInt64(data[pos + i]) << (8 * i) }
        pos += 8
        return Int64(bitPattern: u)
    }
}
