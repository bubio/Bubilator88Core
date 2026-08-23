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

  /// Alpha value stamped on text-layer pixels when `markTextPixels` is on.
  /// Still effectively opaque, so nothing downstream renders differently —
  /// it only exists for the display shader to test against.
  public static let textPixelAlphaTag: UInt8 = 0xFE

  /// Bit-spread lookup table: byte *j* of `spreadLUT[x]` holds bit (7 - j) of `x`.
  /// One load turns a VRAM byte into eight 0/1 pixel selectors, replacing the
  /// per-bit mask-and-branch chain in the scanline loops.
  static let spreadLUT: [UInt64] = (0..<256).map { byte in
    var value: UInt64 = 0
    for j in 0..<8 {
      value |= UInt64((byte >> (7 - j)) & 1) << (UInt64(j) * 8)
    }
    return value
  }

  /// Pack a palette entry into one RGBA8888 word.
  ///
  /// The byte order below assumes a little-endian store so that r lands at
  /// offset 0 — this must match the `premultipliedLast` layout the pixel
  /// buffer is handed to CoreGraphics/Metal with.
  @inline(__always)
  static func packRGBA(_ color: (r: UInt8, g: UInt8, b: UInt8)) -> UInt32 {
    UInt32(color.r)
      | (UInt32(color.g) << 8)
      | (UInt32(color.b) << 16)
      | 0xFF00_0000
  }

  /// Pack up to 8 palette entries into RGBA words, padding with opaque black.
  static func packedPalette(_ palette: [(r: UInt8, g: UInt8, b: UInt8)]) -> [UInt32] {
    var packed = [UInt32](repeating: 0xFF00_0000, count: 8)
    for i in 0..<min(palette.count, 8) {
      packed[i] = packRGBA(palette[i])
    }
    return packed
  }

  /// Convert one 640-pixel color-graphics scanline (80 bytes × 3 planes) into
  /// RGBA words. `dst` points at the first pixel of the destination row.
  ///
  /// The three plane bytes are spread to one byte per pixel and combined into
  /// a single UInt64 holding eight 3-bit palette indices — the bit-plane
  /// interleave the PC-8801 does in hardware, done 8 pixels at a time.
  @inline(__always)
  private static func renderColorScanline(
    blue: UnsafePointer<UInt8>,
    red: UnsafePointer<UInt8>,
    green: UnsafePointer<UInt8>,
    srcOffset: Int,
    bytesPerLine: Int,
    palette: UnsafePointer<UInt32>,
    spread: UnsafePointer<UInt64>,
    dst: UnsafeMutablePointer<UInt32>
  ) {
    var pixelOffset = 0
    for byteIndex in 0..<bytesPerLine {
      let offset = srcOffset + byteIndex
      var indices = spread[Int(blue[offset])]
        | (spread[Int(red[offset])] << 1)
        | (spread[Int(green[offset])] << 2)
      for pixel in 0..<8 {
        dst[pixelOffset + pixel] = palette[Int(indices & 7)]
        indices >>= 8
      }
      pixelOffset += 8
    }
  }

  /// Write the 8 pixels of one attribute-graphics cell byte. Set plane bits
  /// take the cell's attribute color, clear bits take the background.
  /// `dst` points at the first of the 8 destination pixels.
  @inline(__always)
  private static func emitAttributeCell(
    bits: UInt8,
    color: UInt32,
    background: UInt32,
    spread: UnsafePointer<UInt64>,
    dst: UnsafeMutablePointer<UInt32>
  ) {
    var selectors = spread[Int(bits)]
    for pixel in 0..<8 {
      // 0xFFFFFFFF when the plane bit is set, 0 otherwise — keeps the
      // foreground/background choice branchless.
      let mask = UInt32(0) &- UInt32(truncatingIfNeeded: selectors & 1)
      dst[pixel] = (color & mask) | (background & ~mask)
      selectors >>= 8
    }
  }

  /// Resolve the per-cell color and reverse-XOR tables used by the
  /// attribute-graphics modes.
  ///
  /// Attributes are constant down a whole attribute row, so both renderers
  /// build these once instead of re-deriving them on every scanline.
  /// `reverse` is folded into an XOR mask (0x00 / 0xFF) so the pixel loop
  /// needs no branch.
  private func fillAttributeCellTables(
    attrData: [UInt8],
    palette: [(r: UInt8, g: UInt8, b: UInt8)],
    columns80: Bool,
    attrRows: Int,
    cellsPerRow: Int,
    color: UnsafeMutablePointer<UInt32>,
    xor: UnsafeMutablePointer<UInt8>
  ) {
    for row in 0..<attrRows {
      for cell in 0..<cellsPerRow {
        let attr = graphAttribute(
          attrData: attrData,
          attrRow: row,
          cellCol: cell,
          columns80: columns80
        )
        let index = row * cellsPerRow + cell
        color[index] = Self.packRGBA(palette[min(Int((attr >> 5) & 0x07), palette.count - 1)])
        xor[index] = (attr & 0x01) != 0 ? 0xFF : 0x00
      }
    }
  }

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
    let packed = Self.packedPalette(palette)

    blueVRAM.withUnsafeBufferPointer { bluePtr in
      redVRAM.withUnsafeBufferPointer { redPtr in
        greenVRAM.withUnsafeBufferPointer { greenPtr in
          packed.withUnsafeBufferPointer { palPtr in
            Self.spreadLUT.withUnsafeBufferPointer { spreadPtr in
              buffer.withUnsafeMutableBufferPointer { bufPtr in
                let dst = UnsafeMutableRawPointer(bufPtr.baseAddress!)
                  .assumingMemoryBound(to: UInt32.self)

                for line in 0..<Self.height {
                  Self.renderColorScanline(
                    blue: bluePtr.baseAddress!,
                    red: redPtr.baseAddress!,
                    green: greenPtr.baseAddress!,
                    srcOffset: line * bytesPerLine,
                    bytesPerLine: bytesPerLine,
                    palette: palPtr.baseAddress!,
                    spread: spreadPtr.baseAddress!,
                    dst: dst + line * Self.width
                  )
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
    let rowBytes = Self.width * Self.bytesPerPixel
    let packed = Self.packedPalette(palette)

    blueVRAM.withUnsafeBufferPointer { bluePtr in
      redVRAM.withUnsafeBufferPointer { redPtr in
        greenVRAM.withUnsafeBufferPointer { greenPtr in
          packed.withUnsafeBufferPointer { palPtr in
            Self.spreadLUT.withUnsafeBufferPointer { spreadPtr in
              buffer.withUnsafeMutableBufferPointer { bufPtr in
                let dst = UnsafeMutableRawPointer(bufPtr.baseAddress!)
                  .assumingMemoryBound(to: UInt32.self)

                for line in 0..<Self.height {
                  let dstRow = dst + line * 2 * Self.width
                  Self.renderColorScanline(
                    blue: bluePtr.baseAddress!,
                    red: redPtr.baseAddress!,
                    green: greenPtr.baseAddress!,
                    srcOffset: line * bytesPerLine,
                    bytesPerLine: bytesPerLine,
                    palette: palPtr.baseAddress!,
                    spread: spreadPtr.baseAddress!,
                    dst: dstRow
                  )

                  // Copy row to the doubled line below
                  UnsafeMutableRawPointer(dstRow + Self.width)
                    .copyMemory(from: UnsafeRawPointer(dstRow), byteCount: rowBytes)
                }
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
    graphicsDisplayEnabled: Bool = true,
    into buffer: inout [UInt8]
  ) {
    let bytesPerLine = 80
    let rowPixels = Self.width
    let rowBytes = rowPixels * Self.bytesPerPixel
    let attrRows = max(textRows, 1)
    let cellHeight = attrRows <= 20 ? 10 : 8
    let bg32 = Self.packRGBA(palette[0])

    let cellCount = attrRows * bytesPerLine
    let cellColor = UnsafeMutablePointer<UInt32>.allocate(capacity: cellCount)
    let cellXor = UnsafeMutablePointer<UInt8>.allocate(capacity: cellCount)
    defer {
      cellColor.deallocate()
      cellXor.deallocate()
    }
    fillAttributeCellTables(
      attrData: attrData,
      palette: palette,
      columns80: columns80,
      attrRows: attrRows,
      cellsPerRow: bytesPerLine,
      color: cellColor,
      xor: cellXor
    )

    blueVRAM.withUnsafeBufferPointer { bluePtr in
      redVRAM.withUnsafeBufferPointer { redPtr in
        greenVRAM.withUnsafeBufferPointer { greenPtr in
          Self.spreadLUT.withUnsafeBufferPointer { spreadPtr in
            buffer.withUnsafeMutableBufferPointer { bufPtr in
              let dst = UnsafeMutableRawPointer(bufPtr.baseAddress!)
                .assumingMemoryBound(to: UInt32.self)
              let bSrc = bluePtr.baseAddress!
              let rSrc = redPtr.baseAddress!
              let gSrc = greenPtr.baseAddress!
              let spread = spreadPtr.baseAddress!

              for line in 0..<Self.height {
                let attrBase = min(line / cellHeight, attrRows - 1) * bytesPerLine
                let srcOffset = line * bytesPerLine
                let dstRow0 = line * 2 * rowPixels
                var pixelOffset = dstRow0

                for byteIndex in 0..<bytesPerLine {
                  // When graphics display is disabled, the attribute-graph XOR
                  // semantics (reverse ⇒ invert plane bits) don't apply — the
                  // text overlay handles reverse itself. Leave the cell as all
                  // background so text glyph "transparent" pixels fall through
                  // to bg color, not to 0xFF-invert fill.
                  var bits: UInt8 = 0
                  if graphicsDisplayEnabled {
                    let brg = bSrc[srcOffset + byteIndex]
                      | rSrc[srcOffset + byteIndex]
                      | gSrc[srcOffset + byteIndex]
                    bits = brg ^ cellXor[attrBase + byteIndex]
                  }

                  Self.emitAttributeCell(
                    bits: bits,
                    color: cellColor[attrBase + byteIndex],
                    background: bg32,
                    spread: spread,
                    dst: dst + pixelOffset
                  )
                  pixelOffset += 8
                }

                // Copy the completed row to the doubled line below.
                UnsafeMutableRawPointer(dst + dstRow0 + rowPixels)
                  .copyMemory(from: UnsafeRawPointer(dst + dstRow0), byteCount: rowBytes)
              }
            }
          }
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
    graphicsDisplayEnabled: Bool = true,
    into buffer: inout [UInt8]
  ) {
    let bytesPerLine = 80
    let attrRows = max(textRows, 1)
    let cellHeight = attrRows <= 20 ? 10 : 8
    let bg32 = Self.packRGBA(palette[0])

    let cellCount = attrRows * bytesPerLine
    let cellColor = UnsafeMutablePointer<UInt32>.allocate(capacity: cellCount)
    let cellXor = UnsafeMutablePointer<UInt8>.allocate(capacity: cellCount)
    defer {
      cellColor.deallocate()
      cellXor.deallocate()
    }
    fillAttributeCellTables(
      attrData: attrData,
      palette: palette,
      columns80: columns80,
      attrRows: attrRows,
      cellsPerRow: bytesPerLine,
      color: cellColor,
      xor: cellXor
    )

    blueVRAM.withUnsafeBufferPointer { bluePtr in
      redVRAM.withUnsafeBufferPointer { redPtr in
        Self.spreadLUT.withUnsafeBufferPointer { spreadPtr in
          buffer.withUnsafeMutableBufferPointer { bufPtr in
            let dst = UnsafeMutableRawPointer(bufPtr.baseAddress!)
              .assumingMemoryBound(to: UInt32.self)
            let bSrc = bluePtr.baseAddress!
            let rSrc = redPtr.baseAddress!
            let spread = spreadPtr.baseAddress!

            for line in 0..<Self.height400 {
              let attrBase = min((line / 2) / cellHeight, attrRows - 1) * bytesPerLine
              let srcLine = line < Self.height ? line : (line - Self.height)
              let srcOffset = srcLine * bytesPerLine
              let plane = line < Self.height ? bSrc : rSrc
              var pixelOffset = line * Self.width

              for byteIndex in 0..<bytesPerLine {
                // See renderAttributeGraph200 comment — when graphics display is
                // off, skip the attribute-graph XOR so reverse text cells don't
                // pre-fill to white and hide text-overlay glyphs.
                var bits: UInt8 = 0
                if graphicsDisplayEnabled {
                  bits = plane[srcOffset + byteIndex] ^ cellXor[attrBase + byteIndex]
                }

                Self.emitAttributeCell(
                  bits: bits,
                  color: cellColor[attrBase + byteIndex],
                  background: bg32,
                  spread: spread,
                  dst: dst + pixelOffset
                )
                pixelOffset += 8
              }
            }
          }
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
  /// When `is400Line` is true, text is rendered into a 400-line buffer:
  /// cellHeight is doubled (16 for 25-line, 20 for 20-line), each font row
  /// is drawn twice. screenHeight = 400.
  ///
  /// This is the software display mode (port 0x31 bit 0), not the attached
  /// monitor. `MonitorType` is a separate axis: a 24kHz monitor stays 24kHz
  /// whether software is showing 200 or 400 lines. The parameter was called
  /// `hireso` after XM8, which uses that name for the monitor — do not
  /// re-conflate them.
  ///
  /// `markTextPixels` tags every pixel this pass paints with alpha 0xFE so the
  /// display shader can tell text apart from graphics (XM8's SDL port exempts
  /// text from its scanline dimming this way). Alpha is opaque either way — the
  /// graphics renderers rewrite the whole buffer with 0xFF every frame, so the
  /// tag never survives into the next one. Off by default: only the on-screen
  /// render path sets it, keeping snapshots and the AI upscaler input untouched.
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
    is400Line: Bool = false,
    skipLine: Bool = false,
    markTextPixels: Bool = false,
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
    // XM8: skip_line doubles char_height (every other line is displayed)
    let fontHeight = Self.charHeight  // 8 pixels of font glyph data
    let baseCellHeight = textRows <= 20 ? 10 : 8
    let cellHeight = (is400Line ? baseCellHeight * 2 : baseCellHeight) * (skipLine ? 2 : 1)
    let screenHeight = is400Line ? Self.height400 : Self.height

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

          // The attribute-graph mask draws set bits like a normal cell, so
          // both collapse to one flag: does a clear bit paint foreground?
          let inverted = usesAttributeGraphMask ? false : reverse

          // Fetch the glyph once per cell rather than once per scanline —
          // in 400-line mode every font row is drawn twice — and pack the 8 rows
          // into a word so the blank test below is a single comparison.
          var glyph: UInt64 = 0
          for fontRow in 0..<fontHeight {
            let bits = isGraph
              ? fontROM.sgGlyphRow(code: charCode, row: fontRow)
              : fontROM.glyphRow(code: charCode, row: fontRow)
            glyph |= UInt64(bits) << (UInt64(fontRow) * 8)
          }

          // A blank glyph paints nothing unless something else fills a row:
          // `inverted` makes every clear bit foreground, and the line/cursor
          // decorations force a row to 0xFF. Skipping here is what keeps a
          // screen full of spaces cheap.
          if glyph == 0 && !inverted && !underline && !upperline && !isCursorPos {
            continue
          }

          let repeatCount = columns80 ? 1 : 2

          for cellRow in 0..<cellHeight {
            let screenY = row * cellHeight + cellRow
            guard screenY < screenHeight else { break }

            // In 400-line mode, each font row is drawn twice
            let fontRow = is400Line ? cellRow / 2 : cellRow

            var rowBits: UInt8 = fontRow < fontHeight
              ? UInt8(truncatingIfNeeded: glyph >> (UInt64(fontRow) * 8))
              : 0x00

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

            // Foreground pixels as an 8-bit mask, MSB = leftmost pixel.
            let foreground = inverted ? ~rowBits : rowBits
            if foreground == 0 { continue }

            let rowBase = screenY * Self.width

            for glyphCol in 0..<Self.charWidth {
              // QUASI88: style bit ON → DST_T (text color), OFF → DST_V (GVRAM).
              // Only write foreground pixels. Background is transparent (GVRAM).
              guard (foreground & (0x80 >> UInt8(glyphCol))) != 0 else { continue }

              for px in 0..<repeatCount {
                // screenX cannot reach `width`: 80-col tops out at
                // 79*8+7 and 40-col at 39*16+7*2+1, both 639.
                let screenX = col * pixelWidth + glyphCol * repeatCount + px
                let pixelOffset = (rowBase + screenX) * Self.bytesPerPixel
                dst[pixelOffset]     = fg.r
                dst[pixelOffset + 1] = fg.g
                dst[pixelOffset + 2] = fg.b
                if markTextPixels {
                  dst[pixelOffset + 3] = Self.textPixelAlphaTag
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
