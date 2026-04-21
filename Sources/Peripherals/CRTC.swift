/// uPD3301 CRTC behavioral model.
///
/// Manages scanline timing, VRTC (vertical retrace) flag,
/// and VSYNC interrupt generation.
///
/// Display modes:
///   200-line color: 640x200, 8 colors (3 planes)
///   400-line mono:  640x400, B&W
///
/// Timing (200-line, 60Hz NTSC):
///   Total lines per frame: 262
///   Active display: ~200 lines
///   Vertical blanking: ~62 lines
///   T-states per scanline: clock / 60Hz / 262
///
/// Command set (bits 7-5):
///   0x00 (cmd=0): Reset          — 5 parameter bytes (display format)
///   0x20 (cmd=1): Start Display  — no params, bit 0 = reverse
///   0x40 (cmd=2): Set Int Mask   — no extra params, bits 1-0 = mask
///   0x60 (cmd=3): Read Light Pen — clears LP flag
///   0x80 (cmd=4): Load Cursor    — 2 parameter bytes (X, Y), bit 0 = enable
///   0xA0 (cmd=5): Reset Int      — clears interrupt flags
///   0xC0 (cmd=6): Reset Counters — clears interrupt flags
public final class CRTC {

    // MARK: - Display Parameters

    /// Total scanlines per frame — 200-line (NTSC)
    public static let totalScanlines200 = 262

    /// Active display scanlines — 200-line
    public static let activeScanlines200 = 200

    /// Blanking start — 200-line
    public static let blankingStart200 = 200

    /// Legacy alias for static references
    public static let totalScanlines = totalScanlines200

    /// Dynamic total scanlines for current mode.
    /// 200-line: 262 (NTSC), 400-line: (linesPerScreen + vretrace) * charLinesPerRow
    /// Guard: if mode200Line=false but CRTC params are still for 200-line mode,
    /// the formula gives ~208 which breaks VRTC timing. Clamp to >= 262.
    /// Cached dynamic scanline counts — updated by updateDynamicScanlines()
    public private(set) var dynamicTotalScanlines: Int = totalScanlines200
    public private(set) var dynamicBlankingStart: Int = blankingStart200

    /// Recalculate cached scanline values after mode or parameter changes.
    private func updateDynamicScanlines() {
        if mode200Line {
            dynamicTotalScanlines = Self.totalScanlines200
            dynamicBlankingStart = Self.blankingStart200
        } else {
            dynamicTotalScanlines = max(
                (Int(linesPerScreen) + vretrace) * Int(charLinesPerRow),
                Self.totalScanlines200
            )
            dynamicBlankingStart = max(
                Int(linesPerScreen) * Int(charLinesPerRow),
                Self.blankingStart200
            )
        }
    }

    // MARK: - State

    /// Current scanline (0-261)
    public var scanline: Int = 0

    /// VRTC flag — true during vertical blanking
    public var vrtcFlag: Bool = false

    /// T-state accumulator for scanline timing
    public var tStateAccumulator: Int = 0

    /// Whether display is enabled (CRTC start command issued)
    public var displayEnabled: Bool = false

    /// 200-line mode (true) or 400-line mode (false)
    public var mode200Line: Bool = true {
        didSet { updateDynamicScanlines() }
    }

    // MARK: - uPD3301 Registers

    /// Parameter bytes written via port 0x50
    public var parameters: [UInt8] = []
    package var parameterIndex: Int = 0
    package var expectedParameters: Int = 0
    package var currentCommand: UInt8 = 0

    /// Characters per line (from Reset param 0)
    public var charsPerLine: UInt8 = 80

    /// Lines per screen (from Reset param 1)
    public var linesPerScreen: UInt8 = 25 {
        didSet { updateDynamicScanlines() }
    }

    /// Character lines per row (from Reset param 2, bits 4-0 + 1)
    public var charLinesPerRow: UInt8 = 8 {
        didSet { updateDynamicScanlines() }
    }

