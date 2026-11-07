import Foundation
import Testing
@_spi(Debug) @testable import Bubilator88Automation
@_spi(Debug) @testable import Bubilator88Core
#if canImport(ImageIO)
import ImageIO
#endif

@Suite("Automation Tests")
struct AutomationTests {

  // MARK: - Fixture

  /// A machine whose "N88-BASIC ROM" is a short loop:
  ///
  ///     0000  DI
  ///     0001  LD A,42H
  ///     0003  LD (9000H),A
  ///     0006  INC A
  ///     0007  JR 0003H
  static let program: [UInt8] = [0xF3, 0x3E, 0x42, 0x32, 0x00, 0x90, 0x3C, 0x18, 0xFA]

  final class Fixture {
    let host: PC88AutomationHost
    let handler: MCPHandler
    private var nextID = 1

    init() throws {
      let pc88 = PC88()
      var rom = [UInt8](repeating: 0, count: 0x8000)
      rom.replaceSubrange(0..<AutomationTests.program.count, with: AutomationTests.program)
      pc88.loadROM(.n88Basic, data: rom)
      pc88.audioOutputEnabled = false
      host = PC88AutomationHost(pc88: pc88)
      try host.reset(cold: true, mode: .n88v2, clock8MHz: false)
      handler = MCPHandler(tools: AutomationTools(host: host))
    }

    /// Send a JSON-RPC request through the handler and return its reply.
    func request(_ method: String, _ params: JSONValue = [:]) -> JSONValue {
      let id = nextID
      nextID += 1
      let message: JSONValue = ["jsonrpc": "2.0", "id": JSONValue(id), "method": .string(method), "params": params]
      let reply = handler.handle(message.encoded()).flatMap { try? JSONValue(parsing: $0) }
      return reply ?? .null
    }

    /// Call a tool and return its result object.
    func call(_ name: String, _ arguments: JSONValue = [:]) -> JSONValue {
      request("tools/call", ["name": .string(name), "arguments": arguments])["result"] ?? .null
    }

    /// The text blocks of a tool result, joined.
    func text(_ name: String, _ arguments: JSONValue = [:]) -> String {
      Self.text(of: call(name, arguments))
    }

