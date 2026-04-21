import Foundation
import EmulatorCore
import Logging

setbuf(stdout, nil)  // Disable stdout buffering for diagnostics
LoggingSystem.bootstrap(StreamLogHandler.standardError)

let appSupport = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
).first!.appendingPathComponent("Bubilator88")

let bootArgs = Array(CommandLine.arguments.dropFirst())
let requestedDiskPath: String? = {
    guard !bootArgs.isEmpty else { return nil }
    if bootArgs[0] == "--help" || bootArgs[0] == "-h" {
        print("Usage: swift run BootTester [disk.d88]")
        exit(0)
    }
    return bootArgs[0]
}()

let diskBootFrames: Int = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_FRAMES"] ?? ""
    if let value = Int(raw), value > 0 {
        return value
    }
    return 60
}()

let useRunFrame: Bool = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_USE_RUNFRAME"] ?? ""
    return raw == "1"
}()

/// Turbo multiplier: run N internal `runFrame()` calls per logical frame,
/// mirroring the app's CPUSpeed x2/x4/x8/x16 behavior. Key events still fire
/// on the logical frame boundary. Defaults to 1 (no turbo). Only honored
/// when `BOOTTEST_USE_RUNFRAME=1`, because the granular tick path is
/// instrumented per-instruction and wouldn't benefit from the multiplier
/// without also multiplying all internal counters.
let turboMultiplier: Int = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_TURBO"] ?? ""
    if let value = Int(raw), value >= 1 { return value }
    return 1
}()

let ignoreCrashHeuristics: Bool = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_IGNORE_CRASH"] ?? ""
    return raw == "1"
}()

let fmTraceEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_FM_TRACE"] ?? ""
    return raw == "1"
}()

let fmTracePath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_FM_TRACE_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let pioFlowPath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_PIO_FLOW_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

/// Per-instruction Z80 trace for cross-emulator diff workflows.
/// Set BOOTTEST_CPU_TRACE_PATH to a file; each line is emitted before an
/// opcode fetches. Column format matches a simple BubiC patch so `diff`
/// between the two logs reveals the first divergent instruction.
/// BOOTTEST_CPU_TRACE_WHICH selects "main" (default) or "sub".
/// BOOTTEST_CPU_TRACE_LIMIT caps lines written (default unlimited).
let cpuTracePath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_CPU_TRACE_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()
let cpuTraceWhich: String = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_CPU_TRACE_WHICH"] ?? "main"
    return raw.lowercased()
}()
let cpuTraceLimit: Int = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_CPU_TRACE_LIMIT"] ?? ""
    return Int(raw) ?? 0
}()

let audioSummaryEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_AUDIO_SUMMARY"] ?? ""
    return raw == "1"
}()

let audioDebugMask: YM2608.DebugOutputMask = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_AUDIO_MASK"] ?? ""
    guard !raw.isEmpty else { return .all }

    var mask: YM2608.DebugOutputMask = []
    for token in raw.split(separator: ",") {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fm":
            mask.insert(.fm)
        case "ssg":
            mask.insert(.ssg)
        case "adpcm":
            mask.insert(.adpcm)
        case "rhythm":
            mask.insert(.rhythm)
        default:
            break
        }
    }
    return mask
}()

func parseHexWordList(from envName: String) -> [UInt16] {
    let raw = ProcessInfo.processInfo.environment[envName] ?? ""
    guard !raw.isEmpty else { return [] }

    return raw
        .split { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" }
        .compactMap { token -> UInt16? in
            let text = String(token)
            let normalized = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
            return UInt16(normalized, radix: 16)
        }
}

let watchedMainRAMAddresses: [UInt16] = parseHexWordList(from: "BOOTTEST_RAM_WATCH")
let watchedPCs: Set<UInt16> = Set(parseHexWordList(from: "BOOTTEST_PC_WATCH"))
let watchedSubPCs: Set<UInt16> = Set(parseHexWordList(from: "BOOTTEST_SUBPC_WATCH"))
let irqTraceEnabled: Bool = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_IRQ_TRACE"] ?? ""
    return raw == "1"
}()

let watchTracePath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_WATCH_TRACE_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let screenshotPath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_SCREENSHOT_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let screenshotDir: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_SCREENSHOT_DIR"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let screenshotInterval: Int = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_SCREENSHOT_INTERVAL"] ?? ""
    if let value = Int(raw), value > 0 {
        return value
    }
    return 0  // 0 = disabled
}()

let screenshotBaseName: String = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_SCREENSHOT_BASENAME"] ?? ""
    return raw.isEmpty ? "frame" : raw
}()

enum BootTestKeyAction {
    case press
    case release
    case tap
}

struct BootTestKeyFrameEvent {
    let frame: Int
    let key: Keyboard.Key
    let action: BootTestKeyAction
    let keyName: String
}

let bootTestKeyMap: [String: Keyboard.Key] = [
    "return": Keyboard.kpReturn,
    "enter": Keyboard.kpReturn,
    "space": Keyboard.space,
    "esc": Keyboard.esc,
    "escape": Keyboard.esc,
    "up": Keyboard.up,
    "down": Keyboard.down,
    "left": Keyboard.left,
    "right": Keyboard.right,
    "stop": Keyboard.stop,
    "tab": Keyboard.tab,
    "help": Keyboard.help,
    "copy": Keyboard.copy,
    "shift": Keyboard.shift,
    "ctrl": Keyboard.ctrl,
    "grph": Keyboard.grph,
    "kana": Keyboard.kana,
    "0": Keyboard.key0,
    "1": Keyboard.key1,
    "2": Keyboard.key2,
    "3": Keyboard.key3,
    "4": Keyboard.key4,
    "5": Keyboard.key5,
    "6": Keyboard.key6,
    "7": Keyboard.key7,
    "8": Keyboard.key8,
    "9": Keyboard.key9,
    "f1": Keyboard.f1,
    "f2": Keyboard.f2,
    "f3": Keyboard.f3,
    "f4": Keyboard.f4,
    "f5": Keyboard.f5,
    "f6": Keyboard.f6,
    "f7": Keyboard.f7,
    "f8": Keyboard.f8,
    "f9": Keyboard.f9,
    "f10": Keyboard.f10,
    // A-Z — letters must be lowercased by parseBootTestKey before lookup
    "a": Keyboard.a, "b": Keyboard.b, "c": Keyboard.c, "d": Keyboard.d,
    "e": Keyboard.e, "f": Keyboard.f, "g": Keyboard.g, "h": Keyboard.h,
    "i": Keyboard.i, "j": Keyboard.j, "k": Keyboard.k, "l": Keyboard.l,
    "m": Keyboard.m, "n": Keyboard.n, "o": Keyboard.o, "p": Keyboard.p,
    "q": Keyboard.q, "r": Keyboard.r, "s": Keyboard.s, "t": Keyboard.t,
    "u": Keyboard.u, "v": Keyboard.v, "w": Keyboard.w, "x": Keyboard.x,
    "y": Keyboard.y, "z": Keyboard.z,
    // Symbols (ASCII names)
    "at": Keyboard.at,
    "leftbracket": Keyboard.leftBracket,
    "rightbracket": Keyboard.rightBracket,
    "yen": Keyboard.yen,
    "caret": Keyboard.caret,
    "minus": Keyboard.minus,
    "colon": Keyboard.colon,
    "semicolon": Keyboard.semicolon,
    "comma": Keyboard.comma,
    "period": Keyboard.period,
    "slash": Keyboard.slash,
    "underscore": Keyboard.underscore,
    // Numpad (kp* = keypad)
    "kp0": Keyboard.kp0, "kp1": Keyboard.kp1, "kp2": Keyboard.kp2,
    "kp3": Keyboard.kp3, "kp4": Keyboard.kp4, "kp5": Keyboard.kp5,
    "kp6": Keyboard.kp6, "kp7": Keyboard.kp7, "kp8": Keyboard.kp8,
    "kp9": Keyboard.kp9,
    "kpreturn": Keyboard.kpReturn,
    "kpenter":  Keyboard.kpReturn,
    "kpplus":   Keyboard.kpPlus,
    "kpminus":  Keyboard.kpMinus,
    "kpmultiply": Keyboard.kpMultiply,
    "kpdivide":   Keyboard.kpDivide,
    "kpequal":    Keyboard.kpEqual,
    "kpcomma":    Keyboard.kpComma,
    "kpperiod":   Keyboard.kpPeriod,
    // Other
    "clr":  Keyboard.clr,
    "del":  Keyboard.del,
    "bs":   Keyboard.bs,
    "ins":  Keyboard.ins,
    "del2": Keyboard.del2,
    "capslock": Keyboard.capsLock,
    "rollup":   Keyboard.rollUp,
    "rolldown": Keyboard.rollDown,
    "henkan":   Keyboard.henkan,
    "kettei":   Keyboard.kettei,
    "pc":       Keyboard.pc,
    "zenkaku":  Keyboard.zenkaku,
]

func parseBootTestKey(_ token: String) -> Keyboard.Key? {
    if let mapped = bootTestKeyMap[token.lowercased()] {
        return mapped
    }

    let parts = token.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }

    func parseInt(_ raw: String) -> Int? {
        if raw.lowercased().hasPrefix("0x") {
            return Int(raw.dropFirst(2), radix: 16)
        }
        return Int(raw)
    }

    guard let row = parseInt(parts[0]),
          let bit = parseInt(parts[1]),
          row >= 0, row < 15,
          bit >= 0, bit < 8 else {
        return nil
    }
    return Keyboard.Key(row, bit)
}

func parseBootTestKeyEvents(from envName: String) -> [BootTestKeyFrameEvent] {
    let raw = ProcessInfo.processInfo.environment[envName] ?? ""
    guard !raw.isEmpty else { return [] }

    return raw.split(separator: ",").compactMap { eventSpec in
        let parts = eventSpec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              let frame = Int(parts[0]), frame >= 0,
              let key = parseBootTestKey(parts[1]) else {
            return nil
        }

        let actionToken = parts.count >= 3 ? parts[2].lowercased() : "tap"
        let action: BootTestKeyAction
        switch actionToken {
        case "press", "down":
            action = .press
        case "release", "up":
            action = .release
        case "tap":
            action = .tap
        default:
            return nil
        }

        return BootTestKeyFrameEvent(
            frame: frame,
            key: key,
            action: action,
            keyName: parts[1]
        )
    }
}

let scriptedKeyEventsByFrame: [Int: [BootTestKeyFrameEvent]] = Dictionary(
    grouping: parseBootTestKeyEvents(from: "BOOTTEST_KEY_EVENTS"),
    by: \.frame
)

struct MemoryDumpRegion {
    let start: UInt16
    let length: Int
}

func parseMemoryDumpRegions(from envName: String) -> [MemoryDumpRegion] {
    let raw = ProcessInfo.processInfo.environment[envName] ?? ""
    guard !raw.isEmpty else { return [] }

    return raw
        .split(separator: ",")
        .compactMap { region in
            let parts = region.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let startText = parts[0].lowercased().hasPrefix("0x") ? String(parts[0].dropFirst(2)) : parts[0]
            let lengthText = parts[1].lowercased().hasPrefix("0x") ? String(parts[1].dropFirst(2)) : parts[1]
            guard let start = UInt16(startText, radix: 16),
                  let length = Int(lengthText, radix: 16),
                  length > 0 else {
                return nil
            }
            return MemoryDumpRegion(start: start, length: length)
        }
}

