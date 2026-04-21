#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - FMSynthesizer (fmgen port)
//
// Port of cisc's fmgen FM synthesis engine to Swift.
// Reference: BubiC-8801MA/src/vm/fmgen/

// MARK: - Constants

enum FM {
    static let sineBits = 10
    static let sineEntries = 1 << sineBits
    static let phaseBits = 9
    static let ratioBits = 7
    static let egCounterBits = 18
    static let lfoCounterBits = 14
    static let combinedLogEntries = 0x1000 * 2  // 8192 = sineEntries * 8 (log range × sign pairs)
    static let egBottom = 955
    static let lfoEntries = 256
    static let inputToEGShift = (20 + 9) - 13
    static let egMaxLevel = 0x3FF
    static let tlBits = 7
    static let tlEntries = 1 << tlBits
    static let tlOffset = tlEntries / 4
    static let noFeedback: UInt8 = 31

    // EG level thresholds for SSG-EG and normal envelope
    static let ssgEGLimit = 0x200       // SSG-EG sustain/decay ceiling
    static let normalEGLimit = 0x400    // Normal EG off threshold
    static let ssgEGStep = 0x200        // SSG-EG offset unit

    // SSG-EG attack rate thresholds (fmgen: type 8/12 use 56, others 60)
    static let ssgARThresholdAlt = 56   // SSG-EG types 8, 12
    static let ssgARThresholdDefault = 60
    static let ssgTypeAlt1: UInt32 = 8
    static let ssgTypeAlt2: UInt32 = 12

    // Fixed-point scale for PM/TL tables (16-bit fraction)
    static let fixedPointScale = 65536.0

    // 16-bit signed audio sample range
    static let sampleMax = 32767
    static let sampleMin = -32768
    static let sampleScale: Float = 32768.0

    // Rhythm channel fixed-point scale (position × 1024)
    static let rhythmFixedPointScale = 1024
}

// MARK: - Static Tables

/// Log-domain sine table (1024 entries). Even index = positive half, odd = negative.
/// sinetable[i] is an index into cltable.
let sineTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: FM.sineEntries)
    let log2 = log(2.0)
    for i in 0..<(FM.sineEntries / 2) {
        let r = Double(i * 2 + 1) * Double.pi / Double(FM.sineEntries)
        let q = -256.0 * log(sin(r)) / log2
        let s = UInt32(floor(q + 0.5)) + 1
        table[i] = s * 2                              // positive half
        table[FM.sineEntries / 2 + i] = s * 2 + 1       // negative half
    }
    return table
}()

/// Log-to-linear conversion table (8192 entries). Pairs of [+val, -val].
let combinedLogTable: [Int32] = {
    var table = [Int32](repeating: 0, count: FM.combinedLogEntries)
    // First 512 entries (256 pairs)
    for i in 0..<256 {
        var v = Int32(floor(pow(2.0, 13.0 - Double(i) / 256.0)))
        v = (v + 2) & ~3
        table[i * 2] = v
        table[i * 2 + 1] = -v
    }
    // Remaining entries: halve from 512 back
    var idx = 512
    while idx < FM.combinedLogEntries {
        table[idx] = table[idx - 512] / 2
        idx += 1
    }
    return table
}()

/// Detune table [256] — indexed by (detune * 32 + blockNote)
private let detuneTable: [Int8] = [
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,
      4,  6,  6,  6,  8,  8,  8, 10, 10, 12, 12, 14, 16, 16, 16, 16,
      2,  2,  2,  2,  4,  4,  4,  4,  4,  6,  6,  6,  8,  8,  8, 10,
     10, 12, 12, 14, 16, 16, 18, 20, 22, 24, 26, 28, 32, 32, 32, 32,
      4,  4,  4,  4,  4,  6,  6,  6,  8,  8,  8, 10, 10, 12, 12, 14,
     16, 16, 18, 20, 22, 24, 26, 28, 32, 34, 38, 40, 44, 44, 44, 44,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0, -2, -2, -2, -2, -2, -2, -2, -2, -4, -4, -4, -4,
     -4, -6, -6, -6, -8, -8, -8,-10,-10,-12,-12,-14,-16,-16,-16,-16,
     -2, -2, -2, -2, -4, -4, -4, -4, -4, -6, -6, -6, -8, -8, -8,-10,
    -10,-12,-12,-14,-16,-16,-18,-20,-22,-24,-26,-28,-32,-32,-32,-32,
     -4, -4, -4, -4, -4, -6, -6, -6, -8, -8, -8,-10,-10,-12,-12,-14,
    -16,-16,-18,-20,-22,-24,-26,-28,-32,-34,-38,-40,-44,-44,-44,-44,
]

