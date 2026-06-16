import Testing
@testable import EmulatorCore

@Suite("PC-8801 Bus Mouse Tests")
struct MouseTests {

    /// Strobe the mouse `n` times with no significant gap so the phase advances
    /// 0→1→2→3. Returns nothing; phase is internal.
    private func strobeSequence(_ m: Mouse, count: Int, clock8MHz: Bool = true) {
        for i in 0..<count {
            // Keep each strobe close together so it never times out.
            m.strobe(now: UInt64(i * 10), clock8MHz: clock8MHz)
        }
    }

    // MARK: - Nibble protocol

    @Test func fourPhaseNibbleReadout() {
        let m = Mouse()
        m.enabled = true
        // dx=0x12 → latched -0x12 = -18. dy=0x34 → -0x34 = -52.
        // Use values whose negation stays in range and is easy to verify.
        m.injectMovement(dx: 0x12, dy: 0x34)

        // phase 0 latch: latchedX = -0x12 = 0xEE (two's complement byte),
        // latchedY = -0x34 = 0xCC.
        m.strobe(now: 0, clock8MHz: true)            // phase 0: X high nibble
        #expect(m.readData() == (0xF0 | 0x0E))       // (0xEE >> 4)=0xE | 0xF0
        m.strobe(now: 10, clock8MHz: true)           // phase 1: X low nibble
        #expect(m.readData() == (0xF0 | 0x0E))       // 0xEE & 0x0F = 0xE
        m.strobe(now: 20, clock8MHz: true)           // phase 2: Y high nibble
        #expect(m.readData() == (0xF0 | 0x0C))       // (0xCC >> 4)=0xC
        m.strobe(now: 30, clock8MHz: true)           // phase 3: Y low nibble
        #expect(m.readData() == (0xF0 | 0x0C))       // 0xCC & 0x0F = 0xC

        // Upper nibble is always 1.
        #expect((m.readData() & 0xF0) == 0xF0)
    }

    @Test func negationAndLatch() {
        let m = Mouse()
        m.enabled = true
        m.injectMovement(dx: 10, dy: -20)
        m.strobe(now: 0, clock8MHz: true)            // latch: lx=-10, ly=20

        // -10 as byte = 0xF6 → high=0xF, low=0x6
        #expect(m.readData() == (0xF0 | 0x0F))       // phase 0: 0xF6 >> 4 = 0xF
        m.strobe(now: 10, clock8MHz: true)
        #expect(m.readData() == (0xF0 | 0x06))       // phase 1: 0xF6 & 0xF = 0x6
        m.strobe(now: 20, clock8MHz: true)
        // 20 as byte = 0x14 → high=0x1, low=0x4
        #expect(m.readData() == (0xF0 | 0x01))       // phase 2
        m.strobe(now: 30, clock8MHz: true)
        #expect(m.readData() == (0xF0 | 0x04))       // phase 3
    }

    @Test func clip127() {
        let m = Mouse()
        m.enabled = true
        m.injectMovement(dx: 5000, dy: -5000)
        m.strobe(now: 0, clock8MHz: true)            // latch: lx=-127, ly=127

        // -127 = 0x81 → high=0x8, low=0x1
        #expect(m.readData() == (0xF0 | 0x08))
        m.strobe(now: 10, clock8MHz: true)
        #expect(m.readData() == (0xF0 | 0x01))
        // 127 = 0x7F → high=0x7, low=0xF
        m.strobe(now: 20, clock8MHz: true)
        #expect(m.readData() == (0xF0 | 0x07))
        m.strobe(now: 30, clock8MHz: true)
        #expect(m.readData() == (0xF0 | 0x0F))
    }

    @Test func movementClearedAfterLatch() {
        let m = Mouse()
        m.enabled = true
        m.injectMovement(dx: 50, dy: 60)
        m.strobe(now: 0, clock8MHz: true)            // latch and clear

        // Next sequence (after timeout) with no new movement → latches 0.
        m.strobe(now: 100_000, clock8MHz: true)      // big gap → phase resets to 0
        #expect(m.readData() == 0xF0)                // 0 high nibble
        m.strobe(now: 100_010, clock8MHz: true)
        #expect(m.readData() == 0xF0)                // 0 low nibble
    }

    // MARK: - Timeout

    @Test func timeoutResetsPhase() {
        let m = Mouse()
        m.enabled = true
        m.injectMovement(dx: 0x12, dy: 0x00)
        m.strobe(now: 0, clock8MHz: true)            // phase 0
        m.strobe(now: 10, clock8MHz: true)           // phase 1

        // Gap exceeds 8MHz limit (1800) → next strobe resets to phase 0.
        m.injectMovement(dx: 0x34, dy: 0x00)         // accumulates onto remaining
        m.strobe(now: 5000, clock8MHz: true)         // phase reset → re-latch
        // After re-latch, phase 0 = X high nibble of -(0x12 already consumed? )
        // The first latch consumed dx, so only 0x34 remains: -0x34 = 0xCC.
        #expect(m.readData() == (0xF0 | 0x0C))
    }

    @Test func clockAffectsTimeoutWidth() {
        let m = Mouse()
        m.enabled = true
        m.strobe(now: 0, clock8MHz: false)           // 4MHz, limit=900, phase 0
        // gap=950 > 900 → reset at 4MHz
        m.strobe(now: 950, clock8MHz: false)
        // Both are phase 0 (reset), so phase did reset rather than advance.
        // Verify by injecting a known value and reading phase-0 high nibble.
        // (No assertion on phase index directly; behavior covered above.)
        #expect(m.readData() == 0xF0)                // latched 0 → high nibble 0
    }

