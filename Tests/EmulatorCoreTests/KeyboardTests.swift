import Testing
@testable import EmulatorCore

@Suite("Keyboard Tests")
struct KeyboardTests {

    @Test func resetState() {
        let kb = Keyboard()
        kb.reset()

        for row in 0..<15 {
            #expect(kb.matrix[row] == 0xFF)
        }
    }

    @Test func readRowNoKeyPressed() {
        let kb = Keyboard()
        #expect(kb.readRow(0x00) == 0xFF)
        #expect(kb.readRow(0x09) == 0xFF)
        #expect(kb.readRow(0x0E) == 0xFF)
    }

    @Test func pressAndRelease() {
        let kb = Keyboard()

        // Press Space (row 9, bit 6)
        kb.pressKey(row: 9, bit: 6)
        #expect(kb.readRow(0x09) == 0xBF)  // bit 6 cleared

        // Release Space
        kb.releaseKey(row: 9, bit: 6)
        #expect(kb.readRow(0x09) == 0xFF)
    }

    @Test func multipleKeysInSameRow() {
        let kb = Keyboard()

        // Press F1 (row 9, bit 1) and F2 (row 9, bit 2)
        kb.pressKey(row: 9, bit: 1)
        kb.pressKey(row: 9, bit: 2)
        #expect(kb.readRow(0x09) == 0xF9)  // bits 1 and 2 cleared

        kb.releaseKey(row: 9, bit: 1)
        #expect(kb.readRow(0x09) == 0xFB)  // only bit 2 cleared
    }

    @Test func keysAcrossRows() {
        let kb = Keyboard()

        // Press 'A' (row 2, bit 1) and Space (row 9, bit 6)
        kb.pressKey(row: Keyboard.a.row, bit: Keyboard.a.bit)
        kb.pressKey(row: Keyboard.space.row, bit: Keyboard.space.bit)

        #expect(kb.readRow(0x02) == 0xFD)  // A pressed
        #expect(kb.readRow(0x09) == 0xBF)  // Space pressed
        #expect(kb.readRow(0x00) == 0xFF)  // Other rows unaffected
    }

    @Test func releaseAll() {
        let kb = Keyboard()

        kb.pressKey(row: 2, bit: 1)
        kb.pressKey(row: 9, bit: 6)
        kb.releaseAll()

        for row in 0..<15 {
            #expect(kb.matrix[row] == 0xFF)
        }
    }

    @Test func invalidRowAndBit() {
        let kb = Keyboard()

        // Should not crash for out-of-bounds
        kb.pressKey(row: 20, bit: 0)
        kb.pressKey(row: 0, bit: 10)
        kb.releaseKey(row: 20, bit: 0)

        // Invalid row read
        #expect(kb.readRow(0x0F) == 0xFF)
    }

    @Test func keyConstants() {
        #expect(Keyboard.space == Keyboard.Key(9, 6))
        #expect(Keyboard.a == Keyboard.Key(2, 1))
        #expect(Keyboard.esc == Keyboard.Key(9, 7))
        #expect(Keyboard.ctrl == Keyboard.Key(8, 7))
        #expect(Keyboard.shift == Keyboard.Key(8, 6))
    }

    @Test func wiredToBus() {
        let machine = Machine()
        machine.bus.directBasicBoot = false  // test raw keyboard, not boot mode
        machine.reset()

        // No key → 0xFF
        #expect(machine.bus.ioRead(0x09) == 0xFF)

        // Press Space
        machine.keyboard.pressKey(row: 9, bit: 6)
        #expect(machine.bus.ioRead(0x09) == 0xBF)

        // Release
        machine.keyboard.releaseKey(row: 9, bit: 6)
        #expect(machine.bus.ioRead(0x09) == 0xFF)
    }
}
