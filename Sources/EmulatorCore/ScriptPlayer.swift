// ScriptPlayer.swift — [ScriptStep] を Machine 上で再生する。
//
// docs/SCRIPTING.md の drive モード (スクリプトが時計を所有) に相当。
// ファイルシステムには触れず、ディスクパス → バイト列の解決は呼び出し側が
// 渡す `FileLoader` クロージャに委ねる (純粋・テスト容易・サンドボックス対応)。

import Foundation

public final class ScriptPlayer {

  /// ディスクパス文字列を D88 のバイト列へ解決するクロージャ。
  public typealias FileLoader = (_ path: String) throws -> [UInt8]

  /// 再生時エラー (ディスク読み込み失敗・範囲外イメージ等)。
  public struct RuntimeError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
  }

  private let machine: Machine
  private let loader: FileLoader

  /// ドライブごとにマウント済みファイルの全イメージを保持 (disk select 用)。
  private var loadedImages: [[D88Disk]] = [[], []]

  /// ドライブごとに、現在マウント中のディスクパスと選択イメージ番号を保持。
  /// App 層が再生後に `MountedDiskInfo` を再構築し、手動マウントと同じ
  /// イメージ選択 UI を提供するために `driveMount(_:)` 経由で公開する。
  private var mountedPaths: [String?] = [nil, nil]
  private var mountedIndexes: [Int] = [0, 0]

  /// 1 ドライブにマウント済みの素性スナップショット。
  /// `path` はスクリプトが指定したディスクパス (未解決), `images` はその
  /// D88 の全イメージ (disk select 候補), `imageIndex` は現在の選択番号。
  public struct DriveMount {
    public let path: String
    public let images: [D88Disk]
    public let imageIndex: Int
  }

  /// 指定ドライブの現在のマウント素性。未マウント/eject 済みは nil。
  public func driveMount(_ drive: Int) -> DriveMount? {
    guard drive >= 0, drive < mountedPaths.count,
          let path = mountedPaths[drive], !loadedImages[drive].isEmpty else { return nil }
    return DriveMount(path: path, images: loadedImages[drive],
                      imageIndex: mountedIndexes[drive])
  }

  /// tap の自動リリース予約。残りフレーム数。
  private var pendingReleases: [Keyboard.Key: Int] = [:]

  /// 明示 `down` で押したまま (自動リリース対象外) のキー。
  /// live 再生の中断時にマトリクスへ取り残さないため追跡する。
  private var heldDownKeys: Set<Keyboard.Key> = []

  /// setup → timeline 遷移時の確定処理を済ませたか (reset で再武装)。
  private var setupFinalized = false

  /// `boot` で設定したときのみ ROM/ディスク起動 (DIPSW2 bit3) を自動解決する。
  /// `dipsw2` を生値で指定したらユーザに従い自動解決しない。
  private var resolveDiskBoot = true

  /// `clock` で明示されたクロック。`Machine.reset()` は clock8MHz を true に
  /// 戻すため、reset 後に再適用してスクリプトの意図を保つ (nil = 未指定)。
  private var desiredClock8MHz: Bool?

  public init(machine: Machine, loader: @escaping FileLoader) {
    self.machine = machine
    self.loader = loader
  }

  /// スクリプト全体を再生する (drive モード: Player が時計を所有)。
  public func run(_ steps: [ScriptStep]) throws {
    for step in steps {
      try execute(step)
    }
    finish()
  }

  // MARK: - Live driver (ホストが runFrame を所有)

  /// docs/SCRIPTING.md の live モード。アプリの自走 60Hz ループに乗せる用途。
  /// `run()` と異なり Player は `runFrame` を呼ばない — ホストが毎フレーム
  /// `machine.runFrame()` を回し、その直前に `liveTick()` を 1 回呼ぶ。
  private var liveSteps: [ScriptStep] = []
  private var liveCursor = 0
  private var liveWaitRemaining = 0
  private var liveActive = false

  /// live 再生中か。
  public var isLivePlaying: Bool { liveActive }

  /// live 再生を開始する。セットアップ (boot/clock/dipsw/disk) を適用し、
  /// 最初の `wait` (>0) までカーソルを進める。呼び出し側は事前に
  /// `machine.reset()` 済みであることを想定 (drive モードの BootTester と同じ)。
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

  /// 毎フレーム、ホストの `machine.runFrame()` の **直前** に 1 回呼ぶ
  /// (App の `tickPasteQueue()` と同じ位置)。
  /// due な tap リリースを発火し、現在の `wait` を 1 フレーム消費し、
  /// `wait` が尽きたら次の即時ステップ群 (key/disk 等) を適用する。
  /// スクリプトを完全に消費し未解放キーも無くなったら `false` を返す。
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

  /// live 再生を中断し、押下中の全キー (tap 予約 + 明示 down) を解放する。
  public func cancelLive() {
    guard liveActive else { return }
    finish()                                  // tap 予約を解放
    for key in heldDownKeys {                 // 明示 down も取りこぼさない
      machine.keyboard.releaseKey(row: key.row, bit: key.bit)
    }
    heldDownKeys.removeAll()
    liveActive = false
    liveSteps = []
    liveCursor = 0
    liveWaitRemaining = 0
  }

  /// カーソルを次の `wait` (>0) または終端まで進め、その間の即時ステップを適用する。
  /// 最初の時間進行の直前に bit3 を確定する (drive モードの `advance` と同義)。
  private func liveAdvanceCursor() throws {
    while liveCursor < liveSteps.count {
      let step = liveSteps[liveCursor]
      if case .wait(let frames) = step {
        liveCursor += 1
        if frames > 0 {
          finalizeSetupIfNeeded()      // 起動確定はディスク mount 後・最初の時間進行で
          liveWaitRemaining = frames
          return
        }
        continue                          // wait 0 は時間を進めない
      }
      try execute(step)
      liveCursor += 1
    }
    finalizeSetupIfNeeded()                   // 末尾 wait 無しでも起動確定はしておく
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
      // 初期セットアップ (コールドマウント): 交換ディレイを使わず即時マウントする。
      // Machine を再利用する live 再生では reset 後もドライブにディスクが残るため
      // (subSystem.reset は drives を保持)、eject せず mountDisk すると交換ディレイ
      // 経路に入り drive0 が一時 nil → applyBootStrap が ROM 起動へ誤判定する。
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
      // reset は clock8MHz を true に戻し、キーマトリクスを全解放する。
      // スクリプトで明示したクロックは再適用して意図を保つ
      // (dipSw1/2 は reset で保持される)。
      if let c = desiredClock8MHz { machine.clock8MHz = c }
      pendingReleases.removeAll()
      heldDownKeys.removeAll()        // reset でマトリクスは全解放される
      setupFinalized = false          // 次の advance 前に bit3 を再確定
    }
  }

  // MARK: - Time advancement

  func advance(_ frames: Int) {           // internal: タイミングのユニットテスト用
    guard frames > 0 else { return }    // wait 0 は時間も起動確定も進めない
    finalizeSetupIfNeeded()
    for _ in 0..<frames {
      machine.runFrame()
      tickPendingReleases()
    }
  }

  /// 各フレーム後に呼び、予約された tap リリースを発火する。
  private func tickPendingReleases() {
    guard !pendingReleases.isEmpty else { return }
    // キーのスナップショットを反復し、辞書本体は中身だけ更新する。
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

  /// 最初の時間進行 (および reset 後) の一度だけ、ROM/ディスク起動を確定する。
  private func finalizeSetupIfNeeded() {
    guard !setupFinalized else { return }
    setupFinalized = true
    if resolveDiskBoot {
      // ドライブ 0 の占有状態から起動ストラップ (bit3) を確定 (Machine 共有ヘルパ)。
      machine.applyBootStrap()
    }
  }

  // MARK: - Keyboard

  func applyKey(_ key: Keyboard.Key, _ action: KeyAction) {   // internal: タイミングのユニットテスト用
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
      // 保持中の同キーは先に解放してから押し直す (pressKey で上書き)。
      // §6 の「必ず 1 フレーム以上保持」保証のため hold は 1 未満を 1 に丸める。
      machine.keyboard.pressKey(row: key.row, bit: key.bit)
      pendingReleases[key] = max(1, hold)
      heldDownKeys.remove(key)          // 自動リリース管理に委ねる
    }
  }

  // MARK: - Disk

  /// - Parameter immediate: `true` ならマウント前に eject して交換ディレイ
  ///   (ドアが開いている ~100ms 窓) を回避し、即座にディスクを実装する。
  ///   コールドブートのセットアップ (`disk` コマンド) 用。`disk swap` は `false`。
  private func mountFile(drive: Int, path: String, image: Int, immediate: Bool = false) throws {
    let data = try loader(path)
    let disks = D88Disk.parseAll(data: data)
    guard !disks.isEmpty else {
      throw RuntimeError("D88 として解釈できません: \(path)")
    }
    guard image >= 0 && image < disks.count else {
      throw RuntimeError("イメージ番号 \(image) が範囲外 (\(path) は \(disks.count) 面)")
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
      throw RuntimeError("ドライブ \(drive) にマウント済みファイルがありません (disk select)")
    }
    guard image >= 0 && image < disks.count else {
      throw RuntimeError("イメージ番号 \(image) が範囲外 (ドライブ \(drive) は \(disks.count) 面)")
    }
    machine.mountDisk(drive: drive, disk: disks[image])
    mountedIndexes[drive] = image
  }

  // MARK: - Finish

  /// 再生終了時、未リリースの tap 予約を解放する。
  private func finish() {
    for key in pendingReleases.keys {
      machine.keyboard.releaseKey(row: key.row, bit: key.bit)
    }
    pendingReleases.removeAll()
  }
}
