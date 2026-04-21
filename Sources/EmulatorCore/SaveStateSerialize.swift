// MARK: - Save State Serialization
//
// Serialization and deserialization extensions for all emulator components.
// Uses SaveStateWriter/SaveStateReader from SaveState.swift.

import Foundation
import Z80
import FMSynthesis
import Peripherals

// MARK: - Z80

extension Z80 {
    public func writeSaveState(to w: inout SaveStateWriter) {
        w.writeUInt16(af)
        w.writeUInt16(bc)
        w.writeUInt16(de)
        w.writeUInt16(hl)
        w.writeUInt16(af2)
        w.writeUInt16(bc2)
        w.writeUInt16(de2)
        w.writeUInt16(hl2)
        w.writeUInt16(ix)
        w.writeUInt16(iy)
        w.writeUInt16(sp)
        w.writeUInt16(pc)
        w.writeUInt8(i)
        w.writeUInt8(r)
        w.writeBool(iff1)
        w.writeBool(iff2)
        w.writeUInt8(im)
        w.writeBool(halted)
        w.writeBool(eiPending)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        af = try r.readUInt16()
        bc = try r.readUInt16()
        de = try r.readUInt16()
        hl = try r.readUInt16()
        af2 = try r.readUInt16()
        bc2 = try r.readUInt16()
        de2 = try r.readUInt16()
        hl2 = try r.readUInt16()
        ix = try r.readUInt16()
        iy = try r.readUInt16()
        sp = try r.readUInt16()
        pc = try r.readUInt16()
        i = try r.readUInt8()
        self.r = try r.readUInt8()
        iff1 = try r.readBool()
        iff2 = try r.readBool()
        im = try r.readUInt8()
        halted = try r.readBool()
        eiPending = try r.readBool()
    }
}

// MARK: - Pc88Bus

extension Pc88Bus {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // Main RAM (65536 bytes, fixed size)
        w.writeBytes(mainRAM)

        // GVRAM: 3 planes x 16384 bytes (fixed size)
        for plane in 0..<3 {
            w.writeBytes(gvram[plane])
        }

        // tvram (4096 bytes, fixed size)
        w.writeBytes(tvram)

        // Banking state
        w.writeBool(romModeN88)
        w.writeBool(ramMode)
        w.writeInt(gvramPlane)
        w.writeBool(gamMode)
        w.writeBool(evramMode)
        w.writeUInt8(extROMBank)
        w.writeUInt8(n88ExtROMSelect)
        w.writeBool(extROMEnabled)
        w.writeUInt8(textWindowOffset)

        // Display control
        w.writeUInt8(port30w)
        w.writeUInt8(borderColor)
        w.writeUInt8(layerControl)
        w.writeBool(colorMode)
        w.writeBool(columns80)
        w.writeBool(analogPalette)
        w.writeBool(graphicsDisplayEnabled)
        w.writeBool(graphicsColorMode)
        w.writeBool(mode200Line)

        // Extended RAM
        if let ext = extRAM {
            w.writeUInt32(UInt32(ext.count))  // card count
            for card in ext {
                w.writeUInt32(UInt32(card.count))  // bank count
                for bank in card {
                    w.writeBytes(bank)  // 32KB each
                }
            }
        } else {
            w.writeUInt32(0)  // no ext RAM
        }
        w.writeBool(extRAMWriteEnable)
        w.writeBool(extRAMReadEnable)
        w.writeInt(extRAMCard)
        w.writeInt(extRAMBank)

        // Kanji ROM addresses
        w.writeUInt16(kanjiAddr1)
        w.writeUInt16(kanjiAddr2)

        // ALU state
        w.writeUInt8(aluControl1)
        w.writeUInt8(aluControl2)
        w.writeUInt8(aluReg[0])
        w.writeUInt8(aluReg[1])
        w.writeUInt8(aluReg[2])

        // System state
        w.writeUInt8(port31)
        w.writeUInt8(port32)
        w.writeUInt8(port40w)
        w.writeBool(cpuClock8MHz)
        w.writeBool(vrtcFlag)
        w.writeBool(directBasicBoot)
        w.writeInt(pendingWaitStates)
        w.writeBool(tvramEnabled)

        // Palette (8 entries, fixed size)
        for i in 0..<8 {
            w.writeUInt8(palette[i].b)
            w.writeUInt8(palette[i].r)
            w.writeUInt8(palette[i].g)
        }
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        // Main RAM
        mainRAM = try r.readBytes(65536)

