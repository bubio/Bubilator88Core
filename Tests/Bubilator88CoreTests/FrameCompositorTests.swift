import Testing
@_spi(Debug) @testable import Bubilator88Core

/// The palette and attribute helpers `FrameCompositor` composites with.
/// Moved from the app's EmulatorViewModelTests / RenderingHelperTests along
/// with the code.
@Suite("FrameCompositor Tests")
struct FrameCompositorTests {

  @Test("attribute graphics ignore stale attrs when text display is disabled")
  func attributeGraphAttributesNeutralizedWhenTextDisplayDisabled() {
    let attrData = Array(repeating: UInt8(0xFF), count: 80 * 25)

    let result = FrameCompositor.attributeGraphAttributes(
      from: attrData,
      textDisplayMode: .disabled,
      textRows: 25,
      reverseDisplay: false
    )

    #expect(result.count == 80 * 25)
    #expect(result[0] == 0xE0)
    #expect(result[79] == 0xE0)
  }

  @Test("attribute graphics keep attrs in attributes-only mode")
  func attributeGraphAttributesPreserveAttributesOnlyMode() {
    var attrData = Array(repeating: UInt8(0xE0), count: 80 * 25)
    attrData[0] = 0xE1

    let result = FrameCompositor.attributeGraphAttributes(
      from: attrData,
      textDisplayMode: .attributesOnly,
      textRows: 25,
      reverseDisplay: false
    )

    #expect(result == attrData)
  }

  @Test("attribute graphics keep reverse default when display is disabled")
  func attributeGraphAttributesCarryReverseDisplayIntoNeutralState() {
    let result = FrameCompositor.attributeGraphAttributes(
      from: [],
      textDisplayMode: .disabled,
      textRows: 20,
      reverseDisplay: true
    )

    #expect(result.count == 80 * 20)
    #expect(result[0] == 0xE1)
  }

  /// vraminfo / M88M: stopping the CRTC turns B/W graphics' lit dots to
  /// color 0 and drops reverse; mono text (port 0x30 bit 1) makes it 7.
  @Test("attribute graphics take color 0 while the CRTC is stopped")
  func attributeGraphAttributesColorZeroWhenCRTCStopped() {
    let color = FrameCompositor.attributeGraphAttributes(
      from: [],
      textDisplayMode: .disabled,
      textRows: 25,
      reverseDisplay: true,
      crtcStopped: true,
      monoText: false
    )
    #expect(color.count == 80 * 25)
    #expect(color.allSatisfy { $0 == 0x00 })

    let mono = FrameCompositor.attributeGraphAttributes(
      from: [],
      textDisplayMode: .disabled,
      textRows: 25,
      reverseDisplay: true,
      crtcStopped: true,
      monoText: true
    )
    #expect(mono.allSatisfy { $0 == 0xE0 })
  }

