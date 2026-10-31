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
}
