import Foundation
import PC88Types

/// One track on a disc.
package struct CDTrack: Equatable, Sendable {
  /// Track number, 1-99.
  package var number: Int
  /// LBA of the track's first sector (INDEX 01). LBA 0 is the sector at
  /// absolute time 00:02:00, two seconds into the program area.
  package var start: Int
  /// An audio track, rather than data.
  package var isAudio: Bool

  package init(number: Int, start: Int, isAudio: Bool) {
    self.number = number
    self.start = start
    self.isAudio = isAudio
  }
}

/// Raw 2352-byte sectors held somewhere: an image file, or memory in tests.
package protocol CDSectorStore: AnyObject {
  /// Sectors in the store.
  var sectorCount: Int { get }
  /// Copies sector `index` into `buffer`, which holds `CDDisc.sectorBytes`.
  /// Returns false when it could not be read.
  func read(sector index: Int, into buffer: inout [UInt8]) -> Bool
}

/// Sectors read from an image file as they are needed, so a 600MB image
/// costs no memory.
package final class CDFileStore: CDSectorStore {
  private let handle: FileHandle
  package let sectorCount: Int

  package init(url: URL) throws {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let size = try? handle.seekToEnd() else {
      throw CDImageError.unreadable
    }
    self.handle = handle
    self.sectorCount = Int(size) / CDDisc.sectorBytes
  }

  deinit {
    try? handle.close()
  }

  package func read(sector index: Int, into buffer: inout [UInt8]) -> Bool {
    guard index >= 0, index < sectorCount else { return false }
    do {
      try handle.seek(toOffset: UInt64(index * CDDisc.sectorBytes))
      guard let data = try handle.read(upToCount: CDDisc.sectorBytes),
            data.count == CDDisc.sectorBytes else { return false }
      buffer.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
      return true
    } catch {
      return false
    }
  }
}

/// Sectors in memory.
package final class CDMemoryStore: CDSectorStore {
  private let bytes: [UInt8]
  package var sectorCount: Int { bytes.count / CDDisc.sectorBytes }

  package init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  package func read(sector index: Int, into buffer: inout [UInt8]) -> Bool {
    guard index >= 0, index < sectorCount else { return false }
    let base = index * CDDisc.sectorBytes
    for i in 0..<CDDisc.sectorBytes { buffer[i] = bytes[base + i] }
    return true
  }
}

/// A disc: its table of contents, and where each sector is stored.
///
/// Only raw 2352-byte sectors are taken — the whole sector, sync and
/// header included, which is what the drive's 2340-byte read mode needs.
/// A `.cue` sheet may name several files (one per track is common); a
/// `.ccd` sheet goes with one `.img`.
package final class CDDisc {
  /// Bytes in a raw sector (ECMA-130: 12 sync, 4 header, 2048 user data,
  /// 288 EDC/ECC — or 588 stereo 16-bit samples on an audio track).
  package static let sectorBytes = 2352
  /// Sectors per second at normal speed.
  package static let sectorsPerSecond = 75
  /// Absolute time of LBA 0: the program area starts two seconds in.
  package static let leadInFrames = 150

  /// The tracks, in order.
  package let tracks: [CDTrack]
  /// LBA one past the last sector: where the lead-out starts.
  package let leadOut: Int

  /// A run of consecutive sectors: from a store, or silence (a cue
  /// `PREGAP` / `POSTGAP`, which the image does not hold).
  struct Segment {
    var start: Int
    var count: Int
    var store: CDSectorStore?
    var storeSector: Int
  }

  private let segments: [Segment]

  init(tracks: [CDTrack], segments: [Segment]) throws {
    guard !tracks.isEmpty else { throw CDImageError.noTracks }
    self.tracks = tracks
    self.segments = segments
    self.leadOut = segments.last.map { $0.start + $0.count } ?? 0
  }

  /// A disc of one store whose tracks start where `tracks` says.
  package convenience init(store: CDSectorStore, tracks: [CDTrack]) throws {
    try self.init(tracks: tracks,
                  segments: [Segment(start: 0, count: store.sectorCount,
                                     store: store, storeSector: 0)])
  }

  /// Copies the raw sector at `lba` into `buffer` (`sectorBytes` long).
  /// Returns false outside the disc or when the image could not be read.
  package func read(lba: Int, into buffer: inout [UInt8]) -> Bool {
    guard lba >= 0, lba < leadOut,
          let segment = segments.last(where: { $0.start <= lba }) else { return false }
    guard let store = segment.store else {
      for i in 0..<Self.sectorBytes { buffer[i] = 0 }
      return true
    }
    return store.read(sector: segment.storeSector + (lba - segment.start), into: &buffer)
  }

  /// The track `lba` belongs to: the last one starting at or before it.
  /// A sector before the first track counts as the first track.
  package func track(at lba: Int) -> CDTrack {
    tracks.last(where: { $0.start <= lba }) ?? tracks[0]
  }

  /// The track numbered `number`, if the disc has it.
  package func track(number: Int) -> CDTrack? {
    tracks.first(where: { $0.number == number })
  }

  /// Where track `number` ends: the next track's start, or the lead-out.
  package func end(ofTrack number: Int) -> Int {
    tracks.first(where: { $0.number > number })?.start ?? leadOut
  }
}

