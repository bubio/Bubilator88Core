@_exported import FMSynthesis
@_exported import Peripherals
import Logging

private let busLog = Logger(label: "EmulatorCore.Pc88Bus")

/// Format a byte as a zero-padded 2-digit hex string (no Foundation needed)
@inline(__always) private func hex(_ v: UInt8) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return s.count == 1 ? "0\(s)" : s
}

/// PC-8801-FA Bus implementation — memory map, I/O port dispatch.
///
/// Memory layout (default, N88-BASIC V2 ROM mode):
///   0x0000-0x5FFF: N88-BASIC ROM (24KB)
///   0x6000-0x7FFF: N88-BASIC ROM / Ext ROM bank (8KB)
///   0x8000-0x83FF: Text window (1KB via port 0x70)
///   0x8400-0xBFFF: Main RAM
///   0xC000-0xFFFF: GVRAM (plane selected) or Main RAM
///
/// Unimplemented ports return 0xFF.
public final class Pc88Bus: Bus {

    public enum TextDisplayMode: Equatable, CustomStringConvertible {
        case disabled
        case enabled
        case attributesOnly

        public var description: String {
            switch self {
            case .disabled:
                return "disabled"
            case .enabled:
                return "enabled"
            case .attributesOnly:
                return "attributesOnly"
            }
        }
    }

    // MARK: - Memory

    /// 64KB Main RAM
    public var mainRAM: [UInt8] = Array(repeating: 0x00, count: 65536)

    /// Graphic VRAM: 3 planes x 16KB
    /// Index 0=Blue, 1=Red, 2=Green
    public var gvram: [[UInt8]] = Array(repeating: Array(repeating: 0x00, count: 0x4000), count: 3)

    // MARK: - ROM

    /// N88-BASIC ROM (32KB). Nil if not loaded.
    public var n88BasicROM: [UInt8]?

    /// N-BASIC ROM (32KB). Nil if not loaded.
    public var nBasicROM: [UInt8]?

    /// N88 Extended ROM banks (4 banks x 8KB). Nil if not loaded.
    public var n88ExtROM: [[UInt8]]?

    // MARK: - Banking State

    /// Port 0x31 bit 1 (RMODE): false=N-BASIC, true=N88-BASIC
    public var romModeN88: Bool = true

    /// Port 0x31 bit 2 (MMODE): false=ROM at 0x0000-0x7FFF, true=RAM
    public var ramMode: Bool = false

    /// Currently selected GVRAM plane (0-2), or -1 for main RAM.
    /// Controlled by port 0x5C-0x5F writes.
    public var gvramPlane: Int = -1

    /// Port 0x35 bit 7 (GAM): GVRAM access mode enable (Extended mode ALU access).
    public var gamMode: Bool = false

    /// Port 0x32 bit 6 (EVRAM): Extended VRAM access mode.
    /// false = Independent mode (port 0x5C-0x5F controls GVRAM plane access)
    /// true  = Extended mode (port 0x35 bit 7 controls ALU GVRAM access)
    /// Reference: QUASI88 MISC_CTRL_EVRAM, main_memory_vram_mapping()
    public var evramMode: Bool = false

    /// Port 0x71: Extended ROM bank select (active low)
    public var extROMBank: UInt8 = 0xFF

    /// Port 0x32 bit 0-1 (EROMSL): N88 ext ROM bank number
    public var n88ExtROMSelect: UInt8 = 0

    /// Port 0x71 bit 0 (EXT_ROM_NOT): Ext ROM area enable (0x6000-0x7FFF), active low
    public var extROMEnabled: Bool = false

    /// Port 0x71 bits 7-1: external expansion ROM select lines (active low).
    /// Bubilator does not emulate external ROM boards yet, so any selected bit makes
    /// the 0x6000-0x7FFF window behave like an empty socket (open bus).
    private var externalExtROMSelected: Bool {
        (extROMBank & 0xFE) != 0xFE
    }

    /// Port 0x70: Text window offset
    public var textWindowOffset: UInt8 = 0

    // MARK: - Display Control

    /// Port 0x30 write: system control register
    public var port30w: UInt8 = 0

    /// Port 0x52: background/border color (bit 5=R, bit 4=G, bit 3=B)
    public var borderColor: UInt8 = 0

    /// Port 0x53: layer display control (QUASI88: grph_pile)
    /// All bits are SUPPRESS flags (1 = hide layer)
    /// bit 0: text layer suppress (GRPH_PILE_TEXT)
    /// bit 1: Blue GVRAM plane suppress (GRPH_PILE_BLUE)
    /// bit 2: Red GVRAM plane suppress (GRPH_PILE_RED)
    /// bit 3: Green GVRAM plane suppress (GRPH_PILE_GREEN)
    public var layerControl: UInt8 = 0

    /// Color/mono mode: true = color, false = mono
    public var colorMode: Bool = true

    /// Column width: true = 80 columns, false = 40 columns
    public var columns80: Bool = true

    /// Analog palette mode (512 colors): controlled by port 0x32 bit 5 (MISC_CTRL_ANALOG).
    /// false = 8-color digital, true = 512-color analog
    public var analogPalette: Bool = false

    /// Port 0x31 bit 3 (GRPH_CTRL_VDISP): GVRAM display enable.
    /// false = graphics hidden, true = graphics visible.
    /// Reference: QUASI88 GRPH_CTRL_VDISP (0x08), BubiC Port31_GRAPH
    public var graphicsDisplayEnabled: Bool = true

    /// Port 0x31 bit 4 (GRPH_CTRL_COLOR): Graphics color/mono mode.
    /// false = mono/attribute mode, true = 8-color mode.
    /// Reference: QUASI88 GRPH_CTRL_COLOR (0x10), BubiC Port31_HCOLOR
    public var graphicsColorMode: Bool = true

    /// Port 0x31 bit 0 (GRPH_CTRL_200): 200/400 line mode select.
    /// true = 200-line mode, false = 400-line mode.
    /// Reference: QUASI88 GRPH_CTRL_200 (0x01), BubiC Port31_200LINE
    public var mode200Line: Bool = true

    /// True when 400-line monochrome mode is active.
    /// 400-line mode requires: mode200Line=false AND graphicsColorMode=false.
    /// Blue plane = upper 200 lines, Red plane = lower 200 lines.
    public var is400LineMode: Bool {
        !mode200Line && !graphicsColorMode
    }
 
    // MARK: - Extended RAM

    /// Extended RAM: up to 4 cards × 4 banks × 32KB = 512KB total.
    /// Indexed as [card][bank][offset], each bank is 32KB.
    /// Nil if no extended RAM is installed.
    public var extRAM: [[[UInt8]]]?

    /// Port 0xE2 bit 0 (WREN): Extended RAM write enable
    public var extRAMWriteEnable: Bool = false

    /// Port 0xE2 bit 4 (RDEN): Extended RAM read enable
    public var extRAMReadEnable: Bool = false

    /// Port 0xE3 bit 6-7: Selected card (0-3)
    public var extRAMCard: Int = 0

    /// Port 0xE3 bit 0-1: Selected bank (0-3)
    public var extRAMBank: Int = 0

    // MARK: - Kanji ROM

    /// Kanji ROM Level 1 data (128KB). Nil if not loaded.
    public var kanjiROM1: [UInt8]?

    /// Kanji ROM Level 2 data (128KB). Nil if not loaded.
    public var kanjiROM2: [UInt8]?

    /// Kanji ROM Level 1 address register (ports 0xE8-0xE9)
    public var kanjiAddr1: UInt16 = 0

    /// Kanji ROM Level 2 address register (ports 0xEC-0xED)
    public var kanjiAddr2: UInt16 = 0

    // MARK: - ALU State

    /// Port 0x34: ALU control register 1 (per-plane operations)
    public var aluControl1: UInt8 = 0

    /// Port 0x35: ALU control register 2 (GAM, GDM, compare data)
    public var aluControl2: UInt8 = 0

    /// ALU registers: loaded during ALU-mode GVRAM reads, used by GDM write-back modes.
    /// [0]=Blue, [1]=Red, [2]=Green. Reference: BubiC alu_reg[3]
    public var aluReg: [UInt8] = [0, 0, 0]

    // MARK: - System State

    /// Port 0x31 full register value (for mode tracking)
    public var port31: UInt8 = 0

    /// Port 0x32 full register value
    public var port32: UInt8 = 0

    /// Port 0x40 write register (beep, joystick, calendar, CRT sync)
    public var port40w: UInt8 = 0

    /// CPU clock: true=8MHz, false=4MHz
    public var cpuClock8MHz: Bool = true

