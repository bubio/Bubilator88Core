import Foundation
@_spi(Debug) import Bubilator88Core

// The tools for developing software on the machine: patching memory and
// registers, loading a program straight into RAM, the memory map, the
// instruction trace, memory dumps and the cassette.

extension AutomationTools {

  static let spaceProperty: JSONValue = [
    "type": "string", "enum": .array((["cpu"] + PC88.MemoryRegion.allCases.map(\.rawValue)).map { .string($0) }),
    "description": "Default cpu.",
  ]

  static let developmentTools: [Tool] = [
    tool("write_memory", """
    Write bytes to memory. space cpu (default) stores them as the CPU would at the \
    address now, through the current bank mapping (stores to ROM land in the RAM under \
    it; in ALU mode they go through the ALU). The other spaces write the main CPU's \
    memory where it physically lives, by offset, as read_memory reads it. Wait states \
    and memory breakpoints are not triggered.
    """, [
      "address": addressProperty,
      "bytes": ["type": "string", "description": "Hex bytes, such as \"3E 42 C9\" or \"3e42c9\". Up to 4096."],
      "cpu": cpuProperty,
      "space": spaceProperty,
    ], required: ["address", "bytes"]) { tools, args in
      try tools.writeMemory(args)
    },
    tool("set_registers", """
    Change CPU registers; the ones not given keep their values. Setting pc also \
    takes the CPU out of HALT.
    """, [
      "cpu": cpuProperty,
      "pc": addressProperty, "sp": addressProperty,
      "af": addressProperty, "bc": addressProperty, "de": addressProperty, "hl": addressProperty,
      "ix": addressProperty, "iy": addressProperty,
    ]) { tools, args in
      try tools.setRegisters(args)
    },
    tool("load_bin", """
    Load a raw machine-code file into main RAM and point the main CPU at it. With the \
    launcher (the default), a small routine at EFF0H (or FFF0H when the program reaches \
    past it) does LD SP,F000H (FFFFH) / CALL address / JP 0000H, and the PC is set to \
    it; without, the PC is set to the address. The file goes into physical main RAM \
    (and text VRAM too above F000H), whatever the banks select: run it when the CPU \
    sees RAM there, as N88-BASIC does at C000H with no graphics plane selected.
    """, [
      "path": ["type": "string", "description": "Absolute path of the file."],
      "address": addressProperty,
      "launcher": ["type": "boolean", "description": "Default true."],
    ], required: ["path"]) { tools, args in
      try tools.loadBin(args)
    },
    tool("memory_map", """
    Where each part of the main CPU's address space reads from and writes to now, \
    as the bank registers set it: ROMs, RAM, the text window, text VRAM, GVRAM planes \
    or the ALU, extended RAM.
    """) { tools, _ in
      try tools.memoryMap()
    },
    tool("trace", """
    The last instructions a CPU executed, oldest first, with the registers before each. \
    Recording runs only while turned on with enable (or while breakpoints are set) and \
    keeps the last 1024 per CPU. The bytes shown are memory as it is now.
    """, [
      "enable": ["type": "boolean", "description": "true starts recording afresh; false stops it."],
      "cpu": cpuProperty,
      "last": ["type": "integer", "minimum": 0, "maximum": .number(Double(Debugger.traceCapacity)), "description": "Default 32."],
    ]) { tools, args in
      try tools.trace(args)
    },
    tool("dump_memory", """
    Write every memory region (main RAM, GVRAM planes, text VRAM, the disk unit's \
    memory, extended RAM) as raw .bin files plus info.txt into a directory.
    """, [
      "path": ["type": "string", "description": "Absolute path of the directory; created if needed."],
    ], required: ["path"]) { tools, args in
      let url = try args.path("path")
      let files = try tools.withMachine { try MemoryDump.write(pc88: $0, to: url) }
      return ToolResult([.text("Wrote \(files.count) file(s) to \(url.path): "
          + files.map(\.lastPathComponent).joined(separator: ", ") + ".")])
    },
    tool("tape", """
    The cassette: mount a T88 or CMT image, rewind it, or eject it. Loading from it is \
    up to the software, such as CLOAD or MON in BASIC.
    """, [
      "action": ["type": "string", "enum": ["mount", "rewind", "eject"]],
      "path": ["type": "string", "description": "mount: absolute path of the .t88 or .cmt file."],
    ], required: ["action"]) { tools, args in
      try tools.tape(args)
    },
  ]

