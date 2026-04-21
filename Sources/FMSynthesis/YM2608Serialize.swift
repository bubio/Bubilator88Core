// MARK: - YM2608 Save State Serialization
//
// This file must live in the FMSynthesis module to access private(set)
// and package properties of YM2608.

import Foundation

extension YM2608 {

    /// Serialize all YM2608 state to a byte array.
    public func serializeState() -> [UInt8] {
        var buf: [UInt8] = []
        buf.reserveCapacity(0x42000)  // ~256KB for ADPCM RAM + overhead

        // Register banks (256 + 256 bytes, fixed)
        buf.append(contentsOf: registers)
        buf.append(contentsOf: extRegisters)
        buf.append(selectedAddr)
        buf.append(selectedExtAddr)

        // Timer state
        appendU16(&buf, timerAValue)
        buf.append(timerBValue)
        appendI64(&buf, Int64(timerACounter))
        appendI64(&buf, Int64(timerBCounter))
        buf.append(timerAEnabled ? 1 : 0)
        buf.append(timerBEnabled ? 1 : 0)
        buf.append(timerAOverflow ? 1 : 0)
        buf.append(timerBOverflow ? 1 : 0)
        buf.append(timerAIRQEnable ? 1 : 0)
        buf.append(timerBIRQEnable ? 1 : 0)
        buf.append(statusMask)
        buf.append(irqControl)
        buf.append(irqAsserted ? 1 : 0)
        appendI64(&buf, Int64(busyStatusCounter))

        // Clock mode
        buf.append(clock8MHz ? 1 : 0)

        // FM sample counter
        appendI64(&buf, Int64(fmSampleCounter))

        // FM F-number caches (6 + 3 entries, fixed)
        for i in 0..<6 { appendU32(&buf, fmFNumMain[i]) }
        for i in 0..<3 { appendU32(&buf, fmFNum3[i]) }

        // SSG state
        for i in 0..<3 { appendU16(&buf, ssgTonePeriod[i]) }
        for i in 0..<3 { appendI64(&buf, Int64(ssgToneCounter[i])) }
        for i in 0..<3 { buf.append(ssgToneOutput[i] ? 1 : 0) }
        for i in 0..<3 { buf.append(ssgVolume[i]) }
        buf.append(ssgNoisePeriod)
        appendI64(&buf, Int64(ssgNoiseCounter))
        appendU32(&buf, ssgNoiseLFSR)
        buf.append(ssgNoiseOutput ? 1 : 0)
        buf.append(ssgMixer)
        appendU16(&buf, ssgEnvPeriod)
        appendI64(&buf, Int64(ssgEnvCounter))
        buf.append(ssgEnvShape)
        appendI64(&buf, Int64(ssgEnvPosition))
        buf.append(ssgEnvHolding ? 1 : 0)

        // SSG band-limited state
        for i in 0..<3 { appendU32(&buf, ssgTonePhase[i]) }
        for i in 0..<3 { appendU32(&buf, ssgToneStep[i]) }
        appendU32(&buf, ssgNoisePhase)
        appendU32(&buf, ssgNoiseStep)
        appendU32(&buf, ssgEnvelopePhase)
        appendU32(&buf, ssgEnvelopeStep)
        for i in 0..<3 { appendI64(&buf, Int64(ssgOutputLevel[i])) }

        // ADPCM state
        appendU32(&buf, adpcmStartAddr)
        appendU32(&buf, adpcmStopAddr)
        buf.append(adpcmPlaying ? 1 : 0)
        appendI64(&buf, Int64(adpcmAccum))
        appendI64(&buf, Int64(adpcmStepSize))
        appendU16(&buf, adpcmDeltaN)
        buf.append(adpcmTotalLevel)
        appendU32(&buf, adpcmRateAccum)
        appendFloat(&buf, adpcmOutputSample)
        appendI64(&buf, Int64(adpcmPlaybackCounter))
        appendI64(&buf, Int64(adpcmPlaybackDelta))
        appendI64(&buf, Int64(adpcmDecodedOutput))
        appendI64(&buf, Int64(adpcmOutputStage0))
        appendI64(&buf, Int64(adpcmOutputStage1))
        buf.append(adpcmControl1)
        buf.append(adpcmControl2)
        buf.append(adpcmStatusFlags)
        appendU32(&buf, adpcmMemAddr)
        appendU32(&buf, adpcmLimitAddr)
        buf.append(adpcmReadBuffer)

        // ADPCM RAM (256KB, fixed)
        buf.append(contentsOf: adpcmRAM)

        // Audio sample accumulator
        appendI64(&buf, Int64(audioSampleAccum))

        // FM output state
        appendI64(&buf, Int64(fmOutputL))
        appendI64(&buf, Int64(fmOutputR))
        appendI64(&buf, Int64(rhythmOutputL))
        appendI64(&buf, Int64(rhythmOutputR))

        // BEEP
        buf.append(beepOn ? 1 : 0)
        buf.append(singSignal ? 1 : 0)
        appendDouble(&buf, beepPhase)

        // FMSynthesizer (as length-prefixed blob)
        let fmData = fmSynth.serializeState()
        appendU32(&buf, UInt32(fmData.count))
        buf.append(contentsOf: fmData)

        return buf
    }

