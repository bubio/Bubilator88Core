import Foundation
import Bubilator88Automation
@_spi(Debug) import Bubilator88Core

/// Typed, synchronous app callbacks. All pointers are borrowed until the
/// callback returns. Actions run on the machine executor and must not escape.
/// Failures are reported with b88_mcp_app_result_error; no exception may cross
/// the C boundary. Only result_error/result_text may re-enter the session's
/// callback machinery. Normal machine b88_* calls are allowed under its lock.
public typealias B88MCPExecute = @convention(c) (UnsafeMutableRawPointer?, B88MCPMachineAction?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
/// Return 1 after one host frame, or 0 if real time resumed or the predicate
/// returned 0. Check real time and invoke the predicate under the machine lock.
/// Include normal input/cheats, and discard audio produced while paused.
public typealias B88MCPRunFrame = @convention(c) (UnsafeMutableRawPointer?, B88MCPMachineAction?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
public typealias B88MCPPublish = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
public typealias B88MCPGetRunning = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
public typealias B88MCPSetRunning = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void
/// Synchronize app debugger ownership, then execute the attachment action once
/// under the machine lock. Never wait for UI while holding that lock.
public typealias B88MCPSetDebugger = @convention(c) (UnsafeMutableRawPointer?, Int32, B88MCPMachineAction?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
/// cold is 0/1. mode: -1 unchanged, 0 N88-V2, 1 V1H, 2 V1S, 3 N-BASIC.
/// clock8MHz: -1 unchanged, 0 4MHz, 1 8MHz. Use the app's normal reset command.
public typealias B88MCPReset = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Void
/// drive: 0/1, imageIndex: zero-based, writeProtected: 0/1. The path is
/// NUL-terminated UTF-8. Return the name with b88_mcp_app_result_text.
public typealias B88MCPMountDisk = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutableRawPointer?) -> Void
public typealias B88MCPEjectDisk = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Void
/// Path is NUL-terminated UTF-8. Use normal application save/load commands.
public typealias B88MCPStateFile = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

private final class AppHostResult {
  var error: String?
  var text: String?
}

/// Set a callback failure. result is borrowed and valid only inside its host
/// callback. Copies len UTF-8 bytes immediately; never retains the input.
@_cdecl("b88_mcp_app_result_error")
public func b88_mcp_app_result_error(_ result: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt8>?, _ len: Int32) {
  guard let result else { return }
  let message = String(decoding: bytes(text, len), as: UTF8.self)
  Unmanaged<AppHostResult>.fromOpaque(result).takeUnretainedValue().error = message.isEmpty ? "App host failed." : message
}

/// Return a mount callback's image name. Copies exactly len UTF-8 bytes.
@_cdecl("b88_mcp_app_result_text")
public func b88_mcp_app_result_text(_ result: UnsafeMutableRawPointer?, _ text: UnsafePointer<UInt8>?, _ len: Int32) {
  guard let result else { return }
  Unmanaged<AppHostResult>.fromOpaque(result).takeUnretainedValue().text = String(decoding: bytes(text, len), as: UTF8.self)
}

private final class TypedMachineAction {
  let body: () -> Int32
  init(_ body: @escaping () -> Int32) { self.body = body }
}
private let performTypedAction: B88MCPMachineAction = { data in
  guard let data else { return 0 }
  return Unmanaged<TypedMachineAction>.fromOpaque(data).takeUnretainedValue().body()
}

/// An AutomationHost adapter with the same method boundaries as macOS's
/// AppAutomationHost. JSON-RPC and tool semantics stay in AutomationTools.
private final class TypedAppAutomationHost: CAppSessionHost {
  let context: B88Context
  var debugger: Debugger { context.mcpAppDebugger }
  let user: UnsafeMutableRawPointer?
  let execute: B88MCPExecute
  let frame: B88MCPRunFrame
  let publish: B88MCPPublish
  let getRunning: B88MCPGetRunning
  let setRunning: B88MCPSetRunning
  let attach: B88MCPSetDebugger
  let resetMachine: B88MCPReset
  let mount: B88MCPMountDisk
  let eject: B88MCPEjectDisk
  let save: B88MCPStateFile
  let load: B88MCPStateFile
  // Sessions are serial. Reuse this small result cell; hot callbacks allocate
  // neither a JSON payload nor an output byte buffer.
  private let result = AppHostResult()

  init(context: B88Context, user: UnsafeMutableRawPointer?, execute: @escaping B88MCPExecute,
       frame: @escaping B88MCPRunFrame, publish: @escaping B88MCPPublish,
       getRunning: @escaping B88MCPGetRunning, setRunning: @escaping B88MCPSetRunning,
       attach: @escaping B88MCPSetDebugger, reset: @escaping B88MCPReset,
       mount: @escaping B88MCPMountDisk, eject: @escaping B88MCPEjectDisk,
       save: @escaping B88MCPStateFile, load: @escaping B88MCPStateFile) {
    self.context = context; self.user = user; self.execute = execute
    self.frame = frame; self.publish = publish; self.getRunning = getRunning
    self.setRunning = setRunning; self.attach = attach; resetMachine = reset
    self.mount = mount; self.eject = eject; self.save = save; self.load = load
  }

  private func call<T>(_ callback: (UnsafeMutableRawPointer) -> T) throws -> T {
    result.error = nil; result.text = nil
    let value = callback(Unmanaged.passUnretained(result).toOpaque())
    if let error = result.error { throw AutomationError(error) }
    return value
  }

  func withMachine<T>(_ body: (PC88) throws -> T) throws -> T {
    try withoutActuallyEscaping(body) { body in
      var value: Result<T, Error>?
      let action = TypedMachineAction {
        guard value == nil else { return 0 }
        value = Result { try body(self.context.pc88) }; return 1
      }
      try call { execute(user, performTypedAction, Unmanaged.passUnretained(action).toOpaque(), $0) }
      withExtendedLifetime(action) {}
      guard let value else { throw AutomationError("App host did not execute the machine action.") }
      return try value.get()
    }
  }

  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool) throws -> Int {
    try setRunningInRealTime(false)
    var ran = 0
    try withoutActuallyEscaping(beforeEach) { predicate in
      let action = TypedMachineAction { predicate(self.context.pc88) ? 1 : 0 }
      while ran < count {
        guard try call({ frame(user, performTypedAction, Unmanaged.passUnretained(action).toOpaque(), $0) }) == 1 else { break }
        ran += 1
        if debugger.isPaused { break }
      }
      withExtendedLifetime(action) {}
    }
    try call { publish(user, $0) }
    return ran
  }

  func setDebuggerAttached(_ attached: Bool) throws {
    var executed = false
    let action = TypedMachineAction {
      guard !executed else { return 0 }; executed = true
      self.context.pc88.debugger = attached ? self.debugger : nil
      return 1
    }
    try call { attach(user, attached ? 1 : 0, performTypedAction, Unmanaged.passUnretained(action).toOpaque(), $0) }
    withExtendedLifetime(action) {}
    guard executed else { throw AutomationError("App host did not apply debugger attachment.") }
  }

  var isRunningInRealTime: Bool { (try? call { getRunning(user, $0) != 0 }) ?? false }
  func setRunningInRealTime(_ running: Bool) throws { try call { setRunning(user, running ? 1 : 0, $0) } }
  func reset(cold: Bool, mode: BootMode?, clock8MHz: Bool?) throws {
    let modeValue: Int32 = switch mode {
    case .none: -1; case .n88v2: 0; case .n88v1h: 1; case .n88v1s: 2; case .nbasic: 3
    }
    try call { resetMachine(user, cold ? 1 : 0, modeValue, clock8MHz.map { $0 ? 1 : 0 } ?? -1, $0) }
  }
  func mountDisk(drive: Int, url: URL, imageIndex: Int, writeProtected: Bool) throws -> String {
    try url.path.withCString { path in
      try call { mount(user, Int32(drive), path, Int32(imageIndex), writeProtected ? 1 : 0, $0) }
    }
    guard let name = result.text else { throw AutomationError("App host did not return the disk image name.") }
    return name
  }
  func ejectDisk(drive: Int) throws { try call { eject(user, Int32(drive), $0) } }
  func saveState(to url: URL) throws { try url.path.withCString { path in try call { save(user, path, $0) } } }
  func loadState(from url: URL) throws { try url.path.withCString { path in try call { load(user, path, $0) } } }
  func endSession() {
    try? withMachine { pc88 in
      debugger.removeAllWatches(); debugger.isTrackingWrites = false
      pc88.profiler = nil; pc88.debugger = nil
    }
  }
}

/// Create a typed app session. All callbacks are required and must stay alive
/// until session_destroy finishes. Serialize handle/reply/destroy, exactly as
/// for session_create. This additive factory returns the same session handle
/// type accepted by the existing b88_mcp_session_* functions. Neither this
/// factory nor its typed callbacks change the legacy JSON callback contract.
/// Call creation under the machine lock; handle/destroy WITHOUT that lock.
@_cdecl("b88_mcp_app_session_create")
public func b88_mcp_app_session_create(_ machine: UnsafeMutableRawPointer?, _ user: UnsafeMutableRawPointer?,
  _ execute: B88MCPExecute?, _ frame: B88MCPRunFrame?, _ publish: B88MCPPublish?,
  _ getRunning: B88MCPGetRunning?, _ setRunning: B88MCPSetRunning?, _ attach: B88MCPSetDebugger?,
  _ reset: B88MCPReset?, _ mount: B88MCPMountDisk?, _ eject: B88MCPEjectDisk?,
  _ save: B88MCPStateFile?, _ load: B88MCPStateFile?, _ version: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
  guard let context = context(machine), let execute, let frame, let publish, let getRunning,
        let setRunning, let attach, let reset, let mount, let eject, let save, let load else { return nil }
  let host = TypedAppAutomationHost(context: context, user: user, execute: execute, frame: frame,
    publish: publish, getRunning: getRunning, setRunning: setRunning, attach: attach,
    reset: reset, mount: mount, eject: eject, save: save, load: load)
  return Unmanaged.passRetained(CAppMCPSession(host: host, version: string(version) ?? "1.0.0")).toOpaque()
}
