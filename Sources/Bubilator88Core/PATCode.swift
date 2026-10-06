import Foundation

// 88PAR cheat codes, the `.pat` files of P88SR and of pat.dll (the PAT DLL for
// QUASI88). The behaviour follows pat.dll as read from its disassembly, not
// P88SR's PATCH.DOC where the two disagree; docs/develop/PAR_CHEAT_CODES.md
// records both and why.

/// One line of a `.pat` file: `TTaabbbb vvvv`.
public struct PATCode: Equatable, Hashable, Sendable {
  /// `TT`: what to do (write, add, compare, …).
  public var opcode: UInt8
  /// `aa`: which memory the address is in (main RAM, a ROM, sub-CPU RAM, …).
  public var area: UInt8
  /// `bbbb`: the address as that memory is mapped, not an offset into it.
  public var address: UInt16
  /// `vvvv`: the operand. 8-bit operations use only the low byte.
  public var value: UInt16

  public init(opcode: UInt8, area: UInt8, address: UInt16, value: UInt16) {
    self.opcode = opcode
    self.area = area
    self.address = address
    self.value = value
  }
}

/// A named group of codes, switched on and off as one.
public struct PATGroup: Equatable, Hashable, Sendable {
  public var name: String
  public var codes: [PATCode]

  public init(name: String, codes: [PATCode]) {
    self.name = name
    self.codes = codes
  }
}

/// Reading `.pat` files.
public enum PATFile {

  /// pat.dll keeps at most this many groups and drops everything after the
  /// group that would exceed it.
  public static let maxGroups = 15

  /// The name of the group that codes before the first `#` line fall into.
  public static let unnamedGroupName = "No Name"

  /// The file's text. `.pat` files are Shift_JIS, or UTF-16 with a BOM;
  /// UTF-8 is accepted as well. Bytes that fit none of these are read as
  /// Latin-1, which keeps the hex codes intact whatever happens to the names.
  public static func decodeText(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(3))
    if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
      if let text = String(data: data, encoding: .utf16) { return text }
    }
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]),
       let text = String(data: data.dropFirst(3), encoding: .utf8)
    {
      return text
    }
    for encoding in [String.Encoding.utf8, .shiftJIS] {
      if let text = String(data: data, encoding: encoding) { return text }
    }
    return String(data.map { Character(Unicode.Scalar($0)) })
  }

  /// The groups in a `.pat` file's text.
  ///
  /// Mirrors pat.dll's reader:
  /// - A line starting with `;` is a comment. A line starting with `#` begins
  ///   a group named by the rest of the line.
  /// - A line starting with a hex digit or one of `wW+-=!<>` is a code; any
  ///   other line is dropped silently, leading spaces included.
  /// - A code is read as eight characters then four, each after skipping
  ///   spaces, and each taken as hex up to its first non-hex character. A
  ///   malformed operand therefore reads as 0 rather than failing.
  public static func parse(_ text: String) -> [PATGroup] {
    var groups: [PATGroup] = []
    let lines = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
    for line in lines {
      guard let first = line.unicodeScalars.first else { continue }
      if first == ";" { continue }
      if first == "#" {
        guard groups.count < maxGroups else { break }
        let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        groups.append(PATGroup(name: name, codes: []))
        continue
      }
      guard codeLineStarts.contains(first) else { continue }
      if groups.isEmpty {
        groups.append(PATGroup(name: unnamedGroupName, codes: []))
      }
      groups[groups.count - 1].codes.append(parseCode(Substring(line)))
    }
    return groups
  }

  private static let codeLineStarts = Set("0123456789abcdefABCDEFwW+-=!<>".unicodeScalars)

  /// Mnemonic prefixes, which stand for the opcode byte. The second
  /// character gives the width: `w` for 16-bit, `b` for 8-bit.
  private static let mnemonics: [String: String] = [
    "ww": "80", "Ww": "81", "+w": "10", "-w": "11",
    "=w": "D0", "!w": "D1", "<w": "D2", ">w": "D3",
    "wb": "30", "Wb": "31", "+b": "20", "-b": "21",
    "=b": "E0", "!b": "E1", "<b": "E2", ">b": "E3",
    "cp": "C2",
  ]

  private static func parseCode(_ line: Substring) -> PATCode {
    var rest = line.unicodeScalars[...]
    var head = String(String.UnicodeScalarView(takeField(&rest, length: 8)))
    if let opcode = mnemonics[String(head.prefix(2))] {
      head = opcode + head.dropFirst(2)
    }
    let word = hexPrefix(head)
    let value = hexPrefix(String(String.UnicodeScalarView(takeField(&rest, length: 4))))
    return PATCode(opcode: UInt8(truncatingIfNeeded: word >> 24),
                   area: UInt8(truncatingIfNeeded: word >> 16),
                   address: UInt16(truncatingIfNeeded: word),
                   value: UInt16(truncatingIfNeeded: value))
  }

  /// Skip control characters and spaces, then take up to `length` scalars.
  private static func takeField(
    _ rest: inout String.UnicodeScalarView.SubSequence, length: Int
  ) -> String.UnicodeScalarView.SubSequence {
    rest = rest.drop { $0.value <= 0x20 }
    let field = rest.prefix(length)
    rest = rest.dropFirst(field.count)
    return field
  }

  /// The value of the hex digits at the start of `field`, 0 if there are none.
  private static func hexPrefix(_ field: String) -> UInt32 {
    let digits = field.prefix { $0.isHexDigit && $0.isASCII }
    return UInt32(digits, radix: 16) ?? 0
  }
}

