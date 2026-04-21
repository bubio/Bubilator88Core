import Testing
@testable import EmulatorCore

@Suite("PIO8255 Tests")
struct PIO8255Tests {

    // MARK: - Init & Reset

    @Test func resetState() {
        let pio = PIO8255()

        // After reset, 8255 ports are input until a control word is written.
        #expect(pio.portAB[0][0].type == .read)
        #expect(pio.portAB[0][1].type == .read)
        #expect(pio.portAB[0][0].exist == false)
        #expect(pio.portAB[0][1].exist == false)

        // Port C: both halves input after reset
        #expect(pio.portC[0][0].type == .read)
        #expect(pio.portC[0][1].type == .read)
        #expect(pio.portC[0][0].contFlag == true)
        #expect(pio.portC[0][1].contFlag == true)

        // Sub side: same defaults
        #expect(pio.portAB[1][0].type == .read)
        #expect(pio.portAB[1][1].type == .read)
    }

    // MARK: - Port A/B Cross-wired Read/Write

    @Test func writeABThenRead() {
        let pio = PIO8255()

        // Main writes Port B → Sub reads Port A (cross-wired)
        pio.writeAB(side: .main, port: .portB, data: 0x42)
        #expect(pio.portAB[0][1].data == 0x42)
        #expect(pio.portAB[0][1].exist == true)

        // Sub reads Port A → reads from Main Port B
        let value = pio.readAB(side: .sub, port: .portA)
        #expect(value == 0x42)
        // Exist flag cleared after first read
        #expect(pio.portAB[0][1].exist == false)
    }

    @Test func subWriteMainRead() {
        let pio = PIO8255()

        // Sub writes Port B → Main reads Port A
        pio.writeAB(side: .sub, port: .portB, data: 0xAB)
        let value = pio.readAB(side: .main, port: .portA)
        #expect(value == 0xAB)
    }

    @Test func readWithoutWriteReturnsZero() {
        let pio = PIO8255()
        let value = pio.readAB(side: .sub, port: .portA)
        #expect(value == 0x00)
    }

    @Test func consecutiveWriteOverwrites() {
        let pio = PIO8255()

        pio.writeAB(side: .main, port: .portB, data: 0x11)
        #expect(pio.portAB[0][1].exist == true)

        // Second write without read = continuous write
        pio.writeAB(side: .main, port: .portB, data: 0x22)
        #expect(pio.portAB[0][1].data == 0x22)
    }

    @Test func consecutiveReadReturnsLastData() {
        let pio = PIO8255()

        pio.writeAB(side: .main, port: .portB, data: 0x55)
        let first = pio.readAB(side: .sub, port: .portA)
        #expect(first == 0x55)

        // Second read: exist already cleared, returns same data
        let second = pio.readAB(side: .sub, port: .portA)
        #expect(second == 0x55)
    }

    @Test func readOwnWritePort() {
        let pio = PIO8255()
        pio.setMode(side: .main, data: 0x99)  // PB output

        pio.writeAB(side: .main, port: .portB, data: 0x77)

        // Reading an output port returns the output latch.
        let value = pio.readAB(side: .main, port: .portB)
        #expect(value == 0x77)
    }

    // MARK: - Port C Cross-wired Read

    @Test func readCCrossWired() {
        let pio = PIO8255()

        // Port C data writes are nibble-swapped across the two 8255s.
        pio.writePortC(side: .sub, data: 0xA5)

        let value = pio.readC(side: .main)
        #expect(value == 0x5A)
    }

    @Test func readCSubSide() {
        let pio = PIO8255()

        pio.writePortC(side: .main, data: 0x3C)

        let value = pio.readC(side: .sub)
        #expect(value == 0xC3)
    }

    // MARK: - Port C Polling / CPU Switch

