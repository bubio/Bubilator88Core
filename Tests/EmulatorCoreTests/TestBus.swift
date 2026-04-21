import EmulatorCore

/// Simple Bus implementation for unit testing.
/// Provides 64KB RAM and 256 I/O ports with read/write tracking.
final class TestBus: Bus {
    var memory: [UInt8] = Array(repeating: 0x00, count: 65536)
    var ioPorts: [UInt8] = Array(repeating: 0xFF, count: 256)

    var memReadLog: [(addr: UInt16, value: UInt8)] = []
    var memWriteLog: [(addr: UInt16, value: UInt8)] = []
    var ioReadLog: [(port: UInt16, value: UInt8)] = []
    var ioWriteLog: [(port: UInt16, value: UInt8)] = []

    func memRead(_ addr: UInt16) -> UInt8 {
        let value = memory[Int(addr)]
        memReadLog.append((addr, value))
        return value
    }

    func memWrite(_ addr: UInt16, value: UInt8) {
        memory[Int(addr)] = value
        memWriteLog.append((addr, value))
    }

    func ioRead(_ port: UInt16) -> UInt8 {
        let value = ioPorts[Int(port & 0xFF)]
        ioReadLog.append((port, value))
        return value
    }

    func ioWrite(_ port: UInt16, value: UInt8) {
        ioPorts[Int(port & 0xFF)] = value
        ioWriteLog.append((port, value))
    }

    /// Load a sequence of bytes at a given address.
    func load(at address: UInt16, data: [UInt8]) {
        for (i, byte) in data.enumerated() {
            memory[Int(address) + i] = byte
        }
    }

    func clearLogs() {
        memReadLog.removeAll()
        memWriteLog.removeAll()
        ioReadLog.removeAll()
        ioWriteLog.removeAll()
    }
}
