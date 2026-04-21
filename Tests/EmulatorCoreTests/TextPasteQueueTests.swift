import Testing
@testable import EmulatorCore

@Suite("TextPasteQueue Tests")
struct TextPasteQueueTests {

    @Test func tableSize() {
        // 16 + 16 + 32 + 32 + 64 + Return + Tab
        #expect(TextPasteQueue.table.count == 162)
    }

    @Test func asciiMapping() {
        // '1' = ASCII 0x31 → index 0x11 → row 6 bit 1, no modifiers
        let entry = TextPasteQueue.table[0x31 - 0x20]
        #expect((Int(entry) >> 4) & 0x0F == 6)
        #expect(Int(entry) & 0x07 == 1)
        #expect(entry & 0x0100 == 0)
        #expect(entry & 0x1000 == 0)

        // '!' = 0x21 → index 0x01 → same key with SHIFT
        let bang = TextPasteQueue.table[0x21 - 0x20]
        #expect((Int(bang) >> 4) & 0x0F == 6)
        #expect(Int(bang) & 0x07 == 1)
        #expect(bang & 0x0100 != 0)
    }

    @Test func kanaMapping() {
        // ｱ = 0xB1 → index 0x71 → row 6 bit 3 (key '3') + KANA
        let a = TextPasteQueue.table[0xB1 - 0x40]
        #expect((Int(a) >> 4) & 0x0F == 6)
        #expect(Int(a) & 0x07 == 3)
        #expect(a & 0x1000 != 0)
        #expect(a & 0x0100 == 0)
    }

    @Test func returnAndTab() {
        // Newline maps to table[0xA0]
        let ret = TextPasteQueue.table[0xA0]
        #expect((Int(ret) >> 4) & 0x0F == 1)
        #expect(Int(ret) & 0x07 == 7)  // kpReturn row 1 bit 7
        // Tab maps to table[0xA1]
        let tab = TextPasteQueue.table[0xA1]
        #expect((Int(tab) >> 4) & 0x0F == 0x0A)
        #expect(Int(tab) & 0x07 == 0)  // tab row 0x0A bit 0
    }

    @Test func enqueueAndPressSequence() {
        let q = TextPasteQueue()
        q.enqueue("A")
        #expect(!q.isEmpty)

        var events: [TextPasteQueue.KeyAction] = []
        // Run 13 ticks to consume one char (ticksPerChar = 12)
        for _ in 0..<13 {
            q.tick { events.append($0) }
        }
        #expect(q.isEmpty)

        // 'A' = SHIFT + 'a' (row 2 bit 1). Expect SHIFT-down, key-down,
        // then key-up, SHIFT-up.
        #expect(events.count == 4)
        #expect(events[0].row == 8 && events[0].bit == 6 && events[0].down)  // shift down
        #expect(events[1].row == 2 && events[1].bit == 1 && events[1].down)  // a down
        #expect(events[2].row == 2 && events[2].bit == 1 && !events[2].down) // a up
        #expect(events[3].row == 8 && events[3].bit == 6 && !events[3].down) // shift up
    }

    @Test func cancelClearsQueue() {
        let q = TextPasteQueue()
        q.enqueue("HELLO")
        #expect(!q.isEmpty)
        q.cancel { _ in }
        #expect(q.isEmpty)
    }

    /// Regression: ESC cancel mid-press must release the main key + modifier
    /// so the emulator's keyboard matrix doesn't end up with a stuck key.
    @Test func cancelMidPressReleasesHeldKeys() {
        let q = TextPasteQueue()
        q.enqueue("A")  // shift + 'a' (row 2 bit 1)

        // Advance into the "pressed" window (past keyDownTick = 3).
        var events: [TextPasteQueue.KeyAction] = []
        for _ in 0..<5 { q.tick { events.append($0) } }

        // Shift-down and 'a'-down should have been emitted.
        #expect(events.contains { $0.row == 8 && $0.bit == 6 && $0.down })
        #expect(events.contains { $0.row == 2 && $0.bit == 1 && $0.down })

        // Cancel and capture emitted release events.
        var releases: [TextPasteQueue.KeyAction] = []
        q.cancel { releases.append($0) }

        // Both the main key and Shift must be released.
        #expect(releases.contains { $0.row == 2 && $0.bit == 1 && !$0.down })
        #expect(releases.contains { $0.row == 8 && $0.bit == 6 && !$0.down })
        #expect(q.isEmpty)
    }

    /// Regression: enqueue after a cancel in mid-press must reset internal
    /// state so the next paste starts cleanly at tick 0 (first char not dropped).
    @Test func enqueueAfterCancelResetsState() {
        let q = TextPasteQueue()
        q.enqueue("XYZ")
        for _ in 0..<5 { q.tick { _ in } }
        q.cancel { _ in }

        // Fresh paste.
        q.enqueue("a")
        var events: [TextPasteQueue.KeyAction] = []
        for _ in 0..<13 { q.tick { events.append($0) } }

        // 'a' = lowercase, row 2 bit 1. Exactly one press and one release.
        #expect(events.count == 2)
        #expect(events[0].row == 2 && events[0].bit == 1 && events[0].down)
        #expect(events[1].row == 2 && events[1].bit == 1 && !events[1].down)
    }

    /// Regression: Shift is pressed *before* the main key (separate ticks) so
    /// the BIOS can latch the modifier before sampling the letter row, and
    /// released *after* the main key.
    @Test func shiftStraddlesMainKeyInTime() {
        let q = TextPasteQueue()
        q.enqueue("A")
        var tickOf: [(key: String, down: Bool, tick: Int)] = []
        for t in 0..<13 {
            q.tick { ev in
                let k = (ev.row == 8 && ev.bit == 6) ? "shift" : "main"
                tickOf.append((k, ev.down, t))
            }
        }
        // Expect: shift-down < main-down < main-up < shift-up by tick.
        let shiftDown = tickOf.first { $0.key == "shift" && $0.down }!.tick
        let mainDown = tickOf.first { $0.key == "main" && $0.down }!.tick
        let mainUp = tickOf.first { $0.key == "main" && !$0.down }!.tick
        let shiftUp = tickOf.first { $0.key == "shift" && !$0.down }!.tick
        #expect(shiftDown < mainDown)
        #expect(mainDown < mainUp)
        #expect(mainUp < shiftUp)
    }

    @Test func newlineProducesReturnKey() {
        let q = TextPasteQueue()
        q.enqueue("\n")
        var events: [TextPasteQueue.KeyAction] = []
        for _ in 0..<13 {
            q.tick { events.append($0) }
        }
        #expect(events.count == 2)
        #expect(events[0].row == 1 && events[0].bit == 7 && events[0].down)
        #expect(events[1].row == 1 && events[1].bit == 7 && !events[1].down)
    }

    @Test func kanjiSkipped() {
        // "漢字" is 2-byte SJIS for each char; we skip them entirely.
        let q = TextPasteQueue()
        q.enqueue("漢字")
        #expect(q.isEmpty)
    }
}

@Suite("Machine copyTextAsUnicode Tests")
struct MachineCopyTextTests {

    @Test func emptyScreen() {
        let machine = Machine()
        let text = machine.copyTextAsUnicode()
        // 25 rows of newline (empty lines trimmed).
        #expect(text.filter { $0 == "\n" }.count == 25)
    }
}