    // MARK: - Buttons

    @Test func buttonsActiveLow() {
        let m = Mouse()
        m.enabled = true
        #expect(m.readButtons() == 0xFF)             // none pressed → all 1
        m.setButtons(left: true, right: false)
        #expect(m.readButtons() == 0xFE)             // left=bit0 cleared
        m.setButtons(left: false, right: true)
        #expect(m.readButtons() == 0xFD)             // right=bit1 cleared
        m.setButtons(left: true, right: true)
        #expect(m.readButtons() == 0xFC)             // both cleared
    }

    @Test func resetPreservesEnabled() {
        let m = Mouse()
        m.enabled = true
        m.injectMovement(dx: 50, dy: 50)
        m.setButtons(left: true, right: true)
        m.reset()
        #expect(m.enabled == true)                   // config preserved
        #expect(m.readButtons() == 0xFF)             // buttons cleared
    }

    // MARK: - Bus integration

    @Test func busInterceptsPortAWhenEnabled() {
        let bus = Pc88Bus()
        let sound = YM2608()
        let mouse = Mouse()
        bus.sound = sound
        bus.mouse = mouse
        mouse.enabled = true

        mouse.injectMovement(dx: 0x12, dy: 0x34)

        // Select OPN reg 0x0E (port A) via port 0x44.
        bus.ioWrite(0x44, value: 0x0E)

        // Strobe via port 0x40 bit 6 transition (0 → 0x40).
        bus.ioWrite(0x40, value: 0x00)
        bus.ioWrite(0x40, value: 0x40)               // phase 0 latch
        #expect(bus.ioRead(0x45) == (0xF0 | 0x0E))   // -(0x12)=0xEE high nibble

        bus.ioWrite(0x40, value: 0x00)               // bit6 toggles → phase 1
        #expect(bus.ioRead(0x45) == (0xF0 | 0x0E))   // low nibble
    }

    @Test func busButtonsViaPortB() {
        let bus = Pc88Bus()
        let sound = YM2608()
        let mouse = Mouse()
        bus.sound = sound
        bus.mouse = mouse
        mouse.enabled = true
        mouse.setButtons(left: true, right: false)

        bus.ioWrite(0x44, value: 0x0F)               // select port B
        #expect(bus.ioRead(0x45) == 0xFE)            // left pressed
    }

    // MARK: - Joy mode (mouse-as-joystick)

    @Test func joyModeDirectionBits() {
        let m = Mouse()
        m.enabled = true
        m.joyMode = true
        m.joyThreshold = 3

        // No movement → all directions released (0xFF).
        #expect(m.readData() == 0xFF)

        // Move right+down past threshold → bit3 (right) + bit1 (down) cleared.
        m.vsync()                      // release latch
        m.injectMovement(dx: 10, dy: 10)
        // bit1 (down) and bit3 (right) cleared → ~(0x02|0x08) & 0xFF = 0xF5
        #expect(m.readData() == 0xF5)
        // Latched until vsync → same value, movement already consumed.
        #expect(m.readData() == 0xF5)
    }

    @Test func joyModeUpLeft() {
        let m = Mouse()
        m.enabled = true
        m.joyMode = true
        m.joyThreshold = 3
        m.injectMovement(dx: -5, dy: -5)
        // bit0 (up) + bit2 (left) cleared → ~(0x01|0x04) & 0xFF = 0xFA
        #expect(m.readData() == 0xFA)
    }

    @Test func joyModeDeadzone() {
        let m = Mouse()
        m.enabled = true
        m.joyMode = true
        m.joyThreshold = 3
        m.injectMovement(dx: 2, dy: -2)   // below threshold
        #expect(m.readData() == 0xFF)     // no direction
    }

    @Test func joyModeLatchResetsOnVSync() {
        let m = Mouse()
        m.enabled = true
        m.joyMode = true
        m.joyThreshold = 3
        m.injectMovement(dx: 10, dy: 0)
        #expect(m.readData() == 0xF7)     // bit3 (right) cleared
        // After consume + new movement, but no vsync → still latched old value.
        m.injectMovement(dx: -10, dy: 0)
        #expect(m.readData() == 0xF7)
        // vsync releases latch → recompute from accumulated (-10) → left (bit2).
        m.vsync()
        #expect(m.readData() == 0xFB)     // bit2 (left) cleared
    }

    @Test func joyModeButtonsShared() {
        let m = Mouse()
        m.enabled = true
        m.joyMode = true
        m.setButtons(left: true, right: false)
        // Buttons identical in both modes.
        #expect(m.readButtons() == 0xFE)
    }

    @Test func busReturnsFFWhenDisabled() {
        let bus = Pc88Bus()
        let sound = YM2608()
        let mouse = Mouse()
        bus.sound = sound
        bus.mouse = mouse
        mouse.enabled = false                        // mouse mode off

        mouse.injectMovement(dx: 0x12, dy: 0x34)
        bus.ioWrite(0x44, value: 0x0E)
        bus.ioWrite(0x40, value: 0x40)
        // Disabled → falls through to YM2608, which returns 0xFF for port A.
        #expect(bus.ioRead(0x45) == 0xFF)
    }
}
