// PC88.swift — the entry point to the emulation core.
//
// Read this file first. Everything a host needs to drive a PC-8801 — boot it,
// feed it ROMs, disks, tapes and keys, run it a frame at a time, save and
// restore it — is reachable from `PC88`. The value types that cross this
// boundary (`D88Disk`, `BootMode`, `MonitorType`, `PC88Key`, …) live in
// their own files but are public.
//
// `Machine` is the implementation: a container of components wired together
// by `tick()`. `PC88` wraps it so the shape of the public API does not follow
// every reorganisation of those components. The debugger and development
// tools reach inside through `machine` (SPI); tests and BootTester keep using
// `Machine` directly. See docs/develop/EMULATOR_CORE_SPLIT.md §7.

import Foundation
@_exported import PC88Types
import FMSynthesis

/// A PC-8801-FA.
///
/// Same threading contract as `Machine`: confine an instance to one serial
/// queue for its whole lifetime.
public final class PC88: @unchecked Sendable {

  /// The machine this wraps. For the debugger and development tools only;
  /// everything else should go through `PC88`.
  @_spi(Debug) public let machine: Machine

  private let compositor = FrameCompositor()

  public init() {
    machine = Machine()
    // Chain onto the FDC hooks rather than replace them: SubSystem already
    // uses them to set the disk activity flags `takeDiskActivity()` reads.
    let fdc = machine.subSystem.fdc
    let seekStep = fdc.onSeekStep
    fdc.onSeekStep = { [weak self] drive, track in
      seekStep?(drive, track)
      self?.onFDDEvent?(drive, .seekStep)
    }
    let diskAccess = fdc.onDiskAccess
    fdc.onDiskAccess = { [weak self] drive in
      diskAccess?(drive)
      self?.onFDDEvent?(drive, .access)
    }
  }

  // MARK: - Lifecycle

  /// Reset the machine. The default is a cold (power-on) reset;
  /// `preserveRAM` is the front-panel RESET button, which keeps DRAM and
  /// VRAM contents.
  public func reset(preserveRAM: Bool = false) {
    machine.reset(preserveRAM: preserveRAM)
  }

  /// Run one VSYNC frame. Returns the T-states executed, which falls short of
  /// a full frame when a debugger breakpoint stops it.
  @discardableResult
  public func runFrame() -> Int {
    machine.runFrame()
  }

  /// VSYNC frequency in Hz — what the host should pace `runFrame()` at.
  /// Never exactly 60: 55.42Hz on a 24kHz monitor, 62.42Hz on a 15kHz one.
  public var frameRate: Double {
    machine.frameRate
  }

  /// Install extended RAM (`cards` × `banksPerCard` × 32KB). `cards == 0`
  /// removes it; 8 cards is the 1MB linear mode.
  public func installExtRAM(cards: Int = 1, banksPerCard: Int = 4) {
    machine.installExtRAM(cards: cards, banksPerCard: banksPerCard)
  }

  // MARK: - ROMs

  /// The ROM images a host loads. None are bundled.
  public enum ROM: Equatable, Sendable {
    /// N88-BASIC (32KB).
    case n88Basic
    /// N-BASIC (32KB).
    case nBasic
    /// N88-BASIC extended ROM, bank 0-3 (8KB each).
    case n88Ext(bank: Int)
    /// Sub-CPU firmware, DISK.ROM (8KB).
    case disk
    /// Character font (2KB).
    case font
    /// Kanji ROM level 1 (128KB).
    case kanji1
    /// Kanji ROM level 2 (128KB).
    case kanji2
  }

  public func loadROM(_ rom: ROM, data: [UInt8]) {
    switch rom {
    case .n88Basic:          machine.loadN88BasicROM(data)
    case .nBasic:            machine.loadNBasicROM(data)
    case .n88Ext(let bank):  machine.loadN88ExtROM(bank: bank, data: data)
    case .disk:              machine.loadDiskROM(data)
    case .font:              machine.loadFontROM(data)
    case .kanji1:            machine.loadKanjiROM1(data)
    case .kanji2:            machine.loadKanjiROM2(data)
    }
  }

  /// Load one OPNA rhythm sample (signed 16-bit mono PCM). `index`:
  /// 0=BD 1=SD 2=TOP 3=HH 4=TOM 5=RIM. Without these the rhythm part is silent.
  public func loadRhythmSample(index: Int, data: [Int16], sampleRate: Int) {
    machine.loadRhythmSample(index: index, data: data, sampleRate: sampleRate)
  }

  // MARK: - Configuration

  /// DIP switch 1 as port 0x30 reads it: SW1-1 to SW1-5 in bits 1-5 and the
  /// N88/N mode switch in bit 0. Takes effect at the next reset.
  ///
  /// SW1-6 and SW1-8 are not in this byte — they never appear on port 0x30 —
  /// so they are set through `memoryWaitDip` and `monitorType` instead.
  /// SW1-7 (CMD SING) is not emulated.
  public var dipSw1: UInt8 {
    get { machine.bus.dipSw1 }
    set { machine.bus.dipSw1 = newValue }
  }

