import Testing
import Foundation
@testable import EmulatorCore

@Suite("MemoryDump Tests")
struct MemoryDumpTests {

    /// Create a unique temporary directory for this test's output, so parallel
    /// tests never step on each other.
    private func makeTempDir(label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BubilatorMemoryDumpTests")
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    @Test("Dumps all standard regions with correct sizes")
    func dumpStandardRegions() throws {
        let machine = Machine()
        let dir = makeTempDir(label: "standard")
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = try MemoryDump.write(machine: machine, to: dir)

        // Expected files and sizes
        let expected: [(String, Int)] = [
            ("main.bin",    65536),
            ("gvram_b.bin", 16384),
            ("gvram_r.bin", 16384),
            ("gvram_g.bin", 16384),
            ("tvram.bin",    4096),
            ("subram.bin",  32768),
        ]
        for (name, size) in expected {
            let url = dir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(name)")
            let data = try Data(contentsOf: url)
            #expect(data.count == size, "\(name) size \(data.count) != \(size)")
        }

        // info.txt must exist and contain standard keys
        let info = try String(contentsOf: dir.appendingPathComponent("info.txt"), encoding: .utf8)
        #expect(info.contains("emulator=Bubilator88"))
        #expect(info.contains("format_version=1"))
        #expect(info.contains("timestamp="))
        #expect(info.contains("total_tstates="))
        #expect(info.contains("ext_ram=none"))

        // Returned URLs should include info.txt + all binary files (7 total)
        #expect(urls.count == expected.count + 1)
    }

    @Test("Caller metadata is written into info.txt (sorted keys)")
    func dumpWithMetadata() throws {
        let machine = Machine()
        let dir = makeTempDir(label: "metadata")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try MemoryDump.write(
            machine: machine,
            to: dir,
            metadata: [
                "disk0": "Ys.d88",
                "boot_mode": "N88-BASIC V2",
            ]
        )

        let info = try String(contentsOf: dir.appendingPathComponent("info.txt"), encoding: .utf8)
        #expect(info.contains("boot_mode=N88-BASIC V2"))
        #expect(info.contains("disk0=Ys.d88"))
        // Sorted alphabetically → boot_mode appears before disk0
        let bootRange = info.range(of: "boot_mode=")!
        let diskRange = info.range(of: "disk0=")!
        #expect(bootRange.lowerBound < diskRange.lowerBound)
    }

    @Test("extRAM files are only written when installed")
    func dumpWithoutExtRAM() throws {
        let machine = Machine()
        let dir = makeTempDir(label: "no_ext")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try MemoryDump.write(machine: machine, to: dir)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!contents.contains(where: { $0.hasPrefix("extram_") }))
    }

    @Test("extRAM is dumped when installed (default 1 card × 4 banks)")
    func dumpWithExtRAM() throws {
        let machine = Machine()
        machine.installExtRAM()
        let dir = makeTempDir(label: "ext")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try MemoryDump.write(machine: machine, to: dir)

        // Default installExtRAM() = 1 card × 4 banks = 4 files
        for b in 0..<4 {
            let url = dir.appendingPathComponent("extram_c0_b\(b).bin")
            #expect(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            #expect(data.count == 0x8000)
        }

        let info = try String(contentsOf: dir.appendingPathComponent("info.txt"), encoding: .utf8)
        #expect(info.contains("ext_ram=installed"))
    }

    @Test("Content written matches source memory bytes")
    func contentMatchesSource() throws {
        let machine = Machine()
        // Poison a few bytes to confirm they show up in the dump.
        machine.bus.mainRAM[0x0000] = 0xAB
        machine.bus.mainRAM[0xFFFF] = 0xCD
        machine.bus.gvram[1][0x1234] = 0xEF

        let dir = makeTempDir(label: "content")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try MemoryDump.write(machine: machine, to: dir)

        let main = try Data(contentsOf: dir.appendingPathComponent("main.bin"))
        #expect(main[0x0000] == 0xAB)
        #expect(main[0xFFFF] == 0xCD)

        let red = try Data(contentsOf: dir.appendingPathComponent("gvram_r.bin"))
        #expect(red[0x1234] == 0xEF)
    }

    @Test("Creates directory if it does not exist")
    func createsMissingDirectory() throws {
        let dir = makeTempDir(label: "missing")
            .appendingPathComponent("nested").appendingPathComponent("deeper")
        defer {
            try? FileManager.default.removeItem(
                at: dir.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        let machine = Machine()
        _ = try MemoryDump.write(machine: machine, to: dir)

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("main.bin").path
        ))
    }
}
