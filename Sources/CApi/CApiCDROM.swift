// CApiCDROM.swift — the PC-8801MC CD-ROM drive.
//
// Every function here must be `public` (see CApi.swift).

import Bubilator88Core
import Foundation

/// Load the CD BIOS, CDBIOS.ROM (64KB) (`PC88.loadCDBios`). Takes effect
/// at the next `b88_reset`.
@_cdecl("b88_load_cd_bios")
public func b88_load_cd_bios(_ handle: UnsafeMutableRawPointer?,
                             _ ptr: UnsafePointer<UInt8>?, _ len: Int32) {
  guard let c = context(handle) else { return }
  let data = bytes(ptr, len)
  guard !data.isEmpty else { return }
  c.pc88.loadCDBios(data)
}

/// Drop the CD BIOS (`PC88.unloadCDBios`), for when CDBIOS.ROM has gone.
/// Takes effect at the next `b88_reset`.
@_cdecl("b88_unload_cd_bios")
public func b88_unload_cd_bios(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.pc88.unloadCDBios()
}

/// Fit (1) or remove (0) the CD-ROM drive (`PC88.cdDriveInstalled`). With
/// the CD BIOS loaded as well, the machine starts in the CD BIOS from the
/// next `b88_reset`.
@_cdecl("b88_set_cd_drive")
public func b88_set_cd_drive(_ handle: UnsafeMutableRawPointer?, _ on: Int32) {
  context(handle)?.pc88.cdDriveInstalled = (on != 0)
}

/// 1 when the drive took effect at the last reset.
@_cdecl("b88_is_cd_drive_active")
public func b88_is_cd_drive_active(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.isCDDriveActive ?? false) ? 1 : 0
}

/// Insert a CD from a NUL-terminated UTF-8 path: a `.cue` or `.ccd` sheet,
/// or the `.img` / `.bin` next to one (`PC88.mountCD`). The files are read
/// as needed, so they are passed by path and must stay in place while the
/// disc is in. Returns the number of tracks, or a negative error:
///
///     -1 unreadable   -2 a file the sheet names is missing
///     -3 a track not stored as raw 2352-byte sectors   -4 no tracks
@_cdecl("b88_mount_cd")
public func b88_mount_cd(_ handle: UnsafeMutableRawPointer?,
                         _ path: UnsafePointer<CChar>?) -> Int32 {
  guard let c = context(handle), let path = string(path) else { return -1 }
  do {
    try c.pc88.mountCD(url: URL(fileURLWithPath: path))
    return Int32(c.pc88.cdTrackCount)
  } catch let error as CDImageError {
    return cdErrorCode(error)
  } catch {
    return -1
  }
}

private func cdErrorCode(_ error: CDImageError) -> Int32 {
  switch error {
  case .unreadable: return -1
  case .imageFileNotFound: return -2
  case .unsupportedTrackMode: return -3
  case .noTracks: return -4
  }
}

/// Put the CD back after `b88_load_state`, keeping the play position the
/// state restored (`PC88.reattachCD`). Same returns as `b88_mount_cd`.
@_cdecl("b88_reattach_cd")
public func b88_reattach_cd(_ handle: UnsafeMutableRawPointer?,
                            _ path: UnsafePointer<CChar>?) -> Int32 {
  guard let c = context(handle), let path = string(path) else { return -1 }
  do {
    try c.pc88.reattachCD(url: URL(fileURLWithPath: path))
    return Int32(c.pc88.cdTrackCount)
  } catch let error as CDImageError {
    return cdErrorCode(error)
  } catch {
    return -1
  }
}

@_cdecl("b88_eject_cd")
public func b88_eject_cd(_ handle: UnsafeMutableRawPointer?) {
  context(handle)?.pc88.ejectCD()
}

/// Tracks on the CD in the drive, 0 when it is empty.
@_cdecl("b88_cd_track_count")
public func b88_cd_track_count(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  Int32(context(handle)?.pc88.cdTrackCount ?? 0)
}

/// 1 when the drive has been busy since the last call, for an access lamp.
/// Clears the flag.
@_cdecl("b88_cd_activity")
public func b88_cd_activity(_ handle: UnsafeMutableRawPointer?) -> Int32 {
  (context(handle)?.pc88.takeCDActivity() ?? false) ? 1 : 0
}