let mainRAMDumpRegions: [MemoryDumpRegion] = parseMemoryDumpRegions(from: "BOOTTEST_MAINRAM_DUMP")
let subRAMDumpRegions: [MemoryDumpRegion] = parseMemoryDumpRegions(from: "BOOTTEST_SUBRAM_DUMP")

/// Destination directory for a full cross-emulator memory dump at the end of
/// the run. See docs/MEMORY_DUMP_FORMAT.md and MemoryDump.write().
let memoryDumpDirectory: String? = ProcessInfo.processInfo.environment["BOOTTEST_MEMORY_DUMP_DIR"]

func formatWatchedRAM(_ machine: Machine, addresses: [UInt16]) -> String {
    guard !addresses.isEmpty else { return "" }
    return addresses
        .map { addr in
            String(format: "%04X=%02X", addr, machine.bus.mainRAM[Int(addr)])
        }
        .joined(separator: " ")
}

func bootTestAttributeGraphAttributes(
    from attrData: [UInt8],
    textDisplayMode: Pc88Bus.TextDisplayMode,
    textRows: Int,
    reverseDisplay: Bool
) -> [UInt8] {
    guard textDisplayMode == .disabled else { return attrData }
    let defaultAttr: UInt8 = 0xE0 | (reverseDisplay ? 0x01 : 0x00)
    return Array(
        repeating: defaultAttr,
        count: max(textRows, 1) * ScreenRenderer.textCols80
    )
}

func renderCurrentFrame(machine: Machine) -> [UInt8] {
    let renderer = ScreenRenderer()
    let palette = ScreenRenderer.expandPalette(machine.bus.palette)
    let planes = machine.bus.renderGVRAMPlanes()
    let is400 = machine.bus.is400LineMode
    let textData = machine.bus.readTextVRAM()
    let attrData = machine.bus.readTextAttributes()
    let attributeGraphAttrData = bootTestAttributeGraphAttributes(
        from: attrData,
        textDisplayMode: machine.bus.textDisplayMode,
        textRows: Int(machine.crtc.linesPerScreen),
        reverseDisplay: machine.crtc.reverseDisplay
    )
    let crtcLines = Int(machine.crtc.linesPerScreen)
    var pixelBuffer = Array(repeating: UInt8(0), count: ScreenRenderer.bufferSize400)

    if machine.bus.graphicsColorMode {
        renderer.renderDoubled(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            greenVRAM: planes.green,
            palette: palette,
            into: &pixelBuffer
        )
    } else if is400 {
        renderer.renderAttributeGraph400(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            attrData: attributeGraphAttrData,
            palette: palette,
            columns80: machine.bus.columns80,
            textRows: crtcLines,
            into: &pixelBuffer
        )
    } else {
        renderer.renderAttributeGraph200(
            blueVRAM: planes.blue,
            redVRAM: planes.red,
            greenVRAM: planes.green,
            attrData: attributeGraphAttrData,
            palette: palette,
            columns80: machine.bus.columns80,
            textRows: crtcLines,
            into: &pixelBuffer
        )
    }

    renderer.renderTextOverlay(
        textData: textData,
        attrData: attrData,
        fontROM: machine.fontROM,
        palette: palette,
        displayEnabled: machine.bus.textDisplayEnabled,
        columns80: machine.bus.columns80,
        colorMode: machine.bus.colorMode,
        // Fix exective.d88 menu white-out: in attribute-graphics mode,
        // reverse cells must punch glyphs with palette 0 and let the
        // graphics renderer invert the cell. Matches the app-side fix
        // (commit 4ad0578b, EmulatorViewModel+Rendering.swift).
        attributeGraphMode: machine.bus.graphicsDisplayEnabled && !machine.bus.graphicsColorMode,
        textRows: crtcLines,
        cursorX: machine.crtc.cursorX,
        cursorY: machine.crtc.cursorY,
        cursorVisible: machine.crtc.cursorEnabled,
        cursorBlock: (machine.crtc.cursorMode & 0x02) != 0,
        hireso: true,
        skipLine: machine.crtc.skipLine,
        into: &pixelBuffer
    )

    return pixelBuffer
}

func writePPMScreenshot(path: String, pixels: [UInt8]) throws {
    var data = Data("P6\n\(ScreenRenderer.width) \(ScreenRenderer.height400)\n255\n".utf8)
    data.reserveCapacity(data.count + ScreenRenderer.width * ScreenRenderer.height400 * 3)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        data.append(pixels[offset])
        data.append(pixels[offset + 1])
        data.append(pixels[offset + 2])
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

#if DEBUG
let textDMASnapshotPath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_TEXT_DMA_SNAPSHOT_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let textDMASnapshotFrame: Int? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_SNAPSHOT_FRAME"] ?? ""
    guard let value = Int(raw), value >= 0 else { return nil }
    return value
}()

nonisolated(unsafe) var textDMASnapshotWritten = false

func dumpTextDMASnapshotIfRequested(machine: Machine, frame: Int, label: String, force: Bool = false) {
    guard let textDMASnapshotPath, !textDMASnapshotWritten else { return }
    if !force {
        guard let textDMASnapshotFrame else { return }
        guard frame == textDMASnapshotFrame else { return }
    }

    let report = machine.bus.textDMADebugSnapshot().debugReport()
    let payload = """
    === BootTester Snapshot ===
    label: \(label)
    frame: \(frame)
    \(report)
    """

    do {
        try payload.write(toFile: textDMASnapshotPath, atomically: true, encoding: .utf8)
        textDMASnapshotWritten = true
        print("  Text DMA snapshot written to \(textDMASnapshotPath) at frame \(frame)")
    } catch {
        print("  FAILED to write Text DMA snapshot to \(textDMASnapshotPath): \(error)")
    }
}
#endif

guard let romData = try? Data(contentsOf: appSupport.appendingPathComponent("N88.ROM")) else {
    print("N88.ROM not found"); exit(1)
}

/// BOOTTEST_VIRTUAL_RTC=1 のとき、RTC を「emulated 時間ベース」で進める。
/// BootTester は wall-clock より速く (ターボ時は尚更) フレームを回すため、
/// host 時刻を参照する既定の RTC は相対的に止まって見える。RTC 経過を
/// 当てにして画面遷移するゲーム (例: SB2 Music Disk v4) は、これで
/// ゲーム視点の「秒」が正しく進むようになる。
func maybeInstallVirtualRTC(machine: Machine) {
    guard ProcessInfo.processInfo.environment["BOOTTEST_VIRTUAL_RTC"] == "1" else { return }
    // 固定の仮想開始日時: 2025-01-01 00:00:00 (水曜)
    let baseYear = 125   // 1900 起算
    let baseMon  = 1     // 1-12 で返す
    let baseDay  = 1
    let baseWday = 3     // 0=Sunday; 2025-01-01 = Wed
    machine.calendar.timeProvider = { [unowned machine] in
        let rate: UInt64 = machine.clock8MHz ? 8_000_000 : 4_000_000
        let elapsed = Int(machine.totalTStates / rate)
        let sec  = elapsed % 60
        let minT = elapsed / 60
        let min  = minT % 60
        let hrT  = minT / 60
        let hour = hrT % 24
        let dayOffset = hrT / 24
        // 分〜時間単位の検証しかしないので day/mon は粗く扱う。
        return (
            sec: sec,
            min: min,
            hour: hour,
            day: baseDay + dayOffset,
            wday: baseWday,
            mon: baseMon,
            year: baseYear % 100
        )
    }
}

func setupMachine(dipSw1: UInt8 = 0xC3, dipSw2: UInt8 = 0x79) -> Machine {
    let machine = Machine()
    machine.reset()
    machine.sound.debugOutputMask = audioDebugMask
    // Honor BOOTTEST_DIPSW1 / BOOTTEST_DIPSW2 even in the cold-boot path so
    // callers can select N/N88 and V1/V2/V1S/V1H without going through the
    // disk-boot flow.
    func dipSwOverride(_ envName: String, fallback: UInt8) -> UInt8 {
        guard let raw = ProcessInfo.processInfo.environment[envName], !raw.isEmpty else { return fallback }
        let s = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
        if let v = UInt8(s, radix: 16) { return v }
        if let v = UInt8(raw) { return v }
        return fallback
    }
    machine.bus.dipSw1 = dipSwOverride("BOOTTEST_DIPSW1", fallback: dipSw1)
    machine.bus.dipSw2 = dipSwOverride("BOOTTEST_DIPSW2", fallback: dipSw2)
    machine.loadN88BasicROM(Array(romData))
    if let data = try? Data(contentsOf: appSupport.appendingPathComponent("N80.ROM")) {
        machine.loadNBasicROM(Array(data))
    }
    if let data = try? Data(contentsOf: appSupport.appendingPathComponent("FONT.ROM")) {
        machine.loadFontROM(Array(data))
    }
    if let data = try? Data(contentsOf: appSupport.appendingPathComponent("DISK.ROM")) {
        machine.loadDiskROM(Array(data))
    }
    if let data = try? Data(contentsOf: appSupport.appendingPathComponent("KANJI1.ROM")) {
        machine.loadKanjiROM1(Array(data))
    }
    if let data = try? Data(contentsOf: appSupport.appendingPathComponent("KANJI2.ROM")) {
        machine.loadKanjiROM2(Array(data))
    }
    for bank in 0..<4 {
        let primary = appSupport.appendingPathComponent("N88_\(bank).ROM")
        let alt = appSupport.appendingPathComponent("N88EXT\(bank).ROM")
        if let data = try? Data(contentsOf: primary) {
            machine.loadN88ExtROM(bank: bank, data: Array(data))
        } else if let data = try? Data(contentsOf: alt) {
            machine.loadN88ExtROM(bank: bank, data: Array(data))
        }
    }
    machine.installExtRAM()
    machine.clock8MHz = (ProcessInfo.processInfo.environment["CLOCK_4MHZ"] == nil)
    if ProcessInfo.processInfo.environment["BOOTTEST_FORCE_OPN"] != nil {
        machine.sound.forceOPNMode = true
    }
    if let tapePath = ProcessInfo.processInfo.environment["BOOTTEST_TAPE_PATH"],
       !tapePath.isEmpty,
       let tapeData = try? Data(contentsOf: URL(fileURLWithPath: tapePath)) {
        let fmt = machine.mountTape(data: tapeData)
        if let s = ProcessInfo.processInfo.environment["BOOTTEST_CMT_BYTE_PERIOD"],
           let v = Int(s), v > 0 {
            machine.cassette.bytePeriodTStates = v
        }
        if let s = ProcessInfo.processInfo.environment["BOOTTEST_CMT_PRIME_DELAY"],
           let v = Int(s), v >= 0 {
            machine.cassette.primeDelayTStates = v
        }
        print("  Tape mounted: \(tapePath) (\(fmt == .t88 ? "T88" : "CMT"), buffer \(machine.cassette.buffer.count) bytes, carriers \(machine.cassette.dataCarriers.count), bytePeriod=\(machine.cassette.bytePeriodTStates), primeDelay=\(machine.cassette.primeDelayTStates))")
    }
    maybeInstallVirtualRTC(machine: machine)
    return machine
}

