import Foundation
@_spi(Debug) import Bubilator88Core

/// One block of a tool's result.
public enum ToolContent: Equatable, Sendable {
  case text(String)
  /// A PNG image.
  case png([UInt8])
}

/// What a tool call returns. `isError` marks a failure the AI should read
/// and act on, as opposed to a malformed request.
public struct ToolResult: Equatable, Sendable {
  public var content: [ToolContent]
  public var isError: Bool

  public init(_ content: [ToolContent], isError: Bool = false) {
    self.content = content
    self.isError = isError
  }
}

/// A tool as `tools/list` describes it.
public struct ToolDefinition: Sendable {
  public let name: String
  public let description: String
  /// JSON Schema for the arguments object.
  public let inputSchema: JSONValue
}

/// The tools an AI uses to drive the machine, written once against
/// `AutomationHost`.
///
/// Holds the little state the tools need between calls: the text still being
/// typed and the frames run so far. Call from one thread at a time.
public final class AutomationTools {
  public let host: AutomationHost
  private let pasteQueue = TextPasteQueue()
  private var framesRun = 0
  /// The instruction trace is on (`trace`); it needs the debugger attached.
  var tracing = false

  public init(host: AutomationHost) {
    self.host = host
  }

  /// Run the tool `name` with `arguments`. Returns nil for a tool that does
  /// not exist; failures inside a tool come back as an error result.
  public func call(_ name: String, arguments: [String: JSONValue]) -> ToolResult? {
    guard let tool = Self.tools.first(where: { $0.definition.name == name }) else { return nil }
    do {
      return try tool.run(self, Arguments(arguments))
    } catch let error as AutomationError {
      return ToolResult([.text(error.description)], isError: true)
    } catch {
      return ToolResult([.text(String(describing: error))], isError: true)
    }
  }

  public static var definitions: [ToolDefinition] { tools.map(\.definition) }

  // MARK: - Catalogue

  struct Tool: Sendable {
    let definition: ToolDefinition
    let run: @Sendable (AutomationTools, Arguments) throws -> ToolResult
  }

  static func tool(_ name: String, _ description: String,
                   _ properties: [String: JSONValue] = [:], required: [String] = [],
                   _ run: @escaping @Sendable (AutomationTools, Arguments) throws -> ToolResult) -> Tool {
    let schema: JSONValue = [
      "type": "object",
      "properties": .object(properties),
      "required": .array(required.map { .string($0) }),
      "additionalProperties": false,
    ]
    return Tool(definition: ToolDefinition(name: name, description: description, inputSchema: schema), run: run)
  }

  static let cpuProperty: JSONValue = [
    "type": "string", "enum": ["main", "sub"],
    "description": "main: the main Z80. sub: the disk unit's Z80. Default main.",
  ]
  static let addressProperty: JSONValue = [
    "type": ["integer", "string"],
    "description": "0-65535, or hex as \"0xC000\", \"C000H\" or \"$C000\".",
  ]

  private static let tools = basicTools + developmentTools

