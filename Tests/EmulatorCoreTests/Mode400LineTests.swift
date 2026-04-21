import Testing
@testable import EmulatorCore

@Suite("400-Line Mode Tests")
struct Mode400LineTests {

    // MARK: - Pc88Bus: Port 0x31 bit 0

    @Test func mode200LineDefaultTrue() {
        let bus = Pc88Bus()
        #expect(bus.mode200Line == true)
    }

    @Test func port31Bit0Decode() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        bus.crtc = crtc

        // Write 0x00 → bit 0 = 0 → mode200Line = false
        bus.ioWrite(0x31, value: 0x00)
        #expect(bus.mode200Line == false)
        #expect(crtc.mode200Line == false)

        // Write 0x01 → bit 0 = 1 → mode200Line = true
        bus.ioWrite(0x31, value: 0x01)
        #expect(bus.mode200Line == true)
        #expect(crtc.mode200Line == true)
    }

    @Test func is400LineModeComputedProperty() {
        let bus = Pc88Bus()

        // Default: mode200Line=true, graphicsColorMode=true → false
        #expect(bus.is400LineMode == false)

        // mode200Line=false, graphicsColorMode=true → false (must be mono)
        bus.mode200Line = false
        bus.graphicsColorMode = true
        #expect(bus.is400LineMode == false)

        // mode200Line=false, graphicsColorMode=false → true (400-line mono)
        bus.graphicsColorMode = false
        #expect(bus.is400LineMode == true)

        // mode200Line=true, graphicsColorMode=false → false (200-line mono)
        bus.mode200Line = true
        #expect(bus.is400LineMode == false)
    }

    @Test func port31WriteDecodes400LineMode() {
        let bus = Pc88Bus()
        let crtc = CRTC()
        bus.crtc = crtc

        // Port 0x31 = 0x00: bit0=0 (400line), bit4=0 (mono) → is400LineMode
        bus.ioWrite(0x31, value: 0x00)
        #expect(bus.is400LineMode == true)
        #expect(bus.mode200Line == false)
        #expect(bus.graphicsColorMode == false)

        // Port 0x31 = 0x10: bit0=0 (400line), bit4=1 (color) → NOT 400-line
        bus.ioWrite(0x31, value: 0x10)
        #expect(bus.is400LineMode == false)

        // Port 0x31 = 0x01: bit0=1 (200line), bit4=0 (mono) → NOT 400-line
        bus.ioWrite(0x31, value: 0x01)
        #expect(bus.is400LineMode == false)
    }

    // MARK: - Pc88Bus: Port 0x40 bit 1 monitor type

    @Test func port40Bit1MonitorType() {
        let bus = Pc88Bus()

        // Port 0x40 bit 1 (SHG): hardware monitor type, NOT tied to mode200Line.
        // PC-8801-FA has 24kHz monitor (hireso) → bit 1 = 0.
        let val200 = bus.ioRead(0x40)
        #expect((val200 & 0x02) == 0, "24kHz monitor: bit 1 should be 0")

        // Even with mode200Line=false, bit 1 stays 0 (hardware monitor type)
        bus.mode200Line = false
        let val400 = bus.ioRead(0x40)
        #expect((val400 & 0x02) == 0, "24kHz monitor: bit 1 should be 0 regardless of mode")
    }

    // MARK: - Pc88Bus: reset restores mode200Line

    @Test func resetRestoresMode200Line() {
        let bus = Pc88Bus()
        bus.mode200Line = false
        bus.reset()
        #expect(bus.mode200Line == true)
    }

    // MARK: - CRTC: Dynamic Scanlines

    @Test func dynamicTotalScanlines200() {
        let crtc = CRTC()
        crtc.mode200Line = true
        #expect(crtc.dynamicTotalScanlines == 262)
        #expect(crtc.dynamicBlankingStart == 200)
    }

    @Test func dynamicTotalScanlines400WithDefaultParams() {
        let crtc = CRTC()
        crtc.mode200Line = false
        // Default: linesPerScreen=25, vretrace=1, charLinesPerRow=8
        // (25+1)*8 = 208 < 262 → clamp to 262 (200-line fallback)
        // This prevents timing breakage when ROM writes port 0x31=0x00
        // before CRTC is reconfigured for 400-line mode.
        #expect(crtc.dynamicTotalScanlines == 262)
        #expect(crtc.dynamicBlankingStart == 200)
    }

    @Test func dynamicTotalScanlines400With16LinesPerChar() {
        let crtc = CRTC()
        crtc.mode200Line = false
        crtc.charLinesPerRow = 16
        crtc.vretrace = 3
        // (25+3)*16 = 448
        #expect(crtc.dynamicTotalScanlines == 448)
        #expect(crtc.dynamicBlankingStart == 400)
    }

    @Test func vrtcTiming400Line() {
        let crtc = CRTC()
        crtc.reset()
        crtc.mode200Line = false
        crtc.charLinesPerRow = 16
        crtc.vretrace = 3
        // Total = 448, blanking at 400

        var vsyncCount = 0
        crtc.onVSYNC = { vsyncCount += 1 }

        let tStatesPerLine = 297  // 133333 / 448 ≈ 297
        // Advance to scanline 399 (still active)
        for _ in 0..<399 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(crtc.vrtcFlag == false)

        // Advance to scanline 400 (blanking starts)
        crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        #expect(crtc.vrtcFlag == true)
        #expect(vsyncCount == 1)

        // Complete the frame (scanlines 401..447)
        for _ in 401..<448 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(crtc.scanline == 447)

        // Wrap to scanline 0
        crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        #expect(crtc.scanline == 0)
        #expect(crtc.vrtcFlag == false)
    }

    // MARK: - ScreenRenderer: Constants

    @Test func height400Constants() {
        #expect(ScreenRenderer.height400 == 400)
        #expect(ScreenRenderer.bufferSize400 == 640 * 400 * 4)
    }

    // MARK: - ScreenRenderer: 400-line render

    @Test func render400LineBlackScreen() {
        let renderer = ScreenRenderer()
        let blue = Array(repeating: UInt8(0x00), count: 0x4000)
        let red = Array(repeating: UInt8(0x00), count: 0x4000)
        var buffer = Array(repeating: UInt8(0xAA), count: ScreenRenderer.bufferSize400)

        renderer.render400Line(
            blueVRAM: blue,
            redVRAM: red,
            palette: ScreenRenderer.defaultPalette,
            into: &buffer
        )

        // All pixels should be black
        #expect(buffer[0] == 0x00)  // R
        #expect(buffer[1] == 0x00)  // G
        #expect(buffer[2] == 0x00)  // B
        #expect(buffer[3] == 0xFF)  // A

        // Last pixel of lower half
        let lastPixelOffset = (ScreenRenderer.bufferSize400) - 4
        #expect(buffer[lastPixelOffset] == 0x00)
        #expect(buffer[lastPixelOffset + 3] == 0xFF)
    }

    @Test func render400LineUpperHalfFromBlue() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        let red = Array(repeating: UInt8(0x00), count: 0x4000)

        // Set first byte of blue plane to 0x80 (leftmost pixel on)
        blue[0] = 0x80

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)
        renderer.render400Line(
            blueVRAM: blue,
            redVRAM: red,
            palette: ScreenRenderer.defaultPalette,
            into: &buffer
        )

        // Pixel (0,0) should be white (palette[7])
        #expect(buffer[0] == 0xFF)  // R
        #expect(buffer[1] == 0xFF)  // G
        #expect(buffer[2] == 0xFF)  // B

        // Pixel (1,0) should be black
        #expect(buffer[4] == 0x00)
    }

    @Test func render400LineLowerHalfFromRed() {
        let renderer = ScreenRenderer()
        let blue = Array(repeating: UInt8(0x00), count: 0x4000)
        var red = Array(repeating: UInt8(0x00), count: 0x4000)

        // Set first byte of red plane to 0x80 (leftmost pixel of lower half on)
        red[0] = 0x80

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)
        renderer.render400Line(
            blueVRAM: blue,
            redVRAM: red,
            palette: ScreenRenderer.defaultPalette,
            into: &buffer
        )

        // Upper half pixel (0,0) should be black
        #expect(buffer[0] == 0x00)

        // Lower half pixel (0,200) should be white
        let rowBytes = 640 * 4
        let lowerOffset = 200 * rowBytes
        #expect(buffer[lowerOffset] == 0xFF)      // R
        #expect(buffer[lowerOffset + 1] == 0xFF)   // G
        #expect(buffer[lowerOffset + 2] == 0xFF)   // B
    }

    @Test func renderAttributeGraph400UsesTextAttributes() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        var red = Array(repeating: UInt8(0x00), count: 0x4000)
        var attrData = Array(repeating: UInt8(0xE0), count: 80 * 25)

        blue[0] = 0x80
        red[0] = 0x80
        attrData[0] = 0x20            // upper half: blue
        attrData[12 * 80] = 0x40      // lower half first visible row: red

        var buffer = Array(repeating: UInt8(0x00), count: ScreenRenderer.bufferSize400)
        renderer.renderAttributeGraph400(
            blueVRAM: blue,
            redVRAM: red,
            attrData: attrData,
            palette: ScreenRenderer.defaultPalette,
            textRows: 25,
            into: &buffer
        )

        #expect(buffer[0] == 0x00)
        #expect(buffer[1] == 0x00)
        #expect(buffer[2] == 0xFF)

        let lowerOffset = 200 * 640 * 4
        #expect(buffer[lowerOffset] == 0xFF)
        #expect(buffer[lowerOffset + 1] == 0x00)
        #expect(buffer[lowerOffset + 2] == 0x00)
    }

    // MARK: - ScreenRenderer: renderDoubled

    @Test func renderDoubledDoublesLines() {
        let renderer = ScreenRenderer()
        var blue = Array(repeating: UInt8(0x00), count: 0x4000)
        let red = Array(repeating: UInt8(0x00), count: 0x4000)
        let green = Array(repeating: UInt8(0x00), count: 0x4000)

        // First byte of blue plane → pixel at top-left
        blue[0] = 0x80

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)
        renderer.renderDoubled(
            blueVRAM: blue,
            redVRAM: red,
            greenVRAM: green,
            palette: ScreenRenderer.defaultPalette,
            into: &buffer
        )

        let rowBytes = 640 * 4
        // Row 0: pixel (0,0) should be blue (palette index 1: Blue)
        #expect(buffer[0] == 0x00)  // R
        #expect(buffer[1] == 0x00)  // G
        #expect(buffer[2] == 0xFF)  // B = blue

        // Row 1: doubled row — same pixel data
        #expect(buffer[rowBytes] == 0x00)
        #expect(buffer[rowBytes + 1] == 0x00)
        #expect(buffer[rowBytes + 2] == 0xFF)

        // Row 2: should be black (next source line is all zero)
        #expect(buffer[2 * rowBytes] == 0x00)
        #expect(buffer[2 * rowBytes + 1] == 0x00)
        #expect(buffer[2 * rowBytes + 2] == 0x00)
    }

    // MARK: - ScreenRenderer: Text hireso mode

    @Test func textOverlayHiresoDoublesCellHeight() {
        let renderer = ScreenRenderer()
        let fontROM = FontROM()
        let palette = ScreenRenderer.defaultPalette

        // Create text data with a character that has a known glyph
        var textData = Array(repeating: UInt8(0x20), count: 80 * 25)  // spaces
        textData[0] = 0x41  // 'A' at position (0,0)

        let attrData = Array(repeating: UInt8(0xE0), count: 80 * 25)  // white, no effects

        var buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)

        // Non-hireso: cellHeight=8, text at 200-line resolution
        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            hireso: false,
            into: &buffer
        )
        // Check that row 8 is blank (past cell height 8)
        let row8Start = 8 * 640 * 4
        let hasPixelAtRow8 = buffer[row8Start..<(row8Start + 640 * 4)].contains(where: { $0 != 0 })
        #expect(hasPixelAtRow8 == false)

        // Hireso: cellHeight=16, text at 400-line resolution
        buffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)
        renderer.renderTextOverlay(
            textData: textData,
            attrData: attrData,
            fontROM: fontROM,
            palette: palette,
            displayEnabled: true,
            hireso: true,
            into: &buffer
        )
        // Row 8 should have data (doubled font line 4)
        let hasPixelAtRow8Hireso = buffer[row8Start..<(row8Start + 640 * 4)].contains(where: { $0 != 0 })
        // 'A' in built-in font should have pixels in rows 0-6 → doubled = rows 0-13
        #expect(hasPixelAtRow8Hireso == true)
    }
}
