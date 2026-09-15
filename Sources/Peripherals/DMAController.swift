/// uPD8257 DMA Controller — simplified behavioral model.
///
/// The PC-8801 uses DMA channel 2 to transfer text VRAM data
/// from main RAM to the uPD3301 CRTC for display.
///
/// Port assignments (0x60-0x68):
///   0x60/0x61: Channel 0 address/count
///   0x62/0x63: Channel 1 address/count
///   0x64/0x65: Channel 2 address/count (text VRAM → CRTC)
///   0x66/0x67: Channel 3 address/count
///   0x68:      Mode register (write) / status (read)
///
/// Each channel: 16-bit start address + 14-bit count + 2-bit mode
package final class DMAController {

  // MARK: - Channel State

  package struct Channel {
    package var address: UInt16 = 0
    package var count: UInt16 = 0
    package var mode: UInt8 = 0  // bit 6-7: 00=verify, 01=write, 10=read

    /// Whether this channel is enabled
    package var enabled: Bool = false
  }

  /// 4 DMA channels
  package var channels: [Channel] = Array(repeating: Channel(), count: 4)

  /// Mode register (port 0x68)
  package var modeRegister: UInt8 = 0

  /// Flip-flop for address/count byte ordering (low byte first)
  package var flipFlop: Bool = false  // false = low byte, true = high byte

  /// TC status bits 3-0 of the status register, one per channel. Set when a
  /// channel reaches terminal count, cleared by reading port 0x68.
  package var terminalCountFlags: UInt8 = 0

  /// UPDATE flag (status bit 4): channel 3's parameters are being loaded
  /// into channel 2 in auto-load mode.
  ///
  /// Neither flag is in save states; both settle again within a frame.
  package var updateFlag: Bool = false

  // MARK: - Init

  package init() {}

  package func reset() {
    channels = Array(repeating: Channel(), count: 4)
    modeRegister = 0
    flipFlop = false
    terminalCountFlags = 0
    updateFlag = false
  }

  // MARK: - Port I/O

  /// Write to DMA controller port.
  package func ioWrite(_ port: UInt8, value: UInt8) {
    switch port {
    case 0x60, 0x62, 0x64, 0x66:
      // Address register (even ports)
      let ch = Int((port - 0x60) / 2)
      if !flipFlop {
        channels[ch].address = (channels[ch].address & 0xFF00) | UInt16(value)
      } else {
        channels[ch].address = (channels[ch].address & 0x00FF) | (UInt16(value) << 8)
      }
      flipFlop.toggle()

    case 0x61, 0x63, 0x65, 0x67:
      // Count register (odd ports)
      let ch = Int((port - 0x61) / 2)
      if !flipFlop {
        channels[ch].count = (channels[ch].count & 0xFF00) | UInt16(value)
      } else {
        channels[ch].count = (channels[ch].count & 0x00FF) | (UInt16(value) << 8)
        // High 2 bits of count register = mode
        channels[ch].mode = value >> 6
      }
      flipFlop.toggle()

    case 0x68:
      // Mode register
      modeRegister = value
      flipFlop = false
      // Leaving auto-load mode clears UPDATE (i8257).
      if value & 0x80 == 0 { updateFlag = false }

      // Update channel enable flags
      for i in 0..<4 {
        channels[i].enabled = (value & (1 << i)) != 0
      }

    default:
      break
    }
  }

  /// Read from DMA controller port.
  package func ioRead(_ port: UInt8) -> UInt8 {
    switch port {
    case 0x60, 0x62, 0x64, 0x66:
      let ch = Int((port - 0x60) / 2)
      let value = !flipFlop
        ? UInt8(truncatingIfNeeded: channels[ch].address)
        : UInt8(truncatingIfNeeded: channels[ch].address >> 8)
      flipFlop.toggle()
      return value

    case 0x61, 0x63, 0x65, 0x67:
      let ch = Int((port - 0x61) / 2)
      let value = !flipFlop
        ? UInt8(truncatingIfNeeded: channels[ch].count)
        : UInt8(truncatingIfNeeded: channels[ch].count >> 8)
      flipFlop.toggle()
      return value

    case 0x68:
      // Status: bit 4 UPDATE, bits 3-0 TC. Reading clears TC; UPDATE stays
      // (vraminfo: "TC は一旦 1 の状態を read すると即座に 0 にリセット").
      let value = (updateFlag ? 0x10 : 0x00) | terminalCountFlags
      terminalCountFlags = 0
      return value
    default:
      return 0xFF
    }
  }

  // MARK: - Transfer Events

  /// `channel` transferred its last byte.
  ///
  /// Only the TC and UPDATE status bits are modeled. The transfer itself
  /// happens in bulk at VRTC (`Pc88Bus.performTextDMATransfer`), and neither
  /// the auto-load copy nor TC stop changes the channel registers here.
  package func reachTerminalCount(channel: Int) {
    terminalCountFlags |= UInt8(1 << channel)
    if channel == 2 && modeRegister & 0x80 != 0 {
      updateFlag = true
    }
  }

  /// Vertical retrace began. vraminfo measured UPDATE staying 1 "for a
  /// while" after TC but never into vertical blank, so it ends here.
  package func beginVerticalRetrace() {
    updateFlag = false
  }

  // MARK: - Text VRAM Access

  /// Get the start address for text VRAM (DMA channel 2).
  package var textVRAMAddress: UInt16 {
    return channels[2].address
  }

  /// Get the byte count for text VRAM transfer.
  package var textVRAMCount: UInt16 {
    return channels[2].count & 0x3FFF  // 14-bit count
  }
}
