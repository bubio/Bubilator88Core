/// RGBA pixels to a PNG file, in pure Swift so the same code runs on Windows.
///
/// The image data is compressed with fixed-Huffman deflate and a greedy LZ77
/// match search. PC-8801 screens are large flat areas and repeated rows, which
/// this alone shrinks to a few percent of their raw size; dynamic Huffman
/// tables would buy little more.
public enum PNGEncoder {

  /// Encode `rgba` (`width` × `height` × 4 bytes, row by row) as an 8-bit RGB
  /// PNG. Alpha is dropped: the core uses it to tag text pixels, not for
  /// transparency.
  public static func encodeRGB(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
    precondition(rgba.count >= width * height * 4, "pixel buffer too small")
    var raw = [UInt8]()
    raw.reserveCapacity((width * 3 + 1) * height)
    for y in 0..<height {
      raw.append(0)  // filter: none
      var p = y * width * 4
      for _ in 0..<width {
        raw.append(rgba[p]); raw.append(rgba[p + 1]); raw.append(rgba[p + 2])
        p += 4
      }
    }

    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    var header = [UInt8]()
    header.appendBigEndian(UInt32(width))
    header.appendBigEndian(UInt32(height))
    header += [8, 2, 0, 0, 0]  // 8-bit, truecolour, deflate, adaptive filter, no interlace
    appendChunk("IHDR", header, to: &png)
    appendChunk("IDAT", zlib(raw), to: &png)
    appendChunk("IEND", [], to: &png)
    return png
  }

  private static func appendChunk(_ type: String, _ data: [UInt8], to png: inout [UInt8]) {
    png.appendBigEndian(UInt32(data.count))
    let typeAndData = Array(type.utf8) + data
    png += typeAndData
    png.appendBigEndian(crc32(typeAndData))
  }

  // MARK: - zlib / deflate

  /// A zlib stream (RFC 1950) holding one fixed-Huffman deflate block.
  static func zlib(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    out += deflate(data)
    out.appendBigEndian(adler32(data))
    return out
  }

  private static let minMatch = 3
  private static let maxMatch = 258
  private static let window = 32768
  private static let hashBits = 15

  /// Raw deflate (RFC 1951): one final block with the fixed Huffman codes.
  static func deflate(_ data: [UInt8]) -> [UInt8] {
    var bits = BitWriter()
    bits.write(1, count: 1)  // BFINAL
    bits.write(1, count: 2)  // BTYPE = fixed Huffman

    // Most recent position of each 3-byte hash.
    var head = [Int](repeating: -1, count: 1 << hashBits)
    func hash(_ i: Int) -> Int {
      let v = Int(data[i]) << 16 | Int(data[i + 1]) << 8 | Int(data[i + 2])
      return ((v &* 2_654_435_761) >> 7) & ((1 << hashBits) - 1)
    }

    var i = 0
    let n = data.count
    while i < n {
      var length = 0
      var distance = 0
      if i + minMatch <= n {
        let h = hash(i)
        let candidate = head[h]
        head[h] = i
        if candidate >= 0, i - candidate <= window {
          let limit = min(maxMatch, n - i)
          var l = 0
          while l < limit, data[candidate + l] == data[i + l] { l += 1 }
          if l >= minMatch {
            length = l
            distance = i - candidate
          }
        }
      }
      if length > 0 {
        writeLength(length, to: &bits)
        writeDistance(distance, to: &bits)
        // Keep the hash table current inside the match so later matches can
        // reach back into it.
        let end = i + length
        i += 1
        while i < end {
          if i + minMatch <= n { head[hash(i)] = i }
          i += 1
        }
      } else {
        writeLiteral(Int(data[i]), to: &bits)
        i += 1
      }
    }
    writeLiteral(256, to: &bits)  // end of block
    return bits.finish()
  }

  /// Fixed literal/length code for `symbol` (RFC 1951 §3.2.6).
  private static func writeLiteral(_ symbol: Int, to bits: inout BitWriter) {
    switch symbol {
    case 0...143:   bits.writeHuffman(0x30 + symbol, count: 8)
    case 144...255: bits.writeHuffman(0x190 + symbol - 144, count: 9)
    case 256...279: bits.writeHuffman(symbol - 256, count: 7)
    default:        bits.writeHuffman(0xC0 + symbol - 280, count: 8)
    }
  }

  private static let lengthBase: [Int] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
  ]
  private static let lengthExtra: [Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
  ]
  private static let distanceBase: [Int] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra: [Int] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
  ]

  private static func writeLength(_ length: Int, to bits: inout BitWriter) {
    var code = lengthBase.count - 1
    while lengthBase[code] > length { code -= 1 }
    writeLiteral(257 + code, to: &bits)
    bits.write(UInt32(length - lengthBase[code]), count: lengthExtra[code])
  }

  private static func writeDistance(_ distance: Int, to bits: inout BitWriter) {
    var code = distanceBase.count - 1
    while distanceBase[code] > distance { code -= 1 }
    bits.writeHuffman(code, count: 5)
    bits.write(UInt32(distance - distanceBase[code]), count: distanceExtra[code])
  }

  // MARK: - Checksums

  private static let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 {
      c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
  }

  static func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data {
      c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
    }
    return c ^ 0xFFFF_FFFF
  }

  static func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    // 5552 is the most bytes that can be summed before b overflows 32 bits.
    var i = 0
    while i < data.count {
      let end = min(i + 5552, data.count)
      while i < end {
        a += UInt32(data[i])
        b += a
        i += 1
      }
      a %= 65521
      b %= 65521
    }
    return b << 16 | a
  }
}

/// Deflate's bit order: values fill each byte from the least significant bit.
private struct BitWriter {
  private(set) var bytes: [UInt8] = []
  private var buffer: UInt32 = 0
  private var filled = 0

  /// `count` low bits of `value`, least significant first (extra bits and
  /// header fields).
  mutating func write(_ value: UInt32, count: Int) {
    guard count > 0 else { return }
    buffer |= (value & ((1 << count) - 1)) << filled
    filled += count
    while filled >= 8 {
      bytes.append(UInt8(buffer & 0xFF))
      buffer >>= 8
      filled -= 8
    }
  }

  /// A Huffman code, which deflate stores most significant bit first.
  mutating func writeHuffman(_ code: Int, count: Int) {
    var reversed: UInt32 = 0
    for k in 0..<count where code & (1 << k) != 0 {
      reversed |= 1 << (count - 1 - k)
    }
    write(reversed, count: count)
  }

  mutating func finish() -> [UInt8] {
    if filled > 0 { bytes.append(UInt8(buffer & 0xFF)) }
    buffer = 0
    filled = 0
    return bytes
  }
}

extension Array where Element == UInt8 {
  mutating func appendBigEndian(_ v: UInt32) {
    append(UInt8(v >> 24)); append(UInt8(v >> 16 & 0xFF))
    append(UInt8(v >> 8 & 0xFF)); append(UInt8(v & 0xFF))
  }
}