  /// DIP switch 2, raw (port 0x31), including bit 3 — the boot strap.
  /// Takes effect at the next reset.
  public var dipSw2: UInt8 {
    get { machine.bus.dipSw2 }
    set { machine.bus.dipSw2 = newValue }
  }

  /// The standard boot mode the DIP switches currently select, or nil for a
  /// custom combination. Ignores bit 3 of DIP switch 2 (the boot strap).
  public var bootMode: BootMode? {
    let strap = Machine.bootStrapBit
    let sw1: UInt8 = dipSw1 | 0xC0  // bits 7-6 always read as 1
    let sw2: UInt8 = dipSw2 | strap
    return BootMode.allCases.first { mode in
      sw1 == mode.dipSw1 | 0xC0 && sw2 == mode.dipSw2 | strap
    }
  }

  /// Set both DIP switches to a standard boot mode, leaving bit 3 of DIP
  /// switch 2 (the boot strap) as it was. Takes effect at the next reset.
  public func setBootMode(_ mode: BootMode) {
    dipSw1 = mode.dipSw1
    dipSw2 = (mode.dipSw2 & ~Machine.bootStrapBit) | (dipSw2 & Machine.bootStrapBit)
  }

  /// `base` with the boot strap (DIP switch 2 bit 3) set for disk boot when
  /// `hasDiskInDrive0`, ROM boot otherwise. For deciding ahead of mounting.
  public static func resolvedBootStrap(base: UInt8, hasDiskInDrive0: Bool) -> UInt8 {
    Machine.resolvedBootStrap(base: base, hasDiskInDrive0: hasDiskInDrive0)
  }

  /// Set the boot strap (DIP switch 2 bit 3) from whether drive 0 holds a
  /// disk: disk boot if it does, straight to BASIC if not — an empty drive 0
  /// would otherwise sit through a ~30 second IPL timeout. With `base`, DIP
  /// switch 2 is first replaced by it.
  public func applyBootStrap(base: UInt8? = nil) {
    machine.applyBootStrap(base: base)
  }

  /// CPU clock: true = 8MHz, false = 4MHz. `reset()` puts it back to 8MHz,
  /// so set it after resetting.
  public var clock8MHz: Bool {
    get { machine.clock8MHz }
    set { machine.clock8MHz = newValue }
  }

  /// The attached monitor (SW1-8). Not on port 0x30; software sees it as
  /// port 0x40 bit 1 (SHG), and it sets the line time. Takes effect at the
  /// next reset.
  public var monitorType: MonitorType {
    get { machine.monitorType }
    set { machine.monitorType = newValue }
  }

  /// Memory wait (SW1-6): one extra wait state on main RAM, TVRAM and
  /// graphic-off GVRAM accesses. Not readable by software.
  public var memoryWaitDip: Bool {
    get { machine.memoryWaitDip }
    set { machine.memoryWaitDip = newValue }
  }

  /// Run the CPU 1-8× faster while everything else keeps real time, to win
  /// back slowdown. 1 is real speed.
  public var cpuOverclock: Int {
    get { machine.cpuOverclock }
    set { machine.cpuOverclock = newValue }
  }

  // MARK: - Disks

  /// Mount a disk image in drive 0 or 1.
  public func mountDisk(drive: Int, disk: D88Disk) {
    machine.mountDisk(drive: drive, disk: disk)
  }

  public func ejectDisk(drive: Int) {
    machine.ejectDisk(drive: drive)
  }

  public func setWriteProtect(drive: Int, protected: Bool) {
    machine.setWriteProtect(drive: drive, protected: protected)
  }

  public func isWriteProtected(drive: Int) -> Bool {
    machine.isWriteProtected(drive: drive)
  }

  /// The disk in a drive as it is now, guest writes included, or nil if the
  /// drive is empty.
  public func mountedDisk(drive: Int) -> D88Disk? {
    guard drive >= 0, drive < machine.subSystem.drives.count else { return nil }
    return machine.subSystem.drives[drive]
  }

  /// Called after the guest writes to or formats a disk, synchronously on
  /// the thread running `runFrame()`. The drive number is the argument.
  /// Pair it with `takeDirtyDiskImage(drive:)` to write disks back to files.
  public var onDiskWritten: ((_ drive: Int) -> Void)? {
    get { machine.subSystem.onDiskWritten }
    set { machine.subSystem.onDiskWritten = newValue }
  }

