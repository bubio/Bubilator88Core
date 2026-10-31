import Foundation
@_spi(Debug) import Bubilator88Core

/// An `AutomationHost` that owns nothing but a `PC88`: the headless server's,
/// and the one behind the C ABI.
///
/// Time moves only through `runFrames`. Disks are read into memory and never
/// written back to their files; save the state to keep changes.
///
/// Like `PC88`, confine an instance to one thread.
public final class PC88AutomationHost: AutomationHost {
  public let pc88: PC88
  @_spi(Debug) public let debugger = Debugger()
  /// The clock to run at. A reset puts the machine back to 8MHz, so this is
  /// applied again after every one.
  private var clock8MHz: Bool

  /// Wrap `pc88`, which the caller has loaded with ROMs and reset.
  public init(pc88: PC88) {
    self.pc88 = pc88
    clock8MHz = pc88.clock8MHz
  }

  /// A machine loaded from the BIOS files in `romDirectory` (see
  /// `BIOSDirectory`), booted cold in `mode`, with sound synthesis off and
  /// the calendar following emulated time so runs repeat exactly.
  public convenience init(romDirectory: URL, mode: BootMode = .n88v2,
                          clock8MHz: Bool = false) throws {
    let pc88 = PC88()
    try BIOSDirectory.load(into: pc88, from: romDirectory)
    pc88.audioOutputEnabled = false
    BootSnapshot.installEmulatedClock(pc88.machine)
    self.init(pc88: pc88)
    try reset(cold: true, mode: mode, clock8MHz: clock8MHz)
  }

  public func withMachine<T>(_ body: (PC88) throws -> T) throws -> T {
    try body(pc88)
  }

  public func runFrames(_ count: Int, beforeEach: (PC88) -> Bool) throws -> Int {
    var run = 0
    while run < count, beforeEach(pc88) {
      pc88.runFrame()
      run += 1
      if debugger.isPaused { break }
    }
    return run
  }

  public func setDebuggerAttached(_ attached: Bool) throws {
    pc88.debugger = attached ? debugger : nil
  }

  public var isRunningInRealTime: Bool { false }

  public func setRunningInRealTime(_ running: Bool) throws {
    throw AutomationError("This machine is headless: time moves only with run_frames.")
  }

  public func reset(cold: Bool, mode: BootMode?, clock8MHz: Bool?) throws {
    if cold {
      if let mode { pc88.setBootMode(mode) }
      if let clock8MHz { self.clock8MHz = clock8MHz }
      pc88.applyBootStrap()
    }
    pc88.reset(preserveRAM: !cold)
    // As the app does: the clock goes on after the reset, which sets 8MHz.
    pc88.clock8MHz = self.clock8MHz
  }

  public func mountDisk(drive: Int, url: URL, imageIndex: Int, writeProtected: Bool) throws -> String {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    let images = D88Disk.parseAll(data: Array(data))
    guard !images.isEmpty else {
      throw AutomationError("\(url.lastPathComponent) is not a D88 disk image.")
    }
    guard images.indices.contains(imageIndex) else {
      throw AutomationError("\(url.lastPathComponent) holds \(images.count) image(s); image \(imageIndex) does not exist.")
    }
    var disk = images[imageIndex]
    disk.writeProtected = disk.writeProtected || writeProtected
    pc88.mountDisk(drive: drive, disk: disk)
    return disk.name
  }

  public func ejectDisk(drive: Int) throws {
    pc88.ejectDisk(drive: drive)
  }

  public func saveState(to url: URL) throws {
    try Data(pc88.createSaveState()).write(to: url, options: .atomic)
  }

  public func loadState(from url: URL) throws {
    try pc88.loadSaveState(Array(Data(contentsOf: url)))
  }
}

/// The BIOS ROM files a user supplies, by the names the macOS app reads.
public enum BIOSDirectory {
  /// `Bubilator88` in the user's Application Support folder, where the app
  /// keeps them.
  public static var defaultDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory())
    return base.appendingPathComponent("Bubilator88", isDirectory: true)
  }

  /// Load every ROM present in `directory` into `pc88` and install 128KB of
  /// extended RAM, as the app does by default. Only N88.ROM is required.
  public static func load(into pc88: PC88, from directory: URL) throws {
    var files: [(PC88.ROM, [String])] = [
      (.n88Basic, ["N88.ROM"]), (.nBasic, ["N80.ROM"]), (.font, ["FONT.ROM"]),
      (.kanji1, ["KANJI1.ROM"]), (.kanji2, ["KANJI2.ROM"]), (.disk, ["DISK.ROM"]),
    ]
    files += (0..<4).map { (.n88Ext(bank: $0), ["N88_\($0).ROM", "N88EXT\($0).ROM"]) }

    var loadedN88 = false
    for (rom, names) in files {
      for name in names {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
          pc88.loadROM(rom, data: Array(data))
          if rom == .n88Basic { loadedN88 = true }
          break
        }
      }
    }
    guard loadedN88 else {
      throw AutomationError("N88.ROM not found in \(directory.path).")
    }
    if let data = try? Data(contentsOf: directory.appendingPathComponent("JISYO.ROM")) {
      pc88.loadDictionaryROM(Array(data))
    }
    pc88.installExtRAM(cards: 1, banksPerCard: 4)
  }
}