// MARK: - Opening images

extension CDDisc {
  /// Opens a `.cue` or `.ccd` sheet, or the `.img` / `.bin` next to one.
  package static func open(url: URL) throws -> CDDisc {
    switch url.pathExtension.lowercased() {
    case "cue":
      return try openCue(url: url)
    case "ccd":
      return try openCCD(url: url)
    default:
      let base = url.deletingPathExtension()
      for (ext, opener) in [("cue", openCue), ("ccd", openCCD)] as [(String, (URL) throws -> CDDisc)] {
        for candidate in [ext, ext.uppercased()] {
          let sheet = base.appendingPathExtension(candidate)
          if FileManager.default.fileExists(atPath: sheet.path) {
            return try opener(sheet)
          }
        }
      }
      throw CDImageError.imageFileNotFound(base.lastPathComponent + ".cue")
    }
  }

  /// Sheets are plain text; Japanese ones name their files in Shift_JIS.
  static func readSheet(_ url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url) else { throw CDImageError.unreadable }
    if let text = String(data: data, encoding: .utf8) { return text }
    if let text = String(data: data, encoding: .shiftJIS) { return text }
    throw CDImageError.unreadable
  }

  static func openCue(url: URL) throws -> CDDisc {
    let directory = url.deletingLastPathComponent()
    let sheet = try CueSheet(try readSheet(url))
    var stores: [String: CDSectorStore] = [:]
    for name in sheet.fileNames where stores[name] == nil {
      let fileURL = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw CDImageError.imageFileNotFound(name)
      }
      stores[name] = try CDFileStore(url: fileURL)
    }
    return try sheet.disc(stores: stores)
  }

  static func openCCD(url: URL) throws -> CDDisc {
    let base = url.deletingPathExtension()
    guard let image = ["img", "IMG"].lazy
      .map({ base.appendingPathExtension($0) })
      .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      throw CDImageError.imageFileNotFound(base.lastPathComponent + ".img")
    }
    let store = try CDFileStore(url: image)
    let tracks = try parseCCD(try readSheet(url))
    return try CDDisc(store: store, tracks: tracks)
  }
}

// MARK: - Cue sheets

/// A parsed `.cue` sheet, before its files are opened.
struct CueSheet {
  struct Track {
    var number: Int
    var isAudio: Bool
    /// INDEX 01, in sectors from the start of its file.
    var offset: Int?
    /// Silence before the track that the file does not hold (PREGAP).
    var pregap = 0
    /// Silence after the track that the file does not hold (POSTGAP).
    var postgap = 0
  }

  struct File {
    var name: String
    var tracks: [Track] = []
  }

  var files: [File] = []

  var fileNames: [String] { files.map(\.name) }

  init(_ text: String) throws {
    for rawLine in text.components(separatedBy: .newlines) {
      let words = Self.words(rawLine)
      guard let keyword = words.first?.uppercased() else { continue }
      switch keyword {
      case "FILE" where words.count >= 2:
        files.append(File(name: words[1]))
      case "TRACK" where words.count >= 3:
        guard !files.isEmpty, let number = Int(words[1]) else { continue }
        let mode = words[2].uppercased()
        guard mode == "AUDIO" || mode == "MODE1/2352" || mode == "MODE2/2352" else {
          throw CDImageError.unsupportedTrackMode(words[2])
        }
        files[files.count - 1].tracks.append(Track(number: number, isAudio: mode == "AUDIO"))
      case "INDEX" where words.count >= 3:
        guard Int(words[1]) == 1, let frames = Self.frames(words[2]) else { continue }
        Self.modifyLastTrack(&files) { $0.offset = frames }
      case "PREGAP" where words.count >= 2:
        guard let frames = Self.frames(words[1]) else { continue }
        Self.modifyLastTrack(&files) { $0.pregap = frames }
      case "POSTGAP" where words.count >= 2:
        guard let frames = Self.frames(words[1]) else { continue }
        Self.modifyLastTrack(&files) { $0.postgap = frames }
      default:
        continue
      }
    }
    guard files.contains(where: { !$0.tracks.isEmpty }) else { throw CDImageError.noTracks }
  }

