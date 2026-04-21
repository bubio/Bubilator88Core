import Foundation

/// D88 disk image format parser.
///
/// D88 header: 688 bytes
///   0x00 (17B): Disk name
///   0x1A (1B): Write protect (0x00=none, 0x10=protected)
///   0x1B (1B): Disk type (0x00=2D, 0x10=2DD, 0x20=2HD)
///   0x1C (4B): Disk size (total image size)
///   0x20 (4x164B): Track offset table (164 entries)
///
/// Each sector: 16-byte header + data
public struct D88Disk {

    // MARK: - Types

    public enum DiskType: UInt8, Sendable {
        case twoD  = 0x00  // 2D:  40 tracks, 2 sides
        case twoDD = 0x10  // 2DD: 80 tracks, 2 sides
        case twoHD = 0x20  // 2HD: 77 tracks, 2 sides
    }

    public struct Sector: Sendable {
        public var c: UInt8          // Cylinder
        public var h: UInt8          // Head
        public var r: UInt8          // Record (sector number)
        public var n: UInt8          // Size code (0=128, 1=256, 2=512, 3=1024)
        public var sectorCount: UInt16
        public var density: UInt8    // 0x00=double, 0x40=single
        public var deleted: Bool     // Deleted data mark
        public var status: UInt8     // FDC status (0=normal)
        public var data: [UInt8]

        public var dataSize: Int {
            128 << Int(n)
        }

        public init() {
            c = 0; h = 0; r = 0; n = 0
            sectorCount = 0; density = 0
            deleted = false; status = 0; data = []
        }
    }

    // MARK: - Properties

    public var name: String
    public var writeProtected: Bool
    public var diskType: DiskType
    public var tracks: [[Sector]]    // Indexed by track number (up to 164)
    public var dirty: Bool = false

    /// Total number of track slots in D88 format
    public static let maxTracks = 164

    // MARK: - Init

    public init() {
        name = ""
        writeProtected = false
        diskType = .twoD
        tracks = Array(repeating: [], count: Self.maxTracks)
    }

    /// Create a formatted blank disk with empty sectors.
    ///
    /// - 2D:  40 cylinders × 2 sides, 16 sectors/track, 256 bytes/sector
    /// - 2DD: 80 cylinders × 2 sides, 16 sectors/track, 256 bytes/sector
    /// - 2HD: 77 cylinders × 2 sides, 26 sectors/track, 256 bytes/sector
    public static func createFormatted(type: DiskType, name: String = "BLANK") -> D88Disk {
        var disk = D88Disk()
        disk.name = name
        disk.diskType = type
        disk.writeProtected = false

        let cylinders: Int
        let sectorsPerTrack: Int
        let sizeCode: UInt8      // n: 0=128B, 1=256B, 2=512B
        let bytesPerSector: Int

        switch type {
        case .twoD:
            cylinders = 40; sectorsPerTrack = 16; sizeCode = 1; bytesPerSector = 256
        case .twoDD:
            cylinders = 80; sectorsPerTrack = 16; sizeCode = 1; bytesPerSector = 256
        case .twoHD:
            cylinders = 77; sectorsPerTrack = 26; sizeCode = 1; bytesPerSector = 256
        }

        for cyl in 0..<cylinders {
            for head in 0...1 {
                let trackIndex = cyl * 2 + head
                var sectors: [Sector] = []
                for sec in 1...sectorsPerTrack {
                    var sector = Sector()
                    sector.c = UInt8(cyl)
                    sector.h = UInt8(head)
                    sector.r = UInt8(sec)
                    sector.n = sizeCode
                    sector.sectorCount = UInt16(sectorsPerTrack)
                    sector.density = 0x00
                    sector.deleted = false
                    sector.status = 0
                    sector.data = Array(repeating: 0xE5, count: bytesPerSector)
                    sectors.append(sector)
                }
                disk.tracks[trackIndex] = sectors
            }
        }

        return disk
    }

    // MARK: - Parsing

