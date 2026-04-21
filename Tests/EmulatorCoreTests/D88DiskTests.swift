import Testing
@testable import EmulatorCore

@Suite("D88Disk Tests")
struct D88DiskTests {

    @Test func parseMinimalD88() {
        // Create a minimal valid D88 image (header only, no tracks)
        var data = Array(repeating: UInt8(0), count: 688)

        // Disk name: "TEST"
        data[0] = 0x54  // T
        data[1] = 0x45  // E
        data[2] = 0x53  // S
        data[3] = 0x54  // T

        // Write protect: none
        data[0x1A] = 0x00

        // Disk type: 2D
        data[0x1B] = 0x00

        // Disk size: 688 (header only)
        data[0x1C] = 0xB0
        data[0x1D] = 0x02
        data[0x1E] = 0x00
        data[0x1F] = 0x00

        let disk = D88Disk.parse(data: data)
        #expect(disk != nil)
        #expect(disk?.name == "TEST")
        #expect(disk?.writeProtected == false)
        #expect(disk?.diskType == .twoD)
    }

    @Test func parseWithSectors() {
        // Create D88 with one track, one sector
        var data = Array(repeating: UInt8(0), count: 688 + 16 + 256)

        // Header
        data[0] = 0x44  // D
        data[0x1A] = 0x00
        data[0x1B] = 0x00  // 2D

        // Disk size
        let totalSize = UInt32(data.count)
        data[0x1C] = UInt8(totalSize & 0xFF)
        data[0x1D] = UInt8((totalSize >> 8) & 0xFF)

        // Track 0 offset (at byte 688)
        let trackOffset: UInt32 = 688
        data[0x20] = UInt8(trackOffset & 0xFF)
        data[0x21] = UInt8((trackOffset >> 8) & 0xFF)

        // Sector header at offset 688
        let sectorStart = 688
        data[sectorStart + 0] = 0    // C
        data[sectorStart + 1] = 0    // H
        data[sectorStart + 2] = 1    // R (sector 1)
        data[sectorStart + 3] = 1    // N (256 bytes)
        data[sectorStart + 4] = 1    // sector count (low)
        data[sectorStart + 5] = 0    // sector count (high)
        data[sectorStart + 6] = 0    // density
        data[sectorStart + 7] = 0    // not deleted
        data[sectorStart + 8] = 0    // status OK

        // Data size (256 bytes)
        data[sectorStart + 14] = 0x00
        data[sectorStart + 15] = 0x01  // 256 in LE

        // Sector data: fill with 0xAA
        for i in 0..<256 {
            data[sectorStart + 16 + i] = 0xAA
        }

        let disk = D88Disk.parse(data: data)
        #expect(disk != nil)
        #expect(disk!.tracks[0].count == 1)

        let sector = disk!.tracks[0][0]
        #expect(sector.c == 0)
        #expect(sector.h == 0)
        #expect(sector.r == 1)
        #expect(sector.n == 1)
        #expect(sector.data.count == 256)
        #expect(sector.data[0] == 0xAA)
    }

    @Test func findSector() {
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = 0
        sector.h = 0
        sector.r = 1
        sector.n = 1
        sector.data = Array(repeating: 0x55, count: 256)
        disk.tracks[0] = [sector]

        let found = disk.findSector(track: 0, c: 0, h: 0, r: 1)
        #expect(found != nil)
        #expect(found?.data[0] == 0x55)

        let notFound = disk.findSector(track: 0, c: 0, h: 0, r: 2)
        #expect(notFound == nil)
    }

    @Test func writeSector() {
        var disk = D88Disk()
        var sector = D88Disk.Sector()
        sector.c = 0
        sector.h = 0
        sector.r = 1
        sector.n = 1
        sector.data = Array(repeating: 0x00, count: 256)
        disk.tracks[0] = [sector]

        let newData = Array(repeating: UInt8(0xFF), count: 256)
        let result = disk.writeSector(track: 0, c: 0, h: 0, r: 1, data: newData)
        #expect(result == true)
        #expect(disk.dirty == true)
        #expect(disk.tracks[0][0].data[0] == 0xFF)
    }

    @Test func writeProtectedDisk() {
        var disk = D88Disk()
        disk.writeProtected = true
        var sector = D88Disk.Sector()
        sector.c = 0; sector.h = 0; sector.r = 1; sector.n = 1
        sector.data = Array(repeating: 0x00, count: 256)
        disk.tracks[0] = [sector]

        let result = disk.writeSector(track: 0, c: 0, h: 0, r: 1,
                                       data: Array(repeating: 0xFF, count: 256))
        #expect(result == false)  // Write rejected
    }

