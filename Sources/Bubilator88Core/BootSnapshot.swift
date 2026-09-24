import PC88Types

/// Boots a disk with no host attached and picks one frame to stand for it —
/// what a file browser shows as the disk's thumbnail.
///
/// PC-8801 software loads from disk for seconds before its title appears, so a
/// fixed frame count would catch loading screens on some disks and waste time
/// on others. Instead the run stops once the machine has settled: the drives
/// have gone quiet and the screen shows something. Audio synthesis is off
/// throughout, since nothing would hear it.
///
/// The machine is always N88-BASIC V2 at 4MHz. A disk that needs another mode
/// often ends at the BASIC prompt, which counts as not booting.
public enum BootSnapshot {

  /// Why the run stopped.
  public enum StopReason: String, Sendable {
    /// Drives idle and the screen unchanged for a while.
    case settled
    /// Drives idle for longer still, with the screen still moving but no
    /// longer filling up — an animated title.
    case idle
    /// `Parameters.maxEmulatedSeconds` ran out with something on screen.
    case emulatedLimit
    /// The wall-clock deadline passed with something on screen.
    case deadline
  }

  /// The chosen frame.
  public struct Frame: Sendable {
    /// `PC88.frameWidth` × `PC88.frameHeight` RGBA, as `PC88.render` writes it.
    public let pixels: [UInt8]
    /// Emulated time at which the frame was taken.
    public let emulatedSeconds: Double
    /// Fraction of sampled pixels that are not black.
    public let content: Double
    public let reason: StopReason
  }

  /// The thresholds that decide when the machine has settled. All times are
  /// emulated seconds.
  public struct Parameters: Sendable {
    /// Frames between two looks at the drives and the screen.
    public var sampleInterval = 15
    /// Drive idle time after which an unchanged screen is taken.
    public var settledIdleSeconds = 4.0
    /// How long the screen must stay unchanged for `settled`.
    public var stableSeconds = 4.0
    /// Drive idle time after which a moving screen is taken anyway, as long
    /// as it is not still filling up.
    public var idleSeconds = 10.0
    /// How much the lit fraction may grow over `stableSeconds` for a moving
    /// screen to count as animating rather than still being drawn
    /// (ハイドライド３ paints its title for seconds after the drive stops).
    public var maxGrowth = 0.05
    /// Fraction of sampled pixels that must be non-black for the screen to
    /// count as showing something. 2% rejects a few lines of text on black
    /// (LION's menu lights 0.65%), which makes a poor thumbnail; the
    /// sparsest real title in the test set lights 3.4%.
    public var minContent = 0.02
    /// Give up after this much emulated time.
    public var maxEmulatedSeconds = 90.0
    /// Present the machine without a Sound Board II. Programs that find only
    /// an OPN skip loading their ADPCM samples, which can take seconds of
    /// disk time.
    public var hideSoundBoard2 = true

    public init() {}
  }