        // GVRAM
        for plane in 0..<3 {
            gvram[plane] = try r.readBytes(0x4000)
        }

        // tvram
        tvram = try r.readBytes(4096)

        // Banking state
        romModeN88 = try r.readBool()
        ramMode = try r.readBool()
        gvramPlane = try r.readInt()
        gamMode = try r.readBool()
        evramMode = try r.readBool()
        extROMBank = try r.readUInt8()
        n88ExtROMSelect = try r.readUInt8()
        extROMEnabled = try r.readBool()
        textWindowOffset = try r.readUInt8()

        // Display control
        port30w = try r.readUInt8()
        borderColor = try r.readUInt8()
        layerControl = try r.readUInt8()
        colorMode = try r.readBool()
        columns80 = try r.readBool()
        analogPalette = try r.readBool()
        graphicsDisplayEnabled = try r.readBool()
        graphicsColorMode = try r.readBool()
        mode200Line = try r.readBool()

        // Extended RAM
        let cardCount = Int(try r.readUInt32())
        if cardCount > 0 {
            var ext: [[[UInt8]]] = []
            for _ in 0..<cardCount {
                let bankCount = Int(try r.readUInt32())
                var card: [[UInt8]] = []
                for _ in 0..<bankCount {
                    card.append(try r.readBytes(0x8000))
                }
                ext.append(card)
            }
            extRAM = ext
        } else {
            // Don't clear extRAM if it was already installed — just skip
        }
        extRAMWriteEnable = try r.readBool()
        extRAMReadEnable = try r.readBool()
        extRAMCard = try r.readInt()
        extRAMBank = try r.readInt()

        // Kanji ROM addresses
        kanjiAddr1 = try r.readUInt16()
        kanjiAddr2 = try r.readUInt16()

        // ALU state
        aluControl1 = try r.readUInt8()
        aluControl2 = try r.readUInt8()
        aluReg[0] = try r.readUInt8()
        aluReg[1] = try r.readUInt8()
        aluReg[2] = try r.readUInt8()

        // System state
        port31 = try r.readUInt8()
        port32 = try r.readUInt8()
        port40w = try r.readUInt8()
        cpuClock8MHz = try r.readBool()
        vrtcFlag = try r.readBool()
        directBasicBoot = try r.readBool()
        pendingWaitStates = try r.readInt()
        tvramEnabled = try r.readBool()

        // Palette
        for i in 0..<8 {
            let b = try r.readUInt8()
            let rv = try r.readUInt8()
            let g = try r.readUInt8()
            palette[i] = (b: b, r: rv, g: g)
        }
    }
}

// MARK: - CRTC

extension CRTC {
    public func writeSaveState(to w: inout SaveStateWriter) {
        w.writeInt(scanline)
        w.writeBool(vrtcFlag)
        w.writeInt(tStateAccumulator)
        w.writeBool(displayEnabled)
        w.writeBool(mode200Line)

        // Parameters (variable-length)
        w.writeUInt32(UInt32(parameters.count))
        w.writeBytes(parameters)
        w.writeInt(parameterIndex)
        w.writeInt(expectedParameters)
        w.writeUInt8(currentCommand)

        w.writeUInt8(charsPerLine)
        w.writeUInt8(linesPerScreen)
        w.writeUInt8(charLinesPerRow)
        w.writeBool(skipLine)
        w.writeUInt8(displayMode)
        w.writeBool(attrNonTransparent)
        w.writeUInt8(attrsPerLine)
        w.writeUInt8(intrMask)
        w.writeBool(reverseDisplay)
        w.writeInt(cursorX)
        w.writeInt(cursorY)
        w.writeBool(cursorEnabled)
        w.writeUInt8(cursorMode)
        w.writeInt(blinkRate)
        w.writeInt(blinkCounter)
        w.writeUInt8(blinkAttribBit)
        w.writeInt(vretrace)
        w.writeBool(dataReady)
        w.writeBool(lightPen)
        w.writeBool(underrun)

        // DMA buffer (24000 bytes, fixed size)
        w.writeBytes(dmaBuffer)
        w.writeInt(dmaBufferPtr)
        w.writeBool(dmaUnderrun)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        scanline = try r.readInt()
        vrtcFlag = try r.readBool()
        tStateAccumulator = try r.readInt()
        displayEnabled = try r.readBool()
        mode200Line = try r.readBool()

        let paramCount = Int(try r.readUInt32())
        parameters = try r.readBytes(paramCount)
        parameterIndex = try r.readInt()
        expectedParameters = try r.readInt()
        currentCommand = try r.readUInt8()

        charsPerLine = try r.readUInt8()
        linesPerScreen = try r.readUInt8()
        charLinesPerRow = try r.readUInt8()
        skipLine = try r.readBool()
        displayMode = try r.readUInt8()
        attrNonTransparent = try r.readBool()
        attrsPerLine = try r.readUInt8()
        intrMask = try r.readUInt8()
        reverseDisplay = try r.readBool()
        cursorX = try r.readInt()
        cursorY = try r.readInt()
        cursorEnabled = try r.readBool()
        cursorMode = try r.readUInt8()
        blinkRate = try r.readInt()
        blinkCounter = try r.readInt()
        blinkAttribBit = try r.readUInt8()
        vretrace = try r.readInt()
        dataReady = try r.readBool()
        lightPen = try r.readBool()
        underrun = try r.readBool()

        let dmaData = try r.readBytes(24000)
        for i in 0..<24000 { dmaBuffer[i] = dmaData[i] }
        dmaBufferPtr = try r.readInt()
        dmaUnderrun = try r.readBool()
    }
}