    @Test func tooSmallDataReturnsNil() {
        let data = Array(repeating: UInt8(0), count: 100)  // Too small
        #expect(D88Disk.parse(data: data) == nil)
    }

    @Test func parseMultipleImages() {
        // Create two minimal D88 images concatenated
        func makeMinimalImage(name: String) -> [UInt8] {
            var data = Array(repeating: UInt8(0), count: 688)
            for (i, byte) in Array(name.utf8).prefix(16).enumerated() {
                data[i] = byte
            }
            // Disk size = 688
            data[0x1C] = 0xB0
            data[0x1D] = 0x02
            data[0x1E] = 0x00
            data[0x1F] = 0x00
            return data
        }

        let image1 = makeMinimalImage(name: "DISK A")
        let image2 = makeMinimalImage(name: "DISK B")
        let combined = image1 + image2

        let disks = D88Disk.parseAll(data: combined)
        #expect(disks.count == 2)
        #expect(disks[0].name == "DISK A")
        #expect(disks[1].name == "DISK B")
    }

    @Test func parseAllSingleImage() {
        var data = Array(repeating: UInt8(0), count: 688)
        data[0] = 0x54 // T
        data[0x1C] = 0xB0
        data[0x1D] = 0x02
        data[0x1E] = 0x00
        data[0x1F] = 0x00

        let disks = D88Disk.parseAll(data: data)
        #expect(disks.count == 1)
        #expect(disks[0].name == "T")
    }

    @Test func serializeRoundTrip() {
        var disk = D88Disk()
        disk.name = "ROUNDTRIP"
        disk.diskType = .twoDD
        disk.writeProtected = true

        var sector = D88Disk.Sector()
        sector.c = 0; sector.h = 0; sector.r = 1; sector.n = 1
        sector.sectorCount = 1
        sector.data = Array(0..<256).map { UInt8($0) }
        disk.tracks[0] = [sector]

        guard let serialized = disk.serialize() else {
            #expect(Bool(false), "Serialization failed")
            return
        }

        let reparsed = D88Disk.parse(data: serialized)
        #expect(reparsed != nil)
        #expect(reparsed?.name == "ROUNDTRIP")
        #expect(reparsed?.diskType == .twoDD)
        #expect(reparsed?.writeProtected == true)
        #expect(reparsed?.tracks[0].count == 1)
        #expect(reparsed?.tracks[0][0].data == sector.data)
    }

    // MARK: - Sector Matching

    @Test("Find sector with N parameter matching")
    func findSectorWithNParameterMatching() {
        var disk = D88Disk()

        // Two sectors with same R but different N values
        var sector1 = D88Disk.Sector()
        sector1.c = 0; sector1.h = 0; sector1.r = 1; sector1.n = 1  // 256 bytes
        sector1.data = Array(repeating: 0x11, count: 256)

        var sector2 = D88Disk.Sector()
        sector2.c = 0; sector2.h = 0; sector2.r = 1; sector2.n = 2  // 512 bytes
        sector2.data = Array(repeating: 0x22, count: 512)

        disk.tracks[0] = [sector1, sector2]

        // findSector with n: parameter should match the correct size
        let foundN1 = disk.findSector(track: 0, c: 0, h: 0, r: 1, n: 1)
        #expect(foundN1 != nil)
        #expect(foundN1?.data.count == 256)
        #expect(foundN1?.data[0] == 0x11)

        let foundN2 = disk.findSector(track: 0, c: 0, h: 0, r: 1, n: 2)
        #expect(foundN2 != nil)
        #expect(foundN2?.data.count == 512)
        #expect(foundN2?.data[0] == 0x22)
    }

    @Test("Write sector preserves other sectors on track")
    func writeSectorPreservesOtherSectors() {
        var disk = D88Disk()

        // Create 3 sectors on track 0
        for r in 1...3 {
            var sector = D88Disk.Sector()
            sector.c = 0; sector.h = 0; sector.r = UInt8(r); sector.n = 1
            sector.data = Array(repeating: UInt8(r * 0x10), count: 256)
            disk.tracks[0].append(sector)
        }

        // Write to sector 2 only
        let newData = Array(repeating: UInt8(0xFF), count: 256)
        let success = disk.writeSector(track: 0, c: 0, h: 0, r: 2, data: newData)
        #expect(success == true)

        // Verify sector 1 is unchanged
        let s1 = disk.findSector(track: 0, c: 0, h: 0, r: 1)
        #expect(s1?.data[0] == 0x10)

        // Verify sector 2 was updated
        let s2 = disk.findSector(track: 0, c: 0, h: 0, r: 2)
        #expect(s2?.data[0] == 0xFF)

        // Verify sector 3 is unchanged
        let s3 = disk.findSector(track: 0, c: 0, h: 0, r: 3)
        #expect(s3?.data[0] == 0x30)
    }

