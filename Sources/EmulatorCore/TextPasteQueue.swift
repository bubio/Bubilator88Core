import Foundation
import Peripherals

/// Queue that converts a Unicode string into a stream of PC-8801 keyboard
/// matrix press/release events.
///
/// Ported from X88000M's `DoClipboardPasteText()` / `AddIMEChar()` (X88000.cpp).
/// Encoding of the 16-bit queue entry (matches X88000M):
///
/// - bits 0-2: key bit (0-7)
/// - bits 4-7: key row (0-F)
/// - bit 8   : SHIFT modifier (Bubilator88: row 8 / bit 6)
/// - bit 12  : KANA  modifier (Bubilator88: row 8 / bit 5)
///
/// Entry 0x0000 is a "no-op / blank" placeholder in the original table.
public final class TextPasteQueue {

    public struct KeyAction: Sendable {
        public let row: Int
        public let bit: Int
        public let down: Bool
    }

    private static let shiftKey = Keyboard.shift
    private static let kanaKey = Keyboard.kana

    /// Ticks per queued character (≈ 200ms @ 60fps).
    private static let ticksPerChar = 12
    /// Press modifier (Shift/Kana) one tick before the main key so the BIOS
    /// can latch the modifier state before the letter appears. Without this
    /// gap, simultaneous shift+letter pressed on the same tick is sometimes
    /// sampled as lowercase by the keyboard scanner.
    private static let modifierDownTick = 2
    private static let keyDownTick = 3
    private static let keyUpTick = 9
    /// Release the modifier one tick after the main key so the letter has
    /// finished releasing before Shift goes up.
    private static let modifierUpTick = 10

    private var queue: [UInt16] = []
    private var tickCount = 0
    /// True while any part of the current character (main key and/or its
    /// modifier) is pressed. Used to decide whether `cancel(emit:)` needs
    /// to inject releases.
    private var pressed = false

    public init() {}

    public var isEmpty: Bool { queue.isEmpty }

    /// Clear all pending characters and release any currently-held keys via
    /// `emit`. Must be called when cancelling a paste (e.g. user hit ESC)
    /// so the emulator doesn't end up with a stuck-down key in its matrix.
    public func cancel(emit: (KeyAction) -> Void) {
        if pressed, let code = queue.first, code != 0x0000 {
            let row = (Int(code) >> 4) & 0x0F
            let bit = Int(code) & 0x07
            let shift = (code & 0x0100) != 0
            let kana = (code & 0x1000) != 0
            // Release the main key first, then modifiers (matches tick() order).
            emit(KeyAction(row: row, bit: bit, down: false))
            if kana { emit(KeyAction(row: Self.kanaKey.row, bit: Self.kanaKey.bit, down: false)) }
            if shift { emit(KeyAction(row: Self.shiftKey.row, bit: Self.shiftKey.bit, down: false)) }
        }
        queue.removeAll()
        tickCount = 0
        pressed = false
    }

