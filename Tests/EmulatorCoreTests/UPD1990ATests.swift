import Testing
@testable import EmulatorCore

@Suite("UPD1990A Calendar Tests")
struct UPD1990ATests {

    private func pulseStb(_ cal: UPD1990A) {
        cal.writeControl(0x02)
        cal.writeControl(0x00)
    }

    private func pulseClk(_ cal: UPD1990A) {
        cal.writeControl(0x00)
        cal.writeControl(0x04)
    }

    private func strobeExtendedCommand(_ cal: UPD1990A, _ nibble: UInt8) {
        for bit in 0..<4 {
            let value: UInt8 = ((nibble >> bit) & 0x01) != 0 ? 0x08 : 0x00
            cal.writeCommand(value)
            pulseClk(cal)
        }
        cal.writeCommand(0x07)
        pulseStb(cal)
    }

    private func romStrobeExtendedCommand(_ cal: UPD1990A, _ nibble: UInt8) {
        var value = nibble << 3
        for _ in 0..<4 {
            cal.writeCommand(value)
            pulseClk(cal)
            value = (value >> 1) | (value << 7)
        }
        cal.writeCommand(0x07)
        pulseStb(cal)
    }

    private func shiftWriteByte(_ cal: UPD1990A, _ value: UInt8) {
        for bit in 0..<8 {
            let command: UInt8 = ((value >> bit) & 0x01) != 0 ? 0x09 : 0x01
            cal.writeCommand(command)
            pulseClk(cal)
        }
    }

    private func romShiftWriteByte(_ cal: UPD1990A, _ value: UInt8) {
        var command = value
        for _ in 0..<5 {
            command = (command >> 1) | (command << 7)
        }
        for _ in 0..<8 {
            cal.writeCommand(command)
            pulseClk(cal)
            command = (command >> 1) | (command << 7)
        }
    }

    @Test("Initial CDO is false")
    func initialCDO() {
        let cal = UPD1990A()
        #expect(cal.cdo == false)
    }

    @Test("Reset clears CDO")
    func resetClearsCDO() {
        let cal = UPD1990A()
        cal.writeCommand(0x03)
        pulseStb(cal)

        cal.reset()
        #expect(cal.cdo == false)
    }

    // MARK: - BCD format

    @Test("Read command loads BubiC-compatible BCD: sec=45 min=30 hour=12")
    func readCommandLoadsBCD() {
        let cal = UPD1990A()
        cal.timeProvider = { (sec: 45, min: 30, hour: 12, day: 15, wday: 3, mon: 7, year: 26) }

        // Issue Read command (mode 3): raw port bit1 falling edge
        cal.writeCommand(0x03)
        pulseStb(cal)

        // BCD: sec=0x45, min=0x30, hour=0x12, day=0x15, mon/wday=0x73
        #expect(cal.shiftReg[0] == 0x45)  // BCD 45
        #expect(cal.shiftReg[1] == 0x30)  // BCD 30
        #expect(cal.shiftReg[2] == 0x12)  // BCD 12
        #expect(cal.shiftReg[3] == 0x15)  // BCD 15
        #expect(cal.shiftReg[4] == 0x73)  // month=7 << 4 | weekday=3
        #expect(cal.shiftReg[5] == 0x00)
    }

    @Test("CDO exposes bit 0 after strobe without extra shifts")
    func cdoAfterStrobe() {
        let cal = UPD1990A()
        // sec=45 = 0x45, bit 0 = 1
        cal.timeProvider = { (sec: 45, min: 0, hour: 0, day: 1, wday: 0, mon: 1, year: 0) }

        cal.writeCommand(0x03)
        pulseStb(cal)

        #expect(cal.cdo == true)  // 0x45 bit 0 = 1

        // sec=30 = 0x30, bit 0 = 0
        cal.timeProvider = { (sec: 30, min: 0, hour: 0, day: 1, wday: 0, mon: 1, year: 0) }
        cal.writeCommand(0x03)
        pulseStb(cal)

        #expect(cal.cdo == false)  // 0x30 bit 0 = 0
    }

