// VGMLogger.swift — logs YM2608 register writes as a VGM 1.51 stream.

import FMSynthesis

/// Records what the CPU writes to the OPNA as a VGM file: register writes
/// separated by waits counted in 44.1kHz samples of emulated time.
///
/// Time comes from the machine's T-state counter, not the host clock, so a
/// recording made at x2 speed or across a pause plays back at real speed and
/// skips the pause.
///
/// Recording starts mid-song, so `init` first writes the chip's current state:
/// the ADPCM RAM as a data block, then every register a player needs to
/// reproduce the current voices. Key-on state is not restored — the register
/// file keeps no record of which operators are keyed — so a note already
/// sounding when recording starts is silent until its next key-on.
///
/// The beeper and SING (port 0x40) have no VGM representation and are not
/// recorded.
package final class VGMLogger {

  /// The YM2608 clock VGM stores: the chip's input clock, twice the OPNA's
  /// internal 3,993,624Hz. `YM2608.configureStandaloneClock(_:)` takes the
  /// same value.
  package static let chipClock: UInt32 = UInt32(YM2608.baseCpuClockHz8MHz)

  static let sampleRate: UInt64 = 44_100
  static let headerSize = 0x80
  static let adpcmMemorySize = 0x40000

  /// Command bytes after the header, without the end marker.
  private var commands: [UInt8] = []
  private var lastTState: UInt64
  /// Fraction of a sample carried between writes, in 1/`remainderHz` samples.
  private var remainder: UInt64 = 0
  private var remainderHz: UInt64
  private var pendingSamples: UInt64 = 0
  private var totalSamples: UInt64 = 0
  /// CH3 mode bits (register 0x27 bits 6–7) the player last received.
  private var timerMode: UInt8 = 0

  /// T-states per second for the CPU clock the machine is running at.
  package static func cpuClockHz(eightMHz: Bool) -> Int {
    eightMHz ? YM2608.baseCpuClockHz8MHz : YM2608.baseCpuClockHz4MHz
  }

  /// Start a log at `tState` with the chip's current state.
  package init(chip: YM2608, tState: UInt64, cpuClockHz: Int) {
    lastTState = tState
    remainderHz = UInt64(cpuClockHz)
    writeADPCM(chip.adpcmRAM, previous: nil)
    writeRegisters(of: chip)
  }

  /// Log a data write the CPU made to the chip. `secondary` is the second
  /// register bank (ports 0x46/0x47: FM ch4–6 and ADPCM).
  package func log(secondary: Bool, register: UInt8, value: UInt8,
                   tState: UInt64, cpuClockHz: Int) {
    var value = value
    if !secondary {
      switch register {
      // SSG I/O ports (joystick) and timer values: not sound.
      case 0x0E, 0x0F, 0x24, 0x25, 0x26:
        return
      // Timer control: only the CH3 mode bits affect sound, and games
      // rewrite this register on every timer interrupt.
      case 0x27:
        let mode = value & 0xC0
        guard mode != timerMode else { return }
        timerMode = mode
        value = mode
      default:
        break
      }
    }
    advance(to: tState, cpuClockHz: cpuClockHz)
    emitWrite(secondary: secondary, register: register, value: value)
  }

  /// Count the time up to `tState` at `cpuClockHz` without writing anything.
  /// Call it before the T-state counter jumps or the clock changes, so the
  /// time since the last write is kept and measured at the rate it ran at.
  package func catchUp(to tState: UInt64, cpuClockHz: Int) {
    advance(to: tState, cpuClockHz: cpuClockHz)
  }

  /// Rewrite the chip state after the machine's time jumped: a reset or a
  /// state load. `catchUp` to the moment before the jump first. The log continues without a wait; `previousADPCM` is the
  /// ADPCM RAM before the jump, which the player already holds, so only the
  /// range that changed is written again.
  package func resync(chip: YM2608, previousADPCM: [UInt8],
                      tState: UInt64, cpuClockHz: Int) {
    lastTState = tState
    remainder = 0
    remainderHz = UInt64(cpuClockHz)
    flushWait()
    writeADPCM(chip.adpcmRAM, previous: previousADPCM)
    writeRegisters(of: chip)
  }

  /// End the log at `tState` and return the complete VGM file.
  /// `gameName` goes into the GD3 tag.
  package func finish(tState: UInt64, cpuClockHz: Int, gameName: String) -> [UInt8] {
    advance(to: tState, cpuClockHz: cpuClockHz)
    flushWait()

    let gd3 = Self.gd3(gameName: gameName)
    let gd3Start = Self.headerSize + commands.count + 1
    let fileSize = gd3Start + gd3.count

    var header = [UInt8](repeating: 0, count: Self.headerSize)
    func put(_ value: UInt32, at offset: Int) {
      for i in 0..<4 { header[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    put(0x206D_6756, at: 0x00)                               // "Vgm "
    put(UInt32(fileSize - 0x04), at: 0x04)                   // EoF offset
    put(0x151, at: 0x08)                                     // version 1.51
    put(UInt32(gd3Start - 0x14), at: 0x14)                   // GD3 offset
    put(UInt32(truncatingIfNeeded: totalSamples), at: 0x18)  // total samples
    put(UInt32(Self.headerSize - 0x34), at: 0x34)            // data offset
    put(Self.chipClock, at: 0x48)                            // YM2608 clock

    return header + commands + [0x66] + gd3
  }

  // MARK: - Time

  private func advance(to tState: UInt64, cpuClockHz: Int) {
    let hz = UInt64(cpuClockHz)
    if hz != remainderHz {
      remainder = remainder * hz / remainderHz
      remainderHz = hz
    }
    let delta = tState > lastTState ? tState - lastTState : 0
    lastTState = tState
    let accumulated = delta * Self.sampleRate + remainder
    pendingSamples += accumulated / hz
    remainder = accumulated % hz
  }

  private func flushWait() {
    totalSamples += pendingSamples
    while pendingSamples > 0 {
      let n = pendingSamples
      switch n {
      case 735:
        commands.append(0x62)
      case 882:
        commands.append(0x63)
      case 1...16:
        commands.append(0x70 + UInt8(n - 1))
      default:
        let chunk = min(n, 0xFFFF)
        commands += [0x61, UInt8(chunk & 0xFF), UInt8(chunk >> 8)]
        pendingSamples -= chunk
        continue
      }
      pendingSamples = 0
    }
  }

  // MARK: - Commands

  private func emitWrite(secondary: Bool, register: UInt8, value: UInt8) {
    flushWait()
    commands += [secondary ? 0x57 : 0x56, register, value]
  }

  /// Write a YM2608 DELTA-T memory data block (type 0x81) for the bytes of
  /// `ram` that differ from `previous`, or for all of it up to the last
  /// non-zero byte when there is no previous content.
  private func writeADPCM(_ ram: [UInt8], previous: [UInt8]?) {
    let range: Range<Int>
    if let previous, previous.count == ram.count {
      guard let first = ram.indices.first(where: { ram[$0] != previous[$0] }),
            let last = ram.indices.last(where: { ram[$0] != previous[$0] }) else { return }
      range = first..<(last + 1)
    } else {
      guard let last = ram.lastIndex(where: { $0 != 0 }) else { return }
      range = 0..<(last + 1)
    }
    func u32(_ v: Int) -> [UInt8] {
      (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }
    commands += [0x67, 0x66, 0x81]
    commands += u32(range.count + 8)
    commands += u32(Self.adpcmMemorySize)
    commands += u32(range.lowerBound)
    commands += ram[range]
  }

  /// Write every register a player needs to reproduce the chip's voices.
  /// Key-on (0x28), rhythm key-on (0x10), the ADPCM control and data
  /// registers (0x100, 0x108) and the timers are left out: writing them would
  /// start sounds or uploads the chip is not making.
  private func writeRegisters(of chip: YM2608) {
    func emit(secondary: Bool, _ r: Int) {
      emitWrite(secondary: secondary, register: UInt8(r),
                value: chip.effectiveRegister(secondary: secondary, UInt8(r)))
    }

    emit(secondary: false, 0x29)
    timerMode = chip.registers[0x27] & 0xC0
    emitWrite(secondary: false, register: 0x27, value: timerMode)
    for r in Array(0x00...0x0D) + Array(0x11...0x1D) + [0x22] {
      emit(secondary: false, r)
    }

    for isSecondary in [false, true] {
      // The F-number high byte (0xA4–) latches until the low byte (0xA0–) is
      // written, so it goes first.
      var order = Array(0x30...0x9F) + Array(0xA4...0xA6) + Array(0xA0...0xA2)
      if !isSecondary {
        order += Array(0xAC...0xAE) + Array(0xA8...0xAA)  // CH3 special mode
      }
      order += Array(0xB0...0xB2) + Array(0xB4...0xB6)
      for r in order where r & 0x03 != 0x03 {
        emit(secondary: isSecondary, r)
      }
    }

    for r in Array(0x01...0x07) + Array(0x09...0x0D) {
      emit(secondary: true, r)
    }
  }

  // MARK: - GD3

  private static func gd3(gameName: String) -> [UInt8] {
    // Track (en, jp), game (en, jp), system (en, jp), author (en, jp),
    // release date, ripper, notes.
    let fields = ["", "", gameName, gameName, "NEC PC-8801", "NEC PC-8801",
                  "", "", "", "Bubilator88", ""]
    var text: [UInt8] = []
    for field in fields {
      for unit in field.utf16 + [0] {
        text += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
      }
    }
    var out: [UInt8] = [0x47, 0x64, 0x33, 0x20, 0x00, 0x01, 0x00, 0x00]  // "Gd3 ", 1.00
    out += (0..<4).map { UInt8(truncatingIfNeeded: text.count >> (8 * $0)) }
    return out + text
  }
}
