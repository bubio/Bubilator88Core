// CApiMedia.swift — tape, disk write-back, memory images, save-state files
// and cheat files.
//
// Every function here must be `public` (see CApi.swift).

import Bubilator88Core
import Foundation

// MARK: - Tape

/// Load a cassette image, T88 or raw CMT (`PC88.mountTape`). Returns 1 for
/// T88, 2 for CMT, 0 for no data.
@_cdecl("b88_mount_tape")
public func b88_mount_tape(_ handle: UnsafeMutableRawPointer?,
                           _ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return 0 }
  switch c.pc88.mountTape(data: Data(data)) {
  case .t88: return 1
  case .cmt: return 2
  }
}

@_cdecl("b88_eject_tape")
public func b88_eject_tape(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.pc88.ejectTape()
}

@_cdecl("b88_rewind_tape")
public func b88_rewind_tape(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.pc88.rewindTape()
}

@_cdecl("b88_is_tape_loaded")
public func b88_is_tape_loaded(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.isTapeLoaded ?? false) ? 1 : 0
}

/// Whether the motor is turning with tape left to read
/// (`PC88.isTapeMotorRunning`), for the motor sound.
@_cdecl("b88_is_tape_motor_running")
public func b88_is_tape_motor_running(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.isTapeMotorRunning ?? false) ? 1 : 0
}

/// Playback position, 0.0-1.0.
@_cdecl("b88_tape_progress")
public func b88_tape_progress(_ handle: UnsafeMutableRawPointer?) -> Double {
  context(handle)?.pc88.tapeProgress ?? 0
}

// MARK: - Disk

/// Whether the disk in `drive` is write-protected: 1 yes, 0 no or empty.
@_cdecl("b88_is_write_protected")
public func b88_is_write_protected(_ handle: UnsafeMutableRawPointer?, _ drive: Int32) -> Int32 {
  (context(handle)?.pc88.isWriteProtected(drive: Int(drive)) ?? false) ? 1 : 0
}

/// The D88 name of the disk in `drive`, as NUL-terminated UTF-8. Returns the
/// UTF-8 length without the NUL, or -1 with the drive empty.
@_cdecl("b88_disk_name")
public func b88_disk_name(_ handle: UnsafeMutableRawPointer?, _ drive: Int32,
                          _ outUtf8: UnsafeMutablePointer<UInt8>?,
                          _ outCap: Int32) -> Int32 {
  guard let disk = context(handle)?.pc88.mountedDisk(drive: Int(drive)) else { return -1 }
  return copyOutString(disk.name, outUtf8, outCap)
}

/// Which drives the machine has written to since the last call: bit 0 for
/// drive 0, bit 1 for drive 1. Clears them. macOS starts its write-back
/// timer from `PC88.onDiskWritten`; poll this once a frame instead.
@_cdecl("b88_take_disk_written")
public func b88_take_disk_written(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let bits = (c.diskWritten[0] ? 1 : 0) | (c.diskWritten[1] ? 2 : 0)
  c.diskWritten = [false, false]
  return Int32(bits)
}

/// If the disk in `drive` has been written since it was mounted or last
/// taken, serialise it and mark it clean (`PC88.takeDirtyDiskImage`).
/// Returns the image size, then copy it out with `b88_take_dirty_disk_read`;
/// 0 when there is nothing to write back. If saving the file fails, call
/// `b88_mark_disk_dirty` so the next attempt tries again.
@_cdecl("b88_take_dirty_disk")
public func b88_take_dirty_disk(_ handle: UnsafeMutableRawPointer?, _ drive: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  c.dirtyDiskBlob = c.pc88.takeDirtyDiskImage(drive: Int(drive)) ?? []
  return Int32(c.dirtyDiskBlob.count)
}

/// Copy the image `b88_take_dirty_disk` took. Returns the bytes needed.
@_cdecl("b88_take_dirty_disk_read")
public func b88_take_dirty_disk_read(_ handle: UnsafeMutableRawPointer?,
                                     _ out: UnsafeMutablePointer<UInt8>?,
                                     _ outCap: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return copyOut(c.dirtyDiskBlob, out, outCap)
}

/// Mark the disk in `drive` as needing write-back again.
@_cdecl("b88_mark_disk_dirty")
public func b88_mark_disk_dirty(_ handle: UnsafeMutableRawPointer?, _ drive: Int32) {
  context(handle)?.pc88.markDiskDirty(drive: Int(drive))
}

// MARK: - Memory image (.n80)

/// Restore a `.n80` memory image into a machine already reset into N-BASIC
/// (`PC88.restoreMemoryImage`). `b88_memory_image_boot_start` does the whole
/// sequence. Returns 1 on success, 0 when the data is not 0x7F40 bytes.
@_cdecl("b88_restore_memory_image")
public func b88_restore_memory_image(_ handle: UnsafeMutableRawPointer?,
                                     _ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  return c.pc88.restoreMemoryImage(bytes(ptr, len)) ? 1 : 0
}