  private static let basicTools: [Tool] = [
    tool("status", """
    The machine's state: BASIC mode, clock, whether time runs in real time, \
    the debugger's run state, frames run, the main CPU's PC and the mounted disks.
    """) { tools, _ in
      try tools.status()
    },
    tool("reset", """
    Reset the machine. A cold reset (the default) is a power cycle and may change \
    the BASIC mode and clock first; a warm reset is the RESET button and keeps memory. \
    With a disk in drive 1 a cold reset boots it. The app has one reset, its Reset \
    command, for both.
    """, [
      "warm": ["type": "boolean", "description": "Warm reset. Default false."],
      "mode": ["type": "string", "enum": .array(BootMode.allCases.map { .string($0.rawValue) }),
               "description": "BASIC mode for a cold reset."],
      "clock": ["type": "string", "enum": ["4mhz", "8mhz"], "description": "CPU clock for a cold reset."],
    ]) { tools, args in
      try tools.reset(args)
    },
    tool("run_frames", """
    Run the machine for a number of frames (about 1/60 s each) as fast as possible, \
    then stop. Stops early at a breakpoint. If the machine runs in real time, it is \
    paused first and stays paused; use resume to let it run again.
    """, [
      "frames": ["type": "integer", "minimum": 1, "maximum": 36000, "description": "Default 60."],
      "screenshot": ["type": "boolean", "description": "Also return the screen afterwards. Default false."],
    ]) { tools, args in
      try tools.runFrames(args)
    },
    tool("pause", "Stop real-time running (the app only; a headless machine never runs on its own).") { tools, _ in
      try tools.host.setRunningInRealTime(false)
      return ToolResult([.text("Paused.")])
    },
    tool("resume", "Let the machine run in real time again (the app only).") { tools, _ in
      try tools.withMachine { tools.leaveBreakpoint($0) }
      try tools.host.setRunningInRealTime(true)
      return ToolResult([.text("Running in real time.")])
    },
    tool("step", """
    Execute instructions one at a time and show the registers and next instruction. \
    Pauses real-time running. Stops at a PC breakpoint or when a memory or I/O breakpoint fires.
    """, [
      "cpu": cpuProperty,
      "count": ["type": "integer", "minimum": 1, "maximum": 100000, "description": "Default 1."],
    ]) { tools, args in
      try tools.step(args)
    },
    tool("key", """
    Press or release one PC-8801 key. tap presses it, runs some frames, releases it \
    and runs as many again. Names: a-z, 0-9, return, space, esc, stop, tab, help, copy, \
    shift, ctrl, grph, kana, capslock, up, down, left, right, f1-f10, bs, del, ins, clr, \
    rollup, rolldown, at, leftbracket, rightbracket, yen, caret, minus, colon, semicolon, \
    comma, period, slash, underscore, kp0-kp9, kpreturn, kpplus, kpminus, kpmultiply, \
    kpdivide, kpequal, kpcomma, kpperiod, henkan, kettei, pc, zenkaku; or row-bit as "9-6". \
    For a combination, send down for the modifier, tap the key, then up.
    """, [
      "key": ["type": "string", "description": "Key name. Not needed for release_all."],
      "action": ["type": "string", "enum": ["tap", "down", "up", "release_all"], "description": "Default tap."],
      "frames": ["type": "integer", "minimum": 1, "maximum": 600,
                 "description": "tap: frames to hold the key, and to wait after. Default 3."],
    ]) { tools, args in
      try tools.key(args)
    },
    tool("type_text", """
    Type text on the keyboard, running frames until it has all been typed. ASCII and \
    half-width katakana; "\\n" presses RETURN. Kanji cannot be typed.
    """, [
      "text": ["type": "string"],
      "max_frames": ["type": "integer", "minimum": 1, "maximum": 36000,
                     "description": "Give up after this many frames. Default 6000."],
    ], required: ["text"]) { tools, args in
      try tools.typeText(args)
    },
    tool("screenshot", "The screen as a 640x400 PNG image, without display filters.", [
      "path": ["type": "string", "description": "Absolute path to also save the PNG to."],
    ]) { tools, args in
      try tools.screenshot(args)
    },
    tool("read_text", """
    The text screen as Unicode text, one line per row. Graphics are not included; \
    use screenshot to see them.
    """) { tools, _ in
      ToolResult([.text(try tools.withMachine { $0.copyTextAsUnicode() })])
    },
    tool("mount_disk", """
    Insert a D88 disk image into drive 1 or 2. The app writes changes back to the file, \
    as for any disk it opens; a headless machine keeps them in memory.
    """, [
      "drive": ["type": "integer", "enum": [1, 2]],
      "path": ["type": "string", "description": "Absolute path of the .d88 file."],
      "image": ["type": "integer", "minimum": 0,
                "description": "Image number in a file that holds several, from 0. Default 0."],
      "write_protected": ["type": "boolean", "description": "Default false."],
    ], required: ["drive", "path"]) { tools, args in
      try tools.mountDisk(args)
    },
    tool("eject_disk", "Remove the disk from drive 1 or 2.", [
      "drive": ["type": "integer", "enum": [1, 2]],
    ], required: ["drive"]) { tools, args in
      let drive = try args.int("drive", in: 1...2)
      try tools.host.ejectDisk(drive: drive - 1)
      return ToolResult([.text("Drive \(drive) is empty.")])
    },
    tool("save_state", "Save the whole machine, disks included, to a .b88s file.", [
      "path": ["type": "string", "description": "Absolute path of the .b88s file."],
    ], required: ["path"]) { tools, args in
      let url = try args.path("path")
      try tools.host.saveState(to: url)
      return ToolResult([.text("Saved \(url.path).")])
    },
    tool("load_state", "Restore the machine from a .b88s file.", [
      "path": ["type": "string", "description": "Absolute path of the .b88s file."],
    ], required: ["path"]) { tools, args in
      let url = try args.path("path")
      try tools.host.loadState(from: url)
      return ToolResult([.text("Loaded \(url.path).")])
    },
    tool("registers", "A CPU's registers and flags.", ["cpu": cpuProperty]) { tools, args in
      let cpu = try args.cpu()
      let text = try tools.withMachine { AutomationTools.formatRegisters($0.registers(of: cpu)) }
      return ToolResult([.text(text)])
    },
    tool("read_memory", """
    Hex dump of memory. space cpu (default) reads what the CPU sees at the address now, \
    through the current bank mapping (see memory_map). The other spaces read the main \
    CPU's memory where it physically lives, by offset: ram (64KB main RAM, including \
    the RAM under the ROMs and GVRAM), tvram (4KB) and gvram-blue/red/green (16KB each). \
    Reading changes nothing.
    """, [
      "address": addressProperty,
      "length": ["type": "integer", "minimum": 1, "maximum": 4096, "description": "Bytes. Default 256."],
      "cpu": cpuProperty,
      "space": spaceProperty,
    ], required: ["address"]) { tools, args in
      try tools.readMemory(args)
    },
    tool("disassemble", "Disassemble Z80 instructions, starting at the PC by default.", [
      "address": addressProperty,
      "count": ["type": "integer", "minimum": 1, "maximum": 256, "description": "Instructions. Default 16."],
      "cpu": cpuProperty,
    ]) { tools, args in
      try tools.disassemble(args)
    },
    tool("breakpoint_add", """
    Stop run_frames and step when a condition is met. pc / sub-pc: before the \
    instruction at the address runs. mem-read / mem-write: when the main CPU accesses \
    the address. io-read / io-write: when the main CPU accesses the port (low 8 bits). \
    value limits write breakpoints to that byte.
    """, [
      "kind": ["type": "string", "enum": ["pc", "sub-pc", "mem-read", "mem-write", "io-read", "io-write"]],
      "address": addressProperty,
      "value": ["type": "integer", "minimum": 0, "maximum": 255],
    ], required: ["kind", "address"]) { tools, args in
      try tools.addBreakpoint(args)
    },
    tool("breakpoint_list", "List the breakpoints, including any set in the app's debugger window.") { tools, _ in
      tools.listBreakpoints()
    },
    tool("breakpoint_remove", "Remove one breakpoint by id, or all of them.", [
      "id": ["type": "string", "description": "As breakpoint_list shows it."],
      "all": ["type": "boolean"],
    ]) { tools, args in
      try tools.removeBreakpoint(args)
    },
  ]

