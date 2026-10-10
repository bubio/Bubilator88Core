#if canImport(Foundation)
import Foundation
#endif

/// Drives the `LOAD "CAS:"` / `RUN` routine for a mounted cassette.
///
/// The host resets into N88-BASIC with the tape mounted, calls `start()`, then
/// calls `tick(motorRunning:typingIdle:screen:)` once per frame. Whenever
/// `tick` returns text, the host types it with ``TextPasteQueue``.
///
/// The sequencer reads the machine only through `tick`'s arguments, so it can
/// be tested without a ROM:
///
/// 1. Wait for the `Ok` prompt, answering a `How many files` prompt with
///    Return on the way.
/// 2. Type `LOAD "CAS:"`.
/// 3. Wait for the motor to turn, then to stay off with `Ok` back on screen.
///    BASIC switches the motor off when a file ends, so that is the only
///    host-visible end of a load; the tape position never reaches the end.
/// 4. Type `RUN`.
public final class TapeAutoBoot {

  /// Where the sequence is.
  public enum Phase: Equatable, Sendable {
    /// Not started, or cancelled.
    case idle
    /// Waiting for BASIC's `Ok` prompt after the reset.
    case waitingForPrompt
    /// `LOAD "CAS:"` is being typed.
    case typingLoad
    /// Typed; waiting for the motor to start.
    case waitingForMotor
    /// The tape is loading; waiting for the motor to stop and `Ok` to return.
    case loading
    /// `RUN` is being typed.
    case typingRun
    /// `RUN` has been typed.
    case finished
    /// Stopped without sending `RUN`.
    case failed(Failure)
  }

  /// Why the sequence stopped without sending `RUN`.
  public enum Failure: Equatable, Sendable {
    /// BASIC never reached the prompt.
    case promptTimeout
    /// The motor never started after `LOAD "CAS:"`.
    case motorTimeout
    /// The load never finished.
    case loadTimeout
    /// The whole tape was read and BASIC never got back to `Ok`, as when
    /// `LOAD "CAS:"` searches a machine-language tape for a BASIC file that
    /// is not there.
    case tapeEnded
    /// BASIC reported an error.
    case basicError
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
  static let promptTimeoutFrames = 1200
  /// Frames to wait for the motor after `LOAD "CAS:"` is typed.
  static let motorTimeoutFrames = 600
  /// Frames to wait for a load to finish.
  static let loadTimeoutFrames = 36000
  /// Frames BASIC gets, after the tape has been read to its end, to get back
  /// to `Ok` before the load is given up.
  static let tapeEndedFrames = 120
  /// Frames the motor must stay off, after running, to count as finished. It
  /// must be longer than any pause BASIC leaves between a header block and its
  /// body.
  static let motorOffFrames = 45
  /// The screen is read this often, in frames. Reading it costs an 80x25 pass.
  static let screenPollFrames = 6

  private var frames = 0
  private var motorSeen = false
  private var motorOffCount = 0
  private var atTapeEndCount = 0
  private var answeredFileCount = false

  /// An idle sequencer.
  public init() {}

  /// Begin waiting for the prompt. Call right after the reset.
  public func start() {
    phase = .waitingForPrompt
    frames = 0
    motorSeen = false
    motorOffCount = 0
    atTapeEndCount = 0
    answeredFileCount = false
  }

  /// Stop without sending anything further.
  public func cancel() {
    phase = .idle
  }

  /// Advance by one frame.
  ///
  /// - Parameters:
  ///   - motorRunning: ``PC88/isTapeMotorRunning``.
  ///   - tapeProgress: ``PC88/tapeProgress``.
  ///   - typingIdle: Whether the paste queue has nothing left to type.
  ///   - screen: The text screen, as ``PC88/copyTextAsUnicode()`` returns it.
  ///     Only called when the sequencer needs to look.
  /// - Returns: Text for the host to type, or nil.
  public func tick(
    motorRunning: Bool, tapeProgress: Double, typingIdle: Bool, screen: () -> String
  ) -> String? {
    guard isActive else { return nil }
    frames += 1

    switch phase {
    case .waitingForPrompt:
      guard typingIdle else { return nil }
      if frames > Self.promptTimeoutFrames {
        phase = .failed(.promptTimeout)
        return nil
      }
      guard frames % Self.screenPollFrames == 0 else { return nil }
      let lines = Self.lines(screen())
      if !answeredFileCount, lines.contains(where: { $0.hasPrefix("How many files") }) {
        answeredFileCount = true
        return "\n"
      }
      if Self.promptIsOk(lines) {
        phase = .typingLoad
        frames = 0
        return "LOAD \"CAS:\"\n"
      }
      return nil

    case .typingLoad:
      if typingIdle {
        phase = .waitingForMotor
        frames = 0
      }
      return nil

    case .waitingForMotor:
      if motorRunning {
        phase = .loading
        frames = 0
        motorSeen = true
        motorOffCount = 0
      } else if frames > Self.motorTimeoutFrames {
        phase = .failed(.motorTimeout)
      } else if frames % Self.screenPollFrames == 0,
                Self.lastLineIsError(Self.lines(screen())) {
        phase = .failed(.basicError)
      }
      return nil

    case .loading:
      if motorRunning {
        motorOffCount = 0
      } else {
        motorOffCount += 1
      }
      atTapeEndCount = tapeProgress >= 1 ? atTapeEndCount + 1 : 0
      if atTapeEndCount > Self.tapeEndedFrames {
        phase = .failed(.tapeEnded)
        return nil
      }
      if frames > Self.loadTimeoutFrames {
        phase = .failed(.loadTimeout)
        return nil
      }
      guard motorSeen, motorOffCount >= Self.motorOffFrames,
            frames % Self.screenPollFrames == 0 else { return nil }
      let lines = Self.lines(screen())
      if Self.lastLineIsError(lines) {
        phase = .failed(.basicError)
        return nil
      }
      if Self.promptIsOk(lines) {
        phase = .typingRun
        return "RUN\n"
      }
      return nil

    case .typingRun:
      if typingIdle { phase = .finished }
      return nil

    case .idle, .finished, .failed:
      return nil
    }
  }

  // MARK: - Screen reading

  /// The screen's non-empty lines, trimmed, without the bottom row.
  ///
  /// The bottom row of a 25-row screen holds BASIC's function-key labels, which
  /// would otherwise always be the last thing on screen.
  static func lines(_ screen: String) -> [String] {
    var rows = screen.split(separator: "\n", omittingEmptySubsequences: false)
    // `copyTextAsUnicode()` ends every row, the last included, with a newline.
    if rows.last?.isEmpty == true { rows.removeLast() }
    if rows.count >= 25 { rows.removeLast() }
    return rows
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Whether BASIC is sitting at its prompt: `Ok` is the last thing printed.
  static func promptIsOk(_ lines: [String]) -> Bool {
    guard let last = lines.last else { return false }
    return last == "Ok" || last == "Ok."
  }

  /// Whether the last thing printed is a BASIC error message.
  static func lastLineIsError(_ lines: [String]) -> Bool {
    guard let last = lines.last?.lowercased() else { return false }
    return last.contains("error") || last.contains("bad file name")
  }
}