    /// V1S / V1 mode memory wait: when DIP SW2 bit 6 (SW_H) is 0 the machine
    /// behaves as V1S — the real PC-8801 inserts extra wait states on main
    /// memory R/W to emulate V1 compatibility speed. When SW_H=1 (V1H/V2)
    /// no extra wait is applied. Matches BubiC `pc88.cpp:2275-2340` (XM8
    /// version 1.20 wait model, memory-wait branch).
    @inline(__always)
    public var v1sMemWait: Bool { (dipSw2 & 0x40) == 0 }

    /// VRTC flag (set by CRTC during vertical blanking)
    public var vrtcFlag: Bool = false

    /// When true, port 0x09 bit 0 (STOP key) is forced low to skip disk boot
    /// and start N88-BASIC directly (simulates holding STOP during power-on).
    /// Default false: cold boot shows "How many files?" prompt (correct behavior).
    /// Warm boot (STOP held) skips workspace LDIR init, causing E69F garbage.
    public var directBasicBoot: Bool = false

    /// Memory WAIT: accumulated wait T-states from memory access (8MHz main RAM +1T,
    /// GVRAM: 8MHz active+graphOn=+5T, vblank/graphOff=+3T; 4MHz active+graphOn=+2T).
    /// Machine reads and clears this after each CPU step.
    public var pendingWaitStates: Int = 0

    /// V2 high-speed text RAM (0xF000-0xFFFF, 4KB).
    /// Separate buffer from mainRAM, used when tvramEnabled=true.
    public var tvram: [UInt8] = Array(repeating: 0x00, count: 4096)

    /// When true, CPU and DMA accesses to 0xF000-0xFFFF route to tvram instead of mainRAM.
    /// Controlled by Port 0x32 bit 4 (TMODE): TMODE=0 → tvram enabled, TMODE=1 → mainRAM.
    public var tvramEnabled: Bool = false

    // MARK: - Palette

    /// 8-entry palette. Each entry: (blue, red, green) in 3-bit (0-7) range.
    /// Port 0x54-0x5B: each port sets one palette entry.
    /// Digital mode: bit 0=B, bit 1=R, bit 2=G (1 bit per color, stored as 0 or 7).
    /// Analog mode: bit 6=0 → bits 0-2=B, 3-5=R; bit 6=1 → bits 0-2=G.
    public var palette: [(b: UInt8, r: UInt8, g: UInt8)] = Pc88Bus.defaultPalette

    /// Default 8-color palette (standard PC-8801)
    public static let defaultPalette: [(b: UInt8, r: UInt8, g: UInt8)] = [
        (0, 0, 0),  // 0: Black
        (7, 0, 0),  // 1: Blue
        (0, 7, 0),  // 2: Red
        (7, 7, 0),  // 3: Magenta
        (0, 0, 7),  // 4: Green
        (7, 0, 7),  // 5: Cyan
        (0, 7, 7),  // 6: Yellow
        (7, 7, 7),  // 7: White
    ]

    // MARK: - Keyboard

    /// Keyboard reference for port 0x00-0x0E reads
    public weak var keyboard: Keyboard?

    // MARK: - Component References (weak to avoid retain cycles)

    /// Interrupt controller reference for port 0xE4/0xE6 writes
    public weak var interruptController: InterruptControllerRef?

    /// CRTC reference for port 0x50/0x51
    public weak var crtc: CRTC?

    /// YM2608 reference for port 0x44-0x47
    public weak var sound: YM2608?

    /// Called when SINTM transitions from masked→unmasked (port 0x32 bit 7: 1→0).
    /// Machine wires this to re-request sound IRQ if the OPNA line is still active.
    public var onSoundUnmask: (() -> Void)?

    /// Debug: main CPU PC, updated by Machine before each step
    public var debugMainPC: UInt16 = 0

    /// SubSystem reference for port 0xFC-0xFF
    public weak var subSystem: SubSystem?

    /// DMA controller reference for port 0x60-0x68
    public weak var dma: DMAController?

    /// uPD1990A calendar chip for port 0x10 / port 0x40 bit 4
    public var calendar: UPD1990A?

    /// μPD8251 USART for port 0x20/0x21 (CMT / RS-232C)
    public var usart: I8251?

    /// Cassette deck — pumps bytes into `usart` while motor is on and
    /// port 0x30 has CMT selected.
    public var cassette: CassetteDeck?

    // MARK: - Trace

    /// Optional callback invoked on every I/O read/write for trace logging.
    /// Parameters: (port, value, isWrite)
    public var onIOAccess: ((UInt16, UInt8, Bool) -> Void)?

    // MARK: - Debugger access hooks

    /// Optional debugger hooks invoked on every main-bus access. Each
    /// is `nil` by default so the hot path pays only a single pointer
    /// comparison when no debugger is attached. The debugger uses
    /// these to implement memory / I/O breakpoints — it updates its
    /// own paused-state flag; the caller does not inspect a return
    /// value because we cannot unwind a mid-instruction fetch anyway.
    public var onDebuggerMemRead:  ((UInt16) -> Void)?
    public var onDebuggerMemWrite: ((UInt16, UInt8) -> Void)?
    public var onDebuggerIORead:   ((UInt16) -> Void)?
    public var onDebuggerIOWrite:  ((UInt16, UInt8) -> Void)?

    /// Tracks unimplemented ports that have been read (for debugging).
    /// Each port is logged once on first access.
    public var unimplementedReadPorts: Set<UInt8> = []

    /// Tracks unimplemented ports that have been written (for debugging).
    public var unimplementedWritePorts: Set<UInt8> = []

#if DEBUG
    /// Recent I/O on ports that affect text DMA / overlay eligibility.
    public private(set) var recentTextDMAIO: [TextDMADebugSnapshot.IOEvent] = []
    private let recentTextDMAIOMax = 40
#endif

    // MARK: - Init

    public init() {}

    /// Cold reset — initialize all state
    public func reset() {
        powerOnRAMInit()
        gvram = Array(repeating: Array(repeating: 0x00, count: 0x4000), count: 3)

        romModeN88 = true
        ramMode = false
        gvramPlane = -1
        gamMode = false
        evramMode = false
        extROMBank = 0xFF
        n88ExtROMSelect = 0
        extROMEnabled = false
        textWindowOffset = 0
        aluControl1 = 0
        aluControl2 = 0
        aluReg = [0, 0, 0]
        port31 = 0
        port32 = 0
        port40w = 0
        cpuClock8MHz = true
        vrtcFlag = false
        palette = Pc88Bus.defaultPalette
        extRAMWriteEnable = false
        extRAMReadEnable = false
        extRAMCard = 0
        extRAMBank = 0
        kanjiAddr1 = 0
        kanjiAddr2 = 0
        port30w = 0
        borderColor = 0
        layerControl = 0
        colorMode = true
        columns80 = true
        analogPalette = false
        graphicsDisplayEnabled = true
        graphicsColorMode = true
        mode200Line = true
        pendingWaitStates = 0
        tvram = Array(repeating: 0x00, count: 4096)
        tvramEnabled = true  // Port 0x32 initial=0x00 → TMODE=0 → tvram enabled
        nBasicROMWarned = false
        calendar?.reset()
        unimplementedReadPorts.removeAll()
        unimplementedWritePorts.removeAll()
#if DEBUG
        recentTextDMAIO.removeAll()
#endif
    }

    // MARK: - Power-on RAM Init

    /// QUASI88 互換: 電源投入時の RAM パターン初期化
    /// 実機では DRAM セルの電荷パターンにより 0x00/0xFF が交互に出現する。
    /// N88-BASIC ROM の初期化コードはこのパターンに依存している。
    private func powerOnRAMInit() {
        // QUASI88 互換: power_on_ram_init (pc88main.c:3274-3333)
        // DRAM power-on pattern — some commercial software depends on specific values.
        mainRAM = Array(repeating: 0x00, count: 65536)

        // Step 1: 0x0000-0x3FFF — address-dependent 0x00/0xFF alternating blocks
        for addrBase in stride(from: 0, to: 0x4000, by: 0x100) {
            var data: UInt8

            if (addrBase & 0x0D00) == 0x0100 || (addrBase & 0x0D00) == 0x0C00 {
                data = 0xFF  // x100, x300, xC00, xE00
            } else if (addrBase & 0x0F00) == 0x0500 && (addrBase & 0x2000) == 0x0000 {
                data = 0xFF  // 0500, 1500
            } else if (addrBase & 0x0F00) == 0x0A00 && (addrBase & 0x3000) != 0x0000 {
                data = 0xFF  // 1A00, 2A00, 3A00
            } else {
                data = 0x00
            }

            for i in 0..<4 {
                let base = addrBase + i * 64
                for j in 0..<16 { mainRAM[base + j] = data }
                for j in 16..<32 { mainRAM[base + j] = data ^ 0xFF }
                for j in 32..<48 { mainRAM[base + j] = data }
                for j in 48..<64 { mainRAM[base + j] = data ^ 0xFF }
                data ^= 0xFF
            }
        }

        // Step 2: 0x4000-0x7FFF — bitwise inverse of 0x0000-0x3FFF
        for addr in 0x4000..<0x8000 {
            mainRAM[addr] = mainRAM[addr &- 0x4000] ^ 0xFF
        }

        // Step 3: 0x8000-0xFFFF — mirror descending from 0x7F00
        for addrBase in stride(from: 0x8000, to: 0x10000, by: 0x100) {
            let srcBase = 0x7F00 &- (addrBase &- 0x8000)
            for i in 0..<0x100 {
                mainRAM[addrBase + i] = mainRAM[srcBase + i]
            }
        }

        // Step 4: 0xFF00-0xFFFE = 0xFF, 0xFFFF = 0x00
        // Required by: スキーム (0xFFFF==0x00), 天使たちの午後2 (0xFFF8..0xFFFF OR != 0)
        for addr in 0xFF00..<0xFFFF {
            mainRAM[addr] = 0xFF
        }
        mainRAM[0xFFFF] = 0x00

        // Warm boot save area: directBasicBoot path (STOP key held) skips ROM LDIR
        // and 0x72CD reads E6C0-E6C2 → ports 0x30/0x40/0x31. Pre-initialize with safe defaults.
        mainRAM[0xE6C0] = 0x01  // port 0x30: 80-column, color mode
        mainRAM[0xE6C1] = 0x00  // port 0x40: all controls off
        mainRAM[0xE6C2] = 0x01  // port 0x31: 200LINE=1, MMODE=0, RMODE=0
    }