  /// Attach the debugger while breakpoints or the trace need it.
  func updateDebuggerAttachment() throws {
    try host.setDebuggerAttached(tracing || !host.debugger.breakpoints.isEmpty)
  }

  /// The physical region a `space` argument names; nil for `cpu`.
  static func region(named space: String) throws -> PC88.MemoryRegion? {
    if space == "cpu" { return nil }
    guard let region = PC88.MemoryRegion(rawValue: space) else {
      throw AutomationError("Unknown space \(space).")
    }
    return region
  }

  // MARK: - Memory and registers

  private func writeMemory(_ args: Arguments) throws -> ToolResult {
    let address = try args.address("address")
    let bytes = try args.bytes("bytes")
    let space = try args.string("space") ?? "cpu"
    let region = try Self.region(named: space)
    let cpu = try args.cpu()
    try withMachine { pc88 in
      guard let region else {
        for (i, byte) in bytes.enumerated() {
          pc88.pokeMemory(cpu, address &+ UInt16(truncatingIfNeeded: i), byte)
        }
        return
      }
      guard pc88.writeMemory(region, at: Int(address), bytes) else {
        throw AutomationError("\(bytes.count) byte(s) at \(address) do not fit in \(space) "
          + "(\(pc88.memory(region).count) bytes).")
      }
    }
    return ToolResult([.text("Wrote \(bytes.count) byte(s) to \(space) at "
        + String(format: "%04X", address) + ".")])
  }

  private func setRegisters(_ args: Arguments) throws -> ToolResult {
    let cpu = try args.cpu()
    let fields: [(String, WritableKeyPath<PC88.CPURegisters, UInt16>)] = [
      ("pc", \.pc), ("sp", \.sp), ("af", \.af), ("bc", \.bc), ("de", \.de), ("hl", \.hl),
      ("ix", \.ix), ("iy", \.iy),
    ]
    var changes: [(WritableKeyPath<PC88.CPURegisters, UInt16>, UInt16)] = []
    for (name, path) in fields where args.has(name) {
      changes.append((path, try args.address(name)))
    }
    guard !changes.isEmpty else { throw AutomationError("Give at least one register.") }
    let setsPC = args.has("pc")
    let text = try withMachine { pc88 -> String in
      var registers = pc88.registers(of: cpu)
      for (path, value) in changes { registers[keyPath: path] = value }
      if setsPC { registers.halted = false }
      pc88.setRegisters(registers, of: cpu)
      return Self.formatRegisters(pc88.registers(of: cpu))
    }
    return ToolResult([.text(text)])
  }

