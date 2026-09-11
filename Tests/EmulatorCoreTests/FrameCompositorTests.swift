import Testing
@testable import EmulatorCore

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
      borderColor: 0x70
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
      borderColor: 0x00
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
      borderColor: 0x50
    )

    #expect(palette[0].r == 0x00)
    #expect(palette[0].g == 0xFF)
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
      borderColor: 0x00
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
      borderColor: 0x00
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
