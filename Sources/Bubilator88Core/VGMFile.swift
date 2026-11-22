// VGMFile.swift — reads a YM2608 VGM stream for playback.

/// A VGM 1.51–1.71 file whose only sound chip is one YM2608, parsed into
/// register writes, waits and ADPCM uploads.
///
/// The input is the uncompressed file: `.vgz` is gzip, which the caller
/// expands first (the core builds on Windows too and carries no zlib).
/// `VGMLogger` writes files this type reads.
public struct VGMFile: Sendable {

  public enum Event: Sendable, Equatable {
    /// A register write. `secondary` is the second bank (FM ch4–6, ADPCM).
    case write(secondary: Bool, register: UInt8, value: UInt8)
    /// A wait in 44.1kHz samples.
    case wait(Int)
    /// DELTA-T ADPCM RAM contents starting at byte `offset`.
    case adpcm(offset: Int, bytes: [UInt8])
  }

  public enum ReadError: Error, Equatable, CustomStringConvertible {
    /// The file is damaged or not a VGM file.
    case invalid(String)
    /// The file is valid VGM but uses something this reader cannot play,
    /// such as another sound chip.
    case unsupported(String)

    public var description: String {
      switch self {
      case .invalid(let reason): "Invalid VGM: \(reason)"
      case .unsupported(let reason): "Unsupported VGM: \(reason)"
      }
    }
  }

  /// The GD3 tag's eleven fields: track, game, system and author (each in
  /// English, then Japanese), then release date, ripper and notes. Empty
  /// strings when the file has no tag.
  public struct Tags: Sendable, Equatable {
    public let fields: [String]

    init(fields: [String]) {
      self.fields = Array((fields + Array(repeating: "", count: 11)).prefix(11))
    }

    public var track: String { either(0) }
    public var game: String { either(2) }
    public var system: String { either(4) }
    public var author: String { either(6) }

    /// The English field at `index`, else the Japanese one after it.
    private func either(_ index: Int) -> String {
      fields[index].isEmpty ? fields[index + 1] : fields[index]
    }
  }

  /// The YM2608 input clock in Hz.
  public let clockHz: Int
  public let events: [Event]
  /// Index in `events` where playback continues after the end, or `nil`
  /// when the file does not loop.
  public let loopStart: Int?
  /// Length of one pass from the start to the end, in 44.1kHz samples.
  public let samples: Int
  /// Length of the looped part, in 44.1kHz samples; 0 without a loop.
  public let loopSamples: Int
  public let tags: Tags

  /// Playback length in 44.1kHz samples when the looped part repeats
  /// `loops` times after the first pass. Files without a loop play once.
  public func samples(loops: Int) -> Int {
    loopStart == nil ? samples : samples + max(0, loops) * loopSamples
  }

  /// Header fields of chips other than the YM2608. Any non-zero clock among
  /// them means the file needs a chip this reader cannot play.
  private static let otherChipClocks = [
    0x0C, 0x10, 0x2C, 0x30, 0x38, 0x40, 0x44, 0x4C, 0x50, 0x54, 0x58, 0x5C,
    0x60, 0x64, 0x68, 0x6C, 0x70, 0x74, 0x80, 0x84, 0x88, 0x8C, 0x90, 0x98,
    0x9C, 0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xC0, 0xC4, 0xC8, 0xCC,
    0xD0, 0xD8, 0xDC, 0xE0,
  ]

