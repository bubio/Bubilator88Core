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

  /// Which monitor the machine is wired to. Decides the reset-time geometry
  /// and, via `Machine.tStatesPerLine`, the length of a scanline. Applied at
  /// reset only, as on real hardware (it is a DIP switch).
  public var monitorType: MonitorType

  /// Cached scanline geometry, derived from the CRTC's own SET PARAMETER
  /// values — updated by `updateDynamicScanlines()`.
  ///
  /// Both are in CRTC scanline units, which is *not* the same as displayed
  /// graphic lines: a 24kHz 200-line screen is 25 rows of `char_height` 16,
  /// so it counts 400 active lines out of 448, not 200 out of 262.
  ///
  /// This used to special-case 200-line mode to the NTSC constant 262. That
  /// was wrong on two counts — 262 is not a PC-8801 line count, and it made
  /// the frame rate independent of the monitor — but it did guard a real
  /// transient; see `updateDynamicScanlines()`.
  public private(set) var dynamicTotalScanlines: Int = 0
  public private(set) var dynamicBlankingStart: Int = 0

  /// Recalculate cached scanline values after mode or parameter changes.
  ///
  /// The geometry is whatever software programmed, full stop: this is XM8's
  /// `(height + vretrace) * char_height` (`pc88.cpp:2499`) with no correction
  /// applied. The only rejection is structural nonsense — a zeroed or
  /// inside-out CRTC, which would divide the frame into nothing.
  ///
  /// **Why there is no plausibility clamp.** The old code forced 262 lines in
  /// 200-line mode and clamped the 400-line formula to >= 262, because the
  /// power-on defaults (`char_height` 8, `vretrace` 1) produced (25+1)×8 = 208
  /// lines in the window between "software flipped port 0x31" and "software
  /// wrote the matching SET PARAMETER" — and 208 breaks VRTC timing badly
  /// enough to hang boot. `reset()` now seeds monitor-correct defaults (448 at
  /// 24kHz, 256 at 15kHz), so that window never contains invalid geometry and
  /// the clamp has nothing left to defend.
  ///
  /// A frame-rate window is *not* an acceptable replacement, tempting as it
  /// looks. On a 15kHz monitor the 448-line geometry every title writes is
  /// 15,980 / 448 = 35.7Hz — outside any "plausible CRT" range, and yet
  /// exactly what the formula yields. Rejecting it would freeze the CRTC at
  /// its reset geometry and make the 15kHz setting quietly ignore software.
  private func updateDynamicScanlines() {
    let total = (Int(linesPerScreen) + vretrace) * Int(charLinesPerRow)
    let active = Int(linesPerScreen) * Int(charLinesPerRow)
    guard total > 0, active > 0, active < total else { return }
    dynamicTotalScanlines = total
    dynamicBlankingStart = active
  }

  /// Recompute the cached geometry from the current parameters.
  ///
  /// Needed after a bulk restore (save state) where the parameters are
  /// assigned one at a time: an intermediate combination can be structurally
  /// invalid and get rejected, so the settled values need one more pass.
  public func refreshScanlineGeometry() {
    updateDynamicScanlines()
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

  /// 200-line mode (true) or 400-line mode (false).
  ///
  /// Purely a display-mode flag as far as the CRTC is concerned: scanline
  /// geometry comes from the SET PARAMETER values alone. (It used to switch
  /// the line count to the NTSC 262; see `updateDynamicScanlines()`.)
  public var mode200Line: Bool = true

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

  /// Bytes per DMA row.
  ///
  /// uPD3301 attribute modes (param 4 bits 7-5):
  /// - TRANSPARENT (0/2): char block + attribute pair block = charsPerLine + attrsPerLine * 2
  /// - NONETRANSPARENT (4/5): char block only = charsPerLine (attributes not stored in VRAM,
  ///   display is monochrome). Confirmed via vraminfo.html and BubiC pc88.cpp:2836
  ///   `dmac.run(2, 80 + crtc.attrib.num * 2)` where attrib.num = 0 in non-transparent.
  public var bytesPerDMARow: Int {
    if attrNonTransparent {
      return Int(charsPerLine)
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

  /// Blink rate in frames (BubiC pc88.cpp:4012,4076 — default 24,
  /// reset param 1 bits 7-6 give 32/64/96/128).
  public var blinkRate: Int = 24

  /// Frame-scoped blink counter. Advanced once per rendered frame.
  public var blinkCounter: Int = 0

  /// XOR mask applied to internal SECRET bit (0x02) during blink-off phase.
  /// BubiC pc88.cpp:4178 — reuses the SECRET bit to hide blinking text.
  public var blinkAttribBit: UInt8 = 0

  /// CRTC hardware cursor blink-off flag. True = cursor is HIDDEN this frame.
  /// BubiC pc88.cpp:4179-4181 — toggles twice per `blinkRate` window, so the
  /// cursor blinks at ~rate/2 cadence (≈ 0.2s @ rate=24, 60Hz) — about twice
  /// as fast as the attribute BLINK rate.
  public var blinkCursorOff: Bool = false

  /// Advance blink counter. Called once per rendered frame.
  /// BubiC pc88.cpp:4173 — counter wraps at `blinkRate`, attribute BLINK
  /// is masked while counter is below `blinkRate / 4` (off ~25%, on ~75%).
  public func updateBlink() {
    blinkCounter += 1
    if blinkCounter > blinkRate { blinkCounter = 0 }
    blinkAttribBit = blinkCounter < blinkRate / 4 ? 0x02 : 0x00
    let q = blinkRate / 4
    let h = blinkRate / 2
    blinkCursorOff = (blinkCounter <= q) || (h <= blinkCounter && blinkCounter <= 3 * q)
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

  public init(monitorType: MonitorType = .khz24) {
    self.monitorType = monitorType
    reset()
  }

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
  ///
  /// `monitorType` is *not* cleared here — it is a DIP switch, so the caller
  /// sets it before resetting and it survives the reset.
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
    charLinesPerRow = monitorType.resetCharLinesPerRow
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
    blinkRate = 24
    blinkCounter = 0
    blinkAttribBit = 0
    vretrace = monitorType.resetVretrace
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
      updateBlink()
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
    // BubiC pc88.cpp:4076 — blink.rate = 32 * ((data >> 6) + 1) → 32/64/96/128 frames
    blinkRate = 32 * (Int((parameters[1] >> 6) & 0x03) + 1)

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
