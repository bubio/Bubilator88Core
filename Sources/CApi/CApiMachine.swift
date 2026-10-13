// CApiMachine.swift — settings read-back, audio stems, input and screen text.
//
// The rest of what the macOS app reads or sets on `PC88` outside media and
// typing. Every function here must be `public` (see CApi.swift).

import Bubilator88Core
import Foundation

extension B88Context {
  /// Move everything the core has produced into the pending buffers.
  func takeAudio() {
    let samples = pc88.takeAudioSamples()
    pendingAudio.append(contentsOf: samples.stereo)
    let stems = [samples.fm, samples.ssg, samples.adpcm, samples.rhythm, samples.cd]
    for i in stems.indices where !stems[i].isEmpty {
      pendingStems[i].append(contentsOf: stems[i])
      // A host that turns immersive output on but never drains a stem would
      // otherwise grow it for ever; keep one second.
      let limit = PC88.audioSampleRate * 2
      if pendingStems[i].count > limit {
        pendingStems[i].removeFirst(pendingStems[i].count - limit)
      }
    }
  }
}

// MARK: - Settings read-back

/// DIP SW1 as last set (`PC88.dipSw1`).
@_cdecl("b88_get_dipsw1")
public func b88_get_dipsw1(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  Int32(context(handle)?.pc88.dipSw1 ?? 0)
}

/// Set DIP SW2 as is, boot strap bit included (`PC88.dipSw2`). Use
/// `b88_apply_bootstrap` to have bit 3 follow drive 0 instead.
@_cdecl("b88_set_dipsw2")
public func b88_set_dipsw2(_ handle: UnsafeMutableRawPointer?, _ value: Int32) {
  context(handle)?.pc88.dipSw2 = UInt8(truncatingIfNeeded: value)
}

/// DIP SW2 as the machine sees it, boot strap bit included.
@_cdecl("b88_get_dipsw2")
public func b88_get_dipsw2(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  Int32(context(handle)?.pc88.dipSw2 ?? 0)
}

/// Memory wait DIP: 1 = on, 0 = off.
@_cdecl("b88_get_memory_wait_dip")
public func b88_get_memory_wait_dip(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.memoryWaitDip ?? false) ? 1 : 0
}

/// CPU overclock multiplier; 1 = real speed.
@_cdecl("b88_get_cpu_overclock")
public func b88_get_cpu_overclock(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  Int32(context(handle)?.pc88.cpuOverclock ?? 1)
}

/// Report the sound board as an OPN (YM2203) so programs skip OPNA features
/// (`PC88.forceOPNMode`).
@_cdecl("b88_set_force_opn")
public func b88_set_force_opn(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  context(handle)?.pc88.forceOPNMode = (on != 0)
}

@_cdecl("b88_get_force_opn")
public func b88_get_force_opn(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.forceOPNMode ?? false) ? 1 : 0
}

// MARK: - Immersive audio

/// Also produce each sound source on its own (`PC88.immersiveOutputEnabled`),
/// for spatial rendering. Drain them with `b88_drain_audio_stem`. Turning it
/// off drops any stem samples not yet drained.
@_cdecl("b88_set_immersive_output")
public func b88_set_immersive_output(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  guard let c = context(handle) else { return }
  c.pc88.immersiveOutputEnabled = (on != 0)
  if on == 0 { c.pendingStems = [[], [], [], [], []] }
}

/// Drain up to `maxPairs` stereo pairs of one stem: 0 = FM (with the
/// beeper), 1 = SSG, 2 = ADPCM, 3 = rhythm, 4 = CD audio (silence while no
/// disc is playing). They cover the same span as `b88_drain_audio`, which
/// is what takes them from the core, so call it first each time. Returns the pairs written, -1 for a bad stem.
@_cdecl("b88_drain_audio_stem")
public func b88_drain_audio_stem(_ handle: UnsafeMutableRawPointer?,
                                 _ stem: Int32,
                                 _ outPtr: UnsafeMutablePointer<Float>?,
                                 _ maxPairs: Int32) -> Int32 {
  guard let c = context(handle), c.pendingStems.indices.contains(Int(stem)) else { return -1 }
  guard let outPtr, maxPairs > 0 else { return 0 }
  let i = Int(stem)
  let n = min(Int(maxPairs) * 2, c.pendingStems[i].count)
  guard n > 0 else { return 0 }
  c.pendingStems[i].withUnsafeBufferPointer { src in
    outPtr.update(from: src.baseAddress!, count: n)
  }
  c.pendingStems[i].removeFirst(n)
  return Int32(n / 2)
}

// MARK: - Keyboard and mouse

/// Release every key (`PC88.releaseAllKeys`), as when the window loses focus.
@_cdecl("b88_release_all_keys")
public func b88_release_all_keys(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.pc88.releaseAllKeys()
}

/// Connect the mouse (`PC88.mouseEnabled`). Port reads pass through
/// untouched while it is not.
@_cdecl("b88_set_mouse_enabled")
public func b88_set_mouse_enabled(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  context(handle)?.pc88.mouseEnabled = (on != 0)
}

/// 1 = the mouse drives the joystick direction bits, 0 = bus mouse
/// (`PC88.mouseJoystickMode`).
@_cdecl("b88_set_mouse_joystick_mode")
public func b88_set_mouse_joystick_mode(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  context(handle)?.pc88.mouseJoystickMode = (on != 0)
}

/// Feed relative mouse movement from the host (`PC88.moveMouse`).
@_cdecl("b88_move_mouse")
public func b88_move_mouse(_ handle: UnsafeMutableRawPointer?, _ dx: Int32, _ dy: Int32) {
  context(handle)?.pc88.moveMouse(dx: Int(dx), dy: Int(dy))
}

@_cdecl("b88_set_mouse_buttons")
public func b88_set_mouse_buttons(_ handle: UnsafeMutableRawPointer?,
                                  _ left: Int32, _ right: Int32) {
  context(handle)?.pc88.setMouseButtons(left: left != 0, right: right != 0)
}

// MARK: - Screen text and font

/// The text screen as Unicode (`PC88.copyTextAsUnicode`), one line per row,
/// written as NUL-terminated UTF-8. Returns the UTF-8 length without the
/// NUL; pass a nil buffer to ask for it first.
@_cdecl("b88_copy_text")
public func b88_copy_text(_ handle: UnsafeMutableRawPointer?,
                          _ outUtf8: UnsafeMutablePointer<UInt8>?,
                          _ outCap: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return copyOutString(c.pc88.copyTextAsUnicode(), outUtf8, outCap)
}

/// The 8×8 font ROM glyph for `code`, one byte per row with the MSB on the
/// left (`PC88.glyph`), for drawing keytops. Returns the bytes needed (8).
@_cdecl("b88_glyph")
public func b88_glyph(_ handle: UnsafeMutableRawPointer?, _ code: Int32,
                      _ out: UnsafeMutablePointer<UInt8>?, _ outCap: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return copyOut(c.pc88.glyph(for: UInt8(truncatingIfNeeded: code)), out, outCap)
}
