// VGMPlayer.swift — renders a VGMFile through a standalone YM2608.

/// Plays a `VGMFile` into interleaved stereo Float32 at 44.1kHz.
///
/// Rendering runs ahead of real time by a wide margin, so a host can call
/// `render` from its audio refill path and stream the file without
/// rendering it in full first.
public final class VGMPlayer {
  public let file: VGMFile
  /// Frames the whole playback lasts: one pass plus `loops` repeats of the
  /// looped part.
  public let totalFrames: Int
  /// Frames rendered so far.
  public private(set) var playedFrames = 0

  private let renderer: YM2608Renderer
  private var cursor = 0
  private var waiting = 0
  private var loopsLeft: Int

  /// `loops` is how many times the looped part repeats after the first
  /// pass; files without a loop play once regardless.
  public init(file: VGMFile, loops: Int = 1) throws {
    self.file = file
    loopsLeft = file.loopStart == nil ? 0 : max(0, loops)
    totalFrames = file.samples(loops: loops)
    renderer = try YM2608Renderer(clockHz: file.clockHz)
  }

  /// Load one of the six rhythm samples (BD, SD, TOP, HH, TOM, RIM), as
  /// `YM2608Renderer.loadRhythmSample`. Without them the rhythm part is
  /// silent.
  public func loadRhythmSample(index: Int, samples: [Int16], sampleRate: Int) throws {
    try renderer.loadRhythmSample(index: index, samples: samples, sampleRate: sampleRate)
  }

  /// True once every frame has been rendered.
  public var isFinished: Bool { playedFrames >= totalFrames }

  /// Render up to `maxFrames` frames. Returns fewer at the end and an empty
  /// array once finished.
  public func render(maxFrames: Int) -> [Float] {
    var pcm: [Float] = []
    let limit = min(maxFrames, totalFrames - playedFrames)
    guard limit > 0 else { return pcm }
    pcm.reserveCapacity(limit * 2)
    var rendered = 0
    while rendered < limit {
      if waiting > 0 {
        let frames = min(waiting, limit - rendered)
        pcm += renderer.render(frames: frames)
        waiting -= frames
        rendered += frames
        continue
      }
      if cursor == file.events.count {
        guard loopsLeft > 0, let loopStart = file.loopStart else { break }
        loopsLeft -= 1
        cursor = loopStart
      }
      let event = file.events[cursor]
      cursor += 1
      switch event {
      case .wait(let frames):
        waiting = frames
      case .write(let secondary, let register, let value):
        renderer.write(port: secondary ? .secondary : .primary, register: register, value: value)
      case .adpcm(let offset, let bytes):
        // `VGMFile` has already checked the range against the RAM size.
        try? renderer.loadADPCM(bytes, at: offset)
      }
    }
    playedFrames += rendered
    return pcm
  }
}
