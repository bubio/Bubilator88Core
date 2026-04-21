import Foundation

/// Render a sequence of ``InstructionTraceEntry`` values as
/// newline-delimited JSON (JSONL). The format is **intentionally
/// stable and minimal** so equivalent logging from other emulators
/// (BubiC, QUASI88) can produce byte-identical files that `diff`
/// cleanly side-by-side.
///
/// Example line:
/// ```
/// {"seq":42,"pc":"1000","af":"0000","bc":"0000","de":"0000","hl":"0000","ix":"0000","iy":"0000","sp":"FFFF","af2":"0000","bc2":"0000","de2":"0000","hl2":"0000","i":"00","r":"00"}
/// ```
///
/// - All hex values are emitted without the `0x` prefix and with a
///   fixed width (4 digits for word registers, 2 digits for I/R).
/// - `seq` starts at 0 for the oldest entry so index-based alignment
///   works when two emulators produce slightly different total counts.
public enum InstructionTraceJSONL {
    public static func render(_ entries: [InstructionTraceEntry]) -> String {
        var out = ""
        out.reserveCapacity(entries.count * 160)
        for (i, e) in entries.enumerated() {
            out += line(seq: i, entry: e)
            out += "\n"
        }
        return out
    }

    public static func line(seq: Int, entry e: InstructionTraceEntry) -> String {
        String(
            format: #"{"seq":%d,"pc":"%04X","af":"%04X","bc":"%04X","de":"%04X","hl":"%04X","ix":"%04X","iy":"%04X","sp":"%04X","af2":"%04X","bc2":"%04X","de2":"%04X","hl2":"%04X","i":"%02X","r":"%02X"}"#,
            seq,
            e.pc, e.af, e.bc, e.de, e.hl,
            e.ix, e.iy, e.sp,
            e.af2, e.bc2, e.de2, e.hl2,
            e.i, e.r
        )
    }
}
