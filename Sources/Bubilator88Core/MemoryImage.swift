extension PC88 {

  /// Size of a `.n80` memory image: the RAM from 0x8000 to 0xFF3F.
  public static let memoryImageSize = 0x7F40

  /// Restore a `.n80` memory image — a dump of PC-8001 RAM — and resume it.
  ///
  /// The image holds RAM only, so the host first resets into N-BASIC and lets
  /// the ROM bring up the DMA and interrupts (``MemoryImageBoot`` waits for
  /// that), then calls this. Follows X88000M's `CPC88::LoadMemoryImage`:
  ///
  /// - RAM 0x8000-0xFF3F from the image, 0xFF40-0xFFFF cleared.
  /// - The PC-8001 screen: 40 columns, the CRTC set to 40×20, graphics off.
  /// - HL from the word at 0xEA63, SP from the word at 0xFF3E, interrupt
  ///   mode 2, and PC at 0xFF3D, where the image keeps a `RET` that resumes
  ///   whatever was running when it was taken.
  ///
  /// - Returns: `false`, with the machine untouched, when `data` is not
  ///   `memoryImageSize` bytes.
  @discardableResult
  public func restoreMemoryImage(_ data: [UInt8]) -> Bool {
    machine.restoreMemoryImage(data)
  }
}

extension Machine {

  /// CRTC parameters X88000M programs for the PC-8001 screen after a memory
  /// image: DMA character mode with 80 bytes per row (0xCE), 20 rows (0x93),
  /// and the cursor, blanking and attribute settings that follow.
  static let memoryImageCRTCParameters: [UInt8] = [0xCE, 0x93, 0x73, 0x38, 0x13]

  /// `PC88.restoreMemoryImage(_:)`.
  package func restoreMemoryImage(_ data: [UInt8]) -> Bool {
    guard data.count == PC88.memoryImageSize else { return false }
    for (i, byte) in data.enumerated() {
      bus.memWrite(UInt16(0x8000 + i), value: byte)
    }
    for addr in 0xFF40...0xFFFF {
      bus.memWrite(UInt16(addr), value: 0x00)
    }
    // The copy above went through the bus, which charges wait states.
    bus.pendingWaitStates = 0

    // The screen, through the ports so every derived flag follows.
    bus.ioWrite(0x30, value: bus.port30w & ~0x01)  // 40 columns
    bus.ioWrite(0x31, value: bus.port31 & ~0x08)   // graphics display off
    bus.ioWrite(0x51, value: 0x00)                 // reset
    for parameter in Self.memoryImageCRTCParameters {
      bus.ioWrite(0x50, value: parameter)
    }
    bus.ioWrite(0x51, value: 0x43)                 // interrupt mask
    bus.ioWrite(0x51, value: 0x20)                 // start display

    cpu.hl = UInt16(data[0xEA63 - 0x8000]) | UInt16(data[0xEA64 - 0x8000]) << 8
    cpu.sp = UInt16(data[0xFF3E - 0x8000]) | UInt16(data[0xFF3F - 0x8000]) << 8
    cpu.pc = 0xFF3D
    cpu.im = 2
    return true
  }
}

/// Drives the load of a `.n80` memory image: wait for N-BASIC's prompt after
/// the reset, restore the image, then type `RUN` if the image needs it.
///
/// The host resets into N-BASIC, calls `start(image:)`, then calls
/// `tick(typingIdle:screen:)` once per frame and acts on what it returns:
/// `.restore` hands over the image for ``PC88/restoreMemoryImage(_:)``, `.type`
/// is text to type with ``TextPasteQueue``. Like ``TapeAutoBoot`` it reads the
/// machine only through `tick`'s arguments, so it can be tested without a ROM.
///
/// The prompt is waited for because the image holds RAM only: the DMA and the
/// interrupts are whatever the ROM set up, so it has to have got that far.
///
/// An image resumes through the `RET` at 0xFF3D, and where that returns to
/// decides what comes next (``needsRun(_:)``). Images taken at BASIC's prompt
/// return into the ROM's keyboard wait and need `RUN`; it is typed on the
/// frame after the restore, since the image resumes in that wait. Others
/// return straight into their program and start by themselves, and an image
/// taken at the machine-language monitor's `*` prompt waits for a monitor
/// command that only its documentation knows.
public final class MemoryImageBoot {

  /// Where the sequence is.
  public enum Phase: Equatable, Sendable {
    /// Not started, or cancelled.
    case idle
    /// Waiting for N-BASIC's `Ok` prompt after the reset.
    case waitingForPrompt
    /// The image has been handed over for restoring; `RUN` comes next if the
    /// image needs it.
    case restored
    /// `RUN` is being typed.
    case typingRun
    /// Done: the image is restored, and `RUN` typed if it needed it.
    case finished
    /// N-BASIC never reached its prompt; nothing was restored.
    case failed
  }