/// Note table: (fnum >> 7) & 127 → block/note value for KS and detune
private let noteTable: [UInt8] = [
     0,  0,  0,  0,  0,  0,  0,  1,  2,  3,  3,  3,  3,  3,  3,  3,
     4,  4,  4,  4,  4,  4,  4,  5,  6,  7,  7,  7,  7,  7,  7,  7,
     8,  8,  8,  8,  8,  8,  8,  9, 10, 11, 11, 11, 11, 11, 11, 11,
    12, 12, 12, 12, 12, 12, 12, 13, 14, 15, 15, 15, 15, 15, 15, 15,
    16, 16, 16, 16, 16, 16, 16, 17, 18, 19, 19, 19, 19, 19, 19, 19,
    20, 20, 20, 20, 20, 20, 20, 21, 22, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 25, 26, 27, 27, 27, 27, 27, 27, 27,
    28, 28, 28, 28, 28, 28, 28, 29, 30, 31, 31, 31, 31, 31, 31, 31,
]

/// Attack table [64][8]
private let attackRateTable: [[Int8]] = [
    [-1,-1,-1,-1,-1,-1,-1,-1], [-1,-1,-1,-1,-1,-1,-1,-1],
    [ 4, 4, 4, 4, 4, 4, 4, 4], [ 4, 4, 4, 4, 4, 4, 4, 4],
    [ 4, 4, 4, 4, 4, 4, 4, 4], [ 4, 4, 4, 4, 4, 4, 4, 4],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4,-1, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4,-1, 4,-1, 4,-1, 4,-1], [ 4, 4, 4,-1, 4,-1, 4,-1],
    [ 4, 4, 4,-1, 4, 4, 4,-1], [ 4, 4, 4, 4, 4, 4, 4,-1],
    [ 4, 4, 4, 4, 4, 4, 4, 4], [ 3, 4, 4, 4, 3, 4, 4, 4],
    [ 3, 4, 3, 4, 3, 4, 3, 4], [ 3, 3, 3, 4, 3, 3, 3, 4],
    [ 3, 3, 3, 3, 3, 3, 3, 3], [ 2, 3, 3, 3, 2, 3, 3, 3],
    [ 2, 3, 2, 3, 2, 3, 2, 3], [ 2, 2, 2, 3, 2, 2, 2, 3],
    [ 2, 2, 2, 2, 2, 2, 2, 2], [ 1, 2, 2, 2, 1, 2, 2, 2],
    [ 1, 2, 1, 2, 1, 2, 1, 2], [ 1, 1, 1, 2, 1, 1, 1, 2],
    [ 0, 0, 0, 0, 0, 0, 0, 0], [ 0, 0, 0, 0, 0, 0, 0, 0],
    [ 0, 0, 0, 0, 0, 0, 0, 0], [ 0, 0, 0, 0, 0, 0, 0, 0],
]

/// Decay table 1 [64][8]
private let decayRateTable: [[Int8]] = [
    [0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 1, 1],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 0, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 0, 1, 0, 1, 0, 1, 0], [1, 1, 1, 0, 1, 0, 1, 0],
    [1, 1, 1, 0, 1, 1, 1, 0], [1, 1, 1, 1, 1, 1, 1, 0],
    [1, 1, 1, 1, 1, 1, 1, 1], [2, 1, 1, 1, 2, 1, 1, 1],
    [2, 1, 2, 1, 2, 1, 2, 1], [2, 2, 2, 1, 2, 2, 2, 1],
    [2, 2, 2, 2, 2, 2, 2, 2], [4, 2, 2, 2, 4, 2, 2, 2],
    [4, 2, 4, 2, 4, 2, 4, 2], [4, 4, 4, 2, 4, 4, 4, 2],
    [4, 4, 4, 4, 4, 4, 4, 4], [8, 4, 4, 4, 8, 4, 4, 4],
    [8, 4, 8, 4, 8, 4, 8, 4], [8, 8, 8, 4, 8, 8, 8, 4],
    [16,16,16,16,16,16,16,16], [16,16,16,16,16,16,16,16],
    [16,16,16,16,16,16,16,16], [16,16,16,16,16,16,16,16],
]

/// Decay table 2 [16] — EG counter step size per rate/4
private let decayCounterTable: [Int] = [
    1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2047, 2047, 2047, 2047, 2047
]

/// Feedback shift table: fb register value → shift amount
let feedbackShiftTable: [UInt8] = [31, 7, 6, 5, 4, 3, 2, 1]

/// SSG-EG table [8][2][3][2] — [type&7][arHigh][phase][offset/vector]
private let ssgEnvelopeTable: [Int8] = [
    // type 0 (08)
    1, 1,  1, 1,  1, 1,     // ar < threshold
    0, 1,  1, 1,  1, 1,     // ar >= 56
    // type 1 (09)
    0, 1,  2, 0,  2, 0,
    0, 1,  2, 0,  2, 0,
    // type 2 (10)
    1,-1,  0, 1,  1,-1,
    0, 1,  1,-1,  0, 1,     // ar >= 60
    // type 3 (11)
    1,-1,  0, 0,  0, 0,
    0, 1,  0, 0,  0, 0,     // ar >= 60
    // type 4 (12)
    2,-1,  2,-1,  2,-1,
    1,-1,  2,-1,  2,-1,     // ar >= 56
    // type 5 (13)
    1,-1,  0, 0,  0, 0,
    1,-1,  0, 0,  0, 0,
    // type 6 (14)
    0, 1,  1,-1,  0, 1,
    1,-1,  0, 1,  1,-1,     // ar >= 60
    // type 7 (15)
    0, 1,  2, 0,  2, 0,
    1,-1,  2, 0,  2, 0,     // ar >= 60
]

