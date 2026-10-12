/// Why a CD image could not be opened (`PC88.mountCD(url:)`).
public enum CDImageError: Error, Equatable, Sendable {
  /// The sheet or an image file could not be read.
  case unreadable
  /// A file the sheet names, or the image next to a `.ccd`, is missing.
  case imageFileNotFound(String)
  /// A track is not stored as raw 2352-byte sectors; the string is its
  /// mode as the sheet spells it (`MODE1/2048`, …).
  case unsupportedTrackMode(String)
  /// The sheet lists no tracks.
  case noTracks
}
