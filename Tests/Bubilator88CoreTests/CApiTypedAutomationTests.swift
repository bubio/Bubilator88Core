import Foundation
import Testing
import CApi
import Bubilator88Automation
import PC88Types

private final class TypedHost {
  var running = true
  var frames = 0
  var publishes = 0
  var clock: Int32 = -2
  /// What the after-frame callback saw: "frame" then "after" per frame.
  var events: [String] = []
  var writeProtect: (drive: Int32, protected: Int32)?
}

private let machine: B88MCPExecute = { _, action, data, _ in _ = action?(data) }
private let frame: B88MCPRunFrame = { user, predicate, data, _ in
  let h = Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue()
  guard !h.running, predicate?(data) == 1 else { return 0 }
  h.frames += 1
  return 1
}
private let publish: B88MCPPublish = { user, _ in
  Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue().publishes += 1
}
private let running: B88MCPGetRunning = { user, _ in
  Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue().running ? 1 : 0
}
private let setRunning: B88MCPSetRunning = { user, value, _ in
  Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue().running = value != 0
}
private let debugger: B88MCPSetDebugger = { _, _, action, data, _ in _ = action?(data) }
private let reset: B88MCPReset = { user, _, _, clock, result in
  Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue().clock = clock
  let error = Array("Host reset failed".utf8)
  error.withUnsafeBufferPointer { b88_mcp_app_result_error(result, $0.baseAddress, Int32($0.count)) }
}
private let mount: B88MCPMountDisk = { _, _, _, _, _, result in
  let name = Array("Disk name".utf8)
  name.withUnsafeBufferPointer { b88_mcp_app_result_text(result, $0.baseAddress, Int32($0.count)) }
}
private let eject: B88MCPEjectDisk = { _, _, _ in }
private let frameAfter: B88MCPRunFrameAfter = { user, predicate, data, after, afterData, _ in
  let h = Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue()
  guard !h.running, predicate?(data) == 1 else { return 0 }
  h.frames += 1
  h.events.append("frame")
  _ = after?(afterData)
  h.events.append("after")
  return 1
}
private let writeProtect: B88MCPSetWriteProtect = { user, drive, protected, _ in
  Unmanaged<TypedHost>.fromOpaque(user!).takeUnretainedValue().writeProtect = (drive, protected)
}
private let file: B88MCPStateFile = { _, _, _ in }

@Suite("Typed C ABI Automation Host")
struct CApiTypedAutomationTests {
  private func withSession(extras: Bool = false,
                           _ body: (UnsafeMutableRawPointer, TypedHost) throws -> Void) rethrows {
    let context = b88_create()
    defer { b88_destroy(context) }
    let h = TypedHost()
    let session = b88_mcp_app_session_create(context, Unmanaged.passUnretained(h).toOpaque(),
                                             machine, frame, publish, running, setRunning, debugger, reset, mount, eject, file, file, nil)!
    defer { b88_mcp_session_destroy(session) }
    if extras {
      #expect(b88_mcp_app_session_set_frame_after(session, frameAfter) == 1)
      #expect(b88_mcp_app_session_set_write_protect(session, writeProtect) == 1)
    }
    if let disk = D88Disk.createFormatted(type: .twoD).serialize() {
      _ = disk.withUnsafeBufferPointer { b88_mount_disk(context, 0, $0.baseAddress, Int32($0.count), 0) }
    }
    try body(session, h)
    withExtendedLifetime(h) {}
  }

  private func call(_ session: UnsafeMutableRawPointer, _ method: String,
                    _ params: JSONValue = [:]) throws -> JSONValue {
    let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    let bytes = Array(request.encoded())
    let count = bytes.withUnsafeBufferPointer { b88_mcp_session_handle(session, $0.baseAddress, Int32($0.count)) }
    var reply = [UInt8](repeating: 0, count: Int(count))
    _ = b88_mcp_session_reply(session, &reply, count)
    return try JSONValue(parsing: Data(reply))
  }

  @Test func transportOnlyMessagesDoNotPublish() throws {
    try withSession { s, h in
      _ = try call(s, "initialize")
      _ = try call(s, "ping")
      _ = try call(s, "tools/list")
      #expect(h.publishes == 0)
    }
  }

  @Test func typedFramesPauseAndPublishOnce() throws {
    try withSession { s, h in
      _ = try call(s, "tools/call", ["name": "run_frames", "arguments": ["frames": 3]])
      #expect(!h.running)
      #expect(h.frames == 3)
      #expect(h.publishes == 1)
    }
  }

  @Test func typedErrorReachesToolResult() throws {
    try withSession { s, h in
      let reply = try call(s, "tools/call", ["name": "reset", "arguments": ["clock": "4mhz"]])
      #expect(h.clock == 0)
      #expect(reply["result"]?["isError"] == true)
      #expect(reply.encodedString().contains("Host reset failed"))
    }
  }

  @Test func typedDiskNameReachesToolResult() throws {
    try withSession { s, _ in
      let reply = try call(s, "tools/call", ["name": "mount_disk", "arguments": ["drive": 1, "path": "/disk.d88"]])
      #expect(reply["result"]?["isError"] != true)
      #expect(reply.encodedString().contains("Disk name"))
    }
  }

  @Test func afterFrameCallbackRunsEachFrameOnce() throws {
    try withSession(extras: true) { s, h in
      let reply = try call(s, "tools/call", ["name": "capture_audio", "arguments": ["frames": 3]])
      #expect(reply["result"]?["isError"] != true)
      #expect(h.events == ["frame", "after", "frame", "after", "frame", "after"])
      #expect(h.publishes == 1)
      // Plain runs still use the plain frame callback.
      _ = try call(s, "tools/call", ["name": "run_frames", "arguments": ["frames": 2]])
      #expect(h.frames == 5)
      #expect(h.events.count == 6)
    }
  }

  @Test func writeProtectGoesThroughTheApp() throws {
    try withSession(extras: true) { s, h in
      _ = try call(s, "tools/call", ["name": "set_write_protect", "arguments": ["drive": 1, "protected": true]])
      #expect(h.writeProtect?.drive == 0)
      #expect(h.writeProtect?.protected == 1)
    }
  }

  @Test func extrasAreOptional() throws {
    try withSession { s, h in
      let reply = try call(s, "tools/call", ["name": "capture_audio", "arguments": ["frames": 3]])
      #expect(reply["result"]?["isError"] != true)
      #expect(h.frames == 3)
      #expect(h.events.isEmpty)
    }
    #expect(b88_mcp_app_session_set_frame_after(nil, frameAfter) == 0)
  }
}
