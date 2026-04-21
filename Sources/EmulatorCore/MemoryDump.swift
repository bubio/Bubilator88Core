import Foundation

/// Cross-emulator memory dump writer.
///
/// Serializes all machine-visible RAM regions as raw binary files inside a
/// directory, along with a human-readable `info.txt` metadata file. The
/// format is intentionally trivial so other PC-8801 emulators (BubiC,
/// QUASI88, …) can implement the same layout and enable byte-level `diff -r`
/// comparison for graphics/timing bug investigations.
///
/// See `docs/MEMORY_DUMP_FORMAT.md` for the directory layout specification.
public enum MemoryDump {

    public struct Error: Swift.Error, CustomStringConvertible {
        public let description: String
    }

    /// Write all machine memory regions as raw binary files into `directory`.
    ///
    /// The directory is created (with intermediates) if it does not exist.
    /// Existing files at the target paths are overwritten. Additional
    /// `metadata` key/value pairs are appended to `info.txt` after the
    /// standard emulator/timestamp lines.
    ///
    /// Returns the URLs of every file written (for status/log display).
    @discardableResult
    public static func write(
        machine: Machine,
        to directory: URL,
        metadata: [String: String] = [:]
    ) throws -> [URL] {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw Error(description: "Failed to create dump directory \(directory.path): \(error)")
        }

        var written: [URL] = []

        // Helper: write a region as raw bytes.
        func writeBytes(_ bytes: [UInt8], name: String) throws {
            let url = directory.appendingPathComponent(name)
            do {
                try Data(bytes).write(to: url, options: .atomic)
                written.append(url)
            } catch {
                throw Error(description: "Failed to write \(name): \(error)")
            }
        }

        // Main RAM (64KB)
        try writeBytes(machine.bus.mainRAM, name: "main.bin")

        // GVRAM 3 planes (16KB each)
        try writeBytes(machine.bus.gvram[0], name: "gvram_b.bin")
        try writeBytes(machine.bus.gvram[1], name: "gvram_r.bin")
        try writeBytes(machine.bus.gvram[2], name: "gvram_g.bin")

        // High-speed text VRAM (4KB)
        try writeBytes(machine.bus.tvram, name: "tvram.bin")

        // Sub-CPU 32KB (DISK.ROM + backing RAM)
        try writeBytes(machine.subSystem.subBus.romram, name: "subram.bin")

        // Extended RAM (only if installed)
        if let ext = machine.bus.extRAM {
            for (c, card) in ext.enumerated() {
                for (b, bank) in card.enumerated() {
                    try writeBytes(bank, name: "extram_c\(c)_b\(b).bin")
                }
            }
        }

        // info.txt — standard keys + caller-provided metadata
        var lines: [String] = []
        lines.append("emulator=Bubilator88")
        lines.append("format_version=1")
        lines.append("timestamp=\(isoTimestamp())")
        lines.append("total_tstates=\(machine.totalTStates)")
        lines.append("clock=\(machine.bus.cpuClock8MHz ? "8MHz" : "4MHz")")
        lines.append("ext_ram=\(machine.bus.extRAM != nil ? "installed" : "none")")

        // Sort caller metadata keys for deterministic output.
        for key in metadata.keys.sorted() {
            let value = metadata[key] ?? ""
            lines.append("\(key)=\(value)")
        }

        let infoURL = directory.appendingPathComponent("info.txt")
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: infoURL, atomically: true, encoding: .utf8)
            written.append(infoURL)
        } catch {
            throw Error(description: "Failed to write info.txt: \(error)")
        }

        return written
    }

    /// ISO 8601 timestamp in UTC, second precision (e.g. "2026-04-09T20:15:00Z").
    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
