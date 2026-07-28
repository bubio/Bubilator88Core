import Testing
@testable import EmulatorCore

@Suite("Script Parser Tests")
struct ScriptParserTests {

  // MARK: - 基本

  @Test func emptyAndComments() throws {
    let steps = try ScriptParser.parse("""
    # コメントのみ
       # インデント付きコメント

    wait 1   # 行末コメント
    """)
    #expect(steps == [.wait(frames: 1)])
  }

  @Test func unknownVerbThrows() {
    #expect(throws: ScriptError(line: 1, message: "未知の動詞: frobnicate")) {
      try ScriptParser.parse("frobnicate 3")
    }
  }

  @Test func errorReportsCorrectLine() {
    #expect(throws: ScriptError.self) {
      do {
        _ = try ScriptParser.parse("wait 10\nwait 20\nbogus")
      } catch let e as ScriptError {
        #expect(e.line == 3)
        throw e
      }
    }
  }

  // MARK: - wait / duration

  @Test func waitFrames() throws {
    #expect(try ScriptParser.parse("wait 90") == [.wait(frames: 90)])
    #expect(try ScriptParser.parse("wait 90f") == [.wait(frames: 90)])
  }

  @Test func waitSecondsToFrames() throws {
    #expect(try ScriptParser.parse("wait 1s") == [.wait(frames: 60)])
    #expect(try ScriptParser.parse("wait 1.5s") == [.wait(frames: 90)])
    #expect(try ScriptParser.parse("wait 0.5s") == [.wait(frames: 30)])
  }

  @Test func waitCaseInsensitiveAndZero() throws {
    #expect(try ScriptParser.parse("WAIT 0") == [.wait(frames: 0)])
    #expect(try ScriptParser.parse("wait 2S") == [.wait(frames: 120)])
  }

  @Test func waitBadArgsThrow() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("wait") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("wait 10 20") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("wait -5") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("wait abc") }
  }

  // MARK: - key

  @Test func keyDownUp() throws {
    let ret = Keyboard.Key(1, 7)
    #expect(try ScriptParser.parse("key RETURN down") == [.key(ret, .down)])
    #expect(try ScriptParser.parse("key return up") == [.key(ret, .up)])
  }

  @Test func keyTapDefaultAndExplicitHold() throws {
    let sp = Keyboard.Key(9, 6)
    #expect(try ScriptParser.parse("key SPACE tap") == [.key(sp, .tap(hold: 2))])
    #expect(try ScriptParser.parse("key space tap 5") == [.key(sp, .tap(hold: 5))])
  }

  @Test func keyNamesResolveToMatrix() throws {
    #expect(try ScriptParser.parse("key A tap") == [.key(Keyboard.Key(2, 1), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key z tap") == [.key(Keyboard.Key(5, 2), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key 0 tap") == [.key(Keyboard.Key(6, 0), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key 9 tap") == [.key(Keyboard.Key(7, 1), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key f1 tap") == [.key(Keyboard.Key(9, 1), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key f10 tap") == [.key(Keyboard.Key(12, 4), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key kp0 tap") == [.key(Keyboard.Key(0, 0), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key shift down") == [.key(Keyboard.Key(8, 6), .down)])
  }

  @Test func keyRowBitNotation() throws {
    #expect(try ScriptParser.parse("key 2-1 tap") == [.key(Keyboard.Key(2, 1), .tap(hold: 2))])
    #expect(try ScriptParser.parse("key 0x0a-3 tap") == [.key(Keyboard.Key(10, 3), .tap(hold: 2))])
  }

  @Test func keyBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key RETURN") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key NOPE tap") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key RETURN sideways") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key RETURN tap five") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("key RETURN tap 0") }   // §6: hold は 1 以上
  }

  // MARK: - disk

  @Test func diskMountDefaultImage() throws {
    #expect(try ScriptParser.parse(#"disk 0 "Ys.d88""#)
      == [.diskMount(drive: 0, path: "Ys.d88", image: 0)])
  }

  @Test func diskMountWithImageAndSpaces() throws {
    #expect(try ScriptParser.parse(#"disk 1 "My Game.d88" image 2"#)
      == [.diskMount(drive: 1, path: "My Game.d88", image: 2)])
  }

  @Test func diskMountBareWord() throws {
    #expect(try ScriptParser.parse("disk 0 game.d88")
      == [.diskMount(drive: 0, path: "game.d88", image: 0)])
  }

  @Test func diskSwapSelectEject() throws {
    #expect(try ScriptParser.parse(#"disk swap 0 "B.d88""#)
      == [.diskSwap(drive: 0, path: "B.d88", image: 0)])
    #expect(try ScriptParser.parse(#"disk swap 1 "B.d88" image 3"#)
      == [.diskSwap(drive: 1, path: "B.d88", image: 3)])
    #expect(try ScriptParser.parse("disk select 0 1")
      == [.diskSelect(drive: 0, image: 1)])
    #expect(try ScriptParser.parse("disk eject 1")
      == [.diskEject(drive: 1)])
  }

  @Test func diskBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("disk") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("disk 2 x.d88") }       // 不正ドライブ
    #expect(throws: ScriptError.self) { try ScriptParser.parse("disk 0 x.d88 imag 1") } // typo
    #expect(throws: ScriptError.self) { try ScriptParser.parse("disk select 0") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse(#"disk 0 """#) }         // 空パス
  }

  // MARK: - reset

  @Test func resetModes() throws {
    #expect(try ScriptParser.parse("reset") == [.reset(preserveRAM: false)])
    #expect(try ScriptParser.parse("reset cold") == [.reset(preserveRAM: false)])
    #expect(try ScriptParser.parse("reset warm") == [.reset(preserveRAM: true)])
  }

  @Test func resetBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("reset hot") }
  }

  // MARK: - setup directives

  @Test func bootModes() throws {
    #expect(try ScriptParser.parse("boot N88-V2") == [.boot(.n88v2)])
    #expect(try ScriptParser.parse("bootmode n88-v1h") == [.boot(.n88v1h)])
    #expect(try ScriptParser.parse("boot N88-V1S") == [.boot(.n88v1s)])
    #expect(try ScriptParser.parse("boot N-BASIC") == [.boot(.nbasic)])
  }

  @Test func bootModeDipSwExpansion() {
    #expect(BootMode.n88v2.dipSw1 == 0xC3); #expect(BootMode.n88v2.dipSw2 == 0x71)
    #expect(BootMode.n88v1h.dipSw2 == 0xF1)
    #expect(BootMode.n88v1s.dipSw2 == 0xB1)
    #expect(BootMode.nbasic.dipSw1 == 0xC2)
  }

  @Test func bootBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("boot N99") }
  }

  @Test func clockModes() throws {
    #expect(try ScriptParser.parse("clock 4") == [.clock(mhz: 4)])
    #expect(try ScriptParser.parse("clock 8") == [.clock(mhz: 8)])
  }

  @Test func clockBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("clock 6") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("clock") }
  }

  @Test func dipsw() throws {
    #expect(try ScriptParser.parse("dipsw1 0xC3") == [.dipsw1(0xC3)])
    #expect(try ScriptParser.parse("dipsw2 113") == [.dipsw2(113)])   // 0x71
  }

  @Test func dipswBadThrows() {
    #expect(throws: ScriptError.self) { try ScriptParser.parse("dipsw1 0x1FF") }
    #expect(throws: ScriptError.self) { try ScriptParser.parse("dipsw1") }
  }

  // MARK: - 統合

  @Test func fullScript() throws {
    let steps = try ScriptParser.parse("""
    # Ys を起動して Disk B へ
    boot   N88-V2
    clock  8
    disk   0 "Ys.d88" image 0

    wait 90
    key  RETURN tap
    wait 1.5s
    disk select 0 1
    wait 5s
    reset warm
    """)
    #expect(steps == [
      .boot(.n88v2),
      .clock(mhz: 8),
      .diskMount(drive: 0, path: "Ys.d88", image: 0),
      .wait(frames: 90),
      .key(Keyboard.Key(1, 7), .tap(hold: 2)),
      .wait(frames: 90),
      .diskSelect(drive: 0, image: 1),
      .wait(frames: 300),
      .reset(preserveRAM: true),
    ])
  }
}
