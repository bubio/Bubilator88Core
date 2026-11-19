import Foundation
@_spi(Debug) import Bubilator88Core

// Running until something happens on the screen, and listening to the
// sound: the ways to let the machine get on with it and check the result
// in one call instead of many short runs.

extension AutomationTools {

  static let observeTools: [Tool] = [
    tool("wait_for", """
    Run frames until the text screen contains text (as read_text shows it, case-sensitive), \
    or until the screen has not changed for stable_frames frames; give one of the two. \
    Returns at once if the text is already there. Stops early at a breakpoint or watch. \
    Use it in place of repeated run_frames and screenshots, e.g. to wait for a title \
    screen, a prompt or the end of loading.
    """, [
      "text": ["type": "string", "description": "Text to wait for."],
      "stable_frames": ["type": "integer", "minimum": 2, "maximum": 3600,
                        "description": "Frames the screen must stay the same."],
      "max_frames": ["type": "integer", "minimum": 1, "maximum": 36000,
                     "description": "Give up after this many frames. Default 600."],
      "screenshot": ["type": "boolean", "description": "Also return the screen afterwards. Default false."],
    ]) { tools, args in
      try tools.waitFor(args)
    },
    tool("capture_audio", """
    Run frames while recording the sound, and report how loud it was: peak and RMS in \
    dBFS overall, per source (FM, SSG, ADPCM, rhythm, CD) and per second. Use it to check \
    that music or effects play. Optionally save it as a 16-bit stereo 44.1kHz WAV file.
    """, [
      "frames": ["type": "integer", "minimum": 1, "maximum": .number(Double(maxAudioFrames)),
                 "description": "Default 120 (about 2 s)."],
      "path": ["type": "string", "description": "Absolute path of a .wav file to also save."],
    ]) { tools, args in
      try tools.captureAudio(args)
    },
  ]

  /// About a minute: the WAV is kept in memory until it is written.
  static let maxAudioFrames = 3600

  // MARK: - wait_for

  private func waitFor(_ args: Arguments) throws -> ToolResult {
    let text = try args.string("text")
    let stable = args.has("stable_frames") ? try args.int("stable_frames", in: 2...3600) : nil
    guard (text == nil) != (stable == nil) else {
      throw AutomationError("Give either text or stable_frames.")
    }
    if let text, text.isEmpty { throw AutomationError("text must not be empty.") }
    let limit = try args.int("max_frames", in: 1...36000, default: 600)

    var matched = false
    var frame = 0
    // The screen is compared on every frame, though rendering it costs
    // about as much as running one: sampling every few frames would miss
    // a blink or a cycle whose period divides the sampling interval.
    var screen = [UInt8](repeating: 0, count: stable == nil ? 0 : PC88.frameBufferSize)
    var previous: [UInt8] = []
    var sameSince = 0
    func check(_ pc88: PC88) -> Bool {
      if let text { return pc88.copyTextAsUnicode().contains(text) }
      guard let stable else { return false }
      pc88.render(into: &screen, blinkCursor: false)
      if screen == previous { return frame - sameSince >= stable }
      swap(&screen, &previous)
      if screen.isEmpty { screen = previous }
      sameSince = frame
      return false
    }
    let (frames, stop) = try run(limit) { pc88 in
      if check(pc88) {
        matched = true
        return false
      }
      frame += 1
      return true
    }
    if !matched, stop == nil, try withMachine({ check($0) }) { matched = true }

    let what = text.map { "\"\($0)\"" } ?? "the screen to settle"
    var line: String
    if let stop {
      line = "Waited \(frames) frame(s) for \(what). \(stop)"
    } else if matched {
      line = text != nil
        ? "Found \(what) after \(frames) frame(s)."
        : "The screen settled; it has not changed for \(stable ?? 0) frame(s) (\(frames) run)."
    } else {
      line = "Gave up after \(frames) frame(s) waiting for \(what)."
    }
    var content: [ToolContent] = [.text(line)]
    if try args.bool("screenshot", default: false) {
      content.append(.png(try renderPNG()))
    }
    return ToolResult(content, isError: !matched && stop == nil)
  }

  // MARK: - capture_audio

  /// Loudness of one stream: interleaved stereo, −1…1.
  struct Loudness {
    var sumSquares = 0.0
    var count = 0
    var peak: Float = 0