// MARK: - InterruptController

extension InterruptController {
    public mutating func writeSaveState(to w: inout SaveStateWriter) {
        w.writeUInt8(pendingLevels)
        w.writeUInt8(levelThreshold)
        w.writeBool(sgsMode)
        w.writeBool(maskRTC)
        w.writeBool(maskVRTC)
        w.writeBool(maskRXRDY)
        w.writeBool(maskSound)
    }

    public mutating func readSaveState(from r: inout SaveStateReader) throws {
        pendingLevels = try r.readUInt8()
        levelThreshold = try r.readUInt8()
        sgsMode = try r.readBool()
        maskRTC = try r.readBool()
        maskVRTC = try r.readBool()
        maskRXRDY = try r.readBool()
        maskSound = try r.readBool()
    }
}

// MARK: - DMAController

extension DMAController {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // 4 channels (fixed size)
        for i in 0..<4 {
            w.writeUInt16(channels[i].address)
            w.writeUInt16(channels[i].count)
            w.writeUInt8(channels[i].mode)
            w.writeBool(channels[i].enabled)
        }
        w.writeUInt8(modeRegister)
        w.writeBool(flipFlop)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        for i in 0..<4 {
            channels[i].address = try r.readUInt16()
            channels[i].count = try r.readUInt16()
            channels[i].mode = try r.readUInt8()
            channels[i].enabled = try r.readBool()
        }
        modeRegister = try r.readUInt8()
        flipFlop = try r.readBool()
    }
}

// NOTE: YM2608 and FMSynthesizer serialization is in FMSynthesis module
// (YM2608Serialize.swift, FMSynthesizerSerialize.swift) because they need
// access to private(set) and internal types/properties.
// YM2608 exposes serializeState() -> [UInt8] and deserializeState([UInt8]) -> Bool.
// because FMOp, FMCh, and RhythmChannel are internal types in the FMSynthesis module.
// FMSynthesizer exposes serializeState() -> [UInt8] and deserializeState([UInt8]) -> Bool.

// NOTE: UPD765A serialization is in Peripherals/PeripheralSerialize.swift
// because phase, resultBytes, resultIndex are public private(set) and can only
// be set from within the Peripherals module.
// UPD765A exposes serializeState() -> [UInt8] and deserializeState([UInt8]) -> Bool.

// MARK: - PIO8255

extension PIO8255 {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // Raw port state: 2 sides x 3 ports (fixed)
        for side in 0..<2 {
            for port in 0..<3 {
                w.writeUInt8(ports[side][port].wreg)
                w.writeUInt8(ports[side][port].rreg)
                w.writeUInt8(ports[side][port].rmask)
                w.writeUInt8(ports[side][port].mode)
                w.writeBool(ports[side][port].first)
            }
        }

        // PortAB state: 2 sides x 2 ports (fixed)
        for side in 0..<2 {
            for port in 0..<2 {
                w.writeUInt8(portAB[side][port].type == .read ? 0 : 1)
                w.writeBool(portAB[side][port].exist)
                w.writeUInt8(portAB[side][port].data)
            }
        }

