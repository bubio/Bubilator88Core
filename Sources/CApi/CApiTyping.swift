// CApiTyping.swift — Paste Text, Tape Auto Boot and the `.n80` load.
//
// All three type into the machine through one `TextPasteQueue`, ticked once
// per frame. macOS runs them from its frame loop, before the frame, in this
// order: paste, Tape Auto Boot, memory image; call the `*_tick` functions the
// same way, from the thread that runs the frames. Every function here must be
// `public` (see CApi.swift).

import Bubilator88Core
import Foundation

extension B88Context {
  func apply(_ event: TextPasteQueue.KeyEvent) {
    if event.down {
      pc88.pressKey(event.key)
    } else {
      pc88.releaseKey(event.key)
    }
  }
}

// MARK: - Paste Text

/// Type NUL-terminated UTF-8 text as key presses, after anything still
/// queued. ASCII and half-width katakana are typed; anything else is
/// skipped.
@_cdecl("b88_paste_text")
public func b88_paste_text(_ handle: UnsafeMutableRawPointer?, _ utf8: UnsafePointer<CChar>?) {
  guard let c = context(handle), let text = string(utf8), !text.isEmpty else { return }
  c.pasteQueue.enqueue(text)
}

/// Stop typing, releasing any key the queue holds down. Cancels Tape Auto
/// Boot and the memory-image load too, as macOS does for ESC, a reset and a
/// state load; call it before `b88_reset` and `b88_load_state`.
@_cdecl("b88_paste_cancel")
public func b88_paste_cancel(_ handle: UnsafeMutableRawPointer?) {
  guard let c = context(handle) else { return }
  c.pasteQueue.cancel { c.apply($0) }
  c.tapeAutoBoot.cancel()
  c.memoryImageBoot.cancel()
}

/// 1 when nothing is left to type.
@_cdecl("b88_paste_is_idle")
public func b88_paste_is_idle(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pasteQueue.isEmpty ?? true) ? 1 : 0
}

/// Advance typing by one frame.
@_cdecl("b88_paste_tick")
public func b88_paste_tick(_ handle: UnsafeMutableRawPointer?) {
  guard let c = context(handle) else { return }
  c.pasteQueue.tick { c.apply($0) }
}

// MARK: - Tape Auto Boot

/// Start Tape Auto Boot: type `LOAD "CAS:"` at the prompt and `RUN` once the
/// tape has loaded. The host prepares the machine first, as macOS does:
/// mount the tape, eject the disks, rewind, set N88-BASIC V1S (DIP SW1 0xC3,
/// SW2 base 0xB1 through `b88_apply_bootstrap`), `b88_reset`, then call this.
@_cdecl("b88_tape_autoboot_start")
public func b88_tape_autoboot_start(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.tapeAutoBoot.start()
}

@_cdecl("b88_tape_autoboot_cancel")
public func b88_tape_autoboot_cancel(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.tapeAutoBoot.cancel()
}

/// Advance Tape Auto Boot by one frame and return its phase:
///
///     0 idle  1 waiting for the prompt  2 typing LOAD  3 waiting for the motor
///     4 loading  5 typing RUN  6 finished
///     100 failed: no prompt   101 failed: the motor never started
///     102 failed: the load never finished   103 failed: the tape ran out
///     104 failed: BASIC reported an error
///
/// Call after `b88_paste_tick`. macOS shows a toast on any failure.
@_cdecl("b88_tape_autoboot_tick")
public func b88_tape_autoboot_tick(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let boot = c.tapeAutoBoot
  if boot.isActive {
    let pc88 = c.pc88
    if let text = boot.tick(motorRunning: pc88.isTapeMotorRunning,
                            tapeProgress: pc88.tapeProgress,
                            typingIdle: c.pasteQueue.isEmpty,
                            screen: { pc88.copyTextAsUnicode() }) {
      c.pasteQueue.enqueue(text)
    }
  }
  return tapeAutoBootPhaseCode(boot.phase)
}

/// Tape Auto Boot's phase, as `b88_tape_autoboot_tick` returns it, without
/// advancing it.
@_cdecl("b88_tape_autoboot_phase")
public func b88_tape_autoboot_phase(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return tapeAutoBootPhaseCode(c.tapeAutoBoot.phase)
}

private func tapeAutoBootPhaseCode(_ phase: TapeAutoBoot.Phase) -> Int32 {
  switch phase {
  case .idle: return 0
  case .waitingForPrompt: return 1
  case .typingLoad: return 2
  case .waitingForMotor: return 3
  case .loading: return 4
  case .typingRun: return 5
  case .finished: return 6
  case .failed(let failure):
    switch failure {
    case .promptTimeout: return 100
    case .motorTimeout: return 101
    case .loadTimeout: return 102
    case .tapeEnded: return 103
    case .basicError: return 104
    }
  }
}

// MARK: - Memory image (.n80)

/// Start loading a `.n80` memory image: wait for N-BASIC's prompt, restore
/// the image, and type `RUN` if it needs it. The host resets into N-BASIC
/// first (DIP SW1 0xC2, SW2 base 0xB1, drives empty), as macOS does. Returns
/// 0 without starting when the data is not 0x7F40 bytes.
@_cdecl("b88_memory_image_boot_start")
public func b88_memory_image_boot_start(_ handle: UnsafeMutableRawPointer?,
                                        _ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let image = bytes(ptr, len)
  guard image.count == PC88.memoryImageSize else { return 0 }
  c.memoryImageBoot.start(image: image)
  return 1
}

@_cdecl("b88_memory_image_boot_cancel")
public func b88_memory_image_boot_cancel(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.memoryImageBoot.cancel()
}

/// Advance the memory-image load by one frame and return its phase:
/// 0 idle, 1 waiting for the prompt, 2 restored, 3 typing RUN, 4 finished,
/// 100 failed (N-BASIC never reached its prompt). Call after
/// `b88_tape_autoboot_tick`.
@_cdecl("b88_memory_image_boot_tick")
public func b88_memory_image_boot_tick(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let boot = c.memoryImageBoot
  if boot.isActive {
    let pc88 = c.pc88
    switch boot.tick(typingIdle: c.pasteQueue.isEmpty, screen: { pc88.copyTextAsUnicode() }) {
    case .restore(let image):
      pc88.restoreMemoryImage(image)
    case .type(let text):
      c.pasteQueue.enqueue(text)
    case nil:
      break
    }
  }
  switch boot.phase {
  case .idle: return 0
  case .waitingForPrompt: return 1
  case .restored: return 2
  case .typingRun: return 3
  case .finished: return 4
  case .failed: return 100
  }
}