    /// Deserialize all YM2608 state from a byte array.
    /// Returns true on success.
    @discardableResult
    public func deserializeState(_ data: [UInt8]) -> Bool {
        var pos = 0

        guard data.count >= 512 + 256 else { return false }

        // Register banks
        for i in 0..<256 { registers[i] = data[pos + i] }; pos += 256
        for i in 0..<256 { extRegisters[i] = data[pos + i] }; pos += 256
        selectedAddr = data[pos]; pos += 1
        selectedExtAddr = data[pos]; pos += 1

        // Timer state
        timerAValue = readU16(data, at: &pos)
        timerBValue = data[pos]; pos += 1
        timerACounter = Int(readI64(data, at: &pos))
        timerBCounter = Int(readI64(data, at: &pos))
        timerAEnabled = data[pos] != 0; pos += 1
        timerBEnabled = data[pos] != 0; pos += 1
        timerAOverflow = data[pos] != 0; pos += 1
        timerBOverflow = data[pos] != 0; pos += 1
        timerAIRQEnable = data[pos] != 0; pos += 1
        timerBIRQEnable = data[pos] != 0; pos += 1
        statusMask = data[pos]; pos += 1
        irqControl = data[pos]; pos += 1
        irqAsserted = data[pos] != 0; pos += 1
        busyStatusCounter = Int(readI64(data, at: &pos))

        // Clock mode
        clock8MHz = data[pos] != 0; pos += 1

        // FM sample counter
        fmSampleCounter = Int(readI64(data, at: &pos))

        // FM F-number caches
        for i in 0..<6 { fmFNumMain[i] = readU32(data, at: &pos) }
        for i in 0..<3 { fmFNum3[i] = readU32(data, at: &pos) }

        // SSG state
        for i in 0..<3 { ssgTonePeriod[i] = readU16(data, at: &pos) }
        for i in 0..<3 { ssgToneCounter[i] = Int(readI64(data, at: &pos)) }
        for i in 0..<3 { ssgToneOutput[i] = data[pos] != 0; pos += 1 }
        for i in 0..<3 { ssgVolume[i] = data[pos]; pos += 1 }
        ssgNoisePeriod = data[pos]; pos += 1
        ssgNoiseCounter = Int(readI64(data, at: &pos))
        ssgNoiseLFSR = readU32(data, at: &pos)
        ssgNoiseOutput = data[pos] != 0; pos += 1
        ssgMixer = data[pos]; pos += 1
        ssgEnvPeriod = readU16(data, at: &pos)
        ssgEnvCounter = Int(readI64(data, at: &pos))
        ssgEnvShape = data[pos]; pos += 1
        ssgEnvPosition = Int(readI64(data, at: &pos))
        ssgEnvHolding = data[pos] != 0; pos += 1

        // SSG band-limited state
        for i in 0..<3 { ssgTonePhase[i] = readU32(data, at: &pos) }
        for i in 0..<3 { ssgToneStep[i] = readU32(data, at: &pos) }
        ssgNoisePhase = readU32(data, at: &pos)
        ssgNoiseStep = readU32(data, at: &pos)
        ssgEnvelopePhase = readU32(data, at: &pos)
        ssgEnvelopeStep = readU32(data, at: &pos)
        for i in 0..<3 { ssgOutputLevel[i] = Int(readI64(data, at: &pos)) }

        // ADPCM state
        adpcmStartAddr = readU32(data, at: &pos)
        adpcmStopAddr = readU32(data, at: &pos)
        adpcmPlaying = data[pos] != 0; pos += 1
        adpcmAccum = Int(readI64(data, at: &pos))
        adpcmStepSize = Int(readI64(data, at: &pos))
        adpcmDeltaN = readU16(data, at: &pos)
        adpcmTotalLevel = data[pos]; pos += 1
        adpcmRateAccum = readU32(data, at: &pos)
        adpcmOutputSample = readFloat(data, at: &pos)
        adpcmPlaybackCounter = Int(readI64(data, at: &pos))
        adpcmPlaybackDelta = Int(readI64(data, at: &pos))
        adpcmDecodedOutput = Int(readI64(data, at: &pos))
        adpcmOutputStage0 = Int(readI64(data, at: &pos))
        adpcmOutputStage1 = Int(readI64(data, at: &pos))
        adpcmControl1 = data[pos]; pos += 1
        adpcmControl2 = data[pos]; pos += 1
        adpcmStatusFlags = data[pos]; pos += 1
        adpcmMemAddr = readU32(data, at: &pos)
        adpcmLimitAddr = readU32(data, at: &pos)
        adpcmReadBuffer = data[pos]; pos += 1

        // ADPCM RAM
        guard pos + 0x40000 <= data.count else { return false }
        adpcmRAM = Array(data[pos..<(pos + 0x40000)]); pos += 0x40000

        // Audio sample accumulator
        audioSampleAccum = Int(readI64(data, at: &pos))

        // FM output state
        fmOutputL = Int(readI64(data, at: &pos))
        fmOutputR = Int(readI64(data, at: &pos))
        rhythmOutputL = Int(readI64(data, at: &pos))
        rhythmOutputR = Int(readI64(data, at: &pos))

        // BEEP
        beepOn = data[pos] != 0; pos += 1
        singSignal = data[pos] != 0; pos += 1
        beepPhase = readDouble(data, at: &pos)

        // FMSynthesizer
        let fmDataLen = Int(readU32(data, at: &pos))
        guard pos + fmDataLen <= data.count else { return false }
        let fmData = Array(data[pos..<(pos + fmDataLen)]); pos += fmDataLen
        fmSynth.deserializeState(fmData)

        // Clear transient audio buffer
        audioBuffer.removeAll()

        return true
    }

