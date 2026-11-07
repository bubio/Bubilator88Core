import Foundation
@_spi(Debug) import Bubilator88Core

// Where the main CPU's time goes: T-states by instruction address, grouped
// by the labels of a symbol file when one is loaded, and timed regions.

/// Labels read from an assembler's symbol file.
struct SymbolTable {
  private(set) var addresses: [String: UInt16] = [:]
  /// One name per address, in address order.
  private(set) var labels: [(address: UInt16, name: String)] = []

  var isEmpty: Bool { labels.isEmpty }

  /// Read `NAME C000`, `NAME EQU $C000`, `NAME: EQU 0xC000`, `NAME = C000H`
  /// lines. A bare address is hex; `;` starts a comment. Returns the lines
  /// that were none of these.
  static func parse(_ text: String) -> (table: SymbolTable, skipped: [String]) {
    var table = SymbolTable()
    var skipped: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard !words.isEmpty else { continue }
      if words.count == 3, ["equ", "=", ".equ"].contains(words[1].lowercased()) { words.remove(at: 1) }
      var name = words[0]
      if name.hasSuffix(":") { name.removeLast() }
      guard words.count == 2, !name.isEmpty, let address = hexAddress(words[1]) else {
        skipped.append(String(raw))
        continue
      }
      if table.addresses[name] == nil { table.addresses[name] = address }
    }
    var first: [UInt16: String] = [:]
    for (name, address) in table.addresses.sorted(by: { $0.key < $1.key }) where first[address] == nil {
      first[address] = name
    }
    table.labels = first.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    return (table, skipped)
  }

  private static func hexAddress(_ word: String) -> UInt16? {
    var t = word.lowercased()
    if t.hasPrefix("0x") { t.removeFirst(2) } else if t.hasPrefix("$") || t.hasPrefix("#") { t.removeFirst() }
    if t.hasSuffix("h") { t.removeLast() }
    guard let value = Int(t, radix: 16), (0...0xFFFF).contains(value) else { return nil }
    return UInt16(value)
  }

  /// The nearest label at or below `address`.
  func label(containing address: UInt16) -> (address: UInt16, name: String)? {
    var low = 0, high = labels.count
    while low < high {
      let mid = (low + high) / 2
      if labels[mid].address <= address { low = mid + 1 } else { high = mid }
    }
    return low == 0 ? nil : labels[low - 1]
  }

  func name(at address: UInt16) -> String? {
    guard let label = label(containing: address), label.address == address else { return nil }
    return label.name
  }
}

extension AutomationTools {

  static let profileTools: [Tool] = [
    tool("load_symbols", """
    Load an assembler's symbol file, replacing any loaded before. Lines are NAME C000, \
    NAME EQU $C000, NAME: EQU 0xC000 or NAME = C000H; a bare address is hex and ; starts \
    a comment. Names are case-sensitive. Afterwards, address arguments accept the names, \
    disassemble shows the labels and profile groups by them.
    """, [
      "path": ["type": "string", "description": "Absolute path of the symbol file."],
    ], required: ["path"]) { tools, args in
      try tools.loadSymbols(args)
    },
    tool("profile", """
    Count the main CPU's T-states by instruction while frames run. start zeroes the \
    counts and starts counting; stop stops and reports; report shows the counts so far; \
    clear zeroes them. The report groups by label (the nearest symbol at or below each \
    instruction) when symbols are loaded, otherwise by instruction, and lists the \
    profile_region timings. T-states include memory and fetch waits; time halted and \
    interrupt acknowledges are counted apart. Counts are by CPU address, whatever bank \
    is mapped. It slows the machine down while counting. Only the main CPU.
    """, [
      "action": ["type": "string", "enum": ["start", "stop", "report", "clear"], "description": "Default report."],
      "top": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Rows to list. Default 20."],
    ]) { tools, args in
      try tools.profile(args)
    },
    tool("profile_region", """
    Time a stretch of code while profiling: from passing begin to next passing end, \
    each time; the report gives the count, total, longest and mean. With begin equal \
    to end it times one pass round a loop. Give only name to remove the region.
    """, [
      "name": ["type": "string"],
      "begin": addressProperty,
      "end": addressProperty,
    ], required: ["name"]) { tools, args in
      try tools.profileRegion(args)
    },
  ]

  // MARK: - Symbols