    // MARK: - Bus Protocol

    public func memRead(_ addr: UInt16) -> UInt8 {
        onDebuggerMemRead?(addr)
        switch addr {
        case 0x0000..<0x6000:
            if cpuClock8MHz { pendingWaitStates += 1 }
            if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
            // Extended RAM read
            if extRAMReadEnable, let ext = extRAM,
               extRAMCard < ext.count, extRAMBank < ext[extRAMCard].count {
                return ext[extRAMCard][extRAMBank][Int(addr)]
            }
            // 0x0000-0x5FFF: ROM (24KB) or RAM
            if ramMode {
                return mainRAM[Int(addr)]
            }
            return readROM(addr)

        case 0x6000..<0x8000:
            if cpuClock8MHz { pendingWaitStates += 1 }
            if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
            // Extended RAM read
            if extRAMReadEnable, let ext = extRAM,
               extRAMCard < ext.count, extRAMBank < ext[extRAMCard].count {
                return ext[extRAMCard][extRAMBank][Int(addr)]
            }
            // MMODE=1 (64KB RAM mode): mainRAM を返す (QUASI88 confirmed)
            if ramMode {
                return mainRAM[Int(addr)]
            }
            // Ext ROM (4th ROM / external expansion) is only valid in N88 mode.
            // QUASI88 pc88main.c:411-422: in N-BASIC mode, 0x6000-0x7FFF always
            // comes from main_rom_n[0x6000] regardless of port 0x71 state.
            if romModeN88 {
                // Port 0x71 bits 7-1 select external expansion ROMs (active low).
                // If any external slot is selected and no board is emulated, the bus is open.
                if externalExtROMSelected {
                    return 0xFF
                }
                // 0x6000-0x7FFF: ROMバンク
                // When ext ROM is selected (port 0x71 bit 0 = 0):
                //   - If ext ROM data loaded → return ext ROM bank data
                //   - If ext ROM not loaded → return 0xFF (open bus, like empty socket)
                // When ext ROM is NOT selected → return standard ROM
                if extROMEnabled {
                    if let extBanks = n88ExtROM {
                        let bank = Int(n88ExtROMSelect & 0x03)
                        if bank < extBanks.count {
                            return extBanks[bank][Int(addr) - 0x6000]
                        }
                    }
                    return 0xFF  // ext ROM selected but not loaded → open bus
                }
            }
            return readROM(addr)

        case 0x8000..<0x8400:
            if cpuClock8MHz { pendingWaitStates += 1 }
            if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
            // テキストウィンドウ: MMODE=0 かつ RMODE=0 (N88-BASIC ROM) の場合
            // mainRAM 上の textWindowOffset ベースのアドレスにマップ
            // Reference: QUASI88 pc88main.c:555, BubiC pc88.cpp:777.
            // BubiC は F000h 台でも text window access を tvram に迂回させず、
            // 常に RAM shadow を直接読み書きする。
            if !ramMode && romModeN88 {
                let ramAddr = (Int(textWindowOffset) << 8) + Int(addr & 0x03FF)
                return mainRAM[ramAddr & 0xFFFF]
            }
            return mainRAM[Int(addr)]

        case 0x8400..<0xC000:
            if cpuClock8MHz { pendingWaitStates += 1 }
            if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
            // Always main RAM
            return mainRAM[Int(addr)]

        case 0xC000...0xFFFF:
            // GVRAM or main RAM (QUASI88 main_memory_vram_mapping + ALU_read)
            let offset = Int(addr) - 0xC000
            if evramMode {
                if gamMode {
                    // ALU read: load all 3 planes into registers, return comparison
                    // BubiC V1H/V2 8MHz: active+graphOn=5T, vblank/graphOff=3T
                    if cpuClock8MHz {
                        pendingWaitStates += vrtcFlag ? 3 : (graphicsDisplayEnabled ? 5 : 3)
                    } else {
                        if !vrtcFlag && graphicsDisplayEnabled { pendingWaitStates += 2 }
                    }
                    aluReg[0] = gvram[0][offset]
                    aluReg[1] = gvram[1][offset]
                    aluReg[2] = gvram[2][offset]
                    var b = aluReg[0]; if (aluControl2 & 0x01) == 0 { b ^= 0xFF }
                    var r = aluReg[1]; if (aluControl2 & 0x02) == 0 { r ^= 0xFF }
                    var g = aluReg[2]; if (aluControl2 & 0x04) == 0 { g ^= 0xFF }
                    return b & r & g
                }
                // evramMode + !gamMode: mainRAM/tvram access
                return readMainOrTvram(addr)
            }
            // Independent mode: bank access via gvramPlane
            if gvramPlane >= 0 && gvramPlane < 3 {
                // BubiC V1H/V2 8MHz: active+graphOn=5T, vblank/graphOff=3T
                if cpuClock8MHz {
                    pendingWaitStates += vrtcFlag ? 3 : (graphicsDisplayEnabled ? 5 : 3)
                } else {
                    if !vrtcFlag && graphicsDisplayEnabled { pendingWaitStates += 2 }
                }
                return gvram[gvramPlane][offset]
            }
            return readMainOrTvram(addr)

        default:
            return mainRAM[Int(addr)]
        }
    }

    public func memWrite(_ addr: UInt16, value: UInt8) {
        onDebuggerMemWrite?(addr, value)
        switch addr {
        case 0x0000..<0x8000:
            if cpuClock8MHz {
                pendingWaitStates += 1
                if v1sMemWait { pendingWaitStates += 1 }  // V1S 8MHz write wait
            }
            // Extended RAM write (in-place to avoid CoW copy of nested arrays)
            if extRAMWriteEnable, extRAM != nil,
               extRAMCard < extRAM!.count, extRAMBank < extRAM![extRAMCard].count {
                extRAM![extRAMCard][extRAMBank][Int(addr)] = value
                return
            }
            mainRAM[Int(addr)] = value

        case 0x8000..<0x8400:
            if cpuClock8MHz {
                pendingWaitStates += 1
                if v1sMemWait { pendingWaitStates += 1 }  // V1S 8MHz write wait
            }
            // テキストウィンドウ: MMODE=0 かつ RMODE=0 (N88-BASIC ROM) の場合
            if !ramMode && romModeN88 {
                let ramAddr = (Int(textWindowOffset) << 8) + Int(addr & 0x03FF)
                mainRAM[ramAddr & 0xFFFF] = value
            } else {
                mainRAM[Int(addr)] = value
            }

        case 0x8400..<0xC000:
            if cpuClock8MHz {
                pendingWaitStates += 1
                if v1sMemWait { pendingWaitStates += 1 }  // V1S 8MHz write wait
            }
            mainRAM[Int(addr)] = value

        case 0xC000...0xFFFF:
            // GVRAM or main RAM (QUASI88/BubiC: dual-mode logic)
            let offset = Int(addr) - 0xC000
            if evramMode {
                if gamMode {
                    // ALU write: GDM selects operation mode
                    // BubiC V1H/V2 8MHz: active+graphOn=5T, vblank/graphOff=3T
                    if cpuClock8MHz {
                        pendingWaitStates += vrtcFlag ? 3 : (graphicsDisplayEnabled ? 5 : 3)
                    } else {
                        if !vrtcFlag && graphicsDisplayEnabled { pendingWaitStates += 2 }
                    }
                    let gdm = aluControl2 & 0x30
                    switch gdm {
                    case 0x00: applyALU(addr: offset, value: value)
                    case 0x10:
                        gvram[0][offset] = aluReg[0]
                        gvram[1][offset] = aluReg[1]
                        gvram[2][offset] = aluReg[2]
                    case 0x20: gvram[0][offset] = aluReg[1]
                    default:   gvram[1][offset] = aluReg[0]  // 0x30
                    }
                } else {
                    // evramMode + !gamMode: mainRAM/tvram access
                    writeMainOrTvram(addr, value: value)
                }
            } else if gvramPlane >= 0 && gvramPlane < 3 {
                // Independent mode: direct write to selected plane
                // BubiC V1H/V2 8MHz: active+graphOn=5T, vblank/graphOff=3T
                if cpuClock8MHz {
                    pendingWaitStates += vrtcFlag ? 3 : (graphicsDisplayEnabled ? 5 : 3)
                } else {
                    if !vrtcFlag && graphicsDisplayEnabled { pendingWaitStates += 2 }
                }
                gvram[gvramPlane][offset] = value
            } else {
                writeMainOrTvram(addr, value: value)
            }

        default:
            mainRAM[Int(addr)] = value
        }
    }