    /// Skip line flag (from Reset param 2, bit 7)
    public var skipLine: Bool = false

    /// Display mode (from Reset param 4, bits 7-5):
    ///   bit 7: non-transparent (1) / transparent (0)
    ///   bit 6: color (1) / mono (0)
    ///   bit 5: no attributes (1) / attributes (0)
    public var displayMode: UInt8 = 0

    /// Attribute mode: false = transparent (position/value pairs), true = non-transparent
    public var attrNonTransparent: Bool = false

    /// Attribute bytes per line (from Reset param 4, bits 4-0 + 1)
    public var attrsPerLine: UInt8 = 20

    /// Bytes per DMA row = charsPerLine + attrsPerLine * 2 (transparent mode)
    public var bytesPerDMARow: Int {
        if attrNonTransparent {
            return Int(charsPerLine) * 2  // char+attr interleaved
        }
        return Int(charsPerLine) + Int(attrsPerLine) * 2
    }

    /// Interrupt mask (from Set Interrupt Mask command, bits 1-0)
    /// Text display requires intrMask == 3 (both bits set)
    public var intrMask: UInt8 = 0

    /// Reverse display flag (from Start Display command, bit 0)
    public var reverseDisplay: Bool = false

    /// Cursor position and enable
    public var cursorX: Int = -1
    public var cursorY: Int = -1
    public var cursorEnabled: Bool = false
    /// Cursor display mode (from Reset param 2: 0=underline, 1=block)
    public var cursorMode: UInt8 = 0

    /// Blink rate (from Reset param 1, bits 7-6)
    public var blinkRate: Int = 16

    /// Frame-scoped blink counter. Advanced once per rendered frame.
    public var blinkCounter: Int = 0

    /// XOR mask applied to internal SECRET bit (0x02) during blink-off phase.
    /// BubiC pc88.cpp:4178 — reuses the SECRET bit to hide blinking text.
    public var blinkAttribBit: UInt8 = 0

    /// Advance blink counter. Called once per rendered frame.
    public func updateBlink() {
        blinkCounter += 1
        if blinkCounter > blinkRate { blinkCounter = 0 }
        blinkAttribBit = blinkCounter < blinkRate / 4 ? 0x02 : 0x00
    }

    /// Vertical retrace lines (from Reset param 3, bits 7-5)
    public var vretrace: Int = 1 {
        didSet { updateDynamicScanlines() }
    }

    /// Status flags
    public var dataReady: Bool = false    // DMA data ready
    public var lightPen: Bool = false     // Light pen detect (unused)
    public var underrun: Bool = false     // DMA underrun

    // MARK: - DMA Buffer (BubiC-style)

    /// Internal DMA buffer — captures text VRAM snapshot during VRTC.
    /// BubiC: buffer[120*200] (24KB), written by DMA transfer, read by renderer.
    public var dmaBuffer: [UInt8] = Array(repeating: 0, count: 24000)

    /// Write pointer into dmaBuffer (number of bytes transferred).
    public var dmaBufferPtr: Int = 0

    /// True when DMA buffer read exceeds written data (underrun → suppress text).
    public var dmaUnderrun: Bool = false

    // MARK: - Interrupt callback

    /// Called when VSYNC occurs. Machine should wire this to InterruptController.
    public var onVSYNC: (() -> Void)?

    // MARK: - Init

    public init() {}

    // MARK: - DMA Buffer Operations

