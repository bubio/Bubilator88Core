import Testing
@testable import Bubilator88Core

@Suite("TapeAutoBoot Tests")
struct TapeAutoBootTests {

  /// Run ticks with fixed machine state, returning every string typed.
  private func run(
    _ boot: TapeAutoBoot, frames: Int, motor: Bool = false, typingIdle: Bool = true,
    screen: String
  ) -> [String] {
    var typed: [String] = []
    for _ in 0..<frames {
      if let text = boot.tick(motorRunning: motor, typingIdle: typingIdle, screen: { screen }) {
        typed.append(text)
      }
    }
    return typed
  }

  @Test func idleDoesNothing() {
    let boot = TapeAutoBoot()
    #expect(run(boot, frames: 100, screen: "Ok").isEmpty)
    #expect(!boot.isActive)
  }

  @Test func typesLoadAtThePrompt() {
    let boot = TapeAutoBoot()
    boot.start()
    var typed: String?
    for _ in 0..<60 where typed == nil {
      typed = boot.tick(motorRunning: false, typingIdle: true, screen: { "NEC PC-8801\nOk" })
    }
    #expect(typed == "LOAD \"CAS:\"\n")
    #expect(boot.phase == .typingLoad)
  }

  @Test func ignoresTheFunctionKeyRow() {
    var rows = [String](repeating: "", count: 25)
    rows[3] = "Ok"
    rows[24] = "load \"  auto  go to  list  run"
    let boot = TapeAutoBoot()
    boot.start()
    #expect(run(boot, frames: 12, screen: rows.joined(separator: "\n") + "\n") == ["LOAD \"CAS:\"\n"])
  }

  @Test func waitsWhileTheScreenHasNoPrompt() {
    let boot = TapeAutoBoot()
    boot.start()
    #expect(run(boot, frames: 200, screen: "Starting").isEmpty)
    #expect(boot.phase == .waitingForPrompt)
  }

  @Test func answersTheFileCountPromptOnce() {
    let boot = TapeAutoBoot()
    boot.start()
    #expect(run(boot, frames: 60, screen: "How many files(0-15)?") == ["\n"])
  }

  @Test func promptTimesOut() {
    let boot = TapeAutoBoot()
    boot.start()
    _ = run(boot, frames: TapeAutoBoot.promptTimeoutFrames + 10, screen: "Starting")
    #expect(boot.phase == .failed(.promptTimeout))
  }

  @Test func doesNotLookAtTheScreenWhileTyping() {
    let boot = TapeAutoBoot()
    boot.start()
    #expect(run(boot, frames: 60, typingIdle: false, screen: "Ok").isEmpty)
  }

  /// Walk to the loading phase and return the sequencer.
  private func loading() -> TapeAutoBoot {
    let boot = TapeAutoBoot()
    boot.start()
    _ = run(boot, frames: 30, screen: "Ok")
    _ = run(boot, frames: 3, typingIdle: false, screen: "Ok")
    _ = run(boot, frames: 3, screen: "Ok")  // typing done
    _ = run(boot, frames: 2, motor: true, screen: "Found:TEST")
    #expect(boot.phase == .loading)
    return boot
  }

  @Test func sendsRunOnceTheMotorHasStoppedAtOk() {
    let boot = loading()
    _ = run(boot, frames: 100, motor: true, screen: "Found:TEST")
    #expect(run(boot, frames: 100, screen: "Found:TEST\nOk") == ["RUN\n"])
    #expect(boot.phase == .finished)
    #expect(!boot.isActive)
  }

  @Test func shortMotorPauseIsNotTheEnd() {
    let boot = loading()
    // A pause between blocks, shorter than the threshold, with Ok still on
    // screen from before.
    #expect(run(boot, frames: TapeAutoBoot.motorOffFrames - 5, screen: "Ok").isEmpty)
    #expect(boot.phase == .loading)
  }

  @Test func staysPutWhileOkHasNotReturned() {
    let boot = loading()
    #expect(run(boot, frames: 300, screen: "Found:TEST").isEmpty)
    #expect(boot.phase == .loading)
  }

  @Test func motorNeverStartingFails() {
    let boot = TapeAutoBoot()
    boot.start()
    _ = run(boot, frames: 30, screen: "Ok")
    _ = run(boot, frames: 3, screen: "Ok")
    _ = run(boot, frames: TapeAutoBoot.motorTimeoutFrames + 10, screen: "Ok")
    #expect(boot.phase == .failed(.motorTimeout))
  }

  @Test func basicErrorStopsWithoutRun() {
    let boot = TapeAutoBoot()
    boot.start()
    _ = run(boot, frames: 30, screen: "Ok")
    _ = run(boot, frames: 3, screen: "Ok")
    let typed = run(boot, frames: 60, screen: "Ok\nDevice I/O error\nOk\nDevice I/O error")
    #expect(typed.isEmpty)
    #expect(boot.phase == .failed(.basicError))
  }

  @Test func cancelStops() {
    let boot = loading()
    boot.cancel()
    #expect(!boot.isActive)
    #expect(run(boot, frames: 200, screen: "Ok").isEmpty)
  }

  @Test func restartResetsState() {
    let boot = loading()
    boot.start()
    #expect(boot.phase == .waitingForPrompt)
  }
}