/// DT2 level multiplier
private let dt2Multiplier: [Float] = [1.0, 1.414, 1.581, 1.732]

/// LFO frequency divisor table
private let lfoDivisorTable: [UInt8] = [108, 77, 71, 67, 62, 44, 8, 5]

// MARK: - FM Operator (fmgen-accurate)

struct FMOp {
    // Phase generator
    var pgCount: UInt32 = 0
    var pgDiff: UInt32 = 0
    var pgDiffLfo: UInt32 = 0

    // Parameters (from registers)
    var dp: UInt32 = 0         // (fnum & 2047) << block
    var bn: UInt32 = 0         // block/note for KS and detune
    var detune: UInt32 = 0     // DT1 (0-7) * 32 → index into dttable
    var detune2: UInt32 = 0    // DT2 (0-3)
    var multiple: UInt32 = 0   // MUL (0-15)

    // Envelope generator
    var egLevel: Int = FM.egBottom
    var egLevelOnNextPhase: Int = FM.egBottom
    var egCount: Int = 0
    var egCountDiff: Int = 0
    var egOut: Int = 0
    var tlOut: Int = 0
    var egRate: Int = 0
    var egCurveCount: Int = 0
    var egPhase: EGPhase = .off

    // SSG-EG
    var ssgOffset: Int = 0
    var ssgVector: Int = 1
    var ssgPhase: Int = -1
    var ssgType: UInt32 = 0

    // Key scale & TL
    var keyScaleRate: UInt32 = 0
    var tl: UInt32 = 0
    var tlLatch: UInt32 = 0
    var ks: UInt32 = 0

    // Rates
    var ar: UInt32 = 0
    var dr: UInt32 = 0
    var sr: UInt32 = 0
    var sl: UInt32 = 0
    var rr: UInt32 = 0

    // Output
    var out: Int = 0
    var out2: Int = 0

    // Key state
    var keyOn: Bool = false

    // AM
    var amon: Bool = false
    var ms: UInt32 = 0    // LFO sensitivity (from reg 0xB4)
    var amsIndex: Int = 0 // index into amtable

    var paramChanged: Bool = true

    enum EGPhase: Int {
        case attack = 1, decay, sustain, release, off
    }

    @inline(__always)
    static func logToLin(_ a: Int) -> Int {
        (a < FM.combinedLogEntries) ? Int(combinedLogTable[a]) : 0
    }

    @inline(__always)
    static func sine(_ s: Int) -> UInt32 {
        sineTable[s & (FM.sineEntries - 1)]
    }

    mutating func setEGRate(_ rate: Int, ratio: UInt32) {
        egRate = rate
        egCountDiff = decayCounterTable[rate / 4] * Int(ratio)
    }

    mutating func egUpdate() {
        if ssgType == 0 {
            egOut = min(tlOut + egLevel, FM.egMaxLevel) << 3
        } else {
            egOut = min(tlOut + egLevel * ssgVector + ssgOffset, FM.egMaxLevel) << 3
        }
    }

    mutating func egCalc(ratio: UInt32) {
        egCount = (2047 * 3) << FM.ratioBits

        if egPhase == .attack {
            let c = attackRateTable[egRate][egCurveCount & 7]
            if c >= 0 {
                egLevel -= 1 + (egLevel >> Int(c))
                if egLevel <= 0 {
                    shiftPhase(.decay, ratio: ratio)
                }
            }
            egUpdate()
        } else {
            if ssgType == 0 {
                egLevel += Int(decayRateTable[egRate][egCurveCount & 7])
                if egLevel >= egLevelOnNextPhase {
                    shiftPhase(EGPhase(rawValue: egPhase.rawValue + 1) ?? .off, ratio: ratio)
                }
                egUpdate()
            } else {
                egLevel += 4 * Int(decayRateTable[egRate][egCurveCount & 7])
                if egLevel >= egLevelOnNextPhase {
                    egUpdate()
                    switch egPhase {
                    case .decay:   shiftPhase(.sustain, ratio: ratio)
                    case .sustain: shiftPhase(.attack, ratio: ratio)
                    case .release: shiftPhase(.off, ratio: ratio)
                    default: break
                    }
                }
            }
        }
        egCurveCount += 1
    }

    @inline(__always)
    mutating func egStep(ratio: UInt32) {
        egCount -= egCountDiff
        if egCount <= 0 {
            egCalc(ratio: ratio)
        }
    }