  /// Lays the files end to end, with each gap the sheet asks for, and
  /// numbers the sectors from LBA 0.
  func disc(stores: [String: CDSectorStore]) throws -> CDDisc {
    var tracks: [CDTrack] = []
    var segments: [CDDisc.Segment] = []
    var lba = 0
    func data(_ store: CDSectorStore, from first: Int, to end: Int) {
      guard end > first else { return }
      segments.append(.init(start: lba, count: end - first, store: store, storeSector: first))
      lba += end - first
    }
    func silence(_ count: Int) {
      guard count > 0 else { return }
      segments.append(.init(start: lba, count: count, store: nil, storeSector: 0))
      lba += count
    }
    for file in files {
      guard let store = stores[file.name] else { throw CDImageError.imageFileNotFound(file.name) }
      var position = 0
      for track in file.tracks {
        let offset = min(track.offset ?? position, store.sectorCount)
        if track.pregap > 0 {
          data(store, from: position, to: offset)
          position = offset
          silence(track.pregap)
        }
        tracks.append(CDTrack(number: track.number,
                              start: lba + (offset - position),
                              isAudio: track.isAudio))
        if track.postgap > 0 {
          let end = file.tracks.first(where: { $0.number > track.number })?.offset
            ?? store.sectorCount
          data(store, from: position, to: end)
          position = end
          silence(track.postgap)
        }
      }
      data(store, from: position, to: store.sectorCount)
    }
    return try CDDisc(tracks: tracks, segments: segments)
  }

  /// Splits a line into words, keeping a quoted name whole.
  static func words(_ line: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quoted = false
    for ch in line {
      if ch == "\"" {
        quoted.toggle()
      } else if !quoted && (ch == " " || ch == "\t") {
        if !current.isEmpty { words.append(current); current = "" }
      } else {
        current.append(ch)
      }
    }
    if !current.isEmpty { words.append(current) }
    return words
  }

  /// `mm:ss:ff` in sectors.
  static func frames(_ time: String) -> Int? {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return (parts[0] * 60 + parts[1]) * CDDisc.sectorsPerSecond + parts[2]
  }

  private static func modifyLastTrack(_ files: inout [File], _ change: (inout Track) -> Void) {
    guard let f = files.indices.last, let t = files[f].tracks.indices.last else { return }
    change(&files[f].tracks[t])
  }
}

// MARK: - CloneCD sheets

extension CDDisc {
  /// The tracks of a CloneCD `.ccd` sheet: its `[Entry n]` sections whose
  /// `Point` is a track number (1-99), each starting at `PLBA` — or at
  /// `PMin:PSec:PFrame` less the two-second lead-in when `PLBA` is absent.
  /// Control bit 2 marks a data track.
  static func parseCCD(_ text: String) throws -> [CDTrack] {
    var entries: [[String: String]] = []
    var current: [String: String]?
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        if let current { entries.append(current) }
        current = line.lowercased().hasPrefix("[entry") ? [:] : nil
      } else if let eq = line.firstIndex(of: "="), current != nil {
        let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        current![key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      }
    }
    if let current { entries.append(current) }

    func number(_ value: String?) -> Int? {
      guard let value else { return nil }
      if value.lowercased().hasPrefix("0x") { return Int(value.dropFirst(2), radix: 16) }
      return Int(value)
    }
    var tracks: [CDTrack] = []
    for entry in entries {
      guard let point = number(entry["point"]), (1...99).contains(point),
            tracks.first(where: { $0.number == point }) == nil else { continue }
      let start: Int
      if let plba = number(entry["plba"]) {
        start = plba
      } else if let m = number(entry["pmin"]), let s = number(entry["psec"]),
                let f = number(entry["pframe"]) {
        start = (m * 60 + s) * sectorsPerSecond + f - leadInFrames
      } else {
        continue
      }
      let control = number(entry["control"]) ?? 0
      tracks.append(CDTrack(number: point, start: start, isAudio: control & 0x04 == 0))
    }
    guard !tracks.isEmpty else { throw CDImageError.noTracks }
    return tracks.sorted { $0.number < $1.number }
  }
}
