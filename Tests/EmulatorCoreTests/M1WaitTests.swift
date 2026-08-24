import Testing
@testable import EmulatorCore

/// M1 (opcode fetch) wait states — `MEMORY_WAIT_STATES.md` §2.1.
///
/// The Z80 drives `/M1` low only while fetching an opcode byte, and the
/// PC-8801 feeds that pin into its wait generator. Two halves have to be
/// right for the emulation to be: the CPU has to call `opcodeRead` for
/// exactly the bytes the hardware calls M1, and the bus has to charge the
/// right number of T-states for them.
@Suite("M1 Wait States")
struct M1WaitTests {

  // MARK: - Which bytes are M1

  /// An unprefixed instruction has one M1 cycle: the opcode. Its immediate
  /// operand is an ordinary read.
  @Test func unprefixedInstructionHasOneM1Cycle() {
    let cpu = Z80()
    let bus = TestBus()
    bus.load(at: 0x0000, data: [0x3E, 0x42])  // LD A,0x42
    cpu.pc = 0x0000

    _ = cpu.step(bus: bus)

    #expect(bus.opcodeReadLog == [0x0000])
    #expect(cpu.a == 0x42)
  }

  /// `JP nn` likewise: one M1, and the two address bytes are plain reads.
  @Test func immediateOperandsAreNotM1() {
    let cpu = Z80()
    let bus = TestBus()
    bus.load(at: 0x0000, data: [0xC3, 0x34, 0x12])  // JP 0x1234
    cpu.pc = 0x0000

    _ = cpu.step(bus: bus)

    #expect(bus.opcodeReadLog == [0x0000])
    #expect(cpu.pc == 0x1234)
  }

  /// CB / ED / DD / FD prefixed instructions have two M1 cycles: the prefix
  /// and the byte after it.
  @Test func prefixedInstructionsHaveTwoM1Cycles() {
    for program in [
      [0xCB, 0x27] as [UInt8],  // SLA A
      [0xED, 0x44],             // NEG
      [0xDD, 0x23],             // INC IX
      [0xFD, 0x23],             // INC IY
    ] {
      let cpu = Z80()
      let bus = TestBus()
      bus.load(at: 0x0000, data: program)
      cpu.pc = 0x0000

      _ = cpu.step(bus: bus)

      #expect(bus.opcodeReadLog == [0x0000, 0x0001])
    }
  }

  /// DDCB / FDCB is the exception that makes a `fetchByte` hook wrong: the
  /// displacement *and* the final opcode byte are ordinary reads, so the
  /// instruction still has only the two M1 cycles of its two prefixes.
  /// BubiC reads that byte with `FETCH8`, not `FETCHOP`.
  @Test func indexedBitOperationsStillHaveOnlyTwoM1Cycles() {
    let cpu = Z80()
    let bus = TestBus()
    bus.load(at: 0x0000, data: [0xDD, 0xCB, 0x02, 0x26])  // SLA (IX+2)
    cpu.ix = 0x4000
    cpu.pc = 0x0000

    _ = cpu.step(bus: bus)

    #expect(bus.opcodeReadLog == [0x0000, 0x0001])
  }

  /// A DD/FD prefix on an instruction that has no indexed form acts as a 4T
  /// NOP and the byte after it executes as an ordinary opcode — two M1
  /// cycles, and R incremented twice. Rewinding PC to re-decode the byte
  /// would charge a third of each.
  @Test func unindexableOpcodeAfterAPrefixCostsTwoM1Cycles() {
    let cpu = Z80()
    let bus = TestBus()
    bus.load(at: 0x0000, data: [0xDD, 0x04])  // DD (NOP prefix) + INC B
    cpu.pc = 0x0000
    cpu.b = 0x10
    cpu.r = 0x00

    let cycles = cpu.step(bus: bus)

    #expect(bus.opcodeReadLog == [0x0000, 0x0001])
    #expect(cycles == 8)  // 4 (prefix) + 4 (INC B)
    #expect(cpu.b == 0x11)
    #expect(cpu.pc == 0x0002)
    #expect(cpu.r == 0x02)
  }

  /// A run of DD/FD bytes is legal; each is its own M1, and only the last
  /// one decides which index register the instruction uses.
  @Test func chainedPrefixesEachCostAnM1AndTheLastOneWins() {
    let cpu = Z80()
    let bus = TestBus()
    bus.load(at: 0x0000, data: [0xDD, 0xFD, 0x23])  // DD, then FD: INC IY
    cpu.pc = 0x0000
    cpu.ix = 0x1000
    cpu.iy = 0x2000
    cpu.r = 0x00

    let cycles = cpu.step(bus: bus)

    #expect(bus.opcodeReadLog == [0x0000, 0x0001, 0x0002])
    #expect(cycles == 14)  // 4 (the ignored DD) + 10 (INC IY, prefix included)
    #expect(cpu.ix == 0x1000)
    #expect(cpu.iy == 0x2001)
    #expect(cpu.r == 0x03)
  }