    mutating func shiftPhase(_ nextPhase: EGPhase, ratio: UInt32) {
        switch nextPhase {
        case .attack:
            if tl != tlLatch {
                tl = tlLatch
                paramChanged = true
            }
            if ssgType != 0 {
                ssgPhase = ssgPhase + 1
                if ssgPhase > 2 { ssgPhase = 1 }
                let m = ar >= ((ssgType == FM.ssgTypeAlt1 || ssgType == FM.ssgTypeAlt2) ? UInt32(FM.ssgARThresholdAlt) : UInt32(FM.ssgARThresholdDefault)) ? 1 : 0
                let phase = max(0, min(ssgPhase, 2))
                let idx = (Int(ssgType & 7) * 12) + (m * 6) + (phase * 2)
                ssgOffset = Int(ssgEnvelopeTable[idx]) * FM.ssgEGStep
                ssgVector = Int(ssgEnvelopeTable[idx + 1])
            }
            if (ar + keyScaleRate) < 62 {
                setEGRate(ar != 0 ? min(63, Int(ar + keyScaleRate)) : 0, ratio: ratio)
                egPhase = .attack
                return
            }
            fallthrough
        case .decay:
            if sl != 0 {
                egLevel = 0
                egLevelOnNextPhase = ssgType != 0 ? min(Int(sl) * 8, FM.ssgEGLimit) : Int(sl) * 8
                setEGRate(dr != 0 ? min(63, Int(dr + keyScaleRate)) : 0, ratio: ratio)
                egPhase = .decay
                return
            }
            fallthrough
        case .sustain:
            egLevel = Int(sl) * 8
            egLevelOnNextPhase = ssgType != 0 ? FM.ssgEGLimit : FM.normalEGLimit
            setEGRate(sr != 0 ? min(63, Int(sr + keyScaleRate)) : 0, ratio: ratio)
            egPhase = .sustain
        case .release:
            if ssgType != 0 {
                egLevel = egLevel * ssgVector + ssgOffset
                ssgVector = 1
                ssgOffset = 0
            }
            if egPhase == .attack || egLevel < FM.egBottom {
                egLevelOnNextPhase = FM.normalEGLimit
                setEGRate(min(63, Int(rr + keyScaleRate)), ratio: ratio)
                egPhase = .release
                return
            }
            fallthrough
        case .off:
            egLevel = FM.egBottom
            egLevelOnNextPhase = FM.egBottom
            egUpdate()
            setEGRate(0, ratio: ratio)
            egPhase = .off
        }
    }

    mutating func setFNum(_ f: UInt32) {
        dp = (f & 2047) << ((f >> 11) & 7)
        bn = UInt32(noteTable[Int((f >> 7) & 127)])
        paramChanged = true
    }

    mutating func setTL(_ value: UInt32, csm: Bool) {
        if !csm {
            tl = value
            paramChanged = true
        }
        tlLatch = value
    }

    mutating func setSSGEC(_ value: UInt8) {
        if value & 0x08 != 0 {
            ssgType = UInt32(value & 0x0F)
            switch egPhase {
            case .attack:
                ssgPhase = 0
            case .decay:
                ssgPhase = 1
            default:
                ssgPhase = 2
            }
        } else {
            ssgType = 0
        }
        paramChanged = true
    }

    mutating func prepare(ratio: UInt32, multable: [[UInt32]]) {
        guard paramChanged else { return }
        paramChanged = false

        // PG
        let dtIdx = Int(detune + bn) & 255
        let dtVal = Int(detuneTable[dtIdx])
        pgDiff = UInt32(truncatingIfNeeded: (Int(dp) + dtVal) * Int(multable[Int(detune2)][Int(multiple)]))
        pgDiff >>= UInt32(2 + FM.ratioBits - FM.phaseBits)
        pgDiffLfo = pgDiff >> 11

        // EG
        keyScaleRate = bn >> (3 - ks)
        tlOut = Int(tl) * 8

        switch egPhase {
        case .attack:
            setEGRate(ar != 0 ? min(63, Int(ar + keyScaleRate)) : 0, ratio: ratio)
        case .decay:
            setEGRate(dr != 0 ? min(63, Int(dr + keyScaleRate)) : 0, ratio: ratio)
            egLevelOnNextPhase = Int(sl) * 8
        case .sustain:
            setEGRate(sr != 0 ? min(63, Int(sr + keyScaleRate)) : 0, ratio: ratio)
        case .release:
            setEGRate(min(63, Int(rr + keyScaleRate)), ratio: ratio)
        default:
            break
        }

        // SSG-EG
        if ssgType != 0 && egPhase != .release {
            let m = ar >= ((ssgType == FM.ssgTypeAlt1 || ssgType == FM.ssgTypeAlt2) ? UInt32(FM.ssgARThresholdAlt) : UInt32(FM.ssgARThresholdDefault)) ? 1 : 0
            if ssgPhase == -1 { ssgPhase = 0 }
            let phase = max(0, min(ssgPhase, 2))
            let idx = (Int(ssgType & 7) * 12) + (m * 6) + (phase * 2)
            ssgOffset = Int(ssgEnvelopeTable[idx]) * FM.ssgEGStep
            ssgVector = Int(ssgEnvelopeTable[idx + 1])
        }

        // LFO AM index
        amsIndex = amon ? Int((ms >> 4) & 3) : 0

        egUpdate()
    }

