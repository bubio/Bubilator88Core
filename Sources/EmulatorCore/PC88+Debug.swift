// PC88+Debug.swift — what the debugger and development tools may see.
//
// The components (Z80, YM2608, CRTC, the buses) are `package`: nothing outside
// this package can name them. The debugger still has to look inside, so this
// file relays exactly what it reads, as plain values, under
// `@_spi(Debug) import EmulatorCore`. A component can be reorganised without
// touching the debugger as long as these values can still be produced.
//
// Same threading contract as the rest of `PC88`: call from the queue that
// owns the instance. See docs/develop/EMULATOR_CORE_SPLIT.md §7.

import FMSynthesis
import Foundation
import Z80

extension PC88 {

  // MARK: - Debugger

  /// The attached debugger, if any. Setting it wires breakpoints into the
  /// main CPU's instruction loop.
  @_spi(Debug) public var debugger: Debugger? {
    get { machine.debugger }
    set { machine.debugger = newValue }
  }

  /// T-states the main CPU has run since the last reset.
  @_spi(Debug) public var totalTStates: UInt64 {
    machine.totalTStates
  }

  // MARK: - CPUs

  @_spi(Debug) public enum CPU: Sendable {
    /// The main Z80.
    case main
    /// The disk subsystem's Z80.
    case sub
  }

  /// A copy of one Z80's registers.
  @_spi(Debug) public struct CPURegisters: Equatable, Sendable {
    public var pc: UInt16, sp: UInt16
    public var af: UInt16, bc: UInt16, de: UInt16, hl: UInt16
    public var ix: UInt16, iy: UInt16
    public var af2: UInt16, bc2: UInt16, de2: UInt16, hl2: UInt16
    public var i: UInt8, r: UInt8
    public var iff1: Bool, iff2: Bool
    public var im: UInt8
    public var halted: Bool

    init(_ cpu: Z80) {
      pc = cpu.pc; sp = cpu.sp
      af = cpu.af; bc = cpu.bc; de = cpu.de; hl = cpu.hl
      ix = cpu.ix; iy = cpu.iy
      af2 = cpu.af2; bc2 = cpu.bc2; de2 = cpu.de2; hl2 = cpu.hl2
      i = cpu.i; r = cpu.r
      iff1 = cpu.iff1; iff2 = cpu.iff2
      im = cpu.im
      halted = cpu.halted
    }
  }

  @_spi(Debug) public func registers(of cpu: CPU) -> CPURegisters {
    switch cpu {
    case .main: return CPURegisters(machine.cpu)
    case .sub: return CPURegisters(machine.subSystem.subCpu)
    }
  }

  /// One byte as `cpu` would read it at `address` right now (through the
  /// current bank mapping).
  @_spi(Debug) public func readMemory(_ cpu: CPU, _ address: UInt16) -> UInt8 {
    switch cpu {
    case .main: return machine.bus.memRead(address)
    case .sub: return machine.subSystem.subBus.memRead(address)
    }
  }

  /// Runs `cpu` for exactly one instruction. Stepping the main CPU advances
  /// the whole machine by that instruction's T-states; stepping the sub CPU
  /// runs only the sub CPU.
  @_spi(Debug) public func stepInstruction(_ cpu: CPU) {
    switch cpu {
    case .main: _ = machine.tick()
    case .sub: _ = machine.subSystem.runSubCPU(maxTStates: 1)
    }
  }

  // MARK: - Video

  /// The three GVRAM planes and the palette they are shown with.
  @_spi(Debug) public struct GVRAMCapture: Sendable {
    public var blue: [UInt8], red: [UInt8], green: [UInt8]
    public var is400LineMode: Bool
    /// The programmable palette, expanded to 8-bit RGB.
    public var palette: [(r: UInt8, g: UInt8, b: UInt8)]
  }

  @_spi(Debug) public func captureGVRAM() -> GVRAMCapture {
    let bus = machine.bus
    let planes = bus.renderGVRAMPlanes()
    return GVRAMCapture(
      blue: planes.blue, red: planes.red, green: planes.green,
      is400LineMode: bus.is400LineMode,
      palette: ScreenRenderer.expandPalette(bus.palette)
    )
  }

  /// The text layer on its own, rendered, plus the raw codes behind it.
  @_spi(Debug) public struct TextVRAMCapture: Sendable {
    /// RGBA8, 640 wide; 400 lines tall in 400-line mode, 200 otherwise.
    public var image: [UInt8]
    public var is400LineMode: Bool
    /// Character codes, `columns` × `rows`.
    public var characters: [UInt8]
    /// Attribute bytes, `columns` × `rows`.
    public var attributes: [UInt8]
    /// 40 or 80.
    public var columns: Int
    public var rows: Int
    /// CRTC cursor, in character cells.
    public var cursorX: Int, cursorY: Int
    public var cursorEnabled: Bool
  }

