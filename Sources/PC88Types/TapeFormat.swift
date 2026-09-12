/// The format of a cassette image, as detected by `PC88.mountTape(data:)`.
public enum TapeFormat: Sendable {
  /// T88, recognised by its `"PC-8801 Tape Image(T88)"` signature.
  case t88
  /// Raw CMT byte stream.
  case cmt
}
