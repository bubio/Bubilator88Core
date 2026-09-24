import Testing
@testable import Bubilator88Core

/// The pieces of `BootSnapshot` that decide when to stop. The capture itself
/// needs the BIOS ROMs, which tests do not have; `BootTester --snapshot`
/// covers it against real disks.
@Suite("BootSnapshot")
struct BootSnapshotTests {

  @Test("A black frame has no content")
  func blackFrame() {
    let pixels = [UInt8](repeating: 0, count: PC88.frameBufferSize)
    #expect(BootSnapshot.sample(pixels).content == 0)
  }

  /// Fill `rows` 16-pixel-high bands across the full width, lighting every
  /// third pixel: roughly what a line of text gives off.
  private func textRows(_ rows: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: PC88.frameBufferSize)
    for y in 0..<(rows * 16) {
      for x in 0..<PC88.frameWidth where x % 3 == 0 {
        let i = (y * PC88.frameWidth + x) * 4
        pixels[i] = 0xFF; pixels[i + 1] = 0xFF; pixels[i + 2] = 0xFF
      }
    }
    return pixels
  }

  @Test("A few lines of text on black do not count as content")
  func sparseTextIsNotContent() {
    // LION's text-only menu lights 0.65% of the screen.
    #expect(BootSnapshot.sample(textRows(1)).content < BootSnapshot.Parameters().minContent)
  }

  @Test("A screenful of text counts as content")
  func denseTextIsContent() {
    #expect(BootSnapshot.sample(textRows(6)).content >= BootSnapshot.Parameters().minContent)
  }

  @Test("The signature changes when a sampled pixel does")
  func signatureTracksChanges() {
    var pixels = [UInt8](repeating: 0, count: PC88.frameBufferSize)
    let before = BootSnapshot.sample(pixels).signature
    pixels[0] = 0x80
    #expect(BootSnapshot.sample(pixels).signature != before)
  }

  @Test("BASIC waiting for input is recognised", arguments: [
    "How many files(0-15)?",
    "NEC N-88 BASIC Version 2.3\n 45589 Bytes free\n",
    "\nOk\n",
  ])
  func basicPrompt(_ text: String) {
    #expect(BootSnapshot.isAtBASICPrompt(text))
  }

  @Test("Disk BASIC on its way to a game is not", arguments: [
    "How many files(0-15)? 0",
    "LION\n 1. ゲームを始める\n",
    "Hit Any Key",
  ])
  func notBasicPrompt(_ text: String) {
    #expect(!BootSnapshot.isAtBASICPrompt(text))
  }
}