  /// A runaway PC over prefix-filled memory must still yield T-states on
  /// every step, or the frame budget never advances and the emulator hangs
  /// instead of merely spinning.
  @Test func aRunawayPrefixChainStillReturnsTStates() {
    let cpu = Z80()
    let bus = TestBus()
    for addr in 0..<0x100 {
      bus.memory[addr] = 0xDD
    }
    cpu.pc = 0x0000

    let cycles = cpu.step(bus: bus)

    #expect(cycles > 0)
    #expect(cpu.pc > 0x0000)
    #expect(cycles == Int(cpu.pc) * 4)  // one 4T NOP per prefix consumed
  }

  /// The IM2 vector table read is not an M1 cycle. BubiC's `check_interrupt`
  /// uses no `FETCHOP` either.
  @Test func interruptVectorFetchIsNotM1() {
    let cpu = Z80()
    let bus = TestBus()
    cpu.im = 2
    cpu.iff1 = true
    cpu.i = 0x80
    cpu.sp = 0xF000
    bus.load(at: 0x8010, data: [0x00, 0x30])

    _ = cpu.interrupt(vector: 0x10, bus: bus)

    #expect(bus.opcodeReadLog.isEmpty)
    #expect(cpu.pc == 0x3000)
  }

  // MARK: - What the bus charges

  /// V1S / N: `dipSw2` bit 6 clear. Every other axis at its default.
  private func v1sBus() -> Pc88Bus {
    let bus = Pc88Bus()
    bus.dipSw2 = 0x31  // bit 6 = 0 → standard (V1S/N)
    bus.cpuClock8MHz = false
    bus.memoryWaitDip = false
    bus.ramMode = true
    return bus
  }

  /// V1H / V2: `dipSw2` bit 6 set.
  private func v1hBus() -> Pc88Bus {
    let bus = Pc88Bus()
    bus.dipSw2 = 0x71  // bit 6 = 1 → high speed (V1H/V2)
    bus.cpuClock8MHz = false
    bus.memoryWaitDip = false
    bus.ramMode = true
    return bus
  }

  /// The case that matters: 4MHz, V1S/N, memory-wait DIP off. Every opcode
  /// fetch costs 1T wherever it comes from, which is the ~10% slowdown the
  /// mode is known for. An ordinary read of the same byte costs nothing.
  @Test func v1sAt4MHzChargesOneTStateForEveryOpcodeFetch() {
    let bus = v1sBus()
    #expect(bus.bootModeStandard)

    for addr in [UInt16(0x0000), 0x4000, 0x8000, 0xE000, 0xF000] {
      bus.pendingWaitStates = 0
      _ = bus.opcodeRead(addr)
      #expect(bus.pendingWaitStates == 1)

      bus.pendingWaitStates = 0
      _ = bus.memRead(addr)
      #expect(bus.pendingWaitStates == 0)
    }
  }

  /// At 8MHz there is no M1 wait at all — this is the guard that keeps every
  /// 8MHz regression scenario byte-identical.
  @Test func noM1WaitAt8MHz() {
    let bus = v1sBus()
    bus.cpuClock8MHz = true

    for addr in [UInt16(0x0000), 0x8000, 0xF000] {
      bus.pendingWaitStates = 0
      let plain = { () -> Int in
        bus.pendingWaitStates = 0
        _ = bus.memRead(addr)
        return bus.pendingWaitStates
      }()
      bus.pendingWaitStates = 0
      _ = bus.opcodeRead(addr)
      #expect(bus.pendingWaitStates == plain)
    }
  }

  /// The memory-wait DIP being *on* silences the M1 wait — BubiC's
  /// `get_m1_wait()` returns early on `mem_wait_on`. The main-memory read
  /// wait it does add is a separate charge.
  @Test func memoryWaitDipSuppressesTheM1Wait() {
    let bus = v1sBus()
    bus.memoryWaitDip = true

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0x8000)
    #expect(bus.pendingWaitStates == 1)  // the main read wait alone, no M1