    /// True when CPU accesses to 0xF000-0xFFFF should target the dedicated
    /// tvram buffer. Per QUASI88 `pc88main.c:365-370`/`:583-605`:
    ///   - V1S / !high_mode: always tvram (TMODE is ignored on CPU side —
    ///     the hidden main_high_ram bank is exclusive to high mode).
    ///   - V1H/V2 + TMODE=0: tvram (text display).
    ///   - V1H/V2 + TMODE=1: mainRAM (main_high_ram hidden buffer).
    @inline(__always)
    private var cpuUsesTvramForTextArea: Bool {
        // v1sMemWait == !swH == !high_mode
        tvramEnabled || v1sMemWait
    }

    /// Read from mainRAM or tvram (0xC000-0xFFFF fallthrough path).
    @inline(__always)
    private func readMainOrTvram(_ addr: UInt16) -> UInt8 {
        if cpuUsesTvramForTextArea && addr >= 0xF000 {
            if cpuClock8MHz { pendingWaitStates += 2 }  // tvram read wait
            return tvram[Int(addr) - 0xF000]
        }
        if cpuClock8MHz { pendingWaitStates += 1 }
        if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
        return mainRAM[Int(addr)]
    }

    /// Write to mainRAM or tvram (0xC000-0xFFFF fallthrough path).
    @inline(__always)
    private func writeMainOrTvram(_ addr: UInt16, value: UInt8) {
        if cpuUsesTvramForTextArea && addr >= 0xF000 {
            if cpuClock8MHz { pendingWaitStates += 1 }  // tvram write wait
            tvram[Int(addr) - 0xF000] = value
            return
        }
        if cpuClock8MHz {
            pendingWaitStates += 1
            if v1sMemWait { pendingWaitStates += 1 }  // V1S 8MHz write wait
        }
        mainRAM[Int(addr)] = value
    }

    public func ioRead(_ port: UInt16) -> UInt8 {
        onDebuggerIORead?(port)
        let rawPort = UInt8(port & 0xFF)
        let port8 = normalizeIOPort(rawPort)
        let value = _ioReadInternal(port8)
#if DEBUG
        recordTextDMAIO(port: port8, value: value, isWrite: false)
#endif
        onIOAccess?(UInt16(rawPort), value, false)
        return value
    }

    private func _ioReadInternal(_ port8: UInt8) -> UInt8 {
        switch port8 {
        // Keyboard matrix (0x00-0x0E)
        // Port 0x09 row 9 bit 0 = STOP key.
        // At boot, ROM checks this bit: bit0=0 (STOP pressed) → skip disk boot → direct BASIC.
        // We force bit 0 = 0 when no disk is mounted to simulate holding STOP at boot,
        // matching real PC-88 behavior for diskless operation (direct N88-BASIC start).
        case 0x09:
            let row9 = keyboard?.readRow(0x09) ?? 0xFF
            // directBasicBoot only applies in N88-BASIC ROM mode.
            // N-BASIC ROM has its own STOP key check that must see raw state.
            if directBasicBoot && romModeN88 { return row9 & 0xFE }
            return row9

        case 0x00...0x0E:
            return keyboard?.readRow(port8) ?? 0xFF

        // USART (uPD8251C) — CMT / RS-232C
        case 0x20:
            return usart?.readData() ?? 0x00
        case 0x21:
            return usart?.readStatus() ?? 0x05

        // DIP switch 1
        case 0x30:
            return dipSwitch1()

        // DIP switch 2
        case 0x31:
            return dipSwitch2()

        // Port 0x32 read
        case 0x32:
            return port32

        // Port 0x40 read: VRTC flag, control signals
        // BubiC (pc88.cpp:1895) / QUASI88 (pc88main.c:1665): bit 3 is NOT
        // exposed here — real hardware does not route the ROM/DISK boot
        // strap DIP through port 0x40. The strap is latched at reset into
        // dipSw2 bit 3 for the CPU's internal boot-mode decision only.
        // bits: 7-6=always 1, 5=VRTC, 4=calendar CDO, 3=always 0, 2=DCD
        case 0x40:
            var value: UInt8 = 0xC0  // bits 7-6 always 1
            if vrtcFlag { value |= 0x20 }  // bit 5: VRTC
            if calendar?.cdo == true { value |= 0x10 }  // bit 4: calendar CDO
            // bit 2: USART DCD. With a tape loaded, reflects CMT carrier
            // detection; otherwise defaults to 1 (matches QUASI88 stub).
            if let deck = cassette, deck.isLoaded {
                if deck.dcd { value |= 0x04 }
            } else {
                value |= 0x04
            }
            // bit 1: SHG — monitor type (hardware config).
            // XM8: hireso ? 0 : 2. QUASI88: HIGH_MODE ? 0 : 2.
            // PC-8801-FA has 24kHz monitor (hireso) → bit 1 = 0.
            // 15kHz monitor → bit 1 = 1 (0x02).
            return value

        // YM2608 ports
        case 0x44:
            return sound?.readStatus() ?? 0x00

        case 0x45:
            return sound?.readData() ?? 0x00

        case 0x46:
            return sound?.readExtStatus() ?? 0x00

        case 0x47:
            return sound?.readExtData() ?? 0x00

        // CRTC
        case 0x50:
            return crtc?.readParameter() ?? 0x00

        case 0x51:
            return crtc?.readStatus() ?? 0x00

        // GVRAM plane state — one-hot bitmask | 0xF8
        // QUASI88: (1 << memory_bank) | 0xF8  (bank: 0=B, 1=R, 2=G, 3=main)
        // BubiC: gvram_plane | 0xF8  (plane: 1=B, 2=R, 4=G, 0=main)
        // Returns: 0xF9=Blue, 0xFA=Red, 0xFC=Green, 0xF8=mainRAM
        case 0x5C:
            let bank = gvramPlane < 0 ? 3 : gvramPlane
            return UInt8(truncatingIfNeeded: (1 << bank) | 0xF8)

        // DMA controller
        case 0x60...0x68:
            return dma?.ioRead(port8) ?? 0xFF

        // CPU clock indicator (QUASI88: CPU_CLOCK_4HMZ = 0x80)
        case 0x6E:
            return cpuClock8MHz ? 0x00 : 0x80

        // Text window offset
        case 0x70:
            return textWindowOffset

        // Extended ROM bank select (read-back: returns last written value)
        // QUASI88/BubiC: both initialize to 0xFF and return the written value
        case 0x71:
            return extROMBank

        // Extended RAM mode (QUASI88: ~ext_ram_ctrl | 0xEE)
        case 0xE2:
            let ctrl: UInt8 = (extRAMReadEnable ? 0x01 : 0) | (extRAMWriteEnable ? 0x10 : 0)
            return ~ctrl | 0xEE

        // Kanji ROM Level 1 data (port 0xE9 = left, 0xE8 = right)
        case 0xE8:
            // Read right half of kanji glyph row
            if let rom = kanjiROM1 {
                let addr = Int(kanjiAddr1) * 2 + 1
                if addr < rom.count { return rom[addr] }
            }
            return 0xFF

        case 0xE9:
            // Read left half of kanji glyph row
            if let rom = kanjiROM1 {
                let addr = Int(kanjiAddr1) * 2
                if addr < rom.count { return rom[addr] }
            }
            return 0xFF

        // Kanji ROM Level 2 data (port 0xED = left, 0xEC = right)
        case 0xEC:
            // Read right half of kanji glyph row
            if let rom = kanjiROM2 {
                let addr = Int(kanjiAddr2) * 2 + 1
                if addr < rom.count { return rom[addr] }
            }
            return 0xFF

        case 0xED:
            // Read left half of kanji glyph row
            if let rom = kanjiROM2 {
                let addr = Int(kanjiAddr2) * 2
                if addr < rom.count { return rom[addr] }
            }
            return 0xFF

        // PIO (sub-CPU communication)
        case 0xFC...0xFF:
            return subSystem?.pioRead(port: port8) ?? 0xFF

        default:
            if unimplementedReadPorts.insert(port8).inserted {
                busLog.warning("Unimplemented I/O READ port 0x\(hex(port8))")
            }
            return 0xFF  // Unmapped ports return 0xFF
        }
    }

