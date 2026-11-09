import Foundation
@_spi(Debug) import Bubilator88Core

/// Where the automation tools run: a machine plus the few operations whose
/// right behaviour depends on who owns it.
///
/// The tools themselves (`ToolCatalog`) are written once against this
/// protocol. `PC88AutomationHost` is the plain implementation used by the
/// headless server and the C ABI; the macOS app supplies its own so that
/// resets, disks and save states also update its windows and settings.
///
/// Every method is called from one thread at a time (the server's), never
/// concurrently.
public protocol AutomationHost: AnyObject {
  /// Run `body` on the thread that owns the machine, between frames.
  func withMachine<T>(_ body: (PC88) throws -> T) throws -> T

  /// Run up to `count` frames as fast as possible, calling `beforeEach`
  /// before each one; it returns false to stop early. Stops early, too, when
  /// a breakpoint pauses `debugger`. Returns the frames run, counting the one
  /// a breakpoint cut short.
  ///
  /// A host that also runs the machine in real time stops doing so first and
  /// leaves it stopped, so what the caller sees next is what it ran.
  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool) throws -> Int

  /// The debugger breakpoints are kept in. It need not be attached to the
  /// machine; `setDebuggerAttached` attaches it.
  @_spi(Debug) var debugger: Debugger { get }

  /// Attach the debugger while breakpoints exist, so breakpoints fire; the
  /// host may keep it attached for its own reasons as well.
  func setDebuggerAttached(_ attached: Bool) throws

  /// Whether the machine runs in real time on its own. Always false for a
  /// headless host, whose time moves only through `runFrames`.
  var isRunningInRealTime: Bool { get }

  /// Start or stop real-time running. Throws `AutomationError` on a host
  /// that has no real time.
  func setRunningInRealTime(_ running: Bool) throws

  /// Reset the machine. `mode` and `clock8MHz`, when given, change the
  /// machine before a cold reset.
  func reset(cold: Bool, mode: BootMode?, clock8MHz: Bool?) throws

  /// Mount image `imageIndex` of the disk file at `url` in `drive` (0 or 1).
  /// Returns the image's name.
  func mountDisk(drive: Int, url: URL, imageIndex: Int, writeProtected: Bool) throws -> String

  func ejectDisk(drive: Int) throws

  /// Write a `.b88s` save state to `url`.
  func saveState(to url: URL) throws

  /// Restore the `.b88s` save state at `url`.
  func loadState(from url: URL) throws

  /// Load the cassette image at `url`. Returns the format found.
  func mountTape(url: URL) throws -> TapeFormat

  func rewindTape() throws

  func ejectTape() throws
}

/// The plain cassette operations, for a host with no cassette display to
/// keep up to date.
public extension AutomationHost {
  func mountTape(url: URL) throws -> TapeFormat {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    return try withMachine { $0.mountTape(data: data) }
  }

  func rewindTape() throws {
    try withMachine { $0.rewindTape() }
  }

  func ejectTape() throws {
    try withMachine { $0.ejectTape() }
  }
}

/// A failure reported back to the AI as a tool error, in words it can act on.
public struct AutomationError: Error, Equatable, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}
