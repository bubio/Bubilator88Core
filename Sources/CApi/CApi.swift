// CApi.swift — C ABI shim for the Windows native port.
//
// The emulation core (EmulatorCore / Z80 / FMSynthesis / Peripherals) is a
// single Swift source of truth. To avoid a divergent second implementation,
// the Windows shell (C# + WinUI 3) drives the SAME Swift core through this
// thin `@_cdecl` layer compiled into `Bubilator88C.dll` and called via
// P/Invoke. macOS keeps static-linking EmulatorCore directly and never sees
// this file.
//
// Design:
//   * An opaque handle (`UnsafeMutableRawPointer`) wraps a `B88Context` that
//     owns a `PC88` and a reusable RGBA buffer.
//   * Frames come from `PC88.render`, the same compositing the macOS app
//     uses, so the host receives finished RGBA and never re-implements
//     palette math — this is what keeps macOS and Windows pixel-identical.
//
// Export note: on Windows, SwiftPM dynamic libraries may need the `@_cdecl`
// symbols listed in a module-definition (.def) file or exported via
// `-Xlinker /EXPORT:`. See docs/WINDOWS_PORT.md for the build recipe.

import EmulatorCore
import Foundation

/// Owns one emulated machine plus its render scratch state.
public final class B88Context {
  let pc88 = PC88()
  /// Reusable 640×400 RGBA buffer; rendered into, then copied to the host.
  var pixelBuffer = [UInt8](repeating: 0, count: ScreenRenderer.bufferSize400)
  /// Last save-state blob produced by `b88_save_state`, stashed so the host
  /// can query the length and then copy it out in a second call (the blob is
  /// variable-length: RAM + disk images, so the host can't pre-size a buffer).
  var saveStateBlob: [UInt8] = []
  /// Stereo samples taken from the core but not yet handed to the host.
  /// `b88_drain_audio` returns at most what the host asks for, while
  /// `PC88.takeAudioSamples()` takes everything, so the rest waits here. Cleared
  /// wherever the core clears its own buffer (reset, state load), so a stale
  /// tail never plays after either.
  var pendingAudio: [Float] = []

  /// Per-drive FDD sound event counters, sampled + cleared by
  /// `b88_fdd_sound_events`. Distinct from `PC88.takeDiskActivity()` (which
  /// the LED indicator uses) because the host needs to tell a seek step
  /// (mechanical click) apart from a read/write access (buzz) to play the
  /// matching synthesized sound. The macOS app plays straight from
  /// `PC88.onFDDEvent`; the C ABI polls, so the events are counted here.
  ///
  /// `fddSeekCount` is a COUNT, not a boolean: the host only samples once per
  /// rendered frame (~16.7ms), but a multi-track seek can fire `onSeekStep`
  /// several times within that window (step rate is as low as ~2ms — see
  /// `UPD765A.srtClocks`), and macOS plays one discrete click per step with no
  /// throttling (real drives audibly "rattle" across multiple tracks). Collapsing
  /// that to a single bool would silently drop steps and make seeks on Windows
  /// sound like one dull tock instead of a train of clicks. `fddAccessPulse`
  /// stays a bool because `FddSound.PlayReadAccess`'s 30ms per-drive throttle
  /// already exceeds one frame's duration, so multiple accesses within a frame
  /// can never produce more than one audible hit anyway.
  var fddSeekCount: [Int32] = [0, 0]
  var fddAccessPulse: [Bool] = [false, false]

  init() {
    pc88.onFDDEvent = { [weak self] drive, event in
      guard let self, drive < 2 else { return }
      switch event {
      case .seekStep: self.fddSeekCount[drive] += 1
      case .access:   self.fddAccessPulse[drive] = true
      }
    }
  }
}

@inline(__always)
private func context(_ handle: UnsafeMutableRawPointer?) -> B88Context? {
  guard let handle else { return nil }
  return Unmanaged<B88Context>.fromOpaque(handle).takeUnretainedValue()
}

