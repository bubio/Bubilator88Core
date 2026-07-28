// ScriptRecorder.swift — 実プレイ操作を [ScriptStep] タイムラインへ記録する。
//
// `ScriptPlayer` の逆。ホスト (App 層) が毎フレーム `frameIndex` を進め、実ユーザの
// キー押下/解放・ディスク操作を 60fps 正準フレームで投入する。`finish()` が
// セットアップ + 畳み込み済みタイムラインを返し、`ScriptWriter` がテキスト化する。
//
// 純粋ロジック (Machine 非依存): フレーム時刻はホストが `frameIndex` で与える。
//
// tap 畳み込み: down→up を `key X tap hold` に畳む。ScriptPlayer の tap 自動リリースは
// 後続 `wait` 中に `Fd+hold` フレームで発火し、明示 `up@Fu` と同一フレームになるため、
// tap は down/up と**厳密に等価**。閾値以下の短押しのみ tap にし、長押しは明示 down/up。

public final class ScriptRecorder {

  /// この値以下 (フレーム) の押下は `tap` に畳む。超える長押しは明示 down/up。
  public static let tapFoldThreshold = 8

  /// ホストが毎フレーム +1 する記録クロック (記録開始 = 0)。
  public var frameIndex = 0

  private let setup: [ScriptStep]
  private var seqCounter = 0
  private var actions: [PointAction] = []

  // 押下中キーの開始フレーム/順序 (down→up 区間のペアリング用)。
  private var downKeys: Set<Keyboard.Key> = []
  private var downFrame: [Keyboard.Key: Int] = [:]
  private var downSeq: [Keyboard.Key: Int] = [:]

  /// 1 時点アクション (フレーム + 安定ソート用 seq + ステップ)。
  private struct PointAction {
    let frame: Int
    let seq: Int
    let step: ScriptStep
  }

  /// - Parameter setup: 記録開始時に確定した boot/clock/disk ヘッダ。
  public init(setup: [ScriptStep]) {
    self.setup = setup
  }

  // MARK: - Event intake (called by host on the main thread)

  /// 実ユーザのキー押下。OS のオートリピート (既に押下中の同キー) は無視する。
  public func keyDown(_ key: Keyboard.Key) {
    guard !downKeys.contains(key) else { return }
    downKeys.insert(key)
    downFrame[key] = frameIndex
    downSeq[key] = nextSeq()
  }

  /// 実ユーザのキー解放。押下していないキーは無視する。
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

  /// セットアップ + 畳み込み済みタイムラインを返す。押下中キーは現フレームで閉じる。
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
      // 同フレーム解放 (span 0) も含め tap。hold は 1 以上に丸める (パーサ要件)。
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
