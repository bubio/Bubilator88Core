import Testing
@testable import EmulatorCore

@Suite("SubBus Tests")
struct SubBusTests {

    // MARK: - Memory Map

    @Test func romReadOnly() {
        let bus = SubBus()
        let rom: [UInt8] = Array(0..<256).map { UInt8($0 & 0xFF) }
        bus.loadROM(rom + Array(repeating: 0xFF, count: 0x2000 - 256))

        // Read ROM
        #expect(bus.memRead(0x0000) == 0x00)
        #expect(bus.memRead(0x0001) == 0x01)

        // Write to ROM area is ignored
        bus.memWrite(0x0000, value: 0xAA)
        #expect(bus.memRead(0x0000) == 0x00)
    }

    @Test func romDoesNotMirrorIntoInitializedRegion() {
        let bus = SubBus()
        var rom = Array(repeating: UInt8(0x00), count: 0x2000)
        rom[0] = 0x42
        rom[0x100] = 0xAB
        bus.loadROM(rom)

        #expect(bus.memRead(0x0000) == 0x42)
        #expect(bus.memRead(0x0100) == 0xAB)
        #expect(bus.memRead(0x2000) == SubBus.initialByte(at: 0x2000))
        #expect(bus.memRead(0x2100) == SubBus.initialByte(at: 0x2100))
    }

    @Test func ramReadWrite() {
        let bus = SubBus()

        bus.memWrite(0x4000, value: 0x42)
        #expect(bus.memRead(0x4000) == 0x42)

        bus.memWrite(0x7FFF, value: 0xAB)
        #expect(bus.memRead(0x7FFF) == 0xAB)
    }

    @Test func addressWrapping() {
        let bus = SubBus()

        // Write to RAM at 0x4000
        bus.memWrite(0x4000, value: 0x55)

        // 0xC000 wraps to 0x4000 (& 0x7FFF)
        #expect(bus.memRead(0xC000) == 0x55)
    }

    @Test func powerOnPatternMatchesCommonSource() {
        let bus = SubBus()

        #expect(bus.memRead(0x0000) == 0x18)
        #expect(bus.memRead(0x0001) == 0xFE)
        #expect(bus.memRead(0x2000) == 0xF0)
        #expect(bus.memRead(0x2010) == 0x0F)
        #expect(bus.memRead(0x4000) == 0x0F)
        #expect(bus.memRead(0x6000) == 0x0F)
    }

    @Test func resetRestoresInitializedPattern() {
        let bus = SubBus()
        bus.memWrite(0x4000, value: 0xFF)
        bus.memWrite(0x5000, value: 0xFF)
        bus.reset()
        #expect(bus.memRead(0x4000) == SubBus.initialByte(at: 0x4000))
        #expect(bus.memRead(0x5000) == SubBus.initialByte(at: 0x5000))
    }

    // MARK: - I/O Routing

    @Test func fdcStatusRead() {
        let bus = SubBus()
        let fdc = UPD765A()
        bus.fdc = fdc

        let status = bus.ioRead(0xFA)
        #expect(status == 0x80)  // RQM (idle)
    }

    @Test func fdcDataWrite() {
        let bus = SubBus()
        let fdc = UPD765A()
        bus.fdc = fdc

        // Write Specify command
        bus.ioWrite(0xFB, value: 0x03)  // Specify
        #expect(fdc.phase == .command)
    }

    @Test func terminalCountRead() {
        let bus = SubBus()
        let fdc = UPD765A()
        bus.fdc = fdc

        _ = bus.ioRead(0xF8)
        #expect(fdc.tc == true)
    }

    @Test func pioSubSideWrite() {
        let bus = SubBus()
        let pio = PIO8255()
        bus.pio = pio

        // Sub writes Port B
        bus.ioWrite(0xFD, value: 0x42)
        #expect(pio.portAB[1][1].data == 0x42)
    }

    @Test func pioSubSideRead() {
        let bus = SubBus()
        let pio = PIO8255()
        bus.pio = pio

        // Main writes Port B (which sub reads as Port A)
        pio.writeAB(side: .main, port: .portB, data: 0xAB)

        let value = bus.ioRead(0xFC)
        #expect(value == 0xAB)
    }

    @Test func pioModeSet() {
        let bus = SubBus()
        let pio = PIO8255()
        bus.pio = pio

        // Mode set: PA=input, PCH=input, PB=output, PCL=output = 0x98
        bus.ioWrite(0xFF, value: 0x98)
        #expect(pio.portAB[1][0].type == .read)   // PA input
        #expect(pio.portC[1][0].type == .read)     // PCH input
        #expect(pio.portAB[1][1].type == .write)   // PB output
        #expect(pio.portC[1][1].type == .write)    // PCL output
    }

    @Test func pioBSR() {
        let bus = SubBus()
        let pio = PIO8255()
        bus.pio = pio

        // BSR: set bit 2 in CH (sub side)
        bus.ioWrite(0xFF, value: 0x0D)  // CH, bit 2, set
        #expect(pio.portC[1][0].data == 0x04)
    }

    @Test func motorControl() {
        let bus = SubBus()
        bus.ioWrite(0xF8, value: 0x03)  // Motor on for drives 0 and 1
        #expect(bus.motorOn[0] == true)
        #expect(bus.motorOn[1] == true)

        bus.ioWrite(0xF8, value: 0x01)
        #expect(bus.motorOn[0] == true)
        #expect(bus.motorOn[1] == false)
    }
}