  public init(bytes: [UInt8]) throws(ReadError) {
    var reader = Reader(bytes: bytes, end: bytes.count)
    guard try reader.u32(at: 0) == 0x206D_6756 else { throw .invalid("missing header") }
    let version = try reader.u32(at: 0x08)
    guard (0x151...0x171).contains(version) else {
      throw .unsupported("version \(String(version, radix: 16))")
    }
    let end = try reader.offset(at: 0x04, defaultValue: bytes.count)
    let start = try reader.offset(at: 0x34, defaultValue: 0x40)
    let gd3 = try reader.offset(at: 0x14, defaultValue: 0)
    let loopOffset = try reader.offset(at: 0x1C, defaultValue: 0)
    guard end <= bytes.count, start >= 0x4C, start < end,
          gd3 == 0 || (gd3 >= start && gd3 < end) else {
      throw .invalid("header offsets")
    }

    // Bit 31 marks a second chip, which also puts the value out of range.
    let clock = try reader.u32(at: 0x48)
    guard (YM2608Renderer.sampleRate...16_000_000).contains(clock) else {
      throw .unsupported("requires one YM2608")
    }
    // 1.70 moved the end of the header to the extra-header offset.
    let headerEnd = version >= 0x170 && start >= 0xC0
      ? try reader.offset(at: 0xBC, defaultValue: start)
      : start
    guard headerEnd >= min(start, 0xC0), headerEnd <= start else {
      throw .invalid("extra header offset")
    }
    for field in Self.otherChipClocks where field + 4 <= headerEnd {
      guard try reader.u32(at: field) == 0 else { throw .unsupported("another sound chip") }
    }

    tags = Tags(fields: try Self.tagFields(reader: reader, start: gd3, end: end))
    clockHz = clock

    reader.position = start
    reader.end = gd3 == 0 ? end : gd3
    var parsed: [Event] = []
    var total = 0
    var loopIndex: Int?
    var loopSample = 0
    var ended = false
    while reader.position < reader.end {
      if reader.position == loopOffset {
        loopIndex = parsed.count
        loopSample = total
      }
      let command = try reader.byte()
      var wait = 0
      switch command {
      case 0x56, 0x57:
        parsed.append(.write(secondary: command == 0x57,
                             register: try reader.byte(), value: try reader.byte()))
      case 0x61:
        wait = Int(try reader.byte()) | Int(try reader.byte()) << 8
      case 0x62:
        wait = 735
      case 0x63:
        wait = 882
      case 0x70...0x7F:
        wait = Int(command & 0x0F) + 1
      case 0x66:
        ended = true
      case 0x67:
        parsed.append(try Self.dataBlock(&reader))
      default:
        throw .unsupported("command 0x\(String(command, radix: 16))")
      }
      if ended { break }
      if wait > 0 {
        total += wait
        parsed.append(.wait(wait))
      }
    }
    guard ended else { throw .invalid("missing end command") }
    if loopOffset != 0, loopIndex == nil || loopSample == total {
      throw .invalid("loop does not address a playable command")
    }
    events = parsed
    loopStart = loopIndex
    samples = total
    loopSamples = loopIndex == nil ? 0 : total - loopSample
  }

  /// A `0x67` data block. Only type 0x81, the YM2608 DELTA-T RAM, is
  /// accepted.
  private static func dataBlock(_ reader: inout Reader) throws(ReadError) -> Event {
    guard try reader.byte() == 0x66 else { throw .invalid("bad data block marker") }
    let kind = try reader.byte()
    guard kind == 0x81 else { throw .unsupported("data block type 0x\(String(kind, radix: 16))") }
    let size = try reader.word()
    guard size >= 8, size <= reader.end - reader.position else {
      throw .invalid("truncated data block")
    }
    let memorySize = try reader.word()
    let offset = try reader.word()
    let count = size - 8
    guard memorySize <= YM2608Renderer.adpcmCapacity, offset <= memorySize,
          count <= memorySize - offset else {
      throw .invalid("ADPCM range")
    }
    return .adpcm(offset: offset, bytes: try reader.take(count))
  }

  private static func tagFields(reader: Reader, start: Int, end: Int) throws(ReadError) -> [String] {
    guard start > 0 else { return [] }
    guard end - start >= 12, try reader.u32(at: start) == 0x2033_6447 else {
      throw .invalid("GD3 header")
    }
    let size = try reader.u32(at: start + 8)
    guard size <= end - start - 12, size.isMultiple(of: 2) else {
      throw .invalid("GD3 length")
    }
    let payload = reader.bytes[(start + 12)..<(start + 12 + size)]
    let units = stride(from: payload.startIndex, to: payload.endIndex, by: 2).map {
      UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8
    }
    return units.split(separator: 0, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF16.self)
    }
  }
}

private struct Reader {
  let bytes: [UInt8]
  var end: Int
  var position = 0

  func u32(at offset: Int) throws(VGMFile.ReadError) -> Int {
    guard offset >= 0, end - offset >= 4 else { throw .invalid("truncated integer") }
    return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
      | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
  }

  /// A header offset, which VGM stores relative to its own field; 0 means
  /// absent.
  func offset(at field: Int, defaultValue: Int) throws(VGMFile.ReadError) -> Int {
    let relative = try u32(at: field)
    return relative == 0 ? defaultValue : field + relative
  }

  mutating func byte() throws(VGMFile.ReadError) -> UInt8 {
    guard position < end else { throw .invalid("truncated command") }
    defer { position += 1 }
    return bytes[position]
  }

  mutating func word() throws(VGMFile.ReadError) -> Int {
    let value = try u32(at: position)
    position += 4
    return value
  }

  mutating func take(_ count: Int) throws(VGMFile.ReadError) -> [UInt8] {
    guard count <= end - position else { throw .invalid("truncated data block") }
    defer { position += count }
    return Array(bytes[position..<(position + count)])
  }
}
