// FrameCompositor.swift — turns the machine's video state into one RGBA frame.
//
// Resolves the palettes from the bus, picks the graphics renderer for the
// current mode, and lays the text layer over it. This used to be written out
// twice, in the macOS app (EmulatorViewModel+Rendering.swift) and in CApi for
// the Windows shell, and BootTester had a third that differed; the app and
// CApi now call `PC88.render`, which lands here, and BootTester calls it too.

/// Composites the graphics and text layers of a `Machine` into a 640×400
/// RGBA buffer. Stateless apart from the `ScreenRenderer` it reuses.
package final class FrameCompositor {

  private let renderer = ScreenRenderer()

  package init() {}

  /// - Parameters:
  ///   - blinkCursor: honour the CRTC's cursor blink phase. Pass false while
  ///     the machine is paused, so a frozen frame does not keep blinking.
  ///   - textLayerEnabled: debug switch that hides the text layer.
  ///   - markTextPixels: tag text-layer pixels with
  ///     `ScreenRenderer.textPixelAlphaTag` in the alpha channel, so a display
  ///     shader can exempt them from scanline dimming.
  package func render(
    _ machine: Machine,
    into pixelBuffer: inout [UInt8],
    blinkCursor: Bool,
    textLayerEnabled: Bool = true,
    markTextPixels: Bool = false
  ) {
    let bus = machine.bus
    let crtc = machine.crtc
    let graphicsPalette = Self.effectiveRenderPalette(
      busPalette: bus.palette,
      graphicsColorMode: bus.graphicsColorMode,
      graphicsDisplayEnabled: bus.graphicsDisplayEnabled,
      analogPalette: bus.analogPalette,
      borderColor: bus.borderColor
    )
    let textPalette = Self.effectiveTextPalette(
      busPalette: bus.palette,
      graphicsColorMode: bus.graphicsColorMode,
      analogPalette: bus.analogPalette,
      borderColor: bus.borderColor
    )
    let planes = bus.renderGVRAMPlanes()
    let is400 = bus.is400LineMode
    let textData = bus.readTextVRAM()
    let attrData = bus.readTextAttributes()
    let attributeGraphAttrData = Self.attributeGraphAttributes(
      from: attrData,
      textDisplayMode: bus.textDisplayMode,
      textRows: Int(crtc.linesPerScreen),
      reverseDisplay: crtc.reverseDisplay
    )
    let crtcLines = Int(crtc.linesPerScreen)

    if bus.graphicsColorMode {
      renderer.renderDoubled(
        blueVRAM: planes.blue,
        redVRAM: planes.red,
        greenVRAM: planes.green,
        palette: graphicsPalette,
        into: &pixelBuffer
      )
    } else if is400 {
      renderer.renderAttributeGraph400(
        blueVRAM: planes.blue,
        redVRAM: planes.red,
        attrData: attributeGraphAttrData,
        palette: graphicsPalette,
        columns80: bus.columns80,
        textRows: crtcLines,
        graphicsDisplayEnabled: bus.graphicsDisplayEnabled,
        into: &pixelBuffer
      )
    } else {
      renderer.renderAttributeGraph200(
        blueVRAM: planes.blue,
        redVRAM: planes.red,
        greenVRAM: planes.green,
        attrData: attributeGraphAttrData,
        palette: graphicsPalette,
        columns80: bus.columns80,
        textRows: crtcLines,
        graphicsDisplayEnabled: bus.graphicsDisplayEnabled,
        into: &pixelBuffer
      )
    }

    let cursorVisible: Bool
    if blinkCursor {
      // BubiC pc88.cpp:4179-4181 — cursor toggles twice per blinkRate
      // window (≈ rate/2 cadence), so the visible cursor blinks roughly
      // 2× faster than the attribute BLINK rate.
      cursorVisible = crtc.cursorEnabled && !crtc.blinkCursorOff
    } else {
      cursorVisible = crtc.cursorEnabled
    }

    renderer.renderTextOverlay(
      textData: textData,
      attrData: attrData,
      fontROM: machine.fontROM,
      palette: textPalette,
      displayEnabled: Self.effectiveTextDisplayEnabled(
        busTextDisplayEnabled: bus.textDisplayEnabled,
        debugTextLayerEnabled: textLayerEnabled
      ),
      columns80: bus.columns80,
      colorMode: bus.colorMode,
      attributeGraphMode: bus.graphicsDisplayEnabled && !bus.graphicsColorMode,
      textRows: crtcLines,
      cursorX: crtc.cursorX,
      cursorY: crtc.cursorY,
      cursorVisible: cursorVisible,
      cursorBlock: (crtc.cursorMode & 0x02) != 0,
      // Always true: the pixel buffer is 640×400 regardless of display mode
      // (200-line output is line-doubled into it), so text is drawn at the
      // 400-line cell height to match. Nothing to do with the monitor type.
      is400Line: true,
      skipLine: crtc.skipLine,
      markTextPixels: markTextPixels,
      into: &pixelBuffer
    )
  }

  // MARK: - Palette helpers

  package static func attributeGraphAttributes(
    from attrData: [UInt8],
    textDisplayMode: Pc88Bus.TextDisplayMode,
    textRows: Int,
    reverseDisplay: Bool
  ) -> [UInt8] {
    guard textDisplayMode == .disabled else { return attrData }
    let defaultAttr: UInt8 = 0xE0 | (reverseDisplay ? 0x01 : 0x00)
    return Array(
      repeating: defaultAttr,
      count: max(textRows, 1) * ScreenRenderer.textCols80
    )
  }

  package static func effectiveTextDisplayEnabled(
    busTextDisplayEnabled: Bool,
    debugTextLayerEnabled: Bool
  ) -> Bool {
    busTextDisplayEnabled && debugTextLayerEnabled
  }

  package static func port52BackgroundColor(_ value: UInt8) -> (r: UInt8, g: UInt8, b: UInt8) {
    (
      r: (value & 0x20) != 0 ? 0xFF : 0x00,
      g: (value & 0x40) != 0 ? 0xFF : 0x00,
      b: (value & 0x10) != 0 ? 0xFF : 0x00
    )
  }

  package static func effectiveRenderPalette(
    busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
    graphicsColorMode: Bool,
    graphicsDisplayEnabled: Bool,
    analogPalette: Bool,
    borderColor: UInt8
  ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let programmablePalette = ScreenRenderer.expandPalette(busPalette)
    let backgroundColor = Self.port52BackgroundColor(borderColor)
    var palette = (graphicsColorMode || analogPalette)
      ? programmablePalette
      : ScreenRenderer.defaultPalette
    if !graphicsColorMode {
      palette[0] = backgroundColor
    }
    // BubiC forces palette index 0 to black while color graphics output is disabled.
    // Without this, transient graphics-off frames inherit the programmable palette[0]
    // and can flash as a full-screen color instead of black.
    if graphicsColorMode && !graphicsDisplayEnabled {
      palette[0] = ScreenRenderer.defaultPalette[0]
    }
    return palette
  }

  package static func effectiveTextPalette(
    busPalette: [(b: UInt8, r: UInt8, g: UInt8)],
    graphicsColorMode: Bool,
    analogPalette: Bool,
    borderColor: UInt8
  ) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    let programmablePalette = ScreenRenderer.expandPalette(busPalette)
    let backgroundColor = Self.port52BackgroundColor(borderColor)
    // BubiC keeps text colors on the fixed digital palette except in analog
    // attribute-graphics mode. Entry 0 is still special: hi-color tracks the
    // programmable palette 0, while non-hi-color uses the port 0x52 background.
    var palette = analogPalette && !graphicsColorMode
      ? programmablePalette
      : ScreenRenderer.defaultPalette
    if graphicsColorMode {
      palette[0] = programmablePalette[0]
    } else {
      palette[0] = backgroundColor
    }
    return palette
  }
}
