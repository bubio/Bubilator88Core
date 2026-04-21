import Testing
@testable import EmulatorCore

@Suite("InterruptController (i8214) Tests")
struct InterruptControllerTests {

    // MARK: - Basic Priority

    @Test func highestPriorityWins() {
        var ic = InterruptController()
        ic.maskVRTC = false
        ic.maskSound = false

        ic.request(level: .vrtc)   // Level 1
        ic.request(level: .sound)  // Level 4

        let result = ic.resolve()
        #expect(result != nil)
        #expect(result?.level == 1)  // VRTC wins (lower number = higher priority)
        #expect(result?.vectorOffset == 0x02)  // 1*2 = 2
    }

    @Test func vectorOffsetCalculation() {
        var ic = InterruptController()
        ic.maskRXRDY = false
        ic.maskSound = false

        // Level 0 → 0*2 = 0x00
        ic.request(level: .rxrdy)
        #expect(ic.resolve()?.vectorOffset == 0x00)

        ic.clearAll()
        // Level 4 → 4*2 = 0x08
        ic.request(level: .sound)
        #expect(ic.resolve()?.vectorOffset == 0x08)

        ic.clearAll()
        // Level 6 → 6*2 = 0x0C
        // Note: level 7 cannot fire at threshold=7 (QUASI88: N < threshold)
        ic.request(level: .int6)
        #expect(ic.resolve()?.vectorOffset == 0x0C)
    }

    @Test func noPendingReturnsNil() {
        let ic = InterruptController()
        #expect(ic.resolve() == nil)
    }

    // MARK: - Masking

    @Test func maskedInterruptsAreSkipped() {
        var ic = InterruptController()
        ic.maskVRTC = true
        ic.maskSound = false

        ic.request(level: .vrtc)
        #expect(ic.resolve() == nil)  // VRTC is masked

        // Request unmasked source
        ic.request(level: .sound)
        let result = ic.resolve()
        #expect(result?.level == 4)  // Sound is not masked
    }

    @Test func maskedRequestIgnored() {
        // QUASI88: masked sources don't set pending flag at all
        var ic = InterruptController()
        ic.maskRTC = true

        ic.request(level: .rtc)
        #expect(ic.pendingLevels == 0)  // Should not be set

        ic.maskRTC = false
        ic.request(level: .rtc)
        #expect(ic.pendingLevels & (1 << 2) != 0)  // Now it should be set
    }

    @Test func rtcMasking() {
        var ic = InterruptController()
        ic.maskRTC = true

        ic.request(level: .rtc)
        #expect(ic.resolve() == nil)
        #expect(ic.pendingLevels == 0)  // Masked request doesn't set pending

        ic.maskRTC = false
        ic.request(level: .rtc)
        #expect(ic.resolve()?.level == 2)
    }

    @Test func soundMasking() {
        var ic = InterruptController()
        ic.maskSound = true

        ic.request(level: .sound)
        #expect(ic.resolve() == nil)
        #expect(ic.pendingLevels == 0)
    }

    @Test func rxrdyMasking() {
        var ic = InterruptController()
        ic.maskRXRDY = true

        ic.request(level: .rxrdy)
        #expect(ic.resolve() == nil)
        #expect(ic.pendingLevels == 0)
    }

    @Test func unmaskeableLevels() {
        var ic = InterruptController()
        // INT3, INT5-7 have no masks
        ic.request(level: .int3)
        #expect(ic.resolve()?.level == 3)
    }

    // MARK: - Level Threshold

    @Test func thresholdFiltersLowerPriority() {
        var ic = InterruptController()
        ic.maskSound = false
        ic.maskVRTC = false
        ic.levelThreshold = 2  // QUASI88: levels 0, 1 can fire (N < 2)

        ic.request(level: .sound)  // Level 4 — above threshold
        #expect(ic.resolve() == nil)

        ic.request(level: .vrtc)  // Level 1 — within threshold (1 < 2)
        #expect(ic.resolve()?.level == 1)
    }

    @Test func thresholdZeroRejectsAll() {
        // QUASI88: intr_level == 0 → reject all
        var ic = InterruptController()
        ic.maskRXRDY = false
        ic.maskVRTC = false
        ic.levelThreshold = 0

        ic.request(level: .vrtc)
        #expect(ic.resolve() == nil)

        ic.request(level: .rxrdy)  // Level 0
        #expect(ic.resolve() == nil)  // Even level 0 is rejected when threshold=0
    }