  // MARK: - Running

  func withMachine<T>(_ body: (PC88) throws -> T) throws -> T {
    try host.withMachine(body)
  }

  /// Leave a breakpoint stop so the machine can run on.
  ///
  /// A PC breakpoint stops before its instruction and would stop the run
  /// again at once, so that instruction is executed here first.
  func leaveBreakpoint(_ pc88: PC88) {
    let debugger = host.debugger
    guard case .paused(let reason) = debugger.runState else { return }
    debugger.resume()
    guard case .breakpoint(let id) = reason,
          let bp = debugger.breakpoints.first(where: { $0.id == id }) else { return }
    switch bp.kind {
    case .mainPC(let address) where pc88.registers(of: .main).pc == address:
      pc88.stepInstruction(.main)
    case .subPC(let address) where pc88.registers(of: .sub).pc == address:
      // The sub CPU checks its breakpoints on every step, stepping included.
      debugger.setEnabled(false, id: id)
      pc88.stepInstruction(.sub)
      debugger.setEnabled(bp.isEnabled, id: id)
    default:
      break
    }
  }

  /// Run up to `count` frames, leaving any breakpoint stop first. Returns
  /// the frames run and, when a breakpoint ended the run, a line saying so.
  private func run(_ count: Int, beforeEach: (PC88) -> Bool = { _ in true }) throws -> (frames: Int, stop: String?) {
    try withMachine { leaveBreakpoint($0) }
    let frames = try host.runFrames(count, beforeEach: beforeEach)
    framesRun += frames
    return (frames, try withMachine { stopDescription($0) })
  }

