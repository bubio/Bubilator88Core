import Foundation
@_spi(Debug) import Bubilator88Core

// The media beyond the disk drives' basics: the CD, the images in a D88
// file, write protection, booting a cassette and `.n80` memory images.

extension AutomationTools {

  static let mediaTools: [Tool] = [
    tool("cd", """
    The CD-ROM drive (PC-8801MC). mount inserts a .cue or .ccd sheet and, with boot \
    (the default), resets in N88-BASIC V2 at 8MHz so the CD BIOS boots it; that needs \
    the CD BIOS (CDBIOS.ROM). The mode and clock apply to that reset only; later resets \
    use the machine's own settings, so give reset mode n88-v2 and clock 8mhz to keep them. \
    eject takes the CD out; reset afterwards to boot from the disks again. \
    status shows whether a CD is in.
    """, [
      "action": ["type": "string", "enum": ["mount", "eject"]],
      "path": ["type": "string", "description": "mount: absolute path of the .cue or .ccd file."],
      "boot": ["type": "boolean", "description": "mount: reset and boot the CD. Default true."],
    ], required: ["action"]) { tools, args in
      try tools.cd(args)
    },
    tool("disk_images", """
    List the disk images in a D88 file, by the numbers mount_disk's image takes, \
    with their names and write protection. Mounts nothing.
    """, [
      "path": ["type": "string", "description": "Absolute path of the .d88 file."],
    ], required: ["path"]) { _, args in
      let url = try args.path("path")
      let images = try AutomationTools.diskImages(at: url)
      return ToolResult([.text("\(url.lastPathComponent) holds \(images.count) image(s):\n"
          + AutomationTools.describeDiskImages(images))])
    },
    tool("set_write_protect", "Set or clear the write-protect tab on the disk in drive 1 or 2.", [
      "drive": ["type": "integer", "enum": [1, 2]],
      "protected": ["type": "boolean"],
    ], required: ["drive", "protected"]) { tools, args in
      let drive = try args.int("drive", in: 1...2)
      let protected = try args.bool("protected", default: true)
      let empty = try tools.withMachine { $0.mountedDisk(drive: drive - 1) == nil }
      guard !empty else { throw AutomationError("Drive \(drive) is empty.") }
      try tools.host.setWriteProtect(drive: drive - 1, protected: protected)
      return ToolResult([.text("Drive \(drive) is \(protected ? "write-protected" : "writable").")])
    },
    tool("load_memory_image", """
    Load a .n80 memory image (a PC-8001 RAM dump): empty the drives and the CD, reset \
    into N-BASIC at 4MHz, restore the image once N-BASIC is at its prompt and type RUN \
    if the image needs it. Runs frames until that is done.
    """, [
      "path": ["type": "string", "description": "Absolute path of the .n80 file."],
      "max_frames": ["type": "integer", "minimum": 1, "maximum": 36000,
                     "description": "Give up after this many frames. Default 1800."],
    ], required: ["path"]) { tools, args in
      try tools.loadMemoryImage(args)
    },
  ]

  // MARK: - CD

  private func cd(_ args: Arguments) throws -> ToolResult {
    switch try args.string("action") ?? "" {
    case "mount":
      let url = try args.path("path")
      let boot = try args.bool("boot", default: true)
      try host.mountCD(url: url)
      let tracks = try withMachine { $0.cdTrackCount }
      let inserted = "Inserted \(url.lastPathComponent) (\(tracks) track(s))."
      guard boot else {
        return ToolResult([.text(inserted + " It boots at the next reset.")])
      }
      pasteQueue.cancel { _ in }
      try host.reset(cold: true, mode: .n88v2, clock8MHz: true)
      try withMachine { $0.releaseAllKeys() }
      guard try withMachine({ $0.isCDDriveActive }) else {
        // Left in, the disc would keep a drive fitted that cannot boot it.
        try host.ejectCD()
        throw AutomationError("The CD drive did not start: this machine has no CD BIOS (CDBIOS.ROM) "
          + "loaded. The CD was taken out again; the machine reset into BASIC.")
      }
      return ToolResult([.text(inserted + " Reset in N88-BASIC V2 at 8MHz to boot it; run frames to let it load.")])
    case "eject":
      try host.ejectCD()
      return ToolResult([.text("The CD drive is empty. Reset to boot from the disks.")])
    case let other:
      throw AutomationError("Unknown action \(other); use mount or eject.")
    }
  }

  // MARK: - Disk images

