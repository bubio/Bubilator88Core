/// ScreenRenderer — converts GVRAM planes + text VRAM to an RGBA pixel buffer.
///
/// Resolution: 640×200 (200-line mode).
/// Graphics: 3 planes (Blue/Red/Green), each 16KB, 80 bytes per line.
/// Text: 80×25 characters, each 8×8 pixels, overlaid on graphics.
///
/// Output: 640×200×4 bytes (RGBA8888).
public struct ScreenRenderer {

    public static let width = 640
    public static let height = 200
    public static let height400 = 400
    public static let bytesPerPixel = 4
    public static let bufferSize = width * height * bytesPerPixel
    public static let bufferSize400 = width * height400 * bytesPerPixel

    /// Text display dimensions
    public static let textCols80 = 80
    public static let textCols40 = 40
    public static let textRows = 25
    public static let charWidth = 8
    public static let charHeight = 8

    /// Default 8-color palette (index → RGBA).
    /// Index = (Green << 2) | (Red << 1) | Blue
    public static let defaultPalette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (0x00, 0x00, 0x00),  // 0: Black
        (0x00, 0x00, 0xFF),  // 1: Blue
        (0xFF, 0x00, 0x00),  // 2: Red
        (0xFF, 0x00, 0xFF),  // 3: Magenta
        (0x00, 0xFF, 0x00),  // 4: Green
        (0x00, 0xFF, 0xFF),  // 5: Cyan
        (0xFF, 0xFF, 0x00),  // 6: Yellow
        (0xFF, 0xFF, 0xFF),  // 7: White
    ]

    public init() {}

    /// Convert 3-bit bus palette entry to 8-bit RGB.
    public static func expandPalette(_ busPalette: [(b: UInt8, r: UInt8, g: UInt8)]) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        return busPalette.map { entry in
            let r = UInt8(min(Int(entry.r) * 255 / 7, 255))
            let g = UInt8(min(Int(entry.g) * 255 / 7, 255))
            let b = UInt8(min(Int(entry.b) * 255 / 7, 255))
            return (r: r, g: g, b: b)
        }
    }

    /// Render GVRAM planes to RGBA pixel buffer using default palette.
    public func render(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        greenVRAM: [UInt8],
        into buffer: inout [UInt8]
    ) {
        renderWithPalette(
            blueVRAM: blueVRAM,
            redVRAM: redVRAM,
            greenVRAM: greenVRAM,
            palette: Self.defaultPalette,
            into: &buffer
        )
    }

    /// Render GVRAM planes to RGBA pixel buffer with custom palette.
    public func renderWithPalette(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        greenVRAM: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        into buffer: inout [UInt8]
    ) {
        let bytesPerLine = 80  // 640 / 8

        // Pre-expand palette to flat arrays for fast indexed access
        var palR = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var palG = palR
        var palB = palR
        withUnsafeMutablePointer(to: &palR) { pr in
            withUnsafeMutablePointer(to: &palG) { pg in
                withUnsafeMutablePointer(to: &palB) { pb in
                    let rp = UnsafeMutableRawPointer(pr).assumingMemoryBound(to: UInt8.self)
                    let gp = UnsafeMutableRawPointer(pg).assumingMemoryBound(to: UInt8.self)
                    let bp = UnsafeMutableRawPointer(pb).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<min(palette.count, 8) {
                        rp[i] = palette[i].r
                        gp[i] = palette[i].g
                        bp[i] = palette[i].b
                    }
                }
            }
        }

        blueVRAM.withUnsafeBufferPointer { bluePtr in
            redVRAM.withUnsafeBufferPointer { redPtr in
                greenVRAM.withUnsafeBufferPointer { greenPtr in
                    buffer.withUnsafeMutableBufferPointer { bufPtr in
                        let dst = bufPtr.baseAddress!
                        let bSrc = bluePtr.baseAddress!
                        let rSrc = redPtr.baseAddress!
                        let gSrc = greenPtr.baseAddress!

                        withUnsafePointer(to: &palR) { prp in
                            withUnsafePointer(to: &palG) { pgp in
                                withUnsafePointer(to: &palB) { pbp in
                                    let pr = UnsafeRawPointer(prp).assumingMemoryBound(to: UInt8.self)
                                    let pg = UnsafeRawPointer(pgp).assumingMemoryBound(to: UInt8.self)
                                    let pb = UnsafeRawPointer(pbp).assumingMemoryBound(to: UInt8.self)

                                    var pixelOffset = 0
                                    for line in 0..<Self.height {
                                        let lineOffset = line * bytesPerLine
                                        for byteIndex in 0..<bytesPerLine {
                                            let offset = lineOffset + byteIndex
                                            let b = bSrc[offset]
                                            let r = rSrc[offset]
                                            let g = gSrc[offset]

                                            for bit in stride(from: 7, through: 0, by: -1) {
                                                let mask: UInt8 = 1 << bit
                                                let colorIndex = ((g & mask) != 0 ? 4 : 0)
                                                               | ((r & mask) != 0 ? 2 : 0)
                                                               | ((b & mask) != 0 ? 1 : 0)
                                                dst[pixelOffset]     = pr[colorIndex]
                                                dst[pixelOffset + 1] = pg[colorIndex]
                                                dst[pixelOffset + 2] = pb[colorIndex]
                                                dst[pixelOffset + 3] = 0xFF
                                                pixelOffset += 4
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Render 200-line GVRAM into a 400-line buffer by doubling each scanline.
    /// Each 200-line row is written twice (row*2 and row*2+1).
    public func renderDoubled(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        greenVRAM: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        into buffer: inout [UInt8]
    ) {
        let bytesPerLine = 80  // 640 / 8

        var palR = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var palG = palR
        var palB = palR
        withUnsafeMutablePointer(to: &palR) { pr in
            withUnsafeMutablePointer(to: &palG) { pg in
                withUnsafeMutablePointer(to: &palB) { pb in
                    let rp = UnsafeMutableRawPointer(pr).assumingMemoryBound(to: UInt8.self)
                    let gp = UnsafeMutableRawPointer(pg).assumingMemoryBound(to: UInt8.self)
                    let bp = UnsafeMutableRawPointer(pb).assumingMemoryBound(to: UInt8.self)
                    for i in 0..<min(palette.count, 8) {
                        rp[i] = palette[i].r
                        gp[i] = palette[i].g
                        bp[i] = palette[i].b
                    }
                }
            }
        }

        blueVRAM.withUnsafeBufferPointer { bluePtr in
            redVRAM.withUnsafeBufferPointer { redPtr in
                greenVRAM.withUnsafeBufferPointer { greenPtr in
                    buffer.withUnsafeMutableBufferPointer { bufPtr in
                        let dst = bufPtr.baseAddress!
                        let bSrc = bluePtr.baseAddress!
                        let rSrc = redPtr.baseAddress!
                        let gSrc = greenPtr.baseAddress!
                        let rowBytes = Self.width * Self.bytesPerPixel

                        withUnsafePointer(to: &palR) { prp in
                            withUnsafePointer(to: &palG) { pgp in
                                withUnsafePointer(to: &palB) { pbp in
                                    let pr = UnsafeRawPointer(prp).assumingMemoryBound(to: UInt8.self)
                                    let pg = UnsafeRawPointer(pgp).assumingMemoryBound(to: UInt8.self)
                                    let pb = UnsafeRawPointer(pbp).assumingMemoryBound(to: UInt8.self)

                                    for line in 0..<Self.height {
                                        let lineOffset = line * bytesPerLine
                                        let dstRow1 = line * 2 * rowBytes
                                        var pixelOffset = dstRow1

                                        for byteIndex in 0..<bytesPerLine {
                                            let offset = lineOffset + byteIndex
                                            let b = bSrc[offset]
                                            let r = rSrc[offset]
                                            let g = gSrc[offset]

                                            for bit in stride(from: 7, through: 0, by: -1) {
                                                let mask: UInt8 = 1 << bit
                                                let colorIndex = ((g & mask) != 0 ? 4 : 0)
                                                               | ((r & mask) != 0 ? 2 : 0)
                                                               | ((b & mask) != 0 ? 1 : 0)
                                                dst[pixelOffset]     = pr[colorIndex]
                                                dst[pixelOffset + 1] = pg[colorIndex]
                                                dst[pixelOffset + 2] = pb[colorIndex]
                                                dst[pixelOffset + 3] = 0xFF
                                                pixelOffset += 4
                                            }
                                        }

                                        // Copy row to the doubled line below
                                        let dstRow2 = dstRow1 + rowBytes
                                        dst.advanced(by: dstRow2).update(from: dst.advanced(by: dstRow1), count: rowBytes)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Render 400-line monochrome mode into a 400-line buffer.
    /// Blue VRAM = upper 200 lines, Red VRAM = lower 200 lines.
    /// Monochrome: bit=1 → white (palette[7]), bit=0 → black (palette[0]).
    public func render400Line(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        into buffer: inout [UInt8]
    ) {
        let bytesPerLine = 80  // 640 / 8
        let fg = palette[min(7, palette.count - 1)]
        let bg = palette[0]

        blueVRAM.withUnsafeBufferPointer { bluePtr in
            redVRAM.withUnsafeBufferPointer { redPtr in
                buffer.withUnsafeMutableBufferPointer { bufPtr in
                    let dst = bufPtr.baseAddress!
                    let bSrc = bluePtr.baseAddress!
                    let rSrc = redPtr.baseAddress!

                    var pixelOffset = 0

                    // Upper 200 lines from Blue plane
                    for line in 0..<Self.height {
                        let lineOffset = line * bytesPerLine
                        for byteIndex in 0..<bytesPerLine {
                            let byte = bSrc[lineOffset + byteIndex]
                            for bit in stride(from: 7, through: 0, by: -1) {
                                let on = (byte >> bit) & 1
                                dst[pixelOffset]     = on != 0 ? fg.r : bg.r
                                dst[pixelOffset + 1] = on != 0 ? fg.g : bg.g
                                dst[pixelOffset + 2] = on != 0 ? fg.b : bg.b
                                dst[pixelOffset + 3] = 0xFF
                                pixelOffset += 4
                            }
                        }
                    }

                    // Lower 200 lines from Red plane
                    for line in 0..<Self.height {
                        let lineOffset = line * bytesPerLine
                        for byteIndex in 0..<bytesPerLine {
                            let byte = rSrc[lineOffset + byteIndex]
                            for bit in stride(from: 7, through: 0, by: -1) {
                                let on = (byte >> bit) & 1
                                dst[pixelOffset]     = on != 0 ? fg.r : bg.r
                                dst[pixelOffset + 1] = on != 0 ? fg.g : bg.g
                                dst[pixelOffset + 2] = on != 0 ? fg.b : bg.b
                                dst[pixelOffset + 3] = 0xFF
                                pixelOffset += 4
                            }
                        }
                    }
                }
            }
        }
    }

    /// Render 640x200 attribute graphics into a 400-line buffer by doubling each scanline.
    /// Graphics bits come from ORed GVRAM planes; per-cell color/reverse come from text attributes.
    public func renderAttributeGraph200(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        greenVRAM: [UInt8],
        attrData: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        columns80: Bool = true,
        textRows: Int = 25,
        into buffer: inout [UInt8]
    ) {
        let bytesPerLine = 80
        let rowBytes = Self.width * Self.bytesPerPixel
        let attrRows = max(textRows, 1)
        let cellHeight = attrRows <= 20 ? 10 : 8
        let bg = palette[0]

        for line in 0..<Self.height {
            let attrRow = min(line / cellHeight, attrRows - 1)
            let srcOffset = line * bytesPerLine
            let dstRow0 = line * 2 * rowBytes
            let dstRow1 = dstRow0 + rowBytes

            for byteIndex in 0..<bytesPerLine {
                let attr = graphAttribute(
                    attrData: attrData,
                    attrRow: attrRow,
                    cellCol: byteIndex,
                    columns80: columns80
                )
                let color = palette[min(Int((attr >> 5) & 0x07), palette.count - 1)]
                let reverse = (attr & 0x01) != 0
                let brg = blueVRAM[srcOffset + byteIndex]
                    | redVRAM[srcOffset + byteIndex]
                    | greenVRAM[srcOffset + byteIndex]
                let bits = reverse ? (brg ^ 0xFF) : brg

                for bit in stride(from: 7, through: 0, by: -1) {
                    let pixel = byteIndex * 8 + (7 - bit)
                    let srcColor = (bits & (1 << bit)) != 0 ? color : bg
                    let px0 = dstRow0 + pixel * Self.bytesPerPixel
                    let px1 = dstRow1 + pixel * Self.bytesPerPixel

                    buffer[px0] = srcColor.r
                    buffer[px0 + 1] = srcColor.g
                    buffer[px0 + 2] = srcColor.b
                    buffer[px0 + 3] = 0xFF

                    buffer[px1] = srcColor.r
                    buffer[px1 + 1] = srcColor.g
                    buffer[px1 + 2] = srcColor.b
                    buffer[px1 + 3] = 0xFF
                }
            }
        }
    }

    /// Render 640x400 attribute graphics.
    /// Blue plane provides the upper 200 lines, red plane the lower 200 lines.
    /// Per-cell color/reverse come from text attributes.
    public func renderAttributeGraph400(
        blueVRAM: [UInt8],
        redVRAM: [UInt8],
        attrData: [UInt8],
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        columns80: Bool = true,
        textRows: Int = 25,
        into buffer: inout [UInt8]
    ) {
        let bytesPerLine = 80
        let rowBytes = Self.width * Self.bytesPerPixel
        let attrRows = max(textRows, 1)
        let cellHeight = attrRows <= 20 ? 10 : 8
        let bg = palette[0]

        for line in 0..<Self.height400 {
            let attrRow = min((line / 2) / cellHeight, attrRows - 1)
            let srcLine = line < Self.height ? line : (line - Self.height)
            let srcOffset = srcLine * bytesPerLine
            let plane = line < Self.height ? blueVRAM : redVRAM
            let dstRow = line * rowBytes

            for byteIndex in 0..<bytesPerLine {
                let attr = graphAttribute(
                    attrData: attrData,
                    attrRow: attrRow,
                    cellCol: byteIndex,
                    columns80: columns80
                )
                let color = palette[min(Int((attr >> 5) & 0x07), palette.count - 1)]
                let reverse = (attr & 0x01) != 0
                let bits = reverse ? (plane[srcOffset + byteIndex] ^ 0xFF) : plane[srcOffset + byteIndex]

                for bit in stride(from: 7, through: 0, by: -1) {
                    let pixel = byteIndex * 8 + (7 - bit)
                    let srcColor = (bits & (1 << bit)) != 0 ? color : bg
                    let px = dstRow + pixel * Self.bytesPerPixel

                    buffer[px] = srcColor.r
                    buffer[px + 1] = srcColor.g
                    buffer[px + 2] = srcColor.b
                    buffer[px + 3] = 0xFF
                }
            }
        }
    }

    /// Overlay text characters onto the pixel buffer.
    ///
    /// Text VRAM format: character codes at `textData`, attributes at `attrData`.
    /// Each character position has a code byte and an attribute byte.
    ///
    /// Attribute byte (already remapped by `Pc88Bus.remapAttribute` to the QUASI88
    /// internal ATTR_* format — NOT the raw uPD3301 bus byte):
    ///   bit 7-5: color GRB (palette index)
    ///   bit 4:   graph character set
    ///   bit 3:   underline (LOWER)
    ///   bit 2:   upper line (UPPER)
    ///   bit 1:   secret (character hidden)
    ///   bit 0:   reverse
    ///
    /// When `hireso` is true, text is rendered into a 400-line buffer:
    /// cellHeight is doubled (16 for 25-line, 20 for 20-line), each font row
    /// is drawn twice. screenHeight = 400.
    public func renderTextOverlay(
        textData: [UInt8],     // Character codes (cols×rows bytes)
        attrData: [UInt8],     // Attribute bytes (cols×rows bytes)
        fontROM: FontROM,
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        displayEnabled: Bool,
        columns80: Bool = true,
        colorMode: Bool = true,
        attributeGraphMode: Bool = false,
        textRows: Int = 25,
        cursorX: Int = -1,
        cursorY: Int = -1,
        cursorVisible: Bool = false,
        cursorBlock: Bool = false,
        hireso: Bool = false,
        skipLine: Bool = false,
        into buffer: inout [UInt8]
    ) {
        guard displayEnabled || skipLine else { return }

        let textCols = columns80 ? Self.textCols80 : Self.textCols40
        let pixelWidth = columns80 ? Self.charWidth : Self.charWidth * 2  // 40-col: double-width chars
        // Mono mode: always use white (palette 7) for foreground
        let monoFg = palette[min(7, palette.count - 1)]

        // Data always has 80 chars per row from CRTC DMA
        let dataCols = Self.textCols80

        // QUASI88: font height derived from line count, NOT from CRTC charLinesPerRow
        // ≤20 lines → 10px cell (20×10=200), >20 lines → 8px cell (25×8=200)
        // XM8: skip_line doubles char_height (1行飛ばし表示)
        let fontHeight = Self.charHeight  // 8 pixels of font glyph data
        let baseCellHeight = textRows <= 20 ? 10 : 8
        let cellHeight = (hireso ? baseCellHeight * 2 : baseCellHeight) * (skipLine ? 2 : 1)
        let screenHeight = hireso ? Self.height400 : Self.height

        let textCount = textData.count
        let attrCount = attrData.count

        buffer.withUnsafeMutableBufferPointer { bufPtr in
            let dst = bufPtr.baseAddress!

            for row in 0..<textRows {
                for col in 0..<textCols {
                    let charIndex = columns80 ? (row * dataCols + col) : (row * dataCols + col * 2)
                    guard charIndex < textCount else { continue }

                    let charCode = textData[charIndex]
                    let attr = charIndex < attrCount ? attrData[charIndex] : 0xE0

                    if (attr & 0x02) != 0 { continue }  // secret

                    let colorIdx = Int((attr >> 5) & 0x07)
                    var reverse = (attr & 0x01) != 0
                    let underline = (attr & 0x08) != 0
                    let upperline = (attr & 0x04) != 0
                    let isGraph = (attr & 0x10) != 0

                    let isCursorPos: Bool
                    if columns80 {
                        isCursorPos = cursorVisible && cursorY == row && cursorX == col
                    } else {
                        isCursorPos = cursorVisible && cursorY == row && cursorX == col * 2
                    }
                    if isCursorPos && cursorBlock {
                        reverse = !reverse
                    }

                    // BubiC: in attribute-graphics mode, reverse cells do not invert
                    // the text glyph. They punch the glyph out with palette 0 while
                    // the graphics renderer handles the cell inversion.
                    let usesAttributeGraphMask = attributeGraphMode && reverse
                    let fg = usesAttributeGraphMask
                        ? palette[0]
                        : (colorMode ? palette[min(colorIdx, palette.count - 1)] : monoFg)

                    for cellRow in 0..<cellHeight {
                        let screenY = row * cellHeight + cellRow
                        guard screenY < screenHeight else { break }

                        // In hireso mode, each font row is drawn twice
                        let fontRow = hireso ? cellRow / 2 : cellRow

                        var rowBits: UInt8
                        if fontRow < fontHeight {
                            rowBits = isGraph
                                ? fontROM.sgGlyphRow(code: charCode, row: fontRow)
                                : fontROM.glyphRow(code: charCode, row: fontRow)
                        } else {
                            rowBits = 0x00
                        }

                        // vraminfo #50: `rowBits = 0xFF` combined with reverse (which
                        // flips foreground to `bit == 0`) draws no pixels on the line
                        // row, leaving a gap in the reverse-filled cell. That gap is
                        // the "color-inverted (black) line" the spec describes.
                        if underline && cellRow == cellHeight - 1 {
                            rowBits = 0xFF
                        }
                        if upperline && cellRow == 0 {
                            rowBits = 0xFF
                        }
                        if isCursorPos && !cursorBlock && cellRow == cellHeight - 1 {
                            rowBits = 0xFF
                        }

                        let repeatCount = columns80 ? 1 : 2
                        let rowBase = screenY * Self.width

                        for glyphCol in 0..<Self.charWidth {
                            let bit = (rowBits >> (7 - glyphCol)) & 1
                            let isForeground = usesAttributeGraphMask ? (bit != 0) : (reverse ? (bit == 0) : (bit != 0))

                            // QUASI88: style bit ON → DST_T (text color), OFF → DST_V (GVRAM).
                            // Only write foreground pixels. Background is transparent (GVRAM).
                            if isForeground {
                                let color = fg
                                for px in 0..<repeatCount {
                                    let screenX = col * pixelWidth + glyphCol * repeatCount + px
                                    guard screenX < Self.width else { continue }
                                    let pixelOffset = (rowBase + screenX) * Self.bytesPerPixel
                                    dst[pixelOffset]     = color.r
                                    dst[pixelOffset + 1] = color.g
                                    dst[pixelOffset + 2] = color.b
                                }
                            }
                        }
                    }
                }
            }

            // Fill uncovered lines with background color.
            // XM8: memset(text,8) + height<25 leaves bottom lines masked.
            let coveredLines = textRows * cellHeight
            if coveredLines < screenHeight {
                let bg = palette[0]
                for screenY in coveredLines..<screenHeight {
                    let rowBase = screenY * Self.width
                    for x in 0..<Self.width {
                        let off = (rowBase + x) * Self.bytesPerPixel
                        dst[off] = bg.r; dst[off+1] = bg.g; dst[off+2] = bg.b
                    }
                }
            }
        }
    }

    @inline(__always)
    private func graphAttribute(
        attrData: [UInt8],
        attrRow: Int,
        cellCol: Int,
        columns80: Bool
    ) -> UInt8 {
        let col = columns80 ? cellCol : (cellCol & ~1)
        let index = attrRow * Self.textCols80 + min(col, Self.textCols80 - 1)
        if index < attrData.count {
            return attrData[index]
        }
        return 0xE0
    }
}