    public func ioWrite(_ port: UInt16, value: UInt8) {
        onDebuggerIOWrite?(port, value)
        let rawPort = UInt8(port & 0xFF)
        let port8 = normalizeIOPort(rawPort)
#if DEBUG
        recordTextDMAIO(port: port8, value: value, isWrite: true)
#endif
        onIOAccess?(UInt16(rawPort), value, true)

        switch port8 {
        // Port 0x00: Hudson PCG-8100 data write, and the QUASI88-compatible
        // high-speed CMT load trigger. Hudson's boot monitor exits BASIC
        // after CLOAD, drops two `OUT 0,0` (PCG reset), then `G BA00` —
        // the fast-loader runs on the first OUT and copies the machine-code
        // body from the tape into RAM so the G command has somewhere to
        // jump to. PCG itself is unimplemented; the fast-load path is the
        // only thing this write does today. See QUASI88 pc88main.c:960-967.
        // Port 0x00: Hudson PCG-8100 / QUASI88 high-speed CMT load
        case 0x00:
            performHighSpeedTapeLoad()

        // USART (uPD8251C)
        case 0x20:
            usart?.writeData(value)
        case 0x21:
            usart?.writeControl(value)

        // Port 0x30: System control (QUASI88: SYS_CTRL)
        case 0x30:
            port30w = value
            columns80 = (value & 0x01) != 0       // bit 0: SYS_CTRL_80 (1=80col, 0=40col)
            colorMode = (value & 0x02) == 0       // bit 1: SYS_CTRL_MONO (0=color, 1=mono)
            // bit 3: MTON (cassette motor), bit 5: BS (USART channel
            // 0=CMT, 1=RS-232C).
            if let deck = cassette {
                deck.motorOn = (value & 0x08) != 0
                deck.cmtSelected = (value & 0x20) == 0
            }

        // Port 0x31: Graphics control, ROM/RAM select
        case 0x31:
            port31 = value
            // QUASI88: GRPH_CTRL_200=0x01, GRPH_CTRL_64RAM=0x02, GRPH_CTRL_N=0x04
            mode200Line = (value & 0x01) != 0   // bit 0: 200LINE (1=200, 0=400)
            ramMode = (value & 0x02) != 0       // bit 1: MMODE (0=ROM/RAM, 1=64K RAM)
            romModeN88 = (value & 0x04) == 0    // bit 2: RMODE (0=N88-BASIC, 1=N-BASIC)
            graphicsDisplayEnabled = (value & 0x08) != 0  // bit 3: GRPH_CTRL_VDISP
            graphicsColorMode = (value & 0x10) != 0       // bit 4: GRPH_CTRL_COLOR
            crtc?.mode200Line = mode200Line
            busLog.debug("Port 0x31 write=0x\(hex(value)) 200L=\(mode200Line) ramMode=\(ramMode) romN88=\(romModeN88) gDisp=\(graphicsDisplayEnabled) gColor=\(graphicsColorMode)")

        // Port 0x32: Misc control (QUASI88: MISC_CTRL)
        case 0x32:
            port32 = value
            n88ExtROMSelect = value & 0x03      // bit 0-1: MISC_CTRL_EBANK
            // bit 4: MISC_CTRL_TEXT_MAIN (TMODE: 0=tvram, 1=mainRAM)
            tvramEnabled = (value & 0x10) == 0
            analogPalette = (value & 0x20) != 0 // bit 5: MISC_CTRL_ANALOG
            // bit 6: MISC_CTRL_EVRAM (extended VRAM access mode)
            evramMode = (value & 0x40) != 0
            // QUASI88: main_memory_vram_mapping() resets memory_bank to MAIN
            // when entering evramMode. "ワードラゴンで使用 by peach"
            if evramMode {
                gvramPlane = -1
            }
            // bit 7: SINTM (sound interrupt mask)
            let wasMasked = interruptController?.maskSound ?? true
            interruptController?.maskSound = (value & 0x80) != 0
            // Re-request sound IRQ on unmask transition (handles timer overflow while masked)
            if wasMasked && (value & 0x80) == 0 {
                onSoundUnmask?()
            }
            busLog.debug("Port 0x32: val=0x\(hex(value)) evram=\(evramMode) analog=\(analogPalette) SINTM=\((value & 0x80) != 0)")

        // Port 0x34: ALU control 1
        case 0x34:
            aluControl1 = value

        // Port 0x35: ALU control 2
        case 0x35:
            aluControl2 = value
            gamMode = (value & 0x80) != 0  // bit 7: GAM (ALU2_CTRL_VACCESS)
            if gamMode { busLog.debug("GAM enabled (port 0x35 = 0x\(hex(value)))") }

        // Port 0x10: Printer data + calendar command/data
        case 0x10:
            calendar?.writeCommand(value)

        // Port 0x40: Beep, joystick, calendar, CRT sync
        case 0x40:
            port40w = value
            calendar?.writeControl(value)
            sound?.beepOn = (value & 0x20) != 0
            sound?.singSignal = (value & 0x80) != 0

        // YM2608 ports
        case 0x44: sound?.writeAddr(value)
        case 0x45: sound?.writeData(value)
        case 0x46: sound?.writeExtAddr(value)
        case 0x47: sound?.writeExtData(value)

        // CRTC ports
        case 0x50: crtc?.writeParameter(value)
        case 0x51:
            busLog.debug("CRTC writeCommand 0x\(hex(value))")
            crtc?.writeCommand(value)

        // Background/border color
        case 0x52:
            borderColor = value

        // Layer display control
        case 0x53:
            layerControl = value

        // Palette registers (8 entries, port 0x54-0x5B)
        case 0x54...0x5B:
            let index = Int(port8 - 0x54)
            if analogPalette {
                // Analog 512-color mode: bit 6 selects which components to write.
                // QUASI88 (pc88main.c:1238-1248)
                // bit 6=0: bits 0-2 = Blue (3-bit), bits 3-5 = Red (3-bit)
                // bit 6=1: bits 0-2 = Green (3-bit)
                if (value & 0x40) == 0 {
                    palette[index].b = value & 0x07
                    palette[index].r = (value >> 3) & 0x07
                } else {
                    palette[index].g = value & 0x07
                }
            } else {
                // Digital 8-color mode: 1 bit per color (3 bits total)
                // QUASI88 (pc88main.c:1219-1236): bit 0=B, bit 1=R, bit 2=G
                let b: UInt8 = (value & 0x01) != 0 ? 7 : 0
                let r: UInt8 = (value & 0x02) != 0 ? 7 : 0
                let g: UInt8 = (value & 0x04) != 0 ? 7 : 0
                palette[index] = (b: b, r: r, g: g)
            }

        // GVRAM bank select
        case 0x5C: gvramPlane = 0   // Blue
        case 0x5D: gvramPlane = 1   // Red
        case 0x5E: gvramPlane = 2   // Green
        case 0x5F: gvramPlane = -1  // Main RAM

        // DMA controller
        case 0x60...0x68:
            dma?.ioWrite(port8, value: value)

        // Text window offset
        case 0x70:
            textWindowOffset = value

        // Extended ROM bank select
        case 0x71:
            extROMBank = value
            extROMEnabled = (value & 0x01) == 0  // bit 0: EXT_ROM_NOT (active low)
            busLog.debug(
                "Port 0x71: val=0x\(hex(value)) extROMEnabled=\(extROMEnabled) externalSelected=\(externalExtROMSelected)"
            )

        // Text window offset increment
        case 0x78:
            textWindowOffset &+= 1

        // Interrupt control (port 0xE4)
        case 0xE4:
            interruptController?.writeControlPort(value)

        // Interrupt mask (port 0xE6)
        case 0xE6:
            interruptController?.writeMaskPort(value)

        // Extended RAM mode (port 0xE2)
        case 0xE2:
            extRAMReadEnable = (value & 0x01) != 0
            extRAMWriteEnable = (value & 0x10) != 0
            busLog.debug("Port 0xE2: val=0x\(hex(value)) readEnable=\(extRAMReadEnable) writeEnable=\(extRAMWriteEnable)")

        // Extended RAM card/bank select (port 0xE3)
        // BubiC: lower 4 bits only. bits 1-0=bank, bits 3-2=card
        case 0xE3:
            extRAMCard = Int((value >> 2) & 0x03)
            extRAMBank = Int(value & 0x03)
            busLog.debug("Port 0xE3: val=0x\(hex(value)) card=\(extRAMCard) bank=\(extRAMBank)")

        // Kanji ROM Level 1 address (port 0xE8=low, 0xE9=high)
        case 0xE8:
            // Address low byte
            kanjiAddr1 = (kanjiAddr1 & 0xFF00) | UInt16(value)
        case 0xE9:
            // Address high byte
            kanjiAddr1 = (kanjiAddr1 & 0x00FF) | (UInt16(value) << 8)

        // Kanji ROM Level 1 read trigger (port 0xEA/0xEB) — write is address set
        case 0xEA, 0xEB:
            break  // Read-only data ports; writes ignored

        // Kanji ROM Level 2 address (port 0xEC=low, 0xED=high)
        case 0xEC:
            // Address low byte
            kanjiAddr2 = (kanjiAddr2 & 0xFF00) | UInt16(value)
        case 0xED:
            // Address high byte
            kanjiAddr2 = (kanjiAddr2 & 0x00FF) | (UInt16(value) << 8)

        // Dictionary ROM (stub)
        case 0xF0, 0xF1:
            break  // TODO: Dictionary ROM

        // PIO (sub-CPU communication)
        case 0xFC...0xFF:
            subSystem?.pioWrite(port: port8, value: value)

        default:
            if unimplementedWritePorts.insert(port8).inserted {
                busLog.warning("Unimplemented I/O WRITE port 0x\(hex(port8)) val=0x\(hex(value))")
            }
            break  // Unmapped port writes are ignored
        }
    }

