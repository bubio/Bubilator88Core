import Foundation
@_spi(Debug) import Bubilator88Core

// Who wrote memory: the last writer of each byte, and watches that stop the
// run on a write to a range. Both need the debugger attached, so they cost
// nothing while off.

extension AutomationTools {

  static let watchTools: [Tool] = [
    tool("write_tracking", """
    Keep, for every byte of the main CPU's memory, the instruction that last wrote it \
    (see last_writer). Turning it off forgets them. It slows the machine down while on. \
    Writes by DMA and by these tools are not tracked.
    """, [
      "enable": ["type": "boolean"],
    ], required: ["enable"]) { tools, args in
      try tools.setWriteTracking(args)
    },
    tool("last_writer", """
    For each byte, the instruction that last wrote it while write_tracking was on: \
    its PC, the byte written and the T-state. space cpu (default) looks up what the CPU \
    reaches at the address now (in ALU mode, each plane the ALU would change); the other \
    spaces name physical memory by offset, as read_memory does. Writes the GVRAM ALU \
    made say so, and the byte is the CPU's operand, not the plane's new value.
    """, [
      "address": addressProperty,
      "length": ["type": "integer", "minimum": 1, "maximum": 64, "description": "Bytes. Default 1."],
      "space": spaceProperty,
    ], required: ["address"]) { tools, args in
      try tools.lastWriter(args)
    },
    tool("watch_add", """
    Stop run_frames and step when the main CPU writes into a range, after the \
    instruction finishes. space cpu (default) watches CPU addresses whatever is mapped \
    there; the other spaces watch physical memory by offset, so a write to a GVRAM \
    plane is caught through the ALU too. Up to 64 watches.
    """, [
      "address": addressProperty,
      "length": ["type": "integer", "minimum": 1, "maximum": 65536, "description": "Bytes. Default 1."],
      "space": spaceProperty,
    ], required: ["address"]) { tools, args in
      try tools.addWatch(args)
    },
    tool("watch_list", "List the watches.") { tools, _ in
      let watches = tools.host.debugger.watches
      let text = watches.isEmpty ? "No watches." : watches.map(describe).joined(separator: "\n")
      return ToolResult([.text(text)])
    },
    tool("watch_remove", "Remove one watch by id, or all of them.", [
      "id": ["type": "string", "description": "As watch_list shows it."],
      "all": ["type": "boolean"],
    ]) { tools, args in
      try tools.removeWatch(args)
    },
  ]

  // MARK: - Tracking

  private func setWriteTracking(_ args: Arguments) throws -> ToolResult {
    let enable = try args.bool("enable", default: false)
    host.debugger.isTrackingWrites = enable
    try updateDebuggerAttachment()
    return ToolResult([.text(enable ? "Tracking writes." : "Stopped tracking writes.")])
  }

  private func lastWriter(_ args: Arguments) throws -> ToolResult {
    let address = try args.address("address")
    let length = try args.int("length", in: 1...64, default: 1)
    let space = try args.string("space") ?? "cpu"
    let region = try Self.region(named: space)
    let debugger = host.debugger
    guard debugger.isTrackingWrites else {
      throw AutomationError("Write tracking is off; turn it on with write_tracking, then run.")
    }
    let lines = try withMachine { pc88 -> [String] in
      if let region {
        let size = pc88.memory(region).count
        guard Int(address) + length <= size else {
          throw AutomationError("\(space) offsets run 0-\(size - 1).")
        }
      }
      return (0..<length).map { i in
        let at = address &+ UInt16(truncatingIfNeeded: i)
        let locations = region.map { [MemoryLocation(.region($0), Int(at))] } ?? pc88.writeLocations(of: at)
        let found = locations.map { location in
          let write = debugger.lastWrite(at: location).map(Self.describe) ?? "no write seen"
          return "\(Self.describe(location)): \(write)"
        }
        let head = region == nil ? String(format: "%04X ", at) : ""
        return head + found.joined(separator: "; ")
      }
    }
    return ToolResult([.text(lines.joined(separator: "\n"))])
  }

  // MARK: - Watches

  private func addWatch(_ args: Arguments) throws -> ToolResult {
    let address = Int(try args.address("address"))
    let length = try args.int("length", in: 1...65536, default: 1)
    let space = try args.string("space") ?? "cpu"
    let watchSpace: MemoryWatch.Space
    if let region = try Self.region(named: space) {
      let size = try withMachine { $0.memory(region).count }
      guard address + length <= size else {
        throw AutomationError("\(space) offsets run 0-\(size - 1).")
      }
      watchSpace = .region(region)
    } else {
      guard address + length <= 0x10000 else { throw AutomationError("The range runs past FFFF.") }
      watchSpace = .cpu
    }
    let watch = MemoryWatch(space: watchSpace, start: address, length: length)
    guard host.debugger.addWatch(watch) else {
      throw AutomationError("\(Debugger.watchCapacity) watches are set already; remove one first.")
    }
    try updateDebuggerAttachment()
    return ToolResult([.text("Added watch \(Self.describe(watch)).")])
  }

  private func removeWatch(_ args: Arguments) throws -> ToolResult {
    let debugger = host.debugger
    if try args.bool("all", default: false) {
      debugger.removeAllWatches()
    } else {
      guard let id = try args.string("id") else { throw AutomationError("Give id or all.") }
      guard let watch = debugger.watches.first(where: { Self.shortID($0.id) == id.lowercased() }) else {
        throw AutomationError("No watch \(id).")
      }
      debugger.removeWatch(id: watch.id)
    }
    try updateDebuggerAttachment()
    return ToolResult([.text("\(debugger.watches.count) watch(es) left.")])
  }

  /// The line `run` reports when a watch stopped it.
  func watchStopDescription(_ id: MemoryWatch.ID) -> String {
    let debugger = host.debugger
    let what = debugger.watches.first { $0.id == id }.map(Self.describe) ?? "a watch"
    guard let hit = debugger.lastWatchHit, hit.watch == id else { return "Stopped by watch \(what)." }
    let places = hit.locations.map(Self.describe).joined(separator: ", ")
    return "Stopped by watch \(what): " + String(format: "%04X", hit.write.address)
      + (places.isEmpty ? "" : " (\(places))") + ", \(Self.describe(hit.write))."
  }

  // MARK: - Formatting

  static func describe(_ watch: MemoryWatch) -> String {
    let space = switch watch.space {
    case .cpu: "cpu"
    case .region(let region): region.rawValue
    }
    let end = watch.start + watch.length - 1
    let range = watch.length == 1 ? String(format: "%04X", watch.start) : String(format: "%04X-%04X", watch.start, end)
    return "\(shortID(watch.id)) (\(space) \(range))"
  }

  static func describe(_ location: MemoryLocation) -> String {
    let offset = String(format: "%04X", location.offset)
    switch location.space {
    case .region(let region): return "\(region.rawValue) \(offset)"
    case .extRAM(let card, let bank): return "ext-ram card \(card) bank \(bank) \(offset)"
    }
  }

  static func describe(_ write: MemoryWrite) -> String {
    var text = String(format: "PC=%04X wrote %02X", write.pc, write.value)
    if write.viaALU { text += " through the ALU" }
    if write.duringInterrupt { text += " (interrupt acknowledge)" }
    return text + " at T=\(write.tState)"
  }
}