// MARK: - Save-state files

/// `b88_save_state` with a thumbnail and the host's own sections
/// (`PC88.createSaveState(thumbnail:extraSections:)`).
///
/// `thumb` is embedded as is (macOS stores a PNG). `extra` is a run of
/// sections, each `tag` (u32 LE, a FourCC such as "AMTA"), `length` (u32 LE)
/// and `length` bytes; the core attaches no meaning to them. Either may be
/// nil. Returns the blob length; copy it out with `b88_save_state_read`.
@_cdecl("b88_save_state_ex")
public func b88_save_state_ex(_ handle: UnsafeMutableRawPointer?,
                              _ thumb: UnsafePointer<UInt8>?, _ thumbLen: Int32,
                              _ extra: UnsafePointer<UInt8>?, _ extraLen: Int32) -> Int32 {
  guard let c = context(handle) else { return 0 }
  let thumbnail = bytes(thumb, thumbLen)
  let raw = bytes(extra, extraLen)
  var sections: [(tag: UInt32, data: [UInt8])] = []
  var p = 0
  func u32(_ at: Int) -> UInt32 {
    UInt32(raw[at]) | UInt32(raw[at + 1]) << 8 | UInt32(raw[at + 2]) << 16 | UInt32(raw[at + 3]) << 24
  }
  while p + 8 <= raw.count {
    let tag = u32(p)
    let length = Int(u32(p + 4))
    p += 8
    guard length <= raw.count - p else { break }
    sections.append((tag: tag, data: Array(raw[p..<(p + length)])))
    p += length
  }
  c.saveStateBlob = c.pc88.createSaveState(thumbnail: thumbnail.isEmpty ? nil : thumbnail,
                                           extraSections: sections)
  return Int32(c.saveStateBlob.count)
}

/// When a save state was written, in seconds since 1970, from the header of
/// the bytes of a `.b88s` file (the first 64 are enough). Returns 0 when
/// they are not a save state.
@_cdecl("b88_state_timestamp")
public func b88_state_timestamp(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> Double {
  guard let header = try? SaveStateFile.parseHeader(bytes(ptr, len)),
        header.timestamp.isFinite, header.timestamp > 0 else { return 0 }
  return header.timestamp
}

/// One section of a `.b88s` file's bytes, by FourCC (`tag` as u32 LE:
/// "THMB" for the thumbnail, "AMTA" for macOS's metadata, "META" for the
/// core's). Pass enough of the file to reach the section. Returns the
/// section length, or -1 when it is absent or the data is not a save state.
@_cdecl("b88_state_section")
public func b88_state_section(_ ptr: UnsafePointer<UInt8>?, _ len: Int32, _ tag: UInt32,
                              _ out: UnsafeMutablePointer<UInt8>?, _ outCap: Int32) -> Int32 {
  let data = bytes(ptr, len)
  guard let entries = try? SaveStateFile.parseSectionTable(data),
        let entry = entries.first(where: { $0.tag == tag }),
        entry.offset >= 0, entry.size >= 0, entry.offset + entry.size <= data.count
  else { return -1 }
  return copyOut(Array(data[entry.offset..<(entry.offset + entry.size)]), out, outCap)
}

/// A FourCC as the u32 the section functions take, e.g. "THMB".
@_cdecl("b88_fourcc")
public func b88_fourcc(_ text: UnsafePointer<CChar>?) -> UInt32 {
  guard let s = string(text) else { return 0 }
  return SaveStateFile.fourCC(s)
}

// MARK: - Cheat files (.pat)

/// Decode and parse the bytes of an 88PAR `.pat` file (`PATFile.decodeText`
/// then `PATFile.parse`), written as NUL-terminated UTF-8 lines:
///
///     G<TAB>name          a group (show an empty name as "No Name", `PATFile.unnamedGroupName`)
///     C<TAB>hhhhhhhhhhhh  one of its codes, the 6 bytes b88_pat_run takes, in hex
///     N<TAB>text          one of its notes
///
/// Returns the UTF-8 length without the NUL; pass a nil buffer to ask first.
@_cdecl("b88_pat_parse")
public func b88_pat_parse(_ ptr: UnsafePointer<UInt8>?, _ len: Int32,
                          _ outUtf8: UnsafeMutablePointer<UInt8>?,
                          _ outCap: Int32) -> Int32 {
  let text = PATFile.decodeText(Data(bytes(ptr, len)))
  var lines: [String] = []
  for group in PATFile.parse(text) {
    lines.append("G\t" + group.name)
    for code in group.codes {
      let b: [UInt8] = [code.opcode, code.area,
                        UInt8(code.address & 0xFF), UInt8(code.address >> 8),
                        UInt8(code.value & 0xFF), UInt8(code.value >> 8)]
      lines.append("C\t" + b.map { String(format: "%02X", $0) }.joined())
    }
    for note in group.notes {
      lines.append("N\t" + note)
    }
  }
  return copyOutString(lines.joined(separator: "\n"), outUtf8, outCap)
}
