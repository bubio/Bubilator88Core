/// Behavioral model of PC-8801 mouse input, read through the OPN/OPNA
/// general-purpose I/O ports.
///
/// The mouse has no dedicated I/O port; it is read through the OPN (YM2608)
/// general-purpose I/O ports (reg 0x0E = port A, reg 0x0F = port B). As in M88
/// (cisc) `mouse.cpp`, this one device contains **two read modes**:
///
/// 1. Bus mouse mode (`joyMode == false`): the genuine PC-8872 bus mouse.
///    - Strobe: toggling bit 6 (JOP1) of a port 0x40 write advances the phase
///    - reg 0x0E (port A) → X/Y relative movement, read as four nibbles
///      (phase 0: X high / 1: X low / 2: Y high / 3: Y low; low 4 bits carry
///      the value, high bits are `| 0xF0`)
///    - On entering phase 0 the accumulated movement is sign-flipped, clipped
///      to ±127, latched, and cleared
///    - If the gap between strobes exceeds a fixed T-state limit the sequence
///      is treated as abandoned and the phase resets to 0
///    Reference: BubiC `pc88.cpp` read_io8 case 0x45 / M88 `mouse.cpp`
///    GetMove/Strobe
///
/// 2. Joystick mode (`joyMode == true`): treats the mouse as an Atari-style
///    joystick, for games that read the OPN ports as a joystick. No strobe.
///    (No real title is currently known to need this mode; it exists for
///    future use. あーくしゅ works in bus mouse mode above, not this one.)
///    - reg 0x0E (port A) → accumulated movement converted to direction bits
///      (active low): bit0=up, bit1=down, bit2=left, bit3=right, high `| 0xF0`
///    - The latch is released on every VSync (one sample per frame)
///    Reference: M88 `mouse.cpp` GetMove joymode branch / QUASI88 joystick bit
///    layout
///
/// The buttons on reg 0x0F (port B) — left=bit0, right=bit1, negative logic,
/// high bits 0xFC — are common to both modes.
public final class Mouse {

  /// Port reads are only intercepted while the mouse is enabled.
  public var enabled: Bool = false

  /// true = joystick mode (mouse mapped to joystick direction bits),
  /// false = bus mouse mode (strobed four-nibble read).
  public var joyMode: Bool = false

  /// Dead zone for joystick mode: accumulated movement beyond this threshold
  /// sets a direction bit. Equivalent to M88's `sensibility`.
  public var joyThreshold: Int = 3

  /// Accumulated relative movement from the host, consumed on latch.
  private var dx: Int = 0
  private var dy: Int = 0

  /// Movement latched at phase 0, already sign-flipped and clipped.
  private var latchedX: Int = 0
  private var latchedY: Int = 0

  /// Current read phase (0-3). -1 means nothing has been latched yet.
  private var phase: Int = -1

  /// T-state of the previous strobe.
  private var lastStrobeTState: UInt64 = 0

  /// Button state (true = pressed).
  private var leftButton: Bool = false
  private var rightButton: Bool = false

  /// Direction byte latched in joystick mode. -1 means unlatched, so the next
  /// read recomputes it.
  private var joyLatch: Int = -1

  public init() {}

  /// Resets transient read state. `enabled` / `joyMode` are external
  /// configuration set by the host (settings) and are intentionally preserved
  /// across a machine reset.
  public func reset() {
    dx = 0
    dy = 0
    latchedX = 0
    latchedY = 0
    phase = -1
    lastStrobeTState = 0
    leftButton = false
    rightButton = false
    joyLatch = -1
  }

  /// Called by Machine on every vertical blank to release the joystick-mode
  /// latch, giving one sample per frame. Equivalent to M88 `Mouse::VSync`.
  public func vsync() {
    joyLatch = -1
  }

  // MARK: - Host input

  /// Accumulates relative mouse movement from the host. Called by the app layer.
  public func injectMovement(dx: Int, dy: Int) {
    self.dx += dx
    self.dy += dy
  }

  /// Sets the left and right button state.
  public func setButtons(left: Bool, right: Bool) {
    leftButton = left
    rightButton = right
  }

  // MARK: - Bus access

  /// Called when bit 6 (JOP1) of port 0x40 toggles. Advances the phase, and
  /// latches the accumulated movement on reaching phase 0.
  ///
  /// - Parameters:
  ///   - now: The current T-state.
  ///   - clock8MHz: CPU clock, which selects the strobe timeout width.
  public func strobe(now: UInt64, clock8MHz: Bool) {
    // Joystick mode does not use the strobe; advancing the phase is meaningless.
    guard !joyMode else { return }
    // Strobe timeout = (8MHz ? 1440 : 720) * 1.25 CPU clocks. On the Z80 one
    // CPU clock is essentially one T-state.
    let limit: UInt64 = clock8MHz ? 1800 : 900
    let elapsed = now &- lastStrobeTState

    if phase == -1 || elapsed > limit {
      phase = 0
    } else {
      phase = (phase + 1) & 3
    }

    if phase == 0 {
      latchedX = -Mouse.clip127(dx)
      latchedY = -Mouse.clip127(dy)
      dx = 0
      dy = 0
    }

    lastStrobeTState = now
  }

  /// Reads reg 0x0E (port A). Behaviour depends on the mode.
  public func readData() -> UInt8 {
    if joyMode {
      return readJoyDirection()
    }
    // Bus mouse mode: one X/Y nibble per phase.
    let value: Int
    switch phase {
    case 0: value = (latchedX >> 4) & 0x0F  // X high nibble
    case 1: value = latchedX & 0x0F          // X low nibble
    case 2: value = (latchedY >> 4) & 0x0F  // Y high nibble
    case 3: value = latchedY & 0x0F          // Y low nibble
    default: value = 0x0F
    }
    return UInt8(value) | 0xF0
  }

  /// Joystick-mode read of reg 0x0E: converts accumulated movement into
  /// active-low direction bits — bit0=up, bit1=down, bit2=left, bit3=right,
  /// high bits `| 0xF0`. Latched until the next VSync. Equivalent to the
  /// joymode branch of M88 `Mouse::GetMove` (binary, one sample per frame).
  private func readJoyDirection() -> UInt8 {
    if joyLatch == -1 {
      var d = 0xFF
      if dy <= -joyThreshold { d &= ~0x01 }  // up
      if dy >=  joyThreshold { d &= ~0x02 }  // down
      if dx <= -joyThreshold { d &= ~0x04 }  // left
      if dx >=  joyThreshold { d &= ~0x08 }  // right
      joyLatch = d
      dx = 0  // consume this frame's movement
      dy = 0
    }
    return UInt8(joyLatch)
  }

  /// Reads reg 0x0F (port B): left=bit0, right=bit1, negative logic, high bits
  /// fixed at 0xFC.
  public func readButtons() -> UInt8 {
    var buttons: UInt8 = 0
    if leftButton { buttons |= 0x01 }
    if rightButton { buttons |= 0x02 }
    return (~buttons & 0x03) | 0xFC
  }

  // MARK: - Helpers

  /// Clips to ±127.
  private static func clip127(_ v: Int) -> Int {
    return max(-127, min(127, v))
  }
}
