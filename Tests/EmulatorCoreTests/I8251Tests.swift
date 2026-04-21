import Testing
@testable import EmulatorCore

@Suite("I8251 USART Tests")
struct I8251Tests {

    private func initBasicAsync(_ u: I8251) {
        // N88-BASIC CMT load path: Mode = 0x4E (x16 baud, 8-bit, no parity,
        // 1 stop), Command = 0x27 (RxE | ER | DTR | TxEN).
        u.writeControl(0x4E)
        u.writeControl(0x27)
    }

    @Test("Initial status has TxRDY and TxEmpty set, RxRDY clear")
    func initialStatus() {
        let u = I8251()
        let s = I8251.Status(rawValue: u.readStatus())
        #expect(s.contains(.txRDY))
        #expect(s.contains(.txEmpty))
        #expect(!s.contains(.rxRDY))
    }

    @Test("First control write is Mode, second is Command")
    func modeCommandSequence() {
        let u = I8251()
        initBasicAsync(u)
        #expect(u.rxEnabled)
    }

    @Test("Internal Reset returns to Mode-expected state")
    func internalResetReEntersModeWait() {
        let u = I8251()
        initBasicAsync(u)
        // Issue Internal Reset (bit 6).
        u.writeControl(0x40)
        // Now the chip expects Mode again. A bogus Command-looking value
        // here should be parsed as Mode, leaving command unchanged (RxE off).
        u.writeControl(0x4E)
        #expect(!u.rxEnabled)
        u.writeControl(0x27)
        #expect(u.rxEnabled)
    }

    @Test("receiveByte sets RxRDY, readData clears it")
    func rxRoundTrip() {
        let u = I8251()
        initBasicAsync(u)
        u.receiveByte(0xA5)
        #expect(I8251.Status(rawValue: u.readStatus()).contains(.rxRDY))
        #expect(u.readData() == 0xA5)
        #expect(!I8251.Status(rawValue: u.readStatus()).contains(.rxRDY))
    }

    @Test("Overrun error when byte arrives before prior one is read")
    func overrunError() {
        let u = I8251()
        initBasicAsync(u)
        u.receiveByte(0x11)
        u.receiveByte(0x22)
        let s = I8251.Status(rawValue: u.readStatus())
        #expect(s.contains(.overrunErr))
        #expect(u.readData() == 0x22)
    }

    @Test("ER command bit clears error flags")
    func errorResetClearsFlags() {
        let u = I8251()
        initBasicAsync(u)
        u.receiveByte(0x11)
        u.receiveByte(0x22)  // triggers overrun
        #expect(I8251.Status(rawValue: u.readStatus()).contains(.overrunErr))
        // ER (bit 4) + RxE (bit 2) + DTR (bit 1) + TxEN (bit 0) = 0x17.
        u.writeControl(0x17)
        #expect(!I8251.Status(rawValue: u.readStatus()).contains(.overrunErr))
    }

    @Test("writeData keeps TxRDY and TxEmpty asserted")
    func txRemainsReady() {
        let u = I8251()
        initBasicAsync(u)
        u.writeData(0x5A)
        let s = I8251.Status(rawValue: u.readStatus())
        #expect(s.contains(.txRDY))
        #expect(s.contains(.txEmpty))
    }

    @Test("Subsequent Command writes do not re-enter Mode parsing")
    func multipleCommandWrites() {
        let u = I8251()
        initBasicAsync(u)
        u.writeControl(0x05)   // RxE + TxEN only
        #expect(u.rxEnabled)
        u.writeControl(0x01)   // TxEN only, no RxE
        #expect(!u.rxEnabled)
    }

    @Test("rxEnabled defaults off until Command byte is written")
    func rxEnabledDefaultsOff() {
        let u = I8251()
        #expect(!u.rxEnabled)
        u.writeControl(0x4E)   // Mode only — no Command yet
        #expect(!u.rxEnabled)
    }

    @Test("serialize / deserialize roundtrips Mode/Command/status/rxBuf")
    func serializeRoundTrip() {
        let a = I8251()
        initBasicAsync(a)
        a.receiveByte(0x42)
        _ = a.readStatus()   // leave rxBuf pending
        let blob = a.serializeState()

        let b = I8251()
        b.deserializeState(blob)

        #expect(b.readStatus() == a.readStatus())
        #expect(b.readData() == 0x42)
        #expect(b.rxEnabled == a.rxEnabled)
        // After reset, the writeExpect state should match source — verify
        // by issuing a Command and checking it's parsed as Command (not Mode).
        b.writeControl(0x40)  // Internal Reset
        b.writeControl(0x4E)  // Mode
        b.writeControl(0x27)  // Command (RxE on)
        #expect(b.rxEnabled)
    }

    @Test("reset() returns chip to power-on state")
    func resetRestoresDefaults() {
        let u = I8251()
        initBasicAsync(u)
        u.receiveByte(0x77)
        u.reset()
        let s = I8251.Status(rawValue: u.readStatus())
        #expect(s.contains(.txRDY))
        #expect(s.contains(.txEmpty))
        #expect(!s.contains(.rxRDY))
        #expect(!u.rxEnabled)
    }

    // MARK: - T1: onRxReady / onRxReadyCleared callback tests

    @Test("onRxReady fires on 0→1 RxRDY transition only")
    func rxReadyCallbackFiresOnce() {
        let u = I8251()
        var callCount = 0
        u.onRxReady = { callCount += 1 }

        u.receiveByte(0x11)            // 0→1: should fire
        #expect(callCount == 1)

        u.receiveByte(0x22)            // 1→1 (overrun): should NOT fire
        #expect(callCount == 1)
    }

    @Test("onRxReadyCleared fires when readData clears RxRDY")
    func rxReadyClearedCallback() {
        let u = I8251()
        var clearedCount = 0
        u.onRxReadyCleared = { clearedCount += 1 }

        u.receiveByte(0xAA)
        _ = u.readData()               // clears RxRDY → should fire
        #expect(clearedCount == 1)

        _ = u.readData()               // RxRDY already clear → should NOT fire
        #expect(clearedCount == 1)
    }
}