// MARK: - Running codes

/// The memory a group of codes reads and writes, by area code and address.
package protocol PATMemory {
  /// The byte at `address` in `area`, or nil when the area is not installed
  /// or does not cover `address`.
  func patRead(area: UInt8, address: UInt16) -> UInt8?
  /// Store a byte where `patRead` would read it. Ignored where it reads nil.
  func patWrite(area: UInt8, address: UInt16, value: UInt8)
}

package enum PATRunner {

  /// Run one group once, as pat.dll's `pat_run` does for each enabled group
  /// every frame.
  ///
  /// The group carries a condition flag that starts set. A compare runs only
  /// while it is set and replaces it with its result, so consecutive compares
  /// AND together. A write, add or subtract runs only while it is set and
  /// sets it again afterwards, so a failed compare skips exactly one of them;
  /// the odd write opcodes 81 and 31 leave it as it is, so a condition can
  /// cover several writes. An address the area does not cover ends the
  /// group. Opcodes pat.dll does not implement (50, C0, C1, D4, …) do
  /// nothing.
  package static func run(_ codes: [PATCode], on memory: some PATMemory) {
    var condition = true
    var pendingCopy: (area: UInt8, address: UInt16, length: Int)?
    for code in codes {
      let area = code.area
      let address = code.address
      guard let current = memory.patRead(area: area, address: address) else { return }
      switch code.opcode {
      case 0x80, 0x81, 0x30, 0x31:
        let wide = code.opcode >= 0x80
        if condition {
          if let copy = pendingCopy {
            for i in 0..<copy.length {
              let (from, fromCarry) = copy.address.addingReportingOverflow(UInt16(truncatingIfNeeded: i))
              let (to, toCarry) = address.addingReportingOverflow(UInt16(truncatingIfNeeded: i))
              guard !fromCarry, !toCarry,
                    let byte = memory.patRead(area: copy.area, address: from),
                    memory.patRead(area: area, address: to) != nil
              else { break }
              memory.patWrite(area: area, address: to, value: byte)
            }
            pendingCopy = nil
          } else if wide {
            guard write16(code.value, area: area, address: address, on: memory) else { return }
          } else {
            memory.patWrite(area: area, address: address, value: UInt8(truncatingIfNeeded: code.value))
          }
        }
        if code.opcode & 1 == 0 { condition = true }
      case 0x10, 0x11:
        if condition {
          guard let old = read16(area: area, address: address, on: memory) else { return }
          let new = code.opcode == 0x10 ? old &+ code.value : old &- code.value
          guard write16(new, area: area, address: address, on: memory) else { return }
        }
        condition = true
      case 0x20, 0x21:
        if condition {
          let operand = UInt8(truncatingIfNeeded: code.value)
          let new = code.opcode == 0x20 ? current &+ operand : current &- operand
          memory.patWrite(area: area, address: address, value: new)
        }
        condition = true
      case 0xD0...0xD3:
        guard condition else { continue }
        guard let old = read16(area: area, address: address, on: memory) else { return }
        condition = compare(old, code.value, code.opcode & 0x0F)
      case 0xE0...0xE3:
        guard condition else { continue }
        condition = compare(current, UInt8(truncatingIfNeeded: code.value), code.opcode & 0x0F)
      case 0xC2:
        if condition {
          pendingCopy = (area, address, Int(code.value))
        }
      default:
        continue
      }
    }
  }

  private static func compare<T: FixedWidthInteger>(_ memory: T, _ operand: T, _ kind: UInt8) -> Bool {
    switch kind {
    case 0: memory == operand
    case 1: memory != operand
    case 2: memory < operand
    default: memory > operand
    }
  }

  /// Little-endian, both bytes inside the area, or nil.
  private static func read16(area: UInt8, address: UInt16, on memory: some PATMemory) -> UInt16? {
    guard address != 0xFFFF,
          let low = memory.patRead(area: area, address: address),
          let high = memory.patRead(area: area, address: address + 1)
    else { return nil }
    return UInt16(high) << 8 | UInt16(low)
  }

  /// Little-endian. False, writing nothing, if the high byte falls outside
  /// the area.
  private static func write16(_ value: UInt16, area: UInt8, address: UInt16, on memory: some PATMemory) -> Bool {
    guard address != 0xFFFF, memory.patRead(area: area, address: address + 1) != nil else { return false }
    memory.patWrite(area: area, address: address, value: UInt8(truncatingIfNeeded: value))
    memory.patWrite(area: area, address: address + 1, value: UInt8(truncatingIfNeeded: value >> 8))
    return true
  }
}