    static func text(of result: JSONValue) -> String {
      (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    var pc: UInt16 { host.pc88.registers(of: .main).pc }
    var a: UInt8 { UInt8(host.pc88.registers(of: .main).af >> 8) }
  }

  // MARK: - JSON

  @Test func jsonKeepsBooleansAndNumbersApart() throws {
    let value = try JSONValue(parsing: Data("[true, 1, 0, false, 1.5, null]".utf8))
    #expect(value == [true, 1, 0, false, .number(1.5), nil])
  }

  @Test func jsonWritesIntegersWithoutAFraction() {
    let value: JSONValue = ["id": 7, "x": .number(0.5)]
    #expect(value.encodedString() == #"{"id":7,"x":0.5}"#)
  }

  // MARK: - PNG

  @Test func checksumsMatchKnownValues() {
    #expect(PNGEncoder.crc32(Array("IEND".utf8)) == 0xAE42_6082)
    #expect(PNGEncoder.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
  }

  @Test func pngDecodesToTheSamePixels() throws {
    let width = 64, height = 40
    var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
    // Flat areas, repeats and noise, so literals, short and long matches all occur.
    var seed: UInt32 = 12345
    for y in 0..<height {
      for x in 0..<width {
        let p = (y * width + x) * 4
        if y < 10 {
          rgba[p] = 0; rgba[p + 1] = 0; rgba[p + 2] = 0xFF
        } else if y < 20 {
          rgba[p] = UInt8((x / 4) * 16); rgba[p + 1] = UInt8(x % 3 * 80); rgba[p + 2] = 0
        } else {
          seed = seed &* 1_103_515_245 &+ 12345
          rgba[p] = UInt8(seed >> 24); rgba[p + 1] = UInt8(seed >> 16 & 0xFF); rgba[p + 2] = UInt8(seed >> 8 & 0xFF)
        }
      }
    }
    let png = PNGEncoder.encodeRGB(rgba: rgba, width: width, height: height)
    #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    #if canImport(ImageIO)
    let source = try #require(CGImageSourceCreateWithData(Data(png) as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == width && image.height == height)
    var decoded = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(data: &decoded, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    for i in 0..<(width * height) {
      #expect(decoded[i * 4] == rgba[i * 4] && decoded[i * 4 + 1] == rgba[i * 4 + 1]
        && decoded[i * 4 + 2] == rgba[i * 4 + 2], "pixel \(i)")
      if decoded[i * 4] != rgba[i * 4] { break }
    }
    #endif
  }

  // MARK: - Protocol

  @Test func initializeAgreesOnTheClientsVersionWhenSupported() throws {
    let f = try Fixture()
    let reply = f.request("initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                         "clientInfo": ["name": "test", "version": "1"]])
    #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
    #expect(reply["result"]?["capabilities"]?["tools"] != nil)

    let newer = f.request("initialize", ["protocolVersion": "2099-01-01"])
    #expect(newer["result"]?["protocolVersion"] == .string(MCPHandler.supportedVersions[0]))
  }

  @Test func notificationsAndResponsesGetNoReply() throws {
    let f = try Fixture()
    #expect(f.handler.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    #expect(f.handler.handle(["jsonrpc": "2.0", "id": 1, "result": [:]]) == nil)
  }

  @Test func malformedMessagesGetJSONRPCErrors() throws {
    let f = try Fixture()
    let parse = try JSONValue(parsing: try #require(f.handler.handle(Data("{nope".utf8))))
    #expect(parse["error"]?["code"] == -32700)
    #expect(f.handler.handle([1, 2])?["error"]?["code"] == -32600)
    #expect(f.request("resources/list")["error"]?["code"] == -32601)
    #expect(f.request("tools/call", ["name": "no_such_tool"])["error"]?["code"] == -32602)
  }

  @Test func everyToolIsListedWithAnObjectSchema() throws {
    let f = try Fixture()
    let tools = f.request("tools/list")["result"]?["tools"]?.arrayValue ?? []
    let names = tools.compactMap { $0["name"]?.stringValue }
    #expect(names.count == AutomationTools.definitions.count)
    #expect(Set(names).count == names.count)
    for name in ["status", "run_frames", "key", "type_text", "screenshot", "read_text", "registers",
                 "read_memory", "disassemble", "breakpoint_add", "save_state", "mount_disk"] {
      #expect(names.contains(name), "\(name)")
    }
    for tool in tools {
      #expect(tool["inputSchema"]?["type"] == "object")
    }
  }

  @Test func badArgumentsComeBackAsToolErrors() throws {
    let f = try Fixture()
    let result = f.call("run_frames", ["frames": 0])
    #expect(result["isError"] == true)
    #expect(Fixture.text(of: result).contains("frames"))
    #expect(f.call("save_state", ["path": "relative.b88s"])["isError"] == true)
    #expect(f.call("key", ["key": "nosuchkey"])["isError"] == true)
    #expect(f.call("read_memory", ["address": "G000"])["isError"] == true)
  }

  // MARK: - Running and debugging

  @Test func runFramesAdvancesTime() throws {
    let f = try Fixture()
    #expect(f.text("run_frames", ["frames": 3]) == "Ran 3 frame(s).")
    let status = try JSONValue(parsing: Data(f.text("status").utf8))
    #expect(status["frames_run"] == 3)
    #expect(status["real_time"] == false)
    #expect(status["clock"] == "4mhz")
  }

  @Test func headlessHasNoRealTime() throws {
    let f = try Fixture()
    #expect(f.call("resume")["isError"] == true)
    #expect(f.call("pause")["isError"] == true)
  }

  @Test func pcBreakpointStopsAndTheNextRunGetsPastIt() throws {
    let f = try Fixture()
    #expect(f.call("breakpoint_add", ["kind": "pc", "address": "0006H"])["isError"] == false)
    #expect(f.text("run_frames", ["frames": 10]).contains("Stopped at breakpoint"))
    #expect(f.pc == 0x0006)
    let first = f.a
    // Running on executes the instruction under the breakpoint and goes
    // round the loop once more.
    #expect(f.text("run_frames", ["frames": 10]).contains("Stopped at breakpoint"))
    #expect(f.pc == 0x0006)
    #expect(f.a == first &+ 1)

    #expect(f.text("breakpoint_remove", ["all": true]) == "0 breakpoint(s) left.")
    #expect(f.host.pc88.debugger == nil)
    #expect(f.text("run_frames", ["frames": 2]) == "Ran 2 frame(s).")
  }

  @Test func writeBreakpointWithAValueStopsOnThatByte() throws {
    let f = try Fixture()
    _ = f.call("breakpoint_add", ["kind": "mem-write", "address": "0x9000", "value": 0x45])
    #expect(f.text("run_frames", ["frames": 10]).contains("mem-write 9000 = 45"))
    #expect(f.text("read_memory", ["address": "$9000", "length": 1]).hasPrefix("9000  45"))
  }

  @Test func stepShowsRegistersAndTheNextInstruction() throws {
    let f = try Fixture()
    let text = f.text("step", ["count": 3])  // DI, LD A,42H, LD (9000H),A
    #expect(text.contains("Executed 3 instruction(s)."))
    #expect(text.contains("PC=0006"))
    #expect(text.contains("Next: 0006  3C"))
    #expect(f.a == 0x42)
  }

  @Test func stepStopsAtAPCBreakpoint() throws {
    let f = try Fixture()
    _ = f.call("breakpoint_add", ["kind": "pc", "address": 3])
    #expect(f.text("step", ["count": 50]).contains("Executed 2 instruction(s). Stopped at breakpoint"))
  }

  @Test func disassembleStartsAtThePC() throws {
    let f = try Fixture()
    let lines = f.text("disassemble", ["count": 2]).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].hasPrefix("0000  F3"))
    #expect(lines[0].hasSuffix("DI"))
    #expect(lines[1].hasPrefix("0001  3E 42"))
  }

  @Test func readingMemoryDoesNotDisturbTheMachine() throws {
    let f = try Fixture()
    // At 8MHz every main RAM access is charged a wait state.
    _ = f.call("reset", ["clock": "8mhz"])
    _ = f.call("run_frames", ["frames": 1])
    let bus = f.host.pc88.machine.bus
    let waits = bus.pendingWaitStates
    let latches = bus.aluReg
    _ = f.call("read_memory", ["address": "0x8400", "length": 4096])
    #expect(bus.pendingWaitStates == waits)
    _ = f.call("read_memory", ["address": "0xC000", "length": 4096])
    #expect(bus.pendingWaitStates == waits)
    #expect(bus.aluReg == latches)
  }

  @Test func screenshotIsAPNG() throws {
    let f = try Fixture()
    let content = f.call("screenshot")["content"]?.arrayValue ?? []
    #expect(content.first?["type"] == "image")
    #expect(content.first?["mimeType"] == "image/png")
    let data = try #require(Data(base64Encoded: content.first?["data"]?.stringValue ?? ""))
    #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
  }

  @Test func typeTextRunsUntilEverythingIsTyped() throws {
    let f = try Fixture()
    #expect(f.text("type_text", ["text": "AB\n"]).hasPrefix("Typed in"))
    let status = try JSONValue(parsing: Data(f.text("status").utf8))
    #expect((status["frames_run"]?.intValue ?? 0) > 3)
  }

  @Test func saveStateRoundTrips() throws {
    let f = try Fixture()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("s.b88s").path

    _ = f.call("run_frames", ["frames": 2])
    let saved = f.host.pc88.registers(of: .main)
    #expect(f.call("save_state", ["path": .string(path)])["isError"] == false)
    _ = f.call("run_frames", ["frames": 5])
    #expect(f.call("load_state", ["path": .string(path)])["isError"] == false)
    #expect(f.host.pc88.registers(of: .main) == saved)
  }

  @Test func clockSurvivesAReset() throws {
    let f = try Fixture()
    _ = f.call("reset", ["clock": "8mhz"])
    #expect(f.host.pc88.clock8MHz)
    _ = f.call("reset", ["warm": true])
    #expect(f.host.pc88.clock8MHz)
    _ = f.call("reset", ["clock": "4mhz"])
    #expect(!f.host.pc88.clock8MHz)
    #expect(f.call("reset", ["warm": true, "mode": "n-basic"])["isError"] == true)
  }

  @Test func addressesAcceptHexSpellings() {
    #expect(Arguments.parseAddress("0xC000") == 0xC000)
    #expect(Arguments.parseAddress("C000H") == 0xC000)
    #expect(Arguments.parseAddress("$c000") == 0xC000)
    #expect(Arguments.parseAddress("49152") == 0xC000)
    #expect(Arguments.parseAddress("xyz") == nil)
  }

  // MARK: - Development tools

  /// A fresh directory, removed by the caller.
  static func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func cpuWritesLandInTheRAMUnderTheROM() throws {
    let f = try Fixture()
    #expect(f.call("write_memory", ["address": "0x0010", "bytes": "AA bb"])["isError"] == false)
    #expect(f.host.pc88.memory(.mainRAM)[0x10...0x11] == [0xAA, 0xBB])
    // The CPU still reads the ROM there.
    #expect(f.host.pc88.peekMemory(.main, 0x10) == 0x00)
    #expect(f.text("read_memory", ["address": "0x10", "length": 2, "space": "ram"]).hasPrefix("0010  AA BB"))
  }

  @Test func physicalWritesMustFit() throws {
    let f = try Fixture()
    #expect(f.call("write_memory", ["address": "0xFFF", "bytes": "01", "space": "tvram"])["isError"] == false)
    #expect(f.host.pc88.memory(.textVRAM)[0xFFF] == 0x01)
    #expect(f.call("write_memory", ["address": "0xFFF", "bytes": "0102", "space": "tvram"])["isError"] == true)
    #expect(f.call("write_memory", ["address": 0, "bytes": "123"])["isError"] == true)
    #expect(f.call("write_memory", ["address": 0, "bytes": "zz"])["isError"] == true)
  }

  @Test func setRegistersChangesOnlyThoseGiven() throws {
    let f = try Fixture()
    let before = f.host.pc88.registers(of: .main)
    _ = f.call("set_registers", ["pc": "0x1234", "hl": "$BEEF"])
    let after = f.host.pc88.registers(of: .main)
    #expect(after.pc == 0x1234)
    #expect(after.hl == 0xBEEF)
    #expect(after.sp == before.sp)
    #expect(f.call("set_registers", [:])["isError"] == true)
  }

  @Test func loadBinRunsTheProgramThroughTheLauncher() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("p.bin")
    try Data([0x3E, 0x99, 0xC9]).write(to: file)  // LD A,99H / RET

    #expect(f.text("load_bin", ["path": .string(file.path)]).contains("PC=EFF0"))
    let pc88 = f.host.pc88
    pc88.stepInstruction(.main)  // LD SP,F000H
    #expect(pc88.registers(of: .main).sp == 0xF000)
    pc88.stepInstruction(.main)  // CALL C000H
    #expect(f.pc == 0xC000)
    pc88.stepInstruction(.main)
    #expect(f.a == 0x99)
    pc88.stepInstruction(.main)  // RET
    pc88.stepInstruction(.main)  // JP 0000H
    #expect(f.pc == 0x0000)
  }