    /// Prepare buffer for new frame DMA transfer (called at VRTC start).
    public func startDMATransfer() {
        dmaBuffer.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.initialize(repeating: 0, count: buf.count)
        }
        dmaBufferPtr = 0
        dmaUnderrun = false
    }

    /// Write one byte into DMA buffer (called during DMA transfer).
    @inline(__always)
    public func writeDMABuffer(_ data: UInt8) {
        dmaBuffer[dmaBufferPtr & 0x3FFF] = data
        dmaBufferPtr += 1
    }

    /// Read one byte from DMA buffer (called by renderer). Returns 0 if offset exceeds written data.
    @inline(__always)
    public func readDMABuffer(at offset: Int) -> UInt8 {
        if offset < dmaBufferPtr {
            return dmaBuffer[offset]
        }
        return 0
    }

    /// Reset to power-on state.
    public func reset() {
        scanline = 0
        vrtcFlag = false
        tStateAccumulator = 0
        displayEnabled = false
        mode200Line = true
        parameters = []
        parameterIndex = 0
        expectedParameters = 0
        currentCommand = 0
        charsPerLine = 80
        linesPerScreen = 25
        charLinesPerRow = 8
        skipLine = false
        displayMode = 0
        attrNonTransparent = false
        attrsPerLine = 20
        intrMask = 0
        reverseDisplay = false
        cursorX = -1
        cursorY = -1
        cursorEnabled = false
        cursorMode = 0
        blinkRate = 16
        blinkCounter = 0
        blinkAttribBit = 0
        vretrace = 1
        dataReady = false
        lightPen = false
        underrun = false
        dmaBuffer.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.initialize(repeating: 0, count: buf.count)
        }
        dmaBufferPtr = 0
        dmaUnderrun = true  // No data yet → underrun until first DMA transfer
        updateDynamicScanlines()
    }

    // MARK: - Timing

    /// Advance CRTC by the given number of T-states.
    /// `tStatesPerLine` depends on CPU clock (4MHz or 8MHz).
    public func tick(tStates: Int, tStatesPerLine: Int) {
        tStateAccumulator += tStates

        while tStateAccumulator >= tStatesPerLine {
            tStateAccumulator -= tStatesPerLine
            advanceScanline()
        }
    }

    private func advanceScanline() {
        scanline += 1

        let total = dynamicTotalScanlines
        if scanline >= total {
            scanline = 0
        }

        // VRTC flag: active during vertical blanking
        let wasVRTC = vrtcFlag
        vrtcFlag = scanline >= dynamicBlankingStart

        // Rising edge of VRTC → VSYNC interrupt
        if vrtcFlag && !wasVRTC {
            onVSYNC?()
        }
    }

    // MARK: - Port I/O

    /// Read status register (port 0x51).
    /// uPD3301 status bits:
    ///   bit 7 (0x80): DR — data ready (BubiC); QUASI88 omits this
    ///   bit 5 (0x20): VRTC — vertical retrace (active high)
    ///   bit 4 (0x10): VE — display enabled
    ///   bit 3 (0x08): U — DMA underrun
    ///   bit 2 (0x04): N — special control character interrupt
    ///   bit 1 (0x02): E — display end interrupt
    ///   bit 0 (0x01): LP — light pen input
    /// BubiC: if underrun, clears VE on read
    public func readStatus() -> UInt8 {
        var status: UInt8 = 0
        if dataReady { status |= 0x80 }        // bit 7: DR (BubiC convention)
        if vrtcFlag { status |= 0x20 }         // bit 5: VRTC
        if displayEnabled { status |= 0x10 }   // bit 4: VE
        if underrun {
            status |= 0x08                     // bit 3: U (underrun)
            status &= ~0x10                    // BubiC: underrun masks VE on read
        }
        if lightPen { status |= 0x01 }         // bit 0: LP
        return status
    }

    /// Write command register (port 0x51).
    public func writeCommand(_ value: UInt8) {
        let cmd = value & 0xE0  // Upper 3 bits = command

        switch cmd {
        case 0x00:
            // Reset — 5 parameter bytes follow
            // BubiC: status &= ~0x16; status |= 0x80 (keep DR set)
            displayEnabled = false
            underrun = false
            dmaBufferPtr = 0     // Clear buffer → underrun until next DMA transfer
            dmaUnderrun = true
            dataReady = true  // DR stays set after reset (BubiC confirmed)
            cursorX = -1
            cursorY = -1
            expectedParameters = 5
            parameterIndex = 0
            parameters = Array(repeating: 0, count: 5)

        case 0x20:
            // Start Display — no parameters
            // BubiC: status |= 0x90; status &= ~8 (set DR + VE, clear underrun)
            reverseDisplay = (value & 0x01) != 0
            displayEnabled = true
            underrun = false
            dataReady = true  // DR set on Start Display (BubiC confirmed)

        case 0x40:
            // Set Interrupt Mask — bits 1-0 of command byte
            if (value & 0x01) == 0 {
                // BubiC: status = 0x80 (reset all but DR)
                displayEnabled = false
            }
            intrMask = value & 0x03

        case 0x60:
            // Read Light Pen — clears LP flag
            lightPen = false

        case 0x80:
            // Load Cursor Position — 2 parameter bytes follow
            cursorEnabled = (value & 0x01) != 0
            if !cursorEnabled {
                cursorX = -1
                cursorY = -1
            }
            expectedParameters = 2
            parameterIndex = 0
            parameters = Array(repeating: 0, count: 2)

        case 0xA0:
            // Reset Interrupt
            break

        case 0xC0:
            // Reset Counters
            break

        default:
            break
        }

        currentCommand = cmd
    }

    /// Write parameter register (port 0x50).
    public func writeParameter(_ value: UInt8) {
        if parameterIndex < expectedParameters {
            parameters[parameterIndex] = value
            parameterIndex += 1

            // Parse parameters when all received
            if parameterIndex == expectedParameters {
                switch currentCommand {
                case 0x00:
                    parseResetParameters()
                case 0x80:
                    parseCursorParameters()
                default:
                    break
                }
            }
        }
    }

    /// Read parameter register (port 0x50) — typically for light pen data.
    public func readParameter() -> UInt8 {
        return 0x00
    }

    // MARK: - Parameter Parsing

    private func parseResetParameters() {
        guard parameters.count >= 5 else { return }

        // Parameter 0: characters per line (bits 6-0 + 2)
        charsPerLine = (parameters[0] & 0x7F) + 2

        // Parameter 1: lines per screen (bits 5-0 + 1), blink rate (bits 7-6)
        // QUASI88: clamp to 20 or 25 (values 21-24 become 25)
        let rawLines = (parameters[1] & 0x3F) + 1
        if rawLines <= 20 {
            linesPerScreen = 20
        } else {
            linesPerScreen = 25
        }
        // QUASI88: blink_cycle = (value >> 6) * 8 + 8 → gives 8, 16, 24, 32 frames
        blinkRate = Int((parameters[1] >> 6) & 0x03) * 8 + 8

        // Parameter 2: char height (bits 4-0 + 1), cursor mode (bits 6-5), skip line (bit 7)
        charLinesPerRow = (parameters[2] & 0x1F) + 1
        cursorMode = (parameters[2] >> 5) & 0x03
        skipLine = (parameters[2] & 0x80) != 0

        // Parameter 3: vertical retrace (bits 7-5 + 1)
        vretrace = Int((parameters[3] >> 5) & 0x07) + 1

        // Parameter 4: display mode (bits 7-5), attribute count (bits 4-0 + 1)
        displayMode = (parameters[4] >> 5) & 0x07
        attrNonTransparent = (parameters[4] & 0x80) != 0
        let attrField = (parameters[4] & 0x1F) + 1
        attrsPerLine = (displayMode & 0x01) != 0 ? 0 : min(attrField, 20)
        updateDynamicScanlines()
    }

    private func parseCursorParameters() {
        guard parameters.count >= 2 else { return }
        if cursorEnabled {
            cursorX = Int(parameters[0])
            cursorY = Int(parameters[1])
        }
    }
}