        // PortC state: 2 sides x 2 halves (fixed)
        for side in 0..<2 {
            for half in 0..<2 {
                w.writeUInt8(portC[side][half].type == .read ? 0 : 1)
                w.writeBool(portC[side][half].contFlag)
                w.writeUInt8(portC[side][half].data)
            }
        }

        // Pending AB: 2 sides x 2 ports (fixed)
        for side in 0..<2 {
            for port in 0..<2 {
                w.writeBool(pendingAB[side][port])
            }
        }

        w.writeBool(clearPortsByCommandRegister)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        for side in 0..<2 {
            for port in 0..<3 {
                ports[side][port].wreg = try r.readUInt8()
                ports[side][port].rreg = try r.readUInt8()
                ports[side][port].rmask = try r.readUInt8()
                ports[side][port].mode = try r.readUInt8()
                ports[side][port].first = try r.readBool()
            }
        }

        for side in 0..<2 {
            for port in 0..<2 {
                let typeRaw = try r.readUInt8()
                portAB[side][port].type = typeRaw == 0 ? .read : .write
                portAB[side][port].exist = try r.readBool()
                portAB[side][port].data = try r.readUInt8()
            }
        }

        for side in 0..<2 {
            for half in 0..<2 {
                let typeRaw = try r.readUInt8()
                portC[side][half].type = typeRaw == 0 ? .read : .write
                portC[side][half].contFlag = try r.readBool()
                portC[side][half].data = try r.readUInt8()
            }
        }

        for side in 0..<2 {
            for port in 0..<2 {
                pendingAB[side][port] = try r.readBool()
            }
        }

        clearPortsByCommandRegister = try r.readBool()
    }
}

// MARK: - UPD1990A

extension UPD1990A {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // Shift register (7 bytes, fixed)
        for i in 0..<7 { w.writeUInt8(shiftReg[i]) }
        w.writeBool(cdo)
        w.writeUInt8(command)
        w.writeBool(din)
        w.writeUInt8(prevCtrl)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        for i in 0..<7 { shiftReg[i] = try r.readUInt8() }
        cdo = try r.readBool()
        command = try r.readUInt8()
        din = try r.readBool()
        prevCtrl = try r.readUInt8()
    }
}

// MARK: - Keyboard

extension Keyboard {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // 15 rows (fixed size)
        for i in 0..<15 { w.writeUInt8(matrix[i]) }
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        for i in 0..<15 { matrix[i] = try r.readUInt8() }
    }
}

// MARK: - SubBus

extension SubBus {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // romram (32KB, fixed)
        w.writeBytes(romram)

        // Motor state (4 drives, fixed)
        for i in 0..<4 { w.writeBool(motorOn[i]) }

        // Drive/side select
        w.writeUInt8(driveSelect)

        // Current sub PC
        w.writeUInt16(currentSubPC)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        romram = try r.readBytes(0x8000)
        for i in 0..<4 { motorOn[i] = try r.readBool() }
        driveSelect = try r.readUInt8()
        currentSubPC = try r.readUInt16()
    }
}

// MARK: - SubSystem

extension SubSystem {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // Sub-CPU
        subCpu.writeSaveState(to: &w)

        // SubBus
        subBus.writeSaveState(to: &w)

        // PIO
        pio.writeSaveState(to: &w)

        // FDC (serialized as length-prefixed blob — lives in Peripherals module)
        let fdcData = fdc.serializeState()
        w.writeLengthPrefixedBytes(fdcData)

        // Drive state: drives are NOT serialized here (handled by Machine)
        // Access indicators
        w.writeBool(diskAccess[0])
        w.writeBool(diskAccess[1])
        w.writeUInt64(subCpuTStates)

        // Legacy mode
        w.writeBool(useLegacyMode)
        w.writeUInt8(legacyPortA)
        w.writeUInt8(legacyPortB)
        w.writeUInt8(legacyMainPortCH)
        w.writeUInt8(legacySubPortCH)
        w.writeUInt8(legacyPioControl)
        w.writeBool(legacyExpectingCommand)
        w.writeUInt8(legacyCurrentCommand)

        // legacyCommandParams (variable-length)
        w.writeUInt32(UInt32(legacyCommandParams.count))
        w.writeBytes(legacyCommandParams)

        w.writeInt(legacyExpectedParamCount)
        w.writeBool(legacyCollectingWriteData)
        w.writeInt(legacyWriteDataExpected)