    // MARK: - createFormatted

    @Test("createFormatted 2D produces correct geometry")
    func createFormatted2D() {
        let disk = D88Disk.createFormatted(type: .twoD, name: "TEST2D")
        #expect(disk.name == "TEST2D")
        #expect(disk.diskType == .twoD)
        #expect(disk.writeProtected == false)

        // 40 cylinders × 2 sides = 80 tracks
        var nonEmptyCount = 0
        for t in 0..<D88Disk.maxTracks {
            if !disk.tracks[t].isEmpty { nonEmptyCount += 1 }
        }
        #expect(nonEmptyCount == 80)

        // Each track: 16 sectors, 256 bytes each
        let track0 = disk.tracks[0]
        #expect(track0.count == 16)
        #expect(track0[0].c == 0)
        #expect(track0[0].h == 0)
        #expect(track0[0].r == 1)
        #expect(track0[0].n == 1)
        #expect(track0[0].data.count == 256)
        #expect(track0[0].data[0] == 0xE5)

        // Serialize round-trip
        let serialized = disk.serialize()
        #expect(serialized != nil)
        let reparsed = D88Disk.parse(data: serialized!)
        #expect(reparsed != nil)
        #expect(reparsed!.tracks[0].count == 16)
    }

    @Test("createFormatted 2DD produces 160 tracks")
    func createFormatted2DD() {
        let disk = D88Disk.createFormatted(type: .twoDD)
        #expect(disk.diskType == .twoDD)
        var nonEmptyCount = 0
        for t in 0..<D88Disk.maxTracks {
            if !disk.tracks[t].isEmpty { nonEmptyCount += 1 }
        }
        #expect(nonEmptyCount == 160)  // 80 cyl × 2 sides
    }

    @Test("createFormatted 2HD produces 154 tracks with 26 sectors")
    func createFormatted2HD() {
        let disk = D88Disk.createFormatted(type: .twoHD)
        #expect(disk.diskType == .twoHD)
        var nonEmptyCount = 0
        for t in 0..<D88Disk.maxTracks {
            if !disk.tracks[t].isEmpty { nonEmptyCount += 1 }
        }
        #expect(nonEmptyCount == 154)  // 77 cyl × 2 sides
        #expect(disk.tracks[0].count == 26)
    }

    @Test("Parse D88 with empty tracks")
    func parseD88WithEmptyTracks() {
        // Create a D88 with only track 0 having data, others empty (offset=0)
        var data = Array(repeating: UInt8(0), count: 688 + 16 + 256)

        // Header
        data[0] = 0x45  // E
        data[0x1A] = 0x00
        data[0x1B] = 0x00  // 2D

        let totalSize = UInt32(data.count)
        data[0x1C] = UInt8(totalSize & 0xFF)
        data[0x1D] = UInt8((totalSize >> 8) & 0xFF)

        // Track 0 offset only (other tracks remain 0 = empty)
        let trackOffset: UInt32 = 688
        data[0x20] = UInt8(trackOffset & 0xFF)
        data[0x21] = UInt8((trackOffset >> 8) & 0xFF)

        // Sector header at offset 688
        let sectorStart = 688
        data[sectorStart + 0] = 0    // C
        data[sectorStart + 1] = 0    // H
        data[sectorStart + 2] = 1    // R
        data[sectorStart + 3] = 1    // N
        data[sectorStart + 4] = 1    // sector count (low)
        data[sectorStart + 5] = 0    // sector count (high)
        data[sectorStart + 14] = 0x00
        data[sectorStart + 15] = 0x01  // 256 bytes

        for i in 0..<256 {
            data[sectorStart + 16 + i] = 0xBB
        }

        let disk = D88Disk.parse(data: data)
        #expect(disk != nil)

        // Track 0 should have data
        #expect(disk!.tracks[0].count == 1)
        #expect(disk!.tracks[0][0].data[0] == 0xBB)

        // All other tracks should be empty
        for t in 1..<D88Disk.maxTracks {
            #expect(disk!.tracks[t].isEmpty)
        }
    }
}