@inline(__always)
private func bytes(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> [UInt8] {
  guard let ptr, len > 0 else { return [] }
  return Array(UnsafeBufferPointer(start: ptr, count: Int(len)))
}

// MARK: - Lifecycle

@_cdecl("b88_create")
public func b88_create() -> UnsafeMutableRawPointer {
  Unmanaged.passRetained(B88Context()).toOpaque()
}

@_cdecl("b88_destroy")
public func b88_destroy(_ handle: UnsafeMutableRawPointer?) {
  guard let handle else { return }
  Unmanaged<B88Context>.fromOpaque(handle).release()
}

// MARK: - ROM loading
//
// kind:  0=N88  1=N80(N-BASIC)  2=DISK(sub-CPU)  3=FONT
//        4=KANJI1  5=KANJI2  10..13=N88 ext bank 0..3

@_cdecl("b88_load_rom")
public func b88_load_rom(_ handle: UnsafeMutableRawPointer?,
                         _ kind: Int32,
                         _ ptr: UnsafePointer<UInt8>?,
                         _ len: Int32) {
  guard let c = context(handle) else { return }
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return }
  switch kind {
  case 0:  c.pc88.loadROM(.n88Basic, data: data)
  case 1:  c.pc88.loadROM(.nBasic, data: data)
  case 2:  c.pc88.loadROM(.disk, data: data)
  case 3:  c.pc88.loadROM(.font, data: data)
  case 4:  c.pc88.loadROM(.kanji1, data: data)
  case 5:  c.pc88.loadROM(.kanji2, data: data)
  case 10, 11, 12, 13:
    c.pc88.loadROM(.n88Ext(bank: Int(kind - 10)), data: data)
  default: break
  }
}

// MARK: - YM2608 rhythm samples
//
// The OPNA rhythm (BD/SD/TOP/HH/TOM/RIM) needs external WAV samples to make any
// sound — without them the rhythm channels are silent. macOS loads these from
// the app-support dir (EmulatorViewModel+Disk.swift); the Windows shell reads
// the same 2608_*.WAV files and passes their raw bytes here. We parse the WAV
// in the core so both shells share one parser.
//
// index: 0=BD 1=SD 2=TOP 3=HH 4=TOM 5=RIM (order must match the host's file list)
@_cdecl("b88_load_rhythm_sample")
public func b88_load_rhythm_sample(_ handle: UnsafeMutableRawPointer?,
                                   _ index: Int32,
                                   _ ptr: UnsafePointer<UInt8>?,
                                   _ len: Int32) {
  guard let c = context(handle) else { return }
  let data = bytes(ptr, len)
  guard let (samples, sampleRate) = parseWAV(data) else { return }
  c.pc88.loadRhythmSample(index: Int(index), data: samples, sampleRate: sampleRate)
}

/// Parse a RIFF/WAVE blob and extract signed 16-bit PCM samples + sample rate.
/// Mirrors `EmulatorViewModel+Disk.swift`'s parser. Returns nil if not a 16-bit
/// PCM WAVE.
private func parseWAV(_ data: [UInt8]) -> (samples: [Int16], sampleRate: Int)? {
  guard data.count > 44 else { return nil }
  // "RIFF" .... "WAVE"
  guard data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46 else { return nil }
  guard data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 else { return nil }

  var sampleRate = 44100
  var bitsPerSample = 16
  var numChannels = 1
  var dataOffset = 0
  var dataSize = 0

  var offset = 12
  while offset + 8 <= data.count {
    let chunkID = String(bytes: data[offset..<offset+4], encoding: .ascii) ?? ""
    let chunkSize = Int(data[offset+4]) | Int(data[offset+5]) << 8 |
      Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
    if chunkID == "fmt " {
      numChannels = Int(data[offset+10]) | Int(data[offset+11]) << 8
      sampleRate = Int(data[offset+12]) | Int(data[offset+13]) << 8 |
        Int(data[offset+14]) << 16 | Int(data[offset+15]) << 24
      bitsPerSample = Int(data[offset+22]) | Int(data[offset+23]) << 8
    } else if chunkID == "data" {
      dataOffset = offset + 8
      dataSize = chunkSize
      break
    }
    offset += 8 + chunkSize
    if chunkSize & 1 != 0 { offset += 1 }  // Word-align
  }

  guard dataOffset > 0, bitsPerSample == 16, numChannels > 0 else { return nil }
  let sampleCount = min(dataSize, data.count - dataOffset) / (2 * numChannels)
  var samples = [Int16](repeating: 0, count: sampleCount)
  for i in 0..<sampleCount {
    let byteOffset = dataOffset + i * 2 * numChannels
    samples[i] = Int16(bitPattern: UInt16(data[byteOffset]) | UInt16(data[byteOffset+1]) << 8)
  }
  return (samples, sampleRate)
}

