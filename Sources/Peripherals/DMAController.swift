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
///   0x68:      Mode register
///
/// Each channel: 16-bit start address + 14-bit count + 2-bit mode
public final class DMAController {

    // MARK: - Channel State

    public struct Channel {
        public var address: UInt16 = 0
        public var count: UInt16 = 0
        public var mode: UInt8 = 0  // bit 6-7: 00=verify, 01=write, 10=read

        /// Whether this channel is enabled
        public var enabled: Bool = false
    }

    /// 4 DMA channels
    public var channels: [Channel] = Array(repeating: Channel(), count: 4)

    /// Mode register (port 0x68)
    public var modeRegister: UInt8 = 0

    /// Flip-flop for address/count byte ordering (low byte first)
    package var flipFlop: Bool = false  // false = low byte, true = high byte

    // MARK: - Init

    public init() {}

    public func reset() {
        channels = Array(repeating: Channel(), count: 4)
        modeRegister = 0
        flipFlop = false
    }

    // MARK: - Port I/O

    /// Write to DMA controller port.
    public func ioWrite(_ port: UInt8, value: UInt8) {
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

            // Update channel enable flags
            for i in 0..<4 {
                channels[i].enabled = (value & (1 << i)) != 0
            }

        default:
            break
        }
    }

    /// Read from DMA controller port.
    public func ioRead(_ port: UInt8) -> UInt8 {
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
            // Status register
            return modeRegister
        default:
            return 0xFF
        }
    }

    // MARK: - Text VRAM Access

    /// Get the start address for text VRAM (DMA channel 2).
    public var textVRAMAddress: UInt16 {
        return channels[2].address
    }

    /// Get the byte count for text VRAM transfer.
    public var textVRAMCount: UInt16 {
        return channels[2].count & 0x3FFF  // 14-bit count
    }
}