        // legacyWriteDataBuffer (variable-length)
        w.writeUInt32(UInt32(legacyWriteDataBuffer.count))
        w.writeBytes(legacyWriteDataBuffer)

        // legacyReadBuffer (variable-length)
        w.writeUInt32(UInt32(legacyReadBuffer.count))
        w.writeBytes(legacyReadBuffer)

        w.writeUInt8(legacyResultStatus)
        w.writeUInt8(legacySurfaceMode)

        // legacyResponseQueue (variable-length)
        w.writeUInt32(UInt32(legacyResponseQueue.count))
        w.writeBytes(legacyResponseQueue)
        w.writeInt(legacyResponseIndex)

        // legacyMotorOn (2 drives, fixed)
        w.writeBool(legacyMotorOn[0])
        w.writeBool(legacyMotorOn[1])

        // legacyCurrentTrack (2 drives, fixed)
        w.writeInt(legacyCurrentTrack[0])
        w.writeInt(legacyCurrentTrack[1])

        // Debug counters
        w.writeInt(commandCount)
        w.writeUInt8(lastCommand)
        w.writeInt(fdcInterruptDeliveredCount)
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        // Sub-CPU
        try subCpu.readSaveState(from: &r)

        // SubBus
        try subBus.readSaveState(from: &r)

        // PIO
        try pio.readSaveState(from: &r)

        // FDC (length-prefixed blob)
        let fdcData = try r.readLengthPrefixedBytes()
        fdc.deserializeState(fdcData)

        // Access indicators
        diskAccess[0] = try r.readBool()
        diskAccess[1] = try r.readBool()
        subCpuTStates = try r.readUInt64()

        // Legacy mode
        useLegacyMode = try r.readBool()
        legacyPortA = try r.readUInt8()
        legacyPortB = try r.readUInt8()
        legacyMainPortCH = try r.readUInt8()
        legacySubPortCH = try r.readUInt8()
        legacyPioControl = try r.readUInt8()
        legacyExpectingCommand = try r.readBool()
        legacyCurrentCommand = try r.readUInt8()

        let paramCount = Int(try r.readUInt32())
        legacyCommandParams = try r.readBytes(paramCount)

        legacyExpectedParamCount = try r.readInt()
        legacyCollectingWriteData = try r.readBool()
        legacyWriteDataExpected = try r.readInt()

        let writeDataCount = Int(try r.readUInt32())
        legacyWriteDataBuffer = try r.readBytes(writeDataCount)

        let readBufCount = Int(try r.readUInt32())
        legacyReadBuffer = try r.readBytes(readBufCount)

        legacyResultStatus = try r.readUInt8()
        legacySurfaceMode = try r.readUInt8()

        let respCount = Int(try r.readUInt32())
        legacyResponseQueue = try r.readBytes(respCount)
        legacyResponseIndex = try r.readInt()

        legacyMotorOn[0] = try r.readBool()
        legacyMotorOn[1] = try r.readBool()

        legacyCurrentTrack[0] = try r.readInt()
        legacyCurrentTrack[1] = try r.readInt()

        // Debug counters
        commandCount = try r.readInt()
        lastCommand = try r.readUInt8()
        fdcInterruptDeliveredCount = try r.readInt()
    }
}

// MARK: - Machine

extension Machine {
    public func writeSaveState(to w: inout SaveStateWriter) {
        // CPU
        cpu.writeSaveState(to: &w)

        // Bus
        bus.writeSaveState(to: &w)

        // Interrupt controller
        interruptBox.controller.writeSaveState(to: &w)

        // Keyboard
        keyboard.writeSaveState(to: &w)

        // DMA
        dma.writeSaveState(to: &w)

        // CRTC
        crtc.writeSaveState(to: &w)

        // Sound (YM2608) — serialized as length-prefixed blob
        let soundData = sound.serializeState()
        w.writeLengthPrefixedBytes(soundData)

        // SubSystem
        subSystem.writeSaveState(to: &w)

        // Calendar
        calendar.writeSaveState(to: &w)

        // Machine state
        w.writeUInt64(totalTStates)
        w.writeInt(rtcCounter)
        w.writeInt(subAccumClocks)
        w.writeInt(subDebt)
        w.writeBool(clock8MHz)
        w.writeBool(traceEnabled)
    }

