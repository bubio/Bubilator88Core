import Testing
@testable import EmulatorCore

@Suite("Script Writer Tests")
struct ScriptWriterTests {

  // MARK: - keyName(for:)

  @Test func keyNameCanonicalNames() {
    #expect(ScriptWriter.keyName(for: Keyboard.space) == "space")
    #expect(ScriptWriter.keyName(for: Keyboard.z) == "z")
    #expect(ScriptWriter.keyName(for: Keyboard.key0) == "0")
    #expect(ScriptWriter.keyName(for: Keyboard.kp4) == "kp4")
    #expect(ScriptWriter.keyName(for: Keyboard.f1) == "f1")
    #expect(ScriptWriter.keyName(for: Keyboard.up) == "up")
    #expect(ScriptWriter.keyName(for: Keyboard.shift) == "shift")
    // Colliding keys resolve to the canonical name
    #expect(ScriptWriter.keyName(for: Keyboard.esc) == "esc")
    #expect(ScriptWriter.keyName(for: Keyboard.kpReturn) == "return")
  }

  @Test func keyNameRowBitFallback() {
    // Keys absent from the table, e.g. row 14 bit 7, use row-bit notation
    let key = Keyboard.Key(14, 7)
    #expect(ScriptWriter.keyName(for: key) == "14-7")
    // And the parser reads that row-bit notation back
    #expect(ScriptParser.key(named: "14-7") == key)
  }

  // MARK: - Per-step serialization

  @Test func perStepLines() {
    #expect(ScriptWriter.write([.boot(.n88v2)]) == "boot n88-v2\n")
    #expect(ScriptWriter.write([.boot(.n88v1h)]) == "boot n88-v1h\n")
    #expect(ScriptWriter.write([.clock(mhz: 4)]) == "clock 4\n")
    #expect(ScriptWriter.write([.clock(mhz: 8)]) == "clock 8\n")
    #expect(ScriptWriter.write([.dipsw1(0xC3)]) == "dipsw1 0xC3\n")
    #expect(ScriptWriter.write([.dipsw2(0x71)]) == "dipsw2 0x71\n")
    #expect(ScriptWriter.write([.dipsw2(0x08)]) == "dipsw2 0x08\n")  // zero-padded to two digits
    #expect(ScriptWriter.write([.wait(frames: 90)]) == "wait 90\n")
    #expect(ScriptWriter.write([.wait(frames: 0)]) == "wait 0\n")
    #expect(ScriptWriter.write([.key(Keyboard.space, .down)]) == "key space down\n")
    #expect(ScriptWriter.write([.key(Keyboard.space, .up)]) == "key space up\n")
    #expect(ScriptWriter.write([.key(Keyboard.z, .tap(hold: 2))]) == "key z tap\n")  // the default hold is omitted
    #expect(ScriptWriter.write([.key(Keyboard.z, .tap(hold: 12))]) == "key z tap 12\n")
    #expect(ScriptWriter.write([.diskMount(drive: 0, path: "/a b.d88", image: 0)]) == "disk 0 \"/a b.d88\"\n")
    #expect(ScriptWriter.write([.diskMount(drive: 1, path: "/x.d88", image: 3)]) == "disk 1 \"/x.d88\" image 3\n")
    #expect(ScriptWriter.write([.diskSwap(drive: 1, path: "/y.d88", image: 0)]) == "disk swap 1 \"/y.d88\"\n")
    #expect(ScriptWriter.write([.diskSwap(drive: 1, path: "/y.d88", image: 2)]) == "disk swap 1 \"/y.d88\" image 2\n")
    #expect(ScriptWriter.write([.diskSelect(drive: 1, image: 3)]) == "disk select 1 3\n")
    #expect(ScriptWriter.write([.diskEject(drive: 0)]) == "disk eject 0\n")
    #expect(ScriptWriter.write([.reset(preserveRAM: false)]) == "reset cold\n")
    #expect(ScriptWriter.write([.reset(preserveRAM: true)]) == "reset warm\n")
  }

  @Test func emptyStepsYieldEmptyString() {
    #expect(ScriptWriter.write([]) == "")
  }

  @Test func multipleStepsJoinedWithNewlines() {
    let text = ScriptWriter.write([
      .boot(.n88v2),
      .clock(mhz: 4),
      .wait(frames: 60),
      .key(Keyboard.space, .tap(hold: 2)),
    ])
    #expect(text == "boot n88-v2\nclock 4\nwait 60\nkey space tap\n")
  }

  // MARK: - Round-trip (the real point: parse(write(steps)) == steps)

  private func roundTrip(_ steps: [ScriptStep], sourceLocation: SourceLocation = #_sourceLocation) throws {
    let text = ScriptWriter.write(steps)
    let parsed = try ScriptParser.parse(text)
    #expect(parsed == steps, "round-trip mismatch for: \(text)", sourceLocation: sourceLocation)
  }

  @Test func roundTripSetupHeader() throws {
    try roundTrip([
      .boot(.n88v2),
      .clock(mhz: 4),
      .diskMount(drive: 0, path: "/Volumes/X6/sorpack.d88", image: 0),
      .diskMount(drive: 1, path: "/Volumes/X6/sorpack.d88", image: 1),
    ])
  }

  @Test func roundTripTimeline() throws {
    try roundTrip([
      .wait(frames: 300),
      .key(Keyboard.space, .tap(hold: 2)),
      .wait(frames: 60),
      .key(Keyboard.z, .down),
      .wait(frames: 30),
      .key(Keyboard.z, .up),
      .wait(frames: 12),
      .key(Keyboard.kp4, .tap(hold: 6)),
    ])
  }

  @Test func roundTripDiskOpsWithSpaces() throws {
    try roundTrip([
      .diskMount(drive: 0, path: "/path with spaces/game disk.d88", image: 2),
      .diskSwap(drive: 1, path: "/another path/disk 2.d88", image: 3),
      .diskSelect(drive: 1, image: 0),
      .diskEject(drive: 0),
    ])
  }

  @Test func roundTripDipswAndReset() throws {
    try roundTrip([
      .dipsw1(0xC2),
      .dipsw2(0xB1),
      .reset(preserveRAM: false),
      .reset(preserveRAM: true),
    ])
  }

  @Test func roundTripRowBitKey() throws {
    // Keys outside the table round-trip too
    try roundTrip([.key(Keyboard.Key(14, 7), .down)])
  }

  @Test func roundTripPathWithQuotesAndBackslashes() throws {
    // `"` and `\` in a path are escaped and round-trip
    try roundTrip([
      .diskMount(drive: 0, path: #"/weird/disk"v2.d88"#, image: 0),
      .diskSwap(drive: 1, path: #"/a\b/disk "x".d88"#, image: 1),
    ])
  }

  @Test func quotedPathEscapesQuote() {
    // Check the serialized form directly (`"` → `\"`, `\` → `\\`)
    #expect(ScriptWriter.write([.diskMount(drive: 0, path: #"/x"y.d88"#, image: 0)])
      == "disk 0 \"/x\\\"y.d88\"\n")
  }

  @Test func roundTripAllNamedKeys() throws {
    // Tap every key in keyNameTable and round-trip it; duplicates collapse in
    // the set
    let keys = Set(ScriptParser.keyNameTable.values)
    let steps = keys.map { ScriptStep.key($0, .tap(hold: 2)) }
    try roundTrip(steps)
  }
}
