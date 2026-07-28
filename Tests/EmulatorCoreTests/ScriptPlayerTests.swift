import Testing
import Foundation
@testable import EmulatorCore

@Suite("Script Player Tests")
struct ScriptPlayerTests {

  // MARK: - Helpers

  /// Builds a minimal header-only D88 with `names.count` images concatenated.
  private func makeD88(names: [String]) -> [UInt8] {
    var out: [UInt8] = []
    for name in names {
      var block = [UInt8](repeating: 0, count: 688)
      for (i, b) in Array(name.utf8).prefix(16).enumerated() { block[i] = b }
      block[0x1A] = 0x00          // write protect off
      block[0x1B] = 0x00          // 2D
      // disk size = 688 (LE) — non-zero so parseAll can walk multiple images
      block[0x1C] = 0xB0; block[0x1D] = 0x02; block[0x1E] = 0x00; block[0x1F] = 0x00
      out.append(contentsOf: block)
    }
    return out
  }

  private func makePlayer(_ files: [String: [UInt8]] = [:]) -> (ScriptPlayer, Machine) {
    let m = Machine()
    let player = ScriptPlayer(machine: m) { path in
      guard let data = files[path] else {
        throw ScriptPlayer.RuntimeError("not found: \(path)")
      }
      return data
    }
    return (player, m)
  }

  private func pressed(_ m: Machine, _ key: Keyboard.Key) -> Bool {
    (m.keyboard.matrix[key.row] & UInt8(1 << key.bit)) == 0
  }

  // MARK: - Setup directives

  @Test func bootSetsDipSw() throws {
    let (p, m) = makePlayer()
    try p.run([.boot(.n88v1h)])
    #expect(m.bus.dipSw1 == 0xC3)
    #expect(m.bus.dipSw2 == 0xF1)
  }

  @Test func clockSetsRate() throws {
    let (p, m) = makePlayer()
    try p.run([.clock(mhz: 4)])
    #expect(m.clock8MHz == false)
    try p.run([.clock(mhz: 8)])
    #expect(m.clock8MHz == true)
  }

  @Test func dipswRawOverrides() throws {
    let (p, m) = makePlayer()
    try p.run([.dipsw1(0xAA), .dipsw2(0x55)])
    #expect(m.bus.dipSw1 == 0xAA)
    #expect(m.bus.dipSw2 == 0x55)
  }

  // MARK: - Automatic ROM/disk boot (DIPSW2 bit 3)

  @Test func resolvedBootStrapPureFunction() {
    // Disk present clears bit 3, absent sets it. Other bits are preserved.
    #expect(Machine.resolvedBootStrap(base: 0x79, hasDiskInDrive0: true) == 0x71)
    #expect(Machine.resolvedBootStrap(base: 0x71, hasDiskInDrive0: false) == 0x79)
    // Idempotent when already on the correct side.
    #expect(Machine.resolvedBootStrap(base: 0x71, hasDiskInDrive0: true) == 0x71)
    #expect(Machine.resolvedBootStrap(base: 0x79, hasDiskInDrive0: false) == 0x79)
  }

