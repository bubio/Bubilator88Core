import Testing
import Foundation
@testable import EmulatorCore

@Suite("CassetteDeck Tests")
struct CassetteDeckTests {

    private func makeT88(blocks: [(tag: UInt16, payload: [UInt8])]) -> Data {
        var out: [UInt8] = Array("PC-8801 Tape Image(T88)".utf8)
        out.append(0x1A)
        for (tag, payload) in blocks {
            out.append(UInt8(tag & 0xFF))
            out.append(UInt8((tag >> 8) & 0xFF))
            let len = UInt16(payload.count)
            out.append(UInt8(len & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(contentsOf: payload)
        }
        // EOF
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return Data(out)
    }

    @Test("Raw bytes without T88 signature load as CMT")
    func loadsRawAsCMT() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let fmt = d.load(data: Data(bytes))
        #expect(fmt == .cmt)
        #expect(d.buffer == bytes)
    }

    @Test("T88 signature dispatches to loadT88, strips 12-byte meta")
    func loadsT88WithMetaSkipped() {
        let meta: [UInt8] = Array(repeating: 0x55, count: 12)
        let body: [UInt8] = [0xAA, 0xBB, 0xCC]
        let data = makeT88(blocks: [(0x0101, meta + body)])
        let u = I8251()
        let d = CassetteDeck(usart: u)
        let fmt = d.load(data: data)
        #expect(fmt == .t88)
        #expect(d.buffer == body)
    }

    @Test("T88 data carrier tags record buffer positions")
    func t88DataCarriersRecorded() {
        let meta: [UInt8] = Array(repeating: 0x00, count: 12)
        let a: [UInt8] = Array(repeating: 0x11, count: 4)
        let b: [UInt8] = Array(repeating: 0x22, count: 4)
        let data = makeT88(blocks: [
            (0x0102, []),
            (0x0101, meta + a),
            (0x0103, []),
            (0x0101, meta + b),
        ])
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.load(data: data)
        #expect(d.dataCarriers == [0, 4])
        #expect(d.buffer == a + b)
    }

    @Test("Raw CMT scanner finds 0xD3 and 0x9C sync runs")
    func rawCarrierScan() {
        // 0xD3 run length 10 at offset 2, 0x9C run length 6 at offset 20.
        var bytes: [UInt8] = [0x00, 0x01]
        bytes.append(contentsOf: Array(repeating: 0xD3, count: 10))
        bytes.append(contentsOf: Array(repeating: 0x00, count: 8))
        bytes.append(contentsOf: Array(repeating: 0x9C, count: 6))
        let carriers = CassetteDeck.scanCarriers(bytes)
        #expect(carriers == [2, 20])
    }

    @Test("Short sync runs are ignored")
    func shortRunsIgnored() {
        let bytes: [UInt8] =
            Array(repeating: 0xD3, count: 9) +   // too short (<10)
            [0x00] +
            Array(repeating: 0x9C, count: 5)     // too short (<6)
        #expect(CassetteDeck.scanCarriers(bytes).isEmpty)
    }

    @Test("tick pumps one byte per bytePeriodTStates while running")
    func tickRunsUnderMotor() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 100
        d.primeDelayTStates = 0   // skip the BASIC warm-up delay
        d.load(data: Data([0xA1, 0xA2, 0xA3]))
        d.motorOn = true
        d.cmtSelected = true
        // With back-pressure, each byte must be consumed before the next
        // arrives. Pump first byte, consume it, then pump the second.
        d.tick(tStates: 100)
        #expect(d.bufPtr == 1)
        #expect(u.readData() == 0xA1)   // consume → clears RxRDY
        d.tick(tStates: 100)
        #expect(d.bufPtr == 2)
        #expect(u.readData() == 0xA2)
    }

