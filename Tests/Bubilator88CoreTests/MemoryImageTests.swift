import Testing
import Foundation
@_spi(Debug) @testable import Bubilator88Core

/// The `.n80` memory image: a PC-8001 RAM dump of 0x8000-0xFF3F whose last
/// bytes are a resume stub (`RET` at 0xFF3D) and the stack pointer to resume
/// with (0xFF3E).
@Suite("Memory Image Tests")
struct MemoryImageTests {

  /// A machine reset into N-BASIC, which is where a host restores an image.
  /// The ROM's init writes port 0x31 (RMODE=0: N-BASIC); a reset alone leaves
  /// the N88 mapping, which routes 0x8000-0x83FF to the text window.
  private func makeNBasicMachine() -> PC88 {
    let pc88 = PC88()
    pc88.setBootMode(.nbasic)
    pc88.reset()
    pc88.machine.bus.ioWrite(0x31, value: 0x01)
    return pc88
  }

  private func makeImage(hl: UInt16, sp: UInt16) -> [UInt8] {
    var image = [UInt8](repeating: 0, count: PC88.memoryImageSize)
    for i in 0..<image.count { image[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 1) }
    image[0xEA63 - 0x8000] = UInt8(hl & 0xFF)
    image[0xEA64 - 0x8000] = UInt8(hl >> 8)
    image[0xFF3E - 0x8000] = UInt8(sp & 0xFF)
    image[0xFF3F - 0x8000] = UInt8(sp >> 8)
    return image
  }

  @Test func restoreCopiesTheImageAndZeroesTheTail() {
    let pc88 = makeNBasicMachine()
    pc88.machine.bus.memWrite(0xFF80, value: 0xAA)
    let image = makeImage(hl: 0x1234, sp: 0xE8C3)

    #expect(pc88.restoreMemoryImage(image))

    // Read back as the CPU sees it: 0xF000-0xFFFF is the text VRAM in
    // standard-speed mode, not main RAM.
    let bus = pc88.machine.bus
    let restored = (0x8000..<0xFF40).map { bus.memRead(UInt16($0)) }
    #expect(restored == image)
    #expect((0xFF40..<0x10000).allSatisfy { bus.memRead(UInt16($0)) == 0 })
  }

  @Test func restoreResumesAtTheStub() {
    let pc88 = makeNBasicMachine()
    #expect(pc88.restoreMemoryImage(makeImage(hl: 0x1234, sp: 0xE8C3)))
    let cpu = pc88.machine.cpu
    #expect(cpu.pc == 0xFF3D)
    #expect(cpu.sp == 0xE8C3)
    #expect(cpu.hl == 0x1234)
    #expect(cpu.im == 2)
  }

  /// The PC-8001 screen X88000M sets up: 40 columns of an 80-byte row,
  /// 20 rows, graphics off.
  @Test func restoreSetsThePC8001Screen() {
    let pc88 = makeNBasicMachine()
    pc88.machine.bus.ioWrite(0x30, value: 0x01)  // 80 columns
    #expect(pc88.restoreMemoryImage(makeImage(hl: 0, sp: 0xE800)))
    let machine = pc88.machine
    #expect(!machine.bus.columns80)
    #expect(machine.bus.port31 & 0x08 == 0)
    #expect(machine.crtc.charsPerLine == 80)
    #expect(machine.crtc.linesPerScreen == 20)
  }

  @Test func restoreRefusesAWrongSizeAndTouchesNothing() {
    let pc88 = makeNBasicMachine()
    pc88.machine.bus.memWrite(0x8000, value: 0x55)
    #expect(!pc88.restoreMemoryImage([UInt8](repeating: 1, count: PC88.memoryImageSize - 1)))
    #expect(pc88.machine.bus.memRead(0x8000) == 0x55)
  }

  @Test func restoreLeavesNoWaitStatesBehind() {
    let pc88 = makeNBasicMachine()
    #expect(pc88.restoreMemoryImage(makeImage(hl: 0, sp: 0xE800)))
    #expect(pc88.machine.bus.pendingWaitStates == 0)
  }
}

@Suite("MemoryImageBoot Tests")
struct MemoryImageBootTests {

  /// N-BASIC's screen at the prompt: 40×20, function keys on the bottom row.
  private let promptScreen =
    "NEC PC-8001 BASIC Ver 1.4\nCopyright 1979 (C) by Microsoft\n\nOk\n"
      + String(repeating: "\n", count: 15) + "         auto   go to  list   run     \n"
  private let blankScreen =
    String(repeating: "\n", count: 19) + "         auto   go to  list   run     \n"