    @inline(__always)
    mutating func pgCalc() -> UInt32 {
        let ret = pgCount
        pgCount &+= pgDiff
        return ret
    }

    @inline(__always)
    mutating func pgCalcL(pmv: Int) -> UInt32 {
        let ret = pgCount
        pgCount &+= pgDiff &+ UInt32(truncatingIfNeeded: (Int(pgDiffLfo) * pmv) >> 5)
        return ret
    }

    // Standard operator calculation
    @discardableResult @inline(__always)
    mutating func calc(_ input: Int, ratio: UInt32) -> Int {
        egStep(ratio: ratio)
        out2 = out
        var pgin = Int(pgCalc() >> (20 + FM.phaseBits - FM.sineBits))
        pgin += input >> (20 + FM.phaseBits - FM.sineBits - (2 + FM.inputToEGShift))
        out = Self.logToLin(egOut + Int(Self.sine(pgin)))
        return out
    }

    // Operator with LFO
    @discardableResult @inline(__always)
    mutating func calcL(_ input: Int, pmv: Int, aml: Int, amtable: [UInt32], ratio: UInt32) -> Int {
        egStep(ratio: ratio)
        var pgin = Int(pgCalcL(pmv: pmv) >> (20 + FM.phaseBits - FM.sineBits))
        pgin += input >> (20 + FM.phaseBits - FM.sineBits - (2 + FM.inputToEGShift))
        let am = Int(amtable[amsIndex * FM.lfoEntries + aml])
        out = Self.logToLin(egOut + Int(Self.sine(pgin)) + am)
        return out
    }

    // Feedback operator
    @discardableResult @inline(__always)
    mutating func calcFB(_ fb: UInt8, ratio: UInt32) -> Int {
        egStep(ratio: ratio)
        let input = out + out2
        out2 = out
        var pgin = Int(pgCalc() >> (20 + FM.phaseBits - FM.sineBits))
        if fb < FM.noFeedback {
            pgin += ((input << (1 + FM.inputToEGShift)) >> Int(fb)) >> (20 + FM.phaseBits - FM.sineBits)
        }
        out = Self.logToLin(egOut + Int(Self.sine(pgin)))
        return out2
    }

    // Feedback operator with LFO
    @discardableResult @inline(__always)
    mutating func calcFBL(_ fb: UInt8, pmv: Int, aml: Int, amtable: [UInt32], ratio: UInt32) -> Int {
        egStep(ratio: ratio)
        let input = out + out2
        out2 = out
        var pgin = Int(pgCalcL(pmv: pmv) >> (20 + FM.phaseBits - FM.sineBits))
        if fb < FM.noFeedback {
            pgin += ((input << (1 + FM.inputToEGShift)) >> Int(fb)) >> (20 + FM.phaseBits - FM.sineBits)
        }
        let am = Int(amtable[amsIndex * FM.lfoEntries + aml])
        out = Self.logToLin(egOut + Int(Self.sine(pgin)) + am)
        return out
    }

    mutating func doKeyOn(ratio: UInt32) {
        guard !keyOn else { return }
        keyOn = true
        if egPhase == .off || egPhase == .release {
            ssgPhase = -1
            shiftPhase(.attack, ratio: ratio)
            egUpdate()
            out = 0; out2 = 0
            pgCount = 0
        }
    }

    mutating func doKeyOff(ratio: UInt32) {
        guard keyOn else { return }
        keyOn = false
        shiftPhase(.release, ratio: ratio)
    }

    mutating func reset() {
        pgCount = 0; pgDiff = 0; pgDiffLfo = 0
        dp = 0; bn = 0; detune = 0; detune2 = 0; multiple = 0
        egLevel = FM.egBottom; egLevelOnNextPhase = FM.egBottom
        egCount = 0; egCountDiff = 0; egOut = 0; tlOut = 0
        egRate = 0; egCurveCount = 0; egPhase = .off
        ssgOffset = 0; ssgVector = 1; ssgPhase = 0; ssgType = 0
        keyScaleRate = 0; tl = 127; tlLatch = 127; ks = 0
        ar = 0; dr = 0; sr = 0; sl = 0; rr = 0
        out = 0; out2 = 0; keyOn = false
        amon = false; ms = 0; amsIndex = 0; paramChanged = true
    }
}

// MARK: - FM Channel (4 operators)

struct FMCh {
    var op = [FMOp](repeating: FMOp(), count: 4)
    var fb: UInt8 = FM.noFeedback
    var algo: Int = 0
    var panLeft: Bool = true
    var panRight: Bool = true
    var pmsIndex: Int = 0  // PMS register value (0-7)

    mutating func setAlgorithm(_ a: Int) {
        algo = a & 7
        op[0].out = 0; op[0].out2 = 0
    }

