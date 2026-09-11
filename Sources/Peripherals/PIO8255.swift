/// PIO8255 — cross-wired 8255 PIO pair connecting main CPU and sub CPU.
///
/// This models the wiring used by the PC-8801 disk subsystem:
///   Main Port A <-> Sub Port B
///   Main Port B <-> Sub Port A
///   Port C is cross-wired nibble-swapped between the two 8255s
///
/// The implementation follows the fmgen/BubiC `I8255` behavior closely enough
/// for the PC-8801 disk handshake, while keeping a few diagnostic fields used
/// by the existing tests and freeze dumps.
package final class PIO8255 {

  // MARK: - Types

  package enum Side: Int, Sendable {
    case main = 0
    case sub = 1

    var opposite: Side { self == .main ? .sub : .main }
  }

  package enum PortABIndex: Int {
    case portA = 0
    case portB = 1

    var opposite: PortABIndex { self == .portA ? .portB : .portA }
  }

  package enum PortCHalf: Int {
    case ch = 0
    case cl = 1
  }

  package enum PortType {
    case read
    case write
  }

  package struct PortABState {
    package var type: PortType = .read
    package var exist: Bool = false
    package var data: UInt8 = 0x00
  }

  package struct PortCState {
    package var type: PortType = .read
    package var contFlag: Bool = true
    package var data: UInt8 = 0x00
  }

  package enum PortID: Int {
    case portA = 0
    case portB = 1
    case portC = 2
  }

  package struct RawPortState {
    package var wreg: UInt8 = 0x00
    package var rreg: UInt8 = 0x00
    package var rmask: UInt8 = 0xFF
    package var mode: UInt8 = 0
    package var first: Bool = true
  }

  package struct DebugPortState {
    package let wreg: UInt8
    package let rreg: UInt8
    package let rmask: UInt8
    package let mode: UInt8
  }

  /// One PIO data-flow event, fired via ``onPIOAccess`` when the
  /// debugger is attached. `port` uses the low-level numeric index
  /// (0=A, 1=B, 2=C) so this type stays self-contained.
  package struct PIOAccess: Sendable, Hashable {
    package let side: Side
    package let port: UInt8
    package let isWrite: Bool
    package let value: UInt8
  }

  // MARK: - 8255 handshake bits

  private static let bitIBFA: UInt8 = 0x20  // PC5
  private static let bitSTBA: UInt8 = 0x10  // PC4
  private static let bitSTBB: UInt8 = 0x04  // PC2
  private static let bitIBFB: UInt8 = 0x02  // PC1

  private static let bitOBFA: UInt8 = 0x80  // PC7
  private static let bitACKA: UInt8 = 0x40  // PC6
  private static let bitACKB: UInt8 = 0x04  // PC2
  private static let bitOBFB: UInt8 = 0x02  // PC1

  private static let bitINTRA: UInt8 = 0x08 // PC3
  private static let bitINTRB: UInt8 = 0x01 // PC0

  // MARK: - State

  package var ports: [[RawPortState]] = Array(
    repeating: Array(repeating: RawPortState(), count: 3),
    count: 2
  )

  /// Port A/B state: [2 sides][2 ports]
  package var portAB: [[PortABState]] = [
    [PortABState(), PortABState()],
    [PortABState(), PortABState()]
  ]

  /// Port C state: [2 sides][2 halves (CH, CL)]
  package var portC: [[PortCState]] = [
    [PortCState(), PortCState()],
    [PortCState(), PortCState()]
  ]

  package var pendingAB: [[Bool]] = [
    [false, false],
    [false, false]
  ]

  /// Callback fired when Port C polling is detected by the scheduler heuristic.
  package var onCPUSwitch: (() -> Void)?

  /// Optional debugger hook invoked on every Port A/B/C access.
  /// `nil` by default so the hot path pays a single pointer compare.
  package var onPIOAccess: ((PIOAccess) -> Void)?

  /// Optional debugger hook invoked on every control-register
  /// write (port 0xFF — mode set or BSR). Parameters: (side, data).
  /// These modify port C state via the BSR path and are essential
  /// for cross-emulator handshake debugging.
  package var onPIOControlWrite: ((Side, UInt8) -> Void)?


  /// Matches the reference setup used by the PC-8801 PIO pair.
  package var clearPortsByCommandRegister: Bool = true

  // MARK: - Init

  package init() {
    reset()
  }

  package func reset() {
    for side in 0..<2 {
      for port in 0..<3 {
        ports[side][port] = RawPortState()
      }
      pendingAB[side][0] = false
      pendingAB[side][1] = false
      portC[side][PortCHalf.ch.rawValue].contFlag = true
      portC[side][PortCHalf.cl.rawValue].contFlag = true
    }
    syncPublicState()
  }

  // MARK: - Public API

  /// Read from Port A or B using 8255 semantics.
  package func readAB(side: Side, port: PortABIndex) -> UInt8 {
    let sideIndex = side.rawValue
    let portIndex = port.rawValue
    let isInput = ports[sideIndex][portIndex].rmask == 0xFF
    let value = readPort(side: sideIndex, port: portIndex)

    if isInput {
      pendingAB[side.opposite.rawValue][port.opposite.rawValue] = false
    }

    syncPublicState()
    onPIOAccess?(PIOAccess(side: side, port: UInt8(portIndex), isWrite: false, value: value))
    return value
  }

  /// Write to Port A or B using 8255 semantics.
  package func writeAB(side: Side, port: PortABIndex, data: UInt8) {
    pendingAB[side.rawValue][port.rawValue] = true
    writePort(side: side.rawValue, port: port.rawValue, data: data)
    syncPublicState()
    onPIOAccess?(PIOAccess(side: side, port: UInt8(port.rawValue), isWrite: true, value: data))
  }

  /// Read Port C using 8255 semantics.
  package func readC(side: Side) -> UInt8 {
    let sideIndex = side.rawValue
    let value = readPort(side: sideIndex, port: PortID.portC.rawValue)

    let clIndex = PortCHalf.cl.rawValue
    portC[sideIndex][clIndex].contFlag.toggle()
    if !portC[sideIndex][clIndex].contFlag {
      onCPUSwitch?()
    }

    syncPublicState()
    onPIOAccess?(PIOAccess(side: side, port: 2, isWrite: false, value: value))
    return value
  }

  /// Write Port C data register (port 0xFE).
  package func writePortC(side: Side, data: UInt8) {
    writePort(side: side.rawValue, port: PortID.portC.rawValue, data: data)
    syncPublicState()
    onPIOAccess?(PIOAccess(side: side, port: 2, isWrite: true, value: data))
  }

  /// Write Port C using 8255 BSR (Bit Set/Reset) command format.
  /// This corresponds to port 0xFF with bit 7 cleared.
  package func writeC(side: Side, data: UInt8) {
    writeControl(side: side, data: data)
  }

  /// Direct write alias kept for older tests.
  package func writeCDirect(side: Side, data: UInt8) {
    writePortC(side: side, data: data)
  }

  /// Write control register (port 0xFF).
  package func writeControl(side: Side, data: UInt8) {
    writeControlInternal(side: side.rawValue, data: data)
    syncPublicState()
    onPIOControlWrite?(side, data)
  }

  /// Mode-set helper kept for older call sites.
  package func setMode(side: Side, data: UInt8) {
    writeControl(side: side, data: data)
  }

  package func debugPortState(side: Side, port: Int) -> DebugPortState {
    let state = ports[side.rawValue][port]
    return DebugPortState(wreg: state.wreg, rreg: state.rreg, rmask: state.rmask, mode: state.mode)
  }

  // MARK: - Internal 8255 core

  private func readPort(side sideIndex: Int, port portIndex: Int) -> UInt8 {
    switch portIndex {
    case PortID.portA.rawValue:
      if ports[sideIndex][PortID.portA.rawValue].mode == 1 || ports[sideIndex][PortID.portA.rawValue].mode == 2 {
        var value = ports[sideIndex][PortID.portC.rawValue].wreg & ~Self.bitIBFA
        if (ports[sideIndex][PortID.portC.rawValue].wreg & Self.bitSTBA) != 0 {
          value &= ~Self.bitINTRA
        }
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
      }
    case PortID.portB.rawValue:
      if ports[sideIndex][PortID.portB.rawValue].mode == 1 {
        var value = ports[sideIndex][PortID.portC.rawValue].wreg & ~Self.bitIBFB
        if (ports[sideIndex][PortID.portC.rawValue].wreg & Self.bitSTBB) != 0 {
          value &= ~Self.bitINTRB
        }
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
      }
    default:
      break
    }

    let portState = ports[sideIndex][portIndex]
    return (portState.rreg & portState.rmask) | (portState.wreg & ~portState.rmask)
  }

  private func writePort(side sideIndex: Int, port portIndex: Int, data: UInt8) {
    if ports[sideIndex][portIndex].wreg != data || ports[sideIndex][portIndex].first {
      ports[sideIndex][portIndex].wreg = data
      ports[sideIndex][portIndex].first = false
      emitWrite(side: sideIndex, port: portIndex, data: data)
    } else {
      ports[sideIndex][portIndex].wreg = data
    }

    switch portIndex {
    case PortID.portA.rawValue:
      if ports[sideIndex][PortID.portA.rawValue].mode == 1 || ports[sideIndex][PortID.portA.rawValue].mode == 2 {
        var value = ports[sideIndex][PortID.portC.rawValue].wreg & ~Self.bitOBFA
        if (ports[sideIndex][PortID.portC.rawValue].wreg & Self.bitACKA) != 0 {
          value &= ~Self.bitINTRA
        }
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
      }
    case PortID.portB.rawValue:
      if ports[sideIndex][PortID.portB.rawValue].mode == 1 {
        var value = ports[sideIndex][PortID.portC.rawValue].wreg & ~Self.bitOBFB
        if (ports[sideIndex][PortID.portC.rawValue].wreg & Self.bitACKB) != 0 {
          value &= ~Self.bitINTRB
        }
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
      }
    default:
      break
    }
  }

  private func writeControlInternal(side sideIndex: Int, data: UInt8) {
    if data & 0x80 != 0 {
      ports[sideIndex][PortID.portA.rawValue].mode = (data & 0x40) != 0 ? 2 : UInt8((data >> 5) & 0x01)
      ports[sideIndex][PortID.portA.rawValue].rmask =
        ports[sideIndex][PortID.portA.rawValue].mode == 2 ? 0xFF : ((data & 0x10) != 0 ? 0xFF : 0x00)

      ports[sideIndex][PortID.portB.rawValue].mode = UInt8((data >> 2) & 0x01)
      ports[sideIndex][PortID.portB.rawValue].rmask = (data & 0x02) != 0 ? 0xFF : 0x00

      ports[sideIndex][PortID.portC.rawValue].rmask =
        ((data & 0x08) != 0 ? 0xF0 : 0x00) |
        ((data & 0x01) != 0 ? 0x0F : 0x00)

      if clearPortsByCommandRegister {
        pendingAB[sideIndex][0] = false
        pendingAB[sideIndex][1] = false
        writePort(side: sideIndex, port: PortID.portA.rawValue, data: 0x00)
        writePort(side: sideIndex, port: PortID.portB.rawValue, data: 0x00)
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: 0x00)
      }
      portC[sideIndex][PortCHalf.ch.rawValue].contFlag = true
      portC[sideIndex][PortCHalf.cl.rawValue].contFlag = true

      if ports[sideIndex][PortID.portA.rawValue].mode != 0 || ports[sideIndex][PortID.portB.rawValue].mode != 0 {
        var value = ports[sideIndex][PortID.portC.rawValue].wreg
        if ports[sideIndex][PortID.portA.rawValue].mode == 1 || ports[sideIndex][PortID.portA.rawValue].mode == 2 {
          value &= ~Self.bitIBFA
          value |= Self.bitOBFA
          value &= ~Self.bitINTRA
        }
        if ports[sideIndex][PortID.portB.rawValue].mode == 1 {
          if ports[sideIndex][PortID.portB.rawValue].rmask == 0xFF {
            value &= ~Self.bitIBFB
          } else {
            value |= Self.bitOBFB
          }
          value &= ~Self.bitINTRB
        }
        writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
      }
    } else {
      var value = ports[sideIndex][PortID.portC.rawValue].wreg
      let bit = Int((data >> 1) & 0x07)
      if data & 0x01 != 0 {
        value |= UInt8(1 << bit)
      } else {
        value &= ~UInt8(1 << bit)
      }
      writePort(side: sideIndex, port: PortID.portC.rawValue, data: value)
    }
  }

  private func emitWrite(side sideIndex: Int, port portIndex: Int, data: UInt8) {
    let opposite = sideIndex ^ 1
    switch portIndex {
    case PortID.portA.rawValue:
      writeSignal(side: opposite, id: .portB, data: data, mask: 0xFF)
    case PortID.portB.rawValue:
      writeSignal(side: opposite, id: .portA, data: data, mask: 0xFF)
    case PortID.portC.rawValue:
      writeSignal(side: opposite, id: .portC, data: (data & 0x0F) << 4, mask: 0xF0)
      writeSignal(side: opposite, id: .portC, data: (data & 0xF0) >> 4, mask: 0x0F)
    default:
      break
    }
  }

  private func writeSignal(side sideIndex: Int, id: PortID, data: UInt8, mask: UInt8) {
    switch id {
    case .portA:
      ports[sideIndex][PortID.portA.rawValue].rreg =
        (ports[sideIndex][PortID.portA.rawValue].rreg & ~mask) | (data & mask)

    case .portB:
      ports[sideIndex][PortID.portB.rawValue].rreg =
        (ports[sideIndex][PortID.portB.rawValue].rreg & ~mask) | (data & mask)

    case .portC:
      let portAState = ports[sideIndex][PortID.portA.rawValue]
      let portBState = ports[sideIndex][PortID.portB.rawValue]
      let currentCRead = ports[sideIndex][PortID.portC.rawValue].rreg
      let currentCWrite = ports[sideIndex][PortID.portC.rawValue].wreg

      if portAState.mode == 1 || portAState.mode == 2 {
        if (mask & Self.bitSTBA) != 0 {
          if (currentCRead & Self.bitSTBA) != 0 && (data & Self.bitSTBA) == 0 {
            writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitIBFA)
          } else if (currentCRead & Self.bitSTBA) == 0 && (data & Self.bitSTBA) != 0 {
            if (currentCWrite & Self.bitSTBA) != 0 {
              writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitINTRA)
            }
          }
        }
        if (mask & Self.bitACKA) != 0 {
          if (currentCRead & Self.bitACKA) != 0 && (data & Self.bitACKA) == 0 {
            writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitOBFA)
          } else if (currentCRead & Self.bitACKA) == 0 && (data & Self.bitACKA) != 0 {
            if (currentCWrite & Self.bitACKA) != 0 {
              writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitINTRA)
            }
          }
        }
      }

      if portBState.mode == 1 {
        if portBState.rmask == 0xFF {
          if (mask & Self.bitSTBB) != 0 {
            if (currentCRead & Self.bitSTBB) != 0 && (data & Self.bitSTBB) == 0 {
              writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitIBFB)
            } else if (currentCRead & Self.bitSTBB) == 0 && (data & Self.bitSTBB) != 0 {
              if (currentCWrite & Self.bitSTBB) != 0 {
                writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitINTRB)
              }
            }
          }
        } else {
          if (mask & Self.bitACKB) != 0 {
            if (currentCRead & Self.bitACKB) != 0 && (data & Self.bitACKB) == 0 {
              writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitOBFB)
            } else if (currentCRead & Self.bitACKB) == 0 && (data & Self.bitACKB) != 0 {
              if (currentCWrite & Self.bitACKB) != 0 {
                writePort(side: sideIndex, port: PortID.portC.rawValue, data: currentCWrite | Self.bitINTRB)
              }
            }
          }
        }
      }

      ports[sideIndex][PortID.portC.rawValue].rreg =
        (ports[sideIndex][PortID.portC.rawValue].rreg & ~mask) | (data & mask)
    }
  }

  // MARK: - Diagnostic/public state sync

  private func syncPublicState() {
    for side in 0..<2 {
      for portIndex in 0..<2 {
        portAB[side][portIndex].type = ports[side][portIndex].rmask == 0xFF ? .read : .write
        portAB[side][portIndex].exist = pendingAB[side][portIndex]
        portAB[side][portIndex].data = ports[side][portIndex].wreg
      }

      portC[side][PortCHalf.ch.rawValue].type =
        (ports[side][PortID.portC.rawValue].rmask & 0xF0) == 0xF0 ? .read : .write
      portC[side][PortCHalf.ch.rawValue].data = ports[side][PortID.portC.rawValue].wreg >> 4

      portC[side][PortCHalf.cl.rawValue].type =
        (ports[side][PortID.portC.rawValue].rmask & 0x0F) == 0x0F ? .read : .write
      portC[side][PortCHalf.cl.rawValue].data = ports[side][PortID.portC.rawValue].wreg & 0x0F
    }
  }

}