    @Test("STB triggers on raw falling edge, not rising edge")
    func stbFallingEdge() {
        let cal = UPD1990A()
        cal.timeProvider = { (sec: 45, min: 30, hour: 12, day: 15, wday: 3, mon: 7, year: 26) }

        cal.writeCommand(0x03)

        // Raw bit1 rising should not latch.
        cal.writeControl(0x02)
        #expect(cal.shiftReg[0] == 0x00)
        #expect(cal.cdo == false)

        // Raw bit1 falling should latch and expose bit 0.
        cal.writeControl(0x00)
        #expect(cal.shiftReg[0] == 0x45)
        #expect(cal.cdo == true)
    }

    // MARK: - CLK edge

    @Test("CLK triggers on rising edge, not falling edge")
    func clkRisingEdge() {
        let cal = UPD1990A()
        cal.timeProvider = { (sec: 59, min: 0, hour: 0, day: 1, wday: 0, mon: 1, year: 0) }

        // Load time via strobe
        cal.writeCommand(0x03)
        pulseStb(cal)
        cal.writeCommand(0x01)
        pulseStb(cal)

        let cdoAfterStrobe = cal.cdo  // 0x59 bit 0 = 1
        #expect(cdoAfterStrobe == true)

        // CLK rising edge (0→4): should shift
        pulseClk(cal)
        let cdoAfterRise = cal.cdo  // shifted: 0x59 >> 1 bit 0 = 0x2C bit 0 = 0
        #expect(cdoAfterRise == false)

        // CLK falling edge (4→0): should NOT shift
        let regBefore = cal.shiftReg
        cal.writeControl(0x00)
        #expect(cal.shiftReg == regBefore)  // no change on falling edge
    }

    // MARK: - Serial readout

    @Test("40-bit serial readout reconstructs correct time")
    func serialReadout40Bit() {
        let cal = UPD1990A()
        cal.timeProvider = { (sec: 23, min: 45, hour: 7, day: 1, wday: 2, mon: 3, year: 0) }

        cal.writeCommand(0x03)
        pulseStb(cal)
        cal.writeCommand(0x01)
        pulseStb(cal)

        // Read 40 bits LSB-first in direct read mode.
        var bits: [Bool] = []
        // First bit is already in CDO after strobe
        bits.append(cal.cdo)
        for _ in 1..<40 {
            pulseClk(cal)
            bits.append(cal.cdo)
        }

        // Reconstruct bytes from bits
        var bytes = [UInt8](repeating: 0, count: 5)
        for i in 0..<40 {
            if bits[i] {
                bytes[i / 8] |= UInt8(1 << (i % 8))
            }
        }

        #expect(bytes[0] == 0x23)  // BCD sec
        #expect(bytes[1] == 0x45)  // BCD min
        #expect(bytes[2] == 0x07)  // BCD hour
        #expect(bytes[3] == 0x01)  // BCD day
        #expect(bytes[4] == 0x32)  // month=3 << 4 | weekday=2
    }

    @Test("cmd=7 extended read returns year as sixth byte")
    func extendedReadReturnsYear() {
        let cal = UPD1990A()
        cal.timeProvider = { (sec: 23, min: 45, hour: 7, day: 1, wday: 2, mon: 3, year: 26) }

        strobeExtendedCommand(cal, 0x03) // extended read
        strobeExtendedCommand(cal, 0x01) // extended shift

        var bits: [Bool] = [cal.cdo]
        for _ in 1..<48 {
            pulseClk(cal)
            bits.append(cal.cdo)
        }

        var bytes = [UInt8](repeating: 0, count: 6)
        for index in 0..<48 {
            if bits[index] {
                bytes[index / 8] |= UInt8(1 << (index % 8))
            }
        }

        #expect(bytes[0] == 0x23)
        #expect(bytes[1] == 0x45)
        #expect(bytes[2] == 0x07)
        #expect(bytes[3] == 0x01)
        #expect(bytes[4] == 0x32)
        #expect(bytes[5] == 0x26)
    }