    @Test func thresholdExactBoundary() {
        // QUASI88: level N needs intr_level >= N+1, so threshold=3 allows 0,1,2 but NOT 3
        var ic = InterruptController()
        ic.levelThreshold = 3

        ic.request(level: .int3)  // Level 3 — exactly at threshold
        #expect(ic.resolve() == nil)  // 3 < 3 is false, so rejected

        ic.request(level: .rtc)  // Level 2 — below threshold
        ic.maskRTC = false
        ic.request(level: .rtc)
        #expect(ic.resolve()?.level == 2)  // 2 < 3 is true, so accepted
    }

    // MARK: - Acknowledge

    @Test func acknowledgeClearsPending() {
        var ic = InterruptController()
        ic.maskVRTC = false
        ic.maskSound = false

        ic.request(level: .vrtc)
        ic.request(level: .sound)

        // Acknowledge VRTC — also sets threshold to 0
        ic.acknowledge(level: 1)
        // After acknowledge, threshold=0 blocks everything
        #expect(ic.levelThreshold == 0)
        #expect(ic.resolve() == nil)

        // ISR writes to port 0xE4 to re-enable interrupts
        ic.writeControlPort(0x07)  // threshold=7
        let result = ic.resolve()
        #expect(result?.level == 4)  // Sound is now highest
    }

    @Test func acknowledgeAlwaysSetsThresholdZero() {
        // QUASI88: intr_level = 0 on every acknowledge, regardless of SGS mode
        var ic = InterruptController()
        ic.sgsMode = false
        ic.levelThreshold = 7

        ic.maskVRTC = false
        ic.request(level: .vrtc)
        ic.acknowledge(level: 1)

        #expect(ic.levelThreshold == 0)
    }

    @Test func acknowledgeSGSMode() {
        // Even in SGS mode, threshold is set to 0 (QUASI88 behavior)
        var ic = InterruptController()
        ic.sgsMode = true
        ic.levelThreshold = 7

        ic.maskVRTC = false
        ic.request(level: .vrtc)
        ic.acknowledge(level: 1)

        #expect(ic.levelThreshold == 0)
    }

    // MARK: - Port I/O

    @Test func controlPortWrite() {
        var ic = InterruptController()

        // Port 0xE4: threshold=5, SGS=0
        ic.writeControlPort(0x05)  // 0b00000101 = SGS(0) | threshold(5)
        #expect(ic.levelThreshold == 5)
        #expect(ic.sgsMode == false)

        // Port 0xE4: SGS=1 → threshold forced to 7 (QUASI88: intr_level = 7)
        ic.writeControlPort(0x0D)  // 0b00001101 = SGS(1) | lower bits(5)
        #expect(ic.levelThreshold == 7)
        #expect(ic.sgsMode == true)
    }

    @Test func controlPortSGSForcesThreshold7() {
        // Typical game ISR flow: acknowledge → OUT 0xE4, 0x08 → resolve
        var ic = InterruptController()
        ic.maskVRTC = false

        ic.request(level: .vrtc)
        ic.acknowledge(level: 1)
        #expect(ic.levelThreshold == 0)  // All blocked after acknowledge

        // ISR writes OUT (0xE4), 0x08 to re-enable interrupts
        ic.writeControlPort(0x08)  // SGS=1, lower bits=0
        #expect(ic.levelThreshold == 7)  // QUASI88: all levels allowed
        #expect(ic.sgsMode == true)

        // New VRTC can now fire
        ic.request(level: .vrtc)
        let result = ic.resolve()
        #expect(result?.level == 1)
    }

    @Test func controlPortSGSIgnoresLowerBits() {
        // When SGS bit is set, lower 3 bits are ignored for threshold
        var ic = InterruptController()

        ic.writeControlPort(0x0B)  // SGS=1, lower=3
        #expect(ic.levelThreshold == 7)
        #expect(ic.sgsMode == true)

        ic.writeControlPort(0x0F)  // SGS=1, lower=7
        #expect(ic.levelThreshold == 7)
        #expect(ic.sgsMode == true)

        ic.writeControlPort(0x08)  // SGS=1, lower=0
        #expect(ic.levelThreshold == 7)
        #expect(ic.sgsMode == true)
    }

