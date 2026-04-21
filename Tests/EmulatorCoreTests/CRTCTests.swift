import Testing
@testable import EmulatorCore

@Suite("CRTC Tests")
struct CRTCTests {

    @Test func resetState() {
        let crtc = CRTC()
        crtc.reset()

        #expect(crtc.scanline == 0)
        #expect(crtc.vrtcFlag == false)
        #expect(crtc.displayEnabled == false)
        #expect(crtc.mode200Line == true)
    }

    @Test func vrtcFlagDuringBlanking() {
        let crtc = CRTC()
        crtc.reset()

        // Advance to just before blanking (scanline 199)
        let tStatesPerLine = 509  // 8MHz
        for _ in 0..<199 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(crtc.vrtcFlag == false)
        #expect(crtc.scanline == 199)

        // Advance to blanking start (scanline 200)
        crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        #expect(crtc.vrtcFlag == true)
        #expect(crtc.scanline == 200)
    }

    @Test func vsyncCallbackFired() {
        let crtc = CRTC()
        crtc.reset()

        var vsyncCount = 0
        crtc.onVSYNC = { vsyncCount += 1 }

        let tStatesPerLine = 509
        // Run through one full frame (262 scanlines)
        for _ in 0..<262 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(vsyncCount == 1)
    }

    @Test func scanlineWrapsAround() {
        let crtc = CRTC()
        crtc.reset()

        let tStatesPerLine = 509
        // Advance past one full frame
        for _ in 0..<263 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(crtc.scanline == 1)  // Wrapped around
        #expect(crtc.vrtcFlag == false)  // Back to active display
    }

    @Test func statusRegister() {
        let crtc = CRTC()
        crtc.reset()

        // Not in VRTC
        #expect(crtc.readStatus() & 0x20 == 0)

        // Simulate VRTC
        crtc.vrtcFlag = true
        #expect(crtc.readStatus() & 0x20 != 0)

        // Display enabled
        crtc.displayEnabled = true
        #expect(crtc.readStatus() & 0x10 != 0)
    }

    @Test func startDisplayCommand() {
        let crtc = CRTC()
        crtc.reset()

        // Start display command (0x20)
        crtc.writeCommand(0x20)
        #expect(crtc.displayEnabled == true)

        // Reset command (0x00) disables display
        crtc.writeCommand(0x00)
        #expect(crtc.displayEnabled == false)
    }

    @Test func resetCommandParses5Parameters() {
        let crtc = CRTC()
        crtc.reset()

        // Reset command → 5 params (QUASI88 init: 0xCE, 0x98, 0x6F, 0x58, 0x53)
        crtc.writeCommand(0x00)
        crtc.writeParameter(0xCE)  // 78 columns → (0x4E & 0x7F) + 2 = 80
        crtc.writeParameter(0x98)  // 24 lines → (0x18 & 0x3F) + 1 = 25, blink = (2+1)*32 = 96
        crtc.writeParameter(0x6F)  // char height = (0x0F & 0x1F)+1 = 16, cursor mode=3, skip=0
        crtc.writeParameter(0x58)  // vretrace = (2+1) = 3
        crtc.writeParameter(0x53)  // mode bits: non-transparent=0, color=1, no-attr=0; attrs=(0x13&0x1F)+1=20

        #expect(crtc.charsPerLine == 80)
        #expect(crtc.linesPerScreen == 25)
        #expect(crtc.charLinesPerRow == 16)
        #expect(crtc.skipLine == false)
        #expect(crtc.attrsPerLine == 20)
        #expect(crtc.attrNonTransparent == false)
    }

    @Test func setInterruptMaskCommand() {
        let crtc = CRTC()
        crtc.reset()

        // Start display first
        crtc.writeCommand(0x20)
        #expect(crtc.displayEnabled == true)

        // Set interrupt mask (0x43 = cmd 0x40, mask bits = 3)
        crtc.writeCommand(0x43)
        #expect(crtc.intrMask == 3)
        // displayEnabled stays true when bit 0 is set
        #expect(crtc.displayEnabled == true)

        // Set interrupt mask with bit 0 = 0 → disables display (BubiC behavior)
        crtc.writeCommand(0x40)
        #expect(crtc.intrMask == 0)
        #expect(crtc.displayEnabled == false)
    }