// ============================================================
// Cold boot with "0" + Return keyboard input
// ============================================================
print("=== N88-BASIC cold boot: '0' + Return ===")
let m = setupMachine()
m.bus.directBasicBoot = ProcessInfo.processInfo.environment["BOOTTEST_DIRECT_BASIC"] == "1"

print("  Sub-CPU mode: \(m.subSystem.useLegacyMode ? "legacy" : "Z80")")
print(String(format: "  DISK.ROM[0..3]: %02X %02X %02X %02X",
      m.subSystem.subBus.romram[0], m.subSystem.subBus.romram[1],
      m.subSystem.subBus.romram[2], m.subSystem.subBus.romram[3]))

// PC-8801 keyboard matrix:
//   "0" = row 6, bit 0 (Keyboard.key0)
//   Return = row 1, bit 7 (Keyboard.kpReturn)
var readyCount = 0
var firstREADYFrame = -1
var howManyFilesFrame = -1
var coldBootStart = CFAbsoluteTimeGetCurrent()

let coldBootLoopFrames = (ProcessInfo.processInfo.environment["BOOTTEST_TAPE_PATH"] != nil) ? diskBootFrames : 120
struct HeldKey { let row: Int; let bit: Int }
var tapeHeldKeyReleaseFrame: [Int: [HeldKey]] = [:]
if ProcessInfo.processInfo.environment["BOOTTEST_COLDBOOT_PORT_LOG"] == "1" {
    m.bus.onIOAccess = { [weak m] port, value, isWrite in
        guard isWrite else { return }
        switch port {
        case 0x20, 0x21, 0x30, 0x31, 0x32, 0x40:
            print(String(format: "  PORT W %02X=%02X PC=%04X", port, value, m?.cpu.pc ?? 0))
        default: break
        }
    }
}

// Counter mode: tally reads/writes to cassette-related ports, and
// histogram the values observed on port 0x40 reads (to see which bits
// BASIC is actually sampling). Use a class so the closure captures by
// reference.
final class CmtPortStats {
    var stats: [UInt8: (reads: Int, writes: Int)] = [:]
    var port40ReadValues: [UInt8: Int] = [:]
    func record(port: UInt8, value: UInt8, isWrite: Bool) {
        let cur = stats[port] ?? (reads: 0, writes: 0)
        if isWrite {
            stats[port] = (cur.reads, cur.writes + 1)
        } else {
            stats[port] = (cur.reads + 1, cur.writes)
            if port == 0x40 {
                port40ReadValues[value, default: 0] += 1
            }
        }
    }
}
let cmtStats = CmtPortStats()
if ProcessInfo.processInfo.environment["BOOTTEST_CMT_PORT_STATS"] == "1" {
    let existing = m.bus.onIOAccess
    m.bus.onIOAccess = { port, value, isWrite in
        existing?(port, value, isWrite)
        let p8 = UInt8(port & 0xFF)
        switch p8 {
        case 0x20, 0x21, 0x30, 0x40:
            cmtStats.record(port: p8, value: value, isWrite: isWrite)
        default: break
        }
    }
}

for frame in 0..<coldBootLoopFrames {
    let subBefore = m.subSystem.subCpuTStates

    // Scripted key events (shared with the disk-boot path). Taps are
    // released two frames after press. Used to type e.g. CLOAD + RETURN
    // + RUN + RETURN after N88-BASIC cold boot completes.
    if let events = scriptedKeyEventsByFrame[frame] {
        for event in events {
            switch event.action {
            case .press:
                m.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
            case .release:
                m.keyboard.releaseKey(row: event.key.row, bit: event.key.bit)
            case .tap:
                m.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
                tapeHeldKeyReleaseFrame[frame + 2, default: []].append(HeldKey(row: event.key.row, bit: event.key.bit))
            }
            print("  Key event frame \(frame): \(event.keyName)")
        }
    }
    if let toRelease = tapeHeldKeyReleaseFrame.removeValue(forKey: frame) {
        for r in toRelease { m.keyboard.releaseKey(row: r.row, bit: r.bit) }
    }

    // Detect "How many files?" in text VRAM (scan once per frame)
    if howManyFilesFrame < 0 {
        let td = m.bus.readTextVRAM()
        // Check for "How" at start of some row
        for row in 0..<25 {
            let base = row * 80
            if base + 3 < td.count && td[base] == 0x48 && td[base+1] == 0x6F && td[base+2] == 0x77 {
                howManyFilesFrame = frame
                print("  'How many files?' appeared at frame \(frame)")
                break
            }
        }
    }

    // Send "0" two frames after prompt appears
    if howManyFilesFrame >= 0 && frame == howManyFilesFrame + 2 {
        m.keyboard.pressKey(row: 6, bit: 0)  // "0"
    }
    if howManyFilesFrame >= 0 && frame == howManyFilesFrame + 4 {
        m.keyboard.releaseKey(row: 6, bit: 0)
    }
    // Send Return 4 frames after "0"
    if howManyFilesFrame >= 0 && frame == howManyFilesFrame + 6 {
        m.keyboard.pressKey(row: 1, bit: 7)  // Return
    }
    if howManyFilesFrame >= 0 && frame == howManyFilesFrame + 8 {
        m.keyboard.releaseKey(row: 1, bit: 7)
    }

    if useRunFrame {
        m.runFrame()
        if m.cpu.pc == 0x4F9C {
            readyCount += 1
            if firstREADYFrame < 0 {
                firstREADYFrame = frame
                let e69f = m.bus.mainRAM[0xE69F]
                print(String(format: "  READY reached at frame %d, E69F=%02X", frame, e69f))
            }
        }
    } else {
        let frameEnd = m.totalTStates + UInt64(m.tStatesPerFrame)
        while m.totalTStates < frameEnd {
            if m.cpu.pc == 0x4F9C {
                readyCount += 1
                if firstREADYFrame < 0 {
                    firstREADYFrame = frame
                    let e69f = m.bus.mainRAM[0xE69F]
                    print(String(format: "  READY reached at frame %d, E69F=%02X", frame, e69f))
                }
            }
            m.tick()
        }
    }

    let subDelta = m.subSystem.subCpuTStates - subBefore
    if frame % 200 == 199 || frame < 5 {
        let e69f = m.bus.mainRAM[0xE69F]
        let elapsed = CFAbsoluteTimeGetCurrent() - coldBootStart
        print(String(format: "  Frame %d: PC=%04X E69F=%02X READY=%d IFF=%d IM=%d subT=%llu t=%.2fs",
              frame, m.cpu.pc, e69f, readyCount, m.cpu.iff1 ? 1 : 0, m.cpu.im,
              subDelta, elapsed))
    }
}

// Show results
print("\n=== Results ===")
print("  READY count: \(readyCount), first at frame \(firstREADYFrame)")
let e69f = m.bus.mainRAM[0xE69F]
print(String(format: "  E69F: %02X", e69f))

// Dump text VRAM
let textData = m.bus.readTextVRAM()
print("\n  Text VRAM:")
for row in 0..<25 {
    let base = row * 80
    guard base + 80 <= textData.count else { break }
    var line = ""
    for col in 0..<80 {
        let ch = textData[base + col]
        if ch >= 0x20 && ch < 0x7F {
            line += String(UnicodeScalar(ch))
        } else if ch == 0x00 {
            line += " "
        } else {
            line += "."
        }
    }
    line = String(line.reversed().drop(while: { $0 == " " }).reversed())
    if !line.isEmpty { print("  Row \(row): \"\(line)\"") }
}

// Check for "Ok" in text VRAM
var okFound = false
for i in 0..<(textData.count - 1) {
    if textData[i] == 0x4F && textData[i+1] == 0x6B {
        okFound = true
        break
    }
}
print("\n  'Ok' found: \(okFound)")

// Tape-mode: capture screenshot and cassette playback progress.
if ProcessInfo.processInfo.environment["BOOTTEST_TAPE_PATH"] != nil {
    let deck = m.cassette
    if ProcessInfo.processInfo.environment["BOOTTEST_CMT_PORT_STATS"] == "1" {
        for p: UInt8 in [0x20, 0x21, 0x30, 0x40] {
            let s = cmtStats.stats[p] ?? (reads: 0, writes: 0)
            print(String(format: "  Port %02X: R=%d W=%d", p, s.reads, s.writes))
        }
        if !cmtStats.port40ReadValues.isEmpty {
            print("  Port 0x40 read-value histogram:")
            for (v, n) in cmtStats.port40ReadValues.sorted(by: { $0.key < $1.key }) {
                print(String(format: "    %02X: %d", v, n))
            }
        }
    }
    print(String(format: "  Tape playback: %d / %d bytes (motor=%d cmtSel=%d dcd=%d)",
                 deck.bufPtr, deck.buffer.count,
                 deck.motorOn ? 1 : 0, deck.cmtSelected ? 1 : 0, deck.dcd ? 1 : 0))
    if let screenshotPath {
        do {
            let pixels = renderCurrentFrame(machine: m)
            try writePPMScreenshot(path: screenshotPath, pixels: pixels)
            print("  Screenshot written to \(screenshotPath)")
        } catch {
            print("  Failed to write screenshot: \(error)")
        }
    }
}

// ============================================================
// Save state load mode (BOOTTEST_LOAD_STATE)
// Loads a .b88s save state file and runs frames from there.
// ============================================================
let loadStatePath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_LOAD_STATE"] ?? ""
    return raw.isEmpty ? nil : raw
}()

let adpcmTracePath: String? = {
    let raw = ProcessInfo.processInfo.environment["BOOTTEST_ADPCM_TRACE_PATH"] ?? ""
    return raw.isEmpty ? nil : raw
}()

