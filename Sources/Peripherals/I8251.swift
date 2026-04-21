#if canImport(Foundation)
import Foundation
#endif

/// μPD8251 (i8251) USART behavioral model.
///
/// PC-8801 shares this chip between the cassette (CMT) and RS-232C paths.
/// Bubilator88 models only the asynchronous-mode behavior used by the CMT
/// load path: software writes a Mode byte once after reset, then Command
/// bytes (Internal Reset returns to the Mode-expected state), polls the
/// status register for RxRDY, and reads one byte at a time. The CMT deck
/// injects bytes via `receiveByte(_:)`.
///
/// No timing model — bytes become available to the CPU the instant the deck
/// injects them. Throttling is the CMT deck's responsibility (see
/// `CassetteDeck.tick`).
public final class I8251 {

    public struct Status: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let txRDY   = Status(rawValue: 1 << 0)
        public static let rxRDY   = Status(rawValue: 1 << 1)
        public static let txEmpty = Status(rawValue: 1 << 2)
        public static let parityErr   = Status(rawValue: 1 << 3)
        public static let overrunErr  = Status(rawValue: 1 << 4)
        public static let framingErr  = Status(rawValue: 1 << 5)
        public static let syndet      = Status(rawValue: 1 << 6)
        public static let dsr         = Status(rawValue: 1 << 7)
    }

    private enum WriteExpect {
        case mode
        case command
    }

    private var writeExpect: WriteExpect = .mode
    private var mode: UInt8 = 0
    private var command: UInt8 = 0
    private var status: Status = [.txRDY, .txEmpty]

    private var rxBuf: UInt8 = 0

    /// Invoked whenever the RxRDY line transitions 0 → 1 — a new receive
    /// byte is ready. PC-88 wires this to i8214 Level 0 so the CPU
    /// services CMT bytes via interrupt rather than polling (matches
    /// BubiC `SIG_PC88_USART_IRQ`).
    public var onRxReady: (() -> Void)?

    /// Invoked whenever the RxRDY line transitions 1 → 0 — the CPU has
    /// read the data port, clearing the receive flag. The attached
    /// interrupt controller should drop any still-pending USART level so
    /// the next byte can re-fire cleanly (matches BubiC's
    /// `write_signals(&outputs_rxrdy, 0)`).
    public var onRxReadyCleared: (() -> Void)?

    public init() {}

    // MARK: - CPU-visible interface

    /// Port 0x21 write. First write after reset is Mode, subsequent are
    /// Command. Command bit 6 (Internal Reset) returns to Mode-expected.
    public func writeControl(_ value: UInt8) {
        switch writeExpect {
        case .mode:
            mode = value
            writeExpect = .command
        case .command:
            command = value
            if value & 0x40 != 0 {
                reset()
                return
            }
            if value & 0x10 != 0 {
                // ER: clear error flags
                status.remove([.parityErr, .overrunErr, .framingErr])
            }
        }
    }

    /// Port 0x20 write (Tx). No sink is wired for the CMT-only path; we
    /// simply keep TxRDY/TxEmpty asserted.
    public func writeData(_ value: UInt8) {
        _ = value
        status.insert([.txRDY, .txEmpty])
    }

    /// Port 0x21 read (status).
    public func readStatus() -> UInt8 {
        return status.rawValue
    }

    /// Port 0x20 read (Rx). Clears RxRDY.
    public func readData() -> UInt8 {
        let byte = rxBuf
        if status.contains(.rxRDY) {
            status.remove(.rxRDY)
            onRxReadyCleared?()
        }
        return byte
    }

    // MARK: - External producer interface (CMT deck)

    /// Inject one byte into the receive buffer. Sets RxRDY. If the previous
    /// byte hadn't been read yet, sets the overrun error flag (but still
    /// overwrites the buffer, matching hardware).
    public func receiveByte(_ value: UInt8) {
        let wasReady = status.contains(.rxRDY)
        if wasReady {
            status.insert(.overrunErr)
        }
        rxBuf = value
        status.insert(.rxRDY)
        if !wasReady {
            onRxReady?()   // 0 → 1 transition only
        }
    }

    /// True if a received byte is waiting (RxRDY flag is set).
    public var isRxReady: Bool {
        return status.contains(.rxRDY)
    }

    /// True if the receiver is currently enabled (Command bit 2).
    public var rxEnabled: Bool {
        return command & 0x04 != 0
    }

    // MARK: - Reset

    public func reset() {
        writeExpect = .mode
        mode = 0
        command = 0
        rxBuf = 0
        status = [.txRDY, .txEmpty]
    }

    // MARK: - Save state

    /// Serialize internal state to a byte array.
    /// Layout: version(u8)=1, writeExpect(u8 0=mode,1=command), mode(u8),
    /// command(u8), status(u8), rxBuf(u8). 6 bytes.
    public func serializeState() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(6)
        out.append(1)
        out.append(writeExpect == .mode ? 0 : 1)
        out.append(mode)
        out.append(command)
        out.append(status.rawValue)
        out.append(rxBuf)
        return out
    }

    /// Restore from bytes produced by `serializeState()`. Tolerant of
    /// trailing bytes / unknown versions (returns without touching state).
    public func deserializeState(_ data: [UInt8]) {
        guard data.count >= 6, data[0] == 1 else { return }
        writeExpect = data[1] == 0 ? .mode : .command
        mode = data[2]
        command = data[3]
        status = Status(rawValue: data[4])
        rxBuf = data[5]
    }
}
