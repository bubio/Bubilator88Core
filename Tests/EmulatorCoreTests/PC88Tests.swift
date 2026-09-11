import Testing
import Foundation
@_spi(Debug) @testable import EmulatorCore

/// `PC88` only delegates to `Machine` for now; these check each delegation
/// lands on the component it is meant to.
@Suite("PC88 Tests")
struct PC88Tests {

  @Test func dipSwitchesPassThroughToTheBus() {
    let pc88 = PC88()
    pc88.dipSw1 = 0xC2
    pc88.dipSw2 = 0xB9
    #expect(pc88.machine.bus.dipSw1 == 0xC2)
    #expect(pc88.machine.bus.dipSw2 == 0xB9)
  }

  @Test func bootModeIsDerivedIgnoringTheBootStrap() {
    let pc88 = PC88()
    for mode in BootMode.allCases {
      pc88.dipSw1 = mode.dipSw1
      pc88.dipSw2 = mode.dipSw2
      #expect(pc88.bootMode == mode)
      pc88.dipSw2 = mode.dipSw2 | Machine.bootStrapBit
      #expect(pc88.bootMode == mode)
    }
    pc88.dipSw1 = 0xC3
    pc88.dipSw2 = 0x00  // no standard mode has V2 + standard speed with these low bits
    #expect(pc88.bootMode == nil)
  }

  @Test func setBootModeKeepsTheBootStrap() {
    let pc88 = PC88()
    pc88.dipSw2 = 0x79  // n88-v2, ROM boot
    pc88.setBootMode(.n88v1h)
    #expect(pc88.dipSw1 == BootMode.n88v1h.dipSw1)
    #expect(pc88.dipSw2 == BootMode.n88v1h.dipSw2 | Machine.bootStrapBit)

    pc88.dipSw2 = 0x71  // disk boot
    pc88.setBootMode(.n88v1s)
    #expect(pc88.dipSw2 == BootMode.n88v1s.dipSw2 & ~Machine.bootStrapBit)
  }

  @Test func applyBootStrapFollowsDriveZero() {
    let pc88 = PC88()
    pc88.applyBootStrap(base: 0x71)
    #expect(pc88.dipSw2 & Machine.bootStrapBit != 0)  // empty drive 0 → ROM boot

    pc88.mountDisk(drive: 0, disk: D88Disk())
    pc88.applyBootStrap()
    #expect(pc88.dipSw2 & Machine.bootStrapBit == 0)  // disk in drive 0 → disk boot
  }

  @Test func machineSettingsPassThrough() {
    let pc88 = PC88()
    pc88.clock8MHz = false
    pc88.monitorType = .khz15
    pc88.memoryWaitDip = true
    pc88.cpuOverclock = 4
    #expect(pc88.machine.clock8MHz == false)
    #expect(pc88.machine.monitorType == .khz15)
    #expect(pc88.machine.memoryWaitDip == true)
    #expect(pc88.machine.cpuOverclock == 4)
    #expect(pc88.frameRate == pc88.machine.frameRate)
  }

  @Test func romsLandWhereMachinePutsThem() {
    let pc88 = PC88()
    pc88.loadROM(.n88Basic, data: [0x11])
    pc88.loadROM(.nBasic, data: [0x22])
    pc88.loadROM(.n88Ext(bank: 2), data: [0x33])
    pc88.loadROM(.disk, data: [0x44])
    pc88.loadROM(.kanji1, data: [0x55])
    pc88.loadROM(.kanji2, data: [0x66])
    let bus = pc88.machine.bus
    #expect(bus.n88BasicROM == [0x11])
    #expect(bus.nBasicROM == [0x22])
    #expect(bus.n88ExtROM?[2].first == 0x33)
    #expect(pc88.machine.subSystem.subBus.romram[0] == 0x44)
    #expect(!pc88.machine.subSystem.useLegacyMode)
    #expect(bus.kanjiROM1 == [0x55])
    #expect(bus.kanjiROM2 == [0x66])
  }

  @Test func disksPassThrough() {
    let pc88 = PC88()
    var disk = D88Disk()
    disk.name = "TEST"
    pc88.mountDisk(drive: 1, disk: disk)
    #expect(pc88.machine.subSystem.drives[1]?.name == "TEST")
    pc88.setWriteProtect(drive: 1, protected: true)
    #expect(pc88.isWriteProtected(drive: 1))
    pc88.ejectDisk(drive: 1)
    #expect(pc88.machine.subSystem.drives[1] == nil)
  }

  @Test func keysReachTheMatrix() {
    let pc88 = PC88()
    pc88.pressKey(Keyboard.a)
    #expect(pc88.machine.keyboard.matrix[Keyboard.a.row] & (1 << Keyboard.a.bit) == 0)
    pc88.releaseKey(Keyboard.a)
    #expect(pc88.machine.keyboard.matrix[Keyboard.a.row] == 0xFF)
    pc88.pressKey(Keyboard.a)
    pc88.pressKey(Keyboard.kp0)
    pc88.releaseAllKeys()
    #expect(pc88.machine.keyboard.matrix.allSatisfy { $0 == 0xFF })
  }

  @Test func mouseSettingsPassThrough() {
    let pc88 = PC88()
    pc88.mouseEnabled = true
    pc88.mouseJoystickMode = true
    #expect(pc88.machine.mouse.enabled)
    #expect(pc88.machine.mouse.joyMode)
  }

