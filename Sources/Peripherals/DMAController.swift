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

  /// How far into channel 2's block the text DMA has read.
  ///
  /// The real address register counts as it transfers; here it keeps the
  /// programmed value and this offset walks instead, because the transfer
  /// happens in one go at VRTC. It survives across frames, so a count
  /// longer than one screen carries on where the last frame stopped —
  /// which is how a 6000-byte count alternates two screens (vraminfo's
  /// 27-color trick). Not in save states: a load restarts at the top of
  /// the block, at worst showing the other screen for a frame.
  package var textOffset: Int = 0

  /// Auto-load (mode register bit 7): channel 3 holds the parameters that
  /// channel 2 is reloaded with at terminal count.
  package var autoLoad: Bool { modeRegister & 0x80 != 0 }

  // MARK: - Init

  package init() {}

  package func reset() {
    channels = Array(repeating: Channel(), count: 4)
    modeRegister = 0
    flipFlop = false
    terminalCountFlags = 0
    updateFlag = false
    textOffset = 0
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
      if ch == 2 { textOffset = 0 }

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
      if ch == 2 { textOffset = 0 }

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

  /// Address of the next text byte, advancing the walk.
  ///
  /// At terminal count it starts the block again. In auto-load mode the
  /// i8257 takes the parameters back from channel 3, which holds the same
  /// values because writing channel 2 with auto-load on writes both.
  package func nextTextDMAAddress() -> UInt16 {
    let address = channels[2].address &+ UInt16(truncatingIfNeeded: textOffset)
    textOffset = textOffset >= Int(textVRAMCount) ? 0 : textOffset + 1
    return address
  }

  /// `channel` transferred its last byte.
  ///
  /// Only the TC and UPDATE status bits are set here. The transfer itself
  /// happens in bulk at VRTC (`Pc88Bus.performTextDMATransfer`), which is
  /// also where the auto-load reload happens, one byte at a time.
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
