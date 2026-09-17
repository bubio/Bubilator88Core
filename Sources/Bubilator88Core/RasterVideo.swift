// RasterVideo.swift — video registers that take effect in the middle of a frame.
//
// vraminfo found that the palette is latched per scan line (「PC88 のパレットの
// 反映は hblank 毎(?)に行われる」), and that switching 200 → 400 lines or
// turning graphics off halfway down the display splits the screen. The
// compositor draws a whole frame at once, so the bus keeps a log of those
// registers with the scan line each change happened on, and the compositor
// draws each band with the values it had.

/// The registers vraminfo saw take effect mid-frame.
///
/// Port 0x30 (40/80 columns, colour/mono text) and port 0x32 (digital/analog)
/// are not here: the page found the first garbles the screen and the second
/// has no visible effect, so both stay per frame.
package struct RasterVideoState: Equatable {
  package var palette: [(b: UInt8, r: UInt8, g: UInt8)]
  package var borderColor: UInt8
  package var analogBackground: (b: UInt8, r: UInt8, g: UInt8)
  package var graphicsDisplayEnabled: Bool
  package var graphicsColorMode: Bool
  package var mode200Line: Bool

  package init(
    palette: [(b: UInt8, r: UInt8, g: UInt8)],
    borderColor: UInt8,
    analogBackground: (b: UInt8, r: UInt8, g: UInt8),
    graphicsDisplayEnabled: Bool,
    graphicsColorMode: Bool,
    mode200Line: Bool
  ) {
    self.palette = palette
    self.borderColor = borderColor
    self.analogBackground = analogBackground
    self.graphicsDisplayEnabled = graphicsDisplayEnabled
    self.graphicsColorMode = graphicsColorMode
    self.mode200Line = mode200Line
  }

  /// 400-line monochrome: port 0x31 selects 400 lines and B/W graphics.
  package var is400LineMode: Bool { !mode200Line && !graphicsColorMode }

  /// This state with the registers that differ between `old` and `new` taken
  /// from `new`: one change replayed on top of a different starting point.
  package func applying(from old: Self, to new: Self) -> Self {
    var result = self
    for i in new.palette.indices where i < old.palette.count && i < result.palette.count
      && old.palette[i] != new.palette[i] {
      result.palette[i] = new.palette[i]
    }
    if old.borderColor != new.borderColor { result.borderColor = new.borderColor }
    if old.analogBackground != new.analogBackground {
      result.analogBackground = new.analogBackground
    }
    if old.graphicsDisplayEnabled != new.graphicsDisplayEnabled {
      result.graphicsDisplayEnabled = new.graphicsDisplayEnabled
    }
    if old.graphicsColorMode != new.graphicsColorMode {
      result.graphicsColorMode = new.graphicsColorMode
    }
    if old.mode200Line != new.mode200Line { result.mode200Line = new.mode200Line }
    return result
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.borderColor == rhs.borderColor,
          lhs.analogBackground == rhs.analogBackground,
          lhs.graphicsDisplayEnabled == rhs.graphicsDisplayEnabled,
          lhs.graphicsColorMode == rhs.graphicsColorMode,
          lhs.mode200Line == rhs.mode200Line,
          lhs.palette.count == rhs.palette.count else { return false }
    for i in lhs.palette.indices where lhs.palette[i] != rhs.palette[i] {
      return false
    }
    return true
  }
}

/// One frame's worth of mid-frame register changes.
package struct RasterFrame {
  /// The registers as the frame started (scan line 0).
  package var start: RasterVideoState
  /// Each change, in order, with the CRTC scan line it was made on and the
  /// registers after it.
  package var changes: [(scanline: Int, state: RasterVideoState)] = []
  /// First line of vertical blanking in this frame, in CRTC lines.
  package var blankingStart: Int = 0

  package init(start: RasterVideoState) {
    self.start = start
  }

  /// The registers down the picture, as bands of output rows (0..<400).
  ///
  /// A change during the display takes effect from the next line. A change
  /// during vertical blanking comes before the next frame's first line, so it
  /// is placed ahead of every change made during the display: a program that
  /// sets the top of the screen in the retrace and changes it partway down —
  /// the way raster effects are written — then shows the frame the hardware
  /// draws every time. Display changes are replayed register by register on
  /// top of that, so what the retrace set survives in the lower bands.
  ///
  /// Returns nil when the display shows one state all the way down: the
  /// frame is then drawn with the registers as they are now, as it always was.
  package func bands() -> [(rows: Range<Int>, state: RasterVideoState)]? {
    let active = blankingStart > 0 ? blankingStart : 400
    // Each change is kept as the difference from the one before it, so the
    // retrace's can be moved ahead of the display's.
    var initial = start
    var displayChanges: [(scanline: Int, old: RasterVideoState, new: RasterVideoState)] = []
    var previous = start
    for change in changes {
      if change.scanline >= active {
        initial = initial.applying(from: previous, to: change.state)
      } else {
        displayChanges.append((change.scanline, previous, change.state))
      }
      previous = change.state
    }
    guard !displayChanges.isEmpty else { return nil }

    var bands: [(rows: Range<Int>, state: RasterVideoState)] = []
    func close(_ rows: Range<Int>, _ state: RasterVideoState) {
      if let last = bands.last, last.state == state {
        bands[bands.count - 1].rows = last.rows.lowerBound..<rows.upperBound
      } else {
        bands.append((rows, state))
      }
    }
    var top = 0
    var current = initial
    for change in displayChanges {
      let y = min(400, (change.scanline + 1) * 400 / active)
      if y > top {
        close(top..<y, current)
        top = y
      }
      current = current.applying(from: change.old, to: change.new)
    }
    if top < 400 {
      close(top..<400, current)
    }
    // One band is the whole frame in one state: leave it to the ordinary path.
    guard bands.count > 1 else { return nil }
    return bands
  }
}