if let loadStatePath {
    print("\n=== Save state load: \(loadStatePath) ===")
    guard let stateData = try? Array(Data(contentsOf: URL(fileURLWithPath: loadStatePath))) else {
        print("  Failed to read save state file"); exit(1)
    }

    let sm = setupMachine()
    do {
        try sm.loadSaveState(stateData)
        print("  State loaded successfully")
    } catch {
        print("  Failed to load save state: \(error)"); exit(1)
    }

    // Print ADPCM state after load
    let snd = sm.sound
    print(String(format: "  ADPCM: playing=%d startAddr=%04X stopAddr=%04X memAddr=%06X",
          snd.adpcmPlaying ? 1 : 0, snd.adpcmStartAddr, snd.adpcmStopAddr, snd.adpcmMemAddr))
    print(String(format: "  ADPCM: deltaN=%04X totalLevel=%02X control1=%02X control2=%02X",
          snd.adpcmDeltaN, snd.adpcmTotalLevel, snd.adpcmControl1, snd.adpcmControl2))
    print(String(format: "  ADPCM: accum=%d stepSize=%d playbackDelta=%d playbackCounter=%d",
          snd.adpcmAccum, snd.adpcmStepSize, snd.adpcmPlaybackDelta, snd.adpcmPlaybackCounter))
    print(String(format: "  ADPCM: decodedOutput=%d stage0=%d stage1=%d outputSample=%.1f",
          snd.adpcmDecodedOutput, snd.adpcmOutputStage0, snd.adpcmOutputStage1, snd.adpcmOutputSample))
    print(String(format: "  ADPCM: statusFlags=%02X statusMask=%02X limitAddr=%06X",
          snd.adpcmStatusFlags, snd.statusMask, snd.adpcmLimitAddr))
    print(String(format: "  CPU: PC=%04X SP=%04X clock8MHz=%d IFF=%d IM=%d",
          sm.cpu.pc, sm.cpu.sp, sm.clock8MHz ? 1 : 0, sm.cpu.iff1 ? 1 : 0, sm.cpu.im))
    // Dump code around PC
    let loadPC = Int(sm.cpu.pc)
    let codeStart = max(0, loadPC - 8)
    let codeEnd = min(0x10000, loadPC + 24)
    let codeBytes = (codeStart..<codeEnd).map { String(format: "%02X", sm.bus.memRead(UInt16($0))) }.joined(separator: " ")
    print(String(format: "  Code@PC: [%04X] %@", codeStart, codeBytes))
    print(String(format: "  Display: text=%d 80col=%d color=%d 400line=%d ramMode=%d gvPlane=%d graphColor=%d",
          sm.bus.textDisplayEnabled ? 1 : 0, sm.bus.columns80 ? 1 : 0,
          sm.bus.colorMode ? 1 : 0, sm.bus.is400LineMode ? 1 : 0,
          sm.bus.ramMode ? 1 : 0, sm.bus.gvramPlane,
          sm.bus.graphicsColorMode ? 1 : 0))

    snd.debugOutputMask = audioDebugMask

    // ADPCM trace: log output level per frame
    var adpcmTraceLines: [String] = []
    var adpcmPeakPerFrame: Float = 0

    // Key events
    let loadStateKeyEvents = scriptedKeyEventsByFrame

    // Run frames
    let stateBootStart = CFAbsoluteTimeGetCurrent()
    for frame in 0..<diskBootFrames {
        let frameEvents = loadStateKeyEvents[frame] ?? []
        var tappedKeys: [Keyboard.Key] = []
        for event in frameEvents {
            switch event.action {
            case .press:
                sm.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
            case .release:
                sm.keyboard.releaseKey(row: event.key.row, bit: event.key.bit)
            case .tap:
                sm.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
                tappedKeys.append(event.key)
            }
        }

        if useRunFrame {
            for _ in 0..<turboMultiplier {
                sm.runFrame()
            }
        } else {
            let frameEnd = sm.totalTStates + UInt64(sm.tStatesPerFrame)
            while sm.totalTStates < frameEnd {
                sm.tick()
            }
        }

        for key in tappedKeys {
            sm.keyboard.releaseKey(row: key.row, bit: key.bit)
        }

        // Collect ADPCM audio level for this frame
        let audioSamples = snd.audioBuffer
        if !audioSamples.isEmpty {
            let framePeak = audioSamples.reduce(Float.zero) { max($0, abs($1)) }
            adpcmPeakPerFrame = max(adpcmPeakPerFrame, framePeak)
            if adpcmTracePath != nil {
                // Calculate RMS for this frame
                let sum = audioSamples.reduce(Float.zero) { $0 + $1 * $1 }
                let rms = (sum / Float(audioSamples.count)).squareRoot()
                adpcmTraceLines.append(String(format: "f%04d peak=%.6f rms=%.6f playing=%d accum=%d TL=%d out=%.1f stage0=%d stage1=%d",
                    frame, framePeak, rms,
                    snd.adpcmPlaying ? 1 : 0, snd.adpcmAccum,
                    snd.adpcmTotalLevel, snd.adpcmOutputSample,
                    snd.adpcmOutputStage0, snd.adpcmOutputStage1))
            }
        }
        snd.audioBuffer.removeAll(keepingCapacity: true)

        // Interval screenshots
        if let dir = screenshotDir, screenshotInterval > 0,
           frame > 0, frame % screenshotInterval == 0 {
            do {
                let pixels = renderCurrentFrame(machine: sm)
                let filename = String(format: "%@_f%04d.ppm", screenshotBaseName, frame)
                let path = (dir as NSString).appendingPathComponent(filename)
                try writePPMScreenshot(path: path, pixels: pixels)
            } catch {}
        }

        let showFrame = frame < 3 || frame % 60 == 0 || frame == diskBootFrames - 1
        if showFrame {
            let elapsed = CFAbsoluteTimeGetCurrent() - stateBootStart
            print(String(format: "  Frame %d: PC=%04X ADPCM playing=%d accum=%d TL=%d peak=%.4f t=%.2fs",
                  frame, sm.cpu.pc,
                  snd.adpcmPlaying ? 1 : 0, snd.adpcmAccum,
                  snd.adpcmTotalLevel, adpcmPeakPerFrame, elapsed))
        }
    }

    // Final state
    print("\n  === Final State ===")
    print(String(format: "  ADPCM: playing=%d accum=%d stepSize=%d memAddr=%06X",
          snd.adpcmPlaying ? 1 : 0, snd.adpcmAccum, snd.adpcmStepSize, snd.adpcmMemAddr))
    print(String(format: "  ADPCM: deltaN=%04X totalLevel=%02X control1=%02X control2=%02X",
          snd.adpcmDeltaN, snd.adpcmTotalLevel, snd.adpcmControl1, snd.adpcmControl2))

    // Write ADPCM trace
    if let adpcmTracePath, !adpcmTraceLines.isEmpty {
        do {
            try adpcmTraceLines.joined(separator: "\n").write(
                toFile: adpcmTracePath, atomically: true, encoding: .utf8)
            print("  ADPCM trace (\(adpcmTraceLines.count) entries) written to \(adpcmTracePath)")
        } catch {
            print("  Failed to write ADPCM trace: \(error)")
        }
    }

    // Screenshot
    if let screenshotPath {
        do {
            let pixels = renderCurrentFrame(machine: sm)
            try writePPMScreenshot(path: screenshotPath, pixels: pixels)
            print("  Screenshot written to \(screenshotPath)")
        } catch {
            print("  Failed to write screenshot: \(error)")
        }
    }

    print("\nDone.")
    exit(0)
}