  @Test func soundSettingsPassThrough() {
    let pc88 = PC88()
    pc88.pseudoStereoEnabled = true
    pc88.cdMixEnabled = true
    pc88.immersiveOutputEnabled = true
    pc88.forceOPNMode = true
    let sound = pc88.machine.sound
    #expect(sound.pseudoStereoEnabled)
    #expect(sound.cdMixEnabled)
    #expect(sound.immersiveOutputEnabled)
    #expect(sound.forceOPNMode)
  }

  @Test func tapeStateReflectsTheDeck() {
    let pc88 = PC88()
    #expect(!pc88.isTapeLoaded)
    #expect(pc88.tapeProgress == 0)
    pc88.mountTape(data: Data([0xD3, 0xD3, 0xD3]))
    #expect(pc88.isTapeLoaded == pc88.machine.cassette.isLoaded)
    pc88.ejectTape()
    #expect(!pc88.isTapeLoaded)
  }

  @Test func saveStateRoundTrips() throws {
    let pc88 = PC88()
    pc88.reset()
    pc88.machine.bus.mainRAM[0x9000] = 0x5A
    let state = pc88.createSaveState()

    let restored = PC88()
    try restored.loadSaveState(state)
    #expect(restored.machine.bus.mainRAM[0x9000] == 0x5A)
  }

  @Test func renderFillsTheWholeFrame() {
    let pc88 = PC88()
    pc88.reset()
    var frame = [UInt8](repeating: 0x5A, count: ScreenRenderer.bufferSize400)
    pc88.render(into: &frame, blinkCursor: false)
    // Every pixel written: all alpha bytes opaque.
    #expect(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 0xFF })

    var withTextLayer = [UInt8](repeating: 0, count: ScreenRenderer.bufferSize400)
    pc88.render(into: &withTextLayer, blinkCursor: false, textLayerEnabled: true)
    #expect(withTextLayer == frame)
  }

  @Test func fddEventsReachTheHostAndKeepTheActivityLamp() {
    let pc88 = PC88()
    var events: [(Int, PC88.FDDEvent)] = []
    pc88.onFDDEvent = { drive, event in events.append((drive, event)) }

    let fdc = pc88.machine.subSystem.fdc
    fdc.onSeekStep?(1, 5)
    fdc.onSeekStep?(1, 6)
    fdc.onDiskAccess?(0)
    #expect(events.map(\.0) == [1, 1, 0])
    #expect(events.map(\.1) == [.seekStep, .seekStep, .access])

    // SubSystem's own hooks still ran underneath.
    #expect(pc88.takeDiskActivity() == [true, true])
    #expect(pc88.takeDiskActivity() == [false, false])
  }

  @Test func dirtyDiskImageIsTakenOnce() throws {
    let pc88 = PC88()
    var disk = D88Disk()
    disk.name = "SAVE"
    disk.tracks[0] = [D88Disk.Sector()]
    pc88.mountDisk(drive: 1, disk: disk)
    #expect(pc88.mountedDisk(drive: 1)?.name == "SAVE")
    #expect(pc88.mountedDisk(drive: 5) == nil)
    #expect(pc88.takeDirtyDiskImage(drive: 1) == nil)  // clean

    pc88.markDiskDirty(drive: 1)
    let image = try #require(pc88.takeDirtyDiskImage(drive: 1))
    #expect(image == disk.serialize())
    #expect(pc88.mountedDisk(drive: 1)?.dirty == false)
    #expect(pc88.takeDirtyDiskImage(drive: 1) == nil)  // already taken
  }

  @Test func onDiskWrittenIsTheSubSystemHook() {
    let pc88 = PC88()
    var written: [Int] = []
    pc88.onDiskWritten = { written.append($0) }
    pc88.machine.subSystem.onDiskWritten?(1)
    #expect(written == [1])
  }

  @Test func takeAudioSamplesDrainsEveryBuffer() {
    let pc88 = PC88()
    let sound = pc88.machine.sound
    sound.audioBuffer = [0.1, 0.2]
    sound.fmSpatialBuffer = [0.3, 0.4]
    sound.rhythmSpatialBuffer = [0.5, 0.6]
    let samples = pc88.takeAudioSamples()
    #expect(samples.stereo == [0.1, 0.2])
    #expect(samples.fm == [0.3, 0.4])
    #expect(samples.ssg.isEmpty)
    #expect(samples.rhythm == [0.5, 0.6])
    #expect(sound.audioBuffer.isEmpty)
    #expect(sound.fmSpatialBuffer.isEmpty)
    #expect(sound.rhythmSpatialBuffer.isEmpty)
  }

  @Test func adjustAudioRateTracksTheHostQueue() {
    let pc88 = PC88()
    let base = YM2608.baseCpuClockHz8MHz
    pc88.adjustAudioRate(bufferedFrames: 500, capacityFrames: 1000)
    #expect(pc88.machine.sound.cpuClockHz == base)          // half full: no change
    pc88.adjustAudioRate(bufferedFrames: 510, capacityFrames: 1000)
    #expect(pc88.machine.sound.cpuClockHz == base + 160)    // over: run faster
    pc88.adjustAudioRate(bufferedFrames: 0, capacityFrames: 1_000_000)
    #expect(pc88.machine.sound.cpuClockHz == base - base / 200)  // capped
  }

  @Test func glyphComesFromTheFontROM() {
    let pc88 = PC88()
    var font = [UInt8](repeating: 0, count: 2048)
    font[0x41 * 8] = 0x18
    pc88.loadROM(.font, data: font)
    #expect(pc88.glyph(for: 0x41).first == 0x18)
  }
}
