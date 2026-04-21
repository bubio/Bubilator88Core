/// i8214 behavioral model — 8-level priority interrupt controller.
///
/// Lower level number = higher priority.
/// Level 0 (RXRDY) is highest, Level 7 (INT7) is lowest.
///
/// Vector offset for IM2 dispatch: level * 2
public struct InterruptController {

    /// Interrupt source levels
    public enum Level: Int, CaseIterable, Sendable {
        case rxrdy = 0   // RS-232C receive ready
        case vrtc  = 1   // Vertical retrace (VSYNC)
        case rtc   = 2   // Real-time clock (1/600s)
        case int3  = 3   // User/expansion
        case sound = 4   // YM2608 OPNA timer
        case int5  = 5   // User/expansion
        case int6  = 6   // Expansion
        case int7  = 7   // Expansion
    }

    // MARK: - State

    /// Bitmask of pending interrupt levels (bit N = level N pending)
    public var pendingLevels: UInt8 = 0

    /// Level threshold (0-7). Only levels <= threshold can fire.
    /// Port 0xE4 bit 0-2.
    public var levelThreshold: UInt8 = 7

    /// SGS mode — priority mode toggle. Port 0xE4 bit 3.
    /// When true, auto-updates threshold on acknowledge.
    public var sgsMode: Bool = false

    /// Per-source masks (true = masked/disabled)
    /// Default: all masked (QUASI88: all sources disabled at power-on)
    public var maskRTC: Bool = true      // Port 0xE6 bit 0
    public var maskVRTC: Bool = true     // Port 0xE6 bit 1
    public var maskRXRDY: Bool = true    // Port 0xE6 bit 2
    public var maskSound: Bool = true    // Port 0x32 bit 7

    public init() {}

    // MARK: - Request / Clear

    /// Request an interrupt at the given level.
    /// Masked sources are ignored (QUASI88: flag not set when source disabled).
    public mutating func request(level: Level) {
        guard !isMasked(level: level.rawValue) else { return }
        pendingLevels |= (1 << level.rawValue)
    }

    /// Request an interrupt at the given level (by raw value).
    /// Masked sources are ignored (QUASI88: flag not set when source disabled).
    public mutating func request(level: Int) {
        guard level >= 0 && level <= 7 else { return }
        guard !isMasked(level: level) else { return }
        pendingLevels |= (1 << level)
    }

    /// Clear a pending interrupt (on acknowledge).
    /// QUASI88: intr_level = 0 on every acknowledge (intr.c:762)
    /// Blocks all further interrupts until ISR writes to port 0xE4.
    public mutating func acknowledge(level: Int) {
        guard level >= 0 && level <= 7 else { return }
        pendingLevels &= ~(1 << level)
        levelThreshold = 0
    }

    /// Clear all pending interrupts.
    public mutating func clearAll() {
        pendingLevels = 0
    }

    /// Lower a specific pending level without touching `levelThreshold`.
    /// Used when the source device's request line goes inactive before the
    /// CPU has had a chance to acknowledge (e.g. I8251 RxRDY dropping when
    /// the CPU reads the receive data port before the IRQ is serviced).
    public mutating func clearPending(level: Level) {
        pendingLevels &= ~(1 << level.rawValue)
    }

    // MARK: - Resolution

    /// Resolve the highest-priority active (unmasked, within threshold) interrupt.
    /// Returns (level, vectorOffset) or nil if no interrupt is active.
    /// QUASI88: intr_level == 0 → reject all; level N needs intr_level >= N+1 (N < levelThreshold).
    public func resolve() -> (level: Int, vectorOffset: UInt8)? {
        guard levelThreshold > 0 else { return nil }
        // Scan from highest priority (level 0) to lowest (level 7)
        for levelNum in 0...7 {
            guard pendingLevels & (1 << levelNum) != 0 else { continue }
            guard levelNum < Int(levelThreshold) else { continue }
            guard !isMasked(level: levelNum) else { continue }

            let vectorOffset = UInt8(levelNum * 2)
            return (level: levelNum, vectorOffset: vectorOffset)
        }
        return nil
    }

    // MARK: - Port I/O

    /// Write to port 0xE4: interrupt control register.
    /// bit 0-2: level threshold, bit 3: SGS mode
    public mutating func writeControlPort(_ value: UInt8) {
        sgsMode = (value & 0x08) != 0
        if sgsMode {
            levelThreshold = 7   // QUASI88: intr_level = 7 when priority bit set
        } else {
            levelThreshold = value & 0x07
        }
    }

    /// Write to port 0xE6: interrupt enable register.
    /// bit 0: RTC enable, bit 1: VRTC enable, bit 2: RXRDY enable
    /// 1 = enabled, 0 = disabled (masked).
    /// Disabling a source also clears its pending flag (QUASI88 confirmed).
    public mutating func writeMaskPort(_ value: UInt8) {
        maskRTC = (value & 0x01) == 0
        maskVRTC = (value & 0x02) == 0
        maskRXRDY = (value & 0x04) == 0

        // Clear pending flags for disabled sources (QUASI88: set flag=FALSE when disabled)
        if maskRTC { pendingLevels &= ~(1 << Level.rtc.rawValue) }
        if maskVRTC { pendingLevels &= ~(1 << Level.vrtc.rawValue) }
        if maskRXRDY { pendingLevels &= ~(1 << Level.rxrdy.rawValue) }
    }

    /// Reset to initial state.
    /// QUASI88: all interrupt sources disabled at power-on
    /// (intr_rtc_enable=0, intr_vsync_enable=0, SINTM=1).
    public mutating func reset() {
        pendingLevels = 0
        levelThreshold = 7
        sgsMode = false
        maskRTC = true       // QUASI88: intr_rtc_enable = 0x00
        maskVRTC = true      // QUASI88: intr_vsync_enable = 0x00
        maskRXRDY = true     // QUASI88: intr_sio_enable = 0x00
        maskSound = true     // QUASI88: misc_ctrl = 0x90 (SINTM=1)
    }

    // MARK: - Private

    private func isMasked(level: Int) -> Bool {
        switch level {
        case 0: return maskRXRDY
        case 1: return maskVRTC
        case 2: return maskRTC
        case 4: return maskSound
        default: return false  // INT3, INT5-7 have no mask
        }
    }
}
