// CApiVGMPlayer.swift — C ABI for playing YM2608 VGM files (`VGMPlayer`).
//
// Independent of a machine: a player handle owns its own synthesizer.

import Bubilator88Core

/// Parse an uncompressed VGM file of `len` bytes and return a player
/// handle, or null if the file is damaged or needs a chip other than one
/// YM2608. `loops` is how many times a looped file repeats its loop.
/// Release the handle with `b88_vgm_player_close`.
@_cdecl("b88_vgm_player_open")
public func b88_vgm_player_open(_ data: UnsafePointer<UInt8>?, _ len: Int32,
                                _ loops: Int32) -> UnsafeMutableRawPointer? {
  guard let file = try? VGMFile(bytes: bytes(data, len)),
        let player = try? VGMPlayer(file: file, loops: Int(loops)) else { return nil }
  return Unmanaged.passRetained(player).toOpaque()
}

@_cdecl("b88_vgm_player_close")
public func b88_vgm_player_close(_ player: UnsafeMutableRawPointer?) {
  guard let player else { return }
  Unmanaged<VGMPlayer>.fromOpaque(player).release()
}

@inline(__always)
private func vgmPlayer(_ handle: UnsafeMutableRawPointer?) -> VGMPlayer? {
  guard let handle else { return nil }
  return Unmanaged<VGMPlayer>.fromOpaque(handle).takeUnretainedValue()
}

/// Load rhythm sample `index` (0 BD, 1 SD, 2 TOP, 3 HH, 4 TOM, 5 RIM) from
/// `count` signed 16-bit mono samples. Returns 1 on success, else 0.
@_cdecl("b88_vgm_player_load_rhythm")
public func b88_vgm_player_load_rhythm(_ player: UnsafeMutableRawPointer?, _ index: Int32,
                                       _ samples: UnsafePointer<Int16>?, _ count: Int32,
                                       _ sampleRate: Int32) -> Int32 {
  guard let p = vgmPlayer(player), let samples, count > 0 else { return 0 }
  let data = Array(UnsafeBufferPointer(start: samples, count: Int(count)))
  return (try? p.loadRhythmSample(index: Int(index), samples: data,
                                  sampleRate: Int(sampleRate))) != nil ? 1 : 0
}

/// Total playback length in 44.1kHz frames, loops included.
@_cdecl("b88_vgm_player_total_frames")
public func b88_vgm_player_total_frames(_ player: UnsafeMutableRawPointer?) -> Int32 {
  Int32(clamping: vgmPlayer(player)?.totalFrames ?? 0)
}

/// Frames rendered so far.
@_cdecl("b88_vgm_player_played_frames")
public func b88_vgm_player_played_frames(_ player: UnsafeMutableRawPointer?) -> Int32 {
  Int32(clamping: vgmPlayer(player)?.playedFrames ?? 0)
}

/// Render up to `maxFrames` frames of interleaved stereo Float32 into `out`
/// (room for `2 * maxFrames` floats). Returns the frames written; 0 once
/// playback has finished.
@_cdecl("b88_vgm_player_render")
public func b88_vgm_player_render(_ player: UnsafeMutableRawPointer?,
                                  _ out: UnsafeMutablePointer<Float>?,
                                  _ maxFrames: Int32) -> Int32 {
  guard let p = vgmPlayer(player), let out, maxFrames > 0 else { return 0 }
  let pcm = p.render(maxFrames: Int(maxFrames))
  pcm.withUnsafeBufferPointer { src in
    if !src.isEmpty { out.update(from: src.baseAddress!, count: src.count) }
  }
  return Int32(pcm.count / 2)
}

/// Copy GD3 field `field` (0–10, in file order: track, game, system and
/// author in English then Japanese, then date, ripper, notes) as
/// NUL-terminated UTF-8. Returns its UTF-8 length; pass a nil buffer to ask
/// for it first.
@_cdecl("b88_vgm_player_tag")
public func b88_vgm_player_tag(_ player: UnsafeMutableRawPointer?, _ field: Int32,
                               _ out: UnsafeMutablePointer<UInt8>?, _ cap: Int32) -> Int32 {
  guard let p = vgmPlayer(player), (0..<11).contains(field) else { return 0 }
  return copyOutString(p.file.tags.fields[Int(field)], out, cap)
}