    /// Parse a D88 disk image from raw data. Returns nil on invalid data.
    public static func parse(data: [UInt8]) -> D88Disk? {
        guard data.count >= 688 else { return nil }  // Minimum: header only

        var disk = D88Disk()

        // Disk name (17 bytes, null-terminated, Shift-JIS encoded)
        let nameBytes = Array(data[0..<17])
        let trimmedBytes = Data(nameBytes.prefix(while: { $0 != 0 }))
        disk.name = String(data: trimmedBytes, encoding: .shiftJIS)
            ?? String(decoding: trimmedBytes, as: UTF8.self)

        // Write protect
        disk.writeProtected = data[0x1A] == 0x10

        // Disk type
        disk.diskType = DiskType(rawValue: data[0x1B]) ?? .twoD

        // Disk size. Some real-world D88 images (e.g. PERSEUS.D88) have a
        // declared disk size that is larger than the actual file — BubiC
        // happily parses these, so we do too. Clamp to the actual file
        // length for bounds computations below; the per-sector bounds check
        // in the parsing loop prevents any out-of-range reads.
        let declaredSize = Int(readUInt32LE(data, offset: 0x1C))
        let diskSize = UInt32(min(declaredSize == 0 ? data.count : declaredSize, data.count))

        // Track offset table (164 entries, 4 bytes each)
        var trackOffsets: [UInt32] = []
        for i in 0..<maxTracks {
            let offset = readUInt32LE(data, offset: 0x20 + i * 4)
            trackOffsets.append(offset)
        }

        // Parse each track
        for trackIndex in 0..<maxTracks {
            let trackOffset = Int(trackOffsets[trackIndex])
            if trackOffset == 0 { continue }  // Empty track
            guard trackOffset < data.count else { continue }

            var sectors: [Sector] = []
            var pos = trackOffset

            // Read sectors until we hit next track or end of disk
            let nextTrackOffset = findNextTrackOffset(trackOffsets: trackOffsets,
                                                      currentIndex: trackIndex,
                                                      diskSize: Int(diskSize))

            while pos + 16 <= nextTrackOffset && pos + 16 <= data.count {
                var sector = Sector()
                sector.c = data[pos]
                sector.h = data[pos + 1]
                sector.r = data[pos + 2]
                sector.n = data[pos + 3]
                sector.sectorCount = readUInt16LE(data, offset: pos + 4)
                sector.density = data[pos + 6]
                sector.deleted = data[pos + 7] != 0
                sector.status = data[pos + 8]

                let sectorDataSize = Int(readUInt16LE(data, offset: pos + 14))
                pos += 16

                guard pos + sectorDataSize <= data.count else { break }
                sector.data = Array(data[pos..<(pos + sectorDataSize)])
                pos += sectorDataSize

                sectors.append(sector)

                // Safety: stop if we've read all sectors for this track
                if sectors.count >= Int(sector.sectorCount) && sector.sectorCount > 0 {
                    break
                }
            }

            disk.tracks[trackIndex] = sectors
        }

        return disk
    }

    /// Parse all disk images from a multi-image D88 file.
    /// Returns an array of D88Disk; single-image files return a 1-element array.
    public static func parseAll(data: [UInt8]) -> [D88Disk] {
        var disks: [D88Disk] = []
        var offset = 0
        while offset + 688 <= data.count {
            let slice = Array(data[offset...])
            guard let disk = parse(data: slice) else { break }
            disks.append(disk)
            let diskSize = Int(readUInt32LE(data, offset: offset + 0x1C))
            if diskSize == 0 || diskSize > data.count - offset { break }
            offset += diskSize
        }
        return disks
    }

    // MARK: - Sector Access

    /// Find a sector by C/H/R values.
    public func findSector(track: Int, c: UInt8, h: UInt8, r: UInt8) -> Sector? {
        guard track >= 0 && track < tracks.count else { return nil }
        return tracks[track].first { $0.c == c && $0.h == h && $0.r == r }
    }