  @Test func applyBootStrapUsesCurrentDipSw2WhenBaseOmitted() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (_, m) = makePlayer(["A.d88": d88])
    m.bus.dipSw2 = 0xF9            // V1H + bit3=1
    m.applyBootStrap()  // no disk: bit 3 stays set, other bits preserved
    #expect(m.bus.dipSw2 == 0xF9)
  }

  @Test func autoDiskBootClearsBit3WhenDiskPresent() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])
    try p.run([.boot(.n88v2), .diskMount(drive: 0, path: "A.d88", image: 0), .wait(frames: 1)])
    // Disk in drive 0: disk boot (bit 3 = 0)
    #expect((m.bus.dipSw2 & 0x08) == 0)
  }

  @Test func autoRomBootSetsBit3WhenNoDisk() throws {
    let (p, m) = makePlayer()
    try p.run([.boot(.n88v2), .wait(frames: 1)])
    // No disk: ROM boot (bit 3 = 1)
    #expect((m.bus.dipSw2 & 0x08) == 0x08)
  }

  @Test func rawDipsw2DisablesAutoResolve() throws {
    let (p, m) = makePlayer()
    // A raw dipsw2 with bit 3 = 0 is honoured: not re-set even without a disk
    try p.run([.dipsw2(0x71), .wait(frames: 1)])
    #expect((m.bus.dipSw2 & 0x08) == 0)
  }

  // MARK: - Keyboard input

  @Test func keyDownPersistsAcrossWaits() throws {
    let (p, m) = makePlayer()
    let a = Keyboard.Key(2, 1)
    try p.run([.key(a, .down), .wait(frames: 10)])
    // `down` is never auto-released, so it stays held after the run ends
    #expect(pressed(m, a))
  }

  @Test func keyUpReleases() throws {
    let (p, m) = makePlayer()
    let a = Keyboard.Key(2, 1)
    try p.run([.key(a, .down), .key(a, .up), .wait(frames: 5)])
    #expect(!pressed(m, a))
  }

  @Test func tapHoldTiming() {
    let (p, m) = makePlayer()
    let ret = Keyboard.Key(1, 7)
    p.applyKey(ret, .tap(hold: 3))
    #expect(pressed(m, ret))     // just pressed
    p.advance(2)
    #expect(pressed(m, ret))     // 2 frames in (< 3): still held
    p.advance(1)
    #expect(!pressed(m, ret))    // auto-released on the 3rd frame
  }

  @Test func tapHoldZeroClampedToOneFrame() {
    // §6: always held for at least one frame; hold 0 rounds up to 1.
    let (p, m) = makePlayer()
    let ret = Keyboard.Key(1, 7)
    p.applyKey(ret, .tap(hold: 0))
    #expect(pressed(m, ret))     // still held right after the press, not released immediately
    p.advance(1)
    #expect(!pressed(m, ret))    // released one frame later
  }

  @Test func tapReleasedByFinish() throws {
    let (p, m) = makePlayer()
    let sp = Keyboard.Key(9, 6)
    // hold is 100 but there is only wait 1, so finish releases it when run ends
    try p.run([.key(sp, .tap(hold: 100)), .wait(frames: 1)])
    #expect(!pressed(m, sp))
  }

  @Test func explicitDownAfterTapStaysHeld() throws {
    let (p, m) = makePlayer()
    let a = Keyboard.Key(2, 1)
    try p.run([.key(a, .tap(hold: 2)), .key(a, .down), .wait(frames: 10)])
    // `down` cancels the pending tap release, so finish leaves it held
    #expect(pressed(m, a))
  }

  // MARK: - Disks

  @Test func mountSelectsCorrectImage() throws {
    // Selects the right image of a multi-image D88 by index. An empty drive
    // mounts immediately.
    let d88 = makeD88(names: ["IMG0", "IMG1"])
    let (p, m) = makePlayer(["Ys.d88": d88])
    try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 1)])
    #expect(m.subSystem.drives[0]?.name == "IMG1")
  }

  @Test func selectTriggersRemount() throws {
    // Switching image on an occupied drive counts as a swap, so the door opens
    // and drives goes briefly nil. Committing it is non-legacy behaviour that
    // needs DISK.ROM, so this only checks that the remount started.
    let d88 = makeD88(names: ["IMG0", "IMG1"])
    let (p, m) = makePlayer(["Ys.d88": d88])
    try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 0)])
    #expect(m.subSystem.drives[0]?.name == "IMG0")
    try p.run([.diskSelect(drive: 0, image: 1)])
    #expect(m.subSystem.drives[0] == nil)  // door open (pendingMount)
  }

  @Test func selectImageOutOfRangeThrows() {
    let d88 = makeD88(names: ["IMG0"])
    let (p, _) = makePlayer(["A.d88": d88])
    #expect(throws: ScriptPlayer.RuntimeError.self) {
      try p.run([.diskMount(drive: 0, path: "A.d88", image: 0), .diskSelect(drive: 0, image: 9)])
    }
  }

  @Test func diskEjectClears() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])
    try p.run([.diskMount(drive: 1, path: "A.d88", image: 0)])
    #expect(m.subSystem.drives[1] != nil)
    try p.run([.diskEject(drive: 1)])
    #expect(m.subSystem.drives[1] == nil)
  }

  // MARK: - driveMount snapshot (used by the app layer to rebuild MountedDiskInfo)

  @Test func driveMountExposesPathImagesAndIndex() throws {
    // Mounting a multi-image D88 exposes the path, every image, and the
    // selected index.
    let d88 = makeD88(names: ["IMG0", "IMG1", "IMG2"])
    let (p, _) = makePlayer(["Ys.d88": d88])
    try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 2)])
    let mount = try #require(p.driveMount(0))
    #expect(mount.path == "Ys.d88")
    #expect(mount.images.count == 3)
    #expect(mount.imageIndex == 2)
    #expect(p.driveMount(1) == nil)  // a drive the script never touched
  }

  @Test func driveMountTracksSelect() throws {
    // `disk select` updates the image index and keeps the full image list.
    let d88 = makeD88(names: ["IMG0", "IMG1"])
    let (p, _) = makePlayer(["Ys.d88": d88])
    try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 0),
               .diskSelect(drive: 0, image: 1)])
    let mount = try #require(p.driveMount(0))
    #expect(mount.imageIndex == 1)
    #expect(mount.images.count == 2)
  }

  @Test func driveMountClearedOnEject() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (p, _) = makePlayer(["A.d88": d88])
    try p.run([.diskMount(drive: 1, path: "A.d88", image: 0)])
    #expect(p.driveMount(1) != nil)
    try p.run([.diskEject(drive: 1)])
    #expect(p.driveMount(1) == nil)
  }

  @Test func diskSwapMountsFile() throws {
    // A swap into an empty drive mounts immediately; the delay for an occupied
    // drive is SubSystem's responsibility.
    let b = makeD88(names: ["BBBB"])
    let (p, m) = makePlayer(["B.d88": b])
    try p.run([.diskSwap(drive: 0, path: "B.d88", image: 0)])
    #expect(m.subSystem.drives[0]?.name == "BBBB")
  }

  @Test func mountImageOutOfRangeThrows() {
    let d88 = makeD88(names: ["IMG0"])
    let (p, _) = makePlayer(["A.d88": d88])
    #expect(throws: ScriptPlayer.RuntimeError.self) {
      try p.run([.diskMount(drive: 0, path: "A.d88", image: 5)])
    }
  }

  @Test func selectWithoutMountThrows() {
    let (p, _) = makePlayer()
    #expect(throws: ScriptPlayer.RuntimeError.self) {
      try p.run([.diskSelect(drive: 0, image: 0)])
    }
  }

  @Test func missingFileThrows() {
    let (p, _) = makePlayer()
    #expect(throws: ScriptPlayer.RuntimeError.self) {
      try p.run([.diskMount(drive: 0, path: "nope.d88", image: 0)])
    }
  }

  // MARK: - reset

  @Test func resetReFinalizesDiskBoot() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])
    // Boot with a disk present: bit 3 = 0
    try p.run([.boot(.n88v2), .diskMount(drive: 0, path: "A.d88", image: 0), .wait(frames: 1)])
    #expect((m.bus.dipSw2 & 0x08) == 0)
    // Eject then reset: the next wait re-derives a ROM boot (bit 3 = 1)
    try p.run([.diskEject(drive: 0), .reset(preserveRAM: false), .wait(frames: 1)])
    #expect((m.bus.dipSw2 & 0x08) == 0x08)
  }

  @Test func resetPreservesScriptClock() throws {
    // reset forces clock8MHz back to true, but the script's clock is reapplied.
    let (p, m) = makePlayer()
    try p.run([.clock(mhz: 4)])
    #expect(m.clock8MHz == false)
    try p.run([.reset(preserveRAM: false)])
    #expect(m.clock8MHz == false)  // still 4MHz after the reset
  }

  @Test func clockUnspecifiedFollowsResetDefault() throws {
    // With no clock in the script nothing is reapplied, leaving reset's 8MHz.
    let (p, m) = makePlayer()
    m.clock8MHz = false
    try p.run([.reset(preserveRAM: false)])
    #expect(m.clock8MHz == true)
  }

  // MARK: - Live mode (the host owns runFrame)

  @Test func liveTapHoldTiming() throws {
    let (p, m) = makePlayer()
    let ret = Keyboard.Key(1, 7)
    // With no leading wait, beginLive presses the tap immediately.
    try p.beginLive([.key(ret, .tap(hold: 3)), .wait(frames: 5)])
    #expect(pressed(m, ret))             // just pressed
    _ = try p.liveTick()                 // 3→2
    #expect(pressed(m, ret))
    _ = try p.liveTick()                 // 2→1
    #expect(pressed(m, ret))
    _ = try p.liveTick()                 // 1→0 triggers the auto-release
    #expect(!pressed(m, ret))
  }

  @Test func liveWaitSchedulesKey() throws {
    let (p, m) = makePlayer()
    let sp = Keyboard.Key(9, 6)
    try p.beginLive([.wait(frames: 3), .key(sp, .down)])
    #expect(!pressed(m, sp))             // not yet, still in the leading wait
    _ = try p.liveTick()                 // wait 3→2
    _ = try p.liveTick()                 // 2→1
    #expect(!pressed(m, sp))
    _ = try p.liveTick()                 // 1→0, so the next step (down) applies
    #expect(pressed(m, sp))
  }

  @Test func liveReturnsFalseWhenConsumed() throws {
    let (p, _) = makePlayer()
    try p.beginLive([.wait(frames: 1)])
    #expect(p.isLivePlaying)
    #expect(try p.liveTick() == false)   // done after one more frame
    #expect(!p.isLivePlaying)
  }

  @Test func liveResolvesDiskBootOnFirstWait() throws {
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])
    try p.beginLive([.boot(.n88v2),
                     .diskMount(drive: 0, path: "A.d88", image: 0),
                     .wait(frames: 1)])
    // bit 3 is settled at the first wait after the mount: disk boot (bit 3 = 0).
    #expect((m.bus.dipSw2 & 0x08) == 0)
  }

  @Test func liveCancelReleasesHeldKeys() throws {
    let (p, m) = makePlayer()
    let a = Keyboard.Key(2, 1)
    try p.beginLive([.key(a, .down), .wait(frames: 10)])
    #expect(pressed(m, a))
    p.cancelLive()
    #expect(!pressed(m, a))               // cancelling released the key
    #expect(!p.isLivePlaying)
  }

  @Test func liveReplayMountsImmediatelyWhenDriveStillLoaded() throws {
    // Reproduces the app's second playback: subSystem.reset preserves drives,
    // so the previous disk is still in drive 0 when beginLive runs again.
    // diskMount must mount immediately — taking the swap-delay path would leave
    // drive0 == nil at finalize and make applyBootStrap choose a ROM boot.
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])

    // Stand-in for the first playback: get a disk mounted.
    try p.beginLive([.boot(.n88v2),
                     .diskMount(drive: 0, path: "A.d88", image: 0),
                     .wait(frames: 1)])
    #expect(m.subSystem.drives[0] != nil)

    // Second run: reset as the app does, preserving drives, then start over
    // with a new player.
    m.reset(preserveRAM: false)
    #expect(m.subSystem.drives[0] != nil)        // survives the reset
    let p2 = ScriptPlayer(machine: m) { _ in d88 }
    try p2.beginLive([.boot(.n88v2),
                      .diskMount(drive: 0, path: "A.d88", image: 0),
                      .wait(frames: 1)])
    #expect(m.subSystem.drives[0] != nil)        // mounted immediately, never nil via swap delay
    #expect((m.bus.dipSw2 & 0x08) == 0)          // settled on disk boot
  }

  @Test func waitZeroDoesNotLatchBootMode() throws {
    // `wait 0` does not settle the strap, so a disk mounted afterwards still
    // produces a disk boot.
    let d88 = makeD88(names: ["IMG0"])
    let (p, m) = makePlayer(["A.d88": d88])
    try p.run([
      .boot(.n88v2),
      .wait(frames: 0),                                  // must not latch here
      .diskMount(drive: 0, path: "A.d88", image: 0),
      .wait(frames: 1),                                  // settles on disk boot here
    ])
    #expect((m.bus.dipSw2 & 0x08) == 0)   // disk boot (bit3=0)
  }
}
