import Testing
@testable import EmulatorCore

/// Differential tests that pin the optimized scanline loops in `ScreenRenderer`
/// to a naive, obviously-correct reference implementation.
///
/// The production renderers use bit-spread LUTs, packed RGBA words and unsafe
/// pointers. The references below are the plain, one-pixel-at-a-time versions
/// those replaced — they are deliberately slow and dumb so they are easy to
/// read against the hardware docs.
///
/// This suite exists because `scripts/regression_compare.py` does NOT cover
/// every renderer path: as of 2026-08-03 none of its 19 captures reach
/// `renderAttributeGraph200` (verified by instrumenting the BootTester
/// dispatch), since the suite's games all boot into color graphics mode.
/// A byte-identity check here is what makes those loops safe to optimize.
@Suite("ScreenRenderer Differential Tests")
struct ScreenRendererDifferentialTests {

  // MARK: - Reference implementations

  /// Naive reference for `ScreenRenderer.renderAttributeGraph200`.
  private func referenceAttributeGraph200(
    blueVRAM: [UInt8],
    redVRAM: [UInt8],
    greenVRAM: [UInt8],
    attrData: [UInt8],
    palette: [(r: UInt8, g: UInt8, b: UInt8)],
    columns80: Bool,
    textRows: Int,
    graphicsDisplayEnabled: Bool,
    into buffer: inout [UInt8]
  ) {
    let bytesPerLine = 80
    let rowBytes = ScreenRenderer.width * ScreenRenderer.bytesPerPixel
    let attrRows = max(textRows, 1)
    let cellHeight = attrRows <= 20 ? 10 : 8
    let bg = palette[0]

    for line in 0..<ScreenRenderer.height {
      let attrRow = min(line / cellHeight, attrRows - 1)
      let srcOffset = line * bytesPerLine
      let dstRow0 = line * 2 * rowBytes
      let dstRow1 = dstRow0 + rowBytes

      for byteIndex in 0..<bytesPerLine {
        let col = columns80 ? byteIndex : (byteIndex & ~1)
        let attrIndex = attrRow * ScreenRenderer.textCols80
          + min(col, ScreenRenderer.textCols80 - 1)
        let attr = attrIndex < attrData.count ? attrData[attrIndex] : 0xE0

        let color = palette[min(Int((attr >> 5) & 0x07), palette.count - 1)]
        let reverse = (attr & 0x01) != 0

        let bits: UInt8
        if graphicsDisplayEnabled {
          let brg = blueVRAM[srcOffset + byteIndex]
            | redVRAM[srcOffset + byteIndex]
            | greenVRAM[srcOffset + byteIndex]
          bits = reverse ? (brg ^ 0xFF) : brg
        } else {
          bits = 0
        }

        for bit in stride(from: 7, through: 0, by: -1) {
          let pixel = byteIndex * 8 + (7 - bit)
          let srcColor = (bits & (1 << bit)) != 0 ? color : bg
          let px0 = dstRow0 + pixel * ScreenRenderer.bytesPerPixel
          let px1 = dstRow1 + pixel * ScreenRenderer.bytesPerPixel

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

  /// Naive reference for `ScreenRenderer.renderAttributeGraph400`.
  private func referenceAttributeGraph400(
    blueVRAM: [UInt8],
    redVRAM: [UInt8],
    attrData: [UInt8],
    palette: [(r: UInt8, g: UInt8, b: UInt8)],
    columns80: Bool,
    textRows: Int,
    graphicsDisplayEnabled: Bool,
    into buffer: inout [UInt8]
  ) {
    let bytesPerLine = 80
    let rowBytes = ScreenRenderer.width * ScreenRenderer.bytesPerPixel
    let attrRows = max(textRows, 1)
    let cellHeight = attrRows <= 20 ? 10 : 8
    let bg = palette[0]

    for line in 0..<ScreenRenderer.height400 {
      let attrRow = min((line / 2) / cellHeight, attrRows - 1)
      let srcLine = line < ScreenRenderer.height ? line : (line - ScreenRenderer.height)
      let srcOffset = srcLine * bytesPerLine
      let plane = line < ScreenRenderer.height ? blueVRAM : redVRAM
      let dstRow = line * rowBytes

      for byteIndex in 0..<bytesPerLine {
        let col = columns80 ? byteIndex : (byteIndex & ~1)
        let attrIndex = attrRow * ScreenRenderer.textCols80
          + min(col, ScreenRenderer.textCols80 - 1)
        let attr = attrIndex < attrData.count ? attrData[attrIndex] : 0xE0

        let color = palette[min(Int((attr >> 5) & 0x07), palette.count - 1)]
        let reverse = (attr & 0x01) != 0

        let bits: UInt8
        if graphicsDisplayEnabled {
          let planeByte = plane[srcOffset + byteIndex]
          bits = reverse ? (planeByte ^ 0xFF) : planeByte
        } else {
          bits = 0
        }

        for bit in stride(from: 7, through: 0, by: -1) {
          let pixel = byteIndex * 8 + (7 - bit)
          let srcColor = (bits & (1 << bit)) != 0 ? color : bg
          let px = dstRow + pixel * ScreenRenderer.bytesPerPixel

          buffer[px] = srcColor.r
          buffer[px + 1] = srcColor.g
          buffer[px + 2] = srcColor.b
          buffer[px + 3] = 0xFF
        }
      }
    }
  }

  /// Naive reference for the color-graphics plane interleave shared by
  /// `renderWithPalette` (200 lines) and `renderDoubled` (each row twice).
  private func referenceColorGraphics(
    blueVRAM: [UInt8],
    redVRAM: [UInt8],
    greenVRAM: [UInt8],
    palette: [(r: UInt8, g: UInt8, b: UInt8)],
    doubled: Bool,
    into buffer: inout [UInt8]
  ) {
    let bytesPerLine = 80
    let rowBytes = ScreenRenderer.width * ScreenRenderer.bytesPerPixel
    // Entries past the end of a short palette read as opaque black.
    let entry: (Int) -> (r: UInt8, g: UInt8, b: UInt8) = { index in
      index < palette.count ? palette[index] : (r: 0, g: 0, b: 0)
    }

    for line in 0..<ScreenRenderer.height {
      let lineOffset = line * bytesPerLine
      let dstRow = (doubled ? line * 2 : line) * rowBytes
      var pixelOffset = dstRow

      for byteIndex in 0..<bytesPerLine {
        let offset = lineOffset + byteIndex
        let b = blueVRAM[offset]
        let r = redVRAM[offset]
        let g = greenVRAM[offset]

        for bit in stride(from: 7, through: 0, by: -1) {
          let mask: UInt8 = 1 << bit
          let colorIndex = ((g & mask) != 0 ? 4 : 0)
            | ((r & mask) != 0 ? 2 : 0)
            | ((b & mask) != 0 ? 1 : 0)
          let color = entry(colorIndex)
          buffer[pixelOffset] = color.r
          buffer[pixelOffset + 1] = color.g
          buffer[pixelOffset + 2] = color.b
          buffer[pixelOffset + 3] = 0xFF
          pixelOffset += 4
        }
      }

      if doubled {
        for i in 0..<rowBytes {
          buffer[dstRow + rowBytes + i] = buffer[dstRow + i]
        }
      }
    }
  }

  /// Naive reference for `ScreenRenderer.renderTextOverlay` — the
  /// pre-optimization implementation, kept verbatim apart from qualifying
  /// `Self.` as `ScreenRenderer.`.
  private func referenceTextOverlay(
    textData: [UInt8],
    attrData: [UInt8],
    fontROM: FontROM,
    palette: [(r: UInt8, g: UInt8, b: UInt8)],
    displayEnabled: Bool,
    columns80: Bool,
    colorMode: Bool,
    attributeGraphMode: Bool,
    textRows: Int,
    cursorX: Int,
    cursorY: Int,
    cursorVisible: Bool,
    cursorBlock: Bool,
    is400Line: Bool,
    skipLine: Bool,
    into buffer: inout [UInt8]
  ) {
    guard displayEnabled || skipLine else { return }

    let textCols = columns80 ? ScreenRenderer.textCols80 : ScreenRenderer.textCols40
    let pixelWidth = columns80 ? ScreenRenderer.charWidth : ScreenRenderer.charWidth * 2  // 40-col: double-width chars
    // Mono mode: always use white (palette 7) for foreground
    let monoFg = palette[min(7, palette.count - 1)]

    // Data always has 80 chars per row from CRTC DMA
    let dataCols = ScreenRenderer.textCols80

    // QUASI88: font height derived from line count, NOT from CRTC charLinesPerRow
    // ≤20 lines → 10px cell (20×10=200), >20 lines → 8px cell (25×8=200)
    // XM8: skip_line doubles char_height (every other line is displayed)
    let fontHeight = ScreenRenderer.charHeight  // 8 pixels of font glyph data
    let baseCellHeight = textRows <= 20 ? 10 : 8
    let cellHeight = (is400Line ? baseCellHeight * 2 : baseCellHeight) * (skipLine ? 2 : 1)
    let screenHeight = is400Line ? ScreenRenderer.height400 : ScreenRenderer.height

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

            // In is400Line mode, each font row is drawn twice
            let fontRow = is400Line ? cellRow / 2 : cellRow

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
            let rowBase = screenY * ScreenRenderer.width

            for glyphCol in 0..<ScreenRenderer.charWidth {
              let bit = (rowBits >> (7 - glyphCol)) & 1
              let isForeground = usesAttributeGraphMask ? (bit != 0) : (reverse ? (bit == 0) : (bit != 0))

              // QUASI88: style bit ON → DST_T (text color), OFF → DST_V (GVRAM).
              // Only write foreground pixels. Background is transparent (GVRAM).
              if isForeground {
                let color = fg
                for px in 0..<repeatCount {
                  let screenX = col * pixelWidth + glyphCol * repeatCount + px
                  guard screenX < ScreenRenderer.width else { continue }
                  let pixelOffset = (rowBase + screenX) * ScreenRenderer.bytesPerPixel
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
          let rowBase = screenY * ScreenRenderer.width
          for x in 0..<ScreenRenderer.width {
            let off = (rowBase + x) * ScreenRenderer.bytesPerPixel
            dst[off] = bg.r; dst[off+1] = bg.g; dst[off+2] = bg.b
          }
        }
      }
    }
  }

  // MARK: - Deterministic test data

  /// xorshift32 — a fixed generator so failures reproduce exactly.
  private struct Xorshift32 {
    var state: UInt32
    mutating func next() -> UInt32 {
      state ^= state << 13
      state ^= state >> 17
      state ^= state << 5
      return state
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() >> 16) }
    mutating func bytes(_ count: Int) -> [UInt8] {
      var out = [UInt8]()
      out.reserveCapacity(count)
      for _ in 0..<count { out.append(byte()) }
      return out
    }
  }

  // MARK: - Tests

  @Test("renderAttributeGraph200 matches the naive reference byte for byte")
  func attributeGraph200MatchesReference() {
    let renderer = ScreenRenderer()
    var rng = Xorshift32(state: 0x8801_1988)

    // The selectors below cycle every 2, 3 and 5 trials, so 30 trials cover
    // every combination exactly once. More would only re-run the same shapes
    // against fresh noise, and the reference renderer is slow in debug builds.
    for trial in 0..<30 {
      let blue = rng.bytes(0x4000)
      let red = rng.bytes(0x4000)
      let green = rng.bytes(0x4000)

      // Sweep every branch: 40/80 columns, the 8px and 10px cell heights,
      // the attrRows clamp, graphics enable, short palettes, and attrData
      // short enough to hit the 0xE0 fallback.
      let columns80 = trial % 2 == 0
      let textRows = [25, 20, 1, 24, 30][trial % 5]
      let graphicsDisplayEnabled = (trial / 2) % 2 == 0
      let paletteCount = [8, 8, 8, 3, 1][trial % 5]
      let palette: [(r: UInt8, g: UInt8, b: UInt8)] = trial % 3 == 0
        ? Array(ScreenRenderer.defaultPalette.prefix(paletteCount))
        : (0..<paletteCount).map { _ in (r: rng.byte(), g: rng.byte(), b: rng.byte()) }
      let attrData = rng.bytes([80 * 25, 80 * 25, 80 * 10, 0, 137][trial % 5])

      // Pre-fill with a non-zero pattern so a renderer that skips pixels
      // instead of writing them is caught rather than silently matching.
      var actual = Array(repeating: UInt8(0x5A), count: ScreenRenderer.bufferSize400)
      var expected = actual

      renderer.renderAttributeGraph200(
        blueVRAM: blue, redVRAM: red, greenVRAM: green, attrData: attrData,
        palette: palette, columns80: columns80, textRows: textRows,
        graphicsDisplayEnabled: graphicsDisplayEnabled, into: &actual
      )
      referenceAttributeGraph200(
        blueVRAM: blue, redVRAM: red, greenVRAM: green, attrData: attrData,
        palette: palette, columns80: columns80, textRows: textRows,
        graphicsDisplayEnabled: graphicsDisplayEnabled, into: &expected
      )

      let firstDiff = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
      #expect(
        firstDiff == nil,
        """
        trial \(trial) (cols80=\(columns80) rows=\(textRows) \
        gfx=\(graphicsDisplayEnabled) palette=\(paletteCount) \
        attrLen=\(attrData.count)) diverged at byte \
        \(firstDiff?.offset ?? -1)
        """
      )
    }
  }

  @Test("renderAttributeGraph400 matches the naive reference byte for byte")
  func attributeGraph400MatchesReference() {
    let renderer = ScreenRenderer()
    var rng = Xorshift32(state: 0x0400_1988)

    for trial in 0..<30 {
      let blue = rng.bytes(0x4000)
      let red = rng.bytes(0x4000)

      let columns80 = trial % 2 == 0
      let textRows = [25, 20, 1, 24, 30][trial % 5]
      let graphicsDisplayEnabled = (trial / 2) % 2 == 0
      let paletteCount = [8, 8, 8, 3, 1][trial % 5]
      let palette: [(r: UInt8, g: UInt8, b: UInt8)] = trial % 3 == 0
        ? Array(ScreenRenderer.defaultPalette.prefix(paletteCount))
        : (0..<paletteCount).map { _ in (r: rng.byte(), g: rng.byte(), b: rng.byte()) }
      let attrData = rng.bytes([80 * 25, 80 * 25, 80 * 10, 0, 137][trial % 5])

      var actual = Array(repeating: UInt8(0x5A), count: ScreenRenderer.bufferSize400)
      var expected = actual

      renderer.renderAttributeGraph400(
        blueVRAM: blue, redVRAM: red, attrData: attrData,
        palette: palette, columns80: columns80, textRows: textRows,
        graphicsDisplayEnabled: graphicsDisplayEnabled, into: &actual
      )
      referenceAttributeGraph400(
        blueVRAM: blue, redVRAM: red, attrData: attrData,
        palette: palette, columns80: columns80, textRows: textRows,
        graphicsDisplayEnabled: graphicsDisplayEnabled, into: &expected
      )

      let firstDiff = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
      #expect(
        firstDiff == nil,
        """
        trial \(trial) (cols80=\(columns80) rows=\(textRows) \
        gfx=\(graphicsDisplayEnabled) palette=\(paletteCount) \
        attrLen=\(attrData.count)) diverged at byte \
        \(firstDiff?.offset ?? -1)
        """
      )
    }
  }

  @Test("renderWithPalette and renderDoubled match the naive reference byte for byte")
  func colorGraphicsMatchesReference() {
    let renderer = ScreenRenderer()
    var rng = Xorshift32(state: 0x00C0_1988)

    for trial in 0..<12 {
      let blue = rng.bytes(0x4000)
      let red = rng.bytes(0x4000)
      let green = rng.bytes(0x4000)
      // Short palettes exercise the opaque-black padding for indices 1-7.
      let paletteCount = [8, 8, 3, 1][trial % 4]
      let palette: [(r: UInt8, g: UInt8, b: UInt8)] = trial % 3 == 0
        ? Array(ScreenRenderer.defaultPalette.prefix(paletteCount))
        : (0..<paletteCount).map { _ in (r: rng.byte(), g: rng.byte(), b: rng.byte()) }

      var flat = Array(repeating: UInt8(0x5A), count: ScreenRenderer.bufferSize)
      var flatExpected = flat
      renderer.renderWithPalette(
        blueVRAM: blue, redVRAM: red, greenVRAM: green,
        palette: palette, into: &flat
      )
      referenceColorGraphics(
        blueVRAM: blue, redVRAM: red, greenVRAM: green,
        palette: palette, doubled: false, into: &flatExpected
      )
      #expect(
        flat == flatExpected,
        "renderWithPalette trial \(trial) (palette=\(paletteCount)) diverged"
      )

      var doubled = Array(repeating: UInt8(0x5A), count: ScreenRenderer.bufferSize400)
      var doubledExpected = doubled
      renderer.renderDoubled(
        blueVRAM: blue, redVRAM: red, greenVRAM: green,
        palette: palette, into: &doubled
      )
      referenceColorGraphics(
        blueVRAM: blue, redVRAM: red, greenVRAM: green,
        palette: palette, doubled: true, into: &doubledExpected
      )
      #expect(
        doubled == doubledExpected,
        "renderDoubled trial \(trial) (palette=\(paletteCount)) diverged"
      )
    }
  }

  @Test("renderTextOverlay matches the naive reference byte for byte")
  func textOverlayMatchesReference() {
    let renderer = ScreenRenderer()
    let fontROM = FontROM()
    var rng = Xorshift32(state: 0x7E47_0001)

    for trial in 0..<48 {
      // Sweep the flags that change which pixels are written, and the text
      // mixes that decide whether a cell is blank — blank cells take the
      // early-out, so both sides of that branch need coverage.
      let columns80 = trial % 2 == 0
      let colorMode = (trial / 2) % 2 == 0
      let attributeGraphMode = (trial / 4) % 2 == 0
      let is400Line = (trial / 8) % 2 == 0
      let skipLine = (trial / 16) % 2 == 0
      let textRows = [25, 20, 24][trial % 3]
      let cursorVisible = trial % 3 != 0
      let cursorBlock = (trial / 3) % 2 == 0
      let cursorX = trial % 5 == 0 ? -1 : Int(rng.next() % 80)
      let cursorY = trial % 7 == 0 ? -1 : Int(rng.next() % 25)

      let cellCount = 80 * 25
      let textData: [UInt8]
      switch trial % 4 {
      case 0:  // all blank — the case the early-out targets
        textData = [UInt8](repeating: 0x20, count: cellCount)
      case 1:  // dense glyphs — never blank
        textData = (0..<cellCount).map { _ in UInt8(33 + rng.next() % 94) }
      case 2:  // sparse text over blanks — mixes both branches
        textData = (0..<cellCount).map { i in i % 9 == 0 ? UInt8(33 + rng.next() % 94) : 0x20 }
      default:  // full byte range, including the semigraphic codes
        textData = rng.bytes(cellCount)
      }
      // Attributes drive reverse/underline/upperline/secret/graph, each of
      // which can make an otherwise-blank cell draw something.
      let attrData: [UInt8] = trial % 5 == 0
        ? [UInt8](repeating: 0xE0, count: cellCount)
        : rng.bytes(cellCount)

      let palette: [(r: UInt8, g: UInt8, b: UInt8)] = trial % 3 == 0
        ? ScreenRenderer.defaultPalette
        : (0..<8).map { _ in (r: rng.byte(), g: rng.byte(), b: rng.byte()) }

      let size = is400Line ? ScreenRenderer.bufferSize400 : ScreenRenderer.bufferSize
      // Text overlay only writes foreground pixels, so seed both buffers with
      // the same non-zero pattern: an over-eager skip shows up as leftover 0x5A.
      var actual = Array(repeating: UInt8(0x5A), count: size)
      var expected = actual

      renderer.renderTextOverlay(
        textData: textData, attrData: attrData, fontROM: fontROM, palette: palette,
        displayEnabled: true, columns80: columns80, colorMode: colorMode,
        attributeGraphMode: attributeGraphMode, textRows: textRows,
        cursorX: cursorX, cursorY: cursorY, cursorVisible: cursorVisible,
        cursorBlock: cursorBlock, is400Line: is400Line, skipLine: skipLine, into: &actual
      )
      referenceTextOverlay(
        textData: textData, attrData: attrData, fontROM: fontROM, palette: palette,
        displayEnabled: true, columns80: columns80, colorMode: colorMode,
        attributeGraphMode: attributeGraphMode, textRows: textRows,
        cursorX: cursorX, cursorY: cursorY, cursorVisible: cursorVisible,
        cursorBlock: cursorBlock, is400Line: is400Line, skipLine: skipLine, into: &expected
      )

      let firstDiff = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }
      #expect(
        firstDiff == nil,
        """
        trial \(trial) (cols80=\(columns80) color=\(colorMode) \
        attrGraph=\(attributeGraphMode) is400Line=\(is400Line) skipLine=\(skipLine) \
        rows=\(textRows) cursor=\(cursorX),\(cursorY) visible=\(cursorVisible) \
        block=\(cursorBlock)) diverged at byte \(firstDiff?.offset ?? -1)
        """
      )
    }
  }

  @Test("packRGBA lays bytes out in the buffer's R,G,B,A order")
  func packRGBAByteOrder() {
    // Guards the little-endian assumption in the packed-word store path:
    // the pixel buffer is handed to CoreGraphics as premultipliedLast.
    var word = ScreenRenderer.packRGBA((r: 0x12, g: 0x34, b: 0x56))
    withUnsafeBytes(of: &word) { raw in
      #expect(raw[0] == 0x12)
      #expect(raw[1] == 0x34)
      #expect(raw[2] == 0x56)
      #expect(raw[3] == 0xFF)
    }
  }

  @Test("spreadLUT expands a byte into eight MSB-first pixel selectors")
  func spreadLUTOrdering() {
    #expect(ScreenRenderer.spreadLUT[0x80] == 0x0000_0000_0000_0001)
    #expect(ScreenRenderer.spreadLUT[0x01] == 0x0100_0000_0000_0000)
    #expect(ScreenRenderer.spreadLUT[0xFF] == 0x0101_0101_0101_0101)
    #expect(ScreenRenderer.spreadLUT[0x00] == 0)
    for byte in 0..<256 {
      let entry = ScreenRenderer.spreadLUT[byte]
      for j in 0..<8 {
        let selector = UInt8(truncatingIfNeeded: entry >> (UInt64(j) * 8))
        #expect(selector == UInt8((byte >> (7 - j)) & 1))
      }
    }
  }
}
