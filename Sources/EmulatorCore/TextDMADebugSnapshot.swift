#if DEBUG
@inline(__always) private func textDMADebugHex8(_ value: UInt8) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return s.count == 1 ? "0\(s)" : s
}

@inline(__always) private func textDMADebugHex16(_ value: UInt16) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, 4 - s.count)) + s
}

public struct TextDMADebugSnapshot: Sendable {
    public struct DMAState: Sendable {
        public let enabled: Bool
        public let mode: UInt8
        public let address: UInt16
        public let count: UInt16
    }

    public struct CRTCState: Sendable {
        public let displayEnabled: Bool
        public let intrMask: UInt8
        public let dmaUnderrun: Bool
        public let dmaBufferPtr: Int
        public let charsPerLine: Int
        public let linesPerScreen: Int
        public let bytesPerDMARow: Int
        public let expectedDMABytes: Int
        public let attrNonTransparent: Bool
    }

    public struct BusState: Sendable {
        public let textDisplayMode: String
        public let layerControl: UInt8
        public let graphicsColorMode: Bool
        public let tvramEnabled: Bool
    }

    public struct IOEvent: Sendable {
        public let port: UInt8
        public let value: UInt8
        public let isWrite: Bool
    }

    public struct RowState: Sendable {
        public let row: Int
        public let rawChars: [UInt8]
        public let rawAttrBytes: [UInt8]
        public let expandedChars: [UInt8]
        public let expandedAttributes: [UInt8]
    }

    public let dma: DMAState
    public let crtc: CRTCState
    public let bus: BusState
    public let rawDMABufferHead: [UInt8]
    public let textRow0Chars: [UInt8]
    public let textRow0Attributes: [UInt8]
    public let rowStates: [RowState]
    public let recentIO: [IOEvent]

    public func debugReport() -> String {
        var lines: [String] = []
        lines.append("=== Text DMA Snapshot ===")
        lines.append(
            "DMA: enabled=\(dma.enabled) mode=\(dma.mode) address=0x\(textDMADebugHex16(dma.address)) count=0x\(textDMADebugHex16(dma.count))"
        )
        lines.append(
            "CRTC: displayEnabled=\(crtc.displayEnabled) intrMask=\(crtc.intrMask) dmaUnderrun=\(crtc.dmaUnderrun) dmaBufferPtr=\(crtc.dmaBufferPtr) charsPerLine=\(crtc.charsPerLine) linesPerScreen=\(crtc.linesPerScreen) bytesPerDMARow=\(crtc.bytesPerDMARow) expectedDMABytes=\(crtc.expectedDMABytes) attrNonTransparent=\(crtc.attrNonTransparent)"
        )
        lines.append(
            "Bus: textDisplayMode=\(bus.textDisplayMode) layerControl=0x\(textDMADebugHex8(bus.layerControl)) graphicsColorMode=\(bus.graphicsColorMode) tvramEnabled=\(bus.tvramEnabled)"
        )
        lines.append("rawDMABufferHead[64]: \(hexList(rawDMABufferHead))")
        lines.append("textRow0Chars[80]: \(hexList(textRow0Chars))")
        lines.append("textRow0CharsASCII: \(asciiList(textRow0Chars))")
        lines.append("textRow0Attributes[80]: \(hexList(textRow0Attributes))")
        for rowState in rowStates {
            lines.append("row\(rowState.row)RawChars[\(rowState.rawChars.count)]: \(hexList(rowState.rawChars))")
            lines.append("row\(rowState.row)RawCharsASCII: \(asciiList(rowState.rawChars))")
            if !rowState.rawAttrBytes.isEmpty {
                lines.append("row\(rowState.row)RawAttrBytes[\(rowState.rawAttrBytes.count)]: \(hexList(rowState.rawAttrBytes))")
            }
            lines.append("row\(rowState.row)ExpandedChars[\(rowState.expandedChars.count)]: \(hexList(rowState.expandedChars))")
            lines.append("row\(rowState.row)ExpandedCharsASCII: \(asciiList(rowState.expandedChars))")
            lines.append("row\(rowState.row)ExpandedAttrs[\(rowState.expandedAttributes.count)]: \(hexList(rowState.expandedAttributes))")
        }
        if recentIO.isEmpty {
            lines.append("recentIO: <none>")
        } else {
            lines.append("recentIO:")
            for event in recentIO {
                let direction = event.isWrite ? "OUT" : "IN "
                lines.append("  \(direction) 0x\(textDMADebugHex8(event.port))=0x\(textDMADebugHex8(event.value))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func hexList(_ bytes: [UInt8]) -> String {
        bytes.map { textDMADebugHex8($0) }.joined(separator: " ")
    }

    private func asciiList(_ bytes: [UInt8]) -> String {
        var result = ""
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == 0x00 {
                result.append(" ")
            } else if (0x20..<0x7F).contains(byte) {
                result.append(Character(UnicodeScalar(Int(byte))!))
            } else {
                result.append(".")
            }
        }
        return result
    }
}
#endif