  private func loadSymbols(_ args: Arguments) throws -> ToolResult {
    let url = try args.path("path")
    let text: String
    do {
      let data = try Data(contentsOf: url)
      // Names and addresses are ASCII; Latin-1 keeps the lines of a file
      // whose comments are in Shift_JIS.
      text = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    let (table, skipped) = SymbolTable.parse(text)
    symbols = table
    var lines = ["Loaded \(table.addresses.count) symbol(s) from \(url.lastPathComponent)."]
    if !skipped.isEmpty {
      lines.append("\(skipped.count) line(s) not understood, such as:")
      lines += skipped.prefix(5).map { "  " + $0 }
    }
    return ToolResult([.text(lines.joined(separator: "\n"))])
  }

  // MARK: - Profiling

  private func profile(_ args: Arguments) throws -> ToolResult {
    let action = try args.string("action") ?? "report"
    let top = try args.int("top", in: 1...1000, default: 20)
    let profiler = self.profiler ?? Profiler()
    self.profiler = profiler
    switch action {
    case "start":
      try withMachine { pc88 in
        profiler.clear()
        pc88.profiler = profiler
      }
      profiling = true
      try updateDebuggerAttachment()
      return ToolResult([.text("Profiling. Run frames, then profile stop or report.")])
    case "stop":
      try withMachine { $0.profiler = nil }
      profiling = false
      try updateDebuggerAttachment()
      return ToolResult([.text("Stopped profiling.\n" + (try profileReport(profiler, top: top)))])
    case "clear":
      try withMachine { _ in profiler.clear() }
      return ToolResult([.text("Cleared the counts.")])
    case "report":
      return ToolResult([.text(try profileReport(profiler, top: top))])
    default:
      throw AutomationError("Unknown action \(action).")
    }
  }

  private func profileRegion(_ args: Arguments) throws -> ToolResult {
    guard let name = try args.string("name"), !name.isEmpty else { throw AutomationError("name is required.") }
    let profiler = self.profiler ?? Profiler()
    self.profiler = profiler
    switch (args.has("begin"), args.has("end")) {
    case (true, true):
      let region = Profiler.Region(name: name, begin: try args.address("begin"), end: try args.address("end"))
      try withMachine { _ in
        profiler.regions.removeAll { $0.name == name }
        profiler.regions.append(region)
      }
      return ToolResult([.text("Timing \(name) from " + String(format: "%04X to %04X.", region.begin, region.end))])
    case (false, false):
      let removed = try withMachine { _ -> Bool in
        let before = profiler.regions.count
        profiler.regions.removeAll { $0.name == name }
        return profiler.regions.count < before
      }
      guard removed else { throw AutomationError("No region \(name).") }
      return ToolResult([.text("Removed \(name).")])
    default:
      throw AutomationError("Give both begin and end, or neither to remove the region.")
    }
  }

  private func profileReport(_ profiler: Profiler, top: Int) throws -> String {
    try withMachine { pc88 -> String in
      let total = profiler.totalTStates
      guard total > 0 || !profiler.regions.isEmpty else {
        return profiling ? "Nothing counted yet; run some frames." : "Nothing counted; profile start first."
      }
      func percent(_ part: UInt64) -> String {
        total == 0 ? "0.0%" : String(format: "%.1f%%", Double(part) * 100 / Double(total))
      }
      var lines = ["Main CPU: \(total) T-states counted; halted \(percent(profiler.haltTStates)), "
        + "\(profiler.interrupts) interrupt acknowledge(s) \(percent(profiler.interruptTStates))."]

      struct Row { var key: String; var tStates: UInt64 = 0; var waits: UInt64 = 0; var instructions: UInt64 = 0; var entries: UInt32 = 0 }
      var rows: [Int: Row] = [:]
      for pc in 0..<0x10000 where profiler.instructions[pc] > 0 {
        let address = UInt16(pc)
        let key: Int
        let name: String
        if symbols.isEmpty {
          key = pc
          let instruction = Disassembler.decode(at: address) { pc88.peekMemory(.main, $0) }
          name = String(format: "%04X  ", pc) + instruction.mnemonic
        } else if let label = symbols.label(containing: address) {
          key = Int(label.address)
          name = label.name + String(format: " (%04X)", label.address)
        } else {
          key = -1
          name = "(before the first symbol)"
        }
        var row = rows[key] ?? Row(key: name)
        row.tStates += profiler.tStates[pc]
        row.waits += profiler.waitTStates[pc]
        row.instructions += UInt64(profiler.instructions[pc])
        if key == pc { row.entries = profiler.instructions[pc] }
        rows[key] = row
      }
      if !rows.isEmpty {
        let sorted = rows.values.sorted { $0.tStates > $1.tStates }
        let unit = symbols.isEmpty ? "instruction (load_symbols to group by label)" : "label"
        lines.append("By \(unit), top \(min(top, sorted.count)) of \(sorted.count):")
        lines.append(symbols.isEmpty
          ? "  T-states       %     waits  executed  instruction"
          : "  T-states       %     waits  instructions  entries  label")
        for row in sorted.prefix(top) {
          let share = percent(row.tStates)
          let head = String(format: "%10llu  ", row.tStates) + String(repeating: " ", count: max(0, 6 - share.count))
            + share + String(format: "  %8llu", row.waits)
          lines.append(symbols.isEmpty
            ? head + String(format: "  %8llu  ", row.instructions) + row.key
            : head + String(format: "  %12llu  %7u  ", row.instructions, row.entries) + row.key)
        }
      }
      if !profiler.regions.isEmpty {
        lines.append("Regions:")
        for region in profiler.regions {
          let span = String(format: "%04X-%04X", region.begin, region.end)
          guard region.hits > 0 else {
            lines.append("  \(region.name) \(span): not completed yet")
            continue
          }
          lines.append("  \(region.name) \(span): \(region.hits) time(s), \(region.totalTStates) T-states, "
            + "longest \(region.maxTStates), mean \(region.totalTStates / UInt64(region.hits))")
        }
      }
      return lines.joined(separator: "\n")
    }
  }
}