    mutating func add(_ samples: [Float]) {
      for s in samples {
        sumSquares += Double(s) * Double(s)
        peak = max(peak, abs(s))
      }
      count += samples.count
    }

    var rms: Double { count == 0 ? 0 : (sumSquares / Double(count)).squareRoot() }

    static func dBFS(_ level: Double) -> String {
      level < 1e-5 ? "silent" : String(format: "%.1f dBFS", 20 * log10(level))
    }
  }

  private func captureAudio(_ args: Arguments) throws -> ToolResult {
    let count = try args.int("frames", in: 1...Self.maxAudioFrames, default: 120)
    let url = args.has("path") ? try args.path("path") : nil

    let sources = ["FM", "SSG", "ADPCM", "rhythm", "CD"]
    var total = Loudness()
    var perSource = [Loudness](repeating: Loudness(), count: sources.count)
    var seconds: [Loudness] = [Loudness()]
    var pcm: [Int16] = []
    let samplesPerSecond = PC88.audioSampleRate * 2

    let saved = try withMachine { pc88 -> (Bool, Bool) in
      let saved = (pc88.audioOutputEnabled, pc88.immersiveOutputEnabled)
      pc88.audioOutputEnabled = true
      pc88.immersiveOutputEnabled = true
      _ = pc88.takeAudioSamples()
      return saved
    }
    defer {
      _ = try? withMachine { pc88 in
        pc88.audioOutputEnabled = saved.0
        pc88.immersiveOutputEnabled = saved.1
      }
    }
    let (frames, stop) = try run(count, afterEach: { pc88 in
      let samples = pc88.takeAudioSamples()
      total.add(samples.stereo)
      for (i, stream) in [samples.fm, samples.ssg, samples.adpcm, samples.rhythm, samples.cd].enumerated() {
        perSource[i].add(stream)
      }
      var rest = samples.stereo[...]
      while !rest.isEmpty {
        let room = samplesPerSecond - seconds[seconds.count - 1].count
        if room == 0 {
          seconds.append(Loudness())
          continue
        }
        let chunk = rest.prefix(room)
        seconds[seconds.count - 1].add(Array(chunk))
        rest = rest.dropFirst(chunk.count)
      }
      if url != nil {
        pcm.append(contentsOf: samples.stereo.map { Int16(max(-1, min(1, $0)) * 32767) })
      }
    })

    var lines = ["Captured \(frames) frame(s), \(String(format: "%.2f", Double(total.count / 2) / Double(PC88.audioSampleRate))) s."
      + (stop.map { " \($0)" } ?? "")]
    lines.append("Overall: peak " + Loudness.dBFS(Double(total.peak)) + ", RMS " + Loudness.dBFS(total.rms) + ".")
    lines.append("By source (RMS): " + zip(sources, perSource).map { "\($0) " + Loudness.dBFS($1.rms) }
      .joined(separator: ", ") + ".")
    if seconds.count > 1 {
      lines.append("Per second (RMS): " + seconds.filter { $0.count > 0 }.map { Loudness.dBFS($0.rms) }
        .joined(separator: ", ") + ".")
    }
    if let url {
      try Data(WAVEncoder.encode(stereo16: pcm, sampleRate: PC88.audioSampleRate)).write(to: url, options: .atomic)
      lines.append("Saved \(url.path).")
    }
    return ToolResult([.text(lines.joined(separator: "\n"))])
  }
}

/// 16-bit PCM WAV files, in plain Swift so it runs wherever the core does.
enum WAVEncoder {
  /// A WAV file of interleaved stereo 16-bit samples.
  static func encode(stereo16 samples: [Int16], sampleRate: Int) -> [UInt8] {
    var out: [UInt8] = []
    let dataSize = samples.count * 2
    out.reserveCapacity(44 + dataSize)
    func u32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    func u16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    out += Array("RIFF".utf8); u32(36 + dataSize); out += Array("WAVE".utf8)
    out += Array("fmt ".utf8); u32(16); u16(1); u16(2); u32(sampleRate); u32(sampleRate * 4); u16(4); u16(16)
    out += Array("data".utf8); u32(dataSize)
    for s in samples {
      let v = UInt16(bitPattern: s)
      out += [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
    return out
  }
}