    @Test("Time set updates current time and advances with host elapsed seconds")
    func timeSetAdvancesFromWrittenValue() {
        let cal = UPD1990A()
        var host = (sec: 51, min: 3, hour: 12, day: 28, wday: 6, mon: 3, year: 26)
        cal.timeProvider = { host }

        cal.writeCommand(0x01)
        pulseStb(cal)
        for byte: UInt8 in [0x00, 0x00, 0x00, 0x28, 0x36, 0x26] {
            shiftWriteByte(cal, byte)
        }

        cal.writeCommand(0x02)
        pulseStb(cal)

        host.sec = 58
        strobeExtendedCommand(cal, 0x03)

        #expect(cal.shiftReg[0] == 0x07)
        #expect(cal.shiftReg[1] == 0x00)
        #expect(cal.shiftReg[2] == 0x00)
        #expect(cal.shiftReg[3] == 0x28)
        #expect(cal.shiftReg[4] == 0x36)
        #expect(cal.shiftReg[5] == 0x26)
    }

    @Test("ROM-style extended time set sequence updates current time")
    func romStyleExtendedTimeSet() {
        let cal = UPD1990A()
        var host = (sec: 51, min: 3, hour: 12, day: 28, wday: 6, mon: 3, year: 26)
        cal.timeProvider = { host }

        romStrobeExtendedCommand(cal, 0x00)
        romStrobeExtendedCommand(cal, 0x01)
        for byte: UInt8 in [0x00, 0x00, 0x00, 0x28, 0x30, 0x26] {
            romShiftWriteByte(cal, byte)
        }
        romStrobeExtendedCommand(cal, 0x02)

        host.sec = 58
        romStrobeExtendedCommand(cal, 0x03)
        romStrobeExtendedCommand(cal, 0x01)

        var bits: [Bool] = [cal.cdo]
        for _ in 1..<48 {
            pulseClk(cal)
            bits.append(cal.cdo)
        }

        var bytes = [UInt8](repeating: 0, count: 6)
        for index in 0..<48 {
            if bits[index] {
                bytes[index / 8] |= UInt8(1 << (index % 8))
            }
        }

        #expect(bytes[0] == 0x07)
        #expect(bytes[1] == 0x00)
        #expect(bytes[2] == 0x00)
        #expect(bytes[3] == 0x28)
        #expect(bytes[4] == 0x36)
        #expect(bytes[5] == 0x26)
    }

    // MARK: - Shift without Read

    @Test("CLK pulses without Read command shift zeros")
    func clockWithoutReadShiftsZeros() {
        let cal = UPD1990A()

        var allFalse = true
        for _ in 0..<10 {
            pulseClk(cal)
            if cal.cdo { allFalse = false }
        }
        #expect(allFalse)
    }

    // MARK: - Bus integration

    @Test("Port 0x40 CDO bit via Pc88Bus integration")
    func busIntegrationCDO() {
        let bus = Pc88Bus()
        let cal = UPD1990A()
        bus.calendar = cal

        let val1 = bus.ioRead(0x40)
        #expect((val1 & 0x10) == 0)

        cal.timeProvider = { (sec: 59, min: 0, hour: 0, day: 1, wday: 0, mon: 1, year: 0) }
        bus.ioWrite(0x10, value: 0x03)
        bus.ioWrite(0x40, value: 0x02)
        bus.ioWrite(0x40, value: 0x00)

        // sec=59=0x59, bit0=1 → CDO=true → port 0x40 bit 4 = 1
        let val2 = bus.ioRead(0x40)
        #expect((val2 & 0x10) == 0x10)
    }

    @Test("Machine creates and wires calendar")
    func machineWiresCalendar() {
        let machine = Machine()
        #expect(machine.bus.calendar != nil)
        #expect(machine.bus.calendar === machine.calendar)
    }
}
