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
