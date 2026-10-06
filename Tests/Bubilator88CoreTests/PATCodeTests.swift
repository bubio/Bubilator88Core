import Foundation
import Testing
@_spi(Debug) @testable import Bubilator88Core

/// Areas 00 (64KB) and 02 (F000-FFFF) only, enough to exercise the runner
/// without a machine.
private final class FakePATMemory: PATMemory {
  var main = [UInt8](repeating: 0, count: 0x10000)
  var high = [UInt8](repeating: 0, count: 0x1000)

  func patRead(area: UInt8, address: UInt16) -> UInt8? {
    switch area {
    case 0x00: main[Int(address)]
    case 0x02: address >= 0xF000 ? high[Int(address) - 0xF000] : nil
    default: nil
    }
  }

  func patWrite(area: UInt8, address: UInt16, value: UInt8) {
    switch area {
    case 0x00: main[Int(address)] = value
    case 0x02 where address >= 0xF000: high[Int(address) - 0xF000] = value
    default: break
    }
  }
}

private func codes(_ text: String) -> [PATCode] {
  PATFile.parse(text).flatMap(\.codes)
}

@Suite("PAT file parsing")
struct PATFileTests {

  @Test func readsGroupsCodesAndComments() {
    let groups = PATFile.parse("""
    ;イース無敵化

    # 無敵
    D00047CF 4B00
    80004B00 FFFF
    #HP
    3002F224 0190
    """)
    #expect(groups.map(\.name) == ["無敵", "HP"])
    #expect(groups[0].codes == [
      PATCode(opcode: 0xD0, area: 0x00, address: 0x47CF, value: 0x4B00),
      PATCode(opcode: 0x80, area: 0x00, address: 0x4B00, value: 0xFFFF),
    ])
    #expect(groups[1].codes == [PATCode(opcode: 0x30, area: 0x02, address: 0xF224, value: 0x0190)])
  }

  @Test func codesBeforeTheFirstGroupGoIntoAnUnnamedOne() {
    let groups = PATFile.parse("8000E50C 0004\r\n# A\r\n3000E50C 0004\r\n")
    #expect(groups.map(\.name) == [PATFile.unnamedGroupName, "A"])
    #expect(groups.map(\.codes.count) == [1, 1])
  }

  @Test func dropsEverythingAfterTheFifteenthGroup() {
    let text = (1...17).map { "#G\($0)\n8000C000 \(String(format: "%04X", $0))" }.joined(separator: "\n")
    let groups = PATFile.parse(text)
    #expect(groups.count == PATFile.maxGroups)
    #expect(groups.last?.name == "G15")
  }

  @Test func dropsLinesThatStartWithAnythingElse() {
    #expect(codes(" 80004B00 FFFF\nHP減らない").isEmpty)
  }

  @Test func readsAHeadingThatStartsWithAMnemonicCharacterAsANoOp() {
    // The "- HP減らない -" headings of KAJA's list start with `-`, so pat.dll
    // takes them for codes; they parse to opcode 00, which does nothing.
    #expect(codes("- HP減らない -") == [PATCode(opcode: 0, area: 0, address: 0, value: 0)])
  }

  @Test func readsMnemonicPrefixes() {
    let parsed = codes("""
    ww004B00 FFFF
    Wb004B00 0012
    =w004275 52ED
    >b00BE10 00B8
    +w001000 0001
    -b001000 0001
    cp001000 0010
    """)
    #expect(parsed.map(\.opcode) == [0x80, 0x31, 0xD0, 0xE3, 0x10, 0x21, 0xC2])
    #expect(parsed[0].address == 0x4B00)
  }

  @Test func readsAMalformedOperandAsZero() {
    // KAJA's list writes alternative addresses side by side; pat.dll reads
    // the operand "| D0" as 0, and so do we.
    #expect(codes("D000B5F8 | D000B5F9 F920") == [
      PATCode(opcode: 0xD0, area: 0x00, address: 0xB5F8, value: 0)
    ])
  }

  @Test func decodesShiftJISAndUTF16() {
    let text = "# 無敵\r\n80004B00 FFFF\r\n"
    let sjis = text.data(using: .shiftJIS)!
    var utf16 = Data([0xFF, 0xFE])
    utf16.append(text.data(using: .utf16LittleEndian)!)
    for data in [sjis, utf16, Data(text.utf8)] {
      let groups = PATFile.parse(PATFile.decodeText(data))
      #expect(groups.map(\.name) == ["無敵"])
      #expect(groups.first?.codes.count == 1)
    }
  }
}

@Suite("PAT code execution")
struct PATRunnerTests {

  @Test func writesSixteenBitsLittleEndianAndEightBitsLowByteOnly() {
    let memory = FakePATMemory()
    PATRunner.run(codes("80004B00 1234\n30004C00 5678"), on: memory)
    #expect(memory.main[0x4B00] == 0x34)
    #expect(memory.main[0x4B01] == 0x12)
    #expect(memory.main[0x4C00] == 0x78)
    #expect(memory.main[0x4C01] == 0x00)
  }

  @Test func aFailedCompareSkipsOneWrite() {
    let memory = FakePATMemory()
    memory.main[0x4275] = 0xED
    memory.main[0x4276] = 0x52
    PATRunner.run(codes("D0004275 52ED\n80004275 0000"), on: memory)
    #expect(memory.main[0x4275] == 0x00)

    memory.main[0x4275] = 0xED
    memory.main[0x4276] = 0x53
    PATRunner.run(codes("D0004275 52ED\n80004275 0000\n30005000 0001"), on: memory)
    #expect(memory.main[0x4275] == 0xED)
    #expect(memory.main[0x5000] == 0x01)
  }