  /// Boot `disks` (image 0 in drive 0, image 1, if any, in drive 1) and return
  /// the frame that stands for them, or nil if nothing bootable showed up:
  /// the screen is (nearly) black when the run stops, or the machine ended up
  /// at the BASIC prompt.
  ///
  /// When a limit cuts the run short, the screen at that moment is used only
  /// if it shows something. An earlier frame is not substituted: it tends to
  /// be the BASIC sign-on or a loading screen, not the software.
  ///
  /// - Parameters:
  ///   - roms: BIOS images. N88-BASIC and DISK.ROM are the ones that matter.
  ///   - deadline: wall-clock limit on the run.
  public static func capture(roms: [(PC88.ROM, [UInt8])], disks: [D88Disk],
                             parameters: Parameters = Parameters(),
                             deadline: ContinuousClock.Instant) -> Frame? {
    guard let first = disks.first else { return nil }
    let pc88 = PC88()
    for (rom, data) in roms {
      pc88.loadROM(rom, data: data)
    }
    pc88.installExtRAM()
    pc88.setBootMode(.n88v2)
    pc88.mountDisk(drive: 0, disk: first)
    if disks.count > 1 {
      pc88.mountDisk(drive: 1, disk: disks[1])
    }
    pc88.applyBootStrap()
    pc88.reset()
    pc88.clock8MHz = false
    pc88.audioOutputEnabled = false
    pc88.forceOPNMode = parameters.hideSoundBoard2
    installEmulatedClock(pc88.machine)

    var pixels = [UInt8](repeating: 0, count: PC88.frameBufferSize)
    var lastSignature: UInt64 = 0
    var lastChange = 0.0
    var lastActivity = 0.0
    var contentHistory: [(time: Double, content: Double)] = []
    var now = 0.0

    while true {
      // Read the rate each time: a program can switch the monitor mode, and
      // with it the frame rate, part way through.
      let frameRate = pc88.frameRate
      for _ in 0..<parameters.sampleInterval {
        pc88.runFrame()
      }
      now += Double(parameters.sampleInterval) / frameRate

      if pc88.takeDiskActivity().contains(true) {
        lastActivity = now
      }
      pc88.render(into: &pixels, blinkCursor: false)
      let (signature, content) = sample(pixels)
      if signature != lastSignature {
        lastSignature = signature
        lastChange = now
      }
      contentHistory.append((now, content))
      let earlier = contentHistory.last { $0.time <= now - parameters.stableSeconds }
      let stillFilling = earlier.map { content > $0.content * (1 + parameters.maxGrowth) } ?? true

      let hasContent = content >= parameters.minContent
      let idle = now - lastActivity
      var reason: StopReason?
      if hasContent {
        if idle >= parameters.settledIdleSeconds && now - lastChange >= parameters.stableSeconds {
          reason = .settled
        } else if idle >= parameters.idleSeconds && !stillFilling {
          reason = .idle
        }
      }
      if reason == nil {
        if now >= parameters.maxEmulatedSeconds {
          reason = .emulatedLimit
        } else if ContinuousClock.now >= deadline {
          reason = .deadline
        }
      }
      guard let reason else { continue }
      guard hasContent, !isAtBASICPrompt(pc88.copyTextAsUnicode()) else { return nil }
      return Frame(pixels: pixels, emulatedSeconds: now, content: content, reason: reason)
    }
  }

  /// Whether the text screen shows N88-BASIC waiting for the user: the file
  /// count question still unanswered, the sign-on banner, or a bare `Ok`.
  /// That is where a disk with nothing to autorun ends up. Only meaningful
  /// once the machine has settled — disk BASIC answers the question and
  /// prints the banner on its way to running a game.
  ///
  /// The function key legends are no use as a sign: text VRAM keeps them
  /// after games stop displaying the text layer.
  static func isAtBASICPrompt(_ text: String) -> Bool {
    text.split(whereSeparator: \.isNewline).contains { line in
      let row = line.drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed()
        .map(String.init).joined()
      return row == "Ok" || row.hasSuffix("How many files(0-15)?") || row.hasSuffix("Bytes free")
    }
  }

  /// Every 2nd pixel of every 4th row: an FNV-1a hash to notice changes, and
  /// the fraction of samples that are not black. Dense enough that thin text
  /// strokes are not stepped over.
  static func sample(_ pixels: [UInt8]) -> (signature: UInt64, content: Double) {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var lit = 0
    var count = 0
    pixels.withUnsafeBufferPointer { buffer in
      for y in Swift.stride(from: 0, to: PC88.frameHeight, by: 4) {
        for x in Swift.stride(from: 0, to: PC88.frameWidth, by: 2) {
          let i = (y * PC88.frameWidth + x) * 4
          let rgb = UInt32(buffer[i]) << 16 | UInt32(buffer[i + 1]) << 8 | UInt32(buffer[i + 2])
          hash = (hash ^ UInt64(rgb)) &* 0x0000_0100_0000_01B3
          if rgb != 0 { lit += 1 }
          count += 1
        }
      }
    }
    return (hash, Double(lit) / Double(count))
  }

  /// Drive the calendar from emulated time. The host clock would barely move
  /// while the machine runs many times faster, and programs that wait on the
  /// RTC would stall. The date itself (2025-01-01, a Wednesday) is arbitrary.
  private static func installEmulatedClock(_ machine: Machine) {
    machine.calendar.timeProvider = { [unowned machine] in
      let elapsed = Int(Double(machine.totalTStates) / machine.cpuClock)
      let minutes = elapsed / 60
      let hours = minutes / 60
      return (sec: elapsed % 60, min: minutes % 60, hour: hours % 24,
              day: 1 + hours / 24, wday: 3, mon: 1, year: 25)
    }
  }
}