  private func stopDescription(_ pc88: PC88) -> String? {
    guard case .paused(let reason) = host.debugger.runState else { return nil }
    let pc = String(format: "%04X", pc88.registers(of: .main).pc)
    switch reason {
    case .breakpoint(let id):
      let bp = host.debugger.breakpoints.first { $0.id == id }
      let what = bp.map { "\(Self.shortID($0.id)) (\(Self.describe($0)))" } ?? "a breakpoint"
      return "Stopped at breakpoint \(what). Main PC=\(pc)."
    case .userRequest, .initialLaunch:
      return "Paused by the debugger. Main PC=\(pc)."
    }
  }

  private func runFrames(_ args: Arguments) throws -> ToolResult {
    let count = try args.int("frames", in: 1...36000, default: 60)
    let (frames, stop) = try run(count)
    var content: [ToolContent] = [.text(stop.map { "Ran \(frames) frame(s). \($0)" } ?? "Ran \(frames) frame(s).")]
    if try args.bool("screenshot", default: false) {
      content.append(.png(try renderPNG()))
    }
    return ToolResult(content)
  }

  private func step(_ args: Arguments) throws -> ToolResult {
    let cpu = try args.cpu()
    let count = try args.int("count", in: 1...100_000, default: 1)
    if host.isRunningInRealTime {
      try host.setRunningInRealTime(false)
    }
    let debugger = host.debugger
    let text = try withMachine { pc88 -> String in
      leaveBreakpoint(pc88)
      var executed = 0
      var stop: String?
      while executed < count {
        if executed > 0, let hit = pcBreakpoint(pc88, cpu) {
          stop = "Stopped at breakpoint \(Self.shortID(hit.id)) (\(Self.describe(hit)))."
          break
        }
        pc88.stepInstruction(cpu)
        executed += 1
        if debugger.isPaused {
          stop = stopDescription(pc88)
          break
        }
      }
      let regs = pc88.registers(of: cpu)
      let next = Disassembler.decode(at: regs.pc) { pc88.peekMemory(cpu, $0) }
      var lines = ["Executed \(executed) instruction(s)." + (stop.map { " \($0)" } ?? "")]
      lines.append(Self.formatRegisters(regs))
      lines.append("Next: " + Self.formatInstruction(next))
      return lines.joined(separator: "\n")
    }
    return ToolResult([.text(text)])
  }

  private func pcBreakpoint(_ pc88: PC88, _ cpu: PC88.CPU) -> Breakpoint? {
    let pc = pc88.registers(of: cpu).pc
    return host.debugger.breakpoints.first { bp in
      guard bp.isEnabled else { return false }
      switch (bp.kind, cpu) {
      case (.mainPC(let a), .main), (.subPC(let a), .sub): return a == pc
      default: return false
      }
    }
  }

  // MARK: - Machine

  private func status() throws -> ToolResult {
    let debugger = host.debugger
    let realTime = host.isRunningInRealTime
    let frames = framesRun
    let value = try withMachine { pc88 -> JSONValue in
      var disks: [JSONValue] = []
      for drive in 0..<2 {
        if let disk = pc88.mountedDisk(drive: drive) {
          disks.append(["drive": .number(Double(drive + 1)), "name": .string(disk.name),
                        "write_protected": .bool(pc88.isWriteProtected(drive: drive))])
        } else {
          disks.append(["drive": .number(Double(drive + 1)), "name": .null])
        }
      }
      let runState: String
      switch debugger.runState {
      case .running: runState = "running"
      case .paused: runState = stopDescription(pc88) ?? "paused"
      }
      return [
        "mode": pc88.bootMode.map { .string($0.rawValue) } ?? .null,
        "clock": pc88.clock8MHz ? "8mhz" : "4mhz",
        "frame_rate": .number((pc88.frameRate * 100).rounded() / 100),
        "real_time": .bool(realTime),
        "debugger": .string(runState),
        "frames_run": .number(Double(frames)),
        "t_states": .number(Double(pc88.totalTStates)),
        "pc": .string(String(format: "%04X", pc88.registers(of: .main).pc)),
        "disks": .array(disks),
      ]
    }
    return ToolResult([.text(value.encodedString())])
  }