// MARK: - Disk

/// Parses a (possibly multi-image) D88 blob and mounts image `imageIndex` on
/// `drive`. Returns the number of images found in the blob (0 = parse failure
/// or index out of range).
@_cdecl("b88_mount_disk")
public func b88_mount_disk(_ handle: UnsafeMutableRawPointer?,
                           _ drive: Int32,
                           _ ptr: UnsafePointer<UInt8>?,
                           _ len: Int32,
                           _ imageIndex: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return 0 }
  let disks = D88Disk.parseAll(data: data)
  let idx = Int(imageIndex)
  guard idx >= 0, idx < disks.count else { return Int32(disks.count) }
  c.pc88.mountDisk(drive: Int(drive), disk: disks[idx])
  return Int32(disks.count)
}

@_cdecl("b88_eject_disk")
public func b88_eject_disk(_ handle: UnsafeMutableRawPointer?, _ drive: Int32) {
  context(handle)?.pc88.ejectDisk(drive: Int(drive))
}

/// Probe a (possibly multi-image) D88 blob WITHOUT mounting. Returns the image
/// count (0 = not a parseable D88). Per-image metadata is written to `outUtf8`
/// as a NUL-terminated UTF-8 string: one line per image, newline-separated, each
/// line being TAB-separated `name\t<diskTypeRaw>\t<writeProtected>` where
/// diskTypeRaw is the D88 type byte (0=2D, 16=2DD, 32=2HD) and writeProtected is
/// 0/1. An empty name field means the host substitutes a "<file> #<i>" fallback.
/// Pass `outUtf8 == nil` to query just the count.
///
/// Stateless — no handle needed; the host holds the bytes and calls this once at
/// mount time to build the per-drive image menu / selection dialog.
@_cdecl("b88_d88_probe")
public func b88_d88_probe(_ ptr: UnsafePointer<UInt8>?,
                          _ len: Int32,
                          _ outUtf8: UnsafeMutablePointer<UInt8>?,
                          _ outCap: Int32) -> Int32 {
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return 0 }
  let disks = D88Disk.parseAll(data: data)
  if let outUtf8, outCap > 0 {
    let lines = disks.map { d in
      "\(d.name)\t\(d.diskType.rawValue)\t\(d.writeProtected ? 1 : 0)"
    }
    let utf8 = Array(lines.joined(separator: "\n").utf8)
    let n = max(0, min(utf8.count, Int(outCap) - 1))
    utf8.withUnsafeBufferPointer { src in
      if n > 0 { outUtf8.update(from: src.baseAddress!, count: n) }
    }
    outUtf8[n] = 0  // NUL-terminate
  }
  return Int32(disks.count)
}

/// Set the write-protect flag on the disk mounted in `drive`.
@_cdecl("b88_set_write_protect")
public func b88_set_write_protect(_ handle: UnsafeMutableRawPointer?,
                                  _ drive: Int32,
                                  _ protected: Int32) {
  context(handle)?.pc88.setWriteProtect(drive: Int(drive), protected: protected != 0)
}

