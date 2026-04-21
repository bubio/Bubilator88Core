// MARK: - Save State Infrastructure
//
// Binary serialization for save state snapshots.
// All values are little-endian.

import Foundation

// MARK: - Writer

public struct SaveStateWriter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public var data: [UInt8] { buffer }
    public var count: Int { buffer.count }

    public mutating func writeUInt8(_ v: UInt8) {
        buffer.append(v)
    }

    public mutating func writeUInt16(_ v: UInt16) {
        buffer.append(UInt8(v & 0xFF))
        buffer.append(UInt8(v >> 8))
    }

    public mutating func writeUInt32(_ v: UInt32) {
        buffer.append(UInt8(v & 0xFF))
        buffer.append(UInt8((v >> 8) & 0xFF))
        buffer.append(UInt8((v >> 16) & 0xFF))
        buffer.append(UInt8(v >> 24))
    }

    public mutating func writeUInt64(_ v: UInt64) {
        for i in 0..<8 {
            buffer.append(UInt8((v >> (i * 8)) & 0xFF))
        }
    }

    public mutating func writeInt(_ v: Int) {
        writeUInt64(UInt64(bitPattern: Int64(v)))
    }

    public mutating func writeInt32(_ v: Int32) {
        writeUInt32(UInt32(bitPattern: v))
    }

    public mutating func writeBool(_ v: Bool) {
        buffer.append(v ? 1 : 0)
    }

    public mutating func writeFloat(_ v: Float) {
        writeUInt32(v.bitPattern)
    }

    public mutating func writeDouble(_ v: Double) {
        writeUInt64(v.bitPattern)
    }

    public mutating func writeBytes(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
    }

    public mutating func writeBytes(_ data: [UInt8], count: Int) {
        precondition(data.count >= count)
        buffer.append(contentsOf: data[0..<count])
    }

    /// Write a length-prefixed byte array (uint32 length + data).
    public mutating func writeLengthPrefixedBytes(_ data: [UInt8]) {
        writeUInt32(UInt32(data.count))
        buffer.append(contentsOf: data)
    }
}

// MARK: - Reader

public enum SaveStateError: Error {
    case endOfData
    case invalidMagic
    case unsupportedVersion(UInt16)
    case missingSections([String])
    case sectionTooSmall(String)
    case invalidData(String)
}

public struct SaveStateReader: Sendable {
    private let buffer: [UInt8]
    private(set) var position: Int = 0

    public init(_ data: [UInt8]) {
        self.buffer = data
    }

    public init(_ data: Data) {
        self.buffer = Array(data)
    }

    public var remaining: Int { buffer.count - position }

    public mutating func readUInt8() throws -> UInt8 {
        guard position < buffer.count else { throw SaveStateError.endOfData }
        let v = buffer[position]
        position += 1
        return v
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard position + 2 <= buffer.count else { throw SaveStateError.endOfData }
        let v = UInt16(buffer[position]) | (UInt16(buffer[position + 1]) << 8)
        position += 2
        return v
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard position + 4 <= buffer.count else { throw SaveStateError.endOfData }
        let v = UInt32(buffer[position])
            | (UInt32(buffer[position + 1]) << 8)
            | (UInt32(buffer[position + 2]) << 16)
            | (UInt32(buffer[position + 3]) << 24)
        position += 4
        return v
    }

    public mutating func readUInt64() throws -> UInt64 {
        guard position + 8 <= buffer.count else { throw SaveStateError.endOfData }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(buffer[position + i]) << (i * 8)
        }
        position += 8
        return v
    }

    public mutating func readInt() throws -> Int {
        Int(Int64(bitPattern: try readUInt64()))
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard position + count <= buffer.count else { throw SaveStateError.endOfData }
        let result = Array(buffer[position..<(position + count)])
        position += count
        return result
    }

    /// Read a length-prefixed byte array (uint32 length + data).
    public mutating func readLengthPrefixedBytes() throws -> [UInt8] {
        let count = Int(try readUInt32())
        return try readBytes(count)
    }

    public mutating func skip(_ count: Int) throws {
        guard position + count <= buffer.count else { throw SaveStateError.endOfData }
        position += count
    }
}

// MARK: - Save State File Format

public struct SaveStateFile: Sendable {
    public static let magic: UInt32 = 0x38385542  // "BU88" little-endian
    /// v2 (2026-04): CRTC gains blinkCounter + blinkAttribBit fields.
    /// v3 (2026-04-21): dropped chase-heuristic fields (`needsSubCPURun`,
    /// `pioInterleaveInstructionsRemaining`, `subPortBWriteGeneration`,
    /// `pendingFreshMainPort*`, `pendingATNIdleLoopObservation`, etc.) as
    /// part of the BubiC event.cpp scheduler migration. v2 files are no
    /// longer loadable — pre-release only.
    public static let currentVersion: UInt16 = 3
    public static let headerSize = 64
    public static let sectionEntrySize = 12

