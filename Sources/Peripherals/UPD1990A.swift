#if canImport(Foundation)
import Foundation
#endif

#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#endif

/// uPD1990A Real-Time Calendar behavioral model.
///
/// The PC-8801 calendar chip provides BCD-encoded date/time via a serial
/// shift register interface. Software accesses it through:
///   - Port 0x10 write: command bits (C0-C2) + data input (DIN)
///   - Port 0x40 write: control signals (STB bit 1 falling edge, CLK bit 2 rising edge)
///   - Port 0x40 read bit 4: CDO (Calendar Data Output)
///
/// Command modes (bits 2-0 of port 0x10):
///   0: Register hold
///   1: Register shift
///   2: Time set
///   3: Time read — loads current host time into the shift register
///   4-6: (unused)
///   7: Extended command (uPD4990A only, stub)
///
/// Shift register format:
///   [0] = BCD seconds  (tens << 4 | units)
///   [1] = BCD minutes
///   [2] = BCD hours
///   [3] = BCD day
///   [4] = (month << 4) | weekday
///   [5] = BCD year in cmd=7 extended read mode
public final class UPD1990A {

    package struct CurrentTimeState {
        var sec: Int
        var min: Int
        var hour: Int
        var day: Int
        var wday: Int
        var mon: Int
        var year: Int
    }

    // MARK: - Shift Register

    /// Visible byte-oriented view of the 48-bit serial data for tests.
    package var shiftReg: [UInt8] = Array(repeating: 0, count: 7)

    /// Serial shift data, LSB-first like BubiC's `shift_data`.
    private var shiftData: UInt64 = 0

    /// Calendar Data Output — exposed at port 0x40 bit 4.
    public var cdo: Bool = false

    // MARK: - Command State

    /// Command bits from port 0x10 (bits 2-0: C0, C1, C2)
    package var command: UInt8 = 0

    /// Latched mode updated on STB rising edge.
    package var mode: UInt8 = 0

    /// 4-bit extended command shift register for cmd=7 mode.
    package var shiftCommand: UInt8 = 0

    /// Data input line from port 0x10 (bit 3: DIN)
    package var din: Bool = false

    /// Rolling history of shift-register states before each shift-mode clock.
    /// Extended command nibbles are clocked while mode 1 is still latched, but those
    /// four clocks should update only the command register, not the 48-bit time payload.
    private var recentShiftData: [UInt64] = []

    /// Previous port 0x40 value for edge detection
    package var prevCtrl: UInt8 = 0

    /// Offset from host local time after a `time set` command.
    private var timeSetOffsetSeconds: Int?

    /// Injectable time source for deterministic tests.
    /// Default returns the host local time (BubiC-compatible).
    package var timeProvider: () -> (sec: Int, min: Int, hour: Int, day: Int, wday: Int, mon: Int, year: Int) = {
        var t = time(nil)
        var cal = tm()
        localtime_r(&t, &cal)
        return (
            sec: Int(cal.tm_sec),
            min: Int(cal.tm_min),
            hour: Int(cal.tm_hour),
            day: Int(cal.tm_mday),
            wday: Int(cal.tm_wday),
            mon: Int(cal.tm_mon) + 1,
            year: Int(cal.tm_year) % 100
        )
    }

    // MARK: - Init

    public init() {}

    /// Reset to power-on state.
    public func reset() {
        shiftReg = Array(repeating: 0, count: 7)
        shiftData = 0
        cdo = false
        command = 0
        mode = 0
        shiftCommand = 0
        din = false
        recentShiftData.removeAll(keepingCapacity: true)
        prevCtrl = 0
        timeSetOffsetSeconds = nil
    }

    // MARK: - Port I/O

    /// Port 0x10 write: update command bits and data input.
    public func writeCommand(_ value: UInt8) {
        command = value & 0x07      // bits 2-0: C0, C1, C2
        din = (value & 0x08) != 0   // bit 3: DIN
    }

    /// Port 0x40 write: detect raw port edges.
    /// BubiC/XM8 latch STB on raw bit1 falling edge because the chip sees ~data bit1.
    /// CLK still shifts on raw bit2 rising edge.
    public func writeControl(_ value: UInt8) {
        let risingEdge = ~prevCtrl & value
        let prevStb = (~prevCtrl) & 0x02
        let nextStb = (~value) & 0x02

        // STB: chip sees ~data bit1, so the raw port fires on 1 -> 0.
        if prevStb == 0 && nextStb != 0 {
            strobe()
        }

        // CLK: bit 2 rising edge → shift one bit
        if (risingEdge & 0x04) != 0 {
            shiftClock()
        }

        prevCtrl = value
    }

    // MARK: - Internal

    private func strobe() {
        if (mode & 0x0F) == 1, command == 7, recentShiftData.count == 4 {
            shiftData = recentShiftData[0]
            syncShiftRegFromShiftData()
            cdo = (shiftData & 0x01) != 0
        }
        recentShiftData.removeAll(keepingCapacity: true)
        mode = command == 7 ? (shiftCommand | 0x80) : command

        switch mode & 0x0F {
        case 2:
            applyTimeSet()
        case 3:
            shiftData = buildCurrentTimeShiftData(extended: (mode & 0x80) != 0)
            syncShiftRegFromShiftData()
            cdo = (shiftData & 0x01) != 0
        default:
            break
        }
    }

