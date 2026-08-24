/// Bus protocol — the only interface through which Z80 accesses memory and I/O.
///
/// I/O ports are 16-bit per Z80 specification.
/// PC-88 implementation may internally mask to 8-bit.
public protocol Bus: AnyObject {
  func memRead(_ addr: UInt16) -> UInt8
  func memWrite(_ addr: UInt16, value: UInt8)
  func ioRead(_ port: UInt16) -> UInt8
  func ioWrite(_ port: UInt16, value: UInt8)

  /// Opcode fetch (M1 cycle) read.
  ///
  /// The Z80 asserts `/M1` while fetching an opcode byte, and some machines —
  /// the PC-8801 among them — wire that pin into their wait generator so that
  /// opcode fetches cost more than ordinary data reads. Only the opcode byte
  /// itself and a prefix's follow-up byte are M1; immediate operands and
  /// displacement bytes are plain reads and stay on `memRead`.
  ///
  /// The default implementation forwards to `memRead`, so a bus with no M1
  /// wait of its own needs no code.
  func opcodeRead(_ addr: UInt16) -> UInt8
}

extension Bus {
  @inline(__always)
  public func opcodeRead(_ addr: UInt16) -> UInt8 { memRead(addr) }
}