  private func reset(_ args: Arguments) throws -> ToolResult {
    let warm = try args.bool("warm", default: false)
    let mode = try args.string("mode").map { name -> BootMode in
      guard let mode = BootMode(rawValue: name) else {
        throw AutomationError("Unknown mode \(name).")
      }
      return mode
    }
    let clock = try args.string("clock").map { name -> Bool in
      switch name.lowercased() {
      case "4mhz": return false
      case "8mhz": return true
      default: throw AutomationError("Unknown clock \(name); use 4mhz or 8mhz.")
      }
    }
    if warm, mode != nil || clock != nil {
      throw AutomationError("mode and clock apply to a cold reset only.")
    }
    pasteQueue.cancel { _ in }
    try host.reset(cold: !warm, mode: mode, clock8MHz: clock)
    try withMachine { $0.releaseAllKeys() }
    return ToolResult([.text(warm ? "Warm reset." : "Cold reset.")])
  }

  private func mountDisk(_ args: Arguments) throws -> ToolResult {
    let drive = try args.int("drive", in: 1...2)
    let url = try args.path("path")
    let image = try args.int("image", in: 0...255, default: 0)
    let protected = try args.bool("write_protected", default: false)
    let name = try host.mountDisk(drive: drive - 1, url: url, imageIndex: image, writeProtected: protected)
    return ToolResult([.text("Drive \(drive): \(name.isEmpty ? url.lastPathComponent : name).")])
  }

  // MARK: - Input

  private func key(_ args: Arguments) throws -> ToolResult {
    let action = try args.string("action") ?? "tap"
    if action == "release_all" {
      try withMachine { $0.releaseAllKeys() }
      return ToolResult([.text("Released every key.")])
    }
    guard let name = try args.string("key") else {
      throw AutomationError("key is required.")
    }
    guard let key = ScriptParser.key(named: name) else {
      throw AutomationError("Unknown key \(name).")
    }
    switch action {
    case "down":
      try withMachine { $0.pressKey(key) }
      return ToolResult([.text("\(name) is down.")])
    case "up":
      try withMachine { $0.releaseKey(key) }
      return ToolResult([.text("\(name) is up.")])
    case "tap":
      let hold = try args.int("frames", in: 1...600, default: 3)
      try withMachine { $0.pressKey(key) }
      let (held, stop) = try run(hold)
      try withMachine { $0.releaseKey(key) }
      if let stop {
        return ToolResult([.text("Tapped \(name) after \(held) frame(s). \(stop)")])
      }
      let (after, stop2) = try run(hold)
      return ToolResult([.text("Tapped \(name) (\(held + after) frames)." + (stop2.map { " \($0)" } ?? ""))])
    default:
      throw AutomationError("Unknown action \(action).")
    }
  }

  private func typeText(_ args: Arguments) throws -> ToolResult {
    guard let text = try args.string("text") else { throw AutomationError("text is required.") }
    let limit = try args.int("max_frames", in: 1...36000, default: 6000)
    pasteQueue.enqueue(text)
    let queue = pasteQueue
    let (frames, stop) = try run(limit) { pc88 in
      guard !queue.isEmpty else { return false }
      queue.tick { event in
        if event.down { pc88.pressKey(event.key) } else { pc88.releaseKey(event.key) }
      }
      return true
    }
    if !queue.isEmpty {
      try withMachine { pc88 in
        queue.cancel { event in
          if !event.down { pc88.releaseKey(event.key) }
        }
      }
      let reason = stop ?? "Gave up after \(frames) frame(s); the rest was not typed."
      return ToolResult([.text(reason)], isError: stop == nil)
    }
    return ToolResult([.text("Typed in \(frames) frame(s).")])
  }

  // MARK: - Screen

  private func renderPNG() throws -> [UInt8] {
    let rgba = try withMachine { pc88 -> [UInt8] in
      var buffer = [UInt8](repeating: 0, count: PC88.frameBufferSize)
      pc88.render(into: &buffer, blinkCursor: false)
      return buffer
    }
    return PNGEncoder.encodeRGB(rgba: rgba, width: PC88.frameWidth, height: PC88.frameHeight)
  }

  private func screenshot(_ args: Arguments) throws -> ToolResult {
    let png = try renderPNG()
    var content: [ToolContent] = [.png(png)]
    if args.has("path") {
      let url = try args.path("path")
      try Data(png).write(to: url, options: .atomic)
      content.append(.text("Saved \(url.path)."))
    }
    return ToolResult(content)
  }

  // MARK: - Debugging

