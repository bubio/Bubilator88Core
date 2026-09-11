/// PC-8801 Keyboard — 15-row scan matrix accessible via I/O ports 0x00-0x0E.
///
/// Each row returns 8 bits. A bit value of 0 means the key is pressed,
/// 1 means not pressed (active low).
///
/// Key names and the row layout: `PC88Key`.
package final class Keyboard {

  /// 15 rows of keyboard state. 0xFF = no keys pressed (active low).
  package var matrix: [UInt8] = Array(repeating: 0xFF, count: 15)

  package init() {}

  package func reset() {
    matrix = Array(repeating: 0xFF, count: 15)
  }

  /// Read a keyboard row (port 0x00-0x0E).
  package func readRow(_ row: UInt8) -> UInt8 {
    let index = Int(row & 0x0F)
    guard index < 15 else { return 0xFF }
    return matrix[index]
  }

  /// Press a key (set bit to 0 = pressed, active low).
  package func pressKey(row: Int, bit: Int) {
    guard row < 15, bit < 8 else { return }
    matrix[row] &= ~UInt8(1 << bit)
  }

  /// Release a key (set bit to 1 = released, active low).
  package func releaseKey(row: Int, bit: Int) {
    guard row < 15, bit < 8 else { return }
    matrix[row] |= UInt8(1 << bit)
  }

  /// Release all keys.
  package func releaseAll() {
    matrix = Array(repeating: 0xFF, count: 15)
  }
}