    /// The FA still exposes a few legacy partially-decoded I/O ranges.
    /// Keep the alias set narrow so we do not collide with implemented FA-era ports.
    private func normalizeIOPort(_ port: UInt8) -> UInt8 {
        switch port {
        case 0x11...0x1F:
            return 0x10
        case 0x22, 0x24, 0x26, 0x28, 0x2A, 0x2C, 0x2E:
            return 0x20
        case 0x23, 0x25, 0x27, 0x29, 0x2B, 0x2D, 0x2F:
            return 0x21
        default:
            return port
        }
    }

    // MARK: - CMT High-Speed Load (QUASI88-compatible)

    /// Mirrors QUASI88 `sio_tape_highspeed_load()` (pc88main.c:2502-2585).
    /// Hudson titles (ALPHOS, etc.) write `OUT 0,0` from their BASIC stub
    /// to copy the machine-code body from tape directly into RAM, then
    /// jump there with `G xxxx`. Format: find `0x3A`, read addr_H, addr_L,
    /// checksum (sum == 0 mod 256); then loop `0x3A`, size, size bytes,
    /// checksum until size == 0. Any failure aborts silently — real
    /// hardware doesn't do this at all, so giving up matches QUASI88's
    /// behavior of leaving memory untouched.
    private func performHighSpeedTapeLoad() {
        guard let deck = cassette, deck.isLoaded else { return }

        // X88000M's tape image uses block-based access with inter-block
        // wait that naturally prevents the USART from over-delivering
        // past the BASIC section. Our flat buffer has no such boundary,
        // so BASIC's interrupt handler may have consumed a few bytes past
        // the program body — eating into the first Hudson 0x3A header.
        // Back up slightly so the scan can find it. 16 bytes covers the
        // worst observed overrun (~4 bytes).
        deck.seek(to: max(0, deck.bufPtr - 16))
        let startPtr = deck.bufPtr

        // Search for a valid Hudson header: 0x3A + addrH + addrL + chk
        // where (addrH + addrL + chk) & 0xFF == 0. When a checksum fails,
        // seek back to right after the 0x3A so we don't accidentally skip
        // a valid header whose 0x3A byte fell within the 3 consumed bytes.
        var addr = 0
        headerSearch: while true {
            var c: UInt8 = 0
            repeat {
                guard let b = deck.readByte() else { return }
                c = b
            } while c != 0x3A

            let afterMarker = deck.bufPtr  // position right after the 0x3A
            guard let aH = deck.readByte(),
                  let aL = deck.readByte(),
                  let aChk = deck.readByte() else { return }
            let headerSum = Int(aH) + Int(aL) + Int(aChk)
            if (headerSum & 0xFF) == 0 {
                addr = (Int(aH) << 8) | Int(aL)
                busLog.info("CMT fast-load: addr=0x\(hex16(UInt16(addr))) startPtr=\(startPtr) markerAt=\(afterMarker - 1)")
                break headerSearch
            }
            // Checksum failed — one of the 3 consumed bytes might itself
            // be a valid 0x3A marker. Seek back so the next scan picks it.
            deck.seek(to: afterMarker)
        }

        var blockCount = 0
        var totalBytes = 0
        while true {
            var c: UInt8 = 0
            repeat {
                guard let b = deck.readByte() else { return }
                c = b
            } while c != 0x3A

            guard let sizeByte = deck.readByte() else { return }
            if sizeByte == 0 {
                busLog.info("CMT fast-load: done (blocks=\(blockCount) bytes=\(totalBytes) endPtr=\(deck.bufPtr))")
                return
            }
            var blockSum = Int(sizeByte)

            for _ in 0..<Int(sizeByte) {
                guard let d = deck.readByte() else { return }
                blockSum += Int(d)
                // Write directly to mainRAM, bypassing the bus decode path
                // that would accumulate wait states and route through
                // GVRAM/ALU/extRAM. Matches QUASI88's main_mem_write().
                mainRAM[addr & 0xFFFF] = d
                addr = (addr + 1) & 0xFFFF
            }

            guard let bChk = deck.readByte() else { return }
            blockSum += Int(bChk)
            if (blockSum & 0xFF) != 0 { return }
            blockCount += 1
            totalBytes += Int(sizeByte)
        }
    }

    private func hex16(_ v: UInt16) -> String { String(format: "%04X", v) }

    // MARK: - ROM Read

    /// N-BASIC ROM 未ロード警告を一度だけ出すフラグ
    private var nBasicROMWarned: Bool = false

    private func readROM(_ addr: UInt16) -> UInt8 {
        if romModeN88 {
            // RMODE=0: N88-BASIC ROM (default)
            if let rom = n88BasicROM, Int(addr) < rom.count { return rom[Int(addr)] }
        } else {
            // RMODE=1: N-BASIC ROM
            if let rom = nBasicROM, Int(addr) < rom.count { return rom[Int(addr)] }
            // N80.ROM 未ロード時は 0xFF を返す (実機同等)
            if !nBasicROMWarned {
                busLog.warning("N-BASIC ROM (N80.ROM) not loaded — reads return 0xFF. Boot may fail.")
                nBasicROMWarned = true
            }
        }
        return 0xFF
    }

    // MARK: - DIP Switches

    /// DIP switch 1 value (port 0x30 read)
    /// QUASI88 (pc88main.c:1655): dipsw_1 | 0xc0 — bits 7-6 always 1
    /// Physical DIP convention: ON = bit cleared (0), OFF = bit set (1)
    /// bit 0 (SW_N88): 1=N88-BASIC, 0=N-BASIC (mode switch, not physical DIP)
    /// bit 1 (SW1-1): 0=Terminal mode, 1=BASIC mode
    /// bit 2 (SW1-2): 0=80 columns, 1=40 columns
    /// bit 3 (SW1-3): 0=25 lines, 1=20 lines
    /// bit 4 (SW1-4): 0=S parameter on, 1=S parameter off
    /// bit 5 (SW1-5): 0=DEL code process, 1=DEL code ignore
    /// BubiC: (mode==N ? 0 : 1) | 0xC2; QUASI88 V2: 0xDB
    public var dipSw1: UInt8 = 0xC3

    /// DIP switch 2 base value.
    /// bit 7 (SW_V1): 0=V2 mode, 1=V1 mode
    /// bit 6 (SW_H):  0=Standard speed, 1=High speed
    /// bit 5-4: serial baud rate / parity
    /// bit 3 (SW_ROMBOOT): 0=disk boot, 1=ROM boot — latched at reset
    ///        for the internal boot-mode decision only; real hardware does
    ///        not expose this bit on any readable I/O port.
    /// bit 2-0: serial settings
    /// Port 0x31 read forces bit 3 high (BubiC/QUASI88-compatible).
    /// Default base 0x71 = V2 mode, high speed, disk boot selected.
    public var dipSw2: UInt8 = 0x71

    private func dipSwitch1() -> UInt8 {
        return dipSw1 | 0xC0
    }

    private func dipSwitch2() -> UInt8 {
        // Port 0x31 does not expose the disk/ROM boot strap bit directly.
        // Real hardware and BubiC return the mode/config bits with bit 3 high;
        // the disk boot strap is instead visible via port 0x40 bit 3.
        dipSw2 | 0x08
    }

    // MARK: - Text VRAM Access