    /// Convert a user-facing string to queue entries and append them. If the
    /// queue was previously idle, state (tick counter, pressed flag) is reset
    /// so the first character starts cleanly at tick 0.
    public func enqueue(_ text: String) {
        if queue.isEmpty {
            tickCount = 0
            pressed = false
        }
        guard let sjis = text.data(using: .shiftJIS) else { return }
        let bytes = Array(sjis)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if Self.isSJISLeadByte(b), i + 1 < bytes.count {
                // Multi-byte (kanji / zenkaku): not supported. Skip pair.
                i += 2
                continue
            }
            if b >= 0x20 && b <= 0x7E {
                queue.append(Self.table[Int(b) - 0x20])
            } else if b >= 0xA1 && b <= 0xDF {
                queue.append(Self.table[Int(b) - 0x40])
            } else if b == 0x0A {
                queue.append(Self.table[0xA0])  // Return
            } else if b == 0x09 {
                queue.append(Self.table[0xA1])  // Tab
            }
            // 0x0D (CR) is dropped; 0x0A (LF) alone triggers Return.
            i += 1
        }
    }

    /// Drive the queue by one logical frame. Emits key actions via `emit`.
    public func tick(emit: (KeyAction) -> Void) {
        guard let code = queue.first else { return }
        if code == 0x0000 {
            // Skip blank slots (e.g. unmapped lower-alpha 0x7F or kana 0xA0).
            queue.removeFirst()
            tickCount = 0
            return
        }

        let row = (Int(code) >> 4) & 0x0F
        let bit = Int(code) & 0x07
        let shift = (code & 0x0100) != 0
        let kana = (code & 0x1000) != 0

        switch tickCount {
        case Self.modifierDownTick:
            if shift { emit(KeyAction(row: Self.shiftKey.row, bit: Self.shiftKey.bit, down: true)) }
            if kana { emit(KeyAction(row: Self.kanaKey.row, bit: Self.kanaKey.bit, down: true)) }
            if shift || kana { pressed = true }
        case Self.keyDownTick:
            emit(KeyAction(row: row, bit: bit, down: true))
            pressed = true
        case Self.keyUpTick where pressed:
            emit(KeyAction(row: row, bit: bit, down: false))
        case Self.modifierUpTick where pressed:
            if kana { emit(KeyAction(row: Self.kanaKey.row, bit: Self.kanaKey.bit, down: false)) }
            if shift { emit(KeyAction(row: Self.shiftKey.row, bit: Self.shiftKey.bit, down: false)) }
            pressed = false
        default:
            break
        }

        tickCount += 1
        if tickCount >= Self.ticksPerChar {
            queue.removeFirst()
            tickCount = 0
        }
    }

    private static func isSJISLeadByte(_ b: UInt8) -> Bool {
        return (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)
    }

    // MARK: - IME key table (ported verbatim from X88000M's m_awIMECharTable)

    static let table: [UInt16] = [
        // 0x20-0x2F : marks
        0x0096, 0x0161, 0x0162, 0x0163, 0x0164, 0x0165, 0x0166, 0x0167,
        0x0170, 0x0171, 0x0172, 0x0173, 0x0074, 0x0057, 0x0075, 0x0076,
        // 0x30-0x3F : numeric
        0x0060, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
        0x0070, 0x0071, 0x0072, 0x0073, 0x0174, 0x0157, 0x0175, 0x0176,
        // 0x40-0x5F : upper alpha / symbols
        0x0020, 0x0121, 0x0122, 0x0123, 0x0124, 0x0125, 0x0126, 0x0127,
        0x0130, 0x0131, 0x0132, 0x0133, 0x0134, 0x0135, 0x0136, 0x0137,
        0x0140, 0x0141, 0x0142, 0x0143, 0x0144, 0x0145, 0x0146, 0x0147,
        0x0150, 0x0151, 0x0152, 0x0053, 0x0054, 0x0055, 0x0056, 0x0177,
        // 0x60-0x7F : lower alpha / symbols
        0x0120, 0x0021, 0x0022, 0x0023, 0x0024, 0x0025, 0x0026, 0x0027,
        0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
        0x0040, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
        0x0050, 0x0051, 0x0052, 0x0153, 0x0154, 0x0155, 0x0156, 0x0000,
        // Kana 0xA0-0xBF (accessed via btIME-0x40; 0xA0 slot is blank)
        0x0000, 0x1175, 0x1153, 0x1155, 0x1174, 0x1176, 0x1160, 0x1163,
        0x1125, 0x1164, 0x1165, 0x1166, 0x1167, 0x1170, 0x1171, 0x1152,
        0x1054, 0x1063, 0x1025, 0x1064, 0x1065, 0x1066, 0x1044, 0x1027,
        0x1030, 0x1072, 0x1022, 0x1050, 0x1024, 0x1042, 0x1040, 0x1023,
        // Kana 0xC0-0xDF
        0x1041, 0x1021, 0x1052, 0x1047, 0x1043, 0x1045, 0x1031, 0x1061,
        0x1074, 0x1033, 0x1026, 0x1046, 0x1062, 0x1056, 0x1057, 0x1032,
        0x1036, 0x1055, 0x1076, 0x1035, 0x1067, 0x1070, 0x1071, 0x1037,
        0x1034, 0x1075, 0x1073, 0x1077, 0x1060, 0x1051, 0x1020, 0x1053,
        // 0xA0 : Return
        0x0017,
        // 0xA1 : Tab
        0x00A0,
    ]
}