  private func readMemory(_ args: Arguments) throws -> ToolResult {
    let address = try args.address("address")
    let length = try args.int("length", in: 1...4096, default: 256)
    let space = try args.string("space") ?? "cpu"
    let cpu = try args.cpu()
    let region = try Self.region(named: space)
    let bytes: [UInt8] = try withMachine { pc88 in
      guard let region else {
        return (0..<length).map { pc88.peekMemory(cpu, address &+ UInt16(truncatingIfNeeded: $0)) }
      }
      let memory = pc88.memory(region)
      guard Int(address) < memory.count else {
        throw AutomationError("\(space) offsets run 0-\(memory.count - 1).")
      }
      return Array(memory[Int(address)..<min(memory.count, Int(address) + length)])
    }
    return ToolResult([.text(Self.hexDump(bytes, from: address))])
  }

  private func disassemble(_ args: Arguments) throws -> ToolResult {
    let cpu = try args.cpu()
    let count = try args.int("count", in: 1...256, default: 16)
    let start: UInt16? = args.has("address") ? try args.address("address") : nil
    let text = try withMachine { pc88 -> String in
      var address = start ?? pc88.registers(of: cpu).pc
      var lines: [String] = []
      for _ in 0..<count {
        let instruction = Disassembler.decode(at: address) { pc88.peekMemory(cpu, $0) }
        lines.append(Self.formatInstruction(instruction))
        address = instruction.nextAddress
      }
      return lines.joined(separator: "\n")
    }
    return ToolResult([.text(text)])
  }

  private func addBreakpoint(_ args: Arguments) throws -> ToolResult {
    guard let kindName = try args.string("kind") else { throw AutomationError("kind is required.") }
    let address = try args.address("address")
    let kind: Breakpoint.Kind
    switch kindName {
    case "pc": kind = .mainPC(address)
    case "sub-pc": kind = .subPC(address)
    case "mem-read": kind = .memoryRead(address)
    case "mem-write": kind = .memoryWrite(address)
    case "io-read": kind = .ioRead(address & 0xFF)
    case "io-write": kind = .ioWrite(address & 0xFF)
    default: throw AutomationError("Unknown kind \(kindName).")
    }
    var value: UInt8?
    if args.has("value") {
      guard kind.supportsValueFilter else {
        throw AutomationError("value applies to mem-write and io-write only.")
      }
      value = UInt8(try args.int("value", in: 0...255))
    }
    let bp = Breakpoint(kind: kind, valueFilter: value)
    host.debugger.add(bp)
    try updateDebuggerAttachment()
    return ToolResult([.text("Added breakpoint \(Self.shortID(bp.id)): \(Self.describe(bp)).")])
  }

  private func listBreakpoints() -> ToolResult {
    let bps = host.debugger.breakpoints
    guard !bps.isEmpty else { return ToolResult([.text("No breakpoints.")]) }
    let lines = bps.map { bp in
      "\(Self.shortID(bp.id))  \(Self.describe(bp))" + (bp.isEnabled ? "" : "  (disabled)")
    }
    return ToolResult([.text(lines.joined(separator: "\n"))])
  }

  private func removeBreakpoint(_ args: Arguments) throws -> ToolResult {
    let debugger = host.debugger
    if try args.bool("all", default: false) {
      debugger.removeAll()
    } else {
      guard let id = try args.string("id")?.lowercased() else {
        throw AutomationError("Give id or all.")
      }
      guard let bp = debugger.breakpoints.first(where: { Self.shortID($0.id) == id }) else {
        throw AutomationError("No breakpoint \(id).")
      }
      debugger.remove(id: bp.id)
    }
    try updateDebuggerAttachment()
    return ToolResult([.text("\(debugger.breakpoints.count) breakpoint(s) left.")])
  }

  // MARK: - Formatting

