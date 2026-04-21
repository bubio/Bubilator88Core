import Foundation

/// Render a sequence of ``PIOFlowEntry`` values as newline-delimited
/// JSON (JSONL). The format is **intentionally stable and minimal**
/// so equivalent logging from other emulators (BubiC, QUASI88) can
/// produce byte-identical files that `diff` cleanly side-by-side.
///
/// Example line:
/// ```
/// {"seq":42,"mainPC":"1C5A","subPC":"6830","side":"sub","port":"B","op":"W","val":"3B"}
/// ```
///
/// - All hex values are emitted without the `0x` prefix and with a
///   fixed width (4 digits for PCs, 2 digits for value). This keeps
///   diff output aligned.
/// - `seq` starts at 0 for the oldest entry so index-based alignment
///   works when the two emulators produce slightly different total
///   counts.
public enum PIOFlowJSONL {
    public static func render(_ entries: [PIOFlowEntry]) -> String {
        var out = ""
        out.reserveCapacity(entries.count * 80)
        for (i, e) in entries.enumerated() {
            out += line(seq: i, entry: e)
            out += "\n"
        }
        return out
    }

    public static func line(seq: Int, entry e: PIOFlowEntry) -> String {
        String(
            format: #"{"seq":%d,"mainPC":"%04X","subPC":"%04X","side":"%@","port":"%@","op":"%@","val":"%02X"}"#,
            seq,
            e.mainPC,
            e.subPC,
            e.side.rawValue,
            e.port.rawValue,
            e.isWrite ? "W" : "R",
            e.value
        )
    }
}

/// A single PIO8255 access event recorded in chronological order
/// along with the CPU context it happened in. Used to reconstruct
/// the cross-CPU data flow for games whose load routines depend on
/// specific hand-shake orderings (RIGLAS, Wizardry, etc.).
public struct PIOFlowEntry: Sendable, Hashable {

    public enum Side: String, Sendable, Hashable {
        case main
        case sub
    }

    public enum Port: String, Sendable, Hashable {
        case a = "A"
        case b = "B"
        case c = "C"
        /// Control register (port 0xFF). Used for PIO mode set and
        /// bit-set/reset (BSR) operations. These don't normally carry
        /// "data" but they drive port C state changes, so we capture
        /// them in the same stream for cross-emulator comparison.
        case control = "FF"
    }

    /// Main-CPU PC at the moment the access was serviced. For
    /// main-CPU-originated accesses this is the reading/writing
    /// instruction. For sub-CPU accesses it's whatever the main
    /// CPU happened to be running at that moment (still useful
    /// for correlating frames).
    public let mainPC: UInt16

    /// Sub-CPU PC, mirror-image of `mainPC`.
    public let subPC: UInt16

    public let side: Side
    public let port: Port
    public let isWrite: Bool
    public let value: UInt8

    public init(
        mainPC: UInt16,
        subPC: UInt16,
        side: Side,
        port: Port,
        isWrite: Bool,
        value: UInt8
    ) {
        self.mainPC = mainPC
        self.subPC = subPC
        self.side = side
        self.port = port
        self.isWrite = isWrite
        self.value = value
    }
}