// MARK: - Areas

/// The area codes of PATCH.DOC, resolved the way QUASI88 registers them
/// with pat.dll. Each area is addressed as the CPU sees it, so the offset
/// into the backing array is the address minus where the area starts.
extension Machine: PATMemory {

  private enum PATLocation {
    case mainRAM(Int)
    case highSpeedRAM(Int)
    case n88BasicROM(Int)
    case nBasicROM(Int)
    case extROM(bank: Int, Int)
    case extRAM(bank: Int, Int)
    case sub(Int)
  }

  private func patLocate(area: UInt8, address: UInt16) -> PATLocation? {
    let a = Int(address)
    switch area {
    case 0x00: return .mainRAM(a)
    case 0x01: return a <= 0x5FFF ? .n88BasicROM(a) : nil
    case 0x02: return a >= 0xF000 ? .highSpeedRAM(a - 0xF000) : nil
    case 0x03: return (0x4000...0x7FFF).contains(a) ? .sub(a) : nil
    case 0x04: return a <= 0x1FFF ? .sub(a) : nil
    case 0x05: return (0x6000...0x7FFF).contains(a) ? .nBasicROM(a) : nil
    case 0x06: return a <= 0x5FFF ? .nBasicROM(a) : nil
    case 0x07: return (0x6000...0x7FFF).contains(a) ? .n88BasicROM(a) : nil
    case 0x08...0x0B:
      return (0x6000...0x7FFF).contains(a) ? .extROM(bank: Int(area - 0x08), a - 0x6000) : nil
    case 0x0C...0x0F:
      return a <= 0x7FFF ? .extRAM(bank: Int(area - 0x0C), a) : nil
    default: return nil
    }
  }

  package func patRead(area: UInt8, address: UInt16) -> UInt8? {
    guard let location = patLocate(area: area, address: address) else { return nil }
    switch location {
    case .mainRAM(let i): return bus.mainRAM[i]
    case .highSpeedRAM(let i): return bus.tvram[i]
    case .n88BasicROM(let i): return bus.n88BasicROM.flatMap { $0.indices.contains(i) ? $0[i] : nil }
    case .nBasicROM(let i): return bus.nBasicROM.flatMap { $0.indices.contains(i) ? $0[i] : nil }
    case .extROM(let bank, let i):
      guard let banks = bus.n88ExtROM, banks.indices.contains(bank), banks[bank].indices.contains(i) else { return nil }
      return banks[bank][i]
    case .extRAM(let bank, let i):
      guard let cards = bus.extRAM, let card = cards.first, card.indices.contains(bank),
            card[bank].indices.contains(i)
      else { return nil }
      return card[bank][i]
    case .sub(let i): return subSystem.subBus.romram[i]
    }
  }

  package func patWrite(area: UInt8, address: UInt16, value: UInt8) {
    guard patRead(area: area, address: address) != nil,
          let location = patLocate(area: area, address: address)
    else { return }
    switch location {
    case .mainRAM(let i): bus.mainRAM[i] = value
    case .highSpeedRAM(let i): bus.tvram[i] = value
    case .n88BasicROM(let i): bus.n88BasicROM?[i] = value
    case .nBasicROM(let i): bus.nBasicROM?[i] = value
    case .extROM(let bank, let i): bus.n88ExtROM?[bank][i] = value
    case .extRAM(let bank, let i): bus.extRAM?[0][bank][i] = value
    case .sub(let i): subSystem.subBus.romram[i] = value
    }
  }
}

extension PC88 {

  /// Apply one group of 88PAR codes to memory, once. Call it once per frame
  /// for each enabled group, between frames.
  ///
  /// The codes read and write memory directly, not through the bus: no wait
  /// states, no bank switching, and ROM can be patched.
  public func runPATCodes(_ codes: [PATCode]) {
    PATRunner.run(codes, on: machine)
  }
}
