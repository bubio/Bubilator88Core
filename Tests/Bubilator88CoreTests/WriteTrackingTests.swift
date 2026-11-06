import Foundation
import Testing
@_spi(Debug) @testable import Bubilator88Core

@Suite("Write Tracking Tests")
struct WriteTrackingTests {

  /// Every byte `memWrite(addr)` changed, by where it lives.
  private func changedLocations(_ bus: Pc88Bus, _ addr: UInt16) -> Set<MemoryLocation> {
    bus.mainRAM = [UInt8](repeating: 0, count: bus.mainRAM.count)
    bus.tvram = [UInt8](repeating: 0, count: bus.tvram.count)
    bus.gvram = bus.gvram.map { [UInt8](repeating: 0, count: $0.count) }
    if let ext = bus.extRAM { bus.extRAM = ext.map { $0.map { [UInt8](repeating: 0, count: $0.count) } } }
    let before = (bus.mainRAM, bus.tvram, bus.gvram, bus.extRAM)
    bus.memWrite(addr, value: 0xA5)

    var changed: Set<MemoryLocation> = []
    func diff(_ old: [UInt8], _ new: [UInt8], _ space: MemoryLocation.Space) {
      for i in old.indices where old[i] != new[i] { changed.insert(MemoryLocation(space, i)) }
    }
    diff(before.0, bus.mainRAM, .region(.mainRAM))
    diff(before.1, bus.tvram, .region(.textVRAM))
    let planes: [PC88.MemoryRegion] = [.gvramBlue, .gvramRed, .gvramGreen]
    for p in 0..<3 { diff(before.2[p], bus.gvram[p], .region(planes[p])) }
    if let old = before.3, let new = bus.extRAM {
      for c in old.indices { for b in old[c].indices { diff(old[c][b], new[c][b], .extRAM(card: c, bank: b)) } }
    }
    return changed
  }

  @Test("writeLocations names the byte memWrite changes", arguments: [
    "default", "text window", "ram mode", "tvram", "gvram plane", "ext ram",
  ])
  func writeLocationsAgreeWithMemWrite(_ setup: String) {
    let bus = Pc88Bus()
    switch setup {
    case "text window": bus.textWindowOffset = 0x12
    case "ram mode": bus.ramMode = true
    case "tvram": bus.tvramEnabled = true
    case "gvram plane": bus.gvramPlane = 1
    case "ext ram":
      bus.extRAM = [[[UInt8]](repeating: [UInt8](repeating: 0, count: 0x8000), count: 2)]
      bus.extRAMWriteEnable = true
      bus.extRAMBank = 1
    default: break
    }
    for addr: UInt16 in [0x0100, 0x7FFF, 0x8005, 0x9000, 0xC010, 0xF010, 0xFFFF] {
      let named = bus.writeLocations(addr)
      #expect(!named.viaALU)
      #expect(Set(named.locations) == changedLocations(bus, addr), "\(setup) \(String(format: "%04X", addr))")
    }
  }

  @Test func aluWritesNameThePlanesTheALUChanges() {
    let bus = Pc88Bus()
    bus.ioWrite(0x32, value: 0x40)  // evramMode
    bus.ioWrite(0x35, value: 0x80)  // gamMode, GDM=0
    // Blue NOP (bits 0 and 4), red and green AND NOT.
    bus.aluControl1 = 0x11
    let named = bus.writeLocations(0xC123)
    #expect(named.viaALU)
    #expect(named.locations == [MemoryLocation(.region(.gvramRed), 0x123), MemoryLocation(.region(.gvramGreen), 0x123)])
    bus.aluControl1 = 0x77
    #expect(bus.writeLocations(0xC123).locations.isEmpty)
    bus.ioWrite(0x35, value: 0xA0)  // GDM=2: the red latch into blue
    #expect(bus.writeLocations(0xC123).locations == [MemoryLocation(.region(.gvramBlue), 0x123)])
  }

  @Test func watchesMatchByCPUAddressOrByPlace() {
    let cpu = MemoryWatch(space: .cpu, start: 0x9000, length: 2)
    let ram = MemoryWatch(space: .region(.mainRAM), start: 0x1200, length: 1)
    let here = [MemoryLocation(.region(.mainRAM), 0x1200)]
    #expect(cpu.matches(address: 0x9001, locations: []))
    #expect(!cpu.matches(address: 0x9002, locations: here))
    #expect(ram.matches(address: 0x8000, locations: here))
    #expect(!ram.matches(address: 0x1200, locations: [MemoryLocation(.region(.textVRAM), 0x1200)]))
  }
}