    private func shiftClock() {
        shiftCommand = (shiftCommand >> 1) | (din ? 0x08 : 0x00)

        guard (mode & 0x0F) == 1 else { return }

        if recentShiftData.count == 4 {
            recentShiftData.removeFirst()
        }
        recentShiftData.append(shiftData)

        shiftData >>= 1
        if din {
            let width = 48
            shiftData |= UInt64(1) << (width - 1)
        }
        syncShiftRegFromShiftData()
        cdo = (shiftData & 0x01) != 0
    }

    private func buildCurrentTimeShiftData(extended: Bool) -> UInt64 {
        let t = currentTimeState()
        let bytes: [UInt8]
        if extended {
            bytes = [
                bcd(t.sec),
                bcd(t.min),
                bcd(t.hour),
                bcd(t.day),
                UInt8(t.mon & 0x0F) << 4 | UInt8(t.wday & 0x0F),
                bcd(t.year)
            ]
        } else {
            bytes = [
                bcd(t.sec),
                bcd(t.min),
                bcd(t.hour),
                bcd(t.day),
                UInt8(t.mon & 0x0F) << 4 | UInt8(t.wday & 0x0F)
            ]
        }

        var data: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            data |= UInt64(byte) << (index * 8)
        }
        return data
    }

    private func applyTimeSet() {
        let host = hostTimeState()
        let target = decodeTimeStateFromShiftData(defaultYear: host.year)
        guard let hostDate = date(from: host),
              let targetDate = date(from: target) else {
            return
        }

        timeSetOffsetSeconds = Int(targetDate.timeIntervalSince(hostDate).rounded())
    }

    private func hostTimeState() -> CurrentTimeState {
        let t = timeProvider()
        return CurrentTimeState(
            sec: t.sec,
            min: t.min,
            hour: t.hour,
            day: t.day,
            wday: t.wday,
            mon: t.mon,
            year: t.year
        )
    }

    private func currentTimeState() -> CurrentTimeState {
        let host = hostTimeState()
        guard let offset = timeSetOffsetSeconds,
              let hostDate = date(from: host) else {
            return host
        }

        let adjusted = hostDate.addingTimeInterval(TimeInterval(offset))
        return timeState(from: adjusted, fallbackYear: host.year)
    }

    private func decodeTimeStateFromShiftData(defaultYear: Int) -> CurrentTimeState {
        let sec = bcdDecode(UInt8(shiftData & 0xFF))
        let min = bcdDecode(UInt8((shiftData >> 8) & 0xFF))
        let hour = bcdDecode(UInt8((shiftData >> 16) & 0xFF))
        let day = bcdDecode(UInt8((shiftData >> 24) & 0xFF))
        let monthWeekday = UInt8((shiftData >> 32) & 0xFF)
        let yearByte = UInt8((shiftData >> 40) & 0xFF)
        let year = yearByte == 0 ? defaultYear : bcdDecode(yearByte)

        return CurrentTimeState(
            sec: sec,
            min: min,
            hour: hour,
            day: day,
            wday: Int(monthWeekday & 0x0F),
            mon: Int((monthWeekday >> 4) & 0x0F),
            year: year
        )
    }

    private func date(from t: CurrentTimeState) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let currentFullYear = calendar.component(.year, from: Date())
        var fullYear = (currentFullYear / 100) * 100 + (t.year % 100)
        if fullYear - currentFullYear > 50 {
            fullYear -= 100
        } else if currentFullYear - fullYear > 50 {
            fullYear += 100
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = fullYear
        components.month = t.mon
        components.day = t.day
        components.hour = t.hour
        components.minute = t.min
        components.second = t.sec
        return calendar.date(from: components)
    }

    private func timeState(from date: Date, fallbackYear: Int) -> CurrentTimeState {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.second, .minute, .hour, .day, .weekday, .month, .year],
            from: date
        )

        return CurrentTimeState(
            sec: components.second ?? 0,
            min: components.minute ?? 0,
            hour: components.hour ?? 0,
            day: components.day ?? 1,
            wday: weekdayToRtc(Int(components.weekday ?? 1)),
            mon: components.month ?? 1,
            year: ((components.year ?? (2000 + fallbackYear)) % 100 + 100) % 100
        )
    }

    private func syncShiftRegFromShiftData() {
        for index in 0..<6 {
            shiftReg[index] = UInt8((shiftData >> (index * 8)) & 0xFF)
        }
        shiftReg[6] = 0
    }

    @inline(__always)
    private func bcd(_ value: Int) -> UInt8 {
        UInt8(((value / 10) << 4) | (value % 10))
    }

    @inline(__always)
    private func bcdDecode(_ value: UInt8) -> Int {
        Int((value >> 4) & 0x0F) * 10 + Int(value & 0x0F)
    }

    @inline(__always)
    private func weekdayToRtc(_ calendarWeekday: Int) -> Int {
        (calendarWeekday + 6) % 7
    }
}
