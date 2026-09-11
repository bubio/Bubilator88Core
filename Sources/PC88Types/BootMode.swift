/// Boot mode, expanded into a DIPSW1 / DIPSW2 pair: what `PC88.bootMode` /
/// `setBootMode` and b88script's `boot` verb deal in. The values follow
/// docs/develop/BOOTTESTER.md and docs/develop/PERSISTENCE.md.
public enum BootMode: String, Equatable, Sendable, CaseIterable {
  case n88v2   = "n88-v2"
  case n88v1h  = "n88-v1h"
  case n88v1s  = "n88-v1s"
  case nbasic  = "n-basic"

  public var dipSw1: UInt8 {
    switch self {
    case .n88v2, .n88v1h, .n88v1s: return 0xC3
    case .nbasic:                  return 0xC2
    }
  }

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