  /// Renders the text layer alone over a flat grey, so text cells can be
  /// told apart from graphics masked to black.
  ///
  /// - Parameter backgroundGray: the grey level (R = G = B) behind the text.
  @_spi(Debug) public func captureTextVRAM(backgroundGray: UInt8) -> TextVRAMCapture {
    let bus = machine.bus
    let crtc = machine.crtc
    let chars = bus.readTextVRAM()
    let attrs = bus.readTextAttributes()
    let columns = bus.columns80 ? 80 : 40
    let rows = Int(crtc.linesPerScreen)
    let is400Line = bus.is400LineMode
    let height = is400Line ? ScreenRenderer.height400 : ScreenRenderer.height

    // Pack RGBA as UInt32 and fill in one pass. Little-endian: byte 0 = R,
    // 1 = G, 2 = B, 3 = A. renderTextOverlay writes only foreground RGB, so
    // unlit cells keep this colour.
    let pixelCount = ScreenRenderer.width * height
    let gray = UInt32(backgroundGray)
    let backgroundPixel = gray | (gray << 8) | (gray << 16) | (0xFF << 24)
    var buffer = [UInt8](repeating: 0, count: pixelCount * 4)
    buffer.withUnsafeMutableBytes { raw in
      let u32 = raw.bindMemory(to: UInt32.self)
      for i in 0..<pixelCount { u32[i] = backgroundPixel }
    }
    ScreenRenderer().renderTextOverlay(
      textData: chars,
      attrData: attrs,
      fontROM: machine.fontROM,
      palette: ScreenRenderer.expandPalette(bus.palette),
      displayEnabled: true,
      columns80: columns == 80,
      colorMode: bus.colorMode,
      attributeGraphMode: false,
      textRows: rows,
      cursorX: crtc.cursorX,
      cursorY: crtc.cursorY,
      cursorVisible: crtc.cursorEnabled,
      cursorBlock: true,
      is400Line: is400Line,
      skipLine: crtc.skipLine,
      into: &buffer
    )
    return TextVRAMCapture(
      image: buffer,
      is400LineMode: is400Line,
      characters: chars,
      attributes: attrs,
      columns: columns,
      rows: rows,
      cursorX: crtc.cursorX,
      cursorY: crtc.cursorY,
      cursorEnabled: crtc.cursorEnabled
    )
  }

  #if DEBUG
  /// The text DMA state of the frame just run. Only DEBUG builds record it.
  @_spi(Debug) public func textDMADebugSnapshot() -> TextDMADebugSnapshot {
    machine.bus.textDMADebugSnapshot()
  }
  #endif

  // MARK: - Sound

  /// What the OPNA is doing at this moment. Also feeds the controller
  /// rumble, which watches the SSG noise channel.
  @_spi(Debug) public struct SoundState: Equatable, Sendable {
    /// 1 bit per FM channel (bits 0-5) with at least one operator active.
    public var fmKeyOn: UInt8
    /// One per SSG channel: bits 0-3 level (0-15), bit 4 envelope mode.
    public var ssgVolume: [UInt8]
    /// SSG register 7 (active low: 0 enables a tone or noise channel).
    public var ssgMixer: UInt8
    public var ssgNoisePeriod: UInt8
    public var ssgEnvelopeShape: UInt8
    public var ssgEnvelopePeriod: UInt16
    /// 1 bit per rhythm instrument (bits 0-5) currently sounding.
    public var rhythmKeyOn: UInt8
    public var adpcmPlaying: Bool
  }

  @_spi(Debug) public var soundState: SoundState {
    let sound = machine.sound
    return SoundState(
      fmKeyOn: sound.fmKeyOnMask,
      ssgVolume: sound.ssgVolume,
      ssgMixer: sound.ssgMixer,
      ssgNoisePeriod: sound.ssgNoisePeriod,
      ssgEnvelopeShape: sound.ssgEnvShape,
      ssgEnvelopePeriod: sound.ssgEnvPeriod,
      rhythmKeyOn: sound.rhythmKeyOn,
      adpcmPlaying: sound.adpcmPlaying
    )
  }

  /// Which sound sources reach the mix. Debug only; not saved in state.
  @_spi(Debug) public struct DebugOutputMask: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let fm = DebugOutputMask(rawValue: 1 << 0)
    public static let ssg = DebugOutputMask(rawValue: 1 << 1)
    public static let adpcm = DebugOutputMask(rawValue: 1 << 2)
    public static let rhythm = DebugOutputMask(rawValue: 1 << 3)
    public static let all: DebugOutputMask = [.fm, .ssg, .adpcm, .rhythm]
  }

  @_spi(Debug) public var debugOutputMask: DebugOutputMask {
    get { DebugOutputMask(rawValue: machine.sound.debugOutputMask.rawValue) }
    set { machine.sound.debugOutputMask = YM2608.DebugOutputMask(rawValue: newValue.rawValue) }
  }

  /// Per-channel mute. Debug only; not saved in state, but kept across a
  /// reset.
  @_spi(Debug) public struct DebugChannelMask: Sendable, Hashable {
    /// 1 bit per FM channel (bits 0-5). 1 = unmuted, 0 = muted.
    public var fm: UInt8
    /// 1 bit per SSG channel (bits 0-2). 1 = unmuted, 0 = muted.
    public var ssg: UInt8
    /// 1 bit per rhythm instrument (bits 0-5). 1 = unmuted, 0 = muted.
    public var rhythm: UInt8
    /// false = ADPCM muted.
    public var adpcm: Bool

    public static let all = DebugChannelMask()

    public init(fm: UInt8 = 0x3F, ssg: UInt8 = 0x07, rhythm: UInt8 = 0x3F, adpcm: Bool = true) {
      self.fm = fm; self.ssg = ssg; self.rhythm = rhythm; self.adpcm = adpcm
    }
  }

  @_spi(Debug) public var debugChannelMask: DebugChannelMask {
    get {
      let m = machine.sound.debugChannelMask
      return DebugChannelMask(fm: m.fm, ssg: m.ssg, rhythm: m.rhythm, adpcm: m.adpcm)
    }
    set {
      machine.sound.debugChannelMask = YM2608.DebugChannelMask(
        fm: newValue.fm, ssg: newValue.ssg, rhythm: newValue.rhythm, adpcm: newValue.adpcm)
    }
  }
}
