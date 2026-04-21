import Testing
@testable import EmulatorCore

@Suite("DMAController Tests")
struct DMAControllerTests {

    @Test("Initial state")
    func initialState() {
        let dma = DMAController()
        #expect(dma.channels.count == 4)
        #expect(dma.modeRegister == 0)
        #expect(dma.textVRAMAddress == 0)
        #expect(dma.textVRAMCount == 0)
        for ch in dma.channels {
            #expect(ch.address == 0)
            #expect(ch.count == 0)
            #expect(ch.enabled == false)
        }
    }

    @Test("Write channel 2 address (text VRAM)")
    func writeChannel2Address() {
        let dma = DMAController()
        // Write low byte of ch2 address (port 0x64)
        dma.ioWrite(0x64, value: 0x00)
        // Write high byte of ch2 address (port 0x64, flip-flop toggled)
        dma.ioWrite(0x64, value: 0xF3)
        #expect(dma.channels[2].address == 0xF300)
        #expect(dma.textVRAMAddress == 0xF300)
    }

    @Test("Write channel 2 count")
    func writeChannel2Count() {
        let dma = DMAController()
        // Write low byte of ch2 count (port 0x65)
        dma.ioWrite(0x65, value: 0xD0)
        // Write high byte of ch2 count (port 0x65, flip-flop toggled)
        dma.ioWrite(0x65, value: 0x0F)
        #expect(dma.channels[2].count == 0x0FD0)
        #expect(dma.textVRAMCount == 0x0FD0)
        #expect(dma.channels[2].mode == 0x00) // top 2 bits of high byte
    }

    @Test("Count with mode bits")
    func countWithModeBits() {
        let dma = DMAController()
        // Write ch2 count: high byte = 0x80 → mode = 2 (read), count high = 0x00
        dma.ioWrite(0x65, value: 0x00) // low byte
        dma.ioWrite(0x65, value: 0x80) // high byte: mode=10b, count=0x00
        #expect(dma.channels[2].mode == 0x02)
        #expect(dma.textVRAMCount == 0x0000) // 14-bit count masked
    }

    @Test("Mode register enables channels")
    func modeRegisterEnablesChannels() {
        let dma = DMAController()
        // Enable channels 0 and 2 (bits 0 and 2)
        dma.ioWrite(0x68, value: 0x05)
        #expect(dma.channels[0].enabled == true)
        #expect(dma.channels[1].enabled == false)
        #expect(dma.channels[2].enabled == true)
        #expect(dma.channels[3].enabled == false)
        #expect(dma.modeRegister == 0x05)
    }

    @Test("Mode register resets flip-flop")
    func modeRegisterResetsFlipFlop() {
        let dma = DMAController()
        // Write low byte only (flip-flop toggled to high)
        dma.ioWrite(0x64, value: 0xAB)
        // Now write mode register to reset flip-flop
        dma.ioWrite(0x68, value: 0x04)
        // Next write to 0x64 should be low byte again
        dma.ioWrite(0x64, value: 0xCD)
        #expect(dma.channels[2].address == 0x00CD) // low byte overwritten, high cleared by init
    }

    @Test("Read status returns mode register")
    func readStatus() {
        let dma = DMAController()
        dma.ioWrite(0x68, value: 0x0F)
        #expect(dma.ioRead(0x68) == 0x0F)
    }

    @Test("Address register readback uses DMA flip-flop")
    func addressRegisterReadbackUsesDMAFlipFlop() {
        let dma = DMAController()
        dma.ioWrite(0x66, value: 0x34)
        dma.ioWrite(0x66, value: 0x12)

        dma.ioWrite(0x68, value: 0x00)  // reset DMA flip-flop before readback

        #expect(dma.ioRead(0x66) == 0x34)
        #expect(dma.ioRead(0x66) == 0x12)
    }

    @Test("Reset clears all state")
    func resetClearsState() {
        let dma = DMAController()
        dma.ioWrite(0x64, value: 0x00)
        dma.ioWrite(0x64, value: 0xF3)
        dma.ioWrite(0x68, value: 0x0F)
        dma.reset()
        #expect(dma.textVRAMAddress == 0)
        #expect(dma.modeRegister == 0)
        for ch in dma.channels {
            #expect(ch.enabled == false)
        }
    }

    @Test("Bus wiring — DMA ports dispatched through Pc88Bus")
    func busWiring() {
        let bus = Pc88Bus()
        let dma = DMAController()
        bus.dma = dma

        // Write ch2 address via bus
        bus.ioWrite(0x64, value: 0x00)
        bus.ioWrite(0x64, value: 0x80)
        #expect(dma.channels[2].address == 0x8000)

        // Read status via bus
        bus.ioWrite(0x68, value: 0x04)
        let status = bus.ioRead(0x68)
        #expect(status == 0x04)
    }

    @Test("Bus wiring — RIGLAS DMA channel 3 reads back zero by default")
    func riglasDMAChannel3Readback() {
        let bus = Pc88Bus()
        let dma = DMAController()
        bus.dma = dma

        bus.ioWrite(0x68, value: 0x00)  // reset DMA flip-flop before IN 66h

        #expect(bus.ioRead(0x66) == 0x00)
        #expect(bus.ioRead(0x66) == 0x00)
    }
}
