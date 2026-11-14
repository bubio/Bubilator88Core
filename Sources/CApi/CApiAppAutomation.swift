import Foundation
import Bubilator88Automation
@_spi(Debug) import Bubilator88Core

/// A synchronous action supplied by the core. Invoke it only during the host
/// callback, on the machine's serial executor, exactly once for operation 0/5
/// and at most once for operation 1. Never retain either pointer.
public typealias B88MCPMachineAction = @convention(c) (UnsafeMutableRawPointer?) -> Int32

/// App-host bridge, independent of MCP's tools and JSON-RPC messages.
///
/// Operations and their JSON request/reply:
/// 0: withMachine, null/null; invoke action under the machine lock.
/// 1: one host frame, null/0 or 1; under the lock, stop if real time resumed,
///    invoke action (the beforeEach predicate), and only if it returns 1 run
///    one host frame (including cheats/input) and discard its audio.
/// 2: publish the current frame, null/null, on the UI executor.
/// 3: isRunningInRealTime, null/boolean, on the UI executor.
/// 4: setRunningInRealTime, boolean/null, on the UI executor.
/// 5: debugger attachment changed, boolean/null; invoke action under the
///    machine lock, synchronizing any app debugger UI on the UI executor.
/// 6: reset, {cold, mode: string|null, clock8MHz: boolean|null}/null.
/// 7: mountDisk, {drive: 0|1, path, imageIndex, writeProtected}/image name string.
/// 8: ejectDisk, drive number/null.
/// 9: saveState, absolute path string/null.
/// 10: loadState, absolute path string/null.
/// Operations 6-10 use the app's normal commands and update its UI/settings.
/// Tape operations use AutomationHost's default implementation, under operation
/// 0, until the app has cassette UI of its own.
///
/// request and action pointers are borrowed until the callback returns. Write
/// one UTF-8 JSON value to output (capacity bytes) and return its byte length;
/// 0 means null. On failure write UTF-8 error text and return minus its length.
/// The buffer is 65536 bytes; never write past capacity. An oversized result is
/// an error, never a request to repeat a potentially mutating callback.
/// The callback and userData must live until b88_mcp_session_destroy returns.
/// Callbacks must not recursively invoke the session API. Other b88_* calls
/// are allowed under the machine lock. Never hold that lock while waiting for
/// the UI or while calling session_handle/session_destroy.
public typealias B88MCPHostCallback = @convention(c) (
  UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, Int32,
  B88MCPMachineAction?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32
) -> Int32

private final class MachineAction {
  let body: () -> Int32
  init(_ body: @escaping () -> Int32) { self.body = body }
}

private let invokeMachineAction: B88MCPMachineAction = { pointer in
  guard let pointer else { return 0 }
  return Unmanaged<MachineAction>.fromOpaque(pointer).takeUnretainedValue().body()
}

/// Windows equivalent of macOS's AppAutomationHost. MCPHandler and
/// AutomationTools remain unchanged; the application supplies host operations.
protocol CAppSessionHost: AutomationHost {
  func endSession()
}

private final class CAppAutomationHost: CAppSessionHost {
  let context: B88Context
  let callback: B88MCPHostCallback
  let userData: UnsafeMutableRawPointer?
  var debugger: Debugger { context.mcpAppDebugger }

  init(context: B88Context, userData: UnsafeMutableRawPointer?, callback: @escaping B88MCPHostCallback) {
    self.context = context
    self.userData = userData
    self.callback = callback
  }

