/// Bus protocol — the only interface through which Z80 accesses memory and I/O.
///
/// I/O ports are 16-bit per Z80 specification.
/// PC-88 implementation may internally mask to 8-bit.
public protocol Bus: AnyObject {
    func memRead(_ addr: UInt16) -> UInt8
    func memWrite(_ addr: UInt16, value: UInt8)
    func ioRead(_ port: UInt16) -> UInt8
    func ioWrite(_ port: UInt16, value: UInt8)
}