    @Test func readCTogglesContFlag() {
        let pio = PIO8255()

        #expect(pio.portC[0][1].contFlag == true)

        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == false)

        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == true)
    }

    @Test func cpuSwitchOnConsecutiveRead() {
        let pio = PIO8255()

        var switchCount = 0
        pio.onCPUSwitch = { switchCount += 1 }

        // QUASI88 treats the first read after contFlag=true as the boundary.
        _ = pio.readC(side: .main)
        #expect(switchCount == 1)

        // Second consecutive read just rearms the detector.
        _ = pio.readC(side: .main)
        #expect(switchCount == 1)

        // Third read hits the boundary again.
        _ = pio.readC(side: .main)
        #expect(switchCount == 2)
    }

    @Test func subSideCPUSwitchAlsoWorks() {
        let pio = PIO8255()

        var switchCount = 0
        pio.onCPUSwitch = { switchCount += 1 }

        _ = pio.readC(side: .sub)
        #expect(switchCount == 1)

        _ = pio.readC(side: .sub)
        #expect(switchCount == 1)
    }

    @Test("Port C polling boundary survives AB and C writes")
    func portCPollBoundarySurvivesInterveningPIOAccesses() {
        let pio = PIO8255()

        var switchCount = 0
        pio.onCPUSwitch = { switchCount += 1 }

        _ = pio.readC(side: .main)
        #expect(switchCount == 1)

        pio.writeAB(side: .sub, port: .portB, data: 0x12)
        pio.writeC(side: .main, data: 0x09)

        _ = pio.readC(side: .main)
        #expect(switchCount == 1)
    }

    // MARK: - Port C BSR (Bit Set/Reset)

    @Test func writeCBitSet() {
        let pio = PIO8255()

        // Set bit 2 in CH (main side): data = 0x08 | (2<<1) | 1 = 0x0D
        pio.writeC(side: .main, data: 0x0D)
        #expect(pio.portC[0][0].data == 0x04)  // bit 2 set in CH
    }

    @Test func writeCBitReset() {
        let pio = PIO8255()

        // Set bit 3 in CH first
        pio.writeC(side: .main, data: 0x0F)  // CH, bit 3, set
        #expect(pio.portC[0][0].data == 0x08)

        // Clear bit 3 in CH: data = 0x08 | (3<<1) | 0 = 0x0E
        pio.writeC(side: .main, data: 0x0E)
        #expect(pio.portC[0][0].data == 0x00)
    }

    @Test func writeCLowerHalf() {
        let pio = PIO8255()

        // Set bit 1 in CL (main side): data = 0x00 | (1<<1) | 1 = 0x03
        pio.writeC(side: .main, data: 0x03)
        #expect(pio.portC[0][1].data == 0x02)
    }

    @Test func writeCMultipleBits() {
        let pio = PIO8255()

        // Set bits 0, 1, 2 in CH
        pio.writeC(side: .main, data: 0x09)  // CH, bit 0, set
        pio.writeC(side: .main, data: 0x0B)  // CH, bit 1, set
        pio.writeC(side: .main, data: 0x0D)  // CH, bit 2, set
        #expect(pio.portC[0][0].data == 0x07)
    }

    // MARK: - Port C Direct Write

    @Test func writeCDirect() {
        let pio = PIO8255()

        pio.writeCDirect(side: .main, data: 0xA5)
        #expect(pio.portC[0][0].data == 0x0A)  // CH = upper nibble
        #expect(pio.portC[0][1].data == 0x05)  // CL = lower nibble
    }

    // MARK: - Mode Set

    @Test func setModeConfiguresPorts() {
        let pio = PIO8255()

        // Mode: PA=output(0), PCH=output(0), PB=input(1), PCL=input(1)
        // data = 0x80 | 0x00(PA out) | 0x00(PCH out) | 0x02(PB in) | 0x01(PCL in) = 0x83
        // (bit 7 must be 1 for mode set, but we don't check it here)
        pio.setMode(side: .main, data: 0x83)

        #expect(pio.portAB[0][0].type == .write)  // PA = output
        #expect(pio.portAB[0][1].type == .read)    // PB = input
        #expect(pio.portC[0][0].type == .write)    // PCH = output
        #expect(pio.portC[0][1].type == .read)     // PCL = input
    }

    @Test func setModeAllInput() {
        let pio = PIO8255()

        // All input: PA=in(0x10), PCH=in(0x08), PB=in(0x02), PCL=in(0x01) = 0x1B
        pio.setMode(side: .sub, data: 0x1B)

        #expect(pio.portAB[1][0].type == .read)
        #expect(pio.portAB[1][1].type == .read)
        #expect(pio.portC[1][0].type == .read)
        #expect(pio.portC[1][1].type == .read)
    }

    @Test func setModeResetsData() {
        let pio = PIO8255()

        // Write some data first
        pio.writeAB(side: .main, port: .portB, data: 0xFF)
        pio.portC[0][0].data = 0x0F

        // Set mode resets data
        pio.setMode(side: .main, data: 0x83)

        #expect(pio.portAB[0][1].data == 0x00)
        #expect(pio.portC[0][0].data == 0x00)
        #expect(pio.portAB[0][1].exist == false)
        #expect(pio.portC[0][0].contFlag == true)
    }

    // MARK: - Cross-wired Handshake Scenario

    @Test("Full handshake: main writes data, sub reads it, sub responds, main reads")
    func fullHandshake() {
        let pio = PIO8255()

        // Main writes 0x42 on Port B
        pio.writeAB(side: .main, port: .portB, data: 0x42)

        // Sub reads from Port A (cross: main port B)
        let received = pio.readAB(side: .sub, port: .portA)
        #expect(received == 0x42)

        // Sub writes response 0xAB on Port B
        pio.writeAB(side: .sub, port: .portB, data: 0xAB)

        // Main reads from Port A (cross: sub port B)
        let response = pio.readAB(side: .main, port: .portA)
        #expect(response == 0xAB)
    }

    @Test("Sub Port B output restores OBF_B after main ACK_B falls")
    func subPortBOutputRestoresOBFOnAckFall() {
        let pio = PIO8255()

        // PC-8801 disk link: Port A mode1 input, Port B mode1 output.
        pio.setMode(side: .main, data: 0xB4)
        pio.setMode(side: .sub, data: 0xB4)

        // Freshly configured output buffer is empty/ready.
        #expect(pio.readC(side: .sub) & 0x02 != 0)

        // Sub writes one byte for main → OBF_B clears while data is pending.
        pio.writeAB(side: .sub, port: .portB, data: 0x11)
        #expect(pio.readC(side: .sub) & 0x02 == 0)

        // Main toggles ACK_B high→low on its bit6, which is cross-wired to sub PC2.
        pio.writeC(side: .main, data: 0x0D)  // bit 6 set
        pio.writeC(side: .main, data: 0x0C)  // bit 6 clear

        // After the falling edge, the sub output buffer should be marked empty again.
        #expect(pio.readC(side: .sub) & 0x02 != 0)
    }

    @Test("Two-byte sub->main handshake leaves sub ready for the next send")
    func subTwoByteSendRestoresReadyState() {
        let pio = PIO8255()

        pio.setMode(side: .main, data: 0xB4)
        pio.setMode(side: .sub, data: 0xB4)

        // Start state observed by the sub send routine: bit1 high means ready.
        #expect(pio.readC(side: .sub) & 0x02 != 0)

        // First byte pending.
        pio.writeAB(side: .sub, port: .portB, data: 0x12)
        pio.writeC(side: .sub, data: 0x09)  // DAV set

        // Main acknowledges first byte and consumes it.
        pio.writeC(side: .main, data: 0x0D)  // bit6 set
        _ = pio.readAB(side: .main, port: .portA)

        // Second byte pending, then DAV clear.
        pio.writeAB(side: .sub, port: .portB, data: 0x34)
        pio.writeC(side: .sub, data: 0x08)  // DAV clear

        // Main clears ACK and consumes second byte.
        pio.writeC(side: .main, data: 0x0C)  // bit6 clear
        _ = pio.readAB(side: .main, port: .portA)

        // The next send should be able to start immediately.
        #expect(pio.readC(side: .sub) & 0x02 != 0)
    }

    @Test("Port C signals visible across sides")
    func portCSignalsCross() {
        let pio = PIO8255()

        // Main sets CH bit 3 (ATN)
        pio.writeC(side: .main, data: 0x0F)  // CH, bit 3, set
        #expect(pio.portC[0][0].data == 0x08)

        // Sub reads Port C: lower nibble should contain Main CH
        // (Sub CL is read type → reads from Main CH)
        let subC = pio.readC(side: .sub)
        #expect(subC & 0x08 != 0)  // bit 3 of main CH visible in sub's lower nibble
    }

    // MARK: - Port C ContFlag Toggling

    @Test("Port C contFlag starts true and toggles on each readC")
    func portCContFlagTogglesOnEachRead() {
        let pio = PIO8255()

        var switchCount = 0
        pio.onCPUSwitch = { switchCount += 1 }

        // Initial state: contFlag=true (CL side)
        #expect(pio.portC[0][1].contFlag == true)

        // Read 1: contFlag toggles to false → onCPUSwitch fires
        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == false)
        #expect(switchCount == 1)

        // Read 2: contFlag toggles to true → no switch
        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == true)
        #expect(switchCount == 1)

        // Read 3: contFlag toggles to false → onCPUSwitch fires again
        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == false)
        #expect(switchCount == 2)

        // Read 4: contFlag toggles to true → no switch
        _ = pio.readC(side: .main)
        #expect(pio.portC[0][1].contFlag == true)
        #expect(switchCount == 2)
    }

    @Test("Mode word reset clears all ports and exist flags")
    func modeWordResetClearsPortsAndExistFlags() {
        let pio = PIO8255()

        // Write data to ports
        pio.writeAB(side: .main, port: .portB, data: 0xAA)
        #expect(pio.portAB[0][1].exist == true)
        #expect(pio.portAB[0][1].data == 0xAA)

        // Write mode word (bit 7 set = mode set)
        pio.setMode(side: .main, data: 0x83)

        // All ports should be cleared
        #expect(pio.portAB[0][1].data == 0x00)
        #expect(pio.portAB[0][1].exist == false)

        // contFlag should be reset to true
        #expect(pio.portC[0][0].contFlag == true)
        #expect(pio.portC[0][1].contFlag == true)
    }

    @Test("writeControl BSR only affects specified bit")
    func writeControlBSROnlyAffectsSpecifiedBit() {
        let pio = PIO8255()

        // Set bit 0 in CH: data = 0x08 | (0<<1) | 1 = 0x09
        pio.writeC(side: .main, data: 0x09)
        #expect(pio.portC[0][0].data == 0x01)

        // Set bit 3 in CH: data = 0x08 | (3<<1) | 1 = 0x0F
        pio.writeC(side: .main, data: 0x0F)
        #expect(pio.portC[0][0].data == 0x09)  // bits 0 and 3 set

        // Clear bit 0 in CH: data = 0x08 | (0<<1) | 0 = 0x08
        pio.writeC(side: .main, data: 0x08)
        #expect(pio.portC[0][0].data == 0x08)  // only bit 3 remains

        // Verify bit 3 is still set
        #expect(pio.portC[0][0].data & 0x08 != 0)
        // Verify bit 0 is cleared
        #expect(pio.portC[0][0].data & 0x01 == 0)
    }
}