    public struct SectionEntry: Sendable {
        public let tag: UInt32    // FourCC
        public let offset: UInt32
        public let size: UInt32
    }

    /// Create a FourCC from a 4-character string.
    public static func fourCC(_ s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    /// Append a little-endian u32 to a byte buffer. Used when nesting
    /// multiple blobs inside a single section.
    public static func appendU32LE(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8(v >> 24))
    }

    /// Read a little-endian u32 from a byte buffer. Returns nil if the
    /// buffer ends before 4 bytes can be read.
    public static func readU32LE(_ data: [UInt8], at pos: inout Int) -> UInt32? {
        guard pos + 4 <= data.count else { return nil }
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    /// Build a complete save state file from named sections.
    public static func build(sections: [(tag: UInt32, data: [UInt8])],
                             thumbnail: [UInt8]? = nil) -> [UInt8] {
        let sectionCount = sections.count + (thumbnail != nil ? 1 : 0)
        let tableSize = sectionCount * sectionEntrySize
        let dataOffset = headerSize + tableSize

        // Calculate section offsets
        var currentOffset = UInt32(dataOffset)
        var entries: [SectionEntry] = []
        for section in sections {
            entries.append(SectionEntry(tag: section.tag,
                                        offset: currentOffset,
                                        size: UInt32(section.data.count)))
            currentOffset += UInt32(section.data.count)
        }

        var thumbnailOffset: UInt32 = 0
        var thumbnailSize: UInt32 = 0
        if let thumb = thumbnail {
            let tag = fourCC("THMB")
            thumbnailOffset = currentOffset
            thumbnailSize = UInt32(thumb.count)
            entries.append(SectionEntry(tag: tag,
                                        offset: currentOffset,
                                        size: UInt32(thumb.count)))
            currentOffset += UInt32(thumb.count)
        }

        // Write header
        var w = SaveStateWriter()

        // 0x00: Magic
        w.writeUInt32(magic)
        // 0x04: Version
        w.writeUInt16(currentVersion)
        // 0x06: Reserved
        w.writeUInt16(0)
        // 0x08: Timestamp
        w.writeDouble(Date().timeIntervalSince1970)
        // 0x10: Emulator version (32 bytes, null-padded)
        let versionStr = "Bubilator88"
        let versionBytes = Array(versionStr.utf8)
        w.writeBytes(versionBytes)
        for _ in versionBytes.count..<32 { w.writeUInt8(0) }
        // 0x30: Flags
        w.writeUInt32(0)
        // 0x34: Thumbnail offset
        w.writeUInt32(thumbnailOffset)
        // 0x38: Thumbnail size
        w.writeUInt32(thumbnailSize)
        // 0x3C: Section count
        w.writeUInt32(UInt32(sectionCount))

        // Section table
        for entry in entries {
            w.writeUInt32(entry.tag)
            w.writeUInt32(entry.offset)
            w.writeUInt32(entry.size)
        }

        // Section data
        for section in sections {
            w.writeBytes(section.data)
        }
        if let thumb = thumbnail {
            w.writeBytes(thumb)
        }

        return w.data
    }

    /// Parse a save state file and return sections as a dictionary.
    public static func parse(_ data: [UInt8]) throws -> [UInt32: [UInt8]] {
        guard data.count >= headerSize else {
            throw SaveStateError.invalidData("File too small")
        }

        var r = SaveStateReader(data)

        let fileMagic = try r.readUInt32()
        guard fileMagic == magic else {
            throw SaveStateError.invalidMagic
        }

        let version = try r.readUInt16()
        // v1/v2 files are pre-release (v1 had a different CRTC layout; v2
        // carried chase-heuristic fields that no longer exist) — reject both.
        guard version >= 3, version <= currentVersion else {
            throw SaveStateError.unsupportedVersion(version)
        }

        try r.skip(2)  // reserved
        _ = try r.readDouble()  // timestamp
        try r.skip(32) // version string
        _ = try r.readUInt32()  // flags
        _ = try r.readUInt32()  // thumbnail offset
        _ = try r.readUInt32()  // thumbnail size
        let sectionCount = try r.readUInt32()

        // Read section table
        var entries: [(tag: UInt32, offset: Int, size: Int)] = []
        for _ in 0..<sectionCount {
            let tag = try r.readUInt32()
            let offset = Int(try r.readUInt32())
            let size = Int(try r.readUInt32())
            entries.append((tag, offset, size))
        }

        // Extract sections
        var sections: [UInt32: [UInt8]] = [:]
        for entry in entries {
            guard entry.offset + entry.size <= data.count else {
                throw SaveStateError.invalidData("Section extends beyond file")
            }
            sections[entry.tag] = Array(data[entry.offset..<(entry.offset + entry.size)])
        }

        return sections
    }
}
