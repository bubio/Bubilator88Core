/// PC-8801 のマウス入力 (OPN/OPNA 汎用 I/O ポート経由) の behavioral model。
///
/// マウスは専用 I/O ポートを持たず、OPN (YM2608) の汎用 I/O ポート (reg 0x0E =
/// port A / reg 0x0F = port B) 経由で読まれる。M88 (cisc) の `mouse.cpp` と同様、
/// 本デバイスは **2 つの読み取りモード**を 1 つに内包する:
///
/// 1. バスマウスモード (`joyMode == false`): PC-8872 純正バスマウス。
///    - ストローブ: port 0x40 write の bit 6 (JOP1) 反転でフェーズ進行
///    - reg 0x0E (port A) → X/Y 相対移動量を 4 段ニブル読み出し
///      (phase 0: X上位 / 1: X下位 / 2: Y上位 / 3: Y下位、下位4bit有効、上位 | 0xF0)
///    - phase 0 突入時に累積移動量を符号反転 + ±127 クリップしてラッチ&クリア
///    - ストローブ間隔が一定 T-state を超えるとシーケンス中断とみなし phase=0
///    参照: BubiC `pc88.cpp` read_io8 case 0x45 / M88 `mouse.cpp` GetMove/Strobe
///
/// 2. ジョイモード (`joyMode == true`): マウスをアタリ仕様ジョイスティックとして
///    扱い、OPN ポートをジョイスティックとして読むゲーム用。ストローブ不要。
///    (現時点でこのモードを必要とする実タイトルは未発見。将来のための受け皿。
///     あーくしゅはジョイモードではなく上記バスマウスモードで動く。)
///    - reg 0x0E (port A) → 累積移動量を方向ビットに変換 (アクティブLow):
///      bit0=上, bit1=下, bit2=左, bit3=右、上位 | 0xF0
///    - VSync ごとにラッチを解除 (1 フレーム 1 サンプル)
///    参照: M88 `mouse.cpp` GetMove joymode 分岐 / QUASI88 ジョイスティック bit 配置
///
/// reg 0x0F (port B) のボタン (左=bit0 / 右=bit1、負論理、上位 0xFC) は両モード共通。
public final class Mouse {

    /// マウスモード有効時のみ port 横取りを行う。
    public var enabled: Bool = false

    /// true = ジョイモード (マウス→ジョイスティック方向ビット)、
    /// false = バスマウスモード (ストローブ式 4 段ニブル)。
    public var joyMode: Bool = false

    /// ジョイモードの方向判定しきい値 (デッドゾーン)。これを超える累積移動で
    /// 方向ビットが立つ。M88 の sensibility 相当。
    public var joyThreshold: Int = 3

    /// ホスト相対移動の累積 (ラッチで消費)。
    private var dx: Int = 0
    private var dy: Int = 0

    /// phase 0 でラッチされた移動量 (符号反転 + クリップ済み)。
    private var latchedX: Int = 0
    private var latchedY: Int = 0

    /// 現在の読み出しフェーズ (0-3)。-1 = 未ラッチ。
    private var phase: Int = -1

    /// 前回ストローブ時の T-state。
    private var lastStrobeTState: UInt64 = 0

    /// ボタン状態 (true = 押下)。
    private var leftButton: Bool = false
    private var rightButton: Bool = false

    /// ジョイモードでラッチした方向バイト。-1 = 未ラッチ (次の read で再計算)。
    private var joyLatch: Int = -1

    public init() {}

    /// Resets transient read state. `enabled` / `joyMode` are external
    /// configuration set by the host (settings) and are intentionally preserved
    /// across a machine reset.
    public func reset() {
        dx = 0
        dy = 0
        latchedX = 0
        latchedY = 0
        phase = -1
        lastStrobeTState = 0
        leftButton = false
        rightButton = false
        joyLatch = -1
    }

