import Foundation

/// A byte of the main CPU's memory by where it physically lives.
@_spi(Debug) public struct MemoryLocation: Hashable, Sendable {
  public enum Space: Hashable, Sendable {
    case region(PC88.MemoryRegion)
    /// A bank of an extended RAM card.
    case extRAM(card: Int, bank: Int)
  }

  public var space: Space
  public var offset: Int

  public init(_ space: Space, _ offset: Int) {
    self.space = space
    self.offset = offset
  }
}

/// One store the main CPU made.
@_spi(Debug) public struct MemoryWrite: Equatable, Sendable {
  /// The address of the instruction that made it. During an interrupt
  /// acknowledge, the instruction the interrupt came after.
  public var pc: UInt16
  /// The address the CPU wrote to.
  public var address: UInt16
  /// The byte the CPU wrote. Through the GVRAM ALU this is the CPU's operand,
  /// not what the ALU then left in each plane.
  public var value: UInt8
  /// The ALU, not the CPU's byte, decided what each plane got.
  public var viaALU: Bool
  /// Made by the interrupt acknowledge pushing the return address.
  public var duringInterrupt: Bool
  /// The machine's T-state count when the instruction began.
  public var tState: UInt64

  public init(pc: UInt16, address: UInt16, value: UInt8, viaALU: Bool, duringInterrupt: Bool, tState: UInt64) {
    self.pc = pc
    self.address = address
    self.value = value
    self.viaALU = viaALU
    self.duringInterrupt = duringInterrupt
    self.tState = tState
  }
}

/// A range of memory the debugger stops on a write to.
@_spi(Debug) public struct MemoryWatch: Identifiable, Hashable, Sendable {
  public enum Space: Hashable, Sendable {
    /// CPU addresses, whatever is mapped there at the time of the write.
    case cpu
    case region(PC88.MemoryRegion)
  }

  public let id: UUID
  public var space: Space
  public var start: Int
  public var length: Int

  public init(id: UUID = UUID(), space: Space, start: Int, length: Int) {
    self.id = id
    self.space = space
    self.start = start
    self.length = length
  }

  /// Whether a write to CPU address `address`, landing at `locations`, falls
  /// in this range.
  func matches(address: UInt16, locations: [MemoryLocation]) -> Bool {
    let range = start..<start + length
    switch space {
    case .cpu:
      return range.contains(Int(address))
    case .region(let region):
      return locations.contains { $0.space == .region(region) && range.contains($0.offset) }
    }
  }
}

/// The write that stopped the debugger at a watch.
@_spi(Debug) public struct MemoryWatchHit: Equatable, Sendable {
  public var watch: MemoryWatch.ID
  public var write: MemoryWrite
  public var locations: [MemoryLocation]
}
