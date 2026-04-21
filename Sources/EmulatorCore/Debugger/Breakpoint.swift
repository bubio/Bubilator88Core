import Foundation

/// A debugger breakpoint.
///
/// Value type identified by ``id`` so UI lists can distinguish
/// otherwise-equal entries. ``kind`` encodes both the CPU/bus target
/// and the address, keeping the public API small.
public struct Breakpoint: Identifiable, Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        case mainPC(UInt16)
        case subPC(UInt16)
        case memoryRead(UInt16)
        case memoryWrite(UInt16)
        case ioRead(UInt16)
        case ioWrite(UInt16)
    }

    public let id: UUID
    public var kind: Kind
    public var isEnabled: Bool
    public var label: String?

    /// Optional byte filter. Only meaningful for `.memoryWrite` and
    /// `.ioWrite` kinds — if non-nil, the breakpoint fires only when
    /// the value being written matches. Ignored for PC and read BPs
    /// because the byte value isn't known at the hook point.
    public var valueFilter: UInt8?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        isEnabled: Bool = true,
        label: String? = nil,
        valueFilter: UInt8? = nil
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.label = label
        self.valueFilter = valueFilter
    }
}

public extension Breakpoint.Kind {

    /// Short human-readable description for UI rendering.
    var displayName: String {
        switch self {
        case .mainPC(let a):      return String(format: "Main PC = %04X", a)
        case .subPC(let a):       return String(format: "Sub PC = %04X", a)
        case .memoryRead(let a):  return String(format: "Mem R  %04X", a)
        case .memoryWrite(let a): return String(format: "Mem W  %04X", a)
        case .ioRead(let a):      return String(format: "IO  R  %02X", a & 0xFF)
        case .ioWrite(let a):     return String(format: "IO  W  %02X", a & 0xFF)
        }
    }

    /// Whether this kind is write-side and therefore eligible for
    /// byte-match filtering.
    var supportsValueFilter: Bool {
        switch self {
        case .memoryWrite, .ioWrite: return true
        default: return false
        }
    }

    /// Target address (low-16 bits). Useful for compact lookup tables.
    var address: UInt16 {
        switch self {
        case .mainPC(let a), .subPC(let a),
             .memoryRead(let a), .memoryWrite(let a),
             .ioRead(let a),   .ioWrite(let a):
            return a
        }
    }
}
