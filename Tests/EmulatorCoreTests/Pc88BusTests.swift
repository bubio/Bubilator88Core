import Testing
import Foundation
@testable import EmulatorCore

@Suite("Pc88Bus Tests")
struct Pc88BusTests {

    private func configureTextDMARead(
        _ dma: DMAController,
        crtc: CRTC,
        bytes: Int? = nil
    ) {
        let expectedBytes = Int(crtc.linesPerScreen) * crtc.bytesPerDMARow
        let transferBytes = max(bytes ?? expectedBytes, 1)
        dma.channels[2].mode = 0b10
        dma.channels[2].count = UInt16(truncatingIfNeeded: transferBytes - 1)
        dma.channels[2].enabled = true
        crtc.displayEnabled = true
        crtc.intrMask = 3
    }

    // MARK: - Memory Map Basics

    @Test func ramReadWriteDefault() {
        let bus = Pc88Bus()

        // Write to RAM at 0x8400 (always RAM)
        bus.memWrite(0x8400, value: 0x42)
        #expect(bus.memRead(0x8400) == 0x42)

        // 0xC000 without GVRAM mode → main RAM
        bus.memWrite(0xC000, value: 0xAB)
        #expect(bus.memRead(0xC000) == 0xAB)
    }

    @Test func lowMemoryDefaultReadsROM() {
        let bus = Pc88Bus()

        // No ROM loaded → reads 0xFF
        #expect(bus.memRead(0x0000) == 0xFF)

        // Load N88-BASIC ROM
        var rom = Array(repeating: UInt8(0x00), count: 32768)
        rom[0] = 0xC3  // JP instruction at 0x0000
        rom[1] = 0x00
        rom[2] = 0x60
        bus.n88BasicROM = rom

        #expect(bus.memRead(0x0000) == 0xC3)
        #expect(bus.memRead(0x0001) == 0x00)
        #expect(bus.memRead(0x0002) == 0x60)
    }

    @Test func lowMemoryWriteIgnoredInROMMode() {
        let bus = Pc88Bus()
        bus.n88BasicROM = Array(repeating: 0xAA, count: 32768)

        // Write to ROM area — should be silently ignored
        bus.memWrite(0x0000, value: 0x55)
        #expect(bus.memRead(0x0000) == 0xAA)  // ROM value unchanged
    }

    @Test func ramModeSelectsRAMAtLowAddress() {
        let bus = Pc88Bus()
        bus.n88BasicROM = Array(repeating: 0xAA, count: 32768)

        // Switch to RAM mode
        bus.ramMode = true

        // Write to RAM at 0x0000
        bus.memWrite(0x0000, value: 0x55)
        #expect(bus.memRead(0x0000) == 0x55)
    }

    @Test func nBasicROMMode() {
        let bus = Pc88Bus()
        bus.n88BasicROM = Array(repeating: 0xAA, count: 32768)
        bus.nBasicROM = Array(repeating: 0xBB, count: 32768)

        // Default: N88-BASIC
        #expect(bus.memRead(0x0000) == 0xAA)

        // Switch to N-BASIC
        bus.romModeN88 = false
        #expect(bus.memRead(0x0000) == 0xBB)
    }

    // MARK: - GVRAM

    @Test func gvramPlaneSelection() {
        let bus = Pc88Bus()
        // Independent mode (evramMode=false): gvramPlane selects bank

        // Select Blue plane and write
        bus.gvramPlane = 0
        bus.memWrite(0xC000, value: 0x11)
        #expect(bus.memRead(0xC000) == 0x11)

        // Select Red plane — should read 0x00 (different plane)
        bus.gvramPlane = 1
        #expect(bus.memRead(0xC000) == 0x00)

        // Write to Red plane
        bus.memWrite(0xC000, value: 0x22)
        #expect(bus.memRead(0xC000) == 0x22)

        // Switch back to Blue — original value still there
        bus.gvramPlane = 0
        #expect(bus.memRead(0xC000) == 0x11)
    }

    @Test func gvramDisabledReadsMainRAM() {
        let bus = Pc88Bus()

        // Write to main RAM at 0xC000 (gvramPlane=-1, evramMode=false)
        bus.gvramPlane = -1
        bus.memWrite(0xC000, value: 0x42)
        #expect(bus.memRead(0xC000) == 0x42)

        // Enable GVRAM bank — should now read plane data (0x00)
        bus.gvramPlane = 0
        #expect(bus.memRead(0xC000) == 0x00)

        // Disable GVRAM — back to main RAM
        bus.gvramPlane = -1
        #expect(bus.memRead(0xC000) == 0x42)
    }

    @Test func gvramBankSelectViaPorts() {
        let bus = Pc88Bus()

        // Port 0x5C selects Blue
        bus.ioWrite(0x5C, value: 0x00)
        #expect(bus.gvramPlane == 0)

        // Port 0x5D selects Red
        bus.ioWrite(0x5D, value: 0x00)
        #expect(bus.gvramPlane == 1)

        // Port 0x5E selects Green
        bus.ioWrite(0x5E, value: 0x00)
        #expect(bus.gvramPlane == 2)

        // Port 0x5F selects main RAM
        bus.ioWrite(0x5F, value: 0x00)
        #expect(bus.gvramPlane == -1)
    }

    // MARK: - ALU Operations

    @Test("ALU non-contiguous bits: AND NOT, OR, XOR, NOP")
    func aluNonContiguousBits() {
        let bus = Pc88Bus()
        // Enable ALU mode: evramMode=true + gamMode=true
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        bus.ioWrite(0x35, value: 0x80)  // gamMode=true, GDM=0 (ALU bit ops)

        // Pre-fill all planes with 0xFF
        bus.gvram[0][0] = 0xFF
        bus.gvram[1][0] = 0xFF
        bus.gvram[2][0] = 0xFF

        // QUASI88 ALU1_ctrl: non-contiguous bits per plane
        // Blue=bits{0,4}, Red=bits{1,5}, Green=bits{2,6}
        // Set: Blue=AND NOT(0x00), Red=OR(0x01), Green=XOR(0x10)
        bus.aluControl1 = 0x42  // 0b0100_0010

        // Write triggers ALU with value 0x55
        bus.memWrite(0xC000, value: 0x55)

        #expect(bus.gvram[0][0] == 0xAA)  // Blue: AND NOT → 0xFF & ~0x55 = 0xAA
        #expect(bus.gvram[1][0] == 0xFF)  // Red: OR → 0xFF | 0x55 = 0xFF
        #expect(bus.gvram[2][0] == 0xAA)  // Green: XOR → 0xFF ^ 0x55 = 0xAA
    }

    @Test("ALU NOP leaves all planes unchanged")
    func aluNop() {
        let bus = Pc88Bus()
        // Enable ALU mode: evramMode=true + gamMode=true
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        bus.ioWrite(0x35, value: 0x80)  // gamMode=true, GDM=0 (ALU bit ops)

        bus.gvram[0][0] = 0x12
        bus.gvram[1][0] = 0x34
        bus.gvram[2][0] = 0x56

        // NOP for all planes: 0x11 | 0x22 | 0x44 = 0x77
        bus.aluControl1 = 0x77

        bus.memWrite(0xC000, value: 0xFF)

        #expect(bus.gvram[0][0] == 0x12)  // Blue: NOP
        #expect(bus.gvram[1][0] == 0x34)  // Red: NOP
        #expect(bus.gvram[2][0] == 0x56)  // Green: NOP
    }

    // MARK: - I/O Ports

