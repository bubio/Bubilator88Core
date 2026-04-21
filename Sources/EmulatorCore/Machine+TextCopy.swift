extension Machine {

    /// Copy the current text screen as a Unicode string.
    ///
    /// Each row's trailing spaces are trimmed and rows are separated by `\n`.
    /// ASCII (0x20-0x7E) passes through. Half-width katakana (0xA1-0xDF) is
    /// mapped to the Unicode half-width katakana block (U+FF61-U+FF9F).
    /// Cells whose attribute marks them as graphic (bit 4) are treated as
    /// blanks, matching X88000M's `DoClipboardCopyText()`.
    public func copyTextAsUnicode() -> String {
        let chars = bus.readTextVRAM()
        let attrs = bus.readTextAttributes()
        let cols = Int(crtc.charsPerLine)
        let rows = Int(crtc.linesPerScreen)
        guard cols > 0, rows > 0, chars.count >= cols * rows else { return "" }

        var result = ""
        result.reserveCapacity(rows * (cols + 1))

        for row in 0..<rows {
            var line = ""
            var pendingSpaces = 0
            for col in 0..<cols {
                let i = row * cols + col
                let ch = chars[i]
                let attr = i < attrs.count ? attrs[i] : 0xE0
                let isGraphic = (attr & 0x10) != 0

                let scalar: Unicode.Scalar?
                if isGraphic || ch < 0x20 || (ch > 0x7E && ch < 0xA1) || ch > 0xDF {
                    scalar = nil
                } else if ch <= 0x7E {
                    scalar = Unicode.Scalar(UInt32(ch))
                } else {
                    // 0xA1-0xDF → U+FF61-U+FF9F
                    scalar = Unicode.Scalar(UInt32(ch) - 0xA1 + 0xFF61)
                }

                if let s = scalar {
                    if pendingSpaces > 0 {
                        line.append(String(repeating: " ", count: pendingSpaces))
                        pendingSpaces = 0
                    }
                    line.unicodeScalars.append(s)
                } else {
                    pendingSpaces += 1
                }
            }
            result += line
            result += "\n"
        }
        return result
    }
}