  /// If the disk in `drive` has been written since it was mounted or last
  /// taken, return its serialised D88 image and mark it clean — in one step,
  /// so a write landing in between cannot be lost. Returns nil when there is
  /// nothing to write back. Call `markDiskDirty(drive:)` if saving the image
  /// fails, so the next attempt picks it up again.
  public func takeDirtyDiskImage(drive: Int) -> [UInt8]? {
    guard let disk = mountedDisk(drive: drive), disk.dirty,
          let bytes = disk.serialize() else { return nil }
    machine.subSystem.drives[drive]?.dirty = false
    return bytes
  }

  /// Flag the disk in `drive` as needing write-back again.
  public func markDiskDirty(drive: Int) {
    guard drive >= 0, drive < machine.subSystem.drives.count else { return }
    machine.subSystem.drives[drive]?.dirty = true
  }

  /// What the floppy drive mechanism just did, for drive sound effects.
  public enum FDDEvent: Sendable {
    /// The head stepped one track. A multi-track seek fires one per track.
    case seekStep
    /// A sector was read, written or formatted.
    case access
  }

  /// Called for every drive mechanism event, synchronously on the thread
  /// running `runFrame()`, so several can arrive within one frame. Keep it
  /// cheap; hand the work off if it is not.
  public var onFDDEvent: ((_ drive: Int, _ event: FDDEvent) -> Void)?

  /// Whether drive 0 and drive 1 have been active (seek or access) since the
  /// last call, for access lamps. Clears the flags.
  public func takeDiskActivity() -> [Bool] {
    let activity = machine.subSystem.diskAccess
    machine.subSystem.diskAccess = [false, false]
    return activity
  }

  // MARK: - Tape

  /// Load a cassette image, T88 or raw CMT. Returns the format detected.
  @discardableResult
  public func mountTape(data: Data) -> TapeFormat {
    machine.mountTape(data: data)
  }

  public func ejectTape() {
    machine.ejectTape()
  }

  public func rewindTape() {
    machine.rewindTape()
  }

  public var isTapeLoaded: Bool {
    machine.cassette.isLoaded
  }

  /// Playback position, 0.0-1.0 (0 with no tape).
  public var tapeProgress: Double {
    machine.cassette.progress
  }

  // MARK: - Keyboard

  public func pressKey(_ key: PC88Key) {
    machine.keyboard.pressKey(row: key.row, bit: key.bit)
  }

  public func releaseKey(_ key: PC88Key) {
    machine.keyboard.releaseKey(row: key.row, bit: key.bit)
  }

  public func releaseAllKeys() {
    machine.keyboard.releaseAll()
  }

  // MARK: - Mouse and joystick

  /// Whether the mouse is connected. Port reads pass through untouched while
  /// it is not.
  public var mouseEnabled: Bool {
    get { machine.mouse.enabled }
    set { machine.mouse.enabled = newValue }
  }

  /// true = the mouse drives the joystick direction bits; false = bus mouse.
  public var mouseJoystickMode: Bool {
    get { machine.mouse.joyMode }
    set { machine.mouse.joyMode = newValue }
  }

  /// Feed relative mouse movement from the host.
  public func moveMouse(dx: Int, dy: Int) {
    machine.mouse.injectMovement(dx: dx, dy: dy)
  }

  public func setMouseButtons(left: Bool, right: Bool) {
    machine.mouse.setButtons(left: left, right: right)
  }

  // MARK: - Display

  /// Composite the current screen into `pixelBuffer`, which must hold
  /// `ScreenRenderer.bufferSize400` bytes: 640×400 RGBA, with 200-line modes
  /// line-doubled into it.
  ///
  /// - Parameters:
  ///   - blinkCursor: honour the cursor blink phase. Pass false while the
  ///     machine is paused, so a frozen frame does not keep blinking.
  ///   - markTextPixels: tag text-layer pixels with
  ///     `ScreenRenderer.textPixelAlphaTag` in the alpha channel, so a display
  ///     shader can tell them apart (e.g. to exempt them from scanlines).
  public func render(into pixelBuffer: inout [UInt8], blinkCursor: Bool,
                     markTextPixels: Bool = false) {
    compositor.render(machine, into: &pixelBuffer, blinkCursor: blinkCursor,
                      markTextPixels: markTextPixels)
  }

  /// `render(into:blinkCursor:markTextPixels:)` with the debugger's switch
  /// for hiding the text layer.
  @_spi(Debug) public func render(into pixelBuffer: inout [UInt8], blinkCursor: Bool,
                                  textLayerEnabled: Bool, markTextPixels: Bool = false) {
    compositor.render(machine, into: &pixelBuffer, blinkCursor: blinkCursor,
                      textLayerEnabled: textLayerEnabled, markTextPixels: markTextPixels)
  }

  /// True in 400-line monochrome mode. The frame is then 640×400 rather than
  /// 640×200 line-doubled, which the host needs to know to scale it.
  public var is400LineMode: Bool {
    machine.bus.is400LineMode
  }