    /// Current text display mode.
    /// Color mode + port 0x53 bit 0 = fully hidden.
    /// Mono/attribute graphics + port 0x53 bit 0 = glyphs hidden, attributes remain active.
    public var textDisplayMode: TextDisplayMode {
        // QUASI88: (dmac_mode & 0x4) && crtc_active && (crtc_intr_mask == 3)
        // dmaUnderrun not checked here — QUASI88/XM8 always render text
        // when DMA is active. Underrun flag is still set in performTextDMATransfer
        // for CRTC status register reads by the game.
        guard (dma?.channels[2].enabled ?? false),
              (crtc?.displayEnabled ?? false),
              (crtc?.intrMask ?? 0) == 3,
              (dma?.textVRAMCount ?? 0) > 0 else {
            return .disabled
        }
        guard (layerControl & 0x01) != 0 else {
            return .enabled
        }
        return graphicsColorMode ? .disabled : .attributesOnly
    }

    /// Whether text glyphs should be rendered as an overlay.
    public var textDisplayEnabled: Bool {
        textDisplayMode == .enabled
    }

    /// Read a byte for text DMA transfer.
    /// Text DMA always sources the dedicated tvram buffer for 0xF000-0xFFFF.
    /// Per QUASI88 `pc88main.c:365-370`: "text display processing always
    /// refers to main_ram" (what QUASI88 calls main_ram[0xF000] is our
    /// dedicated `tvram` buffer). CPU access is what gets redirected by
    /// TMODE+high_mode — the hidden buffer at 0xF000 lives in mainRAM.
    @inline(__always)
    private func readDMAByte(_ addr: Int) -> UInt8 {
        let maskedAddr = addr & 0xFFFF
        if maskedAddr >= 0xF000 {
            return tvram[maskedAddr - 0xF000]
        }
        return mainRAM[maskedAddr]
    }

    /// Transfer text VRAM data into CRTC's internal DMA buffer (called at VRTC).
    /// BubiC: dmac.run(2, rowBytes) → RAM→buffer per char row during active display.
    /// We do the entire transfer at VRTC for simplicity.
    public func performTextDMATransfer() {
        guard let crtc = crtc else { return }

        crtc.startDMATransfer()

        guard let dma = dma,
              dma.channels[2].enabled else { return }
        let count = Int(dma.textVRAMCount)
        guard count > 0 else {
            // DMA count = 0: no transfer
            return
        }

        let expectedBytes = Int(crtc.linesPerScreen) * crtc.bytesPerDMARow
        let transferBytes = min(expectedBytes, count + 1)
        let startAddr = Int(dma.textVRAMAddress)

        for offset in 0..<transferBytes {
            crtc.writeDMABuffer(readDMAByte(startAddr + offset))
        }
        crtc.dmaUnderrun = transferBytes < expectedBytes
    }

    /// Read text character data from CRTC DMA buffer.
    ///
    /// uPD3301 DMA format: each row is (charsPerLine + attrsPerLine) bytes.
    /// Character codes are the first `charsPerLine` bytes of each row.
    /// Returns flattened character data (cols × rows).
    public func readTextVRAM() -> [UInt8] {
        guard let crtc = crtc else { return Array(repeating: 0x00, count: 2000) }
        let cols = Int(crtc.charsPerLine)
        let rows = Int(crtc.linesPerScreen)
        let rowStride = crtc.bytesPerDMARow
        let totalChars = cols * rows

        var data = [UInt8](repeating: 0x00, count: totalChars)
        for row in 0..<rows {
            let rowBase = row * rowStride  // buffer-internal offset
            for col in 0..<cols {
                // uPD3301 stores characters as a contiguous block in both
                // transparent and non-transparent modes (in non-transparent
                // there is no separate attribute area — the row is char-only,
                // monochrome, see vraminfo.html and BubiC's `80 + attrib.num*2`
                // where attrib.num=0 in non-transparent).
                data[row * cols + col] = crtc.readDMABuffer(at: rowBase + col)
            }
        }
        return data
    }

    /// Read text attribute data from CRTC DMA buffer and expand to per-character attributes.
    ///
    /// uPD3301 transparent mode: attribute data follows characters in each row,
    /// stored as (position, value) pairs. The attribute applies from that
    /// column position until the next attribute change.
    ///
    /// Per uPD3301 behavior (confirmed via BubiC): attributes persist across rows.
    /// Position byte bit 7 is LC flag and masked off (& 0x7F).
    /// All attrsPerLine pairs are processed (no early termination).
    ///
    /// Returns expanded per-character attribute array (cols × rows).
    public func readTextAttributes() -> [UInt8] {
        guard let crtc = crtc else { return Array(repeating: 0xE0, count: 2000) }
        crtc.updateBlink()
        let cols = Int(crtc.charsPerLine)
        let rows = Int(crtc.linesPerScreen)
        let rowStride = crtc.bytesPerDMARow
        let attrsPerLine = Int(crtc.attrsPerLine)
        let totalChars = cols * rows
        // XM8: attrib.data initial = 0xE0 (no reverseDisplay).
        // reverseDisplay XOR is applied only in set_attrib effect branch.
        let defaultAttr: UInt8 = 0xE0

        var data = [UInt8](repeating: defaultAttr, count: totalChars)

        let nonTransparent = crtc.attrNonTransparent

        // Attribute persists across rows (uPD3301 behavior, confirmed via BubiC)
        var currentAttr: UInt8 = defaultAttr

        for row in 0..<rows {
            let rowBase = row * rowStride  // buffer-internal offset

            if nonTransparent {
                // Non-transparent mode (uPD3301 AttrMode 4/5): row holds chars
                // only, no attribute area. Display is monochrome with the
                // default attribute applied uniformly.
                let monoAttr = defaultAttr
                for col in 0..<cols {
                    data[row * cols + col] = monoAttr
                }
            } else {
                currentAttr &= 0xF3
                if (crtc.displayMode & 0x01) != 0 || attrsPerLine == 0 {
                    currentAttr = defaultAttr
                    for col in 0..<cols {
                        data[row * cols + col] = currentAttr
                    }
                    continue
                }

                let attrBase = rowBase + cols
                var flags = Array(repeating: false, count: 128)

                // BubiC expands transparent attributes by first marking the
                // effective columns in reverse order, masking the position
                // byte with 0x7F, then consuming attribute values in their
                // original stream order as each marked column is reached.
                for i in stride(from: attrsPerLine - 1, through: 0, by: -1) {
                    let column = Int(crtc.readDMABuffer(at: attrBase + i * 2) & 0x7F)
                    flags[column] = true
                }

                var pairIndex = 0
                for col in 0..<cols {
                    if flags[col] {
                        let raw = crtc.readDMABuffer(at: attrBase + pairIndex * 2 + 1)
                        _ = remapAttribute(raw, currentAttr: &currentAttr)
                        pairIndex += 1
                    }
                    data[row * cols + col] = currentAttr
                }
            }
        }

        // QUASI88: crtc_reverse_display && GRPH_CTRL_COLOR → XOR ATTR_REVERSE on all cells.
        // Applied after attribute expansion as a separate pass.
        if crtc.reverseDisplay && graphicsColorMode {
            for i in 0..<data.count {
                data[i] ^= 0x01  // toggle ATTR_REVERSE
            }
        }

        return data
    }

#if DEBUG
    public func textDMADebugSnapshot() -> TextDMADebugSnapshot {
        let dmaState = TextDMADebugSnapshot.DMAState(
            enabled: dma?.channels[2].enabled ?? false,
            mode: dma?.channels[2].mode ?? 0,
            address: dma?.textVRAMAddress ?? 0,
            count: dma?.textVRAMCount ?? 0
        )
        let expectedDMABytes = (crtc?.bytesPerDMARow ?? 0) * Int(crtc?.linesPerScreen ?? 0)
        let crtcState = TextDMADebugSnapshot.CRTCState(
            displayEnabled: crtc?.displayEnabled ?? false,
            intrMask: crtc?.intrMask ?? 0,
            dmaUnderrun: crtc?.dmaUnderrun ?? true,
            dmaBufferPtr: crtc?.dmaBufferPtr ?? 0,
            charsPerLine: Int(crtc?.charsPerLine ?? 0),
            linesPerScreen: Int(crtc?.linesPerScreen ?? 0),
            bytesPerDMARow: crtc?.bytesPerDMARow ?? 0,
            expectedDMABytes: expectedDMABytes,
            attrNonTransparent: crtc?.attrNonTransparent ?? false
        )
        let busState = TextDMADebugSnapshot.BusState(
            textDisplayMode: textDisplayMode.description,
            layerControl: layerControl,
            graphicsColorMode: graphicsColorMode,
            tvramEnabled: tvramEnabled
        )

        let rawHead = paddedBytes(from: crtc?.dmaBuffer.prefix(64), to: 64)
        let textChars = readTextVRAM()
        let textAttrs = readTextAttributes()
        let row0Chars = paddedBytes(from: textChars.prefix(80), to: 80)
        let row0Attrs = paddedBytes(from: textAttrs.prefix(80), to: 80)

        var rowsToDump: [Int] = [0, 1, 2, 3]
        for row in 0..<Int(crtc?.linesPerScreen ?? 0) {
            let rowStart = row * 80
            let rowEnd = min(rowStart + 80, textChars.count)
            guard rowStart < rowEnd else { break }
            let hasVisibleChars = textChars[rowStart..<rowEnd].contains { byte in
                byte != 0x00 && byte != 0x20
            }
            if hasVisibleChars {
                rowsToDump.append(row)
            }
        }
        rowsToDump = Array(Set(rowsToDump)).sorted().prefix(8).map { $0 }

        let rowStates: [TextDMADebugSnapshot.RowState] = rowsToDump.compactMap { row in
            guard row >= 0, row < Int(crtc?.linesPerScreen ?? 0) else { return nil }
            let rowBase = row * (crtc?.bytesPerDMARow ?? 0)
            let charStart = row * 80
            let charEnd = min(charStart + 80, textChars.count)
            let attrEnd = min(charStart + 80, textAttrs.count)
            let rawCharsEnd = min(rowBase + Int(crtc?.charsPerLine ?? 0), crtc?.dmaBufferPtr ?? 0)
            let rawAttrStart = rowBase + Int(crtc?.charsPerLine ?? 0)
            let rawAttrEnd = min(rowBase + (crtc?.bytesPerDMARow ?? 0), crtc?.dmaBufferPtr ?? 0)
            return TextDMADebugSnapshot.RowState(
                row: row,
                rawChars: paddedBytes(
                    from: crtc?.dmaBuffer[rowBase..<rawCharsEnd],
                    to: Int(crtc?.charsPerLine ?? 0)
                ),
                rawAttrBytes: rawAttrStart < rawAttrEnd
                    ? Array((crtc?.dmaBuffer[rawAttrStart..<rawAttrEnd]) ?? [])
                    : [],
                expandedChars: paddedBytes(
                    from: charStart < charEnd ? textChars[charStart..<charEnd] : nil,
                    to: Int(crtc?.charsPerLine ?? 0)
                ),
                expandedAttributes: paddedBytes(
                    from: charStart < attrEnd ? textAttrs[charStart..<attrEnd] : nil,
                    to: Int(crtc?.charsPerLine ?? 0)
                )
            )
        }

        return TextDMADebugSnapshot(
            dma: dmaState,
            crtc: crtcState,
            bus: busState,
            rawDMABufferHead: rawHead,
            textRow0Chars: row0Chars,
            textRow0Attributes: row0Attrs,
            rowStates: rowStates,
            recentIO: recentTextDMAIO
        )
    }