  /// An image whose stub returns to `resume`, with `lastScreenLine` on its
  /// own screen.
  private func makeImage(resume: UInt16, lastScreenLine: String = "Ok") -> [UInt8] {
    var image = [UInt8](repeating: 0, count: PC88.memoryImageSize)
    func put(_ addr: Int, _ value: UInt16) {
      image[addr - 0x8000] = UInt8(value & 0xFF)
      image[addr - 0x8000 + 1] = UInt8(value >> 8)
    }
    put(0xFF3E, 0xE8C3)  // SP
    put(0xE8C3, resume)
    for (i, byte) in lastScreenLine.utf8.enumerated() {
      image[0xF300 - 0x8000 + 3 * 120 + i * 2] = byte
    }
    return image
  }

  /// Taken at BASIC's prompt: resumes in the ROM's keyboard wait.
  private var basicImage: [UInt8] { makeImage(resume: 0x03B2) }

  /// Run ticks with a fixed screen, returning every action.
  private func run(
    _ boot: MemoryImageBoot, frames: Int, typingIdle: Bool = true, screen: String
  ) -> [MemoryImageBoot.Action] {
    (0..<frames).compactMap { _ in boot.tick(typingIdle: typingIdle, screen: { screen }) }
  }

  @Test func idleDoesNothing() {
    let boot = MemoryImageBoot()
    #expect(run(boot, frames: 100, screen: promptScreen).isEmpty)
    #expect(!boot.isActive)
  }

  @Test func restoresAtThePromptThenTypesRun() {
    let boot = MemoryImageBoot()
    boot.start(image: basicImage)
    #expect(run(boot, frames: 60, screen: blankScreen).isEmpty)
    #expect(boot.phase == .waitingForPrompt)

    let actions = run(boot, frames: MemoryImageBoot.screenPollFrames + 1, screen: promptScreen)
    #expect(actions == [.restore(basicImage), .type("RUN\n")])
    #expect(boot.phase == .typingRun)
  }

  @Test func finishesOnceTypingIsDone() {
    let boot = MemoryImageBoot()
    boot.start(image: basicImage)
    _ = run(boot, frames: MemoryImageBoot.screenPollFrames + 1, screen: promptScreen)
    _ = run(boot, frames: 10, typingIdle: false, screen: promptScreen)
    #expect(boot.phase == .typingRun)
    _ = run(boot, frames: 1, screen: promptScreen)
    #expect(boot.phase == .finished)
    #expect(!boot.isActive)
  }

  /// The function-key row is the bottom row of a 20-row screen, so it must
  /// not hide an `Ok` above it.
  @Test func readsPastTheFunctionKeysOnA20RowScreen() {
    #expect(MemoryImageBoot.lines(promptScreen).last == "Ok")
  }

  @Test func failsWithoutAPrompt() {
    let boot = MemoryImageBoot()
    boot.start(image: basicImage)
    #expect(run(boot, frames: MemoryImageBoot.promptTimeoutFrames + 1, screen: blankScreen).isEmpty)
    #expect(boot.phase == .failed)
  }

  @Test func anImageThatStartsItselfGetsNoRun() {
    let boot = MemoryImageBoot()
    let image = makeImage(resume: 0xCE07)
    boot.start(image: image)
    let actions = run(boot, frames: MemoryImageBoot.screenPollFrames + 1, screen: promptScreen)
    #expect(actions == [.restore(image)])
    #expect(boot.phase == .finished)
  }

  @Test func readsTheResumeAddressThroughTheImagesSP() {
    #expect(MemoryImageBoot.needsRun(makeImage(resume: 0x03B2)))
    #expect(!MemoryImageBoot.needsRun(makeImage(resume: 0x9000)))
    #expect(!MemoryImageBoot.needsRun(makeImage(resume: 0x03B2, lastScreenLine: "*")))
    // A blank screen at BASIC's prompt still needs RUN.
    #expect(MemoryImageBoot.needsRun(makeImage(resume: 0x03B2, lastScreenLine: "")))
  }

  @Test func readsTheImagesScreenInFortyColumns() {
    #expect(MemoryImageBoot.screenLines(of: makeImage(resume: 0, lastScreenLine: "Ok")) == ["Ok"])
  }

  @Test func cancelStops() {
    let boot = MemoryImageBoot()
    boot.start(image: basicImage)
    boot.cancel()
    #expect(run(boot, frames: 20, screen: promptScreen).isEmpty)
    #expect(boot.phase == .idle)
  }
}