    @Test func unmappedPortsReturn0xFF() {
        let bus = Pc88Bus()
        #expect(bus.ioRead(0x99) == 0xFF)
        #expect(bus.ioRead(0xAA) == 0xFF)
    }

    @Test func port31RomRamSwitch() {
        let bus = Pc88Bus()
        bus.n88BasicROM = Array(repeating: 0xAA, count: 32768)

        // Write port 0x31: bit1=0(ROM), bit2=0(N88-BASIC)
        bus.ioWrite(0x31, value: 0x00)
        #expect(bus.romModeN88 == true)
        #expect(bus.ramMode == false)
        #expect(bus.memRead(0x0000) == 0xAA)

        // Write port 0x31: bit1=1(RAM), bit2=0(N88)
        bus.ioWrite(0x31, value: 0x02)
        #expect(bus.ramMode == true)

        // Write port 0x31: bit1=0(ROM), bit2=1(N-BASIC)
        bus.ioWrite(0x31, value: 0x04)
        #expect(bus.ramMode == false)
        #expect(bus.romModeN88 == false)
    }

    @Test func port35GAMMode() {
        let bus = Pc88Bus()

        // Set GAM mode via port 0x35
        bus.ioWrite(0x35, value: 0x80)
        #expect(bus.gamMode == true)

        bus.ioWrite(0x35, value: 0x00)
        #expect(bus.gamMode == false)
    }

    @Test func port6ECpuClock() {
        let bus = Pc88Bus()

        bus.cpuClock8MHz = true
        #expect(bus.ioRead(0x6E) == 0x00)  // 8MHz → 0x00

        bus.cpuClock8MHz = false
        #expect(bus.ioRead(0x6E) == 0x80)  // 4MHz → bit 7 set (CPU_CLOCK_4HMZ)
    }

    @Test func port40VRTCFlag() {
        let bus = Pc88Bus()

        bus.vrtcFlag = false
        #expect(bus.ioRead(0x40) & 0x20 == 0)

        bus.vrtcFlag = true
        #expect(bus.ioRead(0x40) & 0x20 != 0)
    }

    @Test func port32SoundMaskForwarded() {
        let bus = Pc88Bus()
        let icBox = InterruptControllerBox()
        bus.interruptController = icBox

        // Set SINTM (bit 7)
        bus.ioWrite(0x32, value: 0x80)
        #expect(icBox.controller.maskSound == true)

        bus.ioWrite(0x32, value: 0x00)
        #expect(icBox.controller.maskSound == false)
    }

    @Test func portE4InterruptControl() {
        let bus = Pc88Bus()
        let icBox = InterruptControllerBox()
        bus.interruptController = icBox

        // Set threshold=3, SGS=1
        bus.ioWrite(0xE4, value: 0x0B)  // 0b00001011
        #expect(icBox.controller.levelThreshold == 7)  // SGS=1 forces threshold to 7
        #expect(icBox.controller.sgsMode == true)
    }

    @Test func portE6InterruptMask() {
        let bus = Pc88Bus()
        let icBox = InterruptControllerBox()
        bus.interruptController = icBox

        // Enable RTC and VRTC (bit=1 means enabled/unmasked)
        bus.ioWrite(0xE6, value: 0x03)
        #expect(icBox.controller.maskRTC == false)    // enabled → not masked
        #expect(icBox.controller.maskVRTC == false)   // enabled → not masked
        #expect(icBox.controller.maskRXRDY == true)   // disabled → masked
    }

    @Test func keyboardReturnsNoKeyPressed() {
        let bus = Pc88Bus()
        bus.directBasicBoot = false  // test raw keyboard, not boot mode
        for port in UInt16(0x00)...UInt16(0x0E) {
            #expect(bus.ioRead(port) == 0xFF)
        }
    }

    @Test func directBasicBootForcesStopKeyLow() {
        let bus = Pc88Bus()

        // directBasicBoot=true: port 0x09 bit 0 forced to 0 (STOP "pressed")
        bus.directBasicBoot = true
        #expect(bus.ioRead(0x09) & 0x01 == 0x00, "bit 0 must be 0 for direct BASIC boot")
        // Other keyboard rows unaffected
        #expect(bus.ioRead(0x08) == 0xFF)
        #expect(bus.ioRead(0x0A) == 0xFF)

        // directBasicBoot=false: port 0x09 returns raw keyboard (no keys = 0xFF)
        bus.directBasicBoot = false
        #expect(bus.ioRead(0x09) == 0xFF, "raw keyboard row 9 with no keys")
    }

    // MARK: - Extended RAM

    @Test("Extended RAM read/write through port 0xE2/0xE3")
    func extRAMReadWrite() {
        let bus = Pc88Bus()
        // Install 1 card × 4 banks
        let bank = Array(repeating: UInt8(0x00), count: 0x8000)
        let card = Array(repeating: bank, count: 4)
        bus.extRAM = [card]

        // Select card 0, bank 0
        bus.ioWrite(0xE3, value: 0x00)  // card=0, bank=0
        // Enable write
        bus.ioWrite(0xE2, value: 0x10)  // WREN=1

        // Write to extended RAM at 0x1000
        bus.memWrite(0x1000, value: 0xAB)

        // Disable write, enable read
        bus.ioWrite(0xE2, value: 0x01)  // RDEN=1

        // Read back
        #expect(bus.memRead(0x1000) == 0xAB)
    }

    @Test("Extended RAM bank switching")
    func extRAMBankSwitch() {
        let bus = Pc88Bus()
        let bank = Array(repeating: UInt8(0x00), count: 0x8000)
        let card = Array(repeating: bank, count: 4)
        bus.extRAM = [card]

        // Write to bank 0
        bus.ioWrite(0xE3, value: 0x00)
        bus.ioWrite(0xE2, value: 0x10)
        bus.memWrite(0x2000, value: 0x11)

        // Switch to bank 1 and write
        bus.ioWrite(0xE3, value: 0x01)
        bus.memWrite(0x2000, value: 0x22)

        // Read back bank 0
        bus.ioWrite(0xE2, value: 0x01)
        bus.ioWrite(0xE3, value: 0x00)
        #expect(bus.memRead(0x2000) == 0x11)

        // Read back bank 1
        bus.ioWrite(0xE3, value: 0x01)
        #expect(bus.memRead(0x2000) == 0x22)
    }

    @Test("Extended RAM port 0xE2 readback (inverted per QUASI88)")
    func extRAMPortReadback() {
        let bus = Pc88Bus()
        // QUASI88: ~ext_ram_ctrl | 0xEE
        bus.ioWrite(0xE2, value: 0x11)  // WREN + RDEN
        // ~0x11 = 0xEE, 0xEE | 0xEE = 0xEE
        #expect(bus.ioRead(0xE2) == 0xEE)

        bus.ioWrite(0xE2, value: 0x00)
        // ~0x00 = 0xFF, 0xFF | 0xEE = 0xFF
        #expect(bus.ioRead(0xE2) == 0xFF)

        bus.ioWrite(0xE2, value: 0x01)  // RDEN only
        // ~0x01 = 0xFE, 0xFE | 0xEE = 0xFE
        #expect(bus.ioRead(0xE2) == 0xFE)
    }