    @inline(__always)
    private func recordTextDMAIO(port: UInt8, value: UInt8, isWrite: Bool) {
        guard isTextDMADebugPort(port) else { return }
        if recentTextDMAIO.count == recentTextDMAIOMax {
            recentTextDMAIO.removeFirst()
        }
        recentTextDMAIO.append(.init(port: port, value: value, isWrite: isWrite))
    }

    @inline(__always)
    private func isTextDMADebugPort(_ port: UInt8) -> Bool {
        switch port {
        case 0x31, 0x32, 0x50, 0x51, 0x53, 0x64, 0x65, 0x68:
            return true
        default:
            return false
        }
    }

    private func paddedBytes(from slice: ArraySlice<UInt8>?, to count: Int) -> [UInt8] {
        var result = slice.map(Array.init) ?? []
        if result.count < count {
            result.append(contentsOf: repeatElement(0, count: count - result.count))
        }
        return result
    }
#endif

    /// Remap raw uPD3301 attribute byte to internal expanded format.
    ///
    /// Raw format (uPD3301/BubiC):
    ///   Interpretation is selected by CRTC mode bit 1, not by port 0x30 mono/color.
    ///   CRTC color mode:
    ///     COLOR_SWITCH(0x08) set   → G(7) R(6) B(5) GRAPH(4) + switch(3)
    ///     COLOR_SWITCH(0x08) clear → UNDER(5) UPPER(4) REVERSE(2) BLINK(1) SECRET(0)
    ///   CRTC mono mode:
    ///     GRAPH(7) UNDER(5) UPPER(4) REVERSE(2) BLINK(1) SECRET(0)
    ///
    /// Expanded internal format (QUASI88 ATTR_*):
    ///   G(7) R(6) B(5) GRAPH(4) LOWER(3) UPPER(2) SECRET(1) REVERSE(0)
    private func remapAttribute(_ raw: UInt8, currentAttr: inout UInt8) -> UInt8 {
        let crtcUsesColorAttributes = ((crtc?.displayMode ?? 0) & 0x02) != 0
        if crtcUsesColorAttributes {
            if (raw & 0x08) != 0 {
                // COLOR_SWITCH set: color attribute — update G/R/B/GRAPH, keep effects
                currentAttr = (currentAttr & 0x0F) | (raw & 0xF0)
            } else {
                // Mono-style effects: keep existing color, remap effect bits
                // MONO_UNDER(0x20)>>2 → ATTR_LOWER(0x08)
                // MONO_UPPER(0x10)>>2 → ATTR_UPPER(0x04)
                // MONO_REVERSE(0x04)>>2 → ATTR_REVERSE(0x01)
                // MONO_SECRET(0x01)<<1 → ATTR_SECRET(0x02)
                currentAttr = (currentAttr & 0xF0)
                    | ((raw & 0x34) >> 2)
                    | ((raw & 0x01) << 1)
                currentAttr ^= blinkMask(raw: raw)
            }
        } else {
            // B&W mode: force white foreground, remap all effect bits
            // MONO_GRAPH(0x80)>>3 → ATTR_GRAPH(0x10)
            currentAttr = 0xE0
                | ((raw & 0x80) >> 3)
                | ((raw & 0x34) >> 2)
                | ((raw & 0x01) << 1)
            currentAttr ^= blinkMask(raw: raw)
        }
        return currentAttr
    }

    /// BubiC pc88.cpp:4286 — when raw BLINK (bit 1) is set and SECRET (bit 0)
    /// is clear, XOR the internal SECRET bit with the CRTC blink phase so the
    /// glyph is hidden during the blink-off period. Under/upper lines are
    /// applied after the SECRET skip and thus remain visible (vraminfo #51).
    @inline(__always)
    private func blinkMask(raw: UInt8) -> UInt8 {
        guard (raw & 0x02) != 0, (raw & 0x01) == 0 else { return 0 }
        return crtc?.blinkAttribBit ?? 0
    }

    // MARK: - GVRAM Rendering with Layer Control

    private static let zeroPlane: [UInt8] = Array(repeating: 0, count: 0x4000)

    /// Returns GVRAM planes with display control applied.
    /// Port 0x31 bit 3 (GRPH_CTRL_VDISP): master graphics display enable.
    /// Port 0x53 bits 1-3: per-plane suppress (mono/attrib mode only per BubiC).
    /// In color mode (GRPH_CTRL_COLOR=1), Port 0x53 plane suppress is ignored (BubiC confirmed).
    public func renderGVRAMPlanes() -> (blue: [UInt8], red: [UInt8], green: [UInt8]) {
        // Master switch: Port 0x31 bit 3 (GRPH_CTRL_VDISP)
        guard graphicsDisplayEnabled else {
            return (Self.zeroPlane, Self.zeroPlane, Self.zeroPlane)
        }
        // In color mode, Port 0x53 plane suppress is ignored (BubiC draw_640x200_color_graph)
        if graphicsColorMode {
            return (gvram[0], gvram[1], gvram[2])
        }
        // Mono/attrib mode: apply per-plane suppress
        let blue  = (layerControl & 0x02) != 0 ? Self.zeroPlane : gvram[0]
        let red   = (layerControl & 0x04) != 0 ? Self.zeroPlane : gvram[1]
        let green = (layerControl & 0x08) != 0 ? Self.zeroPlane : gvram[2]
        return (blue, red, green)
    }

    // MARK: - ALU Operations

    private func applyALU(addr: Int, value: UInt8) {
        // Per-plane operations defined by port 0x34 (QUASI88: ALU1_ctrl)
        // Non-contiguous bits: Blue=0x11, Red=0x22, Green=0x44
        // Loop shifts mode right by 1 each iteration, extracts bits 0 and 4 (mask 0x11)
        var mode = aluControl1
        for plane in 0..<3 {
            switch mode & 0x11 {
            case 0x00:  // AND NOT (clear bits)
                gvram[plane][addr] &= ~value
            case 0x01:  // OR (set bits)
                gvram[plane][addr] |= value
            case 0x10:  // XOR
                gvram[plane][addr] ^= value
            default:    // 0x11: NOP
                break
            }
            mode >>= 1
        }
    }
}

