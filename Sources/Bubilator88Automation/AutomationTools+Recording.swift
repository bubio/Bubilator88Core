import Foundation
@_spi(Debug) import Bubilator88Core

// Input recording and replay. A recording is a `.b88s` save state of the
// moment recording began, with one more section holding the key presses the
// tools made and the frame each came before. Loading it as a save state
// gives the starting point; replaying it also runs the input.

/// The keys pressed and released, frame by frame, since recording began.
struct InputRecording: Codable, Equatable {
  struct Event: Codable, Equatable {
    /// Frames run since the start when the event happened, before the next.
    var frame: Int
    /// A key name as `ScriptParser.key(named:)` reads it; nil releases every key.
    var key: String?
    var down: Bool?
  }

  var version = 1
  /// Frames run in all.
  var frames = 0
  var events: [Event] = []

  static let sectionTag = SaveStateFile.fourCC("AREC")
}

extension AutomationTools {

  /// The tools that change the machine other than through the keyboard. A
  /// replay could not repeat them, so they are refused while recording.
  static let refusedWhileRecording: Set<String> = [
    "reset", "resume", "step", "mount_disk", "eject_disk", "load_state", "write_memory",
    "set_registers", "load_bin", "tape", "replay",
  ]

  static let recordingTools: [Tool] = [
    tool("record_start", """
    Start recording input. Saves the machine to a .b88s file now; key, type_text and \
    run_frames are then recorded until record_stop adds them to the file. Tools that \
    change the machine in other ways (reset, disks, memory writes, step, ...) are refused \
    meanwhile. The file is an ordinary save state too. In the app, only the tools' input \
    is recorded, not the user's.
    """, [
      "path": ["type": "string", "description": "Absolute path of the .b88s file."],
    ], required: ["path"]) { tools, args in
      try tools.startRecording(args)
    },
    tool("record_stop", "Stop recording and add the input to the file record_start saved.") { tools, _ in
      try tools.stopRecording()
    },
    tool("replay", """
    Restore a recording made with record_start and run it: the same input on the same \
    frames. Stops early at a breakpoint.
    """, [
      "path": ["type": "string", "description": "Absolute path of the .b88s file."],
    ], required: ["path"]) { tools, args in
      try tools.replay(args)
    },
  ]

  // MARK: - Keys

  /// Press or release `key` (nil: release every key), recording it.
  /// `frameOffset` counts frames run so far by a run still in progress.
  func setKey(_ key: PC88Key?, down: Bool, on pc88: PC88, frameOffset: Int = 0) {
    if let key {
      if down { pc88.pressKey(key) } else { pc88.releaseKey(key) }
    } else {
      pc88.releaseAllKeys()
    }
    guard var recording = recording?.input else { return }
    recording.events.append(InputRecording.Event(
      frame: recording.frames + frameOffset,
      key: key.map(ScriptWriter.keyName(for:)),
      down: key == nil ? nil : down
    ))
    self.recording?.input = recording
  }

  // MARK: - Recording

  private func startRecording(_ args: Arguments) throws -> ToolResult {
    guard recording == nil else { throw AutomationError("Already recording; record_stop first.") }
    let url = try args.path("path")
    try host.saveState(to: url)
    recording = (url, InputRecording())
    return ToolResult([.text("Recording. Saved the starting state to \(url.path).")])
  }

  private func stopRecording() throws -> ToolResult {
    guard let (url, input) = recording else { throw AutomationError("Not recording.") }
    let file: [UInt8]
    do {
      file = Array(try Data(contentsOf: url))
    } catch {
      throw AutomationError("Cannot read \(url.path) back: \(error.localizedDescription)")
    }
    let section = Array(try JSONEncoder().encode(input))
    let updated = try SaveStateFile.settingSection(InputRecording.sectionTag, to: section, in: file)
    try Data(updated).write(to: url, options: .atomic)
    recording = nil
    return ToolResult([.text("Recorded \(input.frames) frame(s) and \(input.events.count) key event(s) to \(url.path).")])
  }

  // MARK: - Replay

  private func replay(_ args: Arguments) throws -> ToolResult {
    let url = try args.path("path")
    let input: InputRecording
    do {
      let sections = try SaveStateFile.parse(Array(Data(contentsOf: url)))
      guard let section = sections[InputRecording.sectionTag] else {
        throw AutomationError("\(url.lastPathComponent) is a save state with no recorded input.")
      }
      input = try JSONDecoder().decode(InputRecording.self, from: Data(section))
    } catch let error as AutomationError {
      throw error
    } catch {
      throw AutomationError("Cannot read \(url.path) as a recording: \(error)")
    }
    var keys: [PC88Key?] = []
    for event in input.events {
      guard let name = event.key else {
        keys.append(nil)
        continue
      }
      guard let key = ScriptParser.key(named: name) else {
        throw AutomationError("The recording has an unknown key \(name).")
      }
      keys.append(key)
    }
    try host.loadState(from: url)

    var next = 0
    func apply(upTo frame: Int, on pc88: PC88) {
      while next < input.events.count, input.events[next].frame <= frame {
        let event = input.events[next]
        setKey(keys[next], down: event.down ?? false, on: pc88)
        next += 1
      }
    }
    var frame = 0
    let (frames, stop) = try run(input.frames) { pc88 in
      apply(upTo: frame, on: pc88)
      frame += 1
      return true
    }
    if stop == nil {
      try withMachine { apply(upTo: input.frames, on: $0) }
    }
    let summary = "Replayed \(frames) of \(input.frames) frame(s) from \(url.lastPathComponent)."
    return ToolResult([.text(stop.map { "\(summary) \($0)" } ?? summary)])
  }
}