    @Test("Extended RAM card select uses bits 3-2 of port 0xE3")
    func extRAMCardSelectBits() {
        let bus = Pc88Bus()
        // Install 2 cards × 4 banks each
        let bank = Array(repeating: UInt8(0x00), count: 0x8000)
        let card = Array(repeating: bank, count: 4)
        bus.extRAM = [card, card]

        // Select card 0, bank 0 → value 0x00
        bus.ioWrite(0xE3, value: 0x00)
        bus.ioWrite(0xE2, value: 0x10)  // WREN
        bus.memWrite(0x3000, value: 0xAA)

        // Select card 1, bank 0 → bits 3-2 = 01 → value 0x04
        bus.ioWrite(0xE3, value: 0x04)
        bus.memWrite(0x3000, value: 0xBB)

        // Verify card 0, bank 0
        bus.ioWrite(0xE2, value: 0x01)  // RDEN
        bus.ioWrite(0xE3, value: 0x00)
        #expect(bus.memRead(0x3000) == 0xAA)

        // Verify card 1, bank 0
        bus.ioWrite(0xE3, value: 0x04)
        #expect(bus.memRead(0x3000) == 0xBB)
    }

    @Test("Extended RAM does not interfere when disabled")
    func extRAMDisabledNoInterference() {
        let bus = Pc88Bus()
        let bank = Array(repeating: UInt8(0x00), count: 0x8000)
        bus.extRAM = [[bank]]

        // Write to main RAM via RAM mode
        bus.ramMode = true
        bus.ioWrite(0xE2, value: 0x00)  // ExtRAM disabled
        bus.memWrite(0x1000, value: 0x55)
        #expect(bus.mainRAM[0x1000] == 0x55)

        // Reading should get main RAM, not ext RAM
        #expect(bus.memRead(0x1000) == 0x55)
    }

    // MARK: - Kanji ROM

    @Test("Kanji ROM Level 1 address set and data read")
    func kanjiROM1Read() {
        let bus = Pc88Bus()
        // Create a small kanji ROM (128KB)
        var rom = Array(repeating: UInt8(0x00), count: 0x20000)
        // Put test data at address 0x1234 * 2 = 0x2468
        rom[0x2468] = 0xAA  // left half
        rom[0x2469] = 0x55  // right half
        bus.kanjiROM1 = rom

        // Set address: low=0x34 (port 0xE8), high=0x12 (port 0xE9)
        bus.ioWrite(0xE8, value: 0x34)
        bus.ioWrite(0xE9, value: 0x12)
        #expect(bus.kanjiAddr1 == 0x1234)

        // Read left half (port 0xE9 read)
        #expect(bus.ioRead(0xE9) == 0xAA)
        // Read right half (port 0xE8 read)
        #expect(bus.ioRead(0xE8) == 0x55)
        // Address should NOT auto-increment
        #expect(bus.kanjiAddr1 == 0x1234)
    }

    @Test("Kanji ROM Level 2 address set and data read")
    func kanjiROM2Read() {
        let bus = Pc88Bus()
        // Create a small kanji ROM (128KB)
        var rom = Array(repeating: UInt8(0x00), count: 0x20000)
        // Put test data at address 0x5678 * 2 = 0xACF0
        rom[0xACF0] = 0xBB  // left half
        rom[0xACF1] = 0x66  // right half
        bus.kanjiROM2 = rom

        // Set address: low=0x78 (port 0xEC), high=0x56 (port 0xED)
        bus.ioWrite(0xEC, value: 0x78)
        bus.ioWrite(0xED, value: 0x56)
        #expect(bus.kanjiAddr2 == 0x5678)

        // Read left half (port 0xED read)
        #expect(bus.ioRead(0xED) == 0xBB)
        // Read right half (port 0xEC read)
        #expect(bus.ioRead(0xEC) == 0x66)
        // Address should NOT auto-increment
        #expect(bus.kanjiAddr2 == 0x5678)
    }

    @Test("Kanji ROM returns 0xFF when not loaded")
    func kanjiROMNotLoaded() {
        let bus = Pc88Bus()
        bus.ioWrite(0xE8, value: 0x00)
        bus.ioWrite(0xE9, value: 0x00)
        #expect(bus.ioRead(0xE9) == 0xFF)
        #expect(bus.ioRead(0xE8) == 0xFF)
    }

    // MARK: - Analog Palette

    @Test("Analog palette 512-color mode uses bit 6 selector")
    func analogPaletteWrite() {
        let bus = Pc88Bus()
        // Enable analog palette mode (port 0x32 bit 5: MISC_CTRL_ANALOG)
        bus.ioWrite(0x32, value: 0x20)
        #expect(bus.analogPalette == true)

        // Write palette entry 0: Blue=3, Red=7 (bit6=0), Green=5 (bit6=1)
        // Blue/Red write: bit6=0, bits 0-2=Blue(3), bits 3-5=Red(7) → 0b00_111_011 = 0x3B
        bus.ioWrite(0x54, value: 0x3B)
        // Green write: bit6=1, bits 0-2=Green(5) → 0b01_000_101 = 0x45
        bus.ioWrite(0x54, value: 0x45)

        #expect(bus.palette[0].b == 3)
        #expect(bus.palette[0].r == 7)
        #expect(bus.palette[0].g == 5)
    }

    @Test("Digital palette mode: 1 bit per color (bit0=B, bit1=R, bit2=G)")
    func digitalPaletteWrite() {
        let bus = Pc88Bus()
        // Ensure digital mode (port 0x32 bit 5 = 0)
        bus.ioWrite(0x32, value: 0x00)
        #expect(bus.analogPalette == false)

        // White: all bits set → 0x07 (bit0=B, bit1=R, bit2=G)
        bus.ioWrite(0x54, value: 0x07)
        #expect(bus.palette[0].b == 7)
        #expect(bus.palette[0].r == 7)
        #expect(bus.palette[0].g == 7)

        // Blue only: bit 0 = 1
        bus.ioWrite(0x55, value: 0x01)
        #expect(bus.palette[1].b == 7)
        #expect(bus.palette[1].r == 0)
        #expect(bus.palette[1].g == 0)

        // Red only: bit 1 = 1
        bus.ioWrite(0x56, value: 0x02)
        #expect(bus.palette[2].b == 0)
        #expect(bus.palette[2].r == 7)
        #expect(bus.palette[2].g == 0)

        // Green only: bit 2 = 1
        bus.ioWrite(0x57, value: 0x04)
        #expect(bus.palette[3].b == 0)
        #expect(bus.palette[3].r == 0)
        #expect(bus.palette[3].g == 7)

        // Black: no bits set
        bus.ioWrite(0x58, value: 0x00)
        #expect(bus.palette[4].b == 0)
        #expect(bus.palette[4].r == 0)
        #expect(bus.palette[4].g == 0)
    }

    // MARK: - VRAM WAIT