  @Test func loadBinMovesTheLauncherOutOfTheWay() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("p.bin")
    try Data(repeating: 0, count: 0x40).write(to: file)

    #expect(f.text("load_bin", ["path": .string(file.path), "address": "0xEFE0"]).contains("PC=FFF0"))
    // Above F000H the launcher is in text VRAM too.
    #expect(f.host.pc88.memory(.textVRAM)[0xFF0] == 0x31)
    #expect(f.call("load_bin", ["path": .string(file.path), "address": "0xFFE0"])["isError"] == true)
    #expect(f.text("load_bin", ["path": .string(file.path), "address": "0xFFC0", "launcher": false])
      .contains("PC=FFC0"))
  }

  @Test func memoryMapFollowsTheBanks() throws {
    let f = try Fixture()
    let map = f.text("memory_map")
    #expect(map.contains("0000-5FFF  read: n88-rom  write: ram"))
    #expect(map.contains("8400-BFFF  ram"))
  }

  @Test func traceRecordsOnlyWhileOn() throws {
    let f = try Fixture()
    #expect(f.text("trace").contains("Nothing recorded"))
    _ = f.call("trace", ["enable": true, "last": 0])
    #expect(f.host.pc88.debugger != nil)
    _ = f.call("run_frames", ["frames": 1])
    let lines = f.text("trace", ["last": 3]).split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines.contains { $0.contains("LD (9000),A") || $0.contains("INC A") || $0.contains("JR") })
    _ = f.call("trace", ["enable": false, "last": 0])
    #expect(f.host.pc88.debugger == nil)
  }

  @Test func dumpMemoryWritesTheRegions() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("dump")
    #expect(f.call("dump_memory", ["path": .string(out.path)])["isError"] == false)
    #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("main.bin").path))
  }

  @Test func tapeMountsRewindsAndEjects() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.cmt")
    try Data([0xD3, 0xD3, 0xD3]).write(to: file)

    #expect(f.text("tape", ["action": "mount", "path": .string(file.path)]).contains("CMT"))
    #expect(f.host.pc88.isTapeLoaded)
    #expect(f.call("tape", ["action": "rewind"])["isError"] == false)
    _ = f.call("tape", ["action": "eject"])
    #expect(!f.host.pc88.isTapeLoaded)
  }

  // MARK: - Recording

  @Test func replayRepeatsTheRecordedRun() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = JSONValue.string(dir.appendingPathComponent("r.b88s").path)

    _ = f.call("run_frames", ["frames": 3])
    #expect(f.call("record_start", ["path": path])["isError"] == false)
    _ = f.call("key", ["key": "a", "action": "down"])
    _ = f.call("run_frames", ["frames": 2])
    _ = f.call("key", ["key": "a", "action": "up"])
    _ = f.call("type_text", ["text": "B"])
    _ = f.call("run_frames", ["frames": 1])
    let end = f.host.pc88.registers(of: .main)
    let endTStates = f.host.pc88.totalTStates
    #expect(f.text("record_stop").contains("key event"))

    _ = f.call("run_frames", ["frames": 7])
    #expect(f.text("replay", ["path": path]).hasPrefix("Replayed"))
    #expect(f.host.pc88.registers(of: .main) == end)
    #expect(f.host.pc88.totalTStates == endTStates)

    // The recording is an ordinary save state as well.
    #expect(f.call("load_state", ["path": path])["isError"] == false)
  }

  @Test func recordingRefusesWhatItCannotReplay() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = JSONValue.string(dir.appendingPathComponent("r.b88s").path)

    _ = f.call("record_start", ["path": path])
    #expect(f.call("reset")["isError"] == true)
    #expect(f.call("write_memory", ["address": 0, "bytes": "00"])["isError"] == true)
    #expect(f.call("record_start", ["path": path])["isError"] == true)
    _ = f.call("record_stop")
    #expect(f.call("reset")["isError"] == false)
    #expect(f.call("record_stop")["isError"] == true)
  }

  @Test func replayNeedsRecordedInput() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = JSONValue.string(dir.appendingPathComponent("s.b88s").path)
    _ = f.call("save_state", ["path": path])
    #expect(f.text("replay", ["path": path]).contains("no recorded input"))
  }

  // MARK: - Write tracking

  @Test func lastWriterNamesTheInstruction() throws {
    let f = try Fixture()
    #expect(f.text("last_writer", ["address": "9000H"]).contains("tracking is off"))
    _ = f.call("write_tracking", ["enable": true])
    #expect(f.host.pc88.debugger != nil)
    _ = f.call("run_frames", ["frames": 1])
    let a = f.host.pc88.peekMemory(.main, 0x9000)
    let text = f.text("last_writer", ["address": "9000H", "length": 2])
    #expect(text.contains("9000 ram 9000: PC=0003 wrote " + String(format: "%02X", a) + " at T="))
    #expect(text.contains("9001 ram 9001: no write seen"))
    #expect(f.text("last_writer", ["address": "9000H", "space": "ram"]).hasPrefix("ram 9000: PC=0003"))

    _ = f.call("write_tracking", ["enable": false])
    #expect(f.host.pc88.debugger == nil)
    // A cold reset forgets what was seen.
    _ = f.call("write_tracking", ["enable": true])
    _ = f.call("run_frames", ["frames": 1])
    _ = f.call("reset")
    #expect(f.text("last_writer", ["address": "9000H"]).contains("no write seen"))
  }

  @Test func watchStopsAfterTheWritingInstruction() throws {
    let f = try Fixture()
    #expect(f.text("watch_add", ["address": "9000H"]).contains("(cpu 9000)"))
    let first = f.text("run_frames", ["frames": 10])
    #expect(first.contains("Stopped by watch"))
    #expect(first.contains("9000 (ram 9000), PC=0003 wrote 42"))
    // The write is done, the next instruction not begun.
    #expect(f.pc == 0x0006)
    #expect(f.host.pc88.peekMemory(.main, 0x9000) == 0x42)
    #expect(f.text("run_frames", ["frames": 10]).contains("PC=0003 wrote 43"))
    #expect(f.text("step", ["count": 10]).contains("Executed 3 instruction(s). Stopped by watch"))

    #expect(f.text("watch_remove", ["all": true]) == "0 watch(es) left.")
    #expect(f.host.pc88.debugger == nil)
    #expect(f.text("run_frames", ["frames": 2]) == "Ran 2 frame(s).")
  }

  @Test func watchOnPhysicalMemoryAndItsLimits() throws {
    let f = try Fixture()
    _ = f.call("watch_add", ["address": "9000H", "space": "ram"])
    #expect(f.text("run_frames", ["frames": 10]).contains("(ram 9000)"))
    #expect(f.call("watch_add", ["address": "0FFFH", "length": 2, "space": "tvram"])["isError"] == true)
    #expect(f.call("watch_add", ["address": "FFFFH", "length": 2])["isError"] == true)
    let id = String(f.text("watch_list").prefix(8))
    #expect(f.text("watch_remove", ["id": .string(id)]) == "0 watch(es) left.")
  }

  // MARK: - Profiling

  @Test func symbolFilesReadTheCommonSpellings() {
    let (table, skipped) = SymbolTable.parse("""
    START 0000 ; the reset vector
    LOOP: EQU $0003
    STEP equ 0x0006
    BACK = 0007H
    not a symbol line
    """)
    #expect(table.addresses == ["START": 0, "LOOP": 3, "STEP": 6, "BACK": 7])
    #expect(skipped == ["not a symbol line"])
    #expect(table.label(containing: 0x0005)?.name == "LOOP")
    #expect(table.name(at: 0x0006) == "STEP")
    #expect(table.name(at: 0x0005) == nil)
  }

  @Test func profileGroupsByLabelAndTimesRegions() throws {
    let f = try Fixture()
    let dir = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("p.sym")
    try "START 0000\nLOOP 0003\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(f.text("load_symbols", ["path": .string(file.path)]).hasPrefix("Loaded 2 symbol(s)"))
    #expect(f.text("disassemble", ["address": "LOOP", "count": 1]).hasPrefix("LOOP:\n0003"))

    _ = f.call("profile_region", ["name": "pass", "begin": "LOOP", "end": "LOOP"])
    _ = f.call("profile", ["action": "start"])
    #expect(f.host.pc88.debugger != nil)
    _ = f.call("run_frames", ["frames": 2])
    let report = f.text("profile", ["action": "stop"])
    #expect(f.host.pc88.debugger == nil)
    #expect(report.contains("By label"))
    let loop = try #require(report.split(separator: "\n").first { $0.hasSuffix("LOOP (0003)") })
    // LD (nn),A 13 + INC A 4 + JR 12, plus their waits, every pass.
    let words = loop.split(separator: " ")
    let tStates = try #require(UInt64(words[0]))
    let instructions = try #require(UInt64(words[3]))
    let entries = try #require(UInt64(words[4]))
    #expect(instructions == entries * 3)
    #expect(tStates >= entries * 29)
    #expect(report.contains("pass 0003-0003: "))
    #expect(report.contains("mean 29"))
  }

  @Test func profileWithoutSymbolsListsInstructions() throws {
    let f = try Fixture()
    #expect(f.text("profile").contains("profile start first"))
    _ = f.call("profile", ["action": "start"])
    _ = f.call("run_frames", ["frames": 1])
    let report = f.text("profile", ["top": 3])
    #expect(report.contains("By instruction"))
    #expect(report.contains("0003  LD (9000H),A"))
    _ = f.call("profile", ["action": "clear"])
    #expect(f.text("profile").contains("Nothing counted yet"))
    #expect(f.call("profile_region", ["name": "x", "begin": 0])["isError"] == true)
    #expect(f.call("profile_region", ["name": "x"])["isError"] == true)
  }
}