  /// The 8×8 font ROM glyph for a character code, one byte per row, MSB on
  /// the left. All zero when no font ROM is loaded.
  public func glyph(for code: UInt8) -> [UInt8] {
    machine.fontROM.glyph(for: code)
  }

  // MARK: - Sound

  /// The rate every sample from `takeAudioSamples()` is produced at, in Hz.
  public static let audioSampleRate = YM2608.sampleRate

  /// Samples generated since the last `takeAudioSamples()`: interleaved
  /// stereo Float32 (L, R, L, R, …) at `audioSampleRate` (44.1kHz), −1…1.
  public struct AudioSamples: Sendable {
    /// The mixed output.
    public var stereo: [Float]
    /// The same span split by source, each interleaved stereo with the
    /// chip's own panning. Empty unless `immersiveOutputEnabled`. The beeper
    /// is mixed into `fm`.
    public var fm: [Float]
    public var ssg: [Float]
    public var adpcm: [Float]
    public var rhythm: [Float]
  }

  /// Take the audio produced by `runFrame()` so far and clear the chip's
  /// buffers. Call it after every frame; nothing else empties them.
  public func takeAudioSamples() -> AudioSamples {
    let sound = machine.sound
    let samples = AudioSamples(stereo: sound.audioBuffer,
                               fm: sound.fmSpatialBuffer,
                               ssg: sound.ssgSpatialBuffer,
                               adpcm: sound.adpcmSpatialBuffer,
                               rhythm: sound.rhythmSpatialBuffer)
    // keepingCapacity: the chip appends every sample, so do not make it
    // regrow the buffers from empty each frame.
    sound.audioBuffer.removeAll(keepingCapacity: true)
    sound.fmSpatialBuffer.removeAll(keepingCapacity: true)
    sound.ssgSpatialBuffer.removeAll(keepingCapacity: true)
    sound.adpcmSpatialBuffer.removeAll(keepingCapacity: true)
    sound.rhythmSpatialBuffer.removeAll(keepingCapacity: true)
    return samples
  }

  /// Nudge the sound chip's sample clock so its output keeps pace with the
  /// host's audio device. The frame pacer and the device clock drift apart
  /// slowly; left alone the host's queue grows (latency) or runs dry
  /// (dropouts). Call after queueing each batch of samples, with how many
  /// stereo frames the host has queued and how many it can hold; this keeps
  /// the queue near half full. The correction is capped at ±0.5%.
  public func adjustAudioRate(bufferedFrames: Int, capacityFrames: Int) {
    let sound = machine.sound
    let targetFill = capacityFrames / 2
    let error = bufferedFrames - targetFill
    let baseClock = sound.clock8MHz
      ? YM2608.baseCpuClockHz8MHz
      : YM2608.baseCpuClockHz4MHz
    let maxAdj = baseClock / 200
    let adj = max(-maxAdj, min(maxAdj, error * 16))
    sound.cpuClockHz = baseClock + adj
  }

  /// Haas-effect widening of mono FM/SSG output. Has no effect once a program
  /// pans an FM channel itself.
  public var pseudoStereoEnabled: Bool {
    get { machine.sound.pseudoStereoEnabled }
    set { machine.sound.pseudoStereoEnabled = newValue }
  }

  /// Low-pass and reverb in the style of 1980s game-music CD mixes. Taste,
  /// not accuracy; off by default.
  public var cdMixEnabled: Bool {
    get { machine.sound.cdMixEnabled }
    set { machine.sound.cdMixEnabled = newValue }
  }

  /// Also produce per-source (FM / SSG / ADPCM / rhythm) stereo streams
  /// alongside the main mix.
  public var immersiveOutputEnabled: Bool {
    get { machine.sound.immersiveOutputEnabled }
    set { machine.sound.immersiveOutputEnabled = newValue }
  }

  /// Report the sound board as YM2203 (OPN) so programs skip OPNA features.
  public var forceOPNMode: Bool {
    get { machine.sound.forceOPNMode }
    set { machine.sound.forceOPNMode = newValue }
  }

  // MARK: - Save states

  /// Serialise the whole machine, mounted disks included. `extraSections`
  /// are stored verbatim for the host's own metadata; the core ignores
  /// their tags when loading.
  public func createSaveState(thumbnail: [UInt8]? = nil,
                              extraSections: [(tag: UInt32, data: [UInt8])] = []) -> [UInt8] {
    machine.createSaveState(thumbnail: thumbnail, extraSections: extraSections)
  }

  public func loadSaveState(_ data: [UInt8]) throws {
    try machine.loadSaveState(data)
  }

  // MARK: - Text

  /// The text screen as a Unicode string, one line per row.
  public func copyTextAsUnicode() -> String {
    machine.copyTextAsUnicode()
  }
}