  static func shortID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
  }

  static func describe(_ bp: Breakpoint) -> String {
    let base: String
    switch bp.kind {
    case .mainPC(let a): base = String(format: "pc %04X", a)
    case .subPC(let a): base = String(format: "sub-pc %04X", a)
    case .memoryRead(let a): base = String(format: "mem-read %04X", a)
    case .memoryWrite(let a): base = String(format: "mem-write %04X", a)
    case .ioRead(let a): base = String(format: "io-read %02X", a & 0xFF)
    case .ioWrite(let a): base = String(format: "io-write %02X", a & 0xFF)
    }
    return bp.valueFilter.map { base + String(format: " = %02X", $0) } ?? base
  }

  static func formatRegisters(_ r: PC88.CPURegisters) -> String {
    let f = UInt8(r.af & 0xFF)
    let flags = zip("SZ5H3PNC", (0..<8).reversed()).map { name, bit in
      f & (1 << bit) != 0 ? String(name) : "-"
    }.joined()
    return String(format: "PC=%04X SP=%04X AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X\n",
                  r.pc, r.sp, r.af, r.bc, r.de, r.hl, r.ix, r.iy)
      + String(format: "AF'=%04X BC'=%04X DE'=%04X HL'=%04X I=%02X R=%02X IM=%d",
               r.af2, r.bc2, r.de2, r.hl2, r.i, r.r, r.im)
      + " IFF1=\(r.iff1 ? 1 : 0) IFF2=\(r.iff2 ? 1 : 0) flags=\(flags)"
      + (r.halted ? " HALT" : "")
  }

  static func formatInstruction(_ i: DisassembledInstruction) -> String {
    let bytes = i.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    let padded = bytes.padding(toLength: 12, withPad: " ", startingAt: 0)
    return String(format: "%04X  ", i.address) + padded + "  " + i.mnemonic
  }

  static func hexDump(_ bytes: [UInt8], from start: UInt16) -> String {
    var lines: [String] = []
    var offset = 0
    while offset < bytes.count {
      let row = bytes[offset..<min(offset + 16, bytes.count)]
      let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
      let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
      let address = start &+ UInt16(truncatingIfNeeded: offset)
      lines.append(String(format: "%04X  ", address) + hex.padding(toLength: 47, withPad: " ", startingAt: 0)
        + "  " + ascii)
      offset += 16
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Arguments

/// A tool call's arguments, with the checks every tool needs.
struct Arguments {
  let values: [String: JSONValue]

  init(_ values: [String: JSONValue]) {
    self.values = values
  }

  func has(_ name: String) -> Bool {
    if let value = values[name], value != .null { return true }
    return false
  }

  func string(_ name: String) throws -> String? {
    guard has(name) else { return nil }
    guard let s = values[name]?.stringValue else { throw AutomationError("\(name) must be a string.") }
    return s
  }

  func bool(_ name: String, default fallback: Bool) throws -> Bool {
    guard has(name) else { return fallback }
    guard let b = values[name]?.boolValue else { throw AutomationError("\(name) must be true or false.") }
    return b
  }

  func int(_ name: String, in range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
    guard has(name) else {
      guard let fallback else { throw AutomationError("\(name) is required.") }
      return fallback
    }
    guard let n = values[name]?.intValue else { throw AutomationError("\(name) must be an integer.") }
    guard range.contains(n) else {
      throw AutomationError("\(name) must be \(range.lowerBound)-\(range.upperBound).")
    }
    return n
  }

  func cpu() throws -> PC88.CPU {
    switch try string("cpu") ?? "main" {
    case "main": return .main
    case "sub": return .sub
    case let other: throw AutomationError("Unknown cpu \(other); use main or sub.")
    }
  }

  /// An address given as a number or as hex text.
  func address(_ name: String) throws -> UInt16 {
    guard let value = values[name], value != .null else { throw AutomationError("\(name) is required.") }
    let number: Int?
    if let n = value.intValue {
      number = n
    } else if let text = value.stringValue {
      number = Self.parseAddress(text)
    } else {
      number = nil
    }
    guard let number, (0...0xFFFF).contains(number) else {
      throw AutomationError("\(name) must be 0-65535 or hex such as 0xC000, C000H or $C000.")
    }
    return UInt16(number)
  }

  static func parseAddress(_ text: String) -> Int? {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if t.hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
    if t.hasPrefix("$") { return Int(t.dropFirst(), radix: 16) }
    if t.hasSuffix("h") { return Int(t.dropLast(), radix: 16) }
    return Int(t)
  }

  /// An absolute file path; `~` is expanded. Relative paths are refused:
  /// the server's working directory is not the caller's.
  func path(_ name: String) throws -> URL {
    guard let raw = try string(name), !raw.isEmpty else { throw AutomationError("\(name) is required.") }
    var path = raw
    if path == "~" || path.hasPrefix("~/") {
      path = NSHomeDirectory() + path.dropFirst()
    }
    guard path.hasPrefix("/") || Self.isWindowsAbsolute(path) else {
      throw AutomationError("\(name) must be an absolute path.")
    }
    return URL(fileURLWithPath: path)
  }

  private static func isWindowsAbsolute(_ path: String) -> Bool {
    let chars = Array(path)
    return chars.count >= 3 && chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/")
  }
}
