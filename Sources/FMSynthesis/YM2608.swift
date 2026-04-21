/// YM2608 (OPNA) behavioral model.
///
/// Ports:
///   0x44: SSG + FM ch1-3 address write / status read
///   0x45: SSG + FM ch1-3 data read/write
///   0x46: ADPCM + FM ch4-6 address write / extended status read
///   0x47: ADPCM + FM ch4-6 data read/write
///
/// Timer A: 10-bit, Timer B: 8-bit.
/// Timer overflow generates interrupt on i8214 Level 4 (Sound).
///
/// FM synthesis delegated to FMSynthesizer (fmgen port).
/// SSG: 3 channels (PSG-compatible).
public final class YM2608 {

    public struct DebugOutputMask: OptionSet, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let fm = DebugOutputMask(rawValue: 1 << 0)
        public static let ssg = DebugOutputMask(rawValue: 1 << 1)
        public static let adpcm = DebugOutputMask(rawValue: 1 << 2)
        public static let rhythm = DebugOutputMask(rawValue: 1 << 3)
        public static let all: DebugOutputMask = [.fm, .ssg, .adpcm, .rhythm]
    }

    /// Per-channel mute mask for debug use.
    ///
    /// Applied once per channel before the audio contribution is added to the mix.
    /// The hot-path cost is one branch per channel — well within branch-predictor
    /// range. Intentionally NOT persisted to `UserDefaults`; resets on restart.
    public struct DebugChannelMask: Sendable, Hashable {
        /// 1 bit per FM channel (bits 0-5). 1 = unmuted, 0 = muted.
        public var fm: UInt8 = 0x3F
        /// 1 bit per SSG channel (bits 0-2). 1 = unmuted, 0 = muted.
        public var ssg: UInt8 = 0x07
        /// 1 bit per Rhythm instrument (bits 0-5). 1 = unmuted, 0 = muted.
        public var rhythm: UInt8 = 0x3F
        /// ADPCM mute flag.
        public var adpcm: Bool = true

        public static let all = DebugChannelMask()

        public init(fm: UInt8 = 0x3F, ssg: UInt8 = 0x07, rhythm: UInt8 = 0x3F, adpcm: Bool = true) {
            self.fm = fm; self.ssg = ssg; self.rhythm = rhythm; self.adpcm = adpcm
        }
    }

    // MARK: - Register Banks

    /// SSG + FM ch1-3 registers (256 entries)
    public package(set) var registers: [UInt8] = Array(repeating: 0x00, count: 256)

    /// ADPCM + FM ch4-6 registers (256 entries)
    public package(set) var extRegisters: [UInt8] = Array(repeating: 0x00, count: 256)

    /// Currently selected address for port 0x44/0x45
    public package(set) var selectedAddr: UInt8 = 0

    /// Currently selected address for port 0x46/0x47
    public package(set) var selectedExtAddr: UInt8 = 0

    // MARK: - Timer State

    /// Timer A period (10-bit, registers 0x24-0x25)
    public package(set) var timerAValue: UInt16 = 0

    /// Timer B period (8-bit, register 0x26)
    public package(set) var timerBValue: UInt8 = 0

    /// Timer A counter (counts up toward overflow)
    public package(set) var timerACounter: Int = 0

    /// Timer B counter
    public package(set) var timerBCounter: Int = 0

    /// Timer A running
    public package(set) var timerAEnabled: Bool = false

    /// Timer B running
    public package(set) var timerBEnabled: Bool = false

    /// Timer A overflow flag
    public var timerAOverflow: Bool = false

    /// Timer B overflow flag
    public var timerBOverflow: Bool = false

    /// Timer A interrupt enable
    public package(set) var timerAIRQEnable: Bool = false

    /// Timer B interrupt enable
    public package(set) var timerBIRQEnable: Bool = false

    /// Status mask for extended status register (fmgen stmask).
    /// Controls which ADPCM status bits are visible in readExtStatus().
    /// Initial value ~0x1C = 0xE3: bits 2,3,4 (EOS, BRDY, ZERO) masked.
    package var statusMask: UInt8 = 0xE3

    /// IRQ control register (reg 0x29). Low bits gate timer/ADPCM IRQ output.
    package var irqControl: UInt8 = 0x1F

    /// Current state of the OPNA IRQ output line.
    package var irqAsserted: Bool = false

    /// Current IRQ output level after timer/ADPCM masking.
    public var irqLineActive: Bool { irqAsserted }

    /// OPNA status busy flag hold time after each data-port write.
    package var busyStatusCounter: Int = 0

    // MARK: - Clock Mode

    /// CPU clock mode: true = 8MHz, false = 4MHz.
    /// OPNA clock is always 3,993,624 Hz (master / 8).
    /// In 8MHz mode, CPU clock = 2× OPNA clock, so OPNA timers
    /// need 2× the T-states per tick.
    public var clock8MHz: Bool = true {
        didSet {
            cpuClockHz = clock8MHz ? Self.cpuClockHz8MHz : Self.cpuClockHz4MHz
        }
    }

    /// OPNA-to-CPU clock ratio (2 at 8MHz, 1 at 4MHz)
    private var clockRatio: Int { clock8MHz ? 2 : 1 }

    // MARK: - Timer Constants

    /// Timer A: 72 OPNA clocks × clockRatio CPU T-states per tick
    var timerATStatesPerTick: Int { 72 * clockRatio }

    /// Timer B: 1152 OPNA clocks × clockRatio CPU T-states per tick
    var timerBTStatesPerTick: Int { 1152 * clockRatio }

    /// FM sample period: 72 OPNA clocks × clockRatio CPU T-states
    public var fmTStatesPerSample: Int { 72 * clockRatio }

    /// SSG clock divider: OPNA/4 prescaler × /4 internal = 16 OPNA clocks × clockRatio
    var ssgDivider: Int { 16 * clockRatio }

    // MARK: - FM Synthesizer

    /// fmgen-based FM synthesis engine
    public let fmSynth: FMSynthesizer = FMSynthesizer()

    /// FM sample counter (FM runs at OPNA clock / 72)
    public package(set) var fmSampleCounter: Int = 0

    /// Cached F-Number values for channels 1-6, combined as fmgen expects.
    package var fmFNumMain: [UInt32] = Array(repeating: 0, count: 6)

    /// Channel 3 special mode F-Number values for operators 1-3.
    package var fmFNum3: [UInt32] = Array(repeating: 0, count: 3)

    // MARK: - SSG (PSG) State

    /// SSG channel tone periods (12-bit, channels A/B/C)
    public package(set) var ssgTonePeriod: [UInt16] = [0, 0, 0]

    /// SSG channel tone counters
    public package(set) var ssgToneCounter: [Int] = [0, 0, 0]

    /// SSG channel tone output state (true = high)
    public package(set) var ssgToneOutput: [Bool] = [true, true, true]

    /// SSG channel volumes (4-bit, 0-15). Bit 4 = envelope mode.
    public package(set) var ssgVolume: [UInt8] = [0, 0, 0]

    /// SSG noise period (5-bit)
    public package(set) var ssgNoisePeriod: UInt8 = 0

    /// SSG noise counter
    public package(set) var ssgNoiseCounter: Int = 0

    /// SSG noise LFSR (17-bit)
    public package(set) var ssgNoiseLFSR: UInt32 = 14321

    /// SSG noise output
    public package(set) var ssgNoiseOutput: Bool = true

    /// SSG mixer register (R7): tone/noise enable per channel
    public package(set) var ssgMixer: UInt8 = 0xFF  // All disabled by default

    /// SSG envelope period (16-bit)
    public package(set) var ssgEnvPeriod: UInt16 = 0

    /// SSG envelope counter
    public package(set) var ssgEnvCounter: Int = 0

    /// SSG envelope shape
    public package(set) var ssgEnvShape: UInt8 = 0

    /// SSG envelope position (0-63, 32 steps per half-cycle for 32-level volume)
    public var ssgEnvPosition: Int = 0  // テストから書き込みあり

    /// SSG envelope holding
    public package(set) var ssgEnvHolding: Bool = false

    /// SSG clock divider (static, used as default only)
    public static let ssgClockDividerDefault = 32

    private static let ssgToneShift = 24
    private static let ssgEnvShift = 22
    private static let ssgNoiseShift = 14
    private static let ssgOversamplingShift = 2
    private static let ssgOversamplingCount = 1 << ssgOversamplingShift
    private static let ssgNoiseTableSize = 1 << 11
    private static let ssgClockHz = 3_993_624 / 4
    private static let ssgTonePeriodBase: UInt32 = {
        let scale = Int64(1 << ssgToneShift) / 4
        return UInt32(scale * Int64(ssgClockHz) / Int64(sampleRate))
    }()
    private static let ssgEnvelopePeriodBase: UInt32 = {
        let scale = Int64(1 << ssgEnvShift) / 4
        return UInt32(scale * Int64(ssgClockHz) / Int64(sampleRate))
    }()
    private static let ssgNoisePeriodBase: UInt32 = {
        let scale = Int64(1 << ssgNoiseShift) / 4
        return UInt32(scale * Int64(ssgClockHz) / Int64(sampleRate))
    }()
    private static let ssgToneStepLimit = UInt32(1 << ssgToneShift)
    private static let ssgEnvelopeWrap = UInt32(1 << (ssgEnvShift + 6 + ssgOversamplingShift))
    private static let ssgEnvelopeHoldBit = UInt32(1 << (ssgEnvShift + 5 + ssgOversamplingShift))

    package var ssgTonePhase: [UInt32] = [0, 0, 0]
    package var ssgToneStep: [UInt32] = Array(repeating: YM2608.ssgTonePeriodBase, count: 3)
    package var ssgNoisePhase: UInt32 = 0
    package var ssgNoiseStep: UInt32 = YM2608.ssgNoisePeriodBase
    package var ssgEnvelopePhase: UInt32 = 0
    package var ssgEnvelopeStep: UInt32 = YM2608.ssgEnvelopePeriodBase * 2
    package var ssgOutputLevel: [Int] = [0, 0, 0]

    // MARK: - ADPCM State

    /// ADPCM start address (register 0x02-0x03, raw 16-bit register pair)
    public var adpcmStartAddr: UInt32 = 0

    /// ADPCM stop address (register 0x04-0x05, in 32-byte units)
    public var adpcmStopAddr: UInt32 = 0

    /// ADPCM playback active
    public var adpcmPlaying: Bool = false

    /// ADPCM decoded sample (fmgen adpcmx, range -32768 to 32767)
    public var adpcmAccum: Int = 0

    /// ADPCM step size (fmgen adpcmd, range 127-24576)
    public var adpcmStepSize: Int = 127

    /// ADPCM delta-N (playback rate register 0x09-0x0A)
    public var adpcmDeltaN: UInt16 = 0

    /// ADPCM total level (register 0x0B): 0=silence, 255=max volume (fmgen adpcmlevel)
    public var adpcmTotalLevel: UInt8 = 0

    /// ADPCM rate accumulator for variable-rate playback
    public var adpcmRateAccum: UInt32 = 0

    /// ADPCM output sample (in fmgen integer domain, ±32636 max)
    public var adpcmOutputSample: Float = 0

    /// ADPCM playback phase (fmgen adplc, 13-bit domain).
    package var adpcmPlaybackCounter: Int = 0

    /// ADPCM playback step per FM sample (fmgen adpld, 13-bit domain).
    package var adpcmPlaybackDelta: Int = 32

    /// Last scaled ADPCM sample (fmgen adpcmout).
    package var adpcmDecodedOutput: Int = 0

    /// Previous and current interpolated ADPCM outputs (fmgen apout0/apout1).
    package var adpcmOutputStage0: Int = 0
    package var adpcmOutputStage1: Int = 0

    /// ADPCM control register 1 (ext reg 0x00, fmgen control1)
    package var adpcmControl1: UInt8 = 0

    /// ADPCM control register 2 (ext reg 0x01, fmgen control2)
    /// bit 7 = Left enable, bit 6 = Right enable, bit 1 = 8-bit RAM layout
    package var adpcmControl2: UInt8 = 0xC0

    /// ADPCM status flags (bit 2 = EOS, managed separately from timer flags)
    package var adpcmStatusFlags: UInt8 = 0

    /// ADPCM memory address (fmgen memaddr, in shifted << 6 address space)
    package var adpcmMemAddr: UInt32 = 0

    /// ADPCM limit address (fmgen limitaddr, default 0x3FFFFF)
    package var adpcmLimitAddr: UInt32 = 0x3FFFFF

    /// ADPCM RAM (256KB, for ADPCM-B data storage)
    public var adpcmRAM: [UInt8] = Array(repeating: 0, count: 0x40000)

    /// ADPCM RAM read buffer (fmgen rembuf). Reg 0x08 reads in memory-read mode
    /// return the previously latched byte; first read after entering the mode
    /// is a "dummy read" on real hardware.
    package var adpcmReadBuffer: UInt8 = 0

    private var adpcmUsesEightBitRAMLayout: Bool {
        (adpcmControl2 & 0x02) != 0
    }

    /// Yamaha ADPCM-B delta table (fmgen table1)
    private static let adpcmDeltaTable: [Int] = [
        1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15
    ]

    /// Yamaha ADPCM-B step adjustment table (fmgen table2)
    private static let adpcmStepAdjTable: [Int] = [
        57, 57, 57, 57, 77, 102, 128, 153, 57, 57, 57, 57, 77, 102, 128, 153
    ]

    // MARK: - Audio Output

    /// Audio sample buffer (interleaved stereo, Float32, -1.0 to 1.0).
    /// Format: [L, R, L, R, ...]. Accumulated during tick(), consumed by audio output.
    public var audioBuffer: [Float] = []

    // MARK: - Immersive Audio Output

    /// When true, per-channel stereo buffers are populated alongside audioBuffer.
    public var immersiveOutputEnabled: Bool = false

    /// Per-channel stereo audio buffers (interleaved [L, R, L, R, ...], Float32).
    /// Only populated when immersiveOutputEnabled is true.
    /// Original L/R panning from hardware registers is preserved.
    /// BEEP is included in fmSpatialBuffer.
    public var fmSpatialBuffer: [Float] = []
    public var ssgSpatialBuffer: [Float] = []
    public var adpcmSpatialBuffer: [Float] = []
    public var rhythmSpatialBuffer: [Float] = []

    /// Debug-only output mask. Mutes final mix sources without affecting chip state.
    public var debugOutputMask: DebugOutputMask = .all

    /// Per-channel mute mask (debug only). Applied to individual FM/SSG/Rhythm/ADPCM
    /// channels. Not persisted; resets to `.all` on `reset()`.
    public var debugChannelMask: DebugChannelMask = .all {
        didSet {
            fmSynth.channelMask = debugChannelMask.fm
            fmSynth.rhythmMask  = debugChannelMask.rhythm
        }
    }

    // MARK: - Debug activity state (read from debug UI; never written on hot path)

    /// 6-bit FM channel key-on mask (bit i = channel i has at least one operator active).
    /// Updated on FM key-on/key-off register writes; never touched by the sample-gen loop.
    public private(set) var fmKeyOnMask: UInt8 = 0

    /// Current rhythm instrument key-on state (6 bits).
    /// Mirrors FMSynthesizer.rhythmKey, which auto-clears bits as samples complete.
    public var rhythmKeyOn: UInt8 { fmSynth.rhythmKey }

    /// Pseudo-stereo: applies Haas effect to mono FM/SSG output for stereo widening.
    /// Only effective when no FM channel has been panned (i.e. YM2203-compatible output).
    public var pseudoStereoEnabled: Bool = false

    /// Set to true when any FM channel's pan register (0xB4) is written with non-center value.
    /// Once set, pseudo-stereo is suppressed for FM until reset.
    public private(set) var fmPanDetected: Bool = false
    package var chorusFM = ChorusEffect()                    // L=dry, R=delayed
    package var chorusSSG = ChorusEffect(delayLeft: true)    // L=delayed, R=dry

    /// Audio sample rate for output (default 44100 Hz)
    public static let sampleRate = 44100

    /// CPU clock rate (Hz) — used for drift-free audio sample timing.
    /// OPNA clock = 3,993,624 Hz; CPU = OPNA × clockRatio.
    private static let cpuClockHz8MHz = 3_993_624 * 2  // 7,987,248
    private static let cpuClockHz4MHz = 3_993_624

    /// Current CPU clock rate for audio sample timing.
    /// AudioOutput adjusts this adaptively to match hardware playback rate.
    public var cpuClockHz: Int = cpuClockHz8MHz

    /// Base CPU clock rate (before adaptive adjustment)
    public static let baseCpuClockHz8MHz = cpuClockHz8MHz
    public static let baseCpuClockHz4MHz = cpuClockHz4MHz

    /// YM2608 keeps the busy flag high for about 10us after data writes.
    private static let busyUsec = 10

    /// Bresenham accumulator for drift-free audio sample generation.
    /// Accumulates tStates × sampleRate; emits sample when >= cpuClockHz.
    package var audioSampleAccum: Int = 0

    // MARK: - BEEP

    /// BEEP on flag (port 0x40 bit 5: 2400Hz square wave)
    public var beepOn: Bool = false

    /// CMD SING flag (port 0x40 bit 7: DC level for N-BASIC BEEP command)
    public var singSignal: Bool = false

    /// BEEP 2400Hz oscillator phase (0.0 ..< 1.0)
    package var beepPhase: Double = 0.0

    /// BEEP frequency in Hz
    private static let beepFrequency: Double = 2400.0

    /// BEEP mix level (amplitude as fraction of full scale)
    private static let beepLevel: Float = 0.15

    // MARK: - Interrupt Callback

    /// Called when timer overflow generates interrupt.
    public var onTimerIRQ: (() -> Void)?

    // MARK: - Init

    public init() {}

    /// Reset to power-on state.
    public func reset() {
        registers = Array(repeating: 0x00, count: 256)
        registers[0x0E] = 0xFF  // Port A (joystick) - no buttons pressed
        registers[0x0F] = 0xFF  // Port B - no buttons pressed
        extRegisters = Array(repeating: 0x00, count: 256)
        selectedAddr = 0
        selectedExtAddr = 0
        timerAValue = 0
        timerBValue = 0
        timerACounter = 0
        timerBCounter = 0
        timerAEnabled = false
        timerBEnabled = false
        timerAOverflow = false
        timerBOverflow = false
        timerAIRQEnable = false
        timerBIRQEnable = false
        statusMask = 0xE3  // ~0x1C: mask bits 2,3,4 (EOS, BRDY, ZERO)
        irqControl = 0x1F
        irqAsserted = false
        busyStatusCounter = 0
        ssgTonePeriod = [0, 0, 0]
        ssgToneCounter = [0, 0, 0]
        ssgToneOutput = [true, true, true]
        ssgVolume = [0, 0, 0]
        ssgNoisePeriod = 0
        ssgNoiseCounter = 0
        ssgNoiseLFSR = 14321
        ssgNoiseOutput = true
        ssgMixer = 0xFF
        ssgEnvPeriod = 0
        ssgEnvCounter = 0
        ssgEnvShape = 0
        ssgEnvPosition = 0
        ssgEnvHolding = false
        ssgTonePhase = [0, 0, 0]
        ssgToneStep = Array(repeating: Self.ssgTonePeriodBase, count: 3)
        ssgNoisePhase = 0
        ssgNoiseStep = Self.ssgNoisePeriodBase
        ssgEnvelopePhase = 0
        ssgEnvelopeStep = Self.ssgEnvelopePeriodBase * 2
        ssgOutputLevel = [0, 0, 0]
        audioSampleAccum = 0
        audioBuffer = []
        fmSpatialBuffer = []
        ssgSpatialBuffer = []
        adpcmSpatialBuffer = []
        rhythmSpatialBuffer = []
        fmKeyOnMask = 0
        debugChannelMask = .all
        fmSynth.reset()
        chorusFM.reset()
        chorusSSG.reset()
        fmPanDetected = false
        fmSampleCounter = 0
        fmFNumMain = Array(repeating: 0, count: 6)
        fmFNum3 = Array(repeating: 0, count: 3)
        fmOutputL = 0
        fmOutputR = 0
        rhythmOutputL = 0
        rhythmOutputR = 0
        adpcmStartAddr = 0
        adpcmStopAddr = 0
        adpcmPlaying = false
        adpcmAccum = 0
        adpcmStepSize = 127
        adpcmDeltaN = 0
        adpcmTotalLevel = 0
        adpcmRateAccum = 0
        adpcmOutputSample = 0
        adpcmPlaybackCounter = 0
        adpcmPlaybackDelta = 32
        adpcmDecodedOutput = 0
        adpcmOutputStage0 = 0
        adpcmOutputStage1 = 0
        adpcmControl1 = 0
        adpcmControl2 = 0xC0  // default: both L+R enabled
        adpcmStatusFlags = 0
        adpcmMemAddr = 0
        adpcmLimitAddr = 0x3FFFFF
        adpcmReadBuffer = 0
        beepOn = false
        singSignal = false
        beepPhase = 0.0
    }

    // MARK: - Timing

    /// Advance timers and synthesis by the given number of T-states.
    public func tick(tStates: Int) {
        if busyStatusCounter > 0 {
            busyStatusCounter = max(0, busyStatusCounter - tStates)
        }

        if timerAEnabled {
            timerACounter += tStates
            let period = (1024 - Int(timerAValue)) * timerATStatesPerTick
            if period > 0 && timerACounter >= period {
                if csmModeEnabled {
                    triggerCSMKeyControl()
                }
                if timerAIRQEnable {
                    timerAOverflow = true
                    updateIRQLine()
                }
                while timerACounter >= period {
                    timerACounter -= period
                }
            }
        }

        if timerBEnabled {
            timerBCounter += tStates
            let period = (256 - Int(timerBValue)) * timerBTStatesPerTick
            if period > 0 && timerBCounter >= period {
                if timerBIRQEnable {
                    timerBOverflow = true
                    updateIRQLine()
                }
                while timerBCounter >= period {
                    timerBCounter -= period
                }
            }
        }

        // ADPCM-B decoding runs on the OPNA 72-clock domain.
        fmSampleCounter += tStates
        while fmSampleCounter >= fmTStatesPerSample {
            fmSampleCounter -= fmTStatesPerSample
            advanceADPCM()
        }

        // Accumulate audio output samples (at audio rate: 44100Hz)
        // Bresenham accumulator: no integer truncation drift
        audioSampleAccum += tStates * Self.sampleRate
        while audioSampleAccum >= cpuClockHz {
            audioSampleAccum -= cpuClockHz
            generateFMSamples()
            advanceRhythm()
            let ssg = generateSSGSample()

            // Generate BEEP sample (2400Hz square wave)
            var beepSample: Int = 0
            if beepOn || singSignal {
                let beepSignal = beepPhase < 0.5  // 50% duty cycle
                if (beepOn && beepSignal) || singSignal {
                    beepSample = Int(Self.beepLevel * FM.sampleScale)
                }
                beepPhase += Self.beepFrequency / Double(Self.sampleRate)
                if beepPhase >= 1.0 { beepPhase -= 1.0 }
            } else {
                beepPhase = 0.0
            }

            let (mixL, mixR) = mixOutputFrame(
                fmLeft: fmOutputL,
                fmRight: fmOutputR,
                ssgSample: ssg,
                adpcmSample: Int(adpcmOutputSample),
                rhythmLeft: rhythmOutputL,
                rhythmRight: rhythmOutputR,
                beepSample: beepSample
            )

            audioBuffer.append(Float(mixL) / FM.sampleScale)
            audioBuffer.append(Float(mixR) / FM.sampleScale)

            if immersiveOutputEnabled {
                let mask = debugOutputMask
                let scale = FM.sampleScale

                // FM: stereo with original hardware panning, includes BEEP
                let fmL = mask.contains(.fm) ? Self.saturate16(fmOutputL) : 0
                let fmR = mask.contains(.fm) ? Self.saturate16(fmOutputR) : 0
                fmSpatialBuffer.append(Float(fmL + beepSample) / scale)
                fmSpatialBuffer.append(Float(fmR + beepSample) / scale)

                // SSG: mono → stereo (same value both channels)
                let ssgVal: Float = mask.contains(.ssg)
                    ? Float(Int((ssg * 16384.0).rounded())) / scale
                    : 0
                ssgSpatialBuffer.append(ssgVal)
                ssgSpatialBuffer.append(ssgVal)

                // ADPCM: stereo with original L/R pan from adpcmControl2
                if mask.contains(.adpcm) {
                    let adL = Float((adpcmControl2 & 0x80) != 0 ? Int(adpcmOutputSample) : 0) / scale
                    let adR = Float((adpcmControl2 & 0x40) != 0 ? Int(adpcmOutputSample) : 0) / scale
                    adpcmSpatialBuffer.append(adL)
                    adpcmSpatialBuffer.append(adR)
                } else {
                    adpcmSpatialBuffer.append(0)
                    adpcmSpatialBuffer.append(0)
                }

                // Rhythm: stereo with original per-instrument panning
                let rhL = mask.contains(.rhythm) ? Self.saturate16(rhythmOutputL) : 0
                let rhR = mask.contains(.rhythm) ? Self.saturate16(rhythmOutputR) : 0
                rhythmSpatialBuffer.append(Float(rhL) / scale)
                rhythmSpatialBuffer.append(Float(rhR) / scale)
            }
        }
    }

    // MARK: - FM Synthesis

    /// Current FM output samples (updated at FM rate, consumed at audio rate)
    package var fmOutputL: Int = 0
    package var fmOutputR: Int = 0

    /// Current rhythm output samples (updated at FM rate, consumed at audio rate)
    package var rhythmOutputL: Int = 0
    package var rhythmOutputR: Int = 0

    static func saturate16(_ value: Int) -> Int {
        max(FM.sampleMin, min(FM.sampleMax, value))
    }

    static func storeSample16(_ dest: Int, _ data: Int) -> Int {
        saturate16(dest + data)
    }

    func mixOutputFrame(
        fmLeft: Int,
        fmRight: Int,
        ssgSample: Float,
        adpcmSample: Int,
        rhythmLeft: Int,
        rhythmRight: Int,
        beepSample: Int
    ) -> (Int, Int) {
        let mask = debugOutputMask
        var mixL = mask.contains(.fm) ? Self.saturate16(fmLeft) : 0
        var mixR = mask.contains(.fm) ? Self.saturate16(fmRight) : 0

        if mask.contains(.ssg) {
            let ssgScaled = Int((ssgSample * 16384.0).rounded())
            // Immersive takes priority: never apply pseudo-stereo chorus when
            // spatial output is active (the two modes are mutually exclusive).
            if pseudoStereoEnabled && !immersiveOutputEnabled {
                let (sl, sr) = chorusSSG.process(monoSample: ssgScaled)
                mixL = Self.storeSample16(mixL, sl)
                mixR = Self.storeSample16(mixR, sr)
            } else {
                mixL = Self.storeSample16(mixL, ssgScaled)
                mixR = Self.storeSample16(mixR, ssgScaled)
            }
        }

        if mask.contains(.adpcm) && debugChannelMask.adpcm {
            let adpcmL = (adpcmControl2 & 0x80) != 0 ? adpcmSample : 0
            let adpcmR = (adpcmControl2 & 0x40) != 0 ? adpcmSample : 0
            mixL = Self.storeSample16(mixL, adpcmL)
            mixR = Self.storeSample16(mixR, adpcmR)
        }

        if mask.contains(.rhythm) {
            mixL = Self.storeSample16(mixL, rhythmLeft)
            mixR = Self.storeSample16(mixR, rhythmRight)
        }

        // BEEP (mono, added to both channels)
        mixL = Self.storeSample16(mixL, beepSample)
        mixR = Self.storeSample16(mixR, beepSample)

        return (mixL, mixR)
    }

    /// Generate one FM sample from all 6 channels via FMSynthesizer.
    private func generateFMSamples() {
        let (l, r) = fmSynth.generateSample()
        // Immersive takes priority over pseudo-stereo: the chorus would leak
        // into the spatial FM buffer (fmOutputL/R feeds fmSpatialBuffer below),
        // and the two modes are mutually exclusive by design.
        if pseudoStereoEnabled && !fmPanDetected && !immersiveOutputEnabled {
            let (cl, cr) = chorusFM.process(monoSample: l)
            fmOutputL = cl
            fmOutputR = cr
        } else {
            fmOutputL = l
            fmOutputR = r
        }
    }

    /// Advance rhythm sample playback (called at FM rate).
    private func advanceRhythm() {
        let (l, r) = fmSynth.generateRhythm()
        rhythmOutputL = l
        rhythmOutputR = r
    }

    // MARK: - ADPCM Synthesis

    /// 13-bit fixed-point unit (1.0 = 8192) for ADPCM interpolation
    private static let adpcmFixedPointUnit = 1 << 13   // 8192
    private static let adpcmFixedPointShift = 13

    /// Advance ADPCM playback by one FM sample period.
    private func advanceADPCM() {
        if adpcmPlaying {
            if adpcmPlaybackCounter < 0 {
                adpcmPlaybackCounter += Self.adpcmFixedPointUnit
                decodeADPCMOutput()
            }

            let sample: Int
            if adpcmPlaying {
                sample = (adpcmPlaybackCounter * adpcmOutputStage0 +
                    (Self.adpcmFixedPointUnit - adpcmPlaybackCounter) * adpcmOutputStage1) >> Self.adpcmFixedPointShift
            } else {
                sample = (adpcmPlaybackCounter * adpcmOutputStage1) >> Self.adpcmFixedPointShift
            }

            adpcmOutputSample = Float(sample)
            adpcmPlaybackCounter -= adpcmPlaybackDelta
            return
        }

        guard adpcmOutputStage0 != 0 || adpcmOutputStage1 != 0 else {
            resetADPCMOutputPipeline()
            return
        }

        if adpcmPlaybackCounter < 0 {
            adpcmOutputStage0 = adpcmOutputStage1
            adpcmOutputStage1 = 0
            adpcmPlaybackCounter += Self.adpcmFixedPointUnit
        }

        adpcmOutputSample = Float((adpcmPlaybackCounter * adpcmOutputStage1) >> Self.adpcmFixedPointShift)
        adpcmPlaybackCounter -= adpcmPlaybackDelta

        if adpcmOutputStage0 == 0, adpcmOutputStage1 == 0, adpcmPlaybackCounter <= 0 {
            resetADPCMOutputPipeline()
        }
    }

    /// Decode one ADPCM step and update fmgen-style interpolation stages.
    private func decodeADPCMOutput() {
        adpcmOutputStage0 = adpcmOutputStage1
        let ram = decodeADPCMNibble()
        let scaled = (ram * Int(adpcmTotalLevel) * 16) >> 13
        adpcmOutputStage1 = adpcmDecodedOutput + scaled
        adpcmDecodedOutput = scaled
    }

    /// Decode one ADPCM nibble from ADPCM RAM and advance playback position.
    /// Follows fmgen ReadRAMN for both 1-bit and 8-bit RAM layouts.
    private func decodeADPCMNibble() -> Int {
        let nibble: Int
        let shouldCheckStop: Bool

        if adpcmUsesEightBitRAMLayout {
            let base = Int((adpcmMemAddr >> 4) & 0x7FFF)
            let bank = Int((adpcmMemAddr >> 1) & 0x07)
            let mask = UInt8(1 << bank)
            let planeBase = base + (((~Int(adpcmMemAddr) & 1) != 0) ? 0x20000 : 0)
            guard planeBase + 0x18000 < adpcmRAM.count else {
                adpcmPlaying = false
                return adpcmAccum
            }

            var data = Int(adpcmRAM[planeBase + 0x18000] & mask)
            data = data * 2 + Int(adpcmRAM[planeBase + 0x10000] & mask)
            data = data * 2 + Int(adpcmRAM[planeBase + 0x08000] & mask)
            data = data * 2 + Int(adpcmRAM[planeBase + 0x00000] & mask)
            nibble = data >> bank
            adpcmMemAddr &+= 1
            shouldCheckStop = (adpcmMemAddr & 1) == 0
        } else {
            let ramAddr = Int((adpcmMemAddr >> 4) & 0x3FFFF)
            guard ramAddr < adpcmRAM.count else {
                adpcmPlaying = false
                return adpcmAccum
            }

            let byte = adpcmRAM[ramAddr]
            adpcmMemAddr &+= 8

            // fmgen ReadRAMN: high nibble first, then low nibble
            let isHighNibble = (adpcmMemAddr & 8) != 0
            if isHighNibble {
                nibble = Int((byte >> 4) & 0x0F)
            } else {
                nibble = Int(byte & 0x0F)
            }
            shouldCheckStop = !isHighNibble
        }

        // Yamaha ADPCM-B decode (fmgen DecodeADPCMBSample)
        adpcmAccum = max(FM.sampleMin, min(FM.sampleMax,
            adpcmAccum + Self.adpcmDeltaTable[nibble] * adpcmStepSize / 8))
        adpcmStepSize = max(127, min(24576,
            adpcmStepSize * Self.adpcmStepAdjTable[nibble] / 64))
        let decoded = adpcmAccum

        // fmgen checks stop/limit after the second nibble in either RAM layout.
        guard shouldCheckStop else { return decoded }

        // Check for end of sample
        let internalStopAddr = (adpcmStopAddr + 1) << 6
        if adpcmMemAddr == internalStopAddr {
            if adpcmControl1 & 0x10 != 0 {
                // Repeat mode
                adpcmMemAddr = adpcmStartAddr << 6
                adpcmAccum = 0
                adpcmStepSize = 127
                adpcmStatusFlags |= 0x04  // Set EOS
                updateIRQLine()
                return decoded
            } else {
                adpcmMemAddr &= 0x3FFFFF
                adpcmPlaying = false
            }
            adpcmStatusFlags |= 0x04  // Set EOS
            updateIRQLine()
        }
        if adpcmMemAddr == adpcmLimitAddr {
            adpcmMemAddr = 0
        }

        return decoded
    }

    private func updateADPCMPlaybackDelta() {
        let deltaN = max(256, Int(adpcmDeltaN))
        adpcmPlaybackDelta = max(1, (deltaN * Self.adpcmFixedPointUnit) >> 16)
    }

    private func writeADPCMRAMByte(_ value: UInt8) {
        if adpcmUsesEightBitRAMLayout {
            let base = Int((adpcmMemAddr >> 4) & 0x7FFF)
            let bank = Int((adpcmMemAddr >> 1) & 0x07)
            let mask = UInt8(1 << bank)
            var shifted = UInt16(value) << bank
            let offsets = [0x00000, 0x08000, 0x10000, 0x18000, 0x20000, 0x28000, 0x30000, 0x38000]
            for offset in offsets {
                let idx = base + offset
                let planeValue = UInt8(shifted & 0x00FF) & mask
                adpcmRAM[idx] = (adpcmRAM[idx] & ~mask) | planeValue
                shifted >>= 1
            }
            adpcmMemAddr &+= 2
            return
        }

        let ramAddr = Int((adpcmMemAddr >> 4) & 0x3FFFF)
        if ramAddr < adpcmRAM.count {
            adpcmRAM[ramAddr] = value
        }
        adpcmMemAddr &+= 16
    }

    private func resetADPCMOutputPipeline() {
        adpcmRateAccum = 0
        adpcmOutputSample = 0
        adpcmPlaybackCounter = 0
        adpcmDecodedOutput = 0
        adpcmOutputStage0 = 0
        adpcmOutputStage1 = 0
    }

    // MARK: - SSG Synthesis

    /// Generate one SSG audio sample (mono, -1.0 to 1.0).
    private func generateSSGSample() -> Float {
        let enabledMask = (~ssgMixer) & 0x3F
        let activeVolume = (ssgVolume[0] | ssgVolume[1] | ssgVolume[2]) & 0x1F
        guard enabledMask != 0 || activeVolume != 0 else {
            return 0
        }

        let toneEnabled = (0..<3).map {
            ((enabledMask >> $0) & 1) != 0 && ssgToneStep[$0] <= Self.ssgToneStepLimit
        }
        let noiseEnabled = (0..<3).map {
            ((enabledMask >> ($0 + 3)) & 1) != 0
        }

        var sample = 0
        var lastNoiseBit = 0

        for _ in 0..<Self.ssgOversamplingCount {
            let envIndex = Int((ssgEnvelopePhase >> (Self.ssgEnvShift + Self.ssgOversamplingShift)) & 0x3F)
            let envelopeLevel = Self.ssgEnvelopeTable[Int(ssgEnvShape & 0x0F)][envIndex]
            let noiseIndex = Int(
                (ssgNoisePhase >> (Self.ssgNoiseShift + Self.ssgOversamplingShift + 6))
                    & UInt32(Self.ssgNoiseTableSize - 1)
            )
            let noiseShift = Int(
                (ssgNoisePhase >> (Self.ssgNoiseShift + Self.ssgOversamplingShift + 1)) & 31
            )
            lastNoiseBit = Int((Self.ssgNoiseTable[noiseIndex] >> noiseShift) & 1)

            for ch in 0..<3 {
                let toneBit = toneEnabled[ch]
                    ? Int((ssgTonePhase[ch] >> (Self.ssgToneShift + Self.ssgOversamplingShift)) & 1)
                    : 0
                let noiseBit = noiseEnabled[ch] ? lastNoiseBit : 0
                let gate = toneBit | noiseBit
                // Per-channel mute mask (debug only; branch is always-taken in normal use).
                let ssgMuted = (debugChannelMask.ssg >> ch) & 1 == 0
                // When both tone and noise are disabled for a channel, output 0
                // instead of -level. This eliminates the DC offset that causes
                // audible clicks when games disable the mixer before clearing
                // volumes. Real hardware removes this DC via AC coupling.
                if !ssgMuted && !(!toneEnabled[ch] && !noiseEnabled[ch]) {
                    let level = (ssgVolume[ch] & 0x10) != 0 ? envelopeLevel : ssgOutputLevel[ch]
                    sample += gate != 0 ? level : -level
                }
                ssgTonePhase[ch] &+= ssgToneStep[ch]
            }

            ssgNoisePhase &+= ssgNoiseStep
            ssgEnvelopePhase &+= ssgEnvelopeStep
            if ssgEnvelopePhase >= Self.ssgEnvelopeWrap {
                if (ssgEnvShape & 0x0B) != 0x0A {
                    ssgEnvelopePhase |= Self.ssgEnvelopeHoldBit
                }
                ssgEnvelopePhase &= Self.ssgEnvelopeWrap - 1
            }
        }

        updateSSGDebugState(noiseBit: lastNoiseBit)
        return Float(sample) / Float(Self.ssgOversamplingCount * 0x4000)
    }

    /// SSG 16-step volume table (legacy, kept for reference).
    public static let ssgVolumeTable: [Float] = [
        0.0,            // 0  (silence)
        0.00781250,     // 1  pow(2, -7.0)
        0.01104854,     // 2  pow(2, -6.5)
        0.01562500,     // 3  pow(2, -6.0)
        0.02209709,     // 4  pow(2, -5.5)
        0.03125000,     // 5  pow(2, -5.0)
        0.04419417,     // 6  pow(2, -4.5)
        0.06250000,     // 7  pow(2, -4.0)
        0.08838835,     // 8  pow(2, -3.5)
        0.12500000,     // 9  pow(2, -3.0)
        0.17677670,     // 10 pow(2, -2.5)
        0.25000000,     // 11 pow(2, -2.0)
        0.35355339,     // 12 pow(2, -1.5)
        0.50000000,     // 13 pow(2, -1.0)
        0.70710678,     // 14 pow(2, -0.5)
        1.00000000,     // 15 pow(2,  0.0)
    ]

    /// SSG 32-step volume table (OPNA mode, fmgen/BubiC compatible).
    /// Step factor: 2^(1/4) ≈ 1.189207115 per level (~1.5 dB/step).
    /// Fixed volume (0-15) maps to odd indices [1,3,5,...,31] (same 3 dB/step as 16-step).
    /// Envelope uses all 32 levels for smooth transitions.
    public static let ssgVolumeTable32: [Float] = {
        var table = [Float](repeating: 0, count: 32)
        // Entry 31 = max (1.0), each step divides by 2^(1/4)
        var level: Float = 1.0
        let step: Float = 1.0 / 1.189207115  // 2^(-1/4)
        for i in stride(from: 31, through: 2, by: -1) {
            table[i] = level
            level *= step
        }
        // Entries 0 and 1 = silence
        table[0] = 0
        table[1] = 0
        return table
    }()

    private static let ssgEmitTable: [Int] = {
        var table = [Int](repeating: 0, count: 32)
        var level = Double(0x4000) / 3.0
        for i in stride(from: 31, through: 2, by: -1) {
            table[i] = Int(level)
            level /= 1.189207115
        }
        return table
    }()

    private static let ssgNoiseTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: ssgNoiseTableSize)
        var noise = 14_321
        for i in 0..<ssgNoiseTableSize {
            var bits: UInt32 = 0
            for _ in 0..<32 {
                bits = (bits << 1) | UInt32(noise & 1)
                noise = (noise >> 1) | (((noise << 14) ^ (noise << 16)) & 0x10000)
            }
            table[i] = bits
        }
        return table
    }()

    private static let ssgEnvelopeTable: [[Int]] = {
        let table1: [UInt8] = [
            2, 0, 2, 0, 2, 0, 2, 0, 1, 0, 1, 0, 1, 0, 1, 0,
            2, 2, 2, 0, 2, 1, 2, 3, 1, 1, 1, 3, 1, 2, 1, 0,
        ]
        let table2: [UInt8] = [0, 0, 31, 31]
        let table3: [Int] = [0, 1, -1, 0]

        var tables = Array(repeating: Array(repeating: 0, count: 64), count: 16)
        for shape in 0..<16 {
            for half in 0..<2 {
                var value = Int(table2[Int(table1[shape * 2 + half])])
                for step in 0..<32 {
                    tables[shape][half * 32 + step] = ssgEmitTable[value]
                    value += table3[Int(table1[shape * 2 + half])]
                }
            }
        }
        return tables
    }()

    private func updateSSGToneStep(_ ch: Int) {
        let raw = Int(ssgTonePeriod[ch] & 0x0FFF)
        ssgToneStep[ch] = raw > 0 ? Self.ssgTonePeriodBase / UInt32(raw) : Self.ssgTonePeriodBase
    }

    private func updateSSGNoiseStep() {
        let raw = Int(ssgNoisePeriod & 0x1F)
        ssgNoiseStep = raw > 0 ? Self.ssgNoisePeriodBase / UInt32(raw) : Self.ssgNoisePeriodBase
    }

    private func updateSSGEnvelopeStep() {
        let raw = Int(ssgEnvPeriod)
        ssgEnvelopeStep = raw > 0
            ? Self.ssgEnvelopePeriodBase / UInt32(raw)
            : Self.ssgEnvelopePeriodBase * 2
    }

    private func updateSSGOutputLevel(_ ch: Int) {
        ssgOutputLevel[ch] = Self.ssgEmitTable[Int(ssgVolume[ch] & 0x0F) * 2 + 1]
    }

    private func updateSSGDebugState(noiseBit: Int) {
        ssgToneCounter = ssgTonePhase.map(Int.init)
        ssgToneOutput = ssgTonePhase.map {
            (($0 >> (Self.ssgToneShift + Self.ssgOversamplingShift)) & 1) != 0
        }
        ssgNoiseCounter = Int(ssgNoisePhase)
        ssgNoiseOutput = noiseBit != 0
        ssgEnvCounter = Int(ssgEnvelopePhase)
        ssgEnvPosition = Int((ssgEnvelopePhase >> (Self.ssgEnvShift + Self.ssgOversamplingShift)) & 0x3F)
        ssgEnvHolding = (ssgEnvelopePhase & Self.ssgEnvelopeHoldBit) != 0
        ssgNoiseLFSR = Self.ssgNoiseTable[
            Int(
                (ssgNoisePhase >> (Self.ssgNoiseShift + Self.ssgOversamplingShift + 6))
                    & UInt32(Self.ssgNoiseTableSize - 1)
            )
        ]
    }

    // MARK: - Port I/O

    /// Read port 0x44: status register
    public func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if timerAOverflow { status |= 0x01 }
        if timerBOverflow { status |= 0x02 }
        if busyStatusCounter > 0 { status |= 0x80 }
        return status
    }

    /// When true, report Sound Board ID as YM2203 (OPN) instead of YM2608 (OPNA).
    /// Programs that check register 0xFF will see 0x00 and skip OPNA-specific features.
    public var forceOPNMode: Bool = false

    /// Read port 0x45: data read
    public func readData() -> UInt8 {
        // Register 0xFF: Sound Board ID (QUASI88/BubiC confirmed)
        // 0x00 = YM2203 (OPN), 0x01 = YM2608 (OPNA)
        if selectedAddr == 0xFF {
            return forceOPNMode ? 0x00 : 0x01
        }
        // SSG Port A/B: joystick input (active-low, 0xFF = no buttons pressed)
        if selectedAddr == 0x0E || selectedAddr == 0x0F {
            return 0xFF
        }
        return registers[Int(selectedAddr)]
    }

    /// Read port 0x46: extended status (fmgen ReadStatusEx)
    /// Bit layout: [5]=PCMBSY, [3]=BRDY (forced on), [2]=EOS, [1]=TimerB, [0]=TimerA
    /// BRDY is always forced on (status | 0x08) then masked by statusMask.
    public func readExtStatus() -> UInt8 {
        var status: UInt8 = 0
        if timerAOverflow { status |= 0x01 }
        if timerBOverflow { status |= 0x02 }
        status |= adpcmStatusFlags  // EOS (bit 2), etc.
        if busyStatusCounter > 0 { status |= 0x80 }
        return ((status | 0x08) & statusMask) | (adpcmPlaying ? 0x20 : 0)
    }

    /// Read port 0x47: extended data read
    public func readExtData() -> UInt8 {
        if selectedExtAddr == 0x08, (adpcmControl1 & 0x60) == 0x20 {
            return readADPCMRAMByte()
        }
        return extRegisters[Int(selectedExtAddr)]
    }

    /// Read one byte from ADPCM RAM at adpcmMemAddr (fmgen ReadRAM).
    /// Returns the previously latched byte, then prefetches the next and
    /// advances memaddr. Matches the "dummy read" behavior real YM2608
    /// programs rely on (e.g. TROUBADOUR RAM DISK on DARK SHRINE).
    private func readADPCMRAMByte() -> UInt8 {
        let data = adpcmReadBuffer

        if adpcmUsesEightBitRAMLayout {
            let base = Int((adpcmMemAddr >> 4) & 0x7FFF)
            let bank = Int((adpcmMemAddr >> 1) & 0x07)
            let mask = UInt8(1 << bank)
            if base + 0x38000 < adpcmRAM.count {
                var byte: UInt8 = 0
                let offsets = [0x00000, 0x08000, 0x10000, 0x18000, 0x20000, 0x28000, 0x30000, 0x38000]
                for (i, offset) in offsets.enumerated() {
                    if (adpcmRAM[base + offset] & mask) != 0 {
                        byte |= UInt8(1 << i)
                    }
                }
                adpcmReadBuffer = byte
            }
            adpcmMemAddr &+= 2
        } else {
            let ramAddr = Int((adpcmMemAddr >> 4) & 0x3FFFF)
            if ramAddr < adpcmRAM.count {
                adpcmReadBuffer = adpcmRAM[ramAddr]
            }
            adpcmMemAddr &+= 16
        }

        let internalStopAddr = (adpcmStopAddr + 1) << 6
        if adpcmMemAddr == internalStopAddr {
            adpcmStatusFlags |= 0x04
            adpcmMemAddr &= 0x3FFFFF
            updateIRQLine()
        }
        if adpcmMemAddr >= adpcmLimitAddr {
            adpcmMemAddr = 0
        }

        return data
    }

    /// Write port 0x44: address select (SSG + FM ch1-3)
    public func writeAddr(_ value: UInt8) {
        selectedAddr = value
    }

    /// Write port 0x45: data write (SSG + FM ch1-3)
    public func writeData(_ value: UInt8) {
        registers[Int(selectedAddr)] = value
        armBusyStatus()
        handleRegisterWrite(addr: selectedAddr, value: value)
    }

    /// Write port 0x46: address select (ADPCM + FM ch4-6)
    public func writeExtAddr(_ value: UInt8) {
        selectedExtAddr = value
    }

    /// Write port 0x47: data write (ADPCM + FM ch4-6)
    public func writeExtData(_ value: UInt8) {
        extRegisters[Int(selectedExtAddr)] = value
        armBusyStatus()
        handleExtRegisterWrite(addr: selectedExtAddr, value: value)
    }

    // MARK: - Register Handling

    /// Slot order mapping: YM2608 register slot → operator index
    private static let slotMap = [0, 2, 1, 3]

    /// Key On register channel mapping: register bits → internal channel index
    private static let keyOnChannelMap: [Int: Int] = [0: 0, 1: 1, 2: 2, 4: 3, 5: 4, 6: 5]

    /// SL table (fmgen sltable): register value → sustain level
    private static let sltable: [UInt32] = [
        0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 124
    ]

    private func handleRegisterWrite(addr: UInt8, value: UInt8) {
        switch addr {
        case 0x00...0x0D:
            handleSSGRegister(addr: addr, value: value)
        case 0x10...0x1D:
            handleRhythmRegister(addr: addr, value: value)
        case 0x22:
            fmSynth.setLFOFreq(value)
        case 0x24...0x27:
            handleTimerRegister(addr: addr, value: value)
        case 0x28:
            handleKeyOnOff(value: value)
        case 0x29:
            irqControl = value
            fmSynth.extendedChannelsEnabled = (value & 0x80) != 0
        default:
            handleFMRegister(addr: addr, value: value, channelBase: 0)
        }
    }

    private func handleSSGRegister(addr: UInt8, value: UInt8) {
        switch addr {
        case 0x00...0x05:
            let ch = Int(addr) / 2
            if addr & 1 == 0 {
                ssgTonePeriod[ch] = (ssgTonePeriod[ch] & 0xF00) | UInt16(value)
            } else {
                ssgTonePeriod[ch] = (ssgTonePeriod[ch] & 0x0FF) | (UInt16(value & 0x0F) << 8)
            }
            updateSSGToneStep(ch)
        case 0x06:
            ssgNoisePeriod = value & 0x1F
            updateSSGNoiseStep()
        case 0x07:
            ssgMixer = value
        case 0x08...0x0A:
            let ch = Int(addr) - 0x08
            ssgVolume[ch] = value & 0x1F
            updateSSGOutputLevel(ch)
        case 0x0B:
            ssgEnvPeriod = (ssgEnvPeriod & 0xFF00) | UInt16(value)
            updateSSGEnvelopeStep()
        case 0x0C:
            ssgEnvPeriod = (ssgEnvPeriod & 0x00FF) | (UInt16(value) << 8)
            updateSSGEnvelopeStep()
        case 0x0D:
            ssgEnvShape = value & 0x0F
            ssgEnvPosition = 0
            ssgEnvCounter = 0
            ssgEnvHolding = false
            ssgEnvelopePhase = 0
        default:
            break
        }
    }

    private func handleTimerRegister(addr: UInt8, value: UInt8) {
        switch addr {
        case 0x24:
            timerAValue = (timerAValue & 0x003) | (UInt16(value) << 2)
        case 0x25:
            timerAValue = (timerAValue & 0x3FC) | UInt16(value & 0x03)
        case 0x26:
            timerBValue = value
        case 0x27:
            let timerAWasEnabled = timerAEnabled
            let timerBWasEnabled = timerBEnabled
            timerAEnabled = (value & 0x01) != 0
            timerBEnabled = (value & 0x02) != 0
            timerAIRQEnable = (value & 0x04) != 0
            timerBIRQEnable = (value & 0x08) != 0
            if timerAWasEnabled != timerAEnabled {
                timerACounter = 0
            }
            if timerBWasEnabled != timerBEnabled {
                timerBCounter = 0
            }
            if value & 0x10 != 0 {
                timerAOverflow = false
            }
            if value & 0x20 != 0 {
                timerBOverflow = false
            }
            updateIRQLine()
            applyChannel3FrequencyRouting()
        default:
            break
        }
    }

    private func handleRhythmRegister(addr: UInt8, value: UInt8) {
        switch addr {
        case 0x10:
            if value & 0x80 == 0 {
                fmSynth.rhythmKey |= value & 0x3F
                for i in 0..<6 {
                    if value & (1 << i) != 0 {
                        fmSynth.rhythm[i].pos = 0
                    }
                }
            } else {
                fmSynth.rhythmKey &= ~value
            }
        case 0x11:
            fmSynth.rhythmTL = Int8(~value & 0x3F)
        case 0x18...0x1D:
            let idx = Int(addr - 0x18)
            fmSynth.rhythm[idx].pan = (value >> 6) & 3
            fmSynth.rhythm[idx].level = Int8(~value & 0x1F)
        default:
            break
        }
    }

    private func handleKeyOnOff(value: UInt8) {
        let chBits = value & 0x07
        guard let ch = Self.keyOnChannelMap[Int(chBits)] else { return }
        let ratio = fmSynth.ratio
        let opBits = (value >> 4) & 0x0F
        for i in 0..<4 {
            if (opBits >> i) & 1 != 0 {
                fmSynth.ch[ch].op[i].doKeyOn(ratio: ratio)
            } else {
                fmSynth.ch[ch].op[i].doKeyOff(ratio: ratio)
            }
        }
        // Maintain fmKeyOnMask (debug only; never read in sample-gen hot path).
        if opBits != 0 {
            fmKeyOnMask |= UInt8(1 << ch)
        } else {
            fmKeyOnMask &= ~UInt8(1 << ch)
        }
    }

    /// Handle extended register writes (ADPCM, rhythm, FM ch4-6).
    private func handleExtRegisterWrite(addr: UInt8, value: UInt8) {
        switch addr {
        // ADPCM-B Control Register 1 (ext reg 0x00, fmgen control1)
        case 0x00:
            adpcmControl1 = value
            if (value & 0x80) != 0, !adpcmPlaying {
                // Playback start (fmgen: memaddr=startaddr, adpcmx=0, adpcmd=127)
                adpcmPlaying = true
                adpcmMemAddr = adpcmStartAddr << 6
                adpcmAccum = 0
                adpcmStepSize = 127
                resetADPCMOutputPipeline()
                updateADPCMPlaybackDelta()
            }
            if (value & 0x60) == 0x60, (value & 0x80) == 0 {
                // Write mode: initialize memaddr to start address
                adpcmMemAddr = adpcmStartAddr << 6
                adpcmStatusFlags &= ~0x04  // Clear EOS
                updateIRQLine()
            }
            if (value & 0x60) == 0x20, (value & 0x80) == 0 {
                // Memory read mode: initialize memaddr to start address
                adpcmMemAddr = adpcmStartAddr << 6
                adpcmStatusFlags &= ~0x04  // Clear EOS
                adpcmReadBuffer = 0
                updateIRQLine()
            }
            if value & 0x01 != 0 {
                adpcmPlaying = false
            }

        // ADPCM-B Control Register 2 (ext reg 0x01, fmgen control2)
        case 0x01:
            adpcmControl2 = value

        case 0x02, 0x03:
            // extRegisters already updated by writeExtData before this call
            adpcmStartAddr = UInt32(extRegisters[0x03]) << 8 | UInt32(extRegisters[0x02])
            adpcmMemAddr = adpcmStartAddr << 6

        case 0x04, 0x05:
            adpcmStopAddr = UInt32(extRegisters[0x05]) << 8 | UInt32(extRegisters[0x04])

        // ADPCM-B Data Write (ext reg 0x08)
        case 0x08:
            if (adpcmControl1 & 0x60) == 0x60 {
                // Write data to ADPCM RAM (fmgen WriteRAM, 1-bit/8-bit layouts)
                writeADPCMRAMByte(value)

                let internalStopAddr = (adpcmStopAddr + 1) << 6
                if adpcmMemAddr == internalStopAddr {
                    adpcmStatusFlags |= 0x04  // Set EOS (bit 2)
                    adpcmMemAddr &= 0x3FFFFF
                    updateIRQLine()
                }
                if adpcmMemAddr >= adpcmLimitAddr {
                    adpcmMemAddr = 0
                }
            }

        case 0x09:
            adpcmDeltaN = (adpcmDeltaN & 0xFF00) | UInt16(value)
            adpcmDeltaN = max(256, adpcmDeltaN)  // fmgen: deltan = Max(256, deltan)
            updateADPCMPlaybackDelta()
        case 0x0A:
            adpcmDeltaN = (adpcmDeltaN & 0x00FF) | (UInt16(value) << 8)
            adpcmDeltaN = max(256, adpcmDeltaN)  // fmgen: deltan = Max(256, deltan)
            updateADPCMPlaybackDelta()

        case 0x0B:
            adpcmTotalLevel = value

        // ADPCM-B Limit Address (ext reg 0x0C-0x0D)
        case 0x0C, 0x0D:
            let limitL = UInt32(extRegisters[0x0C])
            let limitH = UInt32(extRegisters[0x0D])
            adpcmLimitAddr = ((limitH << 8 | limitL) + 1) << 6

        // ADPCM-B Flag Control (register 0x10 in bank 1, fmgen SetADPCMBReg)
        case 0x10:
            if value & 0x80 != 0 {
                // Reset ADPCM status flags (fmgen: status &= 0x03)
                adpcmStatusFlags = 0
            } else {
                // Set status mask: bits set in value are masked out
                // fmgen: stmask = ~(data & 0x1f)
                statusMask = ~(value & 0x1F)
            }
            updateIRQLine()

        default:
            handleFMRegister(addr: addr, value: value, channelBase: 3)
        }
    }

    /// Decode FM register writes for channels.
    private func handleFMRegister(addr: UInt8, value: UInt8, channelBase: Int) {
        let a = Int(addr)

        // Operator parameter registers: 0x30-0x9F
        if a >= 0x30 && a < 0xA0 {
            let ch = a & 0x03
            guard ch < 3 else { return }
            let opAndReg = (a - 0x30) / 4
            let regGroup = opAndReg / 4
            let slot = opAndReg % 4
            let op = Self.slotMap[slot]

            let chIdx = channelBase + ch
            guard chIdx < 6 else { return }

            switch regGroup {
            case 0:  // 0x30-0x3F: DT1/MUL
                fmSynth.ch[chIdx].op[op].detune = UInt32((value >> 4) & 0x07) * 32
                fmSynth.ch[chIdx].op[op].multiple = UInt32(value & 0x0F)
                fmSynth.ch[chIdx].op[op].paramChanged = true
            case 1:  // 0x40-0x4F: TL
                fmSynth.ch[chIdx].op[op].setTL(UInt32(value & 0x7F), csm: csmModeEnabled && chIdx == 2)
            case 2:  // 0x50-0x5F: KS/AR
                fmSynth.ch[chIdx].op[op].ks = UInt32((value >> 6) & 0x03)
                fmSynth.ch[chIdx].op[op].ar = UInt32(value & 0x1F) * 2
                fmSynth.ch[chIdx].op[op].paramChanged = true
            case 3:  // 0x60-0x6F: AM/DR
                fmSynth.ch[chIdx].op[op].amon = (value & 0x80) != 0
                fmSynth.ch[chIdx].op[op].dr = UInt32(value & 0x1F) * 2
                fmSynth.ch[chIdx].op[op].paramChanged = true
            case 4:  // 0x70-0x7F: SR
                fmSynth.ch[chIdx].op[op].sr = UInt32(value & 0x1F) * 2
                fmSynth.ch[chIdx].op[op].paramChanged = true
            case 5:  // 0x80-0x8F: SL/RR
                fmSynth.ch[chIdx].op[op].sl = Self.sltable[Int((value >> 4) & 0x0F)]
                fmSynth.ch[chIdx].op[op].rr = UInt32(value & 0x0F) * 4 + 2
                fmSynth.ch[chIdx].op[op].paramChanged = true
            case 6:  // 0x90-0x9F: SSG-EG
                fmSynth.ch[chIdx].op[op].setSSGEC(value)
            default:
                break
            }
        }

        // Channel-level registers: 0xA0-0xBF
        if a >= 0xA0 && a < 0xC0 {
            let ch = a & 0x03
            guard ch < 3 else { return }
            let chIdx = channelBase + ch

            if channelBase == 0, a >= 0xA8, a < 0xB0 {
                let specialIdx = ch
                switch a & 0xFC {
                case 0xAC:
                    // High byte: latch only
                    break
                case 0xA8:
                    // Low byte: read both bytes and apply
                    let lowAddr = UInt8(0xA8 + specialIdx)
                    let highAddr = UInt8(0xAC + specialIdx)
                    let low = UInt32(registers[Int(lowAddr)])
                    let high = UInt32(registers[Int(highAddr)]) << 8
                    fmFNum3[specialIdx] = low | high
                    applyChannel3FrequencyRouting()
                default:
                    break
                }
                return
            }

            switch a & 0xFC {
            case 0xA4:
                // High byte: latch only (already written to registers[])
                break
            case 0xA0:
                // Low byte: read both bytes from registers and apply
                let lowAddr = UInt8((a & 0x03) + 0xA0)
                let highAddr = UInt8((a & 0x03) + 0xA4)
                let low: UInt32
                let high: UInt32
                if channelBase == 0 {
                    low = UInt32(registers[Int(lowAddr)])
                    high = UInt32(registers[Int(highAddr)]) << 8
                } else {
                    low = UInt32(extRegisters[Int(lowAddr)])
                    high = UInt32(extRegisters[Int(highAddr)]) << 8
                }
                fmFNumMain[chIdx] = low | high
                applyMainChannelFrequency(chIdx)
            case 0xB0:
                // Feedback / Algorithm
                fmSynth.ch[chIdx].fb = feedbackShiftTable[Int((value >> 3) & 0x07)]
                fmSynth.ch[chIdx].setAlgorithm(Int(value & 0x07))
            case 0xB4:
                // Pan / LFO sensitivity
                let panL = (value & 0x80) != 0
                let panR = (value & 0x40) != 0
                fmSynth.ch[chIdx].panLeft = panL
                fmSynth.ch[chIdx].panRight = panR
                if !(panL && panR) { fmPanDetected = true }
                fmSynth.ch[chIdx].pmsIndex = Int(value & 0x07)
                // Set AM sensitivity on all operators
                let ms = UInt32(value)
                for i in 0..<4 {
                    fmSynth.ch[chIdx].op[i].ms = ms
                    fmSynth.ch[chIdx].op[i].paramChanged = true
                }
            default:
                break
            }
        }
    }

    private var ch3PerOperatorFreqEnabled: Bool {
        (registers[0x27] & 0xC0) != 0
    }

    private var csmModeEnabled: Bool {
        (registers[0x27] & 0x80) != 0
    }

    private func triggerCSMKeyControl() {
        let ratio = fmSynth.ratio
        for i in 0..<4 {
            fmSynth.ch[2].op[i].doKeyOff(ratio: ratio)
        }
        for i in 0..<4 {
            fmSynth.ch[2].op[i].doKeyOn(ratio: ratio)
        }
    }

    private func updateIRQLine() {
        let statusBits = (timerAOverflow ? UInt8(0x01) : 0)
            | (timerBOverflow ? UInt8(0x02) : 0)
            | adpcmStatusFlags
        let active = (statusBits & statusMask & irqControl) != 0
        if active {
            if !irqAsserted {
                irqAsserted = true
                onTimerIRQ?()
            }
        } else {
            irqAsserted = false
        }
    }

    private var busyDurationTStates: Int {
        let hardwareCpuClock = clock8MHz ? Self.cpuClockHz8MHz : Self.cpuClockHz4MHz
        return (hardwareCpuClock * Self.busyUsec + 999_999) / 1_000_000
    }

    private func armBusyStatus() {
        busyStatusCounter = busyDurationTStates
    }

    private func applyMainChannelFrequency(_ chIdx: Int) {
        guard chIdx >= 0 && chIdx < fmFNumMain.count else { return }
        if chIdx == 2 {
            applyChannel3FrequencyRouting()
            return
        }
        fmSynth.ch[chIdx].setFNum(fmFNumMain[chIdx])
    }

    private func applyChannel3FrequencyRouting() {
        guard ch3PerOperatorFreqEnabled else {
            fmSynth.ch[2].setFNum(fmFNumMain[2])
            return
        }

        fmSynth.ch[2].op[0].setFNum(fmFNum3[1])
        fmSynth.ch[2].op[1].setFNum(fmFNum3[2])
        fmSynth.ch[2].op[2].setFNum(fmFNum3[0])
        fmSynth.ch[2].op[3].setFNum(fmFNumMain[2])
    }

    // MARK: - Rhythm Sample Loading

    /// Load rhythm WAV sample (signed 16-bit PCM, mono).
    /// Index: 0=BD, 1=SD, 2=TOP, 3=HH, 4=TOM, 5=RIM
    public func loadRhythmSample(index: Int, data: [Int16], sampleRate: Int) {
        fmSynth.loadRhythmSample(index: index, data: data, sampleRate: sampleRate)
    }
}