  /// The images in the D88 file at `url`.
  static func diskImages(at url: URL) throws -> [D88Disk] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    let images = D88Disk.parseAll(data: Array(data))
    guard !images.isEmpty else {
      throw AutomationError("\(url.lastPathComponent) is not a D88 disk image.")
    }
    return images
  }

  static func describeDiskImages(_ images: [D88Disk]) -> String {
    images.enumerated().map { index, disk in
      "\(index)  " + (disk.name.isEmpty ? "(no name)" : disk.name) + (disk.writeProtected ? "  (write-protected)" : "")
    }.joined(separator: "\n")
  }

  // MARK: - Boot sequences

  /// Empty both drives and the CD, as booting a cassette or a memory image
  /// needs: a disk or a CD in at the reset would boot instead.
  func emptyBootMedia() throws {
    try host.ejectDisk(drive: 0)
    try host.ejectDisk(drive: 1)
    if try withMachine({ $0.isCDMounted }) { try host.ejectCD() }
  }

  /// Run frames, typing whatever `step` queues, until `step` says it is
  /// done and everything is typed, or `limit` frames have run. `step` is
  /// called before each frame with the machine and whether typing is idle.
  /// Returns the frames run, whether it finished, and any debugger stop.
  func runSequence(limit: Int, step: @escaping (PC88, Bool) -> Bool) throws
    -> (frames: Int, finished: Bool, stop: String?) {
    let queue = pasteQueue
    var finished = false
    var typed = 0
    let (frames, stop) = try run(limit) { pc88 in
      if step(pc88, queue.isEmpty), queue.isEmpty {
        finished = true
        return false
      }
      queue.tick { event in
        self.setKey(event.key, down: event.down, on: pc88, frameOffset: typed)
      }
      typed += 1
      return true
    }
    if !finished {
      try withMachine { pc88 in
        queue.cancel { event in
          if !event.down { self.setKey(event.key, down: false, on: pc88) }
        }
      }
    }
    return (frames, finished, stop)
  }

  /// Boot the cassette: what the app's Tape > Auto Boot does.
  func bootTape(_ args: Arguments) throws -> ToolResult {
    let limit = try args.int("max_frames", in: 1...36000, default: 36000)
    guard try withMachine({ $0.isTapeLoaded }) else {
      throw AutomationError("No cassette; mount one first.")
    }
    try emptyBootMedia()
    try host.rewindTape()
    pasteQueue.cancel { _ in }
    // Every N88-BASIC mode loads tapes the same way; V1S reaches the prompt
    // without a disk. Tape software is written for 4MHz.
    try host.reset(cold: true, mode: .n88v1s, clock8MHz: false)
    try withMachine { $0.releaseAllKeys() }
    let boot = TapeAutoBoot()
    boot.start()
    let (frames, _, stop) = try runSequence(limit: limit) { pc88, idle in
      if let text = boot.tick(motorRunning: pc88.isTapeMotorRunning, tapeProgress: pc88.tapeProgress,
                              typingIdle: idle, screen: { pc88.copyTextAsUnicode() }) {
        self.pasteQueue.enqueue(text)
        return false
      }
      return !boot.isActive
    }
    if let stop { return ToolResult([.text("Booting the tape, \(frames) frame(s) in. \(stop)")]) }
    switch boot.phase {
    case .finished:
      return ToolResult([.text("Loaded the tape and typed RUN in \(frames) frame(s).")])
    case .failed(let failure):
      return ToolResult([.text("Tape boot stopped after \(frames) frame(s): \(Self.describe(failure)). "
          + "Look at the screen with read_text.")], isError: true)
    default:
      return ToolResult([.text("Tape boot still going after \(frames) frame(s); raise max_frames, "
          + "or run frames and check the screen.")], isError: true)
    }
  }

  static func describe(_ failure: TapeAutoBoot.Failure) -> String {
    switch failure {
    case .promptTimeout: return "BASIC never reached its prompt"
    case .motorTimeout: return "the cassette motor never started after LOAD \"CAS:\""
    case .loadTimeout: return "the load never finished"
    case .tapeEnded: return "the whole tape was read without BASIC returning to Ok (a machine-language tape?)"
    case .basicError: return "BASIC reported an error"
    }
  }

  private func loadMemoryImage(_ args: Arguments) throws -> ToolResult {
    let url = try args.path("path")
    let limit = try args.int("max_frames", in: 1...36000, default: 1800)
    let image: [UInt8]
    do {
      image = Array(try Data(contentsOf: url))
    } catch {
      throw AutomationError("Cannot read \(url.path): \(error.localizedDescription)")
    }
    guard image.count == PC88.memoryImageSize else {
      throw AutomationError("\(url.lastPathComponent) is \(image.count) bytes; a .n80 memory image is "
        + "\(PC88.memoryImageSize).")
    }
    try emptyBootMedia()
    pasteQueue.cancel { _ in }
    // PC-8001 software is written for 4MHz.
    try host.reset(cold: true, mode: .nbasic, clock8MHz: false)
    try withMachine { $0.releaseAllKeys() }
    let boot = MemoryImageBoot()
    boot.start(image: image)
    let (frames, _, stop) = try runSequence(limit: limit) { pc88, idle in
      switch boot.tick(typingIdle: idle, screen: { pc88.copyTextAsUnicode() }) {
      case .restore(let image):
        pc88.restoreMemoryImage(image)
        return false
      case .type(let text):
        self.pasteQueue.enqueue(text)
        return false
      case nil:
        return !boot.isActive
      }
    }
    if let stop { return ToolResult([.text("Loading the image, \(frames) frame(s) in. \(stop)")]) }
    switch boot.phase {
    case .finished:
      return ToolResult([.text("Restored \(url.lastPathComponent) in \(frames) frame(s).")])
    case .failed:
      return ToolResult([.text("N-BASIC never reached its prompt after \(frames) frame(s); nothing was restored.")],
                        isError: true)
    default:
      return ToolResult([.text("Still loading after \(frames) frame(s); raise max_frames.")], isError: true)
    }
  }
}