  private func invoke(_ operation: Int32, _ request: JSONValue = .null,
                      action: (() -> Int32)? = nil) throws -> JSONValue {
    let input = Array(request.encoded())
    var output = [UInt8](repeating: 0, count: 65536)
    let box = action.map(MachineAction.init)
    let result = input.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { output in
        callback(userData, operation, input.baseAddress, Int32(input.count),
                 box == nil ? nil : invokeMachineAction,
                 box.map { Unmanaged.passUnretained($0).toOpaque() }, output.baseAddress, Int32(output.count))
      }
    }
    // Keep the action alive even if the optimizer shortens the local's lifetime.
    withExtendedLifetime(box) {}
    let count = abs(Int64(result))
    guard count <= output.count else { throw AutomationError("App host reply exceeds the callback buffer.") }
    let data = Data(output.prefix(Int(count)))
    guard result >= 0 else { throw AutomationError(String(decoding: data, as: UTF8.self)) }
    return result == 0 ? .null : try JSONValue(parsing: data)
  }

  func withMachine<T>(_ body: (PC88) throws -> T) throws -> T {
    try withoutActuallyEscaping(body) { body in
      var result: Result<T, Error>?
      _ = try invoke(0, action: {
        guard result == nil else { return 0 }
        result = Result { try body(self.context.pc88) }
        return 1
      })
      guard let result else { throw AutomationError("App host did not execute the machine action.") }
      return try result.get()
    }
  }

  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool) throws -> Int {
    try setRunningInRealTime(false)
    var frames = 0
    try withoutActuallyEscaping(beforeEach) { beforeEach in
      while frames < count {
        let ran = try invoke(1, action: { beforeEach(self.context.pc88) ? 1 : 0 })
        guard ran.intValue == 1 else { break }
        frames += 1
        if debugger.isPaused { break }
      }
    }
    _ = try invoke(2)
    return frames
  }

  func setDebuggerAttached(_ attached: Bool) throws {
    var executed = false
    _ = try invoke(5, .bool(attached), action: {
      guard !executed else { return 0 }
      executed = true
      self.context.pc88.debugger = attached ? self.debugger : nil
      return 1
    })
    guard executed else { throw AutomationError("App host did not apply debugger attachment.") }
  }

  var isRunningInRealTime: Bool { (try? invoke(3).boolValue) ?? false }
  func setRunningInRealTime(_ running: Bool) throws { _ = try invoke(4, .bool(running)) }
  func reset(cold: Bool, mode: BootMode?, clock8MHz: Bool?) throws {
    _ = try invoke(6, ["cold": .bool(cold), "mode": mode.map { .string($0.rawValue) } ?? .null,
                       "clock8MHz": clock8MHz.map(JSONValue.bool) ?? .null])
  }
  func mountDisk(drive: Int, url: URL, imageIndex: Int, writeProtected: Bool) throws -> String {
    let result = try invoke(7, ["drive": .number(Double(drive)), "path": .string(url.path),
                               "imageIndex": .number(Double(imageIndex)), "writeProtected": .bool(writeProtected)])
    guard let name = result.stringValue else { throw AutomationError("App host did not return the disk image name.") }
    return name
  }
  func ejectDisk(drive: Int) throws { _ = try invoke(8, .number(Double(drive))) }
  func saveState(to url: URL) throws { _ = try invoke(9, .string(url.path)) }
  func loadState(from url: URL) throws { _ = try invoke(10, .string(url.path)) }

  func endSession() {
    try? withMachine { pc88 in
      debugger.removeAllWatches()
      debugger.isTrackingWrites = false
      pc88.profiler = nil
      pc88.debugger = nil
    }
  }
}

final class CAppMCPSession {
  let host: any CAppSessionHost
  let handler: MCPHandler
  var reply: [UInt8] = []
  init(host: any CAppSessionHost, version: String) {
    self.host = host
    handler = MCPHandler(tools: AutomationTools(host: host), serverVersion: version)
  }
}

/// Create an app-owned MCP session. Unlike b88_mcp_handle this does not select
/// a headless host. Supply the synchronous host callback described above.
/// Call under the machine lock. One active app session per machine; retain its
/// callbacks until destruction. The session retains the native machine context.
@_cdecl("b88_mcp_session_create")
public func b88_mcp_session_create(_ machine: UnsafeMutableRawPointer?, _ userData: UnsafeMutableRawPointer?,
                                    _ callback: B88MCPHostCallback?, _ version: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
  guard let context = context(machine), let callback else { return nil }
  let host = CAppAutomationHost(context: context, userData: userData, callback: callback)
  return Unmanaged.passRetained(CAppMCPSession(host: host, version: string(version) ?? "1.0.0")).toOpaque()
}

/// Run one MCP message on the server's serial executor, WITHOUT holding the
/// machine lock. The host callback marshals each operation to its owner.
/// Returns the reply length or 0 for a notification; session_reply copies it.
/// Serialize handle, reply and destroy for each session. No concurrent calls.
@_cdecl("b88_mcp_session_handle")
public func b88_mcp_session_handle(_ session: UnsafeMutableRawPointer?, _ json: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
  guard let session else { return 0 }
  let s = Unmanaged<CAppMCPSession>.fromOpaque(session).takeUnretainedValue()
  s.reply = s.handler.handle(Data(bytes(json, len))).map(Array.init) ?? []
  return Int32(s.reply.count)
}

/// Copy the last reply. Returns the full length even if cap was too small;
/// nil output queries its size. Does not call back into the app.
@_cdecl("b88_mcp_session_reply")
public func b88_mcp_session_reply(_ session: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UInt8>?, _ cap: Int32) -> Int32 {
  guard let session else { return 0 }
  return copyOut(Unmanaged<CAppMCPSession>.fromOpaque(session).takeUnretainedValue().reply, output, cap)
}

/// End an app session after its last request has finished. Clears its watches,
/// write tracking and profiler and detaches its debugger; breakpoints stay in
/// the machine's shared app debugger, as on macOS. Calls the host's operation 0.
/// Do not hold the machine lock. The pointer must not be used afterwards.
@_cdecl("b88_mcp_session_destroy")
public func b88_mcp_session_destroy(_ session: UnsafeMutableRawPointer?) {
  guard let session else { return }
  let s = Unmanaged<CAppMCPSession>.fromOpaque(session).takeRetainedValue()
  s.host.endSession()
}