    @Test func loadCursorPositionCommand() {
        let crtc = CRTC()
        crtc.reset()

        // Load cursor position ON (0x81 = cmd 0x80, bit 0 = 1)
        crtc.writeCommand(0x81)
        #expect(crtc.cursorEnabled == true)
        crtc.writeParameter(10)  // X = 10
        crtc.writeParameter(5)   // Y = 5
        #expect(crtc.cursorX == 10)
        #expect(crtc.cursorY == 5)

        // Load cursor position OFF (0x80 = cmd 0x80, bit 0 = 0)
        crtc.writeCommand(0x80)
        #expect(crtc.cursorEnabled == false)
        #expect(crtc.cursorX == -1)
        #expect(crtc.cursorY == -1)
    }

    // MARK: - VRTC Timing

    @Test("VRTC flag transitions at blanking boundary")
    func vrtcFlagTransitionsAtBlankingBoundary() {
        let crtc = CRTC()
        crtc.reset()

        let tStatesPerLine = 509  // 8MHz

        // Advance to scanline 199 — still in active display
        for _ in 0..<199 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        #expect(crtc.scanline == 199)
        #expect(crtc.vrtcFlag == false)

        // Advance to scanline 200 — blanking starts
        crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        #expect(crtc.scanline == 200)
        #expect(crtc.vrtcFlag == true)

        // Advance through blanking (scanlines 201..261) then wrap
        for _ in 201..<262 {
            crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        }
        // Scanline 262 wraps to 0
        crtc.tick(tStates: tStatesPerLine, tStatesPerLine: tStatesPerLine)
        #expect(crtc.scanline == 0)  // wrapped to 0
        #expect(crtc.vrtcFlag == false)
    }

    @Test("DMA buffer write and read back")
    func dmaBufferWriteAndReadBack() {
        let crtc = CRTC()
        crtc.reset()
        crtc.startDMATransfer()

        // Write some data via writeDMABuffer
        crtc.writeDMABuffer(0x41)
        crtc.writeDMABuffer(0x42)
        crtc.writeDMABuffer(0x43)

        #expect(crtc.dmaBufferPtr == 3)

        // Read back via readDMABuffer
        #expect(crtc.readDMABuffer(at: 0) == 0x41)
        #expect(crtc.readDMABuffer(at: 1) == 0x42)
        #expect(crtc.readDMABuffer(at: 2) == 0x43)

        // Reading beyond written data returns 0
        #expect(crtc.readDMABuffer(at: 3) == 0)
        #expect(crtc.readDMABuffer(at: 100) == 0)
    }

    @Test("Dynamic scanline cache updates on parameter change")
    func dynamicScanlineCacheUpdates() {
        let crtc = CRTC()
        crtc.reset()

        // Set 400-line mode params: mode200Line=false, charLinesPerRow=16, vretrace=3
        crtc.mode200Line = false
        crtc.charLinesPerRow = 16
        crtc.linesPerScreen = 25
        crtc.vretrace = 3

        // Expected: (25 + 3) * 16 = 448
        #expect(crtc.dynamicTotalScanlines == 448)

        // Change charLinesPerRow to 8 → (25 + 3) * 8 = 224, but clamped to >= 262
        crtc.charLinesPerRow = 8
        #expect(crtc.dynamicTotalScanlines == 262)
    }

    @Test("Reset interrupt command clears status")
    func resetInterruptClearsStatus() {
        let crtc = CRTC()
        crtc.reset()

        // Set some status
        crtc.underrun = true
        #expect(crtc.readStatus() & 0x08 != 0)  // Underrun bit set

        // Reset Interrupt command (0xA0)
        crtc.writeCommand(0xA0)

        // underrun should remain (Reset Interrupt only clears interrupt flags,
        // not the underrun status itself — verified in source)
        // The command itself doesn't clear underrun; that's cleared by Start Display
        #expect(crtc.underrun == true)
    }

    @Test("Start Display with reverse flag")
    func startDisplayWithReverseFlag() {
        let crtc = CRTC()
        crtc.reset()

        // Send 0x21 (Start Display, bit0=reverse)
        crtc.writeCommand(0x21)
        #expect(crtc.reverseDisplay == true)
        #expect(crtc.displayEnabled == true)

        // Send 0x20 (Start Display, bit0=0, no reverse)
        crtc.writeCommand(0x20)
        #expect(crtc.reverseDisplay == false)
        #expect(crtc.displayEnabled == true)
    }
}