    @Test func maskPortWrite() {
        var ic = InterruptController()

        // Port 0xE6: enable RTC + VRTC, disable RXRDY
        // bit=1 means enabled (unmasked), bit=0 means disabled (masked)
        ic.writeMaskPort(0x03)  // bit 0=RTC enable, bit 1=VRTC enable
        #expect(ic.maskRTC == false)    // enabled → not masked
        #expect(ic.maskVRTC == false)   // enabled → not masked
        #expect(ic.maskRXRDY == true)   // disabled → masked
    }

    // MARK: - Reset

    @Test func resetSetsAllMasked() {
        // QUASI88: all sources disabled at power-on
        var ic = InterruptController()
        ic.maskRTC = false
        ic.maskVRTC = false
        ic.maskSound = false
        ic.maskRXRDY = false
        ic.request(level: .vrtc)
        ic.levelThreshold = 3

        ic.reset()
        #expect(ic.pendingLevels == 0)
        #expect(ic.levelThreshold == 7)
        #expect(ic.maskRTC == true)      // Disabled at power-on
        #expect(ic.maskVRTC == true)     // Disabled at power-on
        #expect(ic.maskSound == true)    // Disabled at power-on (SINTM=1)
        #expect(ic.maskRXRDY == true)    // Disabled at power-on
        #expect(ic.sgsMode == false)
    }

    // MARK: - Priority Resolution

    @Test("Multiple pending interrupts resolve highest priority first")
    func multiplePendingResolvesHighestFirst() {
        var ic = InterruptController()
        ic.maskVRTC = false
        ic.maskRTC = false

        ic.request(level: .vrtc)   // Level 1
        ic.request(level: .rtc)    // Level 2

        // Resolve should return level 1 first (higher priority = lower number)
        let first = ic.resolve()
        #expect(first?.level == 1)

        // Acknowledge level 1, then re-enable via controlPort
        ic.acknowledge(level: 1)
        ic.writeControlPort(0x07)  // threshold=7

        // Now level 2 should resolve
        let second = ic.resolve()
        #expect(second?.level == 2)
    }

    @Test("Request during acknowledged state (threshold=0) is deferred")
    func requestDuringAcknowledgedStateIsDeferred() {
        var ic = InterruptController()
        ic.maskVRTC = false

        ic.request(level: .vrtc)
        ic.acknowledge(level: 1)  // threshold becomes 0

        // New request while threshold=0
        ic.request(level: .vrtc)

        // Should not resolve (threshold=0 blocks everything)
        #expect(ic.resolve() == nil)

        // Re-enable via controlPort
        ic.writeControlPort(0x07)  // threshold=7

        // Now it should resolve
        let result = ic.resolve()
        #expect(result?.level == 1)
    }

    @Test("Unmasking previously requested interrupt makes it pending")
    func unmaskingPreviouslyRequestedDoesNotRetroactivelyPend() {
        var ic = InterruptController()
        ic.maskVRTC = true  // Masked

        // Request while masked — QUASI88: flag not set
        ic.request(level: .vrtc)
        #expect(ic.pendingLevels == 0)

        // Unmask — the previous request was ignored, so still not pending
        ic.maskVRTC = false
        #expect(ic.pendingLevels == 0)
        #expect(ic.resolve() == nil)

        // Request again while unmasked — now it should be pending
        ic.request(level: .vrtc)
        #expect(ic.pendingLevels & (1 << 1) != 0)
        #expect(ic.resolve()?.level == 1)
    }

    @Test("Level 7 never resolves (only levels 0-6 valid)")
    func level7NeverResolves() {
        var ic = InterruptController()
        // INT7 has no mask, request it directly
        ic.request(level: .int7)
        #expect(ic.pendingLevels & (1 << 7) != 0)  // Pending bit is set

        // But resolve() requires level < threshold. Default threshold=7, so 7 < 7 is false.
        #expect(ic.resolve() == nil)

        // Even with maximum threshold, level 7 cannot resolve
        ic.levelThreshold = 7
        #expect(ic.resolve() == nil)

        // Only if we could set threshold > 7 would it work, but that's clamped
        ic.writeControlPort(0x08)  // SGS=1 → threshold=7
        #expect(ic.resolve() == nil)
    }
}
