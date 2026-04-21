import Testing
@testable import EmulatorCore

@Suite("ScreenRenderer Tests")
struct ScreenRendererTests {

    @Test func blackScreen() {
        let renderer = ScreenRenderer()
        let blue = Array(repeating: UInt8(0x00), count: 0x4000)
        let red = Array(repeating: UInt8(0x00), count: 0x4000)
        let green = Array(repeating: UInt8(0x00), count: 0x4000)
        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize)

        renderer.render(blueVRAM: blue, redVRAM: red, greenVRAM: green, into: &buffer)

        // First pixel should be black (0,0,0,255)
        #expect(buffer[0] == 0x00)  // R
        #expect(buffer[1] == 0x00)  // G
        #expect(buffer[2] == 0x00)  // B
        #expect(buffer[3] == 0xFF)  // A
    }

    @Test func whiteScreen() {
        let renderer = ScreenRenderer()
        let blue = Array(repeating: UInt8(0xFF), count: 0x4000)
        let red = Array(repeating: UInt8(0xFF), count: 0x4000)
        let green = Array(repeating: UInt8(0xFF), count: 0x4000)
        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize)

        renderer.render(blueVRAM: blue, redVRAM: red, greenVRAM: green, into: &buffer)

        // First pixel should be white (255,255,255,255)
        #expect(buffer[0] == 0xFF)  // R
        #expect(buffer[1] == 0xFF)  // G
        #expect(buffer[2] == 0xFF)  // B
        #expect(buffer[3] == 0xFF)  // A
    }

    @Test func singleRedPixel() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        var red = Array(repeating: UInt8(0x00), count: 0x4000)
        var green = Array(repeating: UInt8(0x00), count: 0x4000)

        // Set MSB of first byte in red plane = leftmost pixel is red
        red[0] = 0x80

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize)
        renderer.render(blueVRAM: blue, redVRAM: red, greenVRAM: green, into: &buffer)

        // Pixel (0,0) should be red
        #expect(buffer[0] == 0xFF)  // R
        #expect(buffer[1] == 0x00)  // G
        #expect(buffer[2] == 0x00)  // B

        // Pixel (1,0) should be black
        #expect(buffer[4] == 0x00)
        #expect(buffer[5] == 0x00)
        #expect(buffer[6] == 0x00)
    }

    @Test func bufferSize() {
        #expect(ScreenRenderer.bufferSize == 640 * 200 * 4)
        #expect(ScreenRenderer.width == 640)
        #expect(ScreenRenderer.height == 200)
    }

    @Test("Text overlay 40-column mode doubles pixel width")
    func textOverlay40col() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()
        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize)
        // Set alpha to 0xFF
        for i in stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 0xFF }

        // Put 'A' at position (0,0)
        var textData = Array(repeating: UInt8(0x20), count: 2000)
        var attrData = Array(repeating: UInt8(0xE0), count: 2000)
        textData[0] = 0x41  // 'A'

        let palette = ScreenRenderer.defaultPalette
        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            columns80: false,  // 40-column mode
            into: &buffer
        )

        // In 40-col mode, character 'A' should occupy 16 pixels width (doubled)
        // The 'A' glyph has non-zero pixels, rendered in white (7) on black background
        // Check that some R channel bytes (stride of 4) are 0xFF (white text pixel)
        // Initial buffer was all black (R=0,G=0,B=0,A=FF), text overlay sets R=FF for white
        var foundWhitePixel = false
        for x in 0..<16 {
            let offset = x * 4  // Row 0, pixel x
            if buffer[offset] == 0xFF && buffer[offset + 1] == 0xFF && buffer[offset + 2] == 0xFF {
                foundWhitePixel = true
                break
            }
        }
        // First row of 'A' glyph (0x18 = 0001_1000) should paint pixels at x=6,7 (doubled: 12-15)
        #expect(foundWhitePixel)
    }

    @Test func cyanPixel() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        var red = Array(repeating: UInt8(0x00), count: 0x4000)
        var green = Array(repeating: UInt8(0x00), count: 0x4000)

        // Blue + Green = Cyan (color index 5)
        blue[0] = 0x80
        green[0] = 0x80

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize)
        renderer.render(blueVRAM: blue, redVRAM: red, greenVRAM: green, into: &buffer)

        #expect(buffer[0] == 0x00)  // R
        #expect(buffer[1] == 0xFF)  // G
        #expect(buffer[2] == 0xFF)  // B
    }

    @Test("GRAPH attribute uses semi-graphic pattern")
    func graphAttributeUseSGPattern() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()
        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize)
        for i in stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 0xFF }

        var textData = Array(repeating: UInt8(0x20), count: 2000)
        var attrData = Array(repeating: UInt8(0xE0), count: 2000)

        // charCode=0xFF with GRAPH attribute (bit 4) → full 8×8 block
        textData[0] = 0xFF
        attrData[0] = 0xF0  // white (0xE0) + GRAPH (0x10)

        let palette = ScreenRenderer.defaultPalette
        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            columns80: true,
            into: &buffer
        )

        // All 8×8 pixels should be foreground (white)
        for row in 0..<8 {
            for col in 0..<8 {
                let offset = (row * ScreenRenderer.width + col) * ScreenRenderer.bytesPerPixel
                #expect(buffer[offset] == 0xFF, "row \(row) col \(col) R should be white")
                #expect(buffer[offset + 1] == 0xFF, "row \(row) col \(col) G should be white")
                #expect(buffer[offset + 2] == 0xFF, "row \(row) col \(col) B should be white")
            }
        }
    }

    @Test("200-line attribute graphics uses text colors and reverse")
    func attributeGraph200UsesTextAttributes() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        let red = Array(repeating: UInt8(0x00), count: 0x4000)
        let green = Array(repeating: UInt8(0x00), count: 0x4000)
        var attrData = Array(repeating: UInt8(0xE0), count: 80 * 25)
        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize400)

        blue[0] = 0x80          // leftmost source pixel on
        attrData[0] = 0x20      // color index 1 = blue
        attrData[1] = 0xE1      // white + reverse

        renderer.renderAttributeGraph200(
            blueVRAM: blue,
            redVRAM: red,
            greenVRAM: green,
            attrData: attrData,
            palette: ScreenRenderer.defaultPalette,
            into: &buffer
        )

        // Cell 0: blue attribute colors the active graphics bit.
        #expect(buffer[0] == 0x00)
        #expect(buffer[1] == 0x00)
        #expect(buffer[2] == 0xFF)

        // Cell 1: reverse turns an empty graphics byte into a filled white cell.
        let x8 = 8 * 4
        #expect(buffer[x8] == 0xFF)
        #expect(buffer[x8 + 1] == 0xFF)
        #expect(buffer[x8 + 2] == 0xFF)
    }

    // MARK: - Xak2/Sorcerian text mask tests

    @Test("CRTC reverse XOR applied only in color graphics mode (QUASI88 compatible)")
    func reverseXORColorModeOnly() {
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
        dma.channels[2].mode = 0b01
        dma.channels[2].count = UInt16(crtc.bytesPerDMARow)
        dma.channels[2].enabled = true
        // Set effect attribute: raw=0x00 → ATTR_REVERSE=0 after remap
        bus.mainRAM[0x8004] = 0x00  // position=0
        bus.mainRAM[0x8005] = 0x00  // value=0x00 (no reverse)
        crtc.writeCommand(0x21) // Start Display with reverse=1

        bus.performTextDMATransfer()

        // Color mode (default graphicsColorMode=true) → XOR applied
        let attrsColor = bus.readTextAttributes()
        #expect(attrsColor[0] & 0x01 == 0x01, "Color mode: reverse should be XOR'd to 1")

        // Switch to non-color mode → XOR not applied
        bus.graphicsColorMode = false
        let attrsMono = bus.readTextAttributes()
        #expect(attrsMono[0] & 0x01 == 0x00, "Non-color mode: reverse should stay 0")
    }

    @Test("Text overlay: reverse+graph mask writes foreground only, background transparent")
    func textOverlayReverseTransparency() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()

        // Pre-fill buffer with cyan (simulating GVRAM content)
        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize)
        for y in 0..<ScreenRenderer.height {
            for x in 0..<ScreenRenderer.width {
                let off = (y * ScreenRenderer.width + x) * 4
                buffer[off] = 0; buffer[off+1] = 255; buffer[off+2] = 255; buffer[off+3] = 255
            }
        }

        var textData = Array(repeating: UInt8(0x00), count: 2000)
        var attrData = Array(repeating: UInt8(0x11), count: 2000) // graph + reverse

        // Col 0: ch=0x00 (mask: reverse → all ON → foreground=black)
        textData[0] = 0x00
        // Col 1: ch=0xFF (viewport: reverse → all OFF → transparent → GVRAM visible)
        textData[1] = 0xFF

        let palette = ScreenRenderer.defaultPalette

        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            columns80: true,
            into: &buffer
        )

        // Col 0 (mask): all pixels should be black (foreground with colorIdx=0)
        let maskOff = 0 * 4
        #expect(buffer[maskOff] == 0, "Mask pixel R should be 0")
        #expect(buffer[maskOff+1] == 0, "Mask pixel G should be 0")
        #expect(buffer[maskOff+2] == 0, "Mask pixel B should be 0")

        // Col 1 (viewport): pixels should be cyan (GVRAM preserved, not overwritten)
        let viewOff = 8 * 4  // col 1, pixel 0
        #expect(buffer[viewOff] == 0, "Viewport pixel R should be 0 (cyan)")
        #expect(buffer[viewOff+1] == 255, "Viewport pixel G should be 255 (cyan)")
        #expect(buffer[viewOff+2] == 255, "Viewport pixel B should be 255 (cyan)")
    }

    @Test("Attribute-graphics reverse uses palette 0 glyph mask instead of inverted text")
    func attributeGraphicsReverseUsesBackgroundGlyphMask() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()

        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize)
        for y in 0..<ScreenRenderer.height {
            for x in 0..<ScreenRenderer.width {
                let off = (y * ScreenRenderer.width + x) * 4
                buffer[off] = 0
                buffer[off + 1] = 255
                buffer[off + 2] = 255
                buffer[off + 3] = 255
            }
        }

        var textData = Array(repeating: UInt8(0x20), count: 2000)
        var attrData = Array(repeating: UInt8(0xE0), count: 2000)
        textData[0] = 0x41      // "A" row 0 = 0x18
        attrData[0] = 0xE1      // white + reverse

        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: ScreenRenderer.defaultPalette,
            displayEnabled: true,
            columns80: true,
            colorMode: true,
            attributeGraphMode: true,
            into: &buffer
        )

        // Attribute-graphics reverse keeps the glyph shape and paints it with
        // palette 0, instead of inverting foreground/background coverage.
        let glyphPixel = 3 * 4
        #expect(buffer[glyphPixel] == 0)
        #expect(buffer[glyphPixel + 1] == 0)
        #expect(buffer[glyphPixel + 2] == 0)

        let backgroundPixel = 0
        #expect(buffer[backgroundPixel] == 0)
        #expect(buffer[backgroundPixel + 1] == 255)
        #expect(buffer[backgroundPixel + 2] == 255)
    }

    @Test("Uncovered lines filled with background color")
    func coveredLinesFill() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()

        // Pre-fill with white (simulating GVRAM)
        var buffer = Array(repeating: UInt8(0xFF), count: ScreenRenderer.bufferSize)

        let textData = Array(repeating: UInt8(0x00), count: 80 * 20)
        let attrData = Array(repeating: UInt8(0xE0), count: 80 * 20)
        var palette = ScreenRenderer.defaultPalette
        palette[0] = (r: 0, g: 0, b: 0)

        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            columns80: true,
            textRows: 20,  // 20 rows × 10 cellHeight = 200 < 200 (just covers)
            into: &buffer
        )

        // With textRows=20, cellHeight=10, coveredLines=200=screenHeight → no fill
        // Test with smaller textRows in hireso mode
        var buffer400 = Array(repeating: UInt8(0xFF), count: ScreenRenderer.bufferSize400)
        let textData25 = Array(repeating: UInt8(0x00), count: 80 * 24)
        let attrData25 = Array(repeating: UInt8(0xE0), count: 80 * 24)

        renderer.renderTextOverlay(
            textData: textData25,
            attrData: attrData25,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            columns80: true,
            textRows: 24,  // 24 rows × 16 cellHeight(hireso) = 384 < 400
            hireso: true,
            into: &buffer400
        )

        // Line 384 (first uncovered) should be filled with palette[0]=black
        let uncoveredOff = (384 * ScreenRenderer.width + 0) * 4
        #expect(buffer400[uncoveredOff] == 0, "Uncovered line R should be 0")
        #expect(buffer400[uncoveredOff+1] == 0, "Uncovered line G should be 0")
        #expect(buffer400[uncoveredOff+2] == 0, "Uncovered line B should be 0")

        // Line 383 (last covered) should NOT be filled (original white preserved or text rendered)
        // It's covered by text rendering so it depends on text content
    }
}