    @Test("GVRAM read 8MHz active+graphOn = +5T")
    func gvramReadWait() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.gvramPlane = 0  // Blue plane
        bus.vrtcFlag = false  // Active display
        bus.graphicsDisplayEnabled = true

        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 5)

        _ = bus.memRead(0xC001)
        #expect(bus.pendingWaitStates == 10)
    }

    @Test("GVRAM read 8MHz VRTC = +3T")
    func gvramReadNoWaitDuringVRTC() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.gvramPlane = 0
        bus.vrtcFlag = true

        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 3)
    }

    @Test("GVRAM write 8MHz active+graphOn = +5T")
    func gvramWriteWait() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.gvramPlane = 0
        bus.vrtcFlag = false
        bus.graphicsDisplayEnabled = true

        bus.memWrite(0xC000, value: 0xFF)
        #expect(bus.pendingWaitStates == 5)
    }

    @Test("Main RAM at 0xC000 8MHz = +1T wait")
    func mainRAMWait8MHz() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.gamMode = false
        bus.gvramPlane = -1
        bus.vrtcFlag = false

        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 1)
    }

    @Test("Main RAM at 0xC000 4MHz = no wait")
    func mainRAMNoWait4MHz() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = false
        bus.gamMode = false
        bus.gvramPlane = -1
        bus.vrtcFlag = false

        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 0)
    }

    // MARK: - Reset

    @Test func resetClearsState() {
        let bus = Pc88Bus()
        bus.mainRAM[0x8400] = 0x42
        bus.gamMode = true
        bus.ramMode = true
        bus.gvramPlane = 2
        bus.extRAMWriteEnable = true
        bus.kanjiAddr1 = 0x1234

        bus.reset()

        // reset() re-initializes RAM with power-on pattern (not necessarily 0x00)
        #expect(bus.mainRAM[0x8400] != 0x42)  // custom value overwritten
        #expect(bus.gamMode == false)
        #expect(bus.ramMode == false)
        #expect(bus.gvramPlane == -1)
        #expect(bus.extRAMWriteEnable == false)
        #expect(bus.extRAMReadEnable == false)
        #expect(bus.kanjiAddr1 == 0)
    }

    // MARK: - DIP Switch 2 (Bootstrap)

    @Test("DIP switch 2 has bootstrap disabled by default")
    func dipSwitch2BootstrapDisabled() {
        let bus = Pc88Bus()
        let dip2 = bus.ioRead(0x31)
        #expect(dip2 & 0x40 != 0)  // bit 6 = 1 → bootstrap disabled
    }

    @Test("DIP switch 2 default matches QUASI88/BubiC base 0x39 | H")
    func dipSwitch2DisplayDefaults() {
        let bus = Pc88Bus()
        let dip2 = bus.ioRead(0x31)
        // Default dipSw2=0x71: base 0x31 | H(0x40), FDD boot (bit3=0)
        #expect(dip2 == 0x71)
    }

    // MARK: - USART (uPD8251C)

    @Test("USART data port returns 0x00")
    func usartDataPort() {
        let bus = Pc88Bus()
        #expect(bus.ioRead(0x20) == 0x00)
    }

    @Test("USART status port returns TxRDY and TxE set, RxRDY clear")
    func usartStatusPort() {
        let bus = Pc88Bus()
        let status = bus.ioRead(0x21)
        #expect(status & 0x01 != 0)  // TxRDY = 1
        #expect(status & 0x04 != 0)  // TxE = 1
        #expect(status & 0x02 == 0)  // RxRDY = 0
    }

    // MARK: - Port 0x40 Control Signals

    @Test("Port 0x40 has bits 7-6 and bit 2 always set")
    func port40ControlSignals() {
        let bus = Pc88Bus()
        let value = bus.ioRead(0x40)
        #expect(value & 0xC4 == 0xC4)  // bits 7-6 and bit 2 always 1
    }

    // MARK: - Text Window (0x8000-0x83FF → textVRAM)

    @Test func textWindowReadWrite() {
        let bus = Pc88Bus()
        bus.textWindowOffset = 0

        // CPU ウィンドウ経由で書き込み → mainRAM[0x0000], mainRAM[0x03FF]
        bus.memWrite(0x8000, value: 0xAA)
        bus.memWrite(0x83FF, value: 0xBB)

        // 同じウィンドウ経由で読み戻し
        #expect(bus.memRead(0x8000) == 0xAA)
        #expect(bus.memRead(0x83FF) == 0xBB)

        // mainRAM のマッピング先に値が書かれている
        #expect(bus.mainRAM[0x0000] == 0xAA)
        #expect(bus.mainRAM[0x03FF] == 0xBB)
    }

    @Test func textWindowOffsetMapsToCorrectAddr() {
        let bus = Pc88Bus()
        bus.textWindowOffset = 1

        // ウィンドウ経由の書き込み → mainRAM[(1<<8) + 0] = mainRAM[0x0100]
        bus.memWrite(0x8000, value: 0xCC)
        #expect(bus.mainRAM[0x0100] == 0xCC)

        // オフセット 0 は変更されていない
        #expect(bus.mainRAM[0x0000] != 0xCC)

        // ウィンドウ経由の読み戻し
        #expect(bus.memRead(0x8000) == 0xCC)
    }

    @Test func textWindowHighMemoryUsesMainRAMShadow() {
        let bus = Pc88Bus()
        bus.textWindowOffset = 0xF3
        bus.tvramEnabled = true

        bus.memWrite(0x80C8, value: 0x4C)

        #expect(bus.mainRAM[0xF3C8] == 0x4C)
        #expect(bus.tvram[0x03C8] == 0x00)
        #expect(bus.memRead(0x80C8) == 0x4C)
    }

    @Test func textWindowDisabledWhenRamMode() {
        let bus = Pc88Bus()
        bus.ramMode = true  // MMODE=1 → text window disabled
        bus.romModeN88 = true

        // Write at 0x8000 → should go to mainRAM[0x8000] directly (no offset remap)
        bus.memWrite(0x8000, value: 0xDD)
        #expect(bus.mainRAM[0x8000] == 0xDD)

        // Read at 0x8000 → should come from mainRAM[0x8000]
        #expect(bus.memRead(0x8000) == 0xDD)
    }

    @Test func textWindowDisabledWhenNBasicROM() {
        let bus = Pc88Bus()
        bus.ramMode = false
        bus.romModeN88 = false  // RMODE=1 (N-BASIC) → text window disabled

        // Write at 0x8000 → should go to mainRAM[0x8000] directly
        bus.memWrite(0x8000, value: 0xEE)
        #expect(bus.mainRAM[0x8000] == 0xEE)

        // Read at 0x8000 → should come from mainRAM[0x8000]
        #expect(bus.memRead(0x8000) == 0xEE)
    }

    // MARK: - Text Display Enabled

    @Test func textDisplayEnabledRequiresDMACount() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc

        // 初期状態: DMAカウント=0 → disabled
        #expect(bus.textDisplayEnabled == false)

        // DMA ch2 カウント設定 → enabled (現行 BubiC 互換: カウント>0のみ)
        configureTextDMARead(dma, crtc: crtc)
        #expect(bus.textDisplayEnabled == true)

        // DMA ch2 カウント=0 → disabled
        dma.channels[2].count = 0
        #expect(bus.textDisplayEnabled == false)
    }

    // MARK: - Port 0x30 Write

    @Test("Port 0x30 write: bit 0 = 80col, bit 1 = mono")
    func port30WriteColumnAndColor() {
        let bus = Pc88Bus()

        // bit0=1, bit1=0 → 80 columns, color mode
        bus.ioWrite(0x30, value: 0x01)
        #expect(bus.columns80 == true)
        #expect(bus.colorMode == true)

        // bit0=0, bit1=0 → 40 columns, color mode
        bus.ioWrite(0x30, value: 0x00)
        #expect(bus.columns80 == false)
        #expect(bus.colorMode == true)

        // bit0=1, bit1=1 → 80 columns, mono mode
        bus.ioWrite(0x30, value: 0x03)
        #expect(bus.columns80 == true)
        #expect(bus.colorMode == false)
    }

    // MARK: - Port 0x71 Ext ROM

    @Test("Port 0x71 bit 0 controls extROMEnabled (active low)")
    func port71ExtROMControl() {
        let bus = Pc88Bus()

        // Default: extROMBank=0xFF → bit 0=1 → extROM disabled
        #expect(bus.extROMEnabled == false)

        // Write 0x00 → bit 0=0 → extROM enabled
        bus.ioWrite(0x71, value: 0x00)
        #expect(bus.extROMEnabled == true)

        // Write 0x01 → bit 0=1 → extROM disabled
        bus.ioWrite(0x71, value: 0x01)
        #expect(bus.extROMEnabled == false)
    }

    @Test("Port 0x71 external ROM select bits return open bus when no board is emulated")
    func port71ExternalROMSelectionReturnsOpenBus() {
        let bus = Pc88Bus()

        var rom = Array(repeating: UInt8(0x11), count: 0x8000)
        rom[0x6000] = 0x22
        bus.n88BasicROM = rom

        bus.n88ExtROM = [
            Array(repeating: 0x33, count: 0x2000),
            Array(repeating: 0x44, count: 0x2000),
            Array(repeating: 0x55, count: 0x2000),
            Array(repeating: 0x66, count: 0x2000),
        ]
        bus.ioWrite(0x32, value: 0x00)  // bank 0

        // Internal ext ROM selected
        bus.ioWrite(0x71, value: 0xFE)
        #expect(bus.memRead(0x6000) == 0x33)

        // External slot selected (bit 2 low), internal ROM disabled
        bus.ioWrite(0x71, value: 0xFB)
        #expect(bus.memRead(0x6000) == 0xFF)

        // Normal ROM mapping resumes when no ext ROM is selected
        bus.ioWrite(0x71, value: 0xFF)
        #expect(bus.memRead(0x6000) == 0x22)
    }

    // MARK: - Port 0x5C Read

    @Test("Port 0x5C returns one-hot bitmask | 0xF8 (QUASI88/BubiC compatible)")
    func port5CReadMemoryBank() {
        let bus = Pc88Bus()

        // Blue plane → 0xF9 (bit 0 set)
        bus.ioWrite(0x5C, value: 0x00)
        #expect(bus.ioRead(0x5C) == 0xF9)

        // Red plane → 0xFA (bit 1 set)
        bus.ioWrite(0x5D, value: 0x00)
        #expect(bus.ioRead(0x5C) == 0xFA)

        // Green plane → 0xFC (bit 2 set)
        bus.ioWrite(0x5E, value: 0x00)
        #expect(bus.ioRead(0x5C) == 0xFC)

        // Main RAM → 0xF8 (no low bits set)
        bus.ioWrite(0x5F, value: 0x00)
        #expect(bus.ioRead(0x5C) == 0xF8)
    }

    // MARK: - DIP SW1

    @Test("DIP switch 1 has bits 7-6 always set")
    func dipSwitch1AlwaysSetBits76() {
        let bus = Pc88Bus()
        let value = bus.ioRead(0x30)
        #expect(value & 0xC0 == 0xC0)  // bits 7-6 always 1
    }

    // MARK: - I/O Trace Callback

    // MARK: - ALU Read/Write Modes

    @Test("ALU read loads aluReg and returns comparison result")
    func aluReadLoadsRegsAndCompares() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        // gamMode=true, compare bits: B=1, R=1, G=1 (non-inverted)
        bus.ioWrite(0x35, value: 0x87)  // 0x80 | 0x07

        bus.gvram[0][0x100] = 0xAA  // Blue
        bus.gvram[1][0x100] = 0xBB  // Red
        bus.gvram[2][0x100] = 0xCC  // Green

        let result = bus.memRead(0xC100)

        // aluReg should be loaded
        #expect(bus.aluReg[0] == 0xAA)
        #expect(bus.aluReg[1] == 0xBB)
        #expect(bus.aluReg[2] == 0xCC)

        // Compare: all bits non-inverted → B & R & G
        #expect(result == (0xAA & 0xBB & 0xCC))
    }

    @Test("ALU read with inversion bits (compare data 0x00)")
    func aluReadWithInversion() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        // gamMode=true, compare bits: 0x00 → all inverted
        bus.ioWrite(0x35, value: 0x80)

        bus.gvram[0][0] = 0xF0  // Blue
        bus.gvram[1][0] = 0xFF  // Red
        bus.gvram[2][0] = 0x0F  // Green

        let result = bus.memRead(0xC000)

        // All inverted: ~0xF0 & ~0xFF & ~0x0F = 0x0F & 0x00 & 0xF0 = 0x00
        #expect(result == 0x00)
    }

    @Test("GDM=1: aluReg write-back to all 3 planes")
    func gdm1WriteBackAllPlanes() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        // gamMode=true, GDM=1 (bits 5-4 = 01)
        bus.ioWrite(0x35, value: 0x90)

        // Pre-load aluReg via ALU read
        bus.aluReg[0] = 0x11
        bus.aluReg[1] = 0x22
        bus.aluReg[2] = 0x33

        // Write triggers GDM=1 write-back
        bus.memWrite(0xC000, value: 0xFF)  // value is ignored for GDM=1

        #expect(bus.gvram[0][0] == 0x11)  // Blue = aluReg[0]
        #expect(bus.gvram[1][0] == 0x22)  // Red = aluReg[1]
        #expect(bus.gvram[2][0] == 0x33)  // Green = aluReg[2]
    }

    @Test("GDM=2: aluReg[1] (Red) → Blue plane cross-copy")
    func gdm2CrossPlaneRedToBlue() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        // gamMode=true, GDM=2 (bits 5-4 = 10)
        bus.ioWrite(0x35, value: 0xA0)

        bus.aluReg[1] = 0x55  // Red register

        bus.memWrite(0xC000, value: 0xFF)

        #expect(bus.gvram[0][0] == 0x55)  // Blue = aluReg[1] (Red)
    }

    @Test("GDM=3: aluReg[0] (Blue) → Red plane cross-copy")
    func gdm3CrossPlaneBlueToRed() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        // gamMode=true, GDM=3 (bits 5-4 = 11)
        bus.ioWrite(0x35, value: 0xB0)

        bus.aluReg[0] = 0x77  // Blue register

        bus.memWrite(0xC000, value: 0xFF)

        #expect(bus.gvram[1][0] == 0x77)  // Red = aluReg[0] (Blue)
    }

    @Test("evramMode=true + gamMode=false → mainRAM access")
    func evramModeNoGamReadsMainRAM() {
        let bus = Pc88Bus()
        bus.ioWrite(0x32, value: 0x40)  // evramMode=true
        bus.ioWrite(0x35, value: 0x00)  // gamMode=false

        bus.mainRAM[0xC000] = 0xAB
        #expect(bus.memRead(0xC000) == 0xAB)

        bus.memWrite(0xC000, value: 0xCD)
        #expect(bus.mainRAM[0xC000] == 0xCD)
    }

    @Test("evramMode entry resets gvramPlane to mainRAM (QUASI88 compatible)")
    func evramModeResetsGvramPlane() {
        let bus = Pc88Bus()

        // Select Green plane via port 0x5E
        bus.ioWrite(0x5E, value: 0x00)
        #expect(bus.gvramPlane == 2)

        // Enable evramMode via port 0x32 bit 6 → gvramPlane reset to -1
        bus.ioWrite(0x32, value: 0x40)
        #expect(bus.evramMode == true)
        #expect(bus.gvramPlane == -1)
    }

    @Test("evramMode=false does not reset gvramPlane")
    func evramModeOffKeepsGvramPlane() {
        let bus = Pc88Bus()

        // Select Red plane
        bus.ioWrite(0x5D, value: 0x00)
        #expect(bus.gvramPlane == 1)

        // Write port 0x32 without evramMode bit → gvramPlane unchanged
        bus.ioWrite(0x32, value: 0x00)
        #expect(bus.evramMode == false)
        #expect(bus.gvramPlane == 1)
    }

    // MARK: - Port 0x53 Layer Control

    @Test("Port 0x53 bit 0 hides text in color mode and becomes attribute-only in mono mode")
    func port53TextSuppress() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc

        // Enable text display with a complete DMA transfer
        configureTextDMARead(dma, crtc: crtc)
        bus.performTextDMATransfer()
        #expect(bus.textDisplayEnabled == true)
        #expect(bus.textDisplayMode == .enabled)

        // Set port 0x53 bit 0 in color mode → text suppressed
        bus.ioWrite(0x31, value: 0x18)  // graphicsColorMode=true
        bus.ioWrite(0x53, value: 0x01)
        #expect(bus.textDisplayEnabled == false)
        #expect(bus.textDisplayMode == .disabled)

        // Clear port 0x53 → text visible again
        bus.ioWrite(0x53, value: 0x00)
        #expect(bus.textDisplayEnabled == true)
        #expect(bus.textDisplayMode == .enabled)

        // port 0x53 bit 0 in mono mode → glyphs hidden, attributes still active
        bus.ioWrite(0x31, value: 0x08)  // graphicsColorMode=false (mono)
        bus.ioWrite(0x53, value: 0x01)
        #expect(bus.textDisplayEnabled == false)
        #expect(bus.textDisplayMode == .attributesOnly)
    }

    @Test("Port 0x53 bits 1-3 suppress GVRAM planes in mono mode")
    func port53GVRAMPlaneSuppressMonoMode() {
        let bus = Pc88Bus()
        // Set mono mode (GRPH_CTRL_COLOR=0) — Port 0x53 plane suppress only works in mono mode
        bus.ioWrite(0x31, value: 0x08)  // bit 3=1 (display on), bit 4=0 (mono)

        // Write test data to all planes
        bus.gvram[0][0] = 0xAA  // Blue
        bus.gvram[1][0] = 0xBB  // Red
        bus.gvram[2][0] = 0xCC  // Green

        // No suppress — all planes visible
        bus.ioWrite(0x53, value: 0x00)
        var planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0xAA)
        #expect(planes.red[0] == 0xBB)
        #expect(planes.green[0] == 0xCC)

        // Suppress Blue (bit 1)
        bus.ioWrite(0x53, value: 0x02)
        planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0x00)
        #expect(planes.red[0] == 0xBB)
        #expect(planes.green[0] == 0xCC)

        // Suppress all GVRAM planes
        bus.ioWrite(0x53, value: 0x0E)
        planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0x00)
        #expect(planes.red[0] == 0x00)
        #expect(planes.green[0] == 0x00)
    }

    @Test("Port 0x53 bits 1-3 ignored in color mode (BubiC confirmed)")
    func port53GVRAMSuppressIgnoredInColorMode() {
        let bus = Pc88Bus()
        // Set color mode (GRPH_CTRL_COLOR=1) — default
        bus.ioWrite(0x31, value: 0x18)  // bit 3=1 (display on), bit 4=1 (color)

        bus.gvram[0][0] = 0xAA
        bus.gvram[1][0] = 0xBB
        bus.gvram[2][0] = 0xCC

        // Set all plane suppress bits — should be ignored in color mode
        bus.ioWrite(0x53, value: 0x0E)
        let planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0xAA)   // NOT suppressed
        #expect(planes.red[0] == 0xBB)    // NOT suppressed
        #expect(planes.green[0] == 0xCC)  // NOT suppressed
    }

    @Test("Port 0x31 bit 3 (GRPH_CTRL_VDISP) hides all graphics")
    func port31GraphicsDisplayEnable() {
        let bus = Pc88Bus()
        bus.gvram[0][0] = 0xAA
        bus.gvram[1][0] = 0xBB
        bus.gvram[2][0] = 0xCC

        // Graphics display enabled (bit 3 = 1)
        bus.ioWrite(0x31, value: 0x18)  // bit 3=1, bit 4=1 (color)
        var planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0xAA)
        #expect(planes.red[0] == 0xBB)
        #expect(planes.green[0] == 0xCC)

        // Graphics display disabled (bit 3 = 0)
        bus.ioWrite(0x31, value: 0x10)  // bit 3=0
        planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0x00)
        #expect(planes.red[0] == 0x00)
        #expect(planes.green[0] == 0x00)

        // Re-enable
        bus.ioWrite(0x31, value: 0x18)
        planes = bus.renderGVRAMPlanes()
        #expect(planes.blue[0] == 0xAA)
    }

    // MARK: - I/O Trace Callback

    @Test("I/O trace callback fires on read and write")
    func ioTraceCallback() {
        let bus = Pc88Bus()
        var traces: [(port: UInt16, value: UInt8, isWrite: Bool)] = []
        bus.onIOAccess = { port, value, isWrite in
            traces.append((port: port, value: value, isWrite: isWrite))
        }

        _ = bus.ioRead(0x40)
        bus.ioWrite(0x5C, value: 0x00)

        #expect(traces.count == 2)
        #expect(traces[0].port == 0x40)
        #expect(traces[0].isWrite == false)
        #expect(traces[1].port == 0x5C)
        #expect(traces[1].isWrite == true)
    }

    // MARK: - 8MHz Memory Wait States

    @Test func mainRAMReadWait8MHz() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.ramMode = true  // ensure mainRAM path

        bus.pendingWaitStates = 0
        _ = bus.memRead(0x4000)
        #expect(bus.pendingWaitStates == 1)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0x8000)
        #expect(bus.pendingWaitStates == 1)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xA000)
        #expect(bus.pendingWaitStates == 1)
    }

    @Test func mainRAMWriteWait8MHz() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.ramMode = true

        bus.pendingWaitStates = 0
        bus.memWrite(0x4000, value: 0xAA)
        #expect(bus.pendingWaitStates == 1)

        bus.pendingWaitStates = 0
        bus.memWrite(0x8200, value: 0xBB)
        #expect(bus.pendingWaitStates == 1)

        bus.pendingWaitStates = 0
        bus.memWrite(0x9000, value: 0xCC)
        #expect(bus.pendingWaitStates == 1)
    }

    @Test func mainRAMNoWait4MHzLowArea() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = false
        bus.ramMode = true

        bus.pendingWaitStates = 0
        _ = bus.memRead(0x4000)
        #expect(bus.pendingWaitStates == 0)

        bus.pendingWaitStates = 0
        bus.memWrite(0x4000, value: 0xAA)
        #expect(bus.pendingWaitStates == 0)
    }

    // MARK: - GVRAM Wait States (BubiC V1H/V2)

    @Test func gvramWait8MHzActiveGraphOn() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.vrtcFlag = false
        bus.graphicsDisplayEnabled = true
        // Independent mode: select blue plane
        bus.ioWrite(0x5C, value: 0x00)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 5)

        bus.pendingWaitStates = 0
        bus.memWrite(0xC000, value: 0xFF)
        #expect(bus.pendingWaitStates == 5)
    }

    @Test func gvramWait8MHzVBlank() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.vrtcFlag = true
        bus.graphicsDisplayEnabled = true
        bus.ioWrite(0x5C, value: 0x00)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 3)

        bus.pendingWaitStates = 0
        bus.memWrite(0xC000, value: 0xFF)
        #expect(bus.pendingWaitStates == 3)
    }

    @Test func gvramWait8MHzGraphOff() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = true
        bus.vrtcFlag = false
        bus.graphicsDisplayEnabled = false
        bus.ioWrite(0x5C, value: 0x00)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 3)

        bus.pendingWaitStates = 0
        bus.memWrite(0xC000, value: 0xFF)
        #expect(bus.pendingWaitStates == 3)
    }

    @Test func gvramWait4MHzActiveGraphOn() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = false
        bus.vrtcFlag = false
        bus.graphicsDisplayEnabled = true
        bus.ioWrite(0x5C, value: 0x00)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 2)

        bus.pendingWaitStates = 0
        bus.memWrite(0xC000, value: 0xFF)
        #expect(bus.pendingWaitStates == 2)
    }

    @Test func gvramWait4MHzVBlank() {
        let bus = Pc88Bus()
        bus.cpuClock8MHz = false
        bus.vrtcFlag = true
        bus.graphicsDisplayEnabled = true
        bus.ioWrite(0x5C, value: 0x00)

        bus.pendingWaitStates = 0
        _ = bus.memRead(0xC000)
        #expect(bus.pendingWaitStates == 0)
    }

    // MARK: - High-Speed Text RAM (tvram)

    @Test func tvramReadWrite() {
        let bus = Pc88Bus()
        bus.tvramEnabled = true
        bus.ramMode = true  // mainRAM path for 0xC000+ (no GVRAM plane selected)
        bus.gvramPlane = -1

        // Write to tvram range
        bus.memWrite(0xF000, value: 0xAA)
        bus.memWrite(0xF100, value: 0xBB)
        bus.memWrite(0xFFFF, value: 0xCC)

        // Read back from tvram
        #expect(bus.memRead(0xF000) == 0xAA)
        #expect(bus.memRead(0xF100) == 0xBB)
        #expect(bus.memRead(0xFFFF) == 0xCC)

        // tvram writes do NOT mirror to mainRAM (would clobber work area)
        #expect(bus.mainRAM[0xF000] == 0x00)
        #expect(bus.mainRAM[0xF100] == 0x00)
        #expect(bus.mainRAM[0xFFFF] == 0x00)
    }

    @Test func tvramDisabledUsesMainRAM() {
        let bus = Pc88Bus()
        bus.tvramEnabled = false
        bus.ramMode = true
        bus.gvramPlane = -1

        bus.memWrite(0xF000, value: 0xDD)
        #expect(bus.mainRAM[0xF000] == 0xDD)
        #expect(bus.tvram[0] == 0x00)  // tvram untouched
    }

    @Test func tvramWaitStates() {
        let bus = Pc88Bus()
        bus.tvramEnabled = true
        bus.cpuClock8MHz = true
        bus.ramMode = true
        bus.gvramPlane = -1

        // tvram read: +2T
        bus.pendingWaitStates = 0
        _ = bus.memRead(0xF000)
        #expect(bus.pendingWaitStates == 2)

        // tvram write: +1T
        bus.pendingWaitStates = 0
        bus.memWrite(0xF000, value: 0x42)
        #expect(bus.pendingWaitStates == 1)
    }

    @Test func tvramBelowF000UsesMainRAM() {
        let bus = Pc88Bus()
        bus.tvramEnabled = true
        bus.ramMode = true
        bus.gvramPlane = -1
        bus.cpuClock8MHz = true

        // 0xEFFF should go to mainRAM, not tvram
        bus.memWrite(0xEFFF, value: 0x55)
        #expect(bus.mainRAM[0xEFFF] == 0x55)
        // mainRAM wait = +1T
        bus.pendingWaitStates = 0
        _ = bus.memRead(0xEFFF)
        #expect(bus.pendingWaitStates == 1)
    }

    @Test func port32TMODEControl() {
        let bus = Pc88Bus()

        // TMODE=0 (bit 4 clear) → tvramEnabled=true
        bus.ioWrite(0x32, value: 0x00)
        #expect(bus.tvramEnabled == true)

        // TMODE=1 (bit 4 set) → tvramEnabled=false
        bus.ioWrite(0x32, value: 0x10)
        #expect(bus.tvramEnabled == false)

        // Other bits don't affect tvramEnabled
        bus.ioWrite(0x32, value: 0xEF)  // bit 4 clear
        #expect(bus.tvramEnabled == true)
    }

    @Test func tvramDMARead() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        // Configure DMA channel 2 to read from 0xF000
        dma.channels[2].address = 0xF000
        crtc.charsPerLine = 2
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 1
        crtc.attrNonTransparent = false
        configureTextDMARead(dma, crtc: crtc)
        bus.ioWrite(0x32, value: 0x10)  // TMODE=1 → CPU sees mainRAM, DMA still reads TVRAM

        // Write to tvram
        bus.tvram[0] = 0x41  // 'A'
        bus.tvram[1] = 0x42  // 'B'
        // Ensure mainRAM has different data
        bus.mainRAM[0xF000] = 0xFF
        bus.mainRAM[0xF001] = 0xFF

        bus.performTextDMATransfer()

        let text = bus.readTextVRAM()
        #expect(text[0] == 0x41)
        #expect(text[1] == 0x42)
    }

    // MARK: - DMA Buffer Tests

    @Test("DMA transfer fills CRTC buffer and readTextVRAM reads from it")
    func dmaBufferTransferAndRead() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        // Configure: 4 chars/line, 1 row, 1 attr pair, transparent mode
        crtc.charsPerLine = 4
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 1
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc)

        // Write text data to RAM at DMA source address
        // Row stride = charsPerLine + attrsPerLine*2 = 4 + 2 = 6
        bus.mainRAM[0x8000] = 0x41  // 'A'
        bus.mainRAM[0x8001] = 0x42  // 'B'
        bus.mainRAM[0x8002] = 0x43  // 'C'
        bus.mainRAM[0x8003] = 0x44  // 'D'

        // Perform DMA transfer
        bus.performTextDMATransfer()

        // Read from buffer
        let text = bus.readTextVRAM()
        #expect(text[0] == 0x41)
        #expect(text[1] == 0x42)
        #expect(text[2] == 0x43)
        #expect(text[3] == 0x44)
        #expect(crtc.dmaUnderrun == false)
    }

    @Test("DMA ch2 count=0 causes no transfer")
    func dmaZeroCountNoTransfer() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        dma.channels[2].count = 0
        dma.channels[2].enabled = true

        bus.performTextDMATransfer()

        #expect(crtc.dmaBufferPtr == 0)
        #expect(bus.textDisplayEnabled == false)
    }

    @Test("CRTC Reset clears DMA buffer and causes underrun")
    func crtcResetClearsBuffer() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc)
        bus.mainRAM[0x8000] = 0x41

        // Fill buffer
        bus.performTextDMATransfer()
        #expect(crtc.dmaUnderrun == false)

        // CRTC Reset → buffer cleared, underrun
        crtc.writeCommand(0x00)
        crtc.writeParameter(0x4E)
        crtc.writeParameter(0x18)
        crtc.writeParameter(0x07)
        crtc.writeParameter(0x20)
        crtc.writeParameter(0x93)
        #expect(crtc.dmaUnderrun == true)
        #expect(crtc.dmaBufferPtr == 0)
    }

    @Test("DMA ch2 count>0 transfers even in non-read mode (current BubiC-compatible behavior)")
    func dmaAnyModeTransfers() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        crtc.charsPerLine = 1
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 0
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        dma.channels[2].mode = 0b01  // non-read mode
        dma.channels[2].count = 1
        dma.channels[2].enabled = true
        bus.mainRAM[0x8000] = 0x41

        bus.performTextDMATransfer()

        #expect(crtc.dmaBufferPtr > 0)
        #expect(crtc.dmaUnderrun == false)
    }

    @Test("Short DMA count triggers underrun")
    func dmaShortCountUnderrun() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        crtc.charsPerLine = 4
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 1
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc, bytes: 3)
        bus.mainRAM[0x8000] = 0x41
        bus.mainRAM[0x8001] = 0x42
        bus.mainRAM[0x8002] = 0x43
        bus.mainRAM[0x8003] = 0x44

        bus.performTextDMATransfer()

        let text = bus.readTextVRAM()
        #expect(text[0] == 0x41)
        #expect(text[1] == 0x42)
        #expect(text[2] == 0x43)
        #expect(text[3] == 0x00)
        #expect(crtc.dmaUnderrun == true)
        // dmaUnderrun no longer disables text display (QUASI88 compatible)
        #expect(bus.textDisplayMode == .enabled)
        #expect(bus.textDisplayEnabled == true)
    }

    @Test("Reverse display seeds default text attributes")
    func reverseDisplaySeedsDefaultAttributes() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        crtc.charsPerLine = 1
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 0
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc, bytes: 1)
        bus.mainRAM[0x8000] = 0x41
        crtc.writeCommand(0x21)

        bus.performTextDMATransfer()

        let attrs = bus.readTextAttributes()
        // defaultAttr=0xE0. QUASI88 reverse XOR applied (graphicsColorMode=true default).
        // 0xE0 ^ 0x01 = 0xE1
        #expect(attrs[0] == 0xE1)
    }

    @Test("readDMABuffer past end does not set dmaUnderrun")
    func readDMABufferNoSideEffect() {
        let crtc = CRTC()
        crtc.startDMATransfer()
        crtc.writeDMABuffer(0x41)
        crtc.dmaUnderrun = false

        #expect(crtc.readDMABuffer(at: 7) == 0x00)
        #expect(crtc.dmaUnderrun == false)
    }

    @Test("Complete text DMA keeps overlay enabled (Misty Blue opening compatible)")
    func mistyBlueCompatibleTextDisplayState() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        let dma = DMAController()
        bus.crtc = crtc
        bus.dma = dma

        dma.channels[2].address = 0xF000
        configureTextDMARead(dma, crtc: crtc)
        bus.layerControl = 0x00

        bus.performTextDMATransfer()

        #expect(crtc.dmaUnderrun == false)
        #expect(bus.textDisplayMode == .enabled)
        #expect(bus.textDisplayEnabled == true)
    }

    // MARK: - CMT High-Speed Load (Hudson / QUASI88 compatible)

    /// Assembles a tape image in the Hudson fast-load format: an optional
    /// prefix, then `0x3A` + addr_H + addr_L + header checksum, followed
    /// by one or more data blocks (`0x3A` + size + bytes + block checksum)
    /// and a final `0x3A, 0x00` terminator. Checksums are chosen so each
    /// group sums to 0 mod 256.
    private func makeHudsonTape(
        prefix: [UInt8] = [],
        loadAddr: UInt16,
        blocks: [[UInt8]]
    ) -> [UInt8] {
        var out = prefix
        out.append(0x3A)
        let aH = UInt8(loadAddr >> 8)
        let aL = UInt8(loadAddr & 0xFF)
        out.append(aH)
        out.append(aL)
        out.append(UInt8((0x100 &- (Int(aH) + Int(aL))) & 0xFF))
        for data in blocks {
            out.append(0x3A)
            let size = UInt8(data.count)
            out.append(size)
            out.append(contentsOf: data)
            var sum = Int(size)
            for b in data { sum += Int(b) }
            out.append(UInt8((0x100 &- sum) & 0xFF))
        }
        // Terminator: 0x3A + size==0.
        out.append(0x3A)
        out.append(0x00)
        return out
    }

    @Test("Port 0x00 write triggers Hudson fast-load into RAM")
    func highSpeedLoadCopiesBlocksToRAM() {
        let bus = Pc88Bus()
        let usart = I8251()
        let deck = CassetteDeck(usart: usart)
        bus.usart = usart
        bus.cassette = deck
        let tape = makeHudsonTape(
            loadAddr: 0xBA00,
            blocks: [[0x11, 0x22, 0x33], [0x44, 0x55]]
        )
        deck.load(data: Data(tape))

        bus.ioWrite(0x0000, value: 0x00)

        #expect(bus.memRead(0xBA00) == 0x11)
        #expect(bus.memRead(0xBA01) == 0x22)
        #expect(bus.memRead(0xBA02) == 0x33)
        #expect(bus.memRead(0xBA03) == 0x44)
        #expect(bus.memRead(0xBA04) == 0x55)
    }

    @Test("Fast-load skips junk bytes before the 0x3A marker")
    func highSpeedLoadSkipsPrefix() {
        let bus = Pc88Bus()
        let usart = I8251()
        let deck = CassetteDeck(usart: usart)
        bus.usart = usart
        bus.cassette = deck
        let tape = makeHudsonTape(
            prefix: [0xFF, 0xAA, 0x55, 0x00, 0xD3, 0xD3, 0xD3],
            loadAddr: 0xC100,
            blocks: [[0xDE, 0xAD]]
        )
        deck.load(data: Data(tape))

        bus.ioWrite(0x0000, value: 0x00)

        #expect(bus.memRead(0xC100) == 0xDE)
        #expect(bus.memRead(0xC101) == 0xAD)
    }

    @Test("Fast-load aborts on bad header checksum without writing RAM")
    func highSpeedLoadAbortsOnBadHeaderChecksum() {
        let bus = Pc88Bus()
        let usart = I8251()
        let deck = CassetteDeck(usart: usart)
        bus.usart = usart
        bus.cassette = deck
        // Valid tape, then corrupt the header checksum byte.
        var tape = makeHudsonTape(loadAddr: 0xD000, blocks: [[0xEE]])
        tape[3] ^= 0x01  // break (aH + aL + chk) == 0 mod 256
        deck.load(data: Data(tape))

        bus.ioWrite(0x0000, value: 0x00)

        #expect(bus.memRead(0xD000) == 0x00)  // RAM untouched
    }

    @Test("Fast-load aborts on bad block checksum and leaves later blocks alone")
    func highSpeedLoadAbortsOnBadBlockChecksum() {
        let bus = Pc88Bus()
        let usart = I8251()
        let deck = CassetteDeck(usart: usart)
        bus.usart = usart
        bus.cassette = deck
        // Two blocks; corrupt the first block's checksum. First block's
        // bytes get copied, then loader aborts before the second.
        var tape = makeHudsonTape(
            loadAddr: 0xE000,
            blocks: [[0x01, 0x02], [0xAA, 0xBB]]
        )
        // Layout: [0x3A][aH][aL][hChk][0x3A][size=2][0x01][0x02][bChk]...
        // Index of first bChk = 8.
        tape[8] ^= 0x55
        deck.load(data: Data(tape))

        bus.ioWrite(0x0000, value: 0x00)

        // First block's data still reaches RAM (written as we go).
        #expect(bus.memRead(0xE000) == 0x01)
        #expect(bus.memRead(0xE001) == 0x02)
        // Second block never starts: 0xE002+ stays at the RAM init value.
        #expect(bus.memRead(0xE002) == 0x00)
        #expect(bus.memRead(0xE003) == 0x00)
    }

    @Test("Fast-load without any tape loaded is a silent no-op")
    func highSpeedLoadNoOpWithoutTape() {
        let bus = Pc88Bus()
        // No CassetteDeck attached — must not crash.
        bus.ioWrite(0x0000, value: 0x00)

        // With deck attached but nothing loaded.
        let usart = I8251()
        let deck = CassetteDeck(usart: usart)
        bus.usart = usart
        bus.cassette = deck
        bus.ioWrite(0x0000, value: 0x00)
        // Reaches here without crashing → pass.
    }
}
