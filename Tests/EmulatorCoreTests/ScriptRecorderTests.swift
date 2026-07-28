import Testing
@testable import EmulatorCore

@Suite("Script Recorder Tests")
struct ScriptRecorderTests {

  private let z = Keyboard.z
  private let a = Keyboard.a
  private let b = Keyboard.b

  /// frameIndex を進めながらイベントを投入するヘルパ。
  private func rec(setup: [ScriptStep] = []) -> ScriptRecorder { ScriptRecorder(setup: setup) }

  @Test func shortPressFoldsToTap() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z)
    r.frameIndex = 3; r.keyUp(z)
    r.frameIndex = 3
    #expect(r.finish() == [.key(z, .tap(hold: 3))])
  }

  @Test func sameFramePressFoldsToTapHold1() {
    let r = rec()
    r.frameIndex = 5; r.keyDown(z); r.keyUp(z)
    r.frameIndex = 5
    // 先頭に wait 5 が入り、tap hold は 1 に丸め
    #expect(r.finish() == [.wait(frames: 5), .key(z, .tap(hold: 1))])
  }

  @Test func longHoldStaysExplicitDownUp() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z)
    r.frameIndex = 20; r.keyUp(z)
    r.frameIndex = 20
    #expect(r.finish() == [.key(z, .down), .wait(frames: 20), .key(z, .up)])
  }

  @Test func autoRepeatDownIsIgnored() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z)
    r.frameIndex = 1; r.keyDown(z)   // OS オートリピート → 無視
    r.frameIndex = 2; r.keyDown(z)   // 同上
    r.frameIndex = 4; r.keyUp(z)
    r.frameIndex = 4
    // 区間は 0→4 の 1 本だけ (tap 4)
    #expect(r.finish() == [.key(z, .tap(hold: 4))])
  }

  @Test func strayKeyUpIsIgnored() {
    let r = rec()
    r.frameIndex = 0; r.keyUp(z)      // 押していないキーの up → 無視
    r.frameIndex = 5; r.keyDown(z); r.keyUp(z)
    r.frameIndex = 5
    #expect(r.finish() == [.wait(frames: 5), .key(z, .tap(hold: 1))])
  }

  @Test func heldKeyAtFinishIsClosed() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z)
    r.frameIndex = 30                 // up せずに finish
    #expect(r.finish() == [.key(z, .down), .wait(frames: 30), .key(z, .up)])
  }

  @Test func twoQuickTapsKeepGapNoFloor() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z)
    r.frameIndex = 2; r.keyUp(z)
    r.frameIndex = 4; r.keyDown(z)
    r.frameIndex = 6; r.keyUp(z)
    r.frameIndex = 6
    // 2 連 tap。実際の gap(4)をそのまま保持 (人工 floor は入れない)
    #expect(r.finish() == [.key(z, .tap(hold: 2)), .wait(frames: 4), .key(z, .tap(hold: 2))])
  }

  @Test func interleavedKeysSortedByFrame() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(a)
    r.frameIndex = 2; r.keyDown(b)
    r.frameIndex = 3; r.keyUp(a)      // A 区間 0..3 (tap 3)
    r.frameIndex = 5; r.keyUp(b)      // B 区間 2..5 (tap 3)
    r.frameIndex = 5
    #expect(r.finish() == [
      .key(a, .tap(hold: 3)),
      .wait(frames: 2),
      .key(b, .tap(hold: 3)),
    ])
  }

  @Test func diskEventsInterleaveWithWaits() {
    let r = rec()
    r.frameIndex = 0; r.keyDown(z); r.frameIndex = 2; r.keyUp(z)   // tap hold 2 → "tap"
    r.frameIndex = 60; r.diskSwap(drive: 1, path: "/x.d88", image: 3)
    r.frameIndex = 90; r.diskSelect(drive: 1, image: 0)
    r.frameIndex = 90
    #expect(r.finish() == [
      .key(z, .tap(hold: 2)),
      .wait(frames: 60),
      .diskSwap(drive: 1, path: "/x.d88", image: 3),
      .wait(frames: 30),
      .diskSelect(drive: 1, image: 0),
    ])
  }

  @Test func setupHeaderPrepended() {
    let setup: [ScriptStep] = [
      .boot(.n88v2), .clock(mhz: 4),
      .diskMount(drive: 0, path: "/g.d88", image: 0),
    ]
    let r = rec(setup: setup)
    r.frameIndex = 300; r.keyDown(Keyboard.space); r.frameIndex = 302; r.keyUp(Keyboard.space)
    r.frameIndex = 302
    #expect(r.finish() == setup + [
      .wait(frames: 300),
      .key(Keyboard.space, .tap(hold: 2)),
    ])
  }

  /// 記録 → ScriptWriter → ScriptParser の通し (記録↔再生の対称性)。
  @Test func recordThenWriteThenParseRoundTrips() throws {
    let setup: [ScriptStep] = [.boot(.n88v2), .clock(mhz: 4),
                               .diskMount(drive: 0, path: "/sorpack.d88", image: 0)]
    let r = rec(setup: setup)
    r.frameIndex = 120; r.keyDown(Keyboard.space); r.frameIndex = 122; r.keyUp(Keyboard.space)
    r.frameIndex = 200; r.keyDown(z); r.frameIndex = 260; r.keyUp(z)   // 長押し
    r.frameIndex = 260
    let steps = r.finish()
    let text = ScriptWriter.write(steps)
    #expect(try ScriptParser.parse(text) == steps)
  }
}
