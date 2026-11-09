import Foundation

/// T-states the main CPU spends, by the address of each instruction.
///
/// Attach one with ``PC88/profiler``. It records only while the machine
/// runs instruction by instruction (a debugger attached), so the plain
/// execution path never sees it. Use it on the machine's thread.
///
/// Counts are by CPU address, not by bank: code at the same address in ROM
/// and in the RAM under it adds up together.
@_spi(Debug) public final class Profiler {

  /// A stretch of code timed from passing `begin` to next passing `end`.
  public struct Region: Equatable, Sendable {
    public var name: String
    public var begin: UInt16
    public var end: UInt16
    /// Times `end` was reached after `begin`.
    public internal(set) var hits = 0
    public internal(set) var totalTStates: UInt64 = 0
    public internal(set) var maxTStates: UInt64 = 0
    /// T-state count when `begin` was last passed, while not yet at `end`.
    var startedAt: UInt64?

    public init(name: String, begin: UInt16, end: UInt16) {
      self.name = name
      self.begin = begin
      self.end = end
    }
  }

  /// T-states of the instructions at each address, their memory and fetch
  /// waits included. Indexed by address.
  public private(set) var tStates = [UInt64](repeating: 0, count: 0x10000)
  /// The wait states among `tStates`.
  public private(set) var waitTStates = [UInt64](repeating: 0, count: 0x10000)
  /// Instructions executed at each address.
  public private(set) var instructions = [UInt32](repeating: 0, count: 0x10000)
  /// T-states spent halted, waiting for an interrupt.
  public private(set) var haltTStates: UInt64 = 0
  /// T-states of interrupt acknowledges.
  public private(set) var interruptTStates: UInt64 = 0
  public private(set) var interrupts = 0
  public var regions: [Region] = []
  private var carriedWaits = 0

  public init() {}

  /// Every T-state counted, halts and interrupts included.
  public var totalTStates: UInt64 {
    tStates.reduce(0, &+) &+ haltTStates &+ interruptTStates
  }

  /// Zero the counts, keeping the regions.
  public func clear() {
    tStates = [UInt64](repeating: 0, count: 0x10000)
    waitTStates = [UInt64](repeating: 0, count: 0x10000)
    instructions = [UInt32](repeating: 0, count: 0x10000)
    haltTStates = 0
    interruptTStates = 0
    interrupts = 0
    carriedWaits = 0
    for i in regions.indices {
      regions[i].hits = 0
      regions[i].totalTStates = 0
      regions[i].maxTStates = 0
      regions[i].startedAt = nil
    }
  }

  // MARK: - Machine-facing

  /// Before the instruction at `pc` runs, at T-state count `now`.
  func willExecute(pc: UInt16, halted: Bool, now: UInt64) {
    // Halted, the CPU stays on the HALT for tick after tick; the
    // instruction ran once, when it was reached.
    guard !halted else { return }
    for i in regions.indices {
      if let start = regions[i].startedAt, pc == regions[i].end {
        let elapsed = now &- start
        regions[i].hits += 1
        regions[i].totalTStates &+= elapsed
        regions[i].maxTStates = max(regions[i].maxTStates, elapsed)
        regions[i].startedAt = nil
      }
      if regions[i].startedAt == nil, pc == regions[i].begin {
        regions[i].startedAt = now
      }
    }
  }

  /// The instruction at `pc` took `cycles` T-states, `waits` of them waits.
  func didExecute(pc: UInt16, halted: Bool, cycles: Int, waits: Int) {
    // The machine adds an acknowledge's waits to the next instruction;
    // they were counted with the acknowledge.
    let carried = min(carriedWaits, waits)
    carriedWaits = 0
    let cycles = UInt64(cycles - carried)
    if halted {
      haltTStates &+= cycles
      return
    }
    let i = Int(pc)
    tStates[i] &+= cycles
    waitTStates[i] &+= UInt64(waits - carried)
    instructions[i] &+= 1
  }

  /// An interrupt acknowledge took `cycles` T-states and left `waits`
  /// waits for the machine to add to the next instruction.
  func didAcknowledgeInterrupt(cycles: Int, waits: Int) {
    interruptTStates &+= UInt64(cycles + waits)
    interrupts += 1
    carriedWaits = waits
  }

  /// Drop the regions' open starts, as when the T-state count jumps.
  func abandonOpenRegions() {
    for i in regions.indices { regions[i].startedAt = nil }
  }
}