    /// Find sector matching C/H/R/N. Used when the track has duplicate R values
    /// with different N (sector size), e.g. mixed 256B/512B sectors on Track 0.
    public func findSector(track: Int, c: UInt8, h: UInt8, r: UInt8, n: UInt8) -> Sector? {
        guard track >= 0 && track < tracks.count else { return nil }
        // Prefer exact N match; fall back to C/H/R-only if no N match exists
        if let exact = tracks[track].first(where: { $0.c == c && $0.h == h && $0.r == r && $0.n == n }) {
            return exact
        }
        return tracks[track].first { $0.c == c && $0.h == h && $0.r == r }
    }

    /// Read sector data by C/H/R.
    public func readSector(track: Int, c: UInt8, h: UInt8, r: UInt8) -> [UInt8]? {
        return findSector(track: track, c: c, h: h, r: r)?.data
    }

    /// Write data to a sector. Returns false if write-protected or sector not found.
    public mutating func writeSector(track: Int, c: UInt8, h: UInt8, r: UInt8, data: [UInt8]) -> Bool {
        guard !writeProtected else { return false }
        guard track >= 0 && track < tracks.count else { return false }

        if let idx = tracks[track].firstIndex(where: { $0.c == c && $0.h == h && $0.r == r }) {
            tracks[track][idx].data = data
            dirty = true
            return true
        }
        return false
    }

    // MARK: - Serialization

    /// Serialize back to D88 format. Returns nil if structure is invalid.
    public func serialize() -> [UInt8]? {
        var output: [UInt8] = []

        // Header: name (17 bytes, Shift-JIS)
        var nameBytes = Array((name.data(using: .shiftJIS) ?? Data(name.utf8)).prefix(16))
        while nameBytes.count < 17 { nameBytes.append(0) }
        output.append(contentsOf: nameBytes)

        // Reserved (9 bytes)
        output.append(contentsOf: Array(repeating: UInt8(0), count: 9))

        // Write protect
        output.append(writeProtected ? 0x10 : 0x00)

        // Disk type
        output.append(diskType.rawValue)

        // Disk size placeholder (4 bytes) — will be filled later
        let diskSizeOffset = output.count
        output.append(contentsOf: [0, 0, 0, 0])

        // Track offset table (164 x 4 bytes)
        let trackTableOffset = output.count
        output.append(contentsOf: Array(repeating: UInt8(0), count: Self.maxTracks * 4))

        // Write track data
        for trackIndex in 0..<Self.maxTracks {
            if tracks[trackIndex].isEmpty {
                continue
            }

            // Record track offset
            let currentOffset = UInt32(output.count)
            writeUInt32LE(&output, offset: trackTableOffset + trackIndex * 4, value: currentOffset)

            // Write sectors
            for sector in tracks[trackIndex] {
                output.append(sector.c)
                output.append(sector.h)
                output.append(sector.r)
                output.append(sector.n)
                appendUInt16LE(&output, value: sector.sectorCount)
                output.append(sector.density)
                output.append(sector.deleted ? 0x10 : 0x00)
                output.append(sector.status)
                // Reserved (5 bytes)
                output.append(contentsOf: Array(repeating: UInt8(0), count: 5))
                appendUInt16LE(&output, value: UInt16(sector.data.count))
                output.append(contentsOf: sector.data)
            }
        }

        // Fill disk size
        writeUInt32LE(&output, offset: diskSizeOffset, value: UInt32(output.count))

        return output
    }

    // MARK: - Helpers

    private static func readUInt16LE(_ data: [UInt8], offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: [UInt8], offset: Int) -> UInt32 {
        return UInt32(data[offset])
             | (UInt32(data[offset + 1]) << 8)
             | (UInt32(data[offset + 2]) << 16)
             | (UInt32(data[offset + 3]) << 24)
    }

    private func appendUInt16LE(_ data: inout [UInt8], value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private func writeUInt32LE(_ data: inout [UInt8], offset: Int, value: UInt32) {
        data[offset]     = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func findNextTrackOffset(trackOffsets: [UInt32], currentIndex: Int, diskSize: Int) -> Int {
        var minNext = diskSize
        let currentOffset = Int(trackOffsets[currentIndex])
        for i in 0..<trackOffsets.count {
            let off = Int(trackOffsets[i])
            if off > currentOffset && off < minNext {
                minNext = off
            }
        }
        return minNext
    }
}
