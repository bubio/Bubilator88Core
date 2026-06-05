import Testing
import Foundation
@testable import EmulatorCore

@Suite("Script Player Tests")
struct ScriptPlayerTests {

    // MARK: - Helpers

    /// ヘッダのみの最小 D88 を `names.count` 面ぶん連結して生成する。
    private func makeD88(names: [String]) -> [UInt8] {
        var out: [UInt8] = []
        for name in names {
            var block = [UInt8](repeating: 0, count: 688)
            for (i, b) in Array(name.utf8).prefix(16).enumerated() { block[i] = b }
            block[0x1A] = 0x00          // write protect off
            block[0x1B] = 0x00          // 2D
            // disk size = 688 (LE) — parseAll が複数面を歩けるよう非ゼロにする
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

    // MARK: - 自動 ROM/ディスク起動 (DIPSW2 bit3)

    @Test func resolvedBootStrapPureFunction() {
        // ディスクあり → bit3 を落とす / なし → bit3 を立てる。他ビットは保持。
        #expect(Machine.resolvedBootStrap(base: 0x79, hasDiskInDrive0: true) == 0x71)
        #expect(Machine.resolvedBootStrap(base: 0x71, hasDiskInDrive0: false) == 0x79)
        // 既に正しい側なら冪等。
        #expect(Machine.resolvedBootStrap(base: 0x71, hasDiskInDrive0: true) == 0x71)
        #expect(Machine.resolvedBootStrap(base: 0x79, hasDiskInDrive0: false) == 0x79)
    }

    @Test func applyBootStrapUsesCurrentDipSw2WhenBaseOmitted() throws {
        let d88 = makeD88(names: ["IMG0"])
        let (_, m) = makePlayer(["A.d88": d88])
        m.bus.dipSw2 = 0xF9            // V1H + bit3=1
        m.applyBootStrap()            // ディスク無し → bit3 維持、他ビット保持
        #expect(m.bus.dipSw2 == 0xF9)
    }

    @Test func autoDiskBootClearsBit3WhenDiskPresent() throws {
        let d88 = makeD88(names: ["IMG0"])
        let (p, m) = makePlayer(["A.d88": d88])
        try p.run([.boot(.n88v2), .diskMount(drive: 0, path: "A.d88", image: 0), .wait(frames: 1)])
        // ドライブ0にディスク → disk boot (bit3=0)
        #expect((m.bus.dipSw2 & 0x08) == 0)
    }

    @Test func autoRomBootSetsBit3WhenNoDisk() throws {
        let (p, m) = makePlayer()
        try p.run([.boot(.n88v2), .wait(frames: 1)])
        // ディスク無し → ROM boot (bit3=1)
        #expect((m.bus.dipSw2 & 0x08) == 0x08)
    }

    @Test func rawDipsw2DisablesAutoResolve() throws {
        let (p, m) = makePlayer()
        // 生値で bit3=0 を指定 → ディスク無しでも自動で立てない
        try p.run([.dipsw2(0x71), .wait(frames: 1)])
        #expect((m.bus.dipSw2 & 0x08) == 0)
    }

    // MARK: - キー入力

    @Test func keyDownPersistsAcrossWaits() throws {
        let (p, m) = makePlayer()
        let a = Keyboard.Key(2, 1)
        try p.run([.key(a, .down), .wait(frames: 10)])
        // down は自動リリースされない → 終了後も押下のまま
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
        #expect(pressed(m, ret))     // 押下直後
        p.advance(2)
        #expect(pressed(m, ret))     // 2 フレーム経過 (< 3) → まだ押下
        p.advance(1)
        #expect(!pressed(m, ret))    // 3 フレーム目で自動リリース
    }

    @Test func tapHoldZeroClampedToOneFrame() {
        // §6: 必ず 1 フレーム以上保持。hold 0 は 1 に丸める。
        let (p, m) = makePlayer()
        let ret = Keyboard.Key(1, 7)
        p.applyKey(ret, .tap(hold: 0))
        #expect(pressed(m, ret))     // 押下直後はまだ押下 (即離さない)
        p.advance(1)
        #expect(!pressed(m, ret))    // 1 フレーム後に解放
    }

    @Test func tapReleasedByFinish() throws {
        let (p, m) = makePlayer()
        let sp = Keyboard.Key(9, 6)
        // hold 100 だが wait 1 のみ → run 終了時に finish が解放する
        try p.run([.key(sp, .tap(hold: 100)), .wait(frames: 1)])
        #expect(!pressed(m, sp))
    }

    @Test func explicitDownAfterTapStaysHeld() throws {
        let (p, m) = makePlayer()
        let a = Keyboard.Key(2, 1)
        try p.run([.key(a, .tap(hold: 2)), .key(a, .down), .wait(frames: 10)])
        // down が tap 予約を解除 → finish でも解放されず押下のまま
        #expect(pressed(m, a))
    }

    // MARK: - ディスク

    @Test func mountSelectsCorrectImage() throws {
        // multi-image D88 から image 番号で正しい面を選ぶ (空ドライブ → 即時)。
        let d88 = makeD88(names: ["IMG0", "IMG1"])
        let (p, m) = makePlayer(["Ys.d88": d88])
        try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 1)])
        #expect(m.subSystem.drives[0]?.name == "IMG1")
    }

    @Test func selectTriggersRemount() throws {
        // 占有ドライブの image 切替は差し替え扱い → ドアが開く (drives 一時 nil)。
        // commit は DISK.ROM ありの非 legacy 動作なので、ここでは remount 開始のみ確認。
        let d88 = makeD88(names: ["IMG0", "IMG1"])
        let (p, m) = makePlayer(["Ys.d88": d88])
        try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 0)])
        #expect(m.subSystem.drives[0]?.name == "IMG0")
        try p.run([.diskSelect(drive: 0, image: 1)])
        #expect(m.subSystem.drives[0] == nil)   // ドア開放中 (pendingMount)
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

    // MARK: - driveMount snapshot (App 層の MountedDiskInfo 再構築用)

    @Test func driveMountExposesPathImagesAndIndex() throws {
        // multi-image D88 をマウントすると、パス・全イメージ・選択番号を公開する。
        let d88 = makeD88(names: ["IMG0", "IMG1", "IMG2"])
        let (p, _) = makePlayer(["Ys.d88": d88])
        try p.run([.diskMount(drive: 0, path: "Ys.d88", image: 2)])
        let mount = try #require(p.driveMount(0))
        #expect(mount.path == "Ys.d88")
        #expect(mount.images.count == 3)
        #expect(mount.imageIndex == 2)
        #expect(p.driveMount(1) == nil)   // 触れていないドライブ
    }

    @Test func driveMountTracksSelect() throws {
        // disk select でイメージ番号が更新される (全イメージは保持)。
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
        // 空ドライブへの swap は即時マウント (占有ドライブの差し替え遅延は SubSystem 側の責務)。
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
        // ディスク有りで起動 → bit3=0
        try p.run([.boot(.n88v2), .diskMount(drive: 0, path: "A.d88", image: 0), .wait(frames: 1)])
        #expect((m.bus.dipSw2 & 0x08) == 0)
        // eject して reset → 次の wait で ROM boot に再確定 (bit3=1)
        try p.run([.diskEject(drive: 0), .reset(preserveRAM: false), .wait(frames: 1)])
        #expect((m.bus.dipSw2 & 0x08) == 0x08)
    }

    @Test func resetPreservesScriptClock() throws {
        // reset は clock8MHz を true に戻すが、スクリプトの clock 指定は再適用される。
        let (p, m) = makePlayer()
        try p.run([.clock(mhz: 4)])
        #expect(m.clock8MHz == false)
        try p.run([.reset(preserveRAM: false)])
        #expect(m.clock8MHz == false)   // reset 後も 4MHz を維持
    }

    @Test func clockUnspecifiedFollowsResetDefault() throws {
        // clock 未指定なら再適用しない (reset の既定 8MHz のまま)。
        let (p, m) = makePlayer()
        m.clock8MHz = false
        try p.run([.reset(preserveRAM: false)])
        #expect(m.clock8MHz == true)
    }

    // MARK: - live モード (ホストが runFrame を所有)

    @Test func liveTapHoldTiming() throws {
        let (p, m) = makePlayer()
        let ret = Keyboard.Key(1, 7)
        // 先頭 wait 無しなので beginLive が即座に tap を押下する。
        try p.beginLive([.key(ret, .tap(hold: 3)), .wait(frames: 5)])
        #expect(pressed(m, ret))             // 押下直後
        _ = try p.liveTick()                 // 3→2
        #expect(pressed(m, ret))
        _ = try p.liveTick()                 // 2→1
        #expect(pressed(m, ret))
        _ = try p.liveTick()                 // 1→0 で自動リリース
        #expect(!pressed(m, ret))
    }

    @Test func liveWaitSchedulesKey() throws {
        let (p, m) = makePlayer()
        let sp = Keyboard.Key(9, 6)
        try p.beginLive([.wait(frames: 3), .key(sp, .down)])
        #expect(!pressed(m, sp))             // 先頭 wait 中はまだ
        _ = try p.liveTick()                 // wait 3→2
        _ = try p.liveTick()                 // 2→1
        #expect(!pressed(m, sp))
        _ = try p.liveTick()                 // 1→0 → 次ステップ (down) を適用
        #expect(pressed(m, sp))
    }

    @Test func liveReturnsFalseWhenConsumed() throws {
        let (p, _) = makePlayer()
        try p.beginLive([.wait(frames: 1)])
        #expect(p.isLivePlaying)
        #expect(try p.liveTick() == false)   // 1 フレーム経過で完了
        #expect(!p.isLivePlaying)
    }

    @Test func liveResolvesDiskBootOnFirstWait() throws {
        let d88 = makeD88(names: ["IMG0"])
        let (p, m) = makePlayer(["A.d88": d88])
        try p.beginLive([.boot(.n88v2),
                         .diskMount(drive: 0, path: "A.d88", image: 0),
                         .wait(frames: 1)])
        // ディスク mount 後に最初の wait で bit3 確定 → disk boot (bit3=0)。
        #expect((m.bus.dipSw2 & 0x08) == 0)
    }

    @Test func liveCancelReleasesHeldKeys() throws {
        let (p, m) = makePlayer()
        let a = Keyboard.Key(2, 1)
        try p.beginLive([.key(a, .down), .wait(frames: 10)])
        #expect(pressed(m, a))
        p.cancelLive()
        #expect(!pressed(m, a))               // 中断でキー解放
        #expect(!p.isLivePlaying)
    }

    @Test func liveReplayMountsImmediatelyWhenDriveStillLoaded() throws {
        // アプリの2回目再生の再現: subSystem.reset は drives を保持するため、
        // 2回目の beginLive 開始時にドライブ0へ前回ディスクが残っている。
        // diskMount は即時マウントすべき (交換ディレイに入ると finalize 時に
        // drive0==nil となり applyBootStrap が ROM 起動へ誤判定する)。
        let d88 = makeD88(names: ["IMG0"])
        let (p, m) = makePlayer(["A.d88": d88])

        // 1回目の再生相当: ディスクをマウントしておく。
        try p.beginLive([.boot(.n88v2),
                         .diskMount(drive: 0, path: "A.d88", image: 0),
                         .wait(frames: 1)])
        #expect(m.subSystem.drives[0] != nil)

        // 2回目: アプリと同じく reset (drives 保持) 後に新しい player で再開。
        m.reset(preserveRAM: false)
        #expect(m.subSystem.drives[0] != nil)        // reset でも残っている
        let p2 = ScriptPlayer(machine: m) { _ in d88 }
        try p2.beginLive([.boot(.n88v2),
                          .diskMount(drive: 0, path: "A.d88", image: 0),
                          .wait(frames: 1)])
        #expect(m.subSystem.drives[0] != nil)        // 即時マウント (交換ディレイで nil にならない)
        #expect((m.bus.dipSw2 & 0x08) == 0)          // disk boot に確定
    }

    @Test func waitZeroDoesNotLatchBootMode() throws {
        // wait 0 は起動確定を進めない。後から mount したディスクで disk boot になる。
        let d88 = makeD88(names: ["IMG0"])
        let (p, m) = makePlayer(["A.d88": d88])
        try p.run([
            .boot(.n88v2),
            .wait(frames: 0),                                  // ここで latch しないこと
            .diskMount(drive: 0, path: "A.d88", image: 0),
            .wait(frames: 1),                                  // ここで disk boot に確定
        ])
        #expect((m.bus.dipSw2 & 0x08) == 0)   // disk boot (bit3=0)
    }
}
