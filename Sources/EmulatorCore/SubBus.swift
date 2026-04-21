/// SubBus — Bus implementation for the PC-8801 sub-CPU (disk controller).
///
/// Memory map (QUASI88 compatible):
///   0x0000-0x1FFF: DISK.ROM (8KB, RO)
///   0x2000-0x7FFF: Pattern-initialized backing memory
///   0x8000-0xFFFF: wraps via addr & 0x7FFF
///
/// I/O ports:
///   0xF4: FDC motor control (write)
///   0xF7: (write) — sub-CPU flag / side select
///   0xF8 read:  FDC Terminal Count
///   0xF8 write: motor control
///   0xFA read:  FDC Main Status Register
///   0xFB read:  FDC Data Register
///   0xFB write: FDC Data Register
///   0xFC-0xFF:  PIO (sub side)
public final class SubBus: Bus {

    // MARK: - Memory

    /// 32KB backing: [0x0000-0x1FFF] ROM, [0x2000-0x7FFF] initialized memory.
    public var romram: [UInt8] = Array(repeating: 0x00, count: 0x8000)

    static let initTable: [UInt8] = [
        // 0x2000
        0, 1, 0, 1, 0, 3, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0,
        // 0x3000
        0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0,
        // 0x4000
        1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1,
        // 0x5000
        1, 0, 1, 0, 1, 0, 1, 1, 1, 1, 3, 1, 0, 1, 0, 1,
        // 0x6000
        1, 0, 1, 0, 1, 2, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1,
        // 0x7000
        1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1,
    ]

    static let initPattern: [UInt8] = [
        0x00, 0xFF, 0x00, 0xFF,
        0xFF, 0x00, 0xFF, 0x00,
        0x00, 0xFF, 0x00, 0xFF,
        0xFF, 0x00, 0xFF, 0x00,
    ]

    // MARK: - References

    /// PIO (for sub-side access on ports 0xFC-0xFF)
    public var pio: PIO8255?

    /// FDC
    public var fdc: UPD765A?

    /// Current sub-CPU PC (set by SubSystem before each step)
    public var currentSubPC: UInt16 = 0

    /// Motor state per drive (set by port 0xF8 write)
    public var motorOn: [Bool] = [false, false, false, false]

    /// Drive/side select (port 0xF4 write)
    public var driveSelect: UInt8 = 0

    // MARK: - Init

    public init() {
        initializeROMDefaults()
        initializeHigherMemory()
    }

    /// Load DISK.ROM (up to 8KB).
    public func loadROM(_ data: [UInt8]) {
        initializeROMDefaults()
        let size = min(data.count, 0x2000)
        for i in 0..<size {
            romram[i] = data[i]
        }
    }

    /// Reset pattern-initialized backing memory.
    public func reset() {
        initializeHigherMemory()
        motorOn = [false, false, false, false]
        driveSelect = 0
    }

    static func initialByte(at mapped: Int) -> UInt8 {
        precondition((0..<0x8000).contains(mapped))
        switch mapped {
        case 0x0000:
            return 0x18
        case 0x0001:
            return 0xFE
        case 0x0002..<0x2000:
            return 0xFF
        default:
            let offset = mapped - 0x2000
            let high = offset >> 8
            let low = (offset >> 4) & 0x0F
            let eor: UInt8
            switch initTable[high] {
            case 0:
                eor = 0xF0
            case 1:
                eor = 0x0F
            case 2:
                eor = 0xFF
            default:
                eor = 0x00
            }
            return initPattern[low] ^ eor
        }
    }

    private func initializeROMDefaults() {
        for i in 0..<0x2000 {
            romram[i] = Self.initialByte(at: i)
        }
    }

    private func initializeHigherMemory() {
        for i in 0x2000..<0x8000 {
            romram[i] = Self.initialByte(at: i)
        }
    }

    // MARK: - Bus Protocol

    public func memRead(_ addr: UInt16) -> UInt8 {
        return romram[Int(addr) & 0x7FFF]
    }

    public func memWrite(_ addr: UInt16, value: UInt8) {
        let mapped = Int(addr) & 0x7FFF
        // Only RAM area (0x4000-0x7FFF) is writable
        if mapped >= 0x4000 {
            romram[mapped] = value
        }
    }

    public func ioRead(_ port: UInt16) -> UInt8 {
        let p = UInt8(port & 0xFF)
        switch p {
        case 0xF8:
            // Terminal Count — signal TC to FDC
            fdc?.terminalCount()
            return 0xFF

        case 0xFA:
            return fdc?.readStatus() ?? 0xFF

        case 0xFB:
            return fdc?.readData() ?? 0xFF

        case 0xFC:
            // PIO Port A (sub side reads from main's Port B)
            return pio?.readAB(side: .sub, port: .portA) ?? 0xFF

        case 0xFD:
            // PIO Port B (sub's own Port B — write type, returns own data)
            return pio?.readAB(side: .sub, port: .portB) ?? 0xFF

        case 0xFE:
            // PIO Port C (cross-wired)
            return pio?.readC(side: .sub) ?? 0xFF

        case 0xFF:
            return 0xFF  // Control register (not typically read)

        default:
            return 0xFF
        }
    }

    public func ioWrite(_ port: UInt16, value: UInt8) {
        let p = UInt8(port & 0xFF)
        switch p {
        case 0xF4:
            // Drive/side select
            driveSelect = value

        case 0xF7:
            // Sub-CPU flag (side select, etc.)
            break

        case 0xF8:
            // Motor control
            motorOn[0] = (value & 0x01) != 0
            motorOn[1] = (value & 0x02) != 0

        case 0xFB:
            fdc?.writeData(value)

        case 0xFC:
            // PIO Port A data register
            pio?.writeAB(side: .sub, port: .portA, data: value)

        case 0xFD:
            // PIO Port B (sub side writes)
            pio?.writeAB(side: .sub, port: .portB, data: value)

        case 0xFE:
            // PIO Port C data register
            pio?.writePortC(side: .sub, data: value)

        case 0xFF:
            pio?.writeControl(side: .sub, data: value)

        default:
            break
        }
    }
}
