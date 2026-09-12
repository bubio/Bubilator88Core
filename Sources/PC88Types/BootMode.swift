/// A standard BASIC mode, expanded into a DIP switch 1 / DIP switch 2 pair.
///
/// What `PC88.bootMode` / `PC88.setBootMode(_:)` and b88script's `boot` verb
/// deal in. The raw value is the name b88script uses.
public enum BootMode: String, Equatable, Sendable, CaseIterable {
  /// N88-BASIC, V2 mode. What most PC-8801 software from the mkII SR on
  /// expects.
  case n88v2   = "n88-v2"
  /// N88-BASIC, V1 high-speed mode.
  case n88v1h  = "n88-v1h"
  /// N88-BASIC, V1 standard-speed mode.
  case n88v1s  = "n88-v1s"
  /// N-BASIC, for the original PC-8001-compatible software.
  case nbasic  = "n-basic"

  /// DIP switch 1 for this mode, in the layout of `PC88.dipSw1`.
  public var dipSw1: UInt8 {
    switch self {
    case .n88v2, .n88v1h, .n88v1s: return 0xC3
    case .nbasic:                  return 0xC2
    }
  }

  /// DIP switch 2 for this mode, in the layout of `PC88.dipSw2`, with the
  /// boot strap (bit 3) clear.
  ///
  /// Port 0x31's DIP bits. Bit 7 is SW4-S2 (0 = V2, 1 = V1) and bit 6 is
  /// SW3-S0 (0 = standard, 1 = high speed); BubiC derives both from the boot
  /// mode in `pc88.cpp` `read_io8` for port 0x31, and N-BASIC comes out as
  /// V1 + standard there — the same value as V1S.
  public var dipSw2: UInt8 {
    switch self {
    case .n88v2:  return 0x71
    case .n88v1h: return 0xF1
    case .n88v1s: return 0xB1
    case .nbasic: return 0xB1
    }
  }
}