    @Test("tick does nothing when motor is off")
    func tickIdleWhenMotorOff() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.load(data: Data([0xA1, 0xA2]))
        d.motorOn = false
        d.cmtSelected = true
        d.tick(tStates: 1_000)
        #expect(d.bufPtr == 0)
        #expect(!I8251.Status(rawValue: u.readStatus()).contains(.rxRDY))
    }

    @Test("tick does nothing when USART is routed to RS-232C")
    func tickIdleWhenCMTNotSelected() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.load(data: Data([0xA1]))
        d.motorOn = true
        d.cmtSelected = false
        d.tick(tStates: 1_000)
        #expect(d.bufPtr == 0)
    }

    @Test("dcd follows carrier-prime / streaming / exhausted phases")
    func dcdReflectsDriveState() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.load(data: Data([0x01, 0x02]))
        #expect(!d.dcd)                    // motor off
        d.motorOn = true
        #expect(!d.dcd)                    // still RS-232C selected
        d.cmtSelected = true
        #expect(d.dcd)                     // carrier-prime window is high
        d.bytePeriodTStates = 1
        d.primeDelayTStates = 0
        d.tick(tStates: 1)                 // pump first byte
        _ = u.readData()                   // consume → clear RxRDY
        d.tick(tStates: 1)                 // pump second byte
        _ = u.readData()                   // consume
        d.tick(tStates: 1)                 // detect exhaustion
        #expect(d.dcd)                     // exhausted also parks high (BubiC compat)
    }

    @Test("eject clears buffer and disengages motor")
    func ejectClearsState() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.load(data: Data([0x01, 0x02, 0x03]))
        d.motorOn = true
        d.cmtSelected = true
        d.eject()
        #expect(d.buffer.isEmpty)
        #expect(d.bufPtr == 0)
        #expect(!d.motorOn)
    }

    @Test("tick consumes entire buffer then stops cleanly")
    func tickDrainsAndStops() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.primeDelayTStates = 0
        d.load(data: Data([0xA1, 0xA2, 0xA3]))
        d.motorOn = true
        d.cmtSelected = true
        // Drain all 3 bytes with back-pressure: pump → consume → pump...
        for _ in 0..<3 {
            d.tick(tStates: 10)
            _ = u.readData()
        }
        d.tick(tStates: 10)  // detect exhaustion
        #expect(d.bufPtr == 3)
        #expect(d.dcd)       // exhausted parks DCD high (BubiC pc88.cpp:2726)
        d.tick(tStates: 100) // further ticks are no-op
        #expect(d.bufPtr == 3)
    }

    @Test("Motor toggle resets tickAccum so resume doesn't burst-send")
    func motorOffResetsAccumulator() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 100
        d.primeDelayTStates = 0
        d.load(data: Data([0x01, 0x02, 0x03]))
        d.motorOn = true
        d.cmtSelected = true
        d.tick(tStates: 99)   // just short of first byte
        #expect(d.bufPtr == 0)
        d.motorOn = false     // pause (clears accumulator per didSet)
        d.motorOn = true      // resume
        d.tick(tStates: 99)
        #expect(d.bufPtr == 0)   // still no byte
        d.tick(tStates: 2)
        #expect(d.bufPtr == 1)   // now the first byte flows
    }

    @Test("Prime delay holds off first byte until it elapses")
    func primeDelayHoldsFirstByte() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.primeDelayTStates = 200
        d.load(data: Data([0xA1, 0xA2]))
        d.motorOn = true
        d.cmtSelected = true
        d.tick(tStates: 199)
        #expect(d.bufPtr == 0)        // still in prime-delay window
        d.tick(tStates: 11)           // now 210 elapsed: delay + 1 period
        #expect(d.bufPtr == 1)        // first byte injected
    }

    @Test("T88 loader stops at EOF tag and ignores trailing bytes")
    func t88StopsAtEOF() {
        let meta: [UInt8] = Array(repeating: 0x00, count: 12)
        let payload: [UInt8] = [0x11, 0x22]
        var data = makeT88(blocks: [(0x0101, meta + payload)])
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.load(data: data)
        #expect(d.buffer == payload)
    }

    @Test("load() replaces any previously-loaded tape")
    func reloadReplacesState() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.primeDelayTStates = 0
        d.load(data: Data([0x11, 0x22, 0x33]))
        d.motorOn = true
        d.cmtSelected = true
        d.tick(tStates: 10)
        _ = u.readData()  // consume first byte → allow second
        d.tick(tStates: 10)
        #expect(d.bufPtr == 2)
        d.load(data: Data([0xAA, 0xBB]))
        #expect(d.buffer == [0xAA, 0xBB])
        #expect(d.bufPtr == 0)
    }

    @Test("readByte returns bytes sequentially and nil at end")
    func readByteDrainsBuffer() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.load(data: Data([0x11, 0x22, 0x33]))
        #expect(d.readByte() == 0x11)
        #expect(d.readByte() == 0x22)
        #expect(d.readByte() == 0x33)
        #expect(d.readByte() == nil)
        #expect(d.bufPtr == 3)
    }

    @Test("serializeState / deserializeState roundtrips buffer and position")
    func serializeRoundTrip() {
        let u1 = I8251()
        let src = CassetteDeck(usart: u1)
        src.bytePeriodTStates = 123
        src.primeDelayTStates = 456
        let bytes: [UInt8] = Array(repeating: 0x9C, count: 8) + [0x11, 0x22, 0x33]
        src.load(data: Data(bytes))
        src.motorOn = true
        src.cmtSelected = true
        // Drain prime delay, then pump 2 bytes with back-pressure.
        src.tick(tStates: 456)
        src.tick(tStates: 123); _ = u1.readData()
        src.tick(tStates: 123)
        let blob = src.serializeState()

        let u2 = I8251()
        let dst = CassetteDeck(usart: u2)
        dst.deserializeState(blob)

        #expect(dst.buffer == bytes)
        #expect(dst.bufPtr == src.bufPtr)
        #expect(dst.motorOn == true)
        #expect(dst.cmtSelected == true)
        #expect(dst.bytePeriodTStates == 123)
        #expect(dst.primeDelayTStates == 456)
        #expect(dst.dataCarriers == src.dataCarriers)
    }

    // MARK: - T2: Back-pressure stall

    @Test("tick stalls when RxRDY is still set (back-pressure)")
    func backPressureStallsPumping() {
        let u = I8251()
        let d = CassetteDeck(usart: u)
        d.bytePeriodTStates = 10
        d.primeDelayTStates = 0
        d.load(data: Data([0xA1, 0xA2, 0xA3]))
        d.motorOn = true
        d.cmtSelected = true
        d.tick(tStates: 10)            // pump first byte
        #expect(d.bufPtr == 1)
        d.tick(tStates: 100)           // plenty of time, but RxRDY still set
        #expect(d.bufPtr == 1)         // must NOT advance
        _ = u.readData()               // consume → clear RxRDY
        d.tick(tStates: 10)            // now should send next byte
        #expect(d.bufPtr == 2)
    }

    // MARK: - T3: Exhausted phase serialize/deserialize

    @Test("serializeState roundtrips exhausted phase")
    func serializeExhaustedPhase() {
        let u1 = I8251()
        let src = CassetteDeck(usart: u1)
        src.bytePeriodTStates = 10
        src.primeDelayTStates = 0
        src.load(data: Data([0x01, 0x02]))
        src.motorOn = true
        src.cmtSelected = true
        // Drain all bytes to reach exhausted phase.
        for _ in 0..<2 {
            src.tick(tStates: 10)
            _ = u1.readData()
        }
        src.tick(tStates: 10)          // triggers .exhausted
        #expect(src.dcd)               // exhausted DCD = high
        let blob = src.serializeState()

        let u2 = I8251()
        let dst = CassetteDeck(usart: u2)
        dst.deserializeState(blob)
        #expect(dst.bufPtr == 2)
        #expect(dst.dcd)               // exhausted phase preserved
    }
}