    /// Create a complete save state file with disk images.
    public func createSaveState(thumbnail: [UInt8]? = nil) -> [UInt8] {
        var w = SaveStateWriter()
        writeSaveState(to: &w)
        let mainSection = (tag: SaveStateFile.fourCC("MAIN"), data: w.data)

        var sections = [mainSection]

        // Disk images (D88 serialized)
        if let disk0 = subSystem.drives[0], let d88Data = disk0.serialize() {
            sections.append((tag: SaveStateFile.fourCC("DSK0"), data: d88Data))
        }
        if let disk1 = subSystem.drives[1], let d88Data = disk1.serialize() {
            sections.append((tag: SaveStateFile.fourCC("DSK1"), data: d88Data))
        }

        // Cassette deck + I8251 (optional; omitted when no tape is loaded)
        if cassette.isLoaded {
            var cmt: [UInt8] = []
            let u = usart.serializeState()
            let d = cassette.serializeState()
            // CMT layout: [usartLen(u32)][usart bytes][deckLen(u32)][deck bytes]
            SaveStateFile.appendU32LE(&cmt, UInt32(u.count))
            cmt.append(contentsOf: u)
            SaveStateFile.appendU32LE(&cmt, UInt32(d.count))
            cmt.append(contentsOf: d)
            sections.append((tag: SaveStateFile.fourCC("CMT "), data: cmt))
        }

        // Metadata JSON
        let disk0Name = subSystem.drives[0]?.name ?? ""
        let disk1Name = subSystem.drives[1]?.name ?? ""
        let metaJSON = "{\"disk0\":\"\(disk0Name)\",\"disk1\":\"\(disk1Name)\",\"clock8MHz\":\(clock8MHz)}"
        sections.append((tag: SaveStateFile.fourCC("META"), data: Array(metaJSON.utf8)))

        return SaveStateFile.build(sections: sections, thumbnail: thumbnail)
    }

    /// Load a complete save state file, restoring all components and disk images.
    public func loadSaveState(_ data: [UInt8]) throws {
        let sections = try SaveStateFile.parse(data)

        guard let mainData = sections[SaveStateFile.fourCC("MAIN")] else {
            throw SaveStateError.missingSections(["MAIN"])
        }
        var r = SaveStateReader(mainData)
        try readSaveState(from: &r)

        // Restore disk images
        if let d88Data = sections[SaveStateFile.fourCC("DSK0")] {
            if let disk = D88Disk.parse(data: d88Data) {
                subSystem.mountDisk(drive: 0, disk: disk)
            }
        } else {
            subSystem.ejectDisk(drive: 0)
        }

        if let d88Data = sections[SaveStateFile.fourCC("DSK1")] {
            if let disk = D88Disk.parse(data: d88Data) {
                subSystem.mountDisk(drive: 1, disk: disk)
            }
        } else {
            subSystem.ejectDisk(drive: 1)
        }

        if let cmt = sections[SaveStateFile.fourCC("CMT ")] {
            var p = 0
            if let uLen = SaveStateFile.readU32LE(cmt, at: &p), p + Int(uLen) <= cmt.count {
                usart.deserializeState(Array(cmt[p..<(p + Int(uLen))]))
                p += Int(uLen)
                if let dLen = SaveStateFile.readU32LE(cmt, at: &p), p + Int(dLen) <= cmt.count {
                    cassette.deserializeState(Array(cmt[p..<(p + Int(dLen))]))
                }
            }
        } else {
            cassette.eject()
            usart.reset()
        }
    }

    public func readSaveState(from r: inout SaveStateReader) throws {
        // CPU
        try cpu.readSaveState(from: &r)

        // Bus
        try bus.readSaveState(from: &r)

        // Interrupt controller
        try interruptBox.controller.readSaveState(from: &r)

        // Keyboard
        try keyboard.readSaveState(from: &r)

        // DMA
        try dma.readSaveState(from: &r)

        // CRTC
        try crtc.readSaveState(from: &r)

        // Sound (YM2608) — length-prefixed blob
        let soundData = try r.readLengthPrefixedBytes()
        sound.deserializeState(soundData)

        // SubSystem
        try subSystem.readSaveState(from: &r)

        // Calendar
        try calendar.readSaveState(from: &r)

        // Machine state
        totalTStates = try r.readUInt64()
        rtcCounter = try r.readInt()
        subAccumClocks = try r.readInt()
        subDebt = try r.readInt()
        clock8MHz = try r.readBool()
        traceEnabled = try r.readBool()
    }
}
