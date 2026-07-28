// ScriptRecorder.swift — records live play into a [ScriptStep] timeline.
//
// The inverse of `ScriptPlayer`. The host (app layer) advances `frameIndex` each
// frame and feeds in the real user's key presses/releases and disk operations on
// canonical 60fps frames. `finish()` returns the setup plus the folded timeline,
// which `ScriptWriter` turns into text.
//
// Pure logic with no dependency on Machine: frame times come from the host via
// `frameIndex`.
//
// Tap folding: a down→up pair is folded into `key X tap hold`. ScriptPlayer's
// automatic tap release fires at frame `Fd+hold` during the following `wait`,
// landing on the same frame as an explicit `up@Fu`, so a tap is **exactly**
// equivalent to the down/up pair. Only presses at or below the threshold are
// folded; longer holds stay as explicit down/up.

public final class ScriptRecorder {

  /// Presses lasting at most this many frames are folded into a `tap`; longer
  /// holds stay as explicit down/up.
  public static let tapFoldThreshold = 8

  /// Recording clock, incremented by the host each frame. Starts at 0.
  public var frameIndex = 0

  private let setup: [ScriptStep]
  private var seqCounter = 0
  private var actions: [PointAction] = []

  // Start frame and ordering of held keys, used to pair down with up.
  private var downKeys: Set<Keyboard.Key> = []
  private var downFrame: [Keyboard.Key: Int] = [:]
  private var downSeq: [Keyboard.Key: Int] = [:]

  /// A point-in-time action: the frame, a sequence number for stable sorting,
  /// and the step itself.
  private struct PointAction {
    let frame: Int
    let seq: Int
    let step: ScriptStep
  }

  /// - Parameter setup: The boot/clock/disk header fixed when recording started.
  public init(setup: [ScriptStep]) {
    self.setup = setup
  }

  // MARK: - Event intake (called by host on the main thread)

  /// A real key press. OS auto-repeat — the same key already held — is ignored.
  public func keyDown(_ key: Keyboard.Key) {
    guard !downKeys.contains(key) else { return }
    downKeys.insert(key)
    downFrame[key] = frameIndex
    downSeq[key] = nextSeq()
  }

  /// A real key release. Keys that are not held are ignored.
  public func keyUp(_ key: Keyboard.Key) {
    guard downKeys.contains(key) else { return }
    downKeys.remove(key)
    let fd = downFrame.removeValue(forKey: key) ?? frameIndex
    let sd = downSeq.removeValue(forKey: key) ?? nextSeq()
    emitInterval(key: key, fd: fd, fu: frameIndex, sd: sd)
  }

  public func diskSwap(drive: Int, path: String, image: Int) {
    append(.diskSwap(drive: drive, path: path, image: image))
  }

  public func diskSelect(drive: Int, image: Int) {
    append(.diskSelect(drive: drive, image: image))
  }

  public func diskEject(drive: Int) {
    append(.diskEject(drive: drive))
  }

  // MARK: - Finalize

  /// Returns the setup plus the folded timeline. Any keys still held are closed
  /// out on the current frame.
  public func finish() -> [ScriptStep] {
    for key in downKeys {
      let fd = downFrame[key] ?? frameIndex
      let sd = downSeq[key] ?? nextSeq()
      emitInterval(key: key, fd: fd, fu: frameIndex, sd: sd)
    }
    downKeys.removeAll()
    downFrame.removeAll()
    downSeq.removeAll()

    let sorted = actions.sorted {
      $0.frame != $1.frame ? $0.frame < $1.frame : $0.seq < $1.seq
    }
    var timeline: [ScriptStep] = []
    var cursor = 0
    for action in sorted {
      if action.frame > cursor {
        timeline.append(.wait(frames: action.frame - cursor))
        cursor = action.frame
      }
      timeline.append(action.step)
    }
    return setup + timeline
  }

  // MARK: - Internals

  private func emitInterval(key: Keyboard.Key, fd: Int, fu: Int, sd: Int) {
    let span = fu - fd
    if span <= Self.tapFoldThreshold {
      // Fold to a tap even for a same-frame release (span 0). The parser
      // requires hold >= 1, so round up.
      actions.append(PointAction(frame: fd, seq: sd, step: .key(key, .tap(hold: max(1, span)))))
    } else {
      actions.append(PointAction(frame: fd, seq: sd, step: .key(key, .down)))
      actions.append(PointAction(frame: fu, seq: nextSeq(), step: .key(key, .up)))
    }
  }

  private func append(_ step: ScriptStep) {
    actions.append(PointAction(frame: frameIndex, seq: nextSeq(), step: step))
  }

  private func nextSeq() -> Int {
    seqCounter += 1
    return seqCounter
  }
}