  private func loadBin(_ args: Arguments) throws -> ToolResult {
    let url = try args.path("path")
    let address = Int(args.has("address") ? try args.address("address") : 0xC000)
    let useLauncher = try args.bool("launcher", default: true)
    let program: [UInt8]
    do {
      program = Array(try Data(contentsOf: url))
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    guard !program.isEmpty else { throw AutomationError("\(url.lastPathComponent) is empty.") }
    let end = address + program.count
    guard end <= 0x10000 else {
      throw AutomationError("\(program.count) bytes at \(String(format: "%04X", address)) run past FFFFH.")
    }
    var launcher: (address: Int, stack: Int)?
    if useLauncher {
      if end <= 0xEFF0 {
        launcher = (0xEFF0, 0xF000)
      } else if end <= 0xFFF0 {
        launcher = (0xFFF0, 0xFFFF)
      } else {
        throw AutomationError("The program reaches past FFF0H, where the launcher goes; pass launcher false.")
      }
    }
    var stores = [(address, program)]
    if let launcher {
      let lo = { (n: Int) in UInt8(n & 0xFF) }, hi = { (n: Int) in UInt8(n >> 8) }
      let code: [UInt8] = [0x31, lo(launcher.stack), hi(launcher.stack),
                           0xCD, lo(address), hi(address),
                           0xC3, 0x00, 0x00]
      stores.append((launcher.address, code))
    }
    let start = UInt16(launcher?.address ?? address)
    try withMachine { pc88 in
      for (at, bytes) in stores {
        pc88.writeMemory(.mainRAM, at: at, bytes)
        // The CPU reads F000H up from text VRAM in most modes.
        let textStart = max(at, 0xF000)
        if textStart < at + bytes.count {
          pc88.writeMemory(.textVRAM, at: textStart - 0xF000, Array(bytes[(textStart - at)...]))
        }
      }
      var registers = pc88.registers(of: .main)
      registers.pc = start
      registers.halted = false
      pc88.setRegisters(registers, of: .main)
    }
    let range = String(format: "%04X-%04X", address, end - 1)
    let how = launcher.map { String(format: "PC=%04X (launcher, SP=%04X).", $0.address, $0.stack) }
      ?? String(format: "PC=%04X.", address)
    return ToolResult([.text("Loaded \(program.count) byte(s) at \(range). \(how)")])
  }

  private func memoryMap() throws -> ToolResult {
    let text = try withMachine { pc88 -> String in
      pc88.memoryMap().map { entry in
        let range = String(format: "%04X-%04X", entry.start, entry.end)
        return entry.read == entry.write
          ? "\(range)  \(entry.read)"
          : "\(range)  read: \(entry.read)  write: \(entry.write)"
      }.joined(separator: "\n")
    }
    return ToolResult([.text(text)])
  }

  // MARK: - Trace

  private func trace(_ args: Arguments) throws -> ToolResult {
    let cpu = try args.cpu()
    let last = try args.int("last", in: 0...Debugger.traceCapacity, default: 32)
    let debugger = host.debugger
    var notes: [String] = []
    if args.has("enable") {
      tracing = try args.bool("enable", default: false)
      if tracing {
        debugger.clearTrace()
        debugger.clearSubTrace()
      }
      try updateDebuggerAttachment()
      notes.append(tracing ? "Tracing on." : "Tracing off.")
    }
    let entries = (cpu == .main ? debugger.traceSnapshot() : debugger.subTraceSnapshot()).suffix(last)
    let lines = try withMachine { pc88 in
      entries.map { e in
        let instruction = Disassembler.decode(at: e.pc) { pc88.peekMemory(cpu, $0) }
        return Self.formatInstruction(instruction).padding(toLength: 40, withPad: " ", startingAt: 0)
          + String(format: "AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X",
                   e.af, e.bc, e.de, e.hl, e.ix, e.iy, e.sp)
      }
    }
    if last > 0 {
      if lines.isEmpty {
        notes.append(tracing || !debugger.breakpoints.isEmpty
          ? "Nothing recorded yet; run some frames."
          : "Nothing recorded. Turn tracing on with enable true, then run.")
      } else {
        notes.append(lines.joined(separator: "\n"))
      }
    }
    return ToolResult([.text(notes.joined(separator: "\n"))])
  }

  // MARK: - Tape

  private func tape(_ args: Arguments) throws -> ToolResult {
    switch try args.string("action") ?? "" {
    case "mount":
      let url = try args.path("path")
      let format = try host.mountTape(url: url)
      return ToolResult([.text("Mounted \(url.lastPathComponent) (\(format == .t88 ? "T88" : "CMT")).")])
    case "rewind":
      try host.rewindTape()
      return ToolResult([.text("Rewound the tape.")])
    case "eject":
      try host.ejectTape()
      return ToolResult([.text("The cassette is empty.")])
    case let other:
      throw AutomationError("Unknown action \(other); use mount, rewind or eject.")
    }
  }
}

extension Arguments {
  /// Bytes given as hex text, with or without spaces.
  func bytes(_ name: String) throws -> [UInt8] {
    guard let text = try string(name) else { throw AutomationError("\(name) is required.") }
    let digits = text.filter { !$0.isWhitespace && $0 != "," }
    guard !digits.isEmpty, digits.count.isMultiple(of: 2), digits.count <= 8192 else {
      throw AutomationError("\(name) must be 1-4096 hex bytes, such as \"3E 42 C9\".")
    }
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
      let next = digits.index(index, offsetBy: 2)
      guard let byte = UInt8(digits[index..<next], radix: 16) else {
        throw AutomationError("\(name) has \"\(digits[index..<next])\", which is not a hex byte.")
      }
      bytes.append(byte)
      index = next
    }
    return bytes
  }
}