  /// What the host should do this frame.
  public enum Action: Equatable, Sendable {
    /// Restore this image with ``PC88/restoreMemoryImage(_:)``.
    case restore([UInt8])
    /// Type this text.
    case type(String)
  }

  /// Current phase.
  public private(set) var phase: Phase = .idle

  /// Whether the sequence is still running, so the host should keep ticking.
  public var isActive: Bool {
    switch phase {
    case .idle, .finished, .failed: return false
    default: return true
    }
  }

  /// Frames to wait for the prompt after the reset.
  static let promptTimeoutFrames = TapeAutoBoot.promptTimeoutFrames
  /// The screen is read this often, in frames.
  static let screenPollFrames = TapeAutoBoot.screenPollFrames

  private var frames = 0
  /// The image, held until it is handed over by `.restore`.
  private var image: [UInt8]?
  private var typesRun = false

  /// An idle sequencer.
  public init() {}

  /// Begin waiting for the prompt for `image`. Call right after the reset.
  public func start(image: [UInt8]) {
    phase = .waitingForPrompt
    frames = 0
    self.image = image
    typesRun = Self.needsRun(image)
  }

  /// Stop without doing anything further.
  public func cancel() {
    phase = .idle
    image = nil
  }

  /// Advance by one frame.
  ///
  /// - Parameters:
  ///   - typingIdle: Whether the paste queue has nothing left to type.
  ///   - screen: The text screen, as ``PC88/copyTextAsUnicode()`` returns it.
  ///     Only called when the sequencer needs to look.
  /// - Returns: What the host should do, or nil.
  public func tick(typingIdle: Bool, screen: () -> String) -> Action? {
    guard isActive else { return nil }
    frames += 1

    switch phase {
    case .waitingForPrompt:
      if frames > Self.promptTimeoutFrames {
        phase = .failed
        image = nil
        return nil
      }
      guard frames % Self.screenPollFrames == 0,
            TapeAutoBoot.promptIsOk(Self.lines(screen())),
            let image else { return nil }
      phase = .restored
      self.image = nil
      return .restore(image)

    case .restored:
      guard typesRun else {
        phase = .finished
        return nil
      }
      phase = .typingRun
      return .type("RUN\n")

    case .typingRun:
      if typingIdle { phase = .finished }
      return nil

    case .idle, .finished, .failed:
      return nil
    }
  }

  // MARK: - Reading the image

  /// Whether `image` was taken at BASIC's prompt, so its program still has to
  /// be started with `RUN`.
  ///
  /// The resume stub returns to the word at the image's SP. An address in RAM
  /// is the program itself: the image starts on its own. An address in the
  /// ROM is a keyboard wait, BASIC's or the monitor's; the monitor's leaves
  /// its `*` prompt as the last line on the image's screen.
  static func needsRun(_ image: [UInt8]) -> Bool {
    guard image.count == PC88.memoryImageSize else { return false }
    func word(_ addr: Int) -> Int? {
      let offset = addr - 0x8000
      guard offset >= 0, offset + 1 < image.count else { return nil }
      return Int(image[offset]) | Int(image[offset + 1]) << 8
    }
    guard let sp = word(0xFF3E), let resume = word(sp), resume < 0x8000 else { return false }
    return screenLines(of: image).last != "*"
  }

  /// The non-empty lines of the image's own screen, trimmed, without the
  /// function-key row: the 40×20 text VRAM at 0xF300 that
  /// ``PC88/restoreMemoryImage(_:)`` displays, 120 bytes a row with each
  /// character in the first byte of its pair.
  static func screenLines(of image: [UInt8]) -> [String] {
    let base = 0xF300 - 0x8000
    let rowBytes = 120
    return (0..<19).compactMap { row in
      let start = base + row * rowBytes
      let chars = stride(from: start, to: start + 80, by: 2).map { image[$0] }
      let text = String(bytes: chars.map { (0x21...0x7E).contains($0) ? $0 : 0x20 }, encoding: .ascii)!
        .trimmingCharacters(in: .whitespaces)
      return text.isEmpty ? nil : text
    }
  }

  // MARK: - Reading the screen

  /// The screen's non-empty lines, trimmed, without the bottom row.
  ///
  /// N-BASIC starts at 40×20 with its function-key labels on the bottom row,
  /// which ``TapeAutoBoot``'s reading drops only for a 25-row screen.
  static func lines(_ screen: String) -> [String] {
    var rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
    // `copyTextAsUnicode()` ends every row, the last included, with a newline.
    if rows.last?.isEmpty == true { rows.removeLast() }
    if !rows.isEmpty { rows.removeLast() }
    return rows
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