  /// The chain explained on anonB's "88PARのススメ".
  @Test func comparesChainUntilTheNextWrite() {
    let chain = codes("""
    D002FE86 0F7A
    E100BE10 00C9
    3000BF05 0050
    E200BE10 00B8
    3000C000 0001
    3000C001 0002
    """)
    let memory = FakePATMemory()
    memory.high[0xE86] = 0x7A
    memory.high[0xE87] = 0x0F
    memory.main[0xBE10] = 0xC9
    PATRunner.run(chain, on: memory)
    #expect(memory.main[0xBF05] == 0x00)  // [2] failed
    #expect(memory.main[0xC000] == 0x00)  // C9 is not below B8
    #expect(memory.main[0xC001] == 0x02)  // unconditional

    memory.main[0xBE10] = 0x10
    PATRunner.run(chain, on: memory)
    #expect(memory.main[0xBF05] == 0x50)
    #expect(memory.main[0xC000] == 0x01)
  }

  @Test func comparesAreUnsigned() {
    let memory = FakePATMemory()
    memory.main[0x1000] = 0x80
    PATRunner.run(codes("E2001000 0010\n30002000 0001\nE3001000 0010\n30002001 0001"), on: memory)
    #expect(memory.main[0x2000] == 0x00)
    #expect(memory.main[0x2001] == 0x01)
  }

  @Test func oddWriteOpcodesKeepTheCondition() {
    let memory = FakePATMemory()
    memory.main[0x1000] = 0x01
    PATRunner.run(codes("E0001000 0000\n31002000 0001\n30002001 0001"), on: memory)
    #expect(memory.main[0x2000] == 0x00)
    #expect(memory.main[0x2001] == 0x00)  // still under the failed compare
  }

  @Test func addsAndSubtractsEveryRunWithTheWidthsOfPatDll() {
    let memory = FakePATMemory()
    memory.main[0x1000] = 0xFF
    memory.main[0x2000] = 0x00
    let adds = codes("10001000 0001\n21002000 0001")
    PATRunner.run(adds, on: memory)
    #expect(memory.main[0x1000] == 0x00)
    #expect(memory.main[0x1001] == 0x01)  // 10 is 16-bit: the carry lands
    #expect(memory.main[0x2000] == 0xFF)  // 21 is 8-bit: wraps
    #expect(memory.main[0x2001] == 0x00)
    PATRunner.run(adds, on: memory)
    #expect(memory.main[0x1000] == 0x01)
    #expect(memory.main[0x2000] == 0xFE)
  }

  @Test func copiesIntoTheNextWrite() {
    let memory = FakePATMemory()
    memory.main[0x1000...0x1003] = [1, 2, 3, 4]
    PATRunner.run(codes("C2001000 0003\n80002000 0000"), on: memory)
    #expect(Array(memory.main[0x2000...0x2003]) == [1, 2, 3, 0])
  }

  @Test func anAddressOutsideTheAreaEndsTheGroup() {
    let memory = FakePATMemory()
    PATRunner.run(codes("30020000 0001\n30001000 0001"), on: memory)  // 02 starts at F000
    PATRunner.run(codes("80020000 0001\n"), on: memory)
    #expect(memory.main[0x1000] == 0x00)
    PATRunner.run(codes("8000FFFF 1234\n30001000 0001"), on: memory)  // high byte past the end
    #expect(memory.main[0xFFFF] == 0x00)
    #expect(memory.main[0x1000] == 0x00)
  }

  @Test func ignoresOpcodesPatDllDoesNotImplement() {
    let memory = FakePATMemory()
    PATRunner.run(codes("50000602 0000\nC1000000 0258\nD4000000 0001\n80001000 FFFF"), on: memory)
    #expect(memory.main[0x1000] == 0xFF)
  }
}

@Suite("PAT areas on the machine")
struct PATMachineAreaTests {

  @Test func areaZeroIsMainRAMAndAreaTwoIsHighSpeedRAM() {
    let machine = Machine()
    PATRunner.run(codes("3000F224 0011\n3002F224 0022"), on: machine)
    #expect(machine.bus.mainRAM[0xF224] == 0x11)
    #expect(machine.bus.tvram[0x224] == 0x22)
  }

  @Test func subCPUAreasAddressItsROMAndRAM() {
    let machine = Machine()
    PATRunner.run(codes("80036000 6618\n30040100 00C9"), on: machine)
    #expect(machine.subSystem.subBus.romram[0x6000] == 0x18)
    #expect(machine.subSystem.subBus.romram[0x6001] == 0x66)
    #expect(machine.subSystem.subBus.romram[0x0100] == 0xC9)
  }

  @Test func romAreasPatchLoadedROMsAndEndTheGroupWhenMissing() {
    let machine = Machine()
    machine.bus.n88BasicROM = [UInt8](repeating: 0, count: 0x8000)
    PATRunner.run(codes("30017000 0001\n30077000 00C9"), on: machine)  // 01 stops at 5FFF
    #expect(machine.bus.n88BasicROM?[0x7000] == 0x00)
    PATRunner.run(codes("30077000 00C9"), on: machine)
    #expect(machine.bus.n88BasicROM?[0x7000] == 0xC9)

    machine.bus.nBasicROM = nil
    PATRunner.run(codes("30061000 0001\n30001000 0001"), on: machine)
    #expect(machine.bus.mainRAM[0x1000] == 0x00)
  }
}
