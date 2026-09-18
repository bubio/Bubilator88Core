import Testing
@_spi(Debug) @testable import Bubilator88Core
import Peripherals

/// vraminfo (READ STATUS): a pair in the attribute area whose position byte is
/// `$E0`/`$60` is a special control character, and its value byte carries
/// I (interrupt), V (display stop) and D (DMA stop).
@Suite("Special control characters")
struct SpecialControlCharacterTests {

  private static let base = 0x8000
  private static let controlRow = 12

  /// The bus holds the CRTC and the DMAC weakly, so a test has to keep them.
  private struct Rig {
    let bus: Pc88Bus
    let crtc: CRTC
    let dma: DMAController

    func character(row: Int, col: Int = 0) -> UInt8 {
      bus.readTextVRAM()[row * Int(crtc.charsPerLine) + col]
    }
  }

  /// A CRTC in transparent B/W with special control characters enabled
  /// (AT1-AT0,SC = 00,0 — the reset state), 25 rows of 80 characters and 20
  /// attribute slots, reading from main RAM at `base`. Every row is filled
  /// with 'A' so a blanked row is easy to tell from a displayed one.
  private func makeRig(controlSlot: Int?, value: UInt8) -> Rig {
    let bus = Pc88Bus()
    let dma = DMAController()
    let crtc = CRTC()
    bus.dma = dma
    bus.crtc = crtc

    dma.ioWrite(0x64, value: UInt8(Self.base & 0xFF))
    dma.ioWrite(0x64, value: UInt8(Self.base >> 8))
    let rowBytes = crtc.bytesPerDMARow
    dma.channels[2].mode = 0b10
    dma.channels[2].count = UInt16(Int(crtc.linesPerScreen) * rowBytes - 1)
    dma.channels[2].enabled = true

    for row in 0..<Int(crtc.linesPerScreen) {
      for col in 0..<Int(crtc.charsPerLine) {
        bus.mainRAM[Self.base + row * rowBytes + col] = 0x41
      }
    }
    if let slot = controlSlot {
      let pair = Self.base + Self.controlRow * rowBytes + Int(crtc.charsPerLine) + slot * 2
      bus.mainRAM[pair] = 0xE0
      bus.mainRAM[pair + 1] = value
    }
    return Rig(bus: bus, crtc: crtc, dma: dma)
  }

  @Test("V stops the display below the row it sits in, the DMA runs on")
  func displayStop() {
    let rig = makeRig(controlSlot: 5, value: 0x02)
    rig.bus.performTextDMATransfer()

    #expect(rig.character(row: 11) == 0x41)
    #expect(rig.character(row: 12) == 0x41)
    #expect(rig.character(row: 13) == 0x00)
    #expect(rig.character(row: 24) == 0x00)
    // The fetch itself is untouched: the whole screen was transferred.
    #expect(rig.crtc.dmaBufferPtr == 25 * 120)
    #expect(rig.crtc.textDMAEndScanline != -1)
  }

  @Test("D stops the DMA there: no terminal count, and the CPU keeps the rest")
  func dmaStop() {
    let rig = makeRig(controlSlot: 5, value: 0x01)
    rig.bus.dipSw2 &= ~0x40  // V1S: the text DMA steals from the CPU there
    rig.bus.performTextDMATransfer()

    #expect(rig.character(row: 12) == 0x41)
    #expect(rig.character(row: 13) == 0x00)
    #expect(rig.crtc.dmaBufferPtr == 13 * 120)
    #expect(rig.crtc.textDMAEndScanline == -1)
    #expect(rig.crtc.textDMAStealRows == 13)
  }

  /// vraminfo tried I on hardware: 「I=1 にした場合は何もおきません」, and
  /// status N and E stay 0.
  @Test("I does nothing")
  func interruptBitDoesNothing() {
    let rig = makeRig(controlSlot: 5, value: 0x04)
    rig.bus.performTextDMATransfer()

    #expect(rig.character(row: 24) == 0x41)
    #expect(rig.crtc.dmaBufferPtr == 25 * 120)
    #expect(rig.crtc.readStatus() & 0x06 == 0)  // N and E stay 0
  }

  /// The page puts no limit on which slot holds it (「20 以上は指定禁止。
  /// 特殊制御文字も含む」 — it is one of the row's attribute slots), so the
  /// last slot is nothing special.
  @Test("Any attribute slot can hold it", arguments: [0, 5, 19])
  func anySlot(slot: Int) {
    let rig = makeRig(controlSlot: slot, value: 0x02)
    rig.bus.performTextDMATransfer()

    #expect(rig.character(row: 12) == 0x41)
    #expect(rig.character(row: 13) == 0x00)
  }

  @Test("The pair takes a slot but is not an attribute")
  func notAnAttribute() {
    let rig = makeRig(controlSlot: 0, value: 0x04)
    rig.crtc.displayMode = 0x02  // transparent color, special control still on
    let attrs = Self.base + Self.controlRow * rig.crtc.bytesPerDMARow
      + Int(rig.crtc.charsPerLine)
    rig.bus.mainRAM[attrs + 2] = 0     // slot 1: from column 0
    rig.bus.mainRAM[attrs + 3] = 0x48  // red
    rig.bus.performTextDMATransfer()

    // Without skipping the special control character, its $04 would be taken
    // as the value for column 0 and every attribute would shift by one slot.
    #expect(rig.bus.readTextAttributes()[Self.controlRow * 80] == 0x40)
  }

  @Test("A save state loaded mid-frame gets the display stop back")
  func recomputedOnLoad() {
    let rig = makeRig(controlSlot: 5, value: 0x02)
    rig.bus.performTextDMATransfer()
    rig.crtc.displayStopOffset = Int.max  // as a plain buffer restore leaves it

    rig.bus.recomputeTextDisplayStop()
    #expect(rig.character(row: 13) == 0x00)
  }
}