/// Enable/disable the pseudo-stereo (Haas effect) chorus on mono FM/SSG
/// output. Mirrors macOS `EmulatorViewModel.pseudoStereo` →
/// `PC88.pseudoStereoEnabled`. Windows has no immersive-audio
/// mode yet, so unlike macOS there is no mutual-exclusion flag to combine
/// this with.
@_cdecl("b88_set_pseudo_stereo")
public func b88_set_pseudo_stereo(_ handle: UnsafeMutableRawPointer?, _ enabled: Int32) {
  context(handle)?.pc88.pseudoStereoEnabled = enabled != 0
}

// MARK: - Machine control

/// Set DIP SW1 raw value (e.g. 0xC3 = N88-BASIC, 0xC2 = N-BASIC).
@_cdecl("b88_set_dipsw1")
public func b88_set_dipsw1(_ handle: UnsafeMutableRawPointer?, _ value: Int32) {
  context(handle)?.pc88.dipSw1 = UInt8(truncatingIfNeeded: value)
}

/// Re-evaluate the boot strap (DIP SW2 bit 3) from drive-0 occupancy.
/// Pass `dipsw2Base >= 0` to also set the SW2 base (0x71=V2, 0xF1=V1H,
/// 0xB1=V1S); pass a negative value to keep the current base.
@_cdecl("b88_apply_bootstrap")
public func b88_apply_bootstrap(_ handle: UnsafeMutableRawPointer?, _ dipsw2Base: Int32) {
  guard let c = context(handle) else { return }
  if dipsw2Base >= 0 {
    c.pc88.applyBootStrap(base: UInt8(truncatingIfNeeded: dipsw2Base))
  } else {
    c.pc88.applyBootStrap()
  }
}

@_cdecl("b88_reset")
public func b88_reset(_ handle: UnsafeMutableRawPointer?, _ preserveRAM: Int32) {
  guard let c = context(handle) else { return }
  c.pc88.reset(preserveRAM: preserveRAM != 0)
  c.pendingAudio.removeAll()
}

/// Install extended RAM (cards × 4 banks × 32KB). 0=none, 1=128KB, 8=1MB,
/// matching Settings.extramCards on macOS. Mirrors PC88.installExtRAM,
/// called fresh on every boot/reset so the host doesn't need to track state.
@_cdecl("b88_install_ext_ram")
public func b88_install_ext_ram(_ handle: UnsafeMutableRawPointer?, _ cards: Int32) {
  context(handle)?.pc88.installExtRAM(cards: Int(cards), banksPerCard: 4)
}

@_cdecl("b88_set_clock_8mhz")
public func b88_set_clock_8mhz(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  context(handle)?.pc88.clock8MHz = (on != 0)
}

/// Query the current CPU clock (1 = 8 MHz, 0 = 4 MHz). Used after a save-state
/// load to re-sync the host UI, since the clock is restored from the state.
@_cdecl("b88_get_clock_8mhz")
public func b88_get_clock_8mhz(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.clock8MHz ?? true) ? 1 : 0
}

/// Query the current line mode (1 = native 400-line, 0 = 200-line doubled).
/// The renderer always emits a 640×400 buffer (200-line content is row-doubled),
/// so the host needs this to feed video filters the correct content resolution:
/// in 200-line mode filters operate on the even rows (640×200), matching the
/// macOS EmulatorMetalView which extracts even rows before filtering (see
/// KNOWN_PITFALLS §9 — filters must run at real content resolution).
@_cdecl("b88_is_400line")
public func b88_is_400line(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.is400LineMode ?? false) ? 1 : 0
}

// MARK: - Save state
//
// Mirrors the macOS quick/slot save-state feature (EmulatorViewModel save/load).
// The core owns the binary format (PC88.createSaveState / loadSaveState —
// magic "BU88", versioned, with MAIN/DSK0/DSK1/CMT/META sections + optional
// thumbnail). The host handles only the file layout (slot_N.b88s + sidecar
// meta.json + thumb.png), so both shells write the same .b88s format and a
// state saved on one platform loads on the other.

