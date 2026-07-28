// ScriptPlayer.swift — replays a [ScriptStep] timeline on a Machine.
//
// This is the drive mode of docs/SCRIPTING.md, where the script owns the clock.
// It never touches the file system: resolving a disk path to bytes is delegated
// to the `FileLoader` closure supplied by the caller, which keeps this type
// pure, easy to test, and sandbox-friendly.

import Foundation

public final class ScriptPlayer {

  /// Resolves a disk path string to the bytes of a D88 image.
  public typealias FileLoader = (_ path: String) throws -> [UInt8]

  /// A playback error, such as a failed disk load or an out-of-range image.
  ///
  /// Like ``ScriptError``, the message is kept as an English format string plus
  /// its arguments so the app layer can localize it; `format` doubles as the
  /// String Catalog key.
  public struct RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    /// English format string, using positional `%1$@`-style placeholders when
    /// there is more than one argument. Doubles as the String Catalog key.
    public let format: String

    /// Values substituted into `format`, already rendered as strings.
    public let arguments: [String]

    /// The English message, with `arguments` substituted in.
    public var message: String {
      arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }

    public init(_ format: String, arguments: [String] = []) {
      self.format = format
      self.arguments = arguments
    }

    public var description: String { message }
  }

  private let machine: Machine
  private let loader: FileLoader

  /// All images of the file mounted in each drive, kept for `disk select`.
  private var loadedImages: [[D88Disk]] = [[], []]

  /// The disk path and selected image index currently mounted in each drive.
  /// Exposed through `driveMount(_:)` so that after playback the app layer can
  /// rebuild a `MountedDiskInfo` and offer the same image-selection UI as a
  /// manual mount.
  private var mountedPaths: [String?] = [nil, nil]
  private var mountedIndexes: [Int] = [0, 0]

  /// Snapshot of what is mounted in one drive.
  /// `path` is the disk path as written in the script (unresolved), `images`
  /// holds every image in that D88 (the `disk select` candidates), and
  /// `imageIndex` is the currently selected one.
  public struct DriveMount {
    public let path: String
    public let images: [D88Disk]
    public let imageIndex: Int
  }

  /// What is mounted in the given drive, or nil if nothing is (or it was ejected).
  public func driveMount(_ drive: Int) -> DriveMount? {
    guard drive >= 0, drive < mountedPaths.count,
          let path = mountedPaths[drive], !loadedImages[drive].isEmpty else { return nil }
    return DriveMount(path: path, images: loadedImages[drive],
                      imageIndex: mountedIndexes[drive])
  }

  /// Scheduled automatic releases for `tap`, holding the remaining frame count.
  private var pendingReleases: [Keyboard.Key: Int] = [:]

  /// Keys held down by an explicit `down`, which are not auto-released.
  /// Tracked so that cancelling live playback does not strand them in the matrix.
  private var heldDownKeys: Set<Keyboard.Key> = []

  /// Whether the setup → timeline transition has been finalized. Re-armed by reset.
  private var setupFinalized = false

  /// ROM/disk boot (DIPSW2 bit 3) is resolved automatically only when `boot` set
  /// it. A raw `dipsw2` value is taken as the user's intent and left alone.
  private var resolveDiskBoot = true

  /// The clock a `clock` step asked for. `Machine.reset()` forces clock8MHz back
  /// to true, so this is reapplied after a reset to preserve the script's intent.
  /// nil means the script never specified one.
  private var desiredClock8MHz: Bool?

  public init(machine: Machine, loader: @escaping FileLoader) {
    self.machine = machine
    self.loader = loader
  }

  /// Replays a whole script in drive mode, where the player owns the clock.
  public func run(_ steps: [ScriptStep]) throws {
    for step in steps {
      try execute(step)
    }
    finish()
  }

  // MARK: - Live driver (the host owns runFrame)

  /// The live mode of docs/SCRIPTING.md, for riding the app's own 60Hz loop.
  /// Unlike `run()`, the player never calls `runFrame` — the host drives
  /// `machine.runFrame()` each frame and calls `liveTick()` once just before it.
  private var liveSteps: [ScriptStep] = []
  private var liveCursor = 0
  private var liveWaitRemaining = 0
  private var liveActive = false

  /// Whether live playback is in progress.
  public var isLivePlaying: Bool { liveActive }

  /// Starts live playback: applies the setup steps (boot/clock/dipsw/disk) and
  /// advances the cursor to the first `wait` greater than zero. The caller is
  /// expected to have called `machine.reset()` already, as BootTester does in
  /// drive mode.
  public func beginLive(_ steps: [ScriptStep]) throws {
    liveSteps = steps
    liveCursor = 0
    liveWaitRemaining = 0
    pendingReleases.removeAll()
    heldDownKeys.removeAll()
    setupFinalized = false
    liveActive = true
    try liveAdvanceCursor()
  }

  /// Call once per frame, **immediately before** the host's
  /// `machine.runFrame()` — the same position as the app's `tickPasteQueue()`.
  /// Fires any due `tap` releases, consumes one frame of the current `wait`, and
  /// once that wait is exhausted applies the next run of immediate steps
  /// (key, disk, and so on).
  ///
  /// - Returns: `false` once the script is fully consumed and no keys remain held.
  @discardableResult
  public func liveTick() throws -> Bool {
    guard liveActive else { return false }
    tickPendingReleases()
    if liveWaitRemaining > 0 { liveWaitRemaining -= 1 }
    if liveWaitRemaining == 0 {
      try liveAdvanceCursor()
    }
    if liveCursor >= liveSteps.count && liveWaitRemaining == 0 && pendingReleases.isEmpty {
      liveActive = false
      return false
    }
    return true
  }

  /// Cancels live playback, releasing every held key — both pending `tap`
  /// releases and explicit `down` presses.
  public func cancelLive() {
    guard liveActive else { return }
    finish()  // release pending tap holds
    for key in heldDownKeys {  // and don't strand explicit downs either
      machine.keyboard.releaseKey(row: key.row, bit: key.bit)
    }
    heldDownKeys.removeAll()
    liveActive = false
    liveSteps = []
    liveCursor = 0
    liveWaitRemaining = 0
  }

  /// Advances the cursor to the next `wait` greater than zero (or to the end),
  /// applying the immediate steps along the way. Finalizes bit 3 just before the
  /// first advance of time, the same as `advance` does in drive mode.
  private func liveAdvanceCursor() throws {
    while liveCursor < liveSteps.count {
      let step = liveSteps[liveCursor]
      if case .wait(let frames) = step {
        liveCursor += 1
        if frames > 0 {
          finalizeSetupIfNeeded()  // finalize the strap after mounts, at the first time advance
          liveWaitRemaining = frames
          return
        }
        continue  // `wait 0` does not advance time
      }
      try execute(step)
      liveCursor += 1
    }
    finalizeSetupIfNeeded()  // finalize even when the script ends without a wait
  }

  // MARK: - Step execution

  private func execute(_ step: ScriptStep) throws {
    switch step {
    case .boot(let mode):
      machine.bus.dipSw1 = mode.dipSw1
      machine.bus.dipSw2 = mode.dipSw2
      resolveDiskBoot = true

    case .clock(let mhz):
      let want = (mhz == 8)
      machine.clock8MHz = want
      desiredClock8MHz = want

    case .dipsw1(let v):
      machine.bus.dipSw1 = v

    case .dipsw2(let v):
      machine.bus.dipSw2 = v
      resolveDiskBoot = false

    case .diskMount(let drive, let path, let image):
      // Initial setup (cold mount): mount immediately, bypassing the swap delay.
      // Live playback reuses the Machine, and a reset leaves disks in the drives
      // (subSystem.reset preserves them). Calling mountDisk without ejecting
      // first would take the swap-delay path, briefly making drive 0 nil, and
      // applyBootStrap would then wrongly decide on a ROM boot.
      try mountFile(drive: drive, path: path, image: image, immediate: true)

    case .wait(let frames):
      advance(frames)

    case .key(let key, let action):
      applyKey(key, action)

    case .diskSwap(let drive, let path, let image):
      try mountFile(drive: drive, path: path, image: image)

    case .diskSelect(let drive, let image):
      try selectImage(drive: drive, image: image)

    case .diskEject(let drive):
      machine.ejectDisk(drive: drive)
      loadedImages[drive] = []
      mountedPaths[drive] = nil
      mountedIndexes[drive] = 0

    case .reset(let preserveRAM):
      machine.reset(preserveRAM: preserveRAM)
      // reset forces clock8MHz back to true and releases the whole key matrix.
      // Reapply the clock the script asked for so its intent survives.
      // (dipSw1/2 are preserved across a reset.)
      if let c = desiredClock8MHz { machine.clock8MHz = c }
      pendingReleases.removeAll()
      heldDownKeys.removeAll()  // the reset already released the matrix
      setupFinalized = false  // re-finalize bit 3 before the next advance
    }
  }

  // MARK: - Time advancement

  func advance(_ frames: Int) {  // internal so timing can be unit tested
    guard frames > 0 else { return }  // `wait 0` advances neither time nor the strap
    finalizeSetupIfNeeded()
    for _ in 0..<frames {
      machine.runFrame()
      tickPendingReleases()
    }
  }

  /// Called after each frame to fire any scheduled `tap` releases.
  private func tickPendingReleases() {
    guard !pendingReleases.isEmpty else { return }
    // Iterate a snapshot of the keys so the dictionary itself can be mutated.
    for key in Array(pendingReleases.keys) {
      guard let remaining = pendingReleases[key] else { continue }
      let next = remaining - 1
      if next <= 0 {
        machine.keyboard.releaseKey(row: key.row, bit: key.bit)
        pendingReleases[key] = nil
      } else {
        pendingReleases[key] = next
      }
    }
  }

  /// Finalizes the ROM/disk boot strap exactly once, at the first advance of
  /// time and again after a reset.
  private func finalizeSetupIfNeeded() {
    guard !setupFinalized else { return }
    setupFinalized = true
    if resolveDiskBoot {
      // Derive the boot strap (bit 3) from whether drive 0 is occupied, via the
      // shared Machine helper.
      machine.applyBootStrap()
    }
  }

  // MARK: - Keyboard

  func applyKey(_ key: Keyboard.Key, _ action: KeyAction) {  // internal so timing can be unit tested
    switch action {
    case .down:
      machine.keyboard.pressKey(row: key.row, bit: key.bit)
      pendingReleases[key] = nil
      heldDownKeys.insert(key)
    case .up:
      machine.keyboard.releaseKey(row: key.row, bit: key.bit)
      pendingReleases[key] = nil
      heldDownKeys.remove(key)
    case .tap(let hold):
      // A key already held is re-pressed; pressKey simply overwrites it.
      // §6 guarantees a hold of at least one frame, so round anything below 1 up.
      machine.keyboard.pressKey(row: key.row, bit: key.bit)
      pendingReleases[key] = max(1, hold)
      heldDownKeys.remove(key)  // hand it over to automatic release
    }
  }

  // MARK: - Disk

  /// - Parameter immediate: When `true`, eject before mounting so the disk is
  ///   seated at once, bypassing the swap delay (the ~100ms window during which
  ///   the door is open). Used for cold-boot setup (the `disk` command);
  ///   `disk swap` passes `false`.
  private func mountFile(drive: Int, path: String, image: Int, immediate: Bool = false) throws {
    let data = try loader(path)
    let disks = D88Disk.parseAll(data: data)
    guard !disks.isEmpty else {
      throw RuntimeError("Not a valid D88 image: %@", arguments: [path])
    }
    guard image >= 0 && image < disks.count else {
      throw RuntimeError(
        "Image index %1$@ is out of range (%2$@ has %3$@ image(s)).",
        arguments: ["\(image)", path, "\(disks.count)"])
    }
    loadedImages[drive] = disks
    mountedPaths[drive] = path
    mountedIndexes[drive] = image
    if immediate { machine.ejectDisk(drive: drive) }
    machine.mountDisk(drive: drive, disk: disks[image])
  }

  private func selectImage(drive: Int, image: Int) throws {
    let disks = loadedImages[drive]
    guard !disks.isEmpty else {
      throw RuntimeError(
        "No file is mounted in drive %@ (disk select).", arguments: ["\(drive)"])
    }
    guard image >= 0 && image < disks.count else {
      throw RuntimeError(
        "Image index %1$@ is out of range (drive %2$@ has %3$@ image(s)).",
        arguments: ["\(image)", "\(drive)", "\(disks.count)"])
    }
    machine.mountDisk(drive: drive, disk: disks[image])
    mountedIndexes[drive] = image
  }

  // MARK: - Finish

  /// Releases any outstanding `tap` holds when playback ends.
  private func finish() {
    for key in pendingReleases.keys {
      machine.keyboard.releaseKey(row: key.row, bit: key.bit)
    }
    pendingReleases.removeAll()
  }
}