// ============================================================
// Disk boot test (ys.d88 DISK A on drive 0)
// Uses sub-CPU command protocol (0x00-0x24), NOT raw FDC commands
// ============================================================
let diskPath = requestedDiskPath ?? "/Volumes/CrucialX6/roms/PC88/ys.d88"
if let diskData = try? Data(contentsOf: URL(fileURLWithPath: diskPath)) {
    let disks = D88Disk.parseAll(data: Array(diskData))
    print("\n=== Disk boot test: \(diskPath) ===")
    print("  Images found: \(disks.count)")
    for (i, d) in disks.enumerated() {
        print("  [\(i)] \"\(d.name)\" type=\(d.diskType) wp=\(d.writeProtected)")
    }

    // Verify boot sector exists
    if let diskA = disks.first {
        // === SCAN FOR "TITLEP" IN ALL DISK SECTORS ===
        let titleBytes: [UInt8] = [0x54, 0x49, 0x54, 0x4C, 0x45, 0x50]  // "TITLEP"
        print("\n  Scanning disk for 'TITLEP'...")
        for trackIdx in 0..<D88Disk.maxTracks {
            for (secIdx, sector) in diskA.tracks[trackIdx].enumerated() {
                for offset in 0..<max(0, sector.data.count - 5) {
                    if sector.data[offset..<(offset+6)].elementsEqual(titleBytes) {
                        print(String(format: "    FOUND at D88track=%d (C=%d H=%d) sector R=%d offset=0x%03X",
                              trackIdx, sector.c, sector.h, sector.r, offset))
                        // Dump surrounding data
                        let dumpStart = max(0, offset - 16)
                        let dumpEnd = min(sector.data.count, offset + 32)
                        let bytes = (dumpStart..<dumpEnd).map { String(format: "%02X", sector.data[$0]) }.joined(separator: " ")
                        print("      data: \(bytes)")
                    }
                }
            }
        }

        // === DUMP DISK DIRECTORY STRUCTURE (first few tracks) ===
        print("\n  D88 track structure (first 10 tracks):")
        for trackIdx in 0..<min(10, diskA.tracks.count) {
            let sectors = diskA.tracks[trackIdx]
            if sectors.isEmpty { continue }
            print(String(format: "    Track %d (%d sectors):", trackIdx, sectors.count))
            for (i, s) in sectors.enumerated() {
                let preview = s.data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
                print(String(format: "      [%d] C=%d H=%d R=%d N=%d size=%d dens=%02X del=%d stat=%02X data: %@",
                      i, s.c, s.h, s.r, s.n, s.data.count, s.density, s.deleted ? 1 : 0, s.status, preview))
            }
        }

        let bootSector = diskA.findSector(track: 0, c: 0, h: 0, r: 1)
        print("\n  Boot sector (trk0 C0H0 R1): \(bootSector != nil ? "\(bootSector!.data.count) bytes" : "NOT FOUND")")
        if let bs = bootSector {
            print("  Boot sector first 16 bytes: ", terminator: "")
            for i in 0..<min(16, bs.data.count) {
                print(String(format: "%02X ", bs.data[i]), terminator: "")
            }
            print()
        }

        // dipSw2: bit3=0 → disk boot.
        // Allow override for V1H/V1S testing via BOOTTEST_DIPSW2 (hex or decimal).
        // Defaults: V2=0x71, V1H=0xF1, V1S=0xB1.
        let defaultSw2: UInt8 = 0x79 & ~0x08  // 0x71 (V2, FDD boot)
        let sw2Override: UInt8? = {
            guard let raw = ProcessInfo.processInfo.environment["BOOTTEST_DIPSW2"], !raw.isEmpty else { return nil }
            let s = raw.hasPrefix("0x") || raw.hasPrefix("0X") ? String(raw.dropFirst(2)) : raw
            if let v = UInt8(s, radix: 16) { return v }
            if let v = UInt8(raw) { return v }
            return nil
        }()
        if let v = sw2Override {
            print(String(format: "  DIP SW2 override: %02X", v))
        }
        let dm = setupMachine(dipSw2: sw2Override ?? defaultSw2)
        dm.bus.directBasicBoot = false
        // Image index overrides: allow selecting a non-default image from a
        // multi-image D88 for each drive. Useful for games like ヴァルナ where
        // Drive 2 should get image #3 (Scenario 1), not the default image #2.
        let drive0ImageIndex = Int(ProcessInfo.processInfo.environment["BOOTTEST_DRIVE0_IMAGE"] ?? "") ?? 0
        let drive1ImageIndexDefault = disks.count >= 2 ? 1 : -1
        let drive1ImageIndex = Int(ProcessInfo.processInfo.environment["BOOTTEST_DRIVE1_IMAGE"] ?? "") ?? drive1ImageIndexDefault
        let drive0Disk = (drive0ImageIndex >= 0 && drive0ImageIndex < disks.count) ? disks[drive0ImageIndex] : diskA
        dm.mountDisk(drive: 0, disk: drive0Disk)
        if drive1ImageIndex >= 0 && drive1ImageIndex < disks.count {
            dm.mountDisk(drive: 1, disk: disks[drive1ImageIndex])
            print("  Mounted multi-image D88: drive0=\"\(drive0Disk.name)\" (idx \(drive0ImageIndex)) drive1=\"\(disks[drive1ImageIndex].name)\" (idx \(drive1ImageIndex))")
        } else {
            print("  Mounted single-image D88: drive0=\"\(drive0Disk.name)\"")
        }
        // When port tracing is active, disable the late execution trace —
        // Machine.traceEnabled hijacks bus.onIOAccess and would clobber our
        // port trace callback mid-run.
        let portTraceActive = ProcessInfo.processInfo.environment["BOOTTEST_PORT_TRACE_PATH"] != nil
        let lateTraceStartFrame = portTraceActive ? Int.max : max(0, diskBootFrames - 60)
        dm.traceMaxEntries = 30_000
        dm.subSystem.fdc.commandLogMax = 500
        // FM register trace removed in refactor

        // === Port write trace (GVRAM-related) ===========================
        // Enabled via BOOTTEST_PORT_TRACE_PATH. Logs writes to ports that
        // affect graphics rendering state (ALU, plane select, palette,
        // display enables, evram mode, etc.) so we can replay what the
        // game did and compare against a reference emulator.
        let portTracePath = ProcessInfo.processInfo.environment["BOOTTEST_PORT_TRACE_PATH"]
        let portTraceStartFrame = Int(ProcessInfo.processInfo.environment["BOOTTEST_PORT_TRACE_START_FRAME"] ?? "") ?? 0
        let portTraceEndFrame = Int(ProcessInfo.processInfo.environment["BOOTTEST_PORT_TRACE_END_FRAME"] ?? "") ?? diskBootFrames
        // Default port set: graphics/ALU/plane/palette + text window. Can be
        // overridden with BOOTTEST_PORT_TRACE_PORTS=30,31,32,...
        let defaultTracePorts: Set<UInt8> = [
            0x30, 0x31, 0x32, 0x34, 0x35,
            0x52, 0x53,
            0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B,
            0x5C, 0x5D, 0x5E, 0x5F,
            0x70, 0x71
        ]
        let tracePorts: Set<UInt8> = {
            guard let raw = ProcessInfo.processInfo.environment["BOOTTEST_PORT_TRACE_PORTS"] else {
                return defaultTracePorts
            }
            var set = Set<UInt8>()
            for token in raw.split(separator: ",") {
                if let v = UInt8(token.trimmingCharacters(in: .whitespaces), radix: 16) {
                    set.insert(v)
                }
            }
            return set.isEmpty ? defaultTracePorts : set
        }()
        var portTraceLines: [String] = []
        var currentTraceFrame: Int = 0
        if portTracePath != nil {
            dm.bus.onIOAccess = { port, value, isWrite in
                guard isWrite else { return }
                guard currentTraceFrame >= portTraceStartFrame,
                      currentTraceFrame < portTraceEndFrame else { return }
                let p8 = UInt8(port & 0xFF)
                guard tracePorts.contains(p8) else { return }
                portTraceLines.append(String(format: "f%05d port=%02X val=%02X",
                                             currentTraceFrame, p8, value))
            }
            print("  Port trace enabled → \(portTracePath!) (frames \(portTraceStartFrame)..<\(portTraceEndFrame), ports=\(tracePorts.sorted().map { String(format: "%02X", $0) }.joined(separator: ",")))")
        }

        // PIO flow trace (lightweight, uses PIOFlowEntry JSONL format)
        var pioFlowSeq: Int = 0
        var pioFlowHandle: FileHandle? = nil
        if let pioFlowPath {
            FileManager.default.createFile(atPath: pioFlowPath, contents: nil)
            pioFlowHandle = FileHandle(forWritingAtPath: pioFlowPath)
            dm.subSystem.pio.onPIOAccess = { [weak dm] event in
                guard let dm, let handle = pioFlowHandle else { return }
                guard currentTraceFrame >= portTraceStartFrame,
                      currentTraceFrame < portTraceEndFrame else { return }
                let entry = PIOFlowEntry(
                    mainPC: dm.cpu.pc,
                    subPC: dm.subSystem.subCpu.pc,
                    side: event.side == .main ? .main : .sub,
                    port: [PIOFlowEntry.Port.a, .b, .c][Int(event.port)],
                    isWrite: event.isWrite,
                    value: event.value
                )
                let line = PIOFlowJSONL.line(seq: pioFlowSeq, entry: entry) + "\n"
                pioFlowSeq += 1
                if let data = line.data(using: .utf8) { handle.write(data) }
            }
            dm.subSystem.pio.onPIOControlWrite = { [weak dm] side, value in
                guard let dm, let handle = pioFlowHandle else { return }
                guard currentTraceFrame >= portTraceStartFrame,
                      currentTraceFrame < portTraceEndFrame else { return }
                let entry = PIOFlowEntry(
                    mainPC: dm.cpu.pc,
                    subPC: dm.subSystem.subCpu.pc,
                    side: side == .main ? .main : .sub,
                    port: .control,
                    isWrite: true,
                    value: value
                )
                let line = PIOFlowJSONL.line(seq: pioFlowSeq, entry: entry) + "\n"
                pioFlowSeq += 1
                if let data = line.data(using: .utf8) { handle.write(data) }
            }
            print("  PIO flow trace enabled → \(pioFlowPath) (frames \(portTraceStartFrame)..<\(portTraceEndFrame))")
        }

        // CPU instruction trace (per-opcode pre-fetch state).
        // Format: seq=N PC=XXXX AF=XXXX BC=XXXX DE=XXXX HL=XXXX IX=XXXX IY=XXXX SP=XXXX I=XX R=XX IFF=X
        var cpuTraceHandle: FileHandle? = nil
        var cpuTraceSeq: Int = 0
        if let cpuTracePath {
            FileManager.default.createFile(atPath: cpuTracePath, contents: nil)
            cpuTraceHandle = FileHandle(forWritingAtPath: cpuTracePath)
            let targetCPU: Z80 = (cpuTraceWhich == "sub") ? dm.subSystem.subCpu : dm.cpu
            let limit = cpuTraceLimit
            targetCPU.onInstructionTrace = { cpu in
                guard let h = cpuTraceHandle else { return }
                if limit > 0, cpuTraceSeq >= limit { return }
                let line = String(
                    format: "seq=%d PC=%04X AF=%04X BC=%04X DE=%04X HL=%04X IX=%04X IY=%04X SP=%04X I=%02X R=%02X IFF=%d\n",
                    cpuTraceSeq, cpu.pc, cpu.af, cpu.bc, cpu.de, cpu.hl,
                    cpu.ix, cpu.iy, cpu.sp, cpu.i, cpu.r, cpu.iff1 ? 1 : 0)
                cpuTraceSeq += 1
                if let d = line.data(using: .utf8) { h.write(d) }
            }
            print("  CPU trace (\(cpuTraceWhich)) → \(cpuTracePath)" + (limit > 0 ? " (limit \(limit))" : ""))
        }

        // FDC data byte trace: logs premature 0xFF reads (readByteReady=false)
        let fdcDataTracePath = ProcessInfo.processInfo.environment["BOOTTEST_FDC_DATA_TRACE_PATH"] ?? ""
        var fdcDataTraceHandle: FileHandle? = nil
        var fdcDataTraceSeq: Int = 0
        if !fdcDataTracePath.isEmpty {
            FileManager.default.createFile(atPath: fdcDataTracePath, contents: nil)
            fdcDataTraceHandle = FileHandle(forWritingAtPath: fdcDataTracePath)
            dm.subSystem.fdc.onReadDataByte = { [weak dm] byte, wasReady, dataIdx, sectorIdx, bufCount, seekAny in
                guard let dm, let handle = fdcDataTraceHandle else { return }
                let subPC = dm.subSystem.subCpu.pc
                // Only log premature reads or if seek is active (to save space)
                if !wasReady || seekAny {
                    let line = String(format: "{\"seq\":%d,\"f\":%d,\"subPC\":\"%04X\",\"byte\":\"%02X\",\"ready\":%@,\"di\":%d,\"si\":%d,\"bc\":%d,\"seek\":%@}\n",
                        fdcDataTraceSeq, currentTraceFrame, subPC, byte,
                        wasReady ? "true" : "false", dataIdx, sectorIdx, bufCount,
                        seekAny ? "true" : "false")
                    if let data = line.data(using: .utf8) { handle.write(data) }
                }
                fdcDataTraceSeq += 1
            }
            print("  FDC data byte trace enabled → \(fdcDataTracePath)")
        }

        // Report sub-CPU mode
        print("  Sub-CPU mode: \(dm.subSystem.useLegacyMode ? "legacy (command-level)" : "Z80 (DISK.ROM)")")

        // Dump DISK.ROM key areas
        let rom = dm.subSystem.subBus.romram
        print("  DISK.ROM entry (JP target):", String(format: "0x%02X%02X", rom[2], rom[1]))
        // RST 10h handler (0x0010) - used for PIO byte receive
        print("  RST 10h (0x0010):", (0..<16).map { String(format: "%02X", rom[0x0010 + $0]) }.joined(separator: " "))
        // RST 18h handler (0x0018)
        print("  RST 18h (0x0018):", (0..<16).map { String(format: "%02X", rom[0x0018 + $0]) }.joined(separator: " "))
        // Command handler area (0x00E8-0x0120)
        print("  Cmd handler (0x00E8):")
        for base in stride(from: 0x00E8, to: 0x0130, by: 16) {
            let bytes = (0..<16).map { String(format: "%02X", rom[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // Command jump table (if exists) — look for a table of addresses
        print("  ROM 0x0038:", (0..<32).map { String(format: "%02X", rom[0x0038 + $0]) }.joined(separator: " "))
        print("  ROM 0x0100:", (0..<48).map { String(format: "%02X", rom[0x0100 + $0]) }.joined(separator: " "))

        // Instrument runSubCPUUntilSwitch to track sub-CPU behavior
        var subRunInvocations = 0
        var subRunMaxPC: UInt16 = 0
        var subRunHitMax = 0  // times it hit maxTStates without Port C read

        var int3Count = 0
        let origInterrupt = dm.subSystem.onInterrupt
        dm.subSystem.onInterrupt = {
            int3Count += 1
            origInterrupt?()
        }

        var lastPC: UInt16 = 0
        var pcLog: [(frame: Int, pc: UInt16)] = []
        let diskBootStart = CFAbsoluteTimeGetCurrent()
        var traceArmed = false
        var crashFrame: Int?
        var stopReason: String?
        var stopFromPC: UInt16 = 0
        var stopToPC: UInt16 = 0
        var stopSP: UInt16 = 0
        var audioFramesWithOutput = 0
        var audioPeak: Float = 0
        var firstAudioFrame: Int?
        // FM trace removed in refactor
        var lowEntryFromPC: UInt16?
        var lowEntryToPC: UInt16?
        var lowEntrySP: UInt16?
        var lowPCFollowRemaining = 0
        let trackedMainRAMAddresses: [UInt16] = [0x0400, 0x45A5, 0x45C8, 0x45D9] + watchedMainRAMAddresses
        var trackedMainRAMInitial: [UInt16: UInt8] = [:]
        var trackedMainRAMFirstChangeFrame: [UInt16: Int] = [:]
        var trackedMainRAMLastValue: [UInt16: UInt8] = [:]
        for addr in trackedMainRAMAddresses {
            let value = dm.bus.mainRAM[Int(addr)]
            trackedMainRAMInitial[addr] = value
            trackedMainRAMLastValue[addr] = value
        }

        struct MainStepSample {
            let frame: Int
            let pc: UInt16
            let op: UInt8
            let sp: UInt16
            let af: UInt16
            let bc: UInt16
            let de: UInt16
            let hl: UInt16
        }
        let mainStepRingSize = 4096
        var mainStepRing: [MainStepSample?] = Array(repeating: nil, count: mainStepRingSize)
        var mainStepRingIndex = 0
        var mainStepRingCount = 0

        struct MainJumpSample {
            let frame: Int
            let fromPC: UInt16
            let toPC: UInt16
            let op: UInt8
            let sp: UInt16
            let af: UInt16
            let bc: UInt16
            let de: UInt16
            let hl: UInt16
        }
        let mainJumpRingSize = 512
        var mainJumpRing: [MainJumpSample?] = Array(repeating: nil, count: mainJumpRingSize)
        var mainJumpRingIndex = 0
        var mainJumpRingCount = 0

        // Track FDC pcn changes per frame
        var prevPCN0: UInt8 = 0
        var prevFDCIntCount: Int = 0
        var watchTraceLines: [String] = []
        var soundIRQAssertCount = 0
        var firstSoundIRQAssertFrame: Int?

        let originalSoundIRQ = dm.sound.onTimerIRQ
        dm.sound.onTimerIRQ = {
            soundIRQAssertCount += 1
            originalSoundIRQ?()
        }

        for frame in 0..<diskBootFrames {
            currentTraceFrame = frame
            if !traceArmed && frame >= lateTraceStartFrame {
                dm.traceEnabled = true
                traceArmed = true
                print("  Main CPU trace enabled at frame \(frame)")
            }
            let frameEvents = scriptedKeyEventsByFrame[frame] ?? []
            var tappedKeys: [Keyboard.Key] = []
            for event in frameEvents {
                switch event.action {
                case .press:
                    dm.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
                case .release:
                    dm.keyboard.releaseKey(row: event.key.row, bit: event.key.bit)
                case .tap:
                    dm.keyboard.pressKey(row: event.key.row, bit: event.key.bit)
                    tappedKeys.append(event.key)
                }
                print("  Key event frame \(frame): \(event.keyName)")
            }
            let subBefore = dm.subSystem.subCpuTStates

            if useRunFrame {
                let pc = dm.cpu.pc
                // Turbo: run N sub-frames per logical frame. This matches
                // the app's Tab-held turbo behavior (8 frames per 60Hz draw).
                for _ in 0..<turboMultiplier {
                    dm.runFrame()
                }
                let postPC = dm.cpu.pc
                if dm.bus.ramMode && dm.cpu.sp < 0x0004 && frame > 100 && crashFrame == nil {
                    crashFrame = frame
                    stopReason = String(format: "abnormal SP=%04X at PC=%04X prevPC=%04X ramMode=1",
                                        dm.cpu.sp, dm.cpu.pc, pc)
                    stopFromPC = pc
                    stopToPC = dm.cpu.pc
                    stopSP = dm.cpu.sp
                } else if postPC < 0x0100 && pc >= 0x8000 {
                    lowEntryFromPC = pc
                    lowEntryToPC = postPC
                    lowEntrySP = dm.cpu.sp
                }
            } else {
                let frameEnd = dm.totalTStates + UInt64(dm.tStatesPerFrame)
                while dm.totalTStates < frameEnd {
                    let pc = dm.cpu.pc
                    if pc != lastPC {
                        if pc < 0x100 && lastPC >= 0x8000 {
                            pcLog.append((frame, pc))
                        }
                        lastPC = pc
                    }
                    if traceArmed {
                        mainStepRing[mainStepRingIndex] = MainStepSample(
                            frame: frame,
                            pc: pc,
                            op: dm.bus.memRead(pc),
                            sp: dm.cpu.sp,
                            af: dm.cpu.af,
                            bc: dm.cpu.bc,
                            de: dm.cpu.de,
                            hl: dm.cpu.hl
                        )
                        mainStepRingIndex = (mainStepRingIndex + 1) % mainStepRingSize
                        if mainStepRingCount < mainStepRingSize {
                            mainStepRingCount += 1
                        }
                    }
                    dm.tick()
                    let postPC = dm.cpu.pc
                    let delta = Int(postPC) - Int(pc)
                    if irqTraceEnabled,
                       firstSoundIRQAssertFrame == nil,
                       soundIRQAssertCount > 0 {
                        firstSoundIRQAssertFrame = frame
                    }
                    let subPC = dm.subSystem.subCpu.pc
                    if !watchedSubPCs.isEmpty, watchedSubPCs.contains(subPC) {
                        let line = String(
                            format: "SUB_PC_HIT frame=%d subPC=%04X subOP=%02X subSP=%04X subAF=%04X subBC=%04X subDE=%04X subHL=%04X mainPC=%04X",
                            frame,
                            subPC,
                            dm.subSystem.subBus.memRead(subPC),
                            dm.subSystem.subCpu.sp,
                            dm.subSystem.subCpu.af,
                            dm.subSystem.subCpu.bc,
                            dm.subSystem.subCpu.de,
                            dm.subSystem.subCpu.hl,
                            dm.cpu.pc
                        )
                        watchTraceLines.append(line)
                    }
                    if !watchedPCs.isEmpty, watchedPCs.contains(pc) {
                        let line = String(
                            format: "PC_HIT frame=%d PC=%04X OP=%02X SP=%04X AF=%04X BC=%04X DE=%04X HL=%04X %@",
                            frame,
                            pc,
                            dm.bus.memRead(pc),
                            dm.cpu.sp,
                            dm.cpu.af,
                            dm.cpu.bc,
                            dm.cpu.de,
                            dm.cpu.hl,
                            formatWatchedRAM(dm, addresses: watchedMainRAMAddresses)
                        )
                        watchTraceLines.append(line)
                    }
                    if !watchedMainRAMAddresses.isEmpty {
                        for addr in watchedMainRAMAddresses {
                            let value = dm.bus.mainRAM[Int(addr)]
                            let previous = trackedMainRAMLastValue[addr] ?? value
                            if value != previous {
                                let line = String(
                                    format: "RAM_WRITE frame=%d PC=%04X SP=%04X %04X:%02X->%02X %@",
                                    frame,
                                    postPC,
                                    dm.cpu.sp,
                                    addr,
                                    previous,
                                    value,
                                    formatWatchedRAM(dm, addresses: watchedMainRAMAddresses)
                                )
                                watchTraceLines.append(line)
                            }
                        }
                    }
                    if traceArmed && (delta > 3 || delta < 0) {
                        mainJumpRing[mainJumpRingIndex] = MainJumpSample(
                            frame: frame,
                            fromPC: pc,
                            toPC: postPC,
                            op: dm.bus.memRead(pc),
                            sp: dm.cpu.sp,
                            af: dm.cpu.af,
                            bc: dm.cpu.bc,
                            de: dm.cpu.de,
                            hl: dm.cpu.hl
                        )
                        mainJumpRingIndex = (mainJumpRingIndex + 1) % mainJumpRingSize
                        if mainJumpRingCount < mainJumpRingSize {
                            mainJumpRingCount += 1
                        }
                    }
                    // Detect abnormal SP in RAM mode (game crash)
                    if dm.bus.ramMode && dm.cpu.sp < 0x0004 && frame > 100 && crashFrame == nil {
                        crashFrame = frame
                        stopReason = String(format: "abnormal SP=%04X at PC=%04X prevPC=%04X ramMode=1",
                                            dm.cpu.sp, dm.cpu.pc, pc)
                        stopFromPC = pc
                        stopToPC = dm.cpu.pc
                        stopSP = dm.cpu.sp
                        if !ignoreCrashHeuristics {
                            break
                        }
                    }
                    if traceArmed && lowEntryToPC == nil && postPC < 0x0100 && pc >= 0x8000 {
                        lowEntryFromPC = pc
                        lowEntryToPC = postPC
                        lowEntrySP = dm.cpu.sp
                        lowPCFollowRemaining = 2048
                    }
                    if lowEntryToPC != nil {
                        if postPC >= 0x7000 && pc < 0x1000 {
                            crashFrame = frame
                            stopReason = String(format: "post-low-PC entered high RAM via %04X→%04X SP=%04X",
                                                pc, postPC, dm.cpu.sp)
                            stopFromPC = pc
                            stopToPC = postPC
                            stopSP = dm.cpu.sp
                            if !ignoreCrashHeuristics {
                                break
                            }
                        }
                        if postPC == 0x0038 {
                            crashFrame = frame
                            stopReason = String(format: "post-low-PC reached 0038 via %04X→%04X SP=%04X",
                                                pc, postPC, dm.cpu.sp)
                            stopFromPC = pc
                            stopToPC = postPC
                            stopSP = dm.cpu.sp
                            if !ignoreCrashHeuristics {
                                break
                            }
                        }
                        if lowPCFollowRemaining <= 0 {
                            crashFrame = frame
                            stopReason = String(format: "followed low-PC path after %04X→%04X for 2048 steps",
                                                lowEntryFromPC ?? 0, lowEntryToPC ?? 0)
                            stopFromPC = pc
                            stopToPC = postPC
                            stopSP = dm.cpu.sp
                            if !ignoreCrashHeuristics {
                                break
                            }
                        }
                        lowPCFollowRemaining -= 1
                    }
                }
            }

            for key in tappedKeys {
                dm.keyboard.releaseKey(row: key.row, bit: key.bit)
            }

            // Interval screenshots
            if let dir = screenshotDir, screenshotInterval > 0,
               frame > 0, frame % screenshotInterval == 0 {
                do {
                    let pixels = renderCurrentFrame(machine: dm)
                    let filename = String(format: "%@_f%04d.ppm", screenshotBaseName, frame)
                    let path = (dir as NSString).appendingPathComponent(filename)
                    try writePPMScreenshot(path: path, pixels: pixels)
                } catch {
                    // Silently skip failed screenshots in batch mode
                }
            }

            if audioSummaryEnabled {
                let nonZeroSamples = dm.sound.audioBuffer.filter { $0 != 0 }
                if !nonZeroSamples.isEmpty {
                    audioFramesWithOutput += 1
                    if firstAudioFrame == nil {
                        firstAudioFrame = frame
                    }
                    let framePeak = nonZeroSamples.reduce(Float.zero) { peak, sample in
                        max(peak, abs(sample))
                    }
                    audioPeak = max(audioPeak, framePeak)
                }
                dm.sound.audioBuffer.removeAll(keepingCapacity: true)
            }

            if crashFrame != nil && !ignoreCrashHeuristics {
                break
            }

            for addr in trackedMainRAMAddresses {
                let value = dm.bus.mainRAM[Int(addr)]
                if trackedMainRAMFirstChangeFrame[addr] == nil && value != trackedMainRAMInitial[addr] {
                    trackedMainRAMFirstChangeFrame[addr] = frame
                }
                trackedMainRAMLastValue[addr] = value
            }

            let subDelta = dm.subSystem.subCpuTStates - subBefore
            let elapsed = CFAbsoluteTimeGetCurrent() - diskBootStart
            let curPCN0 = dm.subSystem.fdc.pcn[0]
            let curFDCInt = dm.subSystem.fdcInterruptDeliveredCount
            let fdcIntDelta = curFDCInt - prevFDCIntCount

            let showFrame = frame < 5 || (frame >= 15 && frame <= 30) || frame == 50
                || (frame >= 140 && frame <= 200) || frame % 50 == 0
            if showFrame {
                let ramMode = dm.bus.ramMode
                print(String(format: "  Frame %d: PC=%04X SP=%04X subPC=%04X subT=%llu pcn=%d fdcInts=%d rm=%d IFF=%d IM=%d t=%.2fs",
                      frame, dm.cpu.pc, dm.cpu.sp, dm.subSystem.subCpu.pc,
                      subDelta, curPCN0, fdcIntDelta, ramMode ? 1 : 0,
                      dm.cpu.iff1 ? 1 : 0, dm.cpu.im, elapsed))
            }
            if curPCN0 != prevPCN0 {
                print(String(format: "    *** FDC pcn[0] changed: %d → %d at frame %d", prevPCN0, curPCN0, frame))
            }
            prevPCN0 = curPCN0
            prevFDCIntCount = curFDCInt
            // At crash frame, dump key info
            if frame == 24 {
                print(String(format: "    CPU: AF=%04X BC=%04X DE=%04X HL=%04X SP=%04X",
                      dm.cpu.af, dm.cpu.bc, dm.cpu.de, dm.cpu.hl, dm.cpu.sp))
                // Code at 0x9000 (where game jumps to)
                let code9000 = (0..<16).map { String(format: "%02X", dm.bus.mainRAM[0x9000 + $0]) }.joined(separator: " ")
                print("    RAM[9000]: \(code9000)")
                // Sub-CPU RAM 0x7800-0x78FF (full file search routine + data)
                print("    Sub-CPU RAM 0x7800-0x78FF:")
                for base in stride(from: 0x7800, to: 0x7900, by: 16) {
                    let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
                    print(String(format: "      %04X: %@", base, bytes))
                }
                // Sub-CPU RAM 0x7900-0x7960 (more routines)
                print("    Sub-CPU RAM 0x7900-0x7960:")
                for base in stride(from: 0x7900, to: 0x7960, by: 16) {
                    let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
                    print(String(format: "      %04X: %@", base, bytes))
                }
                // Sub-CPU work area 0x7F00-0x7F30
                print("    Sub-CPU work area 0x7F00-0x7F30:")
                for base in stride(from: 0x7F00, to: 0x7F30, by: 16) {
                    let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
                    print(String(format: "      %04X: %@", base, bytes))
                }
                // Total FDC interrupt count
                print("    FDC total interrupts: \(dm.subSystem.fdcInterruptDeliveredCount)")
                print("    FDC pcn: [\(dm.subSystem.fdc.pcn[0]), \(dm.subSystem.fdc.pcn[1])]")
            }
            // Safety: abort if single frame takes > 30s
            if elapsed > 30.0 {
                print("  ABORT: total elapsed \(elapsed)s > 30s at frame \(frame)")
                print(String(format: "    subPC=%04X subIFF=%d subHalt=%d fdcPending=%d",
                      dm.subSystem.subCpu.pc, dm.subSystem.subCpu.iff1 ? 1 : 0,
                      dm.subSystem.subCpu.halted ? 1 : 0,
                      dm.subSystem.fdc.interruptPending ? 1 : 0))
                // FDC state
                print("    FDC phase=\(dm.subSystem.fdc.phase) pcn=[\(dm.subSystem.fdc.pcn[0]),\(dm.subSystem.fdc.pcn[1])]")
                // Dump sub-CPU code around current PC
                let spc = Int(dm.subSystem.subCpu.pc)
                let start = max(0, spc - 8)
                let end = min(0x2000, spc + 16)
                print("    Code around subPC:")
                for addr in stride(from: start, to: end, by: 1) {
                    let marker = addr == spc ? ">" : " "
                    print(String(format: "    %s%04X: %02X", marker, addr, dm.subSystem.subBus.romram[addr]), terminator: "")
                }
                print()
                print("    Sub SP=\(String(format: "%04X", dm.subSystem.subCpu.sp))")
                // Stack contents
                let sp = Int(dm.subSystem.subCpu.sp)
                if sp < 0x7FFE {
                    print("    Stack:", (0..<6).map {
                        String(format: "%02X", dm.subSystem.subBus.romram[(sp + $0) & 0x7FFF])
                    }.joined(separator: " "))
                }
                // Sub-CPU registers
                print(String(format: "    Sub AF=%04X BC=%04X DE=%04X HL=%04X",
                      dm.subSystem.subCpu.af, dm.subSystem.subCpu.bc,
                      dm.subSystem.subCpu.de, dm.subSystem.subCpu.hl))
                // Check PIO state
                let mainCH = dm.subSystem.pio.portC[0][0].data
                let mainCL = dm.subSystem.pio.portC[0][1].data
                let subCH = dm.subSystem.pio.portC[1][0].data
                let subCL = dm.subSystem.pio.portC[1][1].data
                print(String(format: "    PIO: main CH=%02X CL=%02X sub CH=%02X CL=%02X",
                      mainCH, mainCL, subCH, subCL))
                // Sub-CPU RAM first 64 bytes (work area at 0x4000)
                print("    SubRAM 4000:", (0..<32).map {
                    String(format: "%02X", dm.subSystem.subBus.romram[0x4000 + $0])
                }.joined(separator: " "))
                break
            }

#if DEBUG
            dumpTextDMASnapshotIfRequested(machine: dm, frame: frame, label: diskPath)
#endif
        }

#if DEBUG
        if textDMASnapshotPath != nil && !textDMASnapshotWritten {
            dumpTextDMASnapshotIfRequested(
                machine: dm,
                frame: diskBootFrames - 1,
                label: "\(diskPath) (final)",
                force: true
            )
        }
#endif

        // Final summary
        print("\n  === Final State ===")
        print("  FDC: phase=\(dm.subSystem.fdc.phase) pcn=[\(dm.subSystem.fdc.pcn[0]),\(dm.subSystem.fdc.pcn[1])]")
        print("  FDC total interrupts: \(dm.subSystem.fdcInterruptDeliveredCount)")
        print("  INT3 total: \(int3Count)")
        print(String(format: "  Sub: PC=%04X AF=%04X SP=%04X",
              dm.subSystem.subCpu.pc, dm.subSystem.subCpu.af, dm.subSystem.subCpu.sp))
        print(String(format: "  Main flags: E6BA=%02X E6CA=%02X EFCD=%02X EFCF=%02X",
                     dm.bus.memRead(0xE6BA), dm.bus.memRead(0xE6CA),
                     dm.bus.memRead(0xEFCD), dm.bus.memRead(0xEFCF)))
        print(String(
            format: "  OPNA timers: reg24=%02X reg25=%02X reg26=%02X reg27=%02X reg29=%02X stat=%02X ext=%02X",
            dm.sound.registers[0x24],
            dm.sound.registers[0x25],
            dm.sound.registers[0x26],
            dm.sound.registers[0x27],
            dm.sound.registers[0x29],
            dm.sound.readStatus(),
            dm.sound.readExtStatus()
        ))
        print(String(
            format: "  OPNA timerA: value=%03X counter=%d enabled=%d irq=%d overflow=%d",
            dm.sound.timerAValue,
            dm.sound.timerACounter,
            dm.sound.timerAEnabled ? 1 : 0,
            dm.sound.timerAIRQEnable ? 1 : 0,
            dm.sound.timerAOverflow ? 1 : 0
        ))
        print(String(
            format: "  OPNA timerB: value=%02X counter=%d enabled=%d irq=%d overflow=%d",
            dm.sound.timerBValue,
            dm.sound.timerBCounter,
            dm.sound.timerBEnabled ? 1 : 0,
            dm.sound.timerBIRQEnable ? 1 : 0,
            dm.sound.timerBOverflow ? 1 : 0
        ))
        print("  Display: " +
              "text=\(dm.bus.textDisplayEnabled ? 1 : 0) " +
              "80col=\(dm.bus.columns80 ? 1 : 0) " +
              "color=\(dm.bus.colorMode ? 1 : 0) " +
              "400line=\(dm.bus.is400LineMode ? 1 : 0) " +
              "ramMode=\(dm.bus.ramMode ? 1 : 0) " +
              "gvPlane=\(dm.bus.gvramPlane)")
        if let crashFrame {
            print("  Crash frame: \(crashFrame)")
        }
        if let stopReason {
            print("  Stop reason: \(stopReason)")
        }
        if audioSummaryEnabled {
            print("  Audio frames with output: \(audioFramesWithOutput)")
            if let firstAudioFrame {
                print(String(format: "  First audio frame: %d peak=%.6f", firstAudioFrame, audioPeak))
            }
        }
        // FM register trace removed in refactor
        _ = fmTraceEnabled
        if irqTraceEnabled {
            print("  Sound IRQ asserts: \(soundIRQAssertCount)")
            if let firstSoundIRQAssertFrame {
                print("  First sound IRQ assert frame: \(firstSoundIRQAssertFrame)")
            }
            print(String(format: "  Interrupt state: pending=%02X threshold=%d maskSound=%d",
                         dm.interruptBox.controller.pendingLevels,
                         dm.interruptBox.controller.levelThreshold,
                         dm.interruptBox.controller.maskSound ? 1 : 0))
        }
        if let lowEntryFromPC, let lowEntryToPC, let lowEntrySP {
            print(String(format: "  First low-PC entry: %04X -> %04X SP=%04X",
                         lowEntryFromPC, lowEntryToPC, lowEntrySP))
        }
        let finalText = dm.bus.readTextVRAM()
        print("  Text VRAM rows:")
        for row in 0..<25 {
            let base = row * 80
            guard base + 80 <= finalText.count else { break }
            var line = ""
            for col in 0..<80 {
                let ch = finalText[base + col]
                if ch >= 0x20 && ch < 0x7F {
                    line.append(String(UnicodeScalar(ch)))
                } else if ch == 0x00 {
                    line.append(" ")
                } else {
                    line.append(".")
                }
            }
            let trimmed = String(line.reversed().drop(while: { $0 == " " }).reversed())
            if !trimmed.isEmpty {
                print("    Row \(row): \"\(trimmed)\"")
            }
        }
        print("  Tracked main RAM writes:")
        for addr in trackedMainRAMAddresses {
            let initial = trackedMainRAMInitial[addr] ?? 0
            let final = trackedMainRAMLastValue[addr] ?? initial
            if let frame = trackedMainRAMFirstChangeFrame[addr] {
                print(String(format: "    %04X: %02X -> %02X (first changed at frame %d)",
                             addr, initial, final, frame))
            } else {
                print(String(format: "    %04X: %02X (unchanged)", addr, initial))
            }
        }
        if !watchTraceLines.isEmpty {
            print("\n  === Watch Trace (last 120 entries) ===")
            for line in watchTraceLines.suffix(120) {
                print("    \(line)")
            }
            if let watchTracePath {
                do {
                    try watchTraceLines.joined(separator: "\n").write(
                        toFile: watchTracePath,
                        atomically: true,
                        encoding: .utf8
                    )
                    print("  Watch trace written to \(watchTracePath)")
                } catch {
                    print("  Failed to write watch trace: \(error)")
                }
            }
        }
        if let portTracePath, !portTraceLines.isEmpty {
            do {
                try portTraceLines.joined(separator: "\n").write(
                    toFile: portTracePath,
                    atomically: true,
                    encoding: .utf8
                )
                print("  Port trace (\(portTraceLines.count) entries) written to \(portTracePath)")
            } catch {
                print("  Failed to write port trace: \(error)")
            }
        }
        if let pioFlowHandle {
            pioFlowHandle.closeFile()
            print("  PIO flow trace (\(pioFlowSeq) entries) written to \(pioFlowPath!)")
        }
        if !mainRAMDumpRegions.isEmpty {
            print("\n  === Main RAM Dumps ===")
            for region in mainRAMDumpRegions {
                print(String(format: "  %04X (+%X)", region.start, region.length))
                let end = min(0x10000, Int(region.start) + region.length)
                for base in stride(from: Int(region.start), to: end, by: 16) {
                    let bytes = (0..<16).compactMap { offset -> String? in
                        let addr = base + offset
                        guard addr < end else { return nil }
                        return String(format: "%02X", dm.bus.mainRAM[addr])
                    }.joined(separator: " ")
                    print(String(format: "    %04X: %@", base, bytes))
                }
            }
        }
        if !subRAMDumpRegions.isEmpty {
            print("\n  === Sub RAM Dumps ===")
            for region in subRAMDumpRegions {
                print(String(format: "  %04X (+%X)", region.start, region.length))
                let end = min(0x10000, Int(region.start) + region.length)
                for base in stride(from: Int(region.start), to: end, by: 16) {
                    let bytes = (0..<16).compactMap { offset -> String? in
                        let addr = base + offset
                        guard addr < end else { return nil }
                        return String(format: "%02X", dm.subSystem.subBus.romram[addr])
                    }.joined(separator: " ")
                    print(String(format: "    %04X: %@", base, bytes))
                }
            }
        }
        if let memoryDumpDirectory {
            let url = URL(fileURLWithPath: memoryDumpDirectory)
            do {
                let files = try MemoryDump.write(
                    machine: dm,
                    to: url,
                    metadata: [
                        "disk": diskPath,
                        "frames": "\(diskBootFrames)",
                        "turbo": "\(turboMultiplier)",
                        "drive0_image": "\(drive0ImageIndex)",
                        "drive1_image": "\(drive1ImageIndex)",
                        "use_run_frame": "\(useRunFrame)",
                    ]
                )
                print("\n  Memory dump (\(files.count) files) written to \(memoryDumpDirectory)")
            } catch {
                print("\n  Memory dump failed: \(error)")
            }
        }
        if stopFromPC != 0 || stopToPC != 0 {
            print(String(format: "  Stop PCs: %04X -> %04X SP=%04X ramMode=%d romN88=%d",
                         stopFromPC, stopToPC, stopSP,
                         dm.bus.ramMode ? 1 : 0, dm.bus.romModeN88 ? 1 : 0))
            let fromStart = max(0, Int(stopFromPC) - 16)
            let fromEnd = min(0x10000, Int(stopFromPC) + 16)
            print("  Code around stopFrom:")
            for base in stride(from: fromStart, to: fromEnd, by: 16) {
                let bytes = (0..<16).compactMap { offset -> String? in
                    let addr = base + offset
                    guard addr < 0x10000 else { return nil }
                    return String(format: "%02X", dm.bus.memRead(UInt16(addr)))
                }.joined(separator: " ")
                print(String(format: "    %04X: %@", base, bytes))
            }
            let toStart = max(0, Int(stopToPC) - 16)
            let toEnd = min(0x10000, Int(stopToPC) + 16)
            print("  Code around stopTo:")
            for base in stride(from: toStart, to: toEnd, by: 16) {
                let bytes = (0..<16).compactMap { offset -> String? in
                    let addr = base + offset
                    guard addr < 0x10000 else { return nil }
                    return String(format: "%02X", dm.bus.memRead(UInt16(addr)))
                }.joined(separator: " ")
                print(String(format: "    %04X: %@", base, bytes))
            }
            let spStart = max(0, Int(stopSP) - 16)
            let spEnd = min(0x10000, Int(stopSP) + 32)
            print("  Stack around SP:")
            for base in stride(from: spStart, to: spEnd, by: 16) {
                let bytes = (0..<16).compactMap { offset -> String? in
                    let addr = base + offset
                    guard addr < 0x10000 else { return nil }
                    return String(format: "%02X", dm.bus.memRead(UInt16(addr)))
                }.joined(separator: " ")
                print(String(format: "    %04X: %@", base, bytes))
            }
        }

        // Dump FDC command log
        let log = dm.subSystem.fdc.commandLog
        print("\n  === FDC Command Log (\(log.count) entries) ===")
        for (i, entry) in log.enumerated() {
            let params = entry.params.map { String(format: "%02X", $0) }.joined(separator: " ")
            let cmd = entry.command.padding(toLength: 20, withPad: " ", startingAt: 0)
            print(String(format: "  [%3d] %@ params=[%@] ST0=%02X ST1=%02X ST2=%02X data=%d CHRN=(%d,%d,%d,%d)",
                  i, cmd, params, entry.st0, entry.st1, entry.st2, entry.dataSize,
                  entry.resultCHRN.c, entry.resultCHRN.h, entry.resultCHRN.r, entry.resultCHRN.n))
        }

        if !pcLog.isEmpty {
            print("\n  PC transitions (high→low):")
            for entry in pcLog.prefix(10) {
                print(String(format: "    frame %d: PC=%04X", entry.frame, entry.pc))
            }
        }

        let shouldPrintExecutionRings = crashFrame != nil || stopReason != nil

        if shouldPrintExecutionRings && mainStepRingCount > 0 {
            print("\n  === Main CPU Steps Before Stop (\(min(mainStepRingCount, 256)) entries) ===")
            let showCount = min(mainStepRingCount, 256)
            let start = (mainStepRingIndex - showCount + mainStepRingSize) % mainStepRingSize
            for i in 0..<showCount {
                let idx = (start + i) % mainStepRingSize
                guard let step = mainStepRing[idx] else { continue }
                print(String(format: "    f=%d PC=%04X OP=%02X SP=%04X AF=%04X BC=%04X DE=%04X HL=%04X",
                      step.frame, step.pc, step.op, step.sp, step.af, step.bc, step.de, step.hl))
            }
        }

        if shouldPrintExecutionRings && mainJumpRingCount > 0 {
            print("\n  === Main CPU Control Transfers (\(mainJumpRingCount) entries) ===")
            let showCount = mainJumpRingCount
            let start = (mainJumpRingIndex - showCount + mainJumpRingSize) % mainJumpRingSize
            for i in 0..<showCount {
                let idx = (start + i) % mainJumpRingSize
                guard let jump = mainJumpRing[idx] else { continue }
                print(String(format: "    f=%d %04X -> %04X OP=%02X SP=%04X AF=%04X BC=%04X DE=%04X HL=%04X",
                      jump.frame, jump.fromPC, jump.toPC, jump.op,
                      jump.sp, jump.af, jump.bc, jump.de, jump.hl))
            }
        }

        // I/O trace skipped (traceLog may be too large and cause SIGSEGV)

        // Dump main RAM at key addresses for diagnosis
        print("\n  === Main RAM Key Areas ===")
        for base in [0x0000, 0x0020, 0x0038, 0x0100, 0x0400, 0x8000, 0x9000] {
            let bytes = (0..<16).map { String(format: "%02X", dm.bus.mainRAM[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // Sub-CPU RAM around idle loop
        print("  Sub-CPU RAM around idle loop (0x4000-0x4060):")
        for base in stride(from: 0x4000, to: 0x4060, by: 16) {
            let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // Sub-CPU command 0x09 handler and surrounding code
        print("  Sub-CPU command handler area (0x4090-0x4120):")
        for base in stride(from: 0x4090, to: 0x4120, by: 16) {
            let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // Sub-CPU FDC handling code (0x47D0-0x4830)
        print("  Sub-CPU FDC area (0x47D0-0x4830):")
        for base in stride(from: 0x47D0, to: 0x4830, by: 16) {
            let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // Sub-CPU full code dump for analysis (0x4460-0x4480, 0x4920-0x4960)
        // Sub-CPU state area
        print("  Sub-CPU state (0x49A0-0x49E0):")
        for base in stride(from: 0x49A0, to: 0x49E0, by: 16) {
            let bytes = (0..<16).map { String(format: "%02X", dm.subSystem.subBus.romram[base + $0]) }.joined(separator: " ")
            print(String(format: "    %04X: %@", base, bytes))
        }
        // PIO state
        let mainCH = dm.subSystem.pio.portC[0][0]
        let mainCL = dm.subSystem.pio.portC[0][1]
        let subCH = dm.subSystem.pio.portC[1][0]
        let subCL = dm.subSystem.pio.portC[1][1]
        print(String(format: "  PIO portC: mainCH=%02X mainCL=%02X subCH=%02X subCL=%02X",
                     mainCH.data, mainCL.data, subCH.data, subCL.data))
        print(String(format: "  PIO portC contFlag: main=%d sub=%d",
                     mainCL.contFlag ? 1 : 0, subCL.contFlag ? 1 : 0))
        // IM2 vector table (if I register is set)
        let iReg = dm.cpu.i
        if iReg != 0 {
            print(String(format: "  IM2 vectors (I=%02X):", iReg))
            for level in 0..<8 {
                let vecAddr = (UInt16(iReg) << 8) | UInt16(level * 2)
                let lo = UInt16(dm.bus.memRead(vecAddr))
                let hi = UInt16(dm.bus.memRead(vecAddr &+ 1))
                let isrAddr = (hi << 8) | lo
                print(String(format: "    Level %d: vec@%04X → ISR@%04X", level, vecAddr, isrAddr))
            }
        }
        // Interrupt controller state
        let ic = dm.interruptBox.controller
        print(String(format: "  IntCtrl: threshold=%d SGS=%d pending=%02X maskVRTC=%d maskRTC=%d maskSound=%d",
                     ic.levelThreshold, ic.sgsMode ? 1 : 0, ic.pendingLevels,
                     ic.maskVRTC ? 1 : 0, ic.maskRTC ? 1 : 0, ic.maskSound ? 1 : 0))

        if let screenshotPath {
            do {
                let pixels = renderCurrentFrame(machine: dm)
                try writePPMScreenshot(path: screenshotPath, pixels: pixels)
                print("  Screenshot written to \(screenshotPath)")
            } catch {
                print("  Failed to write screenshot to \(screenshotPath): \(error)")
            }
        }

    }
} else {
    print("\n  Disk image not found at \(diskPath) — skipping disk boot test")
}

print("\nDone.")