/// Build a save state and stash it. Returns the blob length in bytes; the host
/// then calls `b88_save_state_read` to copy it out. The thumbnail is generated
/// host-side (separate .thumb.png), so none is embedded here (thumbnail = nil).
@_cdecl("b88_save_state")
public func b88_save_state(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  c.saveStateBlob = c.pc88.createSaveState()
  return Int32(c.saveStateBlob.count)
}

/// Copy the stashed save-state blob into `outPtr` (capacity `outCap` bytes).
/// Returns bytes copied. Call after `b88_save_state` returned the length.
@_cdecl("b88_save_state_read")
public func b88_save_state_read(_ handle: UnsafeMutableRawPointer?,
                                _ outPtr: UnsafeMutablePointer<UInt8>?,
                                _ outCap: Int32) -> Int32 {
  guard let c = context(handle), let outPtr else { return 0 }
  let n = min(Int(outCap), c.saveStateBlob.count)
  guard n > 0 else { return 0 }
  c.saveStateBlob.withUnsafeBufferPointer { src in
    outPtr.update(from: src.baseAddress!, count: n)
  }
  return Int32(n)
}

/// Load a save-state blob (the bytes of a .b88s file). Restores CPU, bus, sound,
/// sub-system, and mounted disk images. Returns 1 on success, 0 on failure
/// (not a save state, incompatible version, or corrupt data).
@_cdecl("b88_load_state")
public func b88_load_state(_ handle: UnsafeMutableRawPointer?,
                           _ ptr: UnsafePointer<UInt8>?,
                           _ len: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return 0 }
  do {
    try c.pc88.loadSaveState(data)
    c.pendingAudio.removeAll()
    return 1
  } catch {
    return 0
  }
}

/// Run one 1/60s frame. Returns T-states executed.
@_cdecl("b88_run_frame")
public func b88_run_frame(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return Int32(truncatingIfNeeded: c.pc88.runFrame())
}

// MARK: - Input (15-row keyboard matrix, active-low)

@_cdecl("b88_press_key")
public func b88_press_key(_ handle: UnsafeMutableRawPointer?, _ row: Int32, _ bit: Int32) {
  context(handle)?.pc88.pressKey(Keyboard.Key(Int(row), Int(bit)))
}

@_cdecl("b88_release_key")
public func b88_release_key(_ handle: UnsafeMutableRawPointer?, _ row: Int32, _ bit: Int32) {
  context(handle)?.pc88.releaseKey(Keyboard.Key(Int(row), Int(bit)))
}

// MARK: - Video

/// Composite the current frame into the host buffer as 640×400 RGBA8888.
/// `outLen` is the host buffer capacity in bytes; returns bytes written.
@_cdecl("b88_render_rgba")
public func b88_render_rgba(_ handle: UnsafeMutableRawPointer?,
                            _ outPtr: UnsafeMutablePointer<UInt8>?,
                            _ outLen: Int32,
                            _ blinkCursor: Int32) -> Int32 {
  guard let c = context(handle), let outPtr else { return 0 }
  // markTextPixels stays off: it tags text pixels with alpha 0xFE so the macOS
  // display shader can exempt text from scanline dimming, and the D3D11
  // shader does not implement that yet — parity gap, tracked in
  // windows/README.md.
  c.pc88.render(into: &c.pixelBuffer, blinkCursor: blinkCursor != 0)
  let n = min(Int(outLen), c.pixelBuffer.count)
  guard n > 0 else { return 0 }
  c.pixelBuffer.withUnsafeBufferPointer { src in
    outPtr.update(from: src.baseAddress!, count: n)
  }
  return Int32(n)
}

// MARK: - Audio