    mutating func setFNum(_ f: UInt32) {
        for i in 0..<4 { op[i].setFNum(f) }
    }

    mutating func prepare(ratio: UInt32, multable: [[UInt32]]) -> Int {
        for i in 0..<4 { op[i].prepare(ratio: ratio, multable: multable) }
        // fmgen IsOn(): eg_phase_ != off — includes release phase for proper tail
        let key = op.contains(where: { $0.egPhase != .off }) ? 1 : 0
        let hasAM = op.contains(where: { $0.amon })
        let lfo = (op[0].ms & (hasAM ? 0x37 : 7)) != 0 ? 2 : 0
        return key | lfo
    }

    // Generate one sample (no LFO)
    mutating func calc(ratio: UInt32) -> Int {
        var r = 0
        switch algo {
        case 0:
            op[2].calc(op[1].out, ratio: ratio); op[1].calc(op[0].out, ratio: ratio)
            r = op[3].calc(op[2].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 1:
            op[2].calc(op[0].out + op[1].out, ratio: ratio); op[1].calc(0, ratio: ratio)
            r = op[3].calc(op[2].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 2:
            op[2].calc(op[1].out, ratio: ratio); op[1].calc(0, ratio: ratio)
            r = op[3].calc(op[0].out + op[2].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 3:
            op[2].calc(0, ratio: ratio); op[1].calc(op[0].out, ratio: ratio)
            r = op[3].calc(op[1].out + op[2].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 4:
            op[2].calc(0, ratio: ratio)
            r = op[1].calc(op[0].out, ratio: ratio)
            r &+= op[3].calc(op[2].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 5:
            r = op[2].calc(op[0].out, ratio: ratio)
            r &+= op[1].calc(op[0].out, ratio: ratio)
            r &+= op[3].calc(op[0].out, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 6:
            r = op[2].calc(0, ratio: ratio)
            r &+= op[1].calc(op[0].out, ratio: ratio)
            r &+= op[3].calc(0, ratio: ratio); op[0].calcFB(fb, ratio: ratio)
        case 7:
            r = op[2].calc(0, ratio: ratio)
            r &+= op[1].calc(0, ratio: ratio)
            r &+= op[3].calc(0, ratio: ratio)
            r &+= op[0].calcFB(fb, ratio: ratio)
        default: break
        }
        return r
    }

    // Generate one sample (with LFO)
    mutating func calcL(pmv: Int, aml: Int, amtable: [UInt32], ratio: UInt32) -> Int {
        var r = 0
        switch algo {
        case 0:
            op[2].calcL(op[1].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[1].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r = op[3].calcL(op[2].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 1:
            op[2].calcL(op[0].out + op[1].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[1].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r = op[3].calcL(op[2].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 2:
            op[2].calcL(op[1].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[1].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r = op[3].calcL(op[0].out + op[2].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 3:
            op[2].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[1].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r = op[3].calcL(op[1].out + op[2].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 4:
            op[2].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r = op[1].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[3].calcL(op[2].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 5:
            r = op[2].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[1].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[3].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 6:
            r = op[2].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[1].calcL(op[0].out, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[3].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        case 7:
            r = op[2].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[1].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[3].calcL(0, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
            r &+= op[0].calcFBL(fb, pmv: pmv, aml: aml, amtable: amtable, ratio: ratio)
        default: break
        }
        return r
    }

    mutating func reset() {
        for i in 0..<4 { op[i].reset() }
        fb = FM.noFeedback; algo = 0; panLeft = true; panRight = true; pmsIndex = 0
    }
}

// MARK: - Rhythm Channel

struct RhythmChannel {
    var sample: [Int16]?   // PCM data
    var size: Int = 0       // sample count * 1024
    var pos: Int = 0        // current position (fixed-point × 1024)
    var step: Int = 0       // playback rate (fixed-point × 1024)
    var pan: UInt8 = 0      // bit1=L, bit0=R (fmgen reset: pan=0, no output)
    var level: Int8 = 31    // individual level (fmgen reset: ~0 & 31 = max attenuation)
    var volumeL: Int = 0
    var volumeR: Int = 0

    mutating func reset() {
        pos = size   // stopped
        pan = 0; level = 31; volumeL = 0; volumeR = 0
    }
}

// MARK: - TL Table for rhythm (dB → linear)

let totalLevelTable: [Int32] = {
    var table = [Int32](repeating: 0, count: FM.tlEntries + FM.tlOffset)
    for i in (-FM.tlOffset)..<FM.tlEntries {
        table[i + FM.tlOffset] = Int32(FM.fixedPointScale * pow(2.0, Double(i) * -16.0 / Double(FM.tlEntries))) - 1
    }
    return table
}()

// MARK: - PM/AM Tables

private let pmDepthTable: [Int] = {
    // OPNA type only (index 0)
    let pms: [Double] = [0, 1.0/360, 2.0/360, 3.0/360, 4.0/360, 6.0/360, 12.0/360, 24.0/360]
    var table = [Int](repeating: 0, count: 8 * FM.lfoEntries)
    for i in 0..<8 {
        let pmb = pms[i]
        for j in 0..<FM.lfoEntries {
            let w = 0.6 * pmb * sin(2.0 * Double.pi * Double(j) / Double(FM.lfoEntries)) + 1.0
            table[i * FM.lfoEntries + j] = Int(FM.fixedPointScale * (w - 1.0))
        }
    }
    return table
}()

private let amDepthTable: [UInt32] = {
    let amt: [UInt32] = [31, 6, 4, 3]  // OPNA
    var table = [UInt32](repeating: 0, count: 4 * FM.lfoEntries)
    for i in 0..<4 {
        for j in 0..<FM.lfoEntries {
            table[i * FM.lfoEntries + j] = (((UInt32(j) * 4) >> amt[i]) * 2) << 2
        }
    }
    return table
}()

/// PM waveform table (triangular) — maps LFO phase to pmtable index
let pmWaveformTable: [Int] = {
    var table = [Int](repeating: 0, count: 256)
    for c in 0..<256 {
        if c < 0x40 {
            table[c] = c * 2 + 0x80
        } else if c < 0xC0 {
            table[c] = 0x7F - (c - 0x40) * 2 + 0x80
        } else {
            table[c] = (c - 0xC0) * 2
        }
    }
    return table
}()

/// AM waveform table (sawtooth)
let amWaveformTable: [Int] = {
    var table = [Int](repeating: 0, count: 256)
    for c in 0..<256 {
        if c < 0x80 {
            table[c] = (0xFF - c * 2) & ~3
        } else {
            table[c] = ((c - 0x80) * 2) & ~3
        }
    }
    return table
}()

// MARK: - FMSynthesizer

public final class FMSynthesizer {
    var ch = [FMCh](repeating: FMCh(), count: 6)

    // Chip state
    var ratio: UInt32 = 0
    var multable: [[UInt32]] = Array(repeating: Array(repeating: 0, count: 16), count: 4)

    // LFO
    var lfoCount: UInt32 = 0
    var lfoDCount: UInt32 = 0
    var lfoEnabled: Bool = false

    // Rhythm
    var rhythm: [RhythmChannel] = Array(repeating: RhythmChannel(), count: 6)
    var rhythmTL: Int8 = 63
    var rhythmVolL: Int = 0
    var rhythmVolR: Int = 0
    var rhythmKey: UInt8 = 0
    var extendedChannelsEnabled: Bool = false

    // Debug per-channel mute masks (1 = unmuted, 0 = muted).
    // Set by YM2608 when debugChannelMask changes; never touched in the sample loop itself.
    var channelMask: UInt8 = 0x3F   // FM: bits 0-5
    var rhythmMask:  UInt8 = 0x3F   // Rhythm: bits 0-5

    // Output rate
    var chipClock: Int
    var outputRate: Int = 44100

    public init(clock: Int = 3_993_624) {
        chipClock = clock
        setRatio(clock: clock, rate: outputRate)
    }

    func setRatio(clock: Int, rate: Int) {
        chipClock = clock
        let fmclock = clock / 72  // prescaler 0: /6/12 = /72
        let r = ((fmclock << FM.ratioBits) + rate / 2) / rate
        ratio = UInt32(r)
        makeMultable()
    }

    private func makeMultable() {
        for h in 0..<4 {
            let rr = dt2Multiplier[h] * Float(ratio)
            for l in 0..<16 {
                let mul = l != 0 ? l * 2 : 1
                multable[h][l] = UInt32(Float(mul) * rr)
            }
        }
    }

    func setLFOFreq(_ freq: UInt8) {
        if freq & 0x08 != 0 {
            lfoEnabled = true
            let f = Int(freq & 7)
            let fmclock = chipClock / 72
            let r = ((fmclock << FM.ratioBits) + outputRate / 2) / outputRate
            lfoDCount = UInt32((r << (2 + FM.lfoCounterBits - FM.ratioBits)) / Int(lfoDivisorTable[f]))
        } else {
            lfoEnabled = false
            lfoDCount = 0
        }
    }

    @inline(__always)
    func lfo() -> (pml: Int, aml: Int) {
        let idx = Int((lfoCount >> (FM.lfoCounterBits + 1)) & 0xFF)
        return (pmWaveformTable[idx], amWaveformTable[idx])
    }

    /// Generate one FM sample from all 6 channels. Returns (left, right) in raw amplitude.
    public func generateSample() -> (Int, Int) {
        let lfoState: (pml: Int, aml: Int)?
        if lfoEnabled {
            lfoState = lfo()
            lfoCount &+= lfoDCount
        } else {
            lfoState = nil
        }

        var outL = 0
        var outR = 0

        @inline(__always)
        func processCh(_ ch: inout FMCh) {
            let flags = ch.prepare(ratio: ratio, multable: multable)
            guard flags & 1 != 0 else { return }  // no key on

            let sample: Int
            if let (pmlVal, amlVal) = lfoState, flags & 2 != 0 {
                let pmvVal = pmDepthTable[ch.pmsIndex * FM.lfoEntries + pmlVal]
                sample = ch.calcL(pmv: pmvVal, aml: amlVal, amtable: amDepthTable, ratio: ratio)
            } else {
                sample = ch.calc(ratio: ratio)
            }

            if ch.panLeft { outL &+= sample }
            if ch.panRight { outR &+= sample }
        }

        for i in 0..<3 {
            guard (channelMask >> i) & 1 != 0 else { continue }
            processCh(&ch[i])
        }
        if extendedChannelsEnabled {
            for i in 3..<6 {
                guard (channelMask >> i) & 1 != 0 else { continue }
                processCh(&ch[i])
            }
        }

        return (outL, outR)
    }

    /// Mix rhythm samples into buffer. Returns (left, right) contribution.
    public func generateRhythm() -> (Int, Int) {
        guard rhythmKey & 0x3F != 0 else { return (0, 0) }
        var outL = 0
        var outR = 0
        for i in 0..<6 {
            guard rhythmKey & (1 << i) != 0 else { continue }
            guard let samples = rhythm[i].sample, rhythm[i].pos < rhythm[i].size else {
                rhythmKey &= ~UInt8(1 << i)
                continue
            }
            guard (rhythmMask >> i) & 1 != 0 else {
                // Muted: still advance position so the key clears normally.
                rhythm[i].pos += rhythm[i].step
                if rhythm[i].pos >= rhythm[i].size { rhythmKey &= ~UInt8(1 << i) }
                continue
            }
            let dbL = min(max(Int(rhythmTL) + rhythmVolL + Int(rhythm[i].level) + rhythm[i].volumeL, -31), 127)
            let dbR = min(max(Int(rhythmTL) + rhythmVolR + Int(rhythm[i].level) + rhythm[i].volumeR, -31), 127)
            let volL = Int(totalLevelTable[FM.tlOffset + (dbL << (FM.tlBits - 7))]) >> 4
            let volR = Int(totalLevelTable[FM.tlOffset + (dbR << (FM.tlBits - 7))]) >> 4

            let maskL = (rhythm[i].pan & 2) != 0 ? ~0 : 0
            let maskR = (rhythm[i].pan & 1) != 0 ? ~0 : 0

            let idx = rhythm[i].pos / FM.rhythmFixedPointScale
            if idx < samples.count {
                let s = Int(samples[idx])
                outL &+= ((s * volL) >> 12) & maskL
                outR &+= ((s * volR) >> 12) & maskR
            }
            rhythm[i].pos += rhythm[i].step
            if rhythm[i].pos >= rhythm[i].size {
                rhythmKey &= ~UInt8(1 << i)
            }
        }
        return (outL, outR)
    }

    /// Load rhythm WAV sample (signed 16-bit PCM, mono).
    public func loadRhythmSample(index: Int, data: [Int16], sampleRate: Int) {
        guard index >= 0 && index < 6 else { return }
        rhythm[index].sample = data
        rhythm[index].step = sampleRate * FM.rhythmFixedPointScale / outputRate
        rhythm[index].size = data.count * FM.rhythmFixedPointScale
        rhythm[index].pos = rhythm[index].size  // stopped initially
    }

    public func reset() {
        for i in 0..<6 { ch[i].reset() }
        lfoCount = 0; lfoDCount = 0; lfoEnabled = false
        extendedChannelsEnabled = false
        rhythmKey = 0; rhythmTL = 63; rhythmVolL = 0; rhythmVolR = 0
        for i in 0..<6 { rhythm[i].reset() }
    }

}

// MARK: - ChorusEffect (pseudo-stereo for mono FM)

/// Haas-effect pseudo-stereo widener for mono output.
/// One channel is dry, the other is delayed.
public struct ChorusEffect: Sendable {
    private static let bufferSize = 256
    private static let bufferMask = bufferSize - 1

    private var buffer: [Int]
    private var writePos: Int = 0
    private let delay: Int
    private let delayLeft: Bool   // true: L=delayed/R=dry, false: L=dry/R=delayed

    /// Initialize with FM sample rate.
    /// - Parameters:
    ///   - fmRate: sample rate (default ~55467 Hz)
    ///   - delayLeft: if true, L is delayed and R is dry
    public init(fmRate: Int = 55467, delayLeft: Bool = false) {
        buffer = [Int](repeating: 0, count: Self.bufferSize)
        delay = fmRate * 4 / 1000   // ~4ms
        self.delayLeft = delayLeft
    }

    public mutating func process(monoSample: Int) -> (left: Int, right: Int) {
        buffer[writePos] = monoSample
        writePos = (writePos + 1) & Self.bufferMask

        let delayed = buffer[(writePos - delay) & Self.bufferMask]

        if delayLeft {
            return (left: delayed, right: monoSample)
        } else {
            return (left: monoSample, right: delayed)
        }
    }

    public mutating func reset() {
        for i in 0..<Self.bufferSize {
            buffer[i] = 0
        }
        writePos = 0
    }
}
