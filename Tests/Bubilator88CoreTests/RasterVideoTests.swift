import Testing
@_spi(Debug) @testable import Bubilator88Core
import Peripherals

/// vraminfo: the palette takes effect per scan line, and 200/400 lines and
/// graphics on/off can be switched partway down the display.
@Suite("Mid-frame video registers")
struct RasterVideoTests {

  private static let base = RasterVideoState(
    palette: Pc88Bus.defaultPalette, borderColor: 0, analogBackground: (0, 0, 0),
    graphicsDisplayEnabled: true, graphicsColorMode: true, mode200Line: true)

  private func withPalette(_ state: RasterVideoState, _ index: Int,
                           _ color: (b: UInt8, r: UInt8, g: UInt8)) -> RasterVideoState {
    var s = state
    s.palette[index] = color
    return s
  }

  @Test("No changes, or changes only in the retrace, leave the frame whole")
  func noDisplayChangesNoBands() {
    var frame = RasterFrame(start: Self.base)
    frame.blankingStart = 400
    #expect(frame.bands() == nil)
    frame.changes = [(420, withPalette(Self.base, 0, (7, 0, 0)))]
    #expect(frame.bands() == nil)
  }

  /// VRAMTEST T: palette 0 back to black in the retrace, then a new color
  /// every so many lines.
  @Test("A change during the display starts a band on the next line")
  func displayChangesMakeBands() {
    let black = Self.base
    let blue = withPalette(black, 0, (7, 0, 0))
    let red = withPalette(black, 0, (0, 7, 0))
    var frame = RasterFrame(start: red)
    frame.blankingStart = 400
    frame.changes = [(49, blue), (99, red), (410, black)]

    let bands = frame.bands()
    #expect(bands?.map(\.rows) == [0..<50, 50..<100, 100..<400])
    #expect(bands?.map(\.state) == [black, blue, red])
  }

  @Test("What the retrace set carries into the lower bands")
  func retraceChangesComeFirst() {
    let green1 = withPalette(Self.base, 1, (0, 0, 7))
    let red0 = withPalette(Self.base, 0, (0, 7, 0))
    var frame = RasterFrame(start: Self.base)
    frame.blankingStart = 400
    // Display: palette 0 red at line 199. Retrace: palette 1 green.
    frame.changes = [(199, red0), (420, withPalette(red0, 1, (0, 0, 7)))]

    let bands = frame.bands()
    #expect(bands?.map(\.rows) == [0..<200, 200..<400])
    #expect(bands?[0].state == green1)
    #expect(bands?[1].state == withPalette(green1, 0, (0, 7, 0)))
  }

  @Test("CRTC lines are scaled to the 400-row picture (15kHz: 200 active)")
  func lineScaling() {
    var frame = RasterFrame(start: Self.base)
    frame.blankingStart = 200
    var off = Self.base
    off.graphicsDisplayEnabled = false
    frame.changes = [(99, off)]
    #expect(frame.bands()?.map(\.rows) == [0..<200, 200..<400])
  }

  @Test("A change undone on the same line leaves no band")
  func undoneChangeMerges() {
    var frame = RasterFrame(start: Self.base)
    frame.blankingStart = 400
    frame.changes = [(100, withPalette(Self.base, 2, (7, 7, 7))), (100, Self.base)]
    #expect(frame.bands() == nil)
  }

  @Test("renderDoubled writes only the rows it is given")
  func doubledRendererHonoursRows() {
    let renderer = ScreenRenderer()
    let plane = [UInt8](repeating: 0xFF, count: 0x4000)
    var buffer = [UInt8](repeating: 0x11, count: ScreenRenderer.bufferSize400)
    renderer.renderDoubled(blueVRAM: plane, redVRAM: plane, greenVRAM: plane,
                           palette: ScreenRenderer.defaultPalette, rows: 101..<200,
                           into: &buffer)
    func pixel(_ y: Int) -> UInt8 { buffer[y * 640 * 4] }
    #expect(pixel(100) == 0x11)
    #expect(pixel(101) == 0xFF)
    #expect(pixel(199) == 0xFF)
    #expect(pixel(200) == 0x11)
  }

  @Test("renderAttributeGraph400 writes only the rows it is given")
  func attributeGraph400HonoursRows() {
    let renderer = ScreenRenderer()
    let plane = [UInt8](repeating: 0xFF, count: 0x4000)
    var buffer = [UInt8](repeating: 0x11, count: ScreenRenderer.bufferSize400)
    renderer.renderAttributeGraph400(
      blueVRAM: plane, redVRAM: plane,
      attrData: [UInt8](repeating: 0xE0, count: 80 * 25),
      palette: ScreenRenderer.defaultPalette, rows: 300..<301, into: &buffer)
    #expect(buffer[299 * 640 * 4] == 0x11)
    #expect(buffer[300 * 640 * 4] == 0xFF)
    #expect(buffer[301 * 640 * 4] == 0x11)
  }

  /// End to end: a palette write on scan line 200 of a 24kHz frame colors
  /// the picture from row 201 down.
  @Test("A palette write mid-display splits the rendered frame")
  func machineRendersBands() {
    let machine = Machine()
    let crtc = machine.crtc
    let lines = crtc.dynamicTotalScanlines
    func step() { crtc.tick(tStates: 100, tStatesPerFrame: 100 * lines) }
    // Start from the top of a frame, then run to line 200.
    repeat { step() } while crtc.scanline != 0
    while crtc.scanline != 200 { step() }
    machine.bus.ioWrite(0x54, value: 0x02)  // digital: palette 0 red
    repeat { step() } while crtc.scanline != 0

    var buffer = [UInt8](repeating: 0, count: ScreenRenderer.bufferSize400)
    FrameCompositor().render(machine, into: &buffer, blinkCursor: false)
    func red(_ y: Int) -> UInt8 { buffer[y * 640 * 4] }
    #expect(red(200) == 0x00)
    #expect(red(201) == 0xFF)
    #expect(red(399) == 0xFF)
  }
}
