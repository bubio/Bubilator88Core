import Foundation
import Testing
import CApi
import Bubilator88Automation

private final class TestAppHost {
  var running = true
  var frames = 0
  var calls: [Int32] = []
  var failReset = false
}

private let testHostCallback: B88MCPHostCallback = { user, operation, request, length, action, actionData, output, capacity in
  let host = Unmanaged<TestAppHost>.fromOpaque(user!).takeUnretainedValue()
  host.calls.append(operation)
  var result = "null"
  switch operation {
  case 0: _ = action?(actionData)
  case 1:
    if action?(actionData) == 1 { host.frames += 1; result = "1" } else { result = "0" }
  case 2: break
  case 3: result = host.running ? "true" : "false"
  case 4:
    if let request {
      let data = Data(bytes: request, count: Int(length))
      host.running = (try? JSONValue(parsing: data).boolValue) ?? false
    }
  case 5: _ = action?(actionData)
  case 6 where host.failReset: result = "Reset refused by host"
  default: break
  }
  let data = Array(result.utf8)
  if let output {
    for i in 0..<min(data.count, Int(capacity)) { output[i] = data[i] }
  }
  return operation == 6 && host.failReset ? -Int32(data.count) : Int32(data.count)
}

@Suite("C ABI App Automation Host")
struct CApiAutomationHostTests {
  private func withSession(_ body: (UnsafeMutableRawPointer, TestAppHost) throws -> Void) rethrows {
    let machine = b88_create()
    defer { b88_destroy(machine) }
    let host = TestAppHost()
    let user = Unmanaged.passUnretained(host).toOpaque()
    let session = b88_mcp_session_create(machine, user, testHostCallback, nil)!
    defer { b88_mcp_session_destroy(session) }
    try body(session, host)
  }

  private func call(_ session: UnsafeMutableRawPointer, _ name: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
    let request: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                              "params": ["name": .string(name), "arguments": arguments]]
    let input = Array(request.encoded())
    let length = input.withUnsafeBufferPointer { b88_mcp_session_handle(session, $0.baseAddress, Int32($0.count)) }
    var output = [UInt8](repeating: 0, count: Int(length))
    #expect(b88_mcp_session_reply(session, &output, length) == length)
    return try JSONValue(parsing: Data(output))
  }

  @Test func statusUsesAppHost() throws {
    try withSession { session, host in
      let result = try call(session, "status")
      let text = result["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
      let status = try JSONValue(parsing: Data(text.utf8))
      #expect(status["real_time"] == true)
      #expect(host.calls.contains(0))
      #expect(host.calls.contains(3))
    }
  }

  @Test func pauseResumeUseAppHost() throws {
    try withSession { session, host in
      let paused = try call(session, "pause")
      #expect(paused["result"]?["isError"] != true)
      #expect(!host.running)
      let resumed = try call(session, "resume")
      #expect(resumed["result"]?["isError"] != true)
      #expect(host.running)
    }
  }

  @Test func frameExecutionUsesHostAndPublishes() throws {
    try withSession { session, host in
      _ = try call(session, "run_frames", ["frames": 3])
      #expect(host.frames == 3)
      #expect(!host.running)
      #expect(host.calls.contains(2))
    }
  }

  @Test func hostFailureIsToolError() throws {
    try withSession { session, host in
      host.failReset = true
      let reply = try call(session, "reset")
      #expect(reply["result"]?["isError"] == true)
      #expect(reply["result"]?["content"]?.arrayValue?.first?["text"] == "Reset refused by host")
    }
  }

  @Test func notificationsDoNotCallHost() {
    withSession { session, host in
      let input = Array("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
      let length = input.withUnsafeBufferPointer { b88_mcp_session_handle(session, $0.baseAddress, Int32($0.count)) }
      #expect(length == 0)
      #expect(host.calls.isEmpty)
    }
  }

  @Test func restartingSessionKeepsBreakpointsAndClearsAgentState() throws {
    let machine = b88_create()
    defer { b88_destroy(machine) }
    let host = TestAppHost()
    let user = Unmanaged.passUnretained(host).toOpaque()
    let first = b88_mcp_session_create(machine, user, testHostCallback, nil)!
    _ = try call(first, "breakpoint_add", ["kind": "pc", "address": 4660])
    _ = try call(first, "watch_add", ["address": 32768])
    _ = try call(first, "write_tracking", ["enable": true])
    b88_mcp_session_destroy(first)
    let second = b88_mcp_session_create(machine, user, testHostCallback, nil)!
    defer { b88_mcp_session_destroy(second) }
    let reply = try call(second, "status")
    let text = reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    let status = try JSONValue(parsing: Data(text.utf8))
    #expect(status["watches"] == 0)
    #expect(status["write_tracking"] == false)
    let breakpoints = try call(second, "breakpoint_list")
    #expect(breakpoints.encodedString().contains("1234"))
    withExtendedLifetime(host) {}
  }
}
