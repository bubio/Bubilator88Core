import Testing
@testable import FMSynthesis

@Suite("YM2608 Immersive Audio Tests")
struct YM2608SpatialTests {

    @Test func immersiveOutputDisabledByDefault() {
        let ym = YM2608()
        ym.reset()
        #expect(ym.immersiveOutputEnabled == false)
    }

    @Test func spatialBuffersEmptyWhenDisabled() {
        let ym = YM2608()
        ym.reset()
        // Generate some audio samples
        ym.tick(tStates: 1000)
        #expect(!ym.audioBuffer.isEmpty)
        #expect(ym.fmSpatialBuffer.isEmpty)
        #expect(ym.ssgSpatialBuffer.isEmpty)
        #expect(ym.adpcmSpatialBuffer.isEmpty)
        #expect(ym.rhythmSpatialBuffer.isEmpty)
    }

    @Test func spatialBuffersPopulatedWhenEnabled() {
        let ym = YM2608()
        ym.reset()
        ym.immersiveOutputEnabled = true
        // Generate enough T-states for at least one audio sample
        ym.tick(tStates: 1000)
        #expect(!ym.fmSpatialBuffer.isEmpty)
        #expect(!ym.ssgSpatialBuffer.isEmpty)
        #expect(!ym.adpcmSpatialBuffer.isEmpty)
        #expect(!ym.rhythmSpatialBuffer.isEmpty)
    }

    @Test func spatialBuffersSameLength() {
        let ym = YM2608()
        ym.reset()
        ym.immersiveOutputEnabled = true
        ym.tick(tStates: 5000)
        let count = ym.fmSpatialBuffer.count
        #expect(count > 0)
        #expect(ym.ssgSpatialBuffer.count == count)
        #expect(ym.adpcmSpatialBuffer.count == count)
        #expect(ym.rhythmSpatialBuffer.count == count)
        // Stereo spatial buffers have the same length as stereo audioBuffer
        #expect(ym.audioBuffer.count == count)
    }

    @Test func resetClearsSpatialBuffers() {
        let ym = YM2608()
        ym.reset()
        ym.immersiveOutputEnabled = true
        ym.tick(tStates: 1000)
        #expect(!ym.fmSpatialBuffer.isEmpty)
        ym.reset()
        #expect(ym.fmSpatialBuffer.isEmpty)
        #expect(ym.ssgSpatialBuffer.isEmpty)
        #expect(ym.adpcmSpatialBuffer.isEmpty)
        #expect(ym.rhythmSpatialBuffer.isEmpty)
    }

    @Test func debugMaskRespectedInSpatialBuffers() {
        let ym = YM2608()
        ym.reset()
        ym.immersiveOutputEnabled = true
        // Mute everything except FM
        ym.debugOutputMask = .fm
        ym.tick(tStates: 1000)
        // SSG, ADPCM, Rhythm should be all zeros
        #expect(ym.ssgSpatialBuffer.allSatisfy { $0 == 0 })
        #expect(ym.adpcmSpatialBuffer.allSatisfy { $0 == 0 })
        #expect(ym.rhythmSpatialBuffer.allSatisfy { $0 == 0 })
    }
}