    /// 垂直帰線 (VSync) ごとに Machine から呼ばれ、ジョイモードのラッチを解除する
    /// (1 フレーム 1 サンプル)。M88 `Mouse::VSync` 相当。
    public func vsync() {
        joyLatch = -1
    }

    // MARK: - Host input

    /// ホストの相対マウス移動を累積する (App 層から呼ばれる)。
    public func injectMovement(dx: Int, dy: Int) {
        self.dx += dx
        self.dy += dy
    }

    /// 左右ボタンの状態を設定する。
    public func setButtons(left: Bool, right: Bool) {
        leftButton = left
        rightButton = right
    }

    // MARK: - Bus access

    /// port 0x40 bit 6 (JOP1) の反転で呼ばれる。フェーズを進め、phase 0 で
    /// 累積移動量をラッチする。
    ///
    /// - Parameters:
    ///   - now: 現在の T-state
    ///   - clock8MHz: CPU クロック (タイムアウト幅の決定に使う)
    public func strobe(now: UInt64, clock8MHz: Bool) {
        // ジョイモードではストローブを使わない (フェーズ進行は無意味)。
        guard !joyMode else { return }
        // ストローブ・タイムアウト = (8MHz ? 1440 : 720) * 1.25 CPU クロック。
        // Z80 では 1 CPU クロック ≒ 1 T-state。
        let limit: UInt64 = clock8MHz ? 1800 : 900
        let elapsed = now &- lastStrobeTState

        if phase == -1 || elapsed > limit {
            phase = 0
        } else {
            phase = (phase + 1) & 3
        }

        if phase == 0 {
            latchedX = -Mouse.clip127(dx)
            latchedY = -Mouse.clip127(dy)
            dx = 0
            dy = 0
        }

        lastStrobeTState = now
    }

    /// reg 0x0E (port A) 読み出し。モードで挙動が変わる。
    public func readData() -> UInt8 {
        if joyMode {
            return readJoyDirection()
        }
        // バスマウスモード: phase 別の X/Y ニブル。
        let value: Int
        switch phase {
        case 0: value = (latchedX >> 4) & 0x0F  // X 上位ニブル
        case 1: value = latchedX & 0x0F          // X 下位ニブル
        case 2: value = (latchedY >> 4) & 0x0F  // Y 上位ニブル
        case 3: value = latchedY & 0x0F          // Y 下位ニブル
        default: value = 0x0F
        }
        return UInt8(value) | 0xF0
    }

    /// ジョイモードの reg 0x0E 読み出し: 累積移動量を方向ビット (アクティブLow) に
    /// 変換。bit0=上, bit1=下, bit2=左, bit3=右、上位 | 0xF0。VSync までラッチ。
    /// M88 `Mouse::GetMove` の joymode 分岐相当 (二値、1 フレーム 1 サンプル)。
    private func readJoyDirection() -> UInt8 {
        if joyLatch == -1 {
            var d = 0xFF
            if dy <= -joyThreshold { d &= ~0x01 }  // 上
            if dy >=  joyThreshold { d &= ~0x02 }  // 下
            if dx <= -joyThreshold { d &= ~0x04 }  // 左
            if dx >=  joyThreshold { d &= ~0x08 }  // 右
            joyLatch = d
            dx = 0  // このフレーム分の移動を消費
            dy = 0
        }
        return UInt8(joyLatch)
    }

    /// reg 0x0F (port B) 読み出し: 左=bit0 / 右=bit1、負論理、上位 0xFC 固定。
    public func readButtons() -> UInt8 {
        var buttons: UInt8 = 0
        if leftButton { buttons |= 0x01 }
        if rightButton { buttons |= 0x02 }
        return (~buttons & 0x03) | 0xFC
    }

    // MARK: - Helpers

    /// ±127 にクリップする。
    private static func clip127(_ v: Int) -> Int {
        return max(-127, min(127, v))
    }
}