  /// In B/W mode palette[0] is the background; the lit dots of attribute
  /// color 0 take the fixed digital black or the analog palette instead.
  @Test("attribute color 0 is not the B/W background")
  func attributeGraphColorZeroIsNotBackground() {
    var busPalette = Array(repeating: (b: UInt8(0), r: UInt8(0), g: UInt8(0)), count: 8)
    busPalette[0] = (b: 1, r: 2, g: 3)
    #expect(FrameCompositor.attributeGraphColorZero(busPalette: busPalette, analogPalette: false)
      == ScreenRenderer.defaultPalette[0])
    let analog = FrameCompositor.attributeGraphColorZero(busPalette: busPalette, analogPalette: true)
    let expected = ScreenRenderer.expandPalette(busPalette)[0]
    #expect(analog == expected)
  }

  @Test("debug text toggle suppresses overlay rendering")
  func effectiveTextDisplayEnabledRespectsDebugToggle() {
    #expect(
      FrameCompositor.effectiveTextDisplayEnabled(
        busTextDisplayEnabled: true,
        debugTextLayerEnabled: true
      ) == true
    )
    #expect(
      FrameCompositor.effectiveTextDisplayEnabled(
        busTextDisplayEnabled: true,
        debugTextLayerEnabled: false
      ) == false
    )
    #expect(
      FrameCompositor.effectiveTextDisplayEnabled(
        busTextDisplayEnabled: false,
        debugTextLayerEnabled: true
      ) == false
    )
  }

  @Test("color graphics off forces render palette index 0 to black")
  func effectiveRenderPaletteForcesBlackBackgroundWhenColorGraphicsOff() {
    let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
      (b: 0, r: 7, g: 0), // palette 0 = red
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
    ]

    let palette = FrameCompositor.effectiveRenderPalette(
      busPalette: busPalette,
      graphicsColorMode: true,
      graphicsDisplayEnabled: false,
      analogPalette: false,
      borderColor: 0x70,
      analogBackground: (b: 0, r: 0, g: 0)
    )

    #expect(palette[0].r == 0x00)
    #expect(palette[0].g == 0x00)
    #expect(palette[0].b == 0x00)
  }

  @Test("graphics display palette 0 remains programmable when color graphics are visible")
  func effectiveRenderPalettePreservesPaletteWhenGraphicsVisible() {
    let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
      (b: 7, r: 0, g: 7),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
    ]

    let palette = FrameCompositor.effectiveRenderPalette(
      busPalette: busPalette,
      graphicsColorMode: true,
      graphicsDisplayEnabled: true,
      analogPalette: false,
      borderColor: 0x00,
      analogBackground: (b: 0, r: 0, g: 0)
    )

    #expect(palette[0].r == 0x00)
    #expect(palette[0].g == 0xFF)
    #expect(palette[0].b == 0xFF)
  }

  @Test("attribute graphics use port 0x52 background for palette entry 0")
  func effectiveRenderPaletteUsesPort52BackgroundOutsideHiColor() {
    let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
      (b: 7, r: 7, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
    ]

    let palette = FrameCompositor.effectiveRenderPalette(
      busPalette: busPalette,
      graphicsColorMode: false,
      graphicsDisplayEnabled: true,
      analogPalette: false,
      borderColor: 0x50,
      analogBackground: (b: 0, r: 0, g: 0)
    )

    #expect(palette[0].r == 0x00)
    #expect(palette[0].g == 0xFF)
    #expect(palette[0].b == 0xFF)
  }

  /// vraminfo: port 0x52 only sets the B/W background in digital mode; in
  /// analog mode it comes from the separate register behind port 0x54 bit 7,
  /// and can be any of the 512 colours.
  @Test("B/W graphics take the background from port 0x54 in analog mode")
  func effectiveRenderPaletteUsesAnalogBackgroundInAnalogMode() {
    let busPalette = [(b: UInt8, r: UInt8, g: UInt8)](
      repeating: (b: 0, r: 0, g: 0), count: 8)

    let palette = FrameCompositor.effectiveRenderPalette(
      busPalette: busPalette,
      graphicsColorMode: false,
      graphicsDisplayEnabled: true,
      analogPalette: true,
      borderColor: 0x50,  // ignored: analog mode
      analogBackground: (b: 2, r: 0, g: 4)
    )

    #expect(palette[0].r == 0)
    #expect(palette[0].g == UInt8(4 * 255 / 7))
    #expect(palette[0].b == UInt8(2 * 255 / 7))
  }

  @Test("text colour 0 follows the analog background too")
  func effectiveTextPaletteUsesAnalogBackgroundInAnalogMode() {
    let busPalette = [(b: UInt8, r: UInt8, g: UInt8)](
      repeating: (b: 0, r: 0, g: 0), count: 8)

    let palette = FrameCompositor.effectiveTextPalette(
      busPalette: busPalette,
      graphicsColorMode: false,
      analogPalette: true,
      borderColor: 0x50,
      analogBackground: (b: 7, r: 0, g: 0)
    )

    #expect(palette[0].r == 0)
    #expect(palette[0].g == 0)
    #expect(palette[0].b == 0xFF)
  }

  @Test("hi-color text keeps programmable background but fixed digital foreground colors")
  func effectiveTextPaletteUsesProgrammableBackgroundAndFixedDigitalForegroundInHiColor() {
    let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
      (b: 7, r: 7, g: 0), // programmable magenta
      (b: 0, r: 0, g: 0), // would be black if we incorrectly used programmable colors
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
    ]

    let palette = FrameCompositor.effectiveTextPalette(
      busPalette: busPalette,
      graphicsColorMode: true,
      analogPalette: false,
      borderColor: 0x00,
      analogBackground: (b: 0, r: 0, g: 0)
    )

    #expect(palette[0].r == 0xFF)
    #expect(palette[0].g == 0x00)
    #expect(palette[0].b == 0xFF)
    #expect(palette[1].r == 0x00)
    #expect(palette[1].g == 0x00)
    #expect(palette[1].b == 0xFF)
  }

  @Test("analog attribute text keeps programmable palette")
  func effectiveTextPaletteUsesProgrammablePaletteInAnalogAttributeMode() {
    let busPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
      (b: 7, r: 0, g: 7),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
      (b: 0, r: 0, g: 0),
    ]

    let palette = FrameCompositor.effectiveTextPalette(
      busPalette: busPalette,
      graphicsColorMode: false,
      analogPalette: true,
      borderColor: 0x00,
      analogBackground: (b: 0, r: 0, g: 0)
    )

    #expect(palette[0].r == 0x00)
    #expect(palette[0].g == 0x00)
    #expect(palette[0].b == 0x00)
    #expect(palette[1].r == 0x00)
    #expect(palette[1].g == 0x00)
    #expect(palette[1].b == 0x00)
  }

  // MARK: - port52BackgroundColor

  @Test("all bits off produces black")
  func port52AllOff() {
    let c = FrameCompositor.port52BackgroundColor(0x00)
    #expect(c.r == 0x00)
    #expect(c.g == 0x00)
    #expect(c.b == 0x00)
  }

  @Test("bit 0x20 enables red")
  func port52RedOnly() {
    let c = FrameCompositor.port52BackgroundColor(0x20)
    #expect(c.r == 0xFF)
    #expect(c.g == 0x00)
    #expect(c.b == 0x00)
  }

  @Test("bit 0x40 enables green")
  func port52GreenOnly() {
    let c = FrameCompositor.port52BackgroundColor(0x40)
    #expect(c.r == 0x00)
    #expect(c.g == 0xFF)
    #expect(c.b == 0x00)
  }

  @Test("bit 0x10 enables blue")
  func port52BlueOnly() {
    let c = FrameCompositor.port52BackgroundColor(0x10)
    #expect(c.r == 0x00)
    #expect(c.g == 0x00)
    #expect(c.b == 0xFF)
  }

  @Test("red + green = 0x60")
  func port52RedGreen() {
    let c = FrameCompositor.port52BackgroundColor(0x60)
    #expect(c.r == 0xFF)
    #expect(c.g == 0xFF)
    #expect(c.b == 0x00)
  }

  @Test("red + blue = 0x30")
  func port52RedBlue() {
    let c = FrameCompositor.port52BackgroundColor(0x30)
    #expect(c.r == 0xFF)
    #expect(c.g == 0x00)
    #expect(c.b == 0xFF)
  }

  @Test("green + blue = 0x50")
  func port52GreenBlue() {
    let c = FrameCompositor.port52BackgroundColor(0x50)
    #expect(c.r == 0x00)
    #expect(c.g == 0xFF)
    #expect(c.b == 0xFF)
  }

  @Test("all color bits = 0x70 produces white")
  func port52AllColors() {
    let c = FrameCompositor.port52BackgroundColor(0x70)
    #expect(c.r == 0xFF)
    #expect(c.g == 0xFF)
    #expect(c.b == 0xFF)
  }

  @Test("irrelevant bits (0x8F) are ignored, result is black")
  func port52IgnoresIrrelevantBits() {
    let c = FrameCompositor.port52BackgroundColor(0x8F)
    #expect(c.r == 0x00)
    #expect(c.g == 0x00)
    #expect(c.b == 0x00)
  }

  @Test("0xFF has all color bits set, produces white")
  func port52AllBitsSet() {
    let c = FrameCompositor.port52BackgroundColor(0xFF)
    #expect(c.r == 0xFF)
    #expect(c.g == 0xFF)
    #expect(c.b == 0xFF)
  }
}