    bus.pendingWaitStates = 0
    _ = bus.memRead(0x8000)
    #expect(bus.pendingWaitStates == 1)
  }

  /// V1H / V2 pays only for fetches out of the TVRAM window.
  @Test func v1hChargesNothingOutsideTheTvramWindow() {
    let bus = v1hBus()
    #expect(!bus.bootModeStandard)

    for addr in [UInt16(0x0000), 0x4000, 0x8000, 0xE000, 0xEFFF] {
      bus.pendingWaitStates = 0
      _ = bus.opcodeRead(addr)
      #expect(bus.pendingWaitStates == 0)
    }
  }

  /// …and does pay inside it, when the window is really showing TVRAM.
  @Test func v1hChargesOneTStateForATvramFetch() {
    let bus = v1hBus()
    bus.tvramEnabled = true  // Port32 TMODE = 0
    bus.gvramPlane = -1
    bus.evramMode = false

    for addr in [UInt16(0xF000), 0xF800, 0xFFFF] {
      bus.pendingWaitStates = 0
      _ = bus.opcodeRead(addr)
      #expect(bus.pendingWaitStates == 1)
    }
  }

  /// TMODE = 1 swaps the hidden main-RAM bank in at 0xF000, and the wait
  /// goes away with the TVRAM.
  @Test func v1hChargesNothingWhenTMODESwapsTvramOut() {
    let bus = v1hBus()
    bus.ioWrite(0x32, value: 0x10)  // bit 4 TMODE = 1
    #expect(!bus.tvramEnabled)

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == 0)
  }

  /// So does selecting a GVRAM plane into the window: `!gvram_sel` in
  /// BubiC's `get_m1_wait()`. The GVRAM wait still applies — it is a
  /// different charge — but the M1 one does not.
  @Test func v1hChargesNoM1WaitWhenGVRAMIsSelected() {
    let bus = v1hBus()
    bus.tvramEnabled = true
    bus.graphicsDisplayEnabled = true
    bus.vrtcFlag = false
    bus.gvramPlane = 0

    bus.pendingWaitStates = 0
    let plain = { () -> Int in
      _ = bus.memRead(0xF000)
      return bus.pendingWaitStates
    }()
    #expect(plain == 2)  // V1H/V2 GVRAM read

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == plain)
  }

  /// The ALU path counts as selected only when GAM is on, matching
  /// `update_gvram_sel()`: `Port32_GVAM ? (Port35_GAM ? 8 : 0) : gvram_plane`.
  @Test func v1hEVRAMWithoutGAMStillCountsAsTvram() {
    let bus = v1hBus()
    bus.tvramEnabled = true
    bus.evramMode = true
    bus.gamMode = false

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == 1)

    // GAM on: the ALU takes the window, so no M1 wait. The GVRAM read wait
    // that replaces it is a different charge, hence the comparison against
    // a plain read rather than against zero.
    bus.gamMode = true
    bus.pendingWaitStates = 0
    _ = bus.memRead(0xF000)
    let plain = bus.pendingWaitStates

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == plain)
  }

  /// The M1 wait is charged on top of the address's ordinary read wait, the
  /// way BubiC's `fetch_op` adds it after `read_data8w`. At 8MHz a TVRAM read
  /// costs 2 and the M1 nothing; at 4MHz V1S it is the other way round.
  @Test func theM1WaitIsAdditiveWithTheOrdinaryReadWait() {
    let bus = v1sBus()
    bus.cpuClock8MHz = true
    bus.tvramEnabled = true

    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == 2)  // 2 tvram read + 0 M1

    bus.cpuClock8MHz = false
    bus.pendingWaitStates = 0
    _ = bus.opcodeRead(0xF000)
    #expect(bus.pendingWaitStates == 1)  // 0 tvram read + 1 M1
  }

  // MARK: - End to end

  /// The whole point, measured the way it is felt: a V1S machine at 4MHz
  /// takes longer to run the same code than a V1H one. `NOP` is 4T plus 1T
  /// of M1 wait — a 25% penalty on the shortest instruction, ~10% averaged
  /// over real code.
  @Test func v1sAt4MHzRunsCodeSlowerThanV1H() {
    func tStatesForTenNOPs(_ bus: Pc88Bus) -> Int {
      let cpu = Z80()
      cpu.pc = 0x8000
      var total = 0
      for i in 0..<10 {
        bus.memWrite(UInt16(0x8000 + i), value: 0x00)  // NOP
      }
      for _ in 0..<10 {
        bus.pendingWaitStates = 0
        total += cpu.step(bus: bus) + bus.pendingWaitStates
      }
      return total
    }

    #expect(tStatesForTenNOPs(v1hBus()) == 40)
    #expect(tStatesForTenNOPs(v1sBus()) == 50)
  }
}
