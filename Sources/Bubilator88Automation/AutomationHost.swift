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

  /// `runFrames(_:beforeEach:)`, also calling `afterEach` after each frame
  /// the machine ran, before the host does anything else with it (such as
  /// dropping its sound).
  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool, afterEach: (PC88) -> Void) throws -> Int

  /// Insert the CD sheet (`.cue` / `.ccd`) at `url`, fitting the drive so
  /// that the next reset brings it in. Does not reset.
  func mountCD(url: URL) throws

  /// Take the CD out.
  func ejectCD() throws

  /// Set or clear the write-protect tab on the disk in `drive` (0 or 1).
  func setWriteProtect(drive: Int, protected: Bool) throws

  /// The names the host shows for the CD and the cassette, nil when it
  /// keeps none or the drive is empty.
  var cdName: String? { get }
  var tapeName: String? { get }
}

/// The plain operations, for a host with no display of its own to keep up
/// to date.
public extension AutomationHost {
  func runFrames(_ count: Int, beforeEach: (PC88) -> Bool, afterEach: (PC88) -> Void) throws -> Int {
    try runFramesWithLateAfterEach(count, beforeEach: beforeEach, afterEach: afterEach)
  }

  /// `runFrames(_:beforeEach:afterEach:)` built on `runFrames(_:beforeEach:)`:
  /// `afterEach` for a frame runs just before the next frame's `beforeEach`,
  /// or after the run for the last frame, once per frame either way. Enough
  /// where the host keeps what the frame left behind until the next one;
  /// hosts that drop state after each frame (such as its sound) override
  /// `runFrames(_:beforeEach:afterEach:)` instead.
  func runFramesWithLateAfterEach(_ count: Int, beforeEach: (PC88) -> Bool,
                                  afterEach: (PC88) -> Void) throws -> Int {
    // A frame has run whose afterEach is still to come.
    var pending = false
    let frames = try runFrames(count) { pc88 in
      if pending {
        afterEach(pc88)
        pending = false
      }
      guard beforeEach(pc88) else { return false }
      pending = true
      return true
    }
    if pending { try withMachine { afterEach($0) } }
    return frames
  }

  func mountCD(url: URL) throws {
    try withMachine { pc88 in
      do {
        try pc88.mountCD(url: url)
      } catch {
        throw AutomationError("Cannot open \(url.lastPathComponent) as a CD: \(error).")
      }
      // Only once the disc is in: a drive fitted with nothing in it would
      // take over the next reset.
      pc88.cdDriveInstalled = true
    }
  }

  func ejectCD() throws {
    try withMachine { pc88 in
      pc88.ejectCD()
      // From the next reset the machine starts from the disks or BASIC.
      pc88.cdDriveInstalled = false
    }
  }

  func setWriteProtect(drive: Int, protected: Bool) throws {
    try withMachine { $0.setWriteProtect(drive: drive, protected: protected) }
  }

  var cdName: String? { nil }
  var tapeName: String? { nil }
}

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
