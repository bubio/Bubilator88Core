import Testing
@testable import EmulatorCore

@Suite("FontROM Tests")
struct FontROMTests {

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
    }

    @Test("Built-in font has ASCII glyphs")
    func builtInFontHasASCII() {
        let fontROM = FontROM()
        // 'A' (0x41) should have non-zero glyph data
        let glyph = fontROM.glyph(for: 0x41)
        #expect(glyph.count == 8)
        #expect(glyph.contains(where: { $0 != 0 }))
    }

    @Test("Space character is all zeros")
    func spaceIsZero() {
        let fontROM = FontROM()
        let glyph = fontROM.glyph(for: 0x20)
        #expect(glyph.allSatisfy { $0 == 0 })
    }

    @Test("Load external font ROM")
    func loadExternalROM() {
        let fontROM = FontROM()
        #expect(!fontROM.isLoaded)

        // Create a 2048-byte ROM with a known pattern
        var romData = Array(repeating: UInt8(0xAA), count: 2048)
        // Character 0x00 row 0 = 0xAA
        fontROM.load(romData)
        #expect(fontROM.isLoaded)
        let glyph = fontROM.glyph(for: 0x00)
        #expect(glyph[0] == 0xAA)
    }

    @Test("Load rejects undersized data")
    func rejectUndersizedData() {
        let fontROM = FontROM()
        fontROM.load([0x01, 0x02, 0x03])  // Too small
        #expect(!fontROM.isLoaded)
    }

    @Test("Glyph returns 8 bytes for every character code")
    func glyphReturns8Bytes() {
        let fontROM = FontROM()
        for code in UInt8.min...UInt8.max {
            let glyph = fontROM.glyph(for: code)
            #expect(glyph.count == 8)
        }
    }

    @Test("Digits 0-9 have distinct glyphs")
    func digitsAreDistinct() {
        let fontROM = FontROM()
        var glyphs = Set<[UInt8]>()
        for code: UInt8 in 0x30...0x39 {
            glyphs.insert(fontROM.glyph(for: code))
        }
        #expect(glyphs.count == 10)
    }

    @Test("Text VRAM read from bus with DMA row stride")
    func textVRAMReadFromBus() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc

        // CRTC defaults: 80 chars + 20 attrs*2 = 120 bytes per row
        // Set DMA channel 2 to start at address 0xF3C8
        dma.ioWrite(0x64, value: 0xC8)  // low byte
        dma.ioWrite(0x64, value: 0xF3)  // high byte

        // Write text data to TVRAM at DMA address.
        // DMA addr = 0xF3C8; row1 addr = 0xF3C8 + 120 = 0xF440
        configureTextDMARead(dma, crtc: crtc)
        bus.tvram[0x3C8] = 0x41  // Row 0, Col 0: 'A'
        bus.tvram[0x3C9] = 0x42  // Row 0, Col 1: 'B'
        bus.tvram[0x440] = 0x43  // Row 1, Col 0: 'C'

        bus.performTextDMATransfer()
        let textData = bus.readTextVRAM()
        #expect(textData[0] == 0x41)    // Row 0, Col 0
        #expect(textData[1] == 0x42)    // Row 0, Col 1
        #expect(textData[80] == 0x43)   // Row 1, Col 0 (in flattened output)
    }

    @Test("Text attribute run-length expansion")
    func textAttributeRunLength() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc
        crtc.displayMode = 0x02

        // DMA start address = 0x8000
        dma.ioWrite(0x64, value: 0x00)  // low byte
        dma.ioWrite(0x64, value: 0x80)  // high byte = 0x8000

        // Row 0: 80 chars at addr 0x8000, attrs at addr 0x8050 (= 0x8000 + 80)
        // Attribute pairs (transparent mode):
        // Raw uPD3301 color attribute: G(7) R(6) B(5) GRAPH(4) COLOR_SWITCH(3)
        // Pair 0: position=0, raw=0x48 (Red: R=1, COLOR_SWITCH=1)
        // Pair 1: position=10, raw=0xE8 (White: GRB=111, COLOR_SWITCH=1)
        bus.mainRAM[0x8050] = 0      // Position 0
        bus.mainRAM[0x8051] = 0x48   // Red (bit 6 + COLOR_SWITCH bit 3)
        bus.mainRAM[0x8052] = 10     // Position 10
        bus.mainRAM[0x8053] = 0xE8   // White (bits 7-5 + COLOR_SWITCH bit 3)
        configureTextDMARead(dma, crtc: crtc)
        bus.mainRAM[0x8054] = 0      // End marker
        bus.mainRAM[0x8055] = 0

        // After remapping: COLOR_SWITCH set → upper nibble is color directly
        // 0x48 → (currentAttr & 0x0F) | (0x48 & 0xF0) = 0x40
        // 0xE8 → (currentAttr & 0x0F) | (0xE8 & 0xF0) = 0xE0
        bus.performTextDMATransfer()
        let attrs = bus.readTextAttributes()
        #expect(attrs[0] == 0x40)   // Col 0: Red (from pair 0)
        #expect(attrs[5] == 0x40)   // Col 5: still Red
        #expect(attrs[10] == 0xE0)  // Col 10: White (from pair 1)
        #expect(attrs[79] == 0xE0)  // Col 79: still White
    }

    @Test("Attribute remapping: mono-style reverse bit")
    func attrRemapMonoReverse() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc
        crtc.displayMode = 0x02

        dma.ioWrite(0x64, value: 0x00)
        dma.ioWrite(0x64, value: 0x80)  // DMA at 0x8000
        configureTextDMARead(dma, crtc: crtc)

        // Pair 0: position=0, color=white (0xE8 = COLOR_SWITCH + GRB=111)
        // Pair 1: position=5, mono-style reverse (0x04 = MONO_REVERSE)
        bus.mainRAM[0x8050] = 0
        bus.mainRAM[0x8051] = 0xE8   // White color
        bus.mainRAM[0x8052] = 5
        bus.mainRAM[0x8053] = 0x04   // MONO_REVERSE (raw bit 2)
        bus.mainRAM[0x8054] = 0
        bus.mainRAM[0x8055] = 0

        bus.performTextDMATransfer()
        let attrs = bus.readTextAttributes()
        // Col 0: white, no effects → 0xE0
        #expect(attrs[0] == 0xE0)
        // Col 5: reverse → ATTR_REVERSE(0x01), keep white → 0xE1
        #expect(attrs[5] == 0xE1)
        // Col 10: still reverse white
        #expect(attrs[10] == 0xE1)
    }

    @Test("Attribute remapping: B&W mode")
    func attrRemapBWMode() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc
        bus.colorMode = false  // B&W mode

        dma.ioWrite(0x64, value: 0x00)
        dma.ioWrite(0x64, value: 0x80)
        configureTextDMARead(dma, crtc: crtc)

        // Pair 0: position=0, MONO_REVERSE(0x04) + MONO_UNDER(0x20) = 0x24
        bus.mainRAM[0x8050] = 0
        bus.mainRAM[0x8051] = 0x24
        bus.mainRAM[0x8052] = 0
        bus.mainRAM[0x8053] = 0

        bus.performTextDMATransfer()
        let attrs = bus.readTextAttributes()
        // B&W: 0xE0 (white) | MONO_UNDER(0x20)>>2=ATTR_LOWER(0x08) | MONO_REVERSE(0x04)>>2=ATTR_REVERSE(0x01)
        #expect(attrs[0] == 0xE9)  // 0xE0 | 0x08 | 0x01
    }

    @Test("Attribute remapping uses CRTC color mode, not port 0x30 mono state")
    func attrRemapUsesCRTCColorMode() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc

        // Blassty enters with port 0x30 in mono mode while the CRTC reset
        // parameter still selects color attributes (mode bit 1 set).
        bus.colorMode = false
        crtc.displayMode = 0x02

        dma.ioWrite(0x64, value: 0x00)
        dma.ioWrite(0x64, value: 0x80)
        configureTextDMARead(dma, crtc: crtc)

        bus.mainRAM[0x8050] = 0x00
        bus.mainRAM[0x8051] = 0xE8
        bus.mainRAM[0x8052] = 0x50
        bus.mainRAM[0x8053] = 0x00

        bus.performTextDMATransfer()
        let attrs = bus.readTextAttributes()
        #expect(attrs[0] == 0xE0)
        #expect(attrs[79] == 0xE0)
    }

    @Test("Semi-graphic pattern generation")
    func sgPatternGeneration() {
        let fontROM = FontROM()

        // code 0xFF → all rows 0xFF (fully filled)
        for row in 0..<8 {
            #expect(fontROM.sgGlyphRow(code: 0xFF, row: row) == 0xFF)
        }

        // code 0x00 → all rows 0x00 (empty)
        for row in 0..<8 {
            #expect(fontROM.sgGlyphRow(code: 0x00, row: row) == 0x00)
        }

        // code 0x01 → bit 0 = left-upper block: rows 0,1 = 0xF0, rows 2-7 = 0x00
        #expect(fontROM.sgGlyphRow(code: 0x01, row: 0) == 0xF0)
        #expect(fontROM.sgGlyphRow(code: 0x01, row: 1) == 0xF0)
        for row in 2..<8 {
            #expect(fontROM.sgGlyphRow(code: 0x01, row: row) == 0x00)
        }

        // code 0x11 → bit 0 + bit 4: rows 0,1 = 0xFF (left+right upper)
        #expect(fontROM.sgGlyphRow(code: 0x11, row: 0) == 0xFF)
        #expect(fontROM.sgGlyphRow(code: 0x11, row: 1) == 0xFF)
        for row in 2..<8 {
            #expect(fontROM.sgGlyphRow(code: 0x11, row: row) == 0x00)
        }

        // code 0x0F → bits 0-3: left column fully filled
        for row in 0..<8 {
            #expect(fontROM.sgGlyphRow(code: 0x0F, row: row) == 0xF0)
        }
    }

    @Test("Transparent attributes do not leak underline to next row")
    func transparentAttributesDoNotLeakAcrossRows() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc

        crtc.charsPerLine = 2
        crtc.linesPerScreen = 2
        crtc.attrsPerLine = 1
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc)

        // Row 0 attr: underline from column 0.
        bus.mainRAM[0x8002] = 0
        bus.mainRAM[0x8003] = 0x20

        // Row 1 attr: explicit terminator only, no new effects.
        let row1Base = 0x8000 + crtc.bytesPerDMARow
        bus.mainRAM[row1Base + 2] = 0
        bus.mainRAM[row1Base + 3] = 0

        bus.performTextDMATransfer()

        let attrs = bus.readTextAttributes()
        #expect(attrs[0] == 0xE8)
        #expect(attrs[2] == 0xE0)
    }

    @Test("Transparent attributes follow BubiC stream ordering")
    func transparentAttributesFollowBubiCStreamOrdering() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc
        crtc.displayMode = 0x02

        crtc.charsPerLine = 4
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 3
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc)

        // Pair order:
        //   col 2 -> red
        //   col 0 -> blue
        //   col 3 -> green
        // BubiC marks columns in reverse with `pos & 0x7F`, then consumes
        // attribute values in original stream order as flagged columns are hit.
        // Result:
        //   col 0 -> red, col 2 -> blue, col 3 -> green
        bus.mainRAM[0x8004] = 2
        bus.mainRAM[0x8005] = 0x48
        bus.mainRAM[0x8006] = 0
        bus.mainRAM[0x8007] = 0x28
        bus.mainRAM[0x8008] = 3
        bus.mainRAM[0x8009] = 0x88

        bus.performTextDMATransfer()

        let attrs = bus.readTextAttributes()
        #expect(attrs[0] == 0x40)
        #expect(attrs[1] == 0x40)
        #expect(attrs[2] == 0x20)
        #expect(attrs[3] == 0x80)
    }

    @Test("Transparent attributes mask high bit in position bytes")
    func transparentAttributesMaskPositionHighBit() {
        let bus = Pc88Bus()
        let dma = DMAController()
        let crtc = CRTC()
        bus.dma = dma
        bus.crtc = crtc
        crtc.displayMode = 0x02

        crtc.charsPerLine = 4
        crtc.linesPerScreen = 1
        crtc.attrsPerLine = 2
        crtc.attrNonTransparent = false
        dma.channels[2].address = 0x8000
        configureTextDMARead(dma, crtc: crtc)

        // Position bit 7 is ignored by BubiC (`pos & 0x7F`).
        // 0x82 therefore targets column 2, not "no-op".
        bus.mainRAM[0x8004] = 0x82
        bus.mainRAM[0x8005] = 0x48
        bus.mainRAM[0x8006] = 3
        bus.mainRAM[0x8007] = 0x88

        bus.performTextDMATransfer()

        let attrs = bus.readTextAttributes()
        #expect(attrs[0] == 0xE0)
        #expect(attrs[1] == 0xE0)
        #expect(attrs[2] == 0x40)
        #expect(attrs[3] == 0x80)
    }
}