    // MARK: - Binary helpers

    private func appendU16(_ buf: inout [UInt8], _ v: UInt16) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8(v >> 8))
    }

    private func appendU32(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8(v >> 24))
    }

    private func appendI32(_ buf: inout [UInt8], _ v: Int32) {
        appendU32(&buf, UInt32(bitPattern: v))
    }

    private func appendI64(_ buf: inout [UInt8], _ v: Int64) {
        let bits = UInt64(bitPattern: v)
        for i in 0..<8 {
            buf.append(UInt8((bits >> (i * 8)) & 0xFF))
        }
    }

    private func readI64(_ data: [UInt8], at pos: inout Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos + i]) << (i * 8) }
        pos += 8
        return Int64(bitPattern: v)
    }

    private func appendFloat(_ buf: inout [UInt8], _ v: Float) {
        appendU32(&buf, v.bitPattern)
    }

    private func appendDouble(_ buf: inout [UInt8], _ v: Double) {
        let bits = v.bitPattern
        for i in 0..<8 {
            buf.append(UInt8((bits >> (i * 8)) & 0xFF))
        }
    }

    private func readU16(_ data: [UInt8], at pos: inout Int) -> UInt16 {
        let v = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
        pos += 2
        return v
    }

    private func readU32(_ data: [UInt8], at pos: inout Int) -> UInt32 {
        let v = UInt32(data[pos])
            | (UInt32(data[pos + 1]) << 8)
            | (UInt32(data[pos + 2]) << 16)
            | (UInt32(data[pos + 3]) << 24)
        pos += 4
        return v
    }

    private func readI32(_ data: [UInt8], at pos: inout Int) -> Int32 {
        Int32(bitPattern: readU32(data, at: &pos))
    }

    private func readFloat(_ data: [UInt8], at pos: inout Int) -> Float {
        Float(bitPattern: readU32(data, at: &pos))
    }

    private func readDouble(_ data: [UInt8], at pos: inout Int) -> Double {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[pos + i]) << (i * 8)
        }
        pos += 8
        return Double(bitPattern: v)
    }
}
