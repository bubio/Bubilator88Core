import Testing
@_spi(Debug) @testable import Bubilator88Core
import Z80
import Peripherals

/// vraminfo: in V1 mode the DMA reading the text VRAM stops the main CPU
/// during the display cycle, so STOP DISPLAY makes programs faster.
@Suite("Text DMA cycle steal")
struct TextDMAStealTests {

  /// A V1S machine at 4MHz with the ROM's 25×120-byte text DMA running.
  private func v1sMachine(rows: Int = 25) -> Machine {
    let machine = Machine()
    let bus = machine.bus
    bus.cpuClock8MHz = false
    bus.memoryWaitDip = false
    bus.dipSw2 &= ~0x40  // V1S / N
    bus.ioWrite(0x68, value: 0xA0)
    bus.ioWrite(0x64, value: 0x00)
    bus.ioWrite(0x64, value: 0xF3)
    bus.ioWrite(0x65, value: UInt8((rows * 120 - 1) & 0xFF))
    bus.ioWrite(0x65, value: 0x80 | UInt8((rows * 120 - 1) >> 8))
    bus.ioWrite(0x68, value: 0xE4)
    machine.crtc.displayEnabled = true
    return machine
  }

  /// Ticks the CRTC through the first VRTC (which schedules the DMA), then
  /// through one whole frame, and returns what was stolen in that frame.
  private func stolenInOneFrame(_ machine: Machine,
                                beforeFrame: (Machine) -> Void = { _ in }) -> Int {
    let crtc = machine.crtc
    let lines = crtc.dynamicTotalScanlines
    let perLine = 100
    while !crtc.vrtcFlag {
      crtc.tick(tStates: perLine, tStatesPerFrame: perLine * lines)
    }
    while crtc.scanline != 0 {
      crtc.tick(tStates: perLine, tStatesPerFrame: perLine * lines)
    }
    beforeFrame(machine)
    crtc.pendingStolenTStates = 0
    for _ in 0..<lines {
      crtc.tick(tStates: perLine, tStatesPerFrame: perLine * lines)
    }
    return crtc.pendingStolenTStates
  }

  @Test("V1S 4MHz loses four T-states a byte, 3000 bytes a frame")
  func stealsWhileDisplaying() {
    #expect(stolenInOneFrame(v1sMachine()) == 25 * 120 * 4)
  }

  @Test("A main RAM read wait adds to each byte (8MHz)")
  func eightMegahertzAddsTheReadWait() {
    let machine = v1sMachine()
    machine.bus.cpuClock8MHz = true
    #expect(stolenInOneFrame(machine) == 25 * 120 * 5)
  }

  @Test("Nothing is stolen in V1H / V2")
  func noStealInHighSpeedModes() {
    let machine = v1sMachine()
    machine.bus.dipSw2 |= 0x40
    #expect(stolenInOneFrame(machine) == 0)
  }

  @Test("STOP DISPLAY stops the stealing, even mid-frame")
  func stopDisplayStopsIt() {
    #expect(stolenInOneFrame(v1sMachine()) { $0.crtc.displayEnabled = false } == 0)
  }

  @Test("Nothing is stolen with DMA channel 2 off")
  func channelOffStopsIt() {
    let machine = v1sMachine()
    machine.bus.ioWrite(0x68, value: 0x00)
    #expect(stolenInOneFrame(machine) == 0)
  }

  @Test("A short count steals only the rows it fetches (Sorcerian's 13)")
  func shortCountStealsFewerRows() {
    #expect(stolenInOneFrame(v1sMachine(rows: 13)) == 13 * 120 * 4)
  }

  @Test("The machine hands the stolen time to the CPU as wait states")
  func machineChargesIt() {
    let machine = v1sMachine()
    machine.run(tStates: machine.tStatesPerFrame * 2)
    #expect(machine.crtc.pendingStolenTStates == 0)
  }
}
