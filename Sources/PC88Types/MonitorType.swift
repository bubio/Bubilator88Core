/// Which CRT the machine is wired to — DIP SW1 bit 8 ("CRT モード") on real
/// hardware.
///
/// This is *not* a display-appearance setting. The horizontal frequency of the
/// attached monitor decides the CRTC's line time, and therefore the VRTC
/// period, so the choice is visible to software in three ways:
///
///   * frame rate (see `linesPerSecond`) — 62.42Hz vs 55.42Hz for a 25-row screen
///   * port 0x40 read bit 1 (SHG), which software may read directly
///   * GVRAM wait states in V1S/N mode (`MEMORY_WAIT_STATES.md`)
///
/// Only the reset-time CRTC defaults and the line time depend on it; software
/// is free to write any `char_height` it likes with SET PARAMETER.
public enum MonitorType: Int, Sendable, CaseIterable {
  /// Standard 15kHz display. 400-line mode cannot actually be displayed.
  case khz15 = 0
  /// Dedicated 24kHz display, as shipped with the PC-8801-FA.
  case khz24 = 1

  /// Horizontal frequency in Hz.
  ///
  /// The 24kHz figure is XM8's empirically corrected `24860 * 56.423 / 56.5`
  /// (`pc88.cpp:2499`), not the nominal 24,860 — BubiC carries the same
  /// correction. Do not "simplify" it back to the round number.
  public var horizontalFrequency: Double {
    switch self {
    case .khz15: return 15_980.0
    case .khz24: return 24_860.0 * 56.423 / 56.5
    }
  }

  /// CRTC `char_height` at reset (XM8 `pc88_crtc_t::reset(hireso)`).
  public var resetCharLinesPerRow: UInt8 {
    switch self {
    case .khz15: return 8
    case .khz24: return 16
    }
  }

  /// CRTC vertical-retrace rows at reset (XM8 `pc88_crtc_t::reset(hireso)`).
  public var resetVretrace: Int {
    switch self {
    case .khz15: return 7
    case .khz24: return 3
    }
  }
}
