import Testing
@_spi(Debug) @testable import Bubilator88Core
import Peripherals

@Suite("Peripheral hot-path state preservation")
struct PeripheralHotPathTests {

  @Test("IRQ resolution preserves every pending, threshold, and mask combination")
  func interruptResolutionCombinations() {
    for masks in 0..<16 {
      var controller = InterruptController()
      controller.maskRXRDY = masks & 1 != 0
      controller.maskVRTC = masks & 2 != 0
      controller.maskRTC = masks & 4 != 0
      controller.maskSound = masks & 8 != 0
      let maskedLevels = [controller.maskRXRDY, controller.maskVRTC,
                          controller.maskRTC, false, controller.maskSound,
                          false, false, false]
      for threshold in UInt8(0)...7 {
        controller.levelThreshold = threshold
        for pending in UInt8.min...UInt8.max {
          controller.pendingLevels = pending
          let candidates = (0..<Int(threshold)).filter {
            !maskedLevels[$0] && pending & (1 << $0) != 0
          }
          let resolved = controller.resolve()
          #expect(resolved?.level == candidates.first)
          #expect(resolved?.vectorOffset == candidates.first.map { UInt8($0 * 2) })
          #expect(controller.pendingLevels == pending)
          #expect(controller.levelThreshold == threshold)
        }
      }
    }
  }

  @Test("Port C polling preserves serialized state after restoration",
        arguments: [UInt8(0x80), 0x89, 0x9B, 0xA4, 0xC0])
  func portCPollingPreservesState(control: UInt8) throws {
    let source = PIO8255()
    for side in [PIO8255.Side.main, .sub] {
      source.writeControl(side: side, data: control)
      source.writeAB(side: side, port: .portA, data: 0xA5)
      source.writeAB(side: side, port: .portB, data: 0x3C)
      source.writePortC(side: side, data: 0x69)
    }
    var saved = SaveStateWriter()
    source.writeSaveState(to: &saved)
    let restored = PIO8255()
    var reader = SaveStateReader(saved.data)
    try restored.readSaveState(from: &reader)
    for side in [PIO8255.Side.main, .sub] {
      let before = restored.debugPortState(side: side, port: 2)
      let expected = (before.rreg & before.rmask) | (before.wreg & ~before.rmask)
      #expect(restored.readC(side: side) == expected)
      #expect(restored.readC(side: side) == expected)
    }
    var after = SaveStateWriter()
    restored.writeSaveState(to: &after)
    #expect(after.data == saved.data)
  }

  @Test("Port C access observer sees writes made by the CPU-switch callback")
  func portCPollCallbackOrdering() {
    let pio = PIO8255()
    pio.writeControl(side: .main, data: 0x80)
    pio.writePortC(side: .main, data: 0x12)
    var observations = 0
    pio.onCPUSwitch = {
      pio.writeAB(side: .main, port: .portA, data: 0xA5)
      pio.writePortC(side: .main, data: 0x34)
    }
    pio.onPIOAccess = { access in
      guard !access.isWrite, access.port == 2 else { return }
      observations += 1
      #expect(access.value == 0x12)
      #expect(pio.portAB[0][0].data == 0xA5)
      #expect(pio.portAB[0][0].exist)
      #expect(pio.portC[0][0].data == 3)
      #expect(pio.portC[0][1].data == 4)
    }
    #expect(pio.readC(side: .main) == 0x12)
    #expect(observations == 1)
    pio.onCPUSwitch = nil
    pio.onPIOAccess = nil
  }
}