/// Drain up to `maxPairs` stereo sample pairs (44.1 kHz, interleaved L,R) from
/// the YM2608 output into `outPtr`. Returns the number of pairs written and
/// clears what was drained from the core buffer.
@_cdecl("b88_drain_audio")
public func b88_drain_audio(_ handle: UnsafeMutableRawPointer?,
                            _ outPtr: UnsafeMutablePointer<Float>?,
                            _ maxPairs: Int32) -> Int32 {
  guard let c = context(handle), let outPtr, maxPairs > 0 else { return 0 }
  c.pendingAudio.append(contentsOf: c.pc88.takeAudioSamples().stereo)
  let available = c.pendingAudio.count               // interleaved floats
  let wantFloats = Int(maxPairs) * 2
  let copyFloats = min(wantFloats, available)
  guard copyFloats > 0 else { return 0 }
  c.pendingAudio.withUnsafeBufferPointer { src in
    outPtr.update(from: src.baseAddress!, count: copyFloats)
  }
  if copyFloats == available {
    c.pendingAudio.removeAll(keepingCapacity: true)
  } else {
    c.pendingAudio.removeFirst(copyFloats)
  }
  return Int32(copyFloats / 2)
}

/// Adaptive audio rate control. Nudges the YM2608 sample clock so its output
/// rate tracks the host audio device, keeping the host's queued latency
/// (`fillPairs`) near `capacityPairs / 2`. Without this the emulator (paced by
/// the 60 Hz frame loop) and XAudio2 (locked to 44.1 kHz) slowly drift, causing
/// latency growth or dropouts. The same correction macOS applies
/// (`PC88.adjustAudioRate`).
@_cdecl("b88_audio_rate_control")
public func b88_audio_rate_control(_ handle: UnsafeMutableRawPointer?,
                                   _ fillPairs: Int32,
                                   _ capacityPairs: Int32) {
  context(handle)?.pc88.adjustAudioRate(bufferedFrames: Int(fillPairs),
                                        capacityFrames: Int(capacityPairs))
}

// MARK: - Status

/// Read and clear the per-drive disk-access flags. Writes 1/0 into `out0`/`out1`
/// for drive 0 and drive 1, then resets both to false. Mirrors the macOS
/// status-bar indicator, which samples the flags and clears them each tick.
@_cdecl("b88_disk_access")
public func b88_disk_access(_ handle: UnsafeMutableRawPointer?,
                            _ out0: UnsafeMutablePointer<Int32>?,
                            _ out1: UnsafeMutablePointer<Int32>?) {
  guard let c = context(handle) else { return }
  let access = c.pc88.takeDiskActivity()
  out0?.pointee = (access.count > 0 && access[0]) ? 1 : 0
  out1?.pointee = (access.count > 1 && access[1]) ? 1 : 0
}

/// Read and clear the per-drive FDD *sound* events: seek-step count (mechanical
/// head movement — a COUNT, since several steps can land in one sampled frame;
/// see `B88Context.fddSeekCount`) and read/write access (buzz, a 0/1 pulse),
/// tracked separately from `b88_disk_access` so the host can play the two
/// distinct synthesized sounds macOS uses (`FDDSound.playSeekStep` /
/// `playReadAccess`).
@_cdecl("b88_fdd_sound_events")
public func b88_fdd_sound_events(_ handle: UnsafeMutableRawPointer?,
                                 _ seek0: UnsafeMutablePointer<Int32>?,
                                 _ seek1: UnsafeMutablePointer<Int32>?,
                                 _ access0: UnsafeMutablePointer<Int32>?,
                                 _ access1: UnsafeMutablePointer<Int32>?) {
  guard let c = context(handle) else { return }
  seek0?.pointee = c.fddSeekCount[0]
  seek1?.pointee = c.fddSeekCount[1]
  access0?.pointee = c.fddAccessPulse[0] ? 1 : 0
  access1?.pointee = c.fddAccessPulse[1] ? 1 : 0
  c.fddSeekCount = [0, 0]
  c.fddAccessPulse = [false, false]
}
