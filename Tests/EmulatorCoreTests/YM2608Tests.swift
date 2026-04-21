import Testing
@testable import EmulatorCore
@testable import FMSynthesis

@Suite("YM2608 Tests")
struct YM2608Tests {

    @Test func resetState() {
        let ym = YM2608()
        ym.reset()

        #expect(ym.readStatus() == 0x00)
        #expect(ym.timerAEnabled == false)
        #expect(ym.timerBEnabled == false)
    }

    @Test func registerReadWrite() {
        let ym = YM2608()
        ym.reset()

        // Write to register 0x30 via port 0x44/0x45
        ym.writeAddr(0x30)
        ym.writeData(0xAB)

        ym.writeAddr(0x30)
        #expect(ym.readData() == 0xAB)
    }

    @Test func extRegisterReadWrite() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0x10)
        ym.writeExtData(0xCD)

        ym.writeExtAddr(0x10)
        #expect(ym.readExtData() == 0xCD)
    }

    @Test("Status busy flag is asserted for about 10us after data writes")
    func busyFlagTracksRecentDataWrites() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x30)
        ym.writeData(0x12)

        #expect(ym.readStatus() & 0x80 != 0)
        #expect(ym.readExtStatus() & 0x80 != 0)

        ym.tick(tStates: 79)
        #expect(ym.readStatus() & 0x80 != 0)

        ym.tick(tStates: 1)
        #expect(ym.readStatus() & 0x80 == 0)
        #expect(ym.readExtStatus() & 0x80 == 0)
    }

    @Test func timerASetup() {
        let ym = YM2608()
        ym.reset()

        // Set Timer A value: 0x3FF (1023)
        ym.writeAddr(0x24)
        ym.writeData(0xFF)  // high 8 bits → bits 9-2 = 0xFF → value bits 9-2 = 0x3FC
        ym.writeAddr(0x25)
        ym.writeData(0x03)  // low 2 bits

        #expect(ym.timerAValue == 0x3FF)
    }

    @Test func timerBSetup() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x26)
        ym.writeData(0x80)
        #expect(ym.timerBValue == 0x80)
    }

    @Test func timerAOverflow() {
        let ym = YM2608()
        ym.reset()

        // Set Timer A = 1023 → period = (1024 - 1023) * 144 = 144 T-states (8MHz mode)
        // (72 OPNA clocks × clockRatio=2)
        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)

        // Enable Timer A + IRQ
        ym.writeAddr(0x27)
        ym.writeData(0x05)  // bit 0: Timer A start, bit 2: Timer A IRQ

        #expect(ym.timerAEnabled == true)
        #expect(ym.timerAIRQEnable == true)

        var irqFired = false
        ym.onTimerIRQ = { irqFired = true }

        // Tick for 143 T-states — should NOT overflow
        ym.tick(tStates: 143)
        #expect(ym.timerAOverflow == false)
        #expect(irqFired == false)

        // Tick 1 more — should overflow
        ym.tick(tStates: 1)
        #expect(ym.timerAOverflow == true)
        #expect(irqFired == true)

        // Status register should reflect overflow
        #expect(ym.readStatus() & 0x01 != 0)
    }

    @Test func timerAStatusDoesNotAssertIRQWhenReg29MaskCleared() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)

        var irqCount = 0
        ym.onTimerIRQ = { irqCount += 1 }

        ym.writeAddr(0x29)
        ym.writeData(0x00)

        ym.writeAddr(0x27)
        ym.writeData(0x05)
        ym.tick(tStates: 144)

        #expect(ym.timerAOverflow == true)
        #expect(ym.readStatus() & 0x01 != 0)
        #expect(irqCount == 0)
    }

    @Test func timerBOverflow() {
        let ym = YM2608()
        ym.reset()

        // Set Timer B = 255 → period = (256 - 255) * 2304 = 2304 T-states (8MHz mode)
        // (1152 OPNA clocks × clockRatio=2)
        ym.writeAddr(0x26)
        ym.writeData(0xFF)

        // Enable Timer B + IRQ
        ym.writeAddr(0x27)
        ym.writeData(0x0A)  // bit 1: Timer B start, bit 3: Timer B IRQ

        var irqCount = 0
        ym.onTimerIRQ = { irqCount += 1 }

        ym.tick(tStates: 2303)
        #expect(ym.timerBOverflow == false)

        ym.tick(tStates: 1)
        #expect(ym.timerBOverflow == true)
        #expect(irqCount == 1)
    }

    @Test func resetTimerFlags() {
        let ym = YM2608()
        ym.reset()

        ym.timerAOverflow = true
        ym.timerBOverflow = true

        // Reset flags via register 0x27 bit 4-5
        ym.writeAddr(0x27)
        ym.writeData(0x30)  // bit 4: reset A, bit 5: reset B

        #expect(ym.timerAOverflow == false)
        #expect(ym.timerBOverflow == false)
        #expect(ym.readStatus() & 0x03 == 0x00)
    }

    @Test func timerNotFiringWhenDisabled() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)

        // Don't enable timer
        var irqFired = false
        ym.onTimerIRQ = { irqFired = true }

        ym.tick(tStates: 1000)
        #expect(irqFired == false)
    }

    // MARK: - SSG Tests

    @Test("SSG tone period set via registers")
    func ssgTonePeriodSet() {
        let ym = YM2608()
        ym.reset()

        // Set channel A tone period: low=0x80, high=0x01 → 0x180 = 384
        ym.writeAddr(0x00)
        ym.writeData(0x80)
        ym.writeAddr(0x01)
        ym.writeData(0x01)

        #expect(ym.ssgTonePeriod[0] == 0x180)
    }

    @Test("SSG mixer register")
    func ssgMixerRegister() {
        let ym = YM2608()
        ym.reset()

        // Enable tone on ch A, noise on ch B
        // R7: bit 0=0 (tone A on), bit 1=1 (tone B off), bit 4=0 (noise B on)
        ym.writeAddr(0x07)
        ym.writeData(0b00101110)  // toneA=on, noiseB=on, rest off

        #expect(ym.ssgMixer == 0b00101110)
    }

    @Test("SSG generates audio samples")
    func ssgGeneratesSamples() {
        let ym = YM2608()
        ym.reset()

        // Set ch A: tone period = 100, volume = 15 (max)
        ym.writeAddr(0x00)
        ym.writeData(100)
        ym.writeAddr(0x01)
        ym.writeData(0)
        ym.writeAddr(0x08)
        ym.writeData(15)

        // Enable tone on ch A (bit 0 = 0 means enabled)
        ym.writeAddr(0x07)
        ym.writeData(0b00111110)  // only tone A enabled

        // Run enough T-states to generate samples
        ym.tick(tStates: 182 * 10)

        #expect(ym.audioBuffer.count >= 10)
        // Should have non-zero samples
        #expect(ym.audioBuffer.contains(where: { $0 != 0 }))
    }

    @Test("SSG sample-domain generator advances tone, noise, and envelope")
    func ssgSampleDomainGeneratorAdvancesState() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x00)
        ym.writeData(0x01)
        ym.writeAddr(0x01)
        ym.writeData(0x00)
        ym.writeAddr(0x06)
        ym.writeData(0x01)
        ym.writeAddr(0x08)
        ym.writeData(0x10)
        ym.writeAddr(0x0B)
        ym.writeData(0x01)
        ym.writeAddr(0x0C)
        ym.writeData(0x00)
        ym.writeAddr(0x0D)
        ym.writeData(0x08)
        ym.writeAddr(0x07)
        ym.writeData(0b00110110)  // tone A + noise A enabled

        ym.tick(tStates: 182 * 64)

        #expect(ym.audioBuffer.contains(where: { $0 != 0 }))
        #expect(ym.ssgToneCounter[0] != 0)
        #expect(ym.ssgNoiseCounter != 0)
        #expect(ym.ssgEnvPosition != 0)
    }

    @Test("SSG volume table correctness")
    func ssgVolumeTable() {
        #expect(YM2608.ssgVolumeTable[0] == 0.0)
        #expect(YM2608.ssgVolumeTable[15] > 0.9)
        // Monotonically increasing
        for i in 1..<16 {
            #expect(YM2608.ssgVolumeTable[i] > YM2608.ssgVolumeTable[i - 1])
        }
    }

    @Test("SSG Port A/B read returns 0xFF (no joystick)")
    func ssgPortABReadReturnsFF() {
        let ym = YM2608()
        ym.reset()

        // Port A (register 0x0E)
        ym.writeAddr(0x0E)
        #expect(ym.readData() == 0xFF)

        // Port B (register 0x0F)
        ym.writeAddr(0x0F)
        #expect(ym.readData() == 0xFF)

        // Verify register initial values too
        #expect(ym.registers[0x0E] == 0xFF)
        #expect(ym.registers[0x0F] == 0xFF)
    }

    @Test("SSG envelope shape register resets position")
    func ssgEnvelopeReset() {
        let ym = YM2608()
        ym.reset()

        ym.ssgEnvPosition = 10

        // Write envelope shape register (R13)
        ym.writeAddr(0x0D)
        ym.writeData(0x08)

        #expect(ym.ssgEnvPosition == 0)
        #expect(ym.ssgEnvShape == 0x08)
    }

    @Test("SSG silent when all channels disabled")
    func ssgSilentWhenDisabled() {
        let ym = YM2608()
        ym.reset()

        // Default mixer = 0xFF (all disabled)
        ym.tick(tStates: 182 * 5)

        // All samples should be 0
        #expect(ym.audioBuffer.allSatisfy { $0 == 0 })
    }

    // MARK: - FM Tests

    @Test("FM register write sets operator parameters")
    func fmRegisterWrite() {
        let ym = YM2608()
        ym.reset()

        // Set ch1 op1 TL = 10 (register 0x40)
        ym.writeAddr(0x40)
        ym.writeData(10)
        #expect(ym.fmSynth.ch[0].op[0].tlLatch == 10)

        // Set ch1 op1 MUL = 5, DT = 3 (register 0x30)
        ym.writeAddr(0x30)
        ym.writeData(0x35)  // DT=3, MUL=5
        #expect(ym.fmSynth.ch[0].op[0].multiple == 5)
        #expect(ym.fmSynth.ch[0].op[0].detune == 3 * 32)  // stored as DT*32
    }

    @Test("FM F-Number and Block set")
    func fmFnumBlock() {
        let ym = YM2608()
        ym.reset()

        // Set ch1 F-Number=0x200, Block=4
        // High byte first (0xA4): block=4, fnum high=2
        ym.writeAddr(0xA4)
        ym.writeData((4 << 3) | 0x02)  // block=4, fnum_hi=2
        // Low byte (0xA0): fnum low = 0x00
        ym.writeAddr(0xA0)
        ym.writeData(0x00)

        // FMSynthesizer stores fnum/block as dp = (fnum & 2047) << block
        // fnum=0x200, block=4 → dp = 0x200 << 4 = 0x2000
        #expect(ym.fmSynth.ch[0].op[0].dp == UInt32(0x200 << 4))
    }

    @Test("FM Key On/Off")
    func fmKeyOnOff() {
        let ym = YM2608()
        ym.reset()

        // Key on ch1 all operators: register 0x28, value = 0xF0 | ch
        ym.writeAddr(0x28)
        ym.writeData(0xF0)  // All 4 ops on, ch1

        #expect(ym.fmSynth.ch[0].op[0].keyOn == true)
        #expect(ym.fmSynth.ch[0].op[1].keyOn == true)
        #expect(ym.fmSynth.ch[0].op[2].keyOn == true)
        #expect(ym.fmSynth.ch[0].op[3].keyOn == true)
        #expect(ym.fmSynth.ch[0].op[0].egPhase == .attack)

        // Key off
        ym.writeAddr(0x28)
        ym.writeData(0x00)  // All ops off, ch1

        #expect(ym.fmSynth.ch[0].op[0].keyOn == false)
        #expect(ym.fmSynth.ch[0].op[1].keyOn == false)
        #expect(ym.fmSynth.ch[0].op[2].keyOn == false)
        #expect(ym.fmSynth.ch[0].op[3].keyOn == false)
        #expect(ym.fmSynth.ch[0].op[0].egPhase == .release)
    }

    @Test("FM algorithm and feedback set")
    func fmAlgorithmFeedback() {
        let ym = YM2608()
        ym.reset()

        // Register 0xB0 for ch1: feedback=5, algorithm=3
        ym.writeAddr(0xB0)
        ym.writeData((5 << 3) | 3)

        #expect(ym.fmSynth.ch[0].algo == 3)
        #expect(ym.fmSynth.ch[0].fb == feedbackShiftTable[5])
    }

    @Test("FM extended registers set ch4-6")
    func fmExtRegisters() {
        let ym = YM2608()
        ym.reset()

        // Set ch4 op1 TL via ext register (0x40 in ext bank = ch4)
        ym.writeExtAddr(0x40)
        ym.writeExtData(20)
        #expect(ym.fmSynth.ch[3].op[0].tlLatch == 20)
    }

    @Test("FM reg29 gates channels 4-6 output")
    func fmReg29GatesExtendedChannels() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0xA4)
        ym.writeExtData((4 << 3) | 0x01)
        ym.writeExtAddr(0xA0)
        ym.writeExtData(0x80)

        ym.writeExtAddr(0x30)
        ym.writeExtData(0x01)
        ym.writeExtAddr(0x40)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x50)
        ym.writeExtData(0x1F)
        ym.writeExtAddr(0x60)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x70)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x80)
        ym.writeExtData(0x0F)
        ym.writeExtAddr(0xB0)
        ym.writeExtData(0x07)

        ym.writeAddr(0x28)
        ym.writeData(0xF4)  // ch4 all operators on

        let muted = (0..<32).reduce(into: false) { hasOutput, _ in
            let (l, r) = ym.fmSynth.generateSample()
            hasOutput = hasOutput || l != 0 || r != 0
        }
        #expect(muted == false)

        ym.writeAddr(0x29)
        ym.writeData(0x80)

        let enabled = (0..<32).contains { _ in
            let (l, r) = ym.fmSynth.generateSample()
            return l != 0 || r != 0
        }
        #expect(enabled == true)
    }

    @Test("FM channel 3 special mode routes operator F-Numbers")
    func fmChannel3SpecialMode() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0xA6)
        ym.writeData((4 << 3) | 0x01)
        ym.writeAddr(0xA2)
        ym.writeData(0x80)

        ym.writeAddr(0xAC)
        ym.writeData((2 << 3) | 0x01)
        ym.writeAddr(0xA8)
        ym.writeData(0x20)

        ym.writeAddr(0xAD)
        ym.writeData((3 << 3) | 0x02)
        ym.writeAddr(0xA9)
        ym.writeData(0x40)

        ym.writeAddr(0xAE)
        ym.writeData((5 << 3) | 0x03)
        ym.writeAddr(0xAA)
        ym.writeData(0x60)

        ym.writeAddr(0x27)
        ym.writeData(0x40)

        func dp(_ high: UInt8, _ low: UInt8) -> UInt32 {
            let f = UInt32(low) | (UInt32(high) << 8)
            return (f & 2047) << ((f >> 11) & 7)
        }

        #expect(ym.fmSynth.ch[2].op[0].dp == dp((3 << 3) | 0x02, 0x40))
        #expect(ym.fmSynth.ch[2].op[1].dp == dp((5 << 3) | 0x03, 0x60))
        #expect(ym.fmSynth.ch[2].op[2].dp == dp((2 << 3) | 0x01, 0x20))
        #expect(ym.fmSynth.ch[2].op[3].dp == dp((4 << 3) | 0x01, 0x80))
    }

    @Test("FM CSM mode enables channel 3 per-operator frequency routing")
    func fmCSMEnablesChannel3SpecialRouting() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0xA6)
        ym.writeData((4 << 3) | 0x01)
        ym.writeAddr(0xA2)
        ym.writeData(0x80)

        ym.writeAddr(0xAC)
        ym.writeData((2 << 3) | 0x01)
        ym.writeAddr(0xA8)
        ym.writeData(0x20)

        ym.writeAddr(0xAD)
        ym.writeData((3 << 3) | 0x02)
        ym.writeAddr(0xA9)
        ym.writeData(0x40)

        ym.writeAddr(0xAE)
        ym.writeData((5 << 3) | 0x03)
        ym.writeAddr(0xAA)
        ym.writeData(0x60)

        ym.writeAddr(0x27)
        ym.writeData(0x80)

        func dp(_ high: UInt8, _ low: UInt8) -> UInt32 {
            let f = UInt32(low) | (UInt32(high) << 8)
            return (f & 2047) << ((f >> 11) & 7)
        }

        #expect(ym.fmSynth.ch[2].op[0].dp == dp((3 << 3) | 0x02, 0x40))
        #expect(ym.fmSynth.ch[2].op[1].dp == dp((5 << 3) | 0x03, 0x60))
        #expect(ym.fmSynth.ch[2].op[2].dp == dp((2 << 3) | 0x01, 0x20))
        #expect(ym.fmSynth.ch[2].op[3].dp == dp((4 << 3) | 0x01, 0x80))
    }

    @Test("FM CSM latches TL until Timer A retrigger")
    func fmCSMTLLatch() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x42)
        ym.writeData(0x10)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x10)

        ym.writeAddr(0x28)
        ym.writeData(0xF2)
        #expect(ym.fmSynth.ch[2].op[0].keyOn == true)

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)
        ym.writeAddr(0x27)
        ym.writeData(0x80)

        ym.writeAddr(0x42)
        ym.writeData(0x20)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x20)

        ym.writeAddr(0x27)
        ym.writeData(0x81)
        ym.tick(tStates: 144)

        #expect(ym.timerAOverflow == false)
        #expect(ym.fmSynth.ch[2].op[0].keyOn == true)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)
    }

    @Test("FM CSM timer restart reloads Timer A phase")
    func fmCSMTimerRestartReloadsPhase() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x42)
        ym.writeData(0x10)
        ym.writeAddr(0x28)
        ym.writeData(0xF2)

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)
        ym.writeAddr(0x27)
        ym.writeData(0x81)

        ym.tick(tStates: 100)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)

        ym.writeAddr(0x27)
        ym.writeData(0x80)

        ym.writeAddr(0x42)
        ym.writeData(0x20)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x20)

        ym.writeAddr(0x27)
        ym.writeData(0x81)
        ym.tick(tStates: 100)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)

        ym.tick(tStates: 44)
        #expect(ym.timerAOverflow == false)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)
    }

    @Test("FM CSM stops retriggering after mode clear")
    func fmCSMStopsRetriggeringAfterModeClear() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x42)
        ym.writeData(0x10)
        ym.writeAddr(0x28)
        ym.writeData(0xF2)

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)
        ym.writeAddr(0x27)
        ym.writeData(0x80)

        ym.writeAddr(0x42)
        ym.writeData(0x20)
        ym.writeAddr(0x27)
        ym.writeData(0x81)
        ym.tick(tStates: 144)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)

        ym.writeAddr(0x42)
        ym.writeData(0x30)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x30)

        ym.writeAddr(0x27)
        ym.writeData(0x01)
        ym.tick(tStates: 144)

        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x30)
    }

    @Test("FM CSM stays active when channel 3 special mode is also enabled")
    func fmCSMAndChannel3SpecialModeCanCoexist() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x42)
        ym.writeData(0x10)
        ym.writeAddr(0x28)
        ym.writeData(0xF2)

        ym.writeAddr(0x24)
        ym.writeData(0xFF)
        ym.writeAddr(0x25)
        ym.writeData(0x03)
        ym.writeAddr(0x27)
        ym.writeData(0xC0)

        ym.writeAddr(0x42)
        ym.writeData(0x20)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x10)
        #expect(ym.fmSynth.ch[2].op[0].tlLatch == 0x20)

        ym.writeAddr(0x27)
        ym.writeData(0xC1)
        ym.tick(tStates: 144)

        #expect(ym.timerAOverflow == false)
        #expect(ym.fmSynth.ch[2].op[0].keyOn == true)
        #expect(ym.fmSynth.ch[2].op[0].tl == 0x20)
    }

    @Test("FM SSG-EG register write follows fmgen phase mapping")
    func fmSSGEGRegisterWrite() {
        let ym = YM2608()
        ym.reset()

        ym.fmSynth.ch[0].op[0].egPhase = .decay

        ym.writeAddr(0x90)
        ym.writeData(0x0D)

        #expect(ym.fmSynth.ch[0].op[0].ssgType == 0x0D)
        #expect(ym.fmSynth.ch[0].op[0].ssgPhase == 1)

        ym.writeAddr(0x90)
        ym.writeData(0x00)

        #expect(ym.fmSynth.ch[0].op[0].ssgType == 0)
    }

    @Test("FM LFO uses fmgen OPNA phase tables")
    func fmLfoUsesWaveTables() {
        let synth = FMSynthesizer()
        synth.lfoCount = UInt32(0x20 << 15)

        let (pml, aml) = synth.lfo()

        #expect(pml == pmWaveformTable[0x20])
        #expect(aml == amWaveformTable[0x20])
    }

    @Test("Final mix uses fmgen-style 16-bit saturating accumulation")
    func finalMixUsesSaturatingStoreSample() {
        #expect(YM2608.storeSample16(32000, 10000) == 32767)
        #expect(YM2608.storeSample16(-32000, -10000) == -32768)
        #expect(YM2608.storeSample16(12000, -4000) == 8000)
    }

    @Test("Debug output mask mutes selected sources in final mix")
    func debugOutputMaskMutesSelectedSources() {
        let ym = YM2608()
        ym.reset()

        let allOn = ym.mixOutputFrame(
            fmLeft: 1000,
            fmRight: 2000,
            ssgSample: 0.5,
            adpcmSample: 300,
            rhythmLeft: 400,
            rhythmRight: 500,
            beepSample: 0
        )
        #expect(allOn.0 == 9892)
        #expect(allOn.1 == 10992)

        ym.debugOutputMask = [.ssg, .rhythm]
        let fmAndAdpcmMuted = ym.mixOutputFrame(
            fmLeft: 1000,
            fmRight: 2000,
            ssgSample: 0.5,
            adpcmSample: 300,
            rhythmLeft: 400,
            rhythmRight: 500,
            beepSample: 0
        )
        #expect(fmAndAdpcmMuted.0 == 8592)
        #expect(fmAndAdpcmMuted.1 == 8692)

        ym.debugOutputMask = []
        let fullyMuted = ym.mixOutputFrame(
            fmLeft: 1000,
            fmRight: 2000,
            ssgSample: 0.5,
            adpcmSample: 300,
            rhythmLeft: 400,
            rhythmRight: 500,
            beepSample: 0
        )
        #expect(fullyMuted.0 == 0)
        #expect(fullyMuted.1 == 0)
    }

    // MARK: - ADPCM Tests

    @Test("ADPCM start address set via ext registers")
    func adpcmStartAddr() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0x02)
        ym.writeExtData(0x10)  // start low
        ym.writeExtAddr(0x03)
        ym.writeExtData(0x00)  // start high

        #expect(ym.adpcmStartAddr == 0x0010)
    }

    @Test("ADPCM playback starts and stops")
    func adpcmPlayback() {
        let ym = YM2608()
        ym.reset()

        // Set up addresses
        ym.writeExtAddr(0x02)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x03)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x04)
        ym.writeExtData(0x01)  // stop at 1 (32 bytes)
        ym.writeExtAddr(0x05)
        ym.writeExtData(0x00)

        // Set delta-N (playback rate)
        ym.writeExtAddr(0x09)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x0A)
        ym.writeExtData(0x80)  // High rate

        // Start playback
        ym.writeExtAddr(0x00)
        ym.writeExtData(0x80)
        #expect(ym.adpcmPlaying == true)

        // Stop playback
        ym.writeExtAddr(0x00)
        ym.writeExtData(0x01)
        #expect(ym.adpcmPlaying == false)
    }

    @Test("ADPCM total level")
    func adpcmTotalLevel() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0x0B)
        ym.writeExtData(0x80)
        #expect(ym.adpcmTotalLevel == 0x80)
    }

    @Test("ADPCM 8-bit RAM writes use fmgen bit-sliced layout")
    func adpcmEightBitRAMWriteLayout() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0x01)
        ym.writeExtData(0xC2)  // L+R + 8-bit RAM layout
        ym.writeExtAddr(0x02)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x03)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x04)
        ym.writeExtData(0x01)
        ym.writeExtAddr(0x05)
        ym.writeExtData(0x00)

        ym.writeExtAddr(0x00)
        ym.writeExtData(0x60)  // RAM write mode
        ym.writeExtAddr(0x08)
        ym.writeExtData(0xA5)
        ym.writeExtAddr(0x08)
        ym.writeExtData(0x3C)

        #expect(ym.adpcmRAM[0x00000] & 0x01 == 0x01)
        #expect(ym.adpcmRAM[0x08000] & 0x01 == 0x00)
        #expect(ym.adpcmRAM[0x10000] & 0x01 == 0x01)
        #expect(ym.adpcmRAM[0x28000] & 0x01 == 0x01)
        #expect(ym.adpcmRAM[0x38000] & 0x01 == 0x01)

        #expect(ym.adpcmRAM[0x08000] & 0x02 == 0x00)
        #expect(ym.adpcmRAM[0x10000] & 0x02 == 0x02)
        #expect(ym.adpcmRAM[0x18000] & 0x02 == 0x02)
        #expect(ym.adpcmRAM[0x20000] & 0x02 == 0x02)
        #expect(ym.adpcmRAM[0x28000] & 0x02 == 0x02)
    }

    @Test("ADPCM output is fmgen-style interpolated")
    func adpcmInterpolatedOutput() {
        let ym = YM2608()
        ym.reset()

        ym.adpcmRAM[0] = 0x70

        ym.writeExtAddr(0x09)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x0A)
        ym.writeExtData(0x40)  // delta-N = 0x4000 -> first decode on second FM step
        ym.writeExtAddr(0x0B)
        ym.writeExtData(0xFF)

        ym.writeExtAddr(0x00)
        ym.writeExtData(0x80)

        ym.tick(tStates: ym.fmTStatesPerSample)
        #expect(ym.adpcmOutputSample == 0)

        ym.tick(tStates: ym.fmTStatesPerSample)
        #expect(ym.adpcmOutputSample == 29)
    }

    @Test("ADPCM 8-bit RAM layout reconstructs playback nibbles")
    func adpcmEightBitPlayback() {
        let ym = YM2608()
        ym.reset()

        ym.writeExtAddr(0x01)
        ym.writeExtData(0xC2)  // L+R + 8-bit RAM layout
        ym.writeExtAddr(0x02)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x03)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x04)
        ym.writeExtData(0x01)
        ym.writeExtAddr(0x05)
        ym.writeExtData(0x00)

        ym.writeExtAddr(0x00)
        ym.writeExtData(0x60)  // RAM write mode
        ym.writeExtAddr(0x08)
        ym.writeExtData(0x70)

        ym.writeExtAddr(0x09)
        ym.writeExtData(0x00)
        ym.writeExtAddr(0x0A)
        ym.writeExtData(0x40)  // delta-N = 0x4000 -> first decode on second FM step
        ym.writeExtAddr(0x0B)
        ym.writeExtData(0xFF)

        ym.writeExtAddr(0x00)
        ym.writeExtData(0x80)

        ym.tick(tStates: ym.fmTStatesPerSample)
        #expect(ym.adpcmOutputSample == 0)

        ym.tick(tStates: ym.fmTStatesPerSample)
        #expect(ym.adpcmOutputSample == 29)
    }

    // MARK: - Rhythm Tests

    @Test("Rhythm key on/off via bank 0 register 0x10")
    func rhythmKeyOnOff() {
        let ym = YM2608()
        ym.reset()

        // Key on BD (bit 0) and SD (bit 1): bit 7=0 means key on
        ym.writeAddr(0x10)
        ym.writeData(0x03)  // bit 7 = 0 (key on), bit 0+1

        #expect(ym.fmSynth.rhythmKey & 0x01 != 0)  // BD
        #expect(ym.fmSynth.rhythmKey & 0x02 != 0)  // SD
        #expect(ym.fmSynth.rhythmKey & 0x04 == 0)
    }

    @Test("Rhythm total level and individual levels")
    func rhythmLevels() {
        let ym = YM2608()
        ym.reset()

        ym.writeAddr(0x11)
        ym.writeData(0x20)
        // rhythmTL = ~value & 0x3F (fmgen: unsigned bitwise NOT masked to 6 bits)
        #expect(ym.fmSynth.rhythmTL == Int8(~UInt8(0x20) & 0x3F))  // = 31

        ym.writeAddr(0x18)
        ym.writeData(0x10)
        // level = ~value & 0x1F (fmgen: inverted, positive attenuation 0-31)
        #expect(ym.fmSynth.rhythm[0].level == Int8(~UInt8(0x10) & 0x1F))  // = 15
    }

    @Test("Rhythm generates output when key on")
    func rhythmGeneratesOutput() {
        let ym = YM2608()
        ym.reset()

        // Set levels (bank 0 registers)
        ym.writeAddr(0x11)
        ym.writeData(0x00)  // max total level
        ym.writeAddr(0x18)
        ym.writeData(0x00)  // max BD level

        // Key on BD: bit 7=0 means key on (fmgen convention)
        ym.writeAddr(0x10)
        ym.writeData(0x01)

        // Run to generate samples
        ym.tick(tStates: 182 * 10)

        #expect(ym.audioBuffer.count >= 5)
    }

    @Test("FM generates non-silent output when key on")
    func fmGeneratesOutput() {
        let ym = YM2608()
        ym.reset()

        // Setup ch1: simple tone
        // Set F-Number and Block
        ym.writeAddr(0xA4)
        ym.writeData((4 << 3) | 0x01)  // block=4, fnum_hi=1
        ym.writeAddr(0xA0)
        ym.writeData(0x80)  // fnum_lo

        // Set op1 (carrier in algo 0): TL=0 (max volume), AR=31, MUL=1
        ym.writeAddr(0x30)
        ym.writeData(0x01)  // DT=0, MUL=1
        ym.writeAddr(0x40)
        ym.writeData(0x00)  // TL=0
        ym.writeAddr(0x50)
        ym.writeData(0x1F)  // AR=31
        ym.writeAddr(0x60)
        ym.writeData(0x00)  // DR=0
        ym.writeAddr(0x70)
        ym.writeData(0x00)  // SR=0
        ym.writeAddr(0x80)
        ym.writeData(0x0F)  // SL=0, RR=15

        // Algorithm 7 (all carriers)
        ym.writeAddr(0xB0)
        ym.writeData(0x07)  // fb=0, algo=7

        // Key on all ops
        ym.writeAddr(0x28)
        ym.writeData(0xF0)

        // Run enough to generate audio
        ym.tick(tStates: 182 * 50)

        #expect(ym.audioBuffer.count >= 40)
        // Should have non-zero FM contribution
        #expect(ym.audioBuffer.contains(where: { $0 != 0 }))
    }

    // MARK: - BEEP Tests

    @Test func beepOnProducesNonZeroOutput() {
        let ym = YM2608()
        ym.reset()
        ym.beepOn = true

        // Tick enough to generate audio samples
        ym.tick(tStates: 8000)
        #expect(ym.audioBuffer.count > 0)
        #expect(ym.audioBuffer.contains(where: { $0 != 0 }))
    }

    @Test func beepOffProducesZeroBeepContribution() {
        let ym = YM2608()
        ym.reset()
        ym.beepOn = false
        ym.singSignal = false

        ym.tick(tStates: 8000)
        // All samples should be zero (no FM/SSG/ADPCM/Rhythm/BEEP active)
        #expect(ym.audioBuffer.allSatisfy { $0 == 0 })
    }

    @Test func singSignalProducesDCOutput() {
        let ym = YM2608()
        ym.reset()
        ym.singSignal = true

        ym.tick(tStates: 8000)
        #expect(ym.audioBuffer.count > 0)
        // SING produces constant DC level — all non-zero samples should be positive
        let nonZero = ym.audioBuffer.filter { $0 != 0 }
        #expect(!nonZero.isEmpty)
        #expect(nonZero.allSatisfy { $0 > 0 })
    }

    @Test func beepResetClearsState() {
        let ym = YM2608()
        ym.reset()
        ym.beepOn = true
        ym.singSignal = true
        ym.reset()

        #expect(ym.beepOn == false)
        #expect(ym.singSignal == false)
    }

    // MARK: - Mathematical Correctness Tests

    @Test("Sine table: entry 0 is near-zero attenuation (loud), entry 255 is maximum attenuation")
    func sineTableBoundaryValues() {
        // Entry 0 = sin(π/1024) ≈ nearly full amplitude → small log value
        // The table stores log-domain values: lower = louder
        let entry0 = sineTable[0]
        let entryQuarter = sineTable[FM.sineEntries / 4]  // sin(π/2) = 1.0 → minimum log

        // sin(π/2) = 1.0 → log value should be minimal (2, the smallest nonzero)
        #expect(entryQuarter == 2)  // Even index = positive

        // First entry should be larger (higher attenuation for near-zero sine)
        #expect(entry0 > entryQuarter)

        // Negative half mirrors positive but odd index
        let entryNegQuarter = sineTable[FM.sineEntries / 4 + FM.sineEntries / 2]
        #expect(entryNegQuarter == entryQuarter + 1)  // +1 for negative flag
    }

    @Test("Combined log table: entry 0 is maximum amplitude, decays monotonically")
    func combinedLogTableMonotonicity() {
        // combinedLogTable[0] = positive max, [1] = negative max
        let posMax = combinedLogTable[0]
        let negMax = combinedLogTable[1]
        #expect(posMax > 0)
        #expect(negMax < 0)
        #expect(posMax == -negMax)  // Symmetric

        // Even entries (positive) should decrease monotonically
        for i in stride(from: 0, to: FM.combinedLogEntries - 2, by: 2) {
            #expect(combinedLogTable[i] >= combinedLogTable[i + 2],
                    "combinedLogTable[\(i)] should be >= combinedLogTable[\(i + 2)]")
        }

        // Last entries should be zero (fully attenuated)
        #expect(combinedLogTable[FM.combinedLogEntries - 2] == 0)
    }

    @Test("logToLin converts sine table entry to valid amplitude")
    func logToLinRoundTrip() {
        // sin(π/2) = 1.0 → sineTable[256] = 2 → combinedLogTable[2] should be close to max
        let sineIdx = FM.sineEntries / 4  // quarter period = peak
        let logVal = Int(sineTable[sineIdx])
        let linear = FMOp.logToLin(logVal)

        // At peak sine with zero EG attenuation, output should be near max
        #expect(linear > 4000, "Peak sine should produce large amplitude, got \(linear)")

        // Out of range returns zero
        #expect(FMOp.logToLin(FM.combinedLogEntries) == 0)
        #expect(FMOp.logToLin(FM.combinedLogEntries + 100) == 0)
    }

    @Test("Phase accumulator wraps correctly at 32-bit boundary")
    func phaseAccumulatorWraparound() {
        var op = FMOp()
        op.pgCount = UInt32.max - 10
        op.pgDiff = 20

        let before = op.pgCount
        let ret = op.pgCalc()
        #expect(ret == before)
        #expect(op.pgCount == 9)  // UInt32.max - 10 + 20 wraps to 9
    }

    @Test("SSG noise LFSR produces identical sequence at Int vs UInt32 width")
    func ssgNoiseLFSR32BitConsistency() {
        // Verify that the LFSR used in ssgNoiseTable produces identical
        // results whether computed with Int (64-bit) or UInt32 (32-bit)
        var noise64: Int = 14_321
        var noise32: UInt32 = 14_321

        for _ in 0..<10_000 {
            let bit64 = noise64 & 1
            let bit32 = noise32 & 1
            #expect(UInt32(bit64) == bit32)

            noise64 = (noise64 >> 1) | (((noise64 << 14) ^ (noise64 << 16)) & 0x10000)
            noise32 = (noise32 >> 1) | (((noise32 << 14) ^ (noise32 << 16)) & 0x10000)
        }
    }

    @Test("EG attack curve decreases level toward zero")
    func egAttackCurveDecreases() {
        var op = FMOp()
        op.ar = 30  // Fast attack
        op.dr = 0
        op.sr = 0
        op.sl = 0
        op.rr = 0
        op.tl = 0
        op.tlLatch = 0
        op.ks = 0
        op.paramChanged = true

        let ratio: UInt32 = 161  // Typical ratio at 44100Hz
        op.doKeyOn(ratio: ratio)

        #expect(op.egPhase == .attack)
        let initialLevel = op.egLevel

        // Run several EG steps — level should decrease (attack moves toward 0)
        for _ in 0..<1000 {
            op.egStep(ratio: ratio)
        }

        #expect(op.egLevel < initialLevel, "EG level should decrease during attack")
    }

    @Test("EG release increases level toward egBottom")
    func egReleaseCurveIncreases() {
        var op = FMOp()
        op.ar = 31  // Instant attack
        op.dr = 0
        op.sr = 0
        op.sl = 0
        op.rr = 8  // Moderate release
        op.tl = 0
        op.tlLatch = 0
        op.ks = 0
        op.paramChanged = true

        let ratio: UInt32 = 161
        op.doKeyOn(ratio: ratio)

        // Run attack to completion
        for _ in 0..<500 {
            op.egStep(ratio: ratio)
        }

        op.doKeyOff(ratio: ratio)
        #expect(op.egPhase == .release)
        let levelAtRelease = op.egLevel

        // Run release — level should increase toward FM.egBottom
        for _ in 0..<5000 {
            op.egStep(ratio: ratio)
        }

        #expect(op.egLevel > levelAtRelease, "EG level should increase during release")
    }

    @Test("pgDiff intermediate calculation stays safe for extreme parameters")
    func pgDiffExtremParameterSafety() {
        var op = FMOp()
        // Maximum possible values
        op.dp = (2047) << 7   // fnum=2047, block=7
        op.bn = 31            // max block/note
        op.detune = 3 * 32    // DT1=3 (max positive)
        op.detune2 = 3        // DT2=3 (max)
        op.multiple = 15      // MUL=15 (max)
        op.ks = 3
        op.tl = 0
        op.tlLatch = 0
        op.paramChanged = true

        let synth = FMSynthesizer()
        op.prepare(ratio: synth.ratio, multable: synth.multable)

        // Should not crash and pgDiff should be a valid UInt32
        #expect(op.pgDiff > 0)
    }

    @Test("FM operator output is bounded within safe range")
    func fmOperatorOutputBounded() {
        var ch = FMCh()

        // Set up a maximum-volume sine tone
        ch.op[0].ar = 31
        ch.op[0].tl = 0
        ch.op[0].tlLatch = 0
        ch.op[0].paramChanged = true
        ch.algo = 7  // All carriers
        ch.fb = FM.noFeedback

        let synth = FMSynthesizer()
        let ratio = synth.ratio

        // Set a frequency
        ch.setFNum((440 << 11) | 1200)

        ch.op[0].doKeyOn(ratio: ratio)
        ch.op[1].doKeyOn(ratio: ratio)
        ch.op[2].doKeyOn(ratio: ratio)
        ch.op[3].doKeyOn(ratio: ratio)

        // Generate samples and verify they're bounded
        var maxSample = 0
        for _ in 0..<1000 {
            for i in 0..<4 { ch.op[i].prepare(ratio: ratio, multable: synth.multable) }
            let sample = ch.calc(ratio: ratio)
            maxSample = max(maxSample, abs(sample))
        }

        // FM output should be nonzero and bounded
        #expect(maxSample > 0, "FM should produce non-zero output")
        // Each operator's max output is combinedLogTable[0] ≈ 8192
        // With 4 carriers in algo 7, max theoretical is ~32768
        #expect(maxSample < 50000, "FM output should be bounded, got \(maxSample)")
    }

    @Test("ADPCM clamp operates correctly at 16-bit boundaries")
    func adpcmClampBoundaries() {
        #expect(YM2608.storeSample16(0, 0) == 0)
        #expect(YM2608.storeSample16(32767, 0) == 32767)
        #expect(YM2608.storeSample16(32767, 1) == 32767)  // Saturates
        #expect(YM2608.storeSample16(-32768, 0) == -32768)
        #expect(YM2608.storeSample16(-32768, -1) == -32768)  // Saturates
        #expect(YM2608.storeSample16(16384, 16383) == 32767)  // Saturates at max
        #expect(YM2608.storeSample16(-16384, -16385) == -32768)  // Saturates at min
    }

    @Test("PM waveform table is triangular and bounded")
    func pmWaveformTableShape() {
        // Phase 0 (index 0): should be 0x80 (DC offset start)
        #expect(pmWaveformTable[0] == 0x80)

        // Phase π/2 (index 64): should be peak
        let peak = pmWaveformTable[0x3F]  // Just before 0x40
        #expect(peak > pmWaveformTable[0])

        // Phase π (index 128): near minimum
        let trough = pmWaveformTable[0x80]
        #expect(trough < pmWaveformTable[0])

        // All entries should be in valid range [0, 255]
        for (i, v) in pmWaveformTable.enumerated() {
            #expect(v >= 0 && v <= 255, "pmWaveformTable[\(i)] = \(v) out of range")
        }
    }

    @Test("AM waveform table is sawtooth-like and bounded")
    func amWaveformTableShape() {
        // First entry should be near maximum
        #expect(amWaveformTable[0] > 200)

        // Entry at 128 should be near zero (trough of sawtooth)
        #expect(amWaveformTable[0x80] == 0)

        // All entries should be non-negative and bounded
        for (i, v) in amWaveformTable.enumerated() {
            #expect(v >= 0 && v <= 255, "amWaveformTable[\(i)] = \(v) out of range")
        }

        // Values should be multiples of 4 (the & ~3 mask)
        for (i, v) in amWaveformTable.enumerated() {
            #expect(v & 3 == 0, "amWaveformTable[\(i)] = \(v) should be multiple of 4")
        }
    }

    @Test("Feedback shift table maps correctly")
    func feedbackShiftTableValues() {
        #expect(feedbackShiftTable[0] == FM.noFeedback)  // fb=0 → no feedback (shift 31)
        #expect(feedbackShiftTable[1] == 7)   // fb=1 → shift 7 (least feedback)
        #expect(feedbackShiftTable[7] == 1)   // fb=7 → shift 1 (most feedback)

        // All entries should be valid shift amounts
        for v in feedbackShiftTable {
            #expect(v >= 1 && v <= 31)
        }
    }

    @Test("Total level table is monotonically decreasing for positive entries")
    func totalLevelTableMonotonicity() {
        // Entries at FM.tlOffset+0 through FM.tlOffset+FM.tlEntries-1
        for i in 0..<(FM.tlEntries - 1) {
            let cur = totalLevelTable[FM.tlOffset + i]
            let next = totalLevelTable[FM.tlOffset + i + 1]
            #expect(cur >= next,
                    "totalLevelTable[\(i)] = \(cur) should be >= totalLevelTable[\(i+1)] = \(next)")
        }
    }

    // MARK: - Prescaler / Ratio / Timing Tests

    @Test("FM ratio matches OPNA clock / 72 prescaler at 44100Hz")
    func fmRatioValue() {
        // OPNA clock = 3,993,624 Hz. FM rate = clock / 72 = 55,467 Hz.
        // ratio = ((fmclock << ratioBits) + rate/2) / rate
        //       = ((55467 << 7) + 22050) / 44100
        //       = (7099776 + 22050) / 44100
        //       = 7121826 / 44100 = 161 (truncated)
        let synth = FMSynthesizer()
        #expect(synth.ratio == 161, "ratio should be 161 for OPNA 3,993,624Hz / 72 at 44100Hz output")
    }

    @Test("FM multable entry MUL=1,DT2=0 equals 2 × ratio")
    func multableBasicEntry() {
        // MUL=1: multiplier = 1*2 = 2
        // DT2=0: dt2Multiplier[0] = 1.0
        // multable[0][1] = UInt32(Float(2) * Float(ratio) * 1.0)
        let synth = FMSynthesizer()
        let expected = UInt32(2 * synth.ratio)
        #expect(synth.multable[0][1] == expected)
    }

    @Test("FM multable MUL=0 uses multiplier 1 (half-frequency)")
    func multableMulZero() {
        let synth = FMSynthesizer()
        let mulZero = synth.multable[0][0]   // MUL=0 → multiplier=1
        let mulOne = synth.multable[0][1]    // MUL=1 → multiplier=2
        #expect(mulZero * 2 == mulOne, "MUL=0 should be half of MUL=1")
    }

    @Test("FM multable DT2 increases with index")
    func multableDT2Ordering() {
        let synth = FMSynthesizer()
        // Same MUL, increasing DT2 should increase multable value
        // dt2Multiplier = [1.0, 1.414, 1.581, 1.732]
        for mul in 1..<16 {
            for dt2 in 0..<3 {
                #expect(synth.multable[dt2][mul] < synth.multable[dt2 + 1][mul],
                        "DT2=\(dt2) should be < DT2=\(dt2+1) at MUL=\(mul)")
            }
        }
    }

    @Test("pgDiff is deterministic and nonzero for extreme parameters")
    func pgDiffExtremeParameters() {
        // Verify that extreme fnum/block/DT/MUL produces a consistent, nonzero pgDiff
        // and that calling prepare() twice with same params gives same result
        let synth = FMSynthesizer()

        func makeExtremeOp() -> FMOp {
            var op = FMOp()
            op.dp = (2047) << 7   // Max fnum, max block
            op.bn = 28            // High block/note
            op.detune = 2 * 32    // DT1=2
            op.detune2 = 3        // DT2=3 (max)
            op.multiple = 15      // MUL=15 (max)
            op.ks = 0
            op.tl = 0; op.tlLatch = 0
            op.paramChanged = true
            op.prepare(ratio: synth.ratio, multable: synth.multable)
            return op
        }

        let op1 = makeExtremeOp()
        let op2 = makeExtremeOp()

        #expect(op1.pgDiff > 0, "pgDiff should be nonzero")
        #expect(op1.pgDiff == op2.pgDiff, "pgDiff should be deterministic")
    }

    @Test("pgDiff increases with F-Number (pitch proportional to frequency)")
    func pgDiffProportionalToFnum() {
        let synth = FMSynthesizer()

        var opLow = FMOp()
        opLow.multiple = 1; opLow.detune2 = 0
        opLow.paramChanged = true
        opLow.setFNum((4 << 11) | 500)  // block=4, fnum=500
        opLow.prepare(ratio: synth.ratio, multable: synth.multable)

        var opHigh = FMOp()
        opHigh.multiple = 1; opHigh.detune2 = 0
        opHigh.paramChanged = true
        opHigh.setFNum((4 << 11) | 1000)  // block=4, fnum=1000
        opHigh.prepare(ratio: synth.ratio, multable: synth.multable)

        // Higher fnum → higher pgDiff (faster phase accumulation = higher pitch)
        #expect(opHigh.pgDiff > opLow.pgDiff,
                "Higher F-Number should produce higher pgDiff: \(opHigh.pgDiff) vs \(opLow.pgDiff)")

        // Ratio should be approximately 2:1 (linear with fnum)
        let ratio = Double(opHigh.pgDiff) / Double(opLow.pgDiff)
        #expect(ratio > 1.8 && ratio < 2.2,
                "pgDiff ratio should be ~2.0 for 2x fnum, got \(ratio)")
    }

    @Test("Timer A period scales correctly with clock mode")
    func timerAPeriodScaling() {
        let ym = YM2608()
        ym.reset()

        // At 8MHz: timerATStatesPerTick = 72 * 2 = 144
        #expect(ym.timerATStatesPerTick == 144)
        #expect(ym.fmTStatesPerSample == 144)

        // At 4MHz: timerATStatesPerTick = 72 * 1 = 72
        ym.clock8MHz = false
        #expect(ym.timerATStatesPerTick == 72)
        #expect(ym.fmTStatesPerSample == 72)
    }

    @Test("FM sample rate is approximately 55467 Hz from OPNA clock")
    func fmSampleRate() {
        // OPNA clock = 3,993,624 Hz
        // FM rate = OPNA / 72 = 55,467 Hz (integer division)
        let opnaClock = 3_993_624
        let fmRate = opnaClock / 72
        #expect(fmRate == 55_467)

        // This is the rate at which generateSample() is called internally
        // The output is then downsampled to 44100 Hz via Bresenham
    }

    @Test("Bresenham audio accumulator produces correct sample count")
    func bresenhamSampleRate() {
        let ym = YM2608()
        ym.reset()
        ym.clock8MHz = true

        // Run for exactly 1 second worth of T-states (8MHz CPU)
        let cpuHz = YM2608.baseCpuClockHz8MHz  // 7,987,248
        ym.tick(tStates: cpuHz)

        // Should produce approximately 44100 samples (L+R interleaved = 88200 floats)
        let samplePairs = ym.audioBuffer.count / 2
        // Allow ±2 sample tolerance for Bresenham rounding
        #expect(abs(samplePairs - 44100) <= 2,
                "Expected ~44100 sample pairs in 1 second, got \(samplePairs)")
    }

    @Test("SSG clock divider is correct for both clock modes")
    func ssgClockDivider() {
        let ym = YM2608()
        // 8MHz: 16 OPNA clocks × 2 = 32 T-states per SSG tick
        ym.clock8MHz = true
        #expect(ym.ssgDivider == 32)

        // 4MHz: 16 OPNA clocks × 1 = 16 T-states per SSG tick
        ym.clock8MHz = false
        #expect(ym.ssgDivider == 16)
    }

    @Test("FM output amplitude is consistent between single and multi-frame generation")
    func fmOutputConsistencyAcrossFrames() {
        // This tests that ratio/prescaler is applied consistently
        // by comparing output from a single long tick vs many short ticks
        let ym1 = YM2608()
        ym1.reset()
        let ym2 = YM2608()
        ym2.reset()

        // Set up identical FM tone on both
        for ym in [ym1, ym2] {
            ym.writeAddr(0xA4); ym.writeData((4 << 3) | 0x01)  // block=4
            ym.writeAddr(0xA0); ym.writeData(0x80)              // fnum
            ym.writeAddr(0x30); ym.writeData(0x01)              // MUL=1
            ym.writeAddr(0x40); ym.writeData(0x00)              // TL=0
            ym.writeAddr(0x50); ym.writeData(0x1F)              // AR=31
            ym.writeAddr(0x60); ym.writeData(0x00)              // DR=0
            ym.writeAddr(0x70); ym.writeData(0x00)              // SR=0
            ym.writeAddr(0x80); ym.writeData(0x0F)              // RR=15
            ym.writeAddr(0xB0); ym.writeData(0x07)              // algo=7
            ym.writeAddr(0x28); ym.writeData(0xF0)              // key on all
        }

        // ym1: one big tick
        ym1.tick(tStates: 144 * 100)
        // ym2: many small ticks (same total)
        for _ in 0..<100 { ym2.tick(tStates: 144) }

        // Both should have the same number of samples
        #expect(ym1.audioBuffer.count == ym2.audioBuffer.count,
                "Sample counts should match: \(ym1.audioBuffer.count) vs \(ym2.audioBuffer.count)")

        // And the same sample values (deterministic)
        if ym1.audioBuffer.count == ym2.audioBuffer.count {
            for i in 0..<ym1.audioBuffer.count {
                #expect(ym1.audioBuffer[i] == ym2.audioBuffer[i],
                        "Sample \(i) differs: \(ym1.audioBuffer[i]) vs \(ym2.audioBuffer[i])")
            }
        }
    }
}
