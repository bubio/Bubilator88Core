# Bubilator88Core

NEC PC-8801 (FA 相当) のエミュレーションコア。Swift パッケージ。

macOS エミュレーター [Bubilator88](https://github.com/bubio/Bubilator88) のコアを
切り出したものです。UI・描画・音声出力は持たず、「1 フレーム進める」「画面を RGBA で
受け取る」「音声サンプルを受け取る」だけを提供します。

**このプロジェクトのコードは、ほぼすべて AI（Claude, Codex）によって書かれています。**

- Z80 (T ステート精度)、メイン CPU とディスクサブシステムの 2 CPU 構成
- YM2608 (OPNA) — FM 6ch、SSG 3ch、リズム、ADPCM
- μPD765A FDC (D88 イメージ)、カセット (T88 / CMT)
- N88-BASIC V2 / V1H / V1S、N-BASIC
- セーブステート、テキスト画面のコピー、b88script (操作の記録・再生)

## 要件

- Swift 6.1 以降 (Xcode 16.3 以降)
- macOS 15 以降
- Windows では C ABI の DLL (`Bubilator88C`) としてビルドできます (後述)

## 導入

```swift
dependencies: [
    .package(url: "https://github.com/bubio/Bubilator88Core.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Bubilator88Core", package: "Bubilator88Core"),
    ]),
]
```

> **Debug ビルドについて**: コアは `-Onone` だと約 10 倍遅く、Debug ビルドのアプリでは
> 実速度が出ません。`main` ブランチは Debug でも `-O` でビルドする設定 (unsafeFlags) を
> 持っていますが、SwiftPM はバージョン指定の依存に unsafeFlags を許さないため、
> リリースタグはこの設定を外したコミットに打っています。バージョン指定で使うと、
> Debug ビルドのコアは遅くなります。`branch:` / `revision:` 指定なら `-O` が効きます。

## 使い方

```swift
import Bubilator88Core

let pc88 = PC88()

// ROM は同梱していません。実機から吸い出したものを渡してください。
pc88.loadROM(.n88Basic, data: n88ROM)           // N88.ROM
pc88.loadROM(.nBasic, data: n80ROM)             // N80.ROM
for bank in 0..<4 {
  pc88.loadROM(.n88Ext(bank: bank), data: n88ExtROM[bank])  // N88_0〜3.ROM
}
pc88.loadROM(.disk, data: diskROM)              // DISK.ROM
pc88.loadROM(.font, data: fontROM)              // FONT.ROM
pc88.loadROM(.kanji1, data: kanji1ROM)          // KANJI1.ROM

pc88.setBootMode(.n88v2)
if let disk = D88Disk.parse(data: d88Bytes) {
  pc88.mountDisk(drive: 0, disk: disk)
}
pc88.applyBootStrap()  // ドライブ 0 にディスクがあればディスク起動
pc88.reset()

var frame = [UInt8](repeating: 0, count: PC88.frameBufferSize)

// pc88.frameRate (約 55〜62Hz。60Hz ではない) の間隔で繰り返す
pc88.runFrame()
pc88.render(into: &frame, blinkCursor: true)  // 640×400 RGBA
let audio = pc88.takeAudioSamples()           // 44.1kHz ステレオ Float32 (L, R, …)

pc88.pressKey(.space)
pc88.releaseKey(.space)
```

入口は `PC88` 1 つです。API リファレンスは DocC で書いてあり、Xcode の
Product > Build Documentation で開けます。
境界をまたぐ値 (`D88Disk`, `PC88Key`, `BootMode`, `MonitorType`, `TapeFormat`) は
`import Bubilator88Core` だけで使えます。

### スレッド

`PC88` のインスタンスは、生成から破棄まで 1 本の直列キューから使ってください。
`onDiskWritten` / `onFDDEvent` のコールバックも `runFrame()` を呼んだスレッドで
同期的に呼ばれます。

## API の安定性

- **安定**: `PC88` と、上記の値型の public API。1.0.0 以降、メジャーバージョンを
  上げずに互換を壊す変更はしません。
- **不安定**: `@_spi(Debug) import Bubilator88Core` で見えるもの (デバッガ、CPU レジスタ、
  音源の内部状態など)。Bubilator88 のデバッガ用で、予告なく変わります。
- **C ABI** (`Bubilator88C`, `b88_*`): 関数の追加のみ行い、既存の関数は変えません。

## Windows (C ABI)

`Bubilator88C` プロダクトは、`PC88` を C の関数 (`b88_*`) で包んだ動的ライブラリです。
Bubilator88 の Windows 版 (C# / WinUI 3) はこれを P/Invoke で呼んでいます。

```
swift build -c release --product Bubilator88C
```

Windows でのシンボル書き出しにリンカフラグ (unsafeFlags) を使っているため、
このプロダクトはバージョン指定の依存としては使えません。リポジトリを clone して
ビルドしてください。

## 開発

```
swift test
```

リリースタグは GitHub Actions の Release Tag ワークフロー
(`scripts/tag-release.sh`) で打ちます。手で `git tag` しないでください
(unsafeFlags を外したコミットを作る必要があるため)。

安定 API の互換は CI が `scripts/check-api.sh` で最新のリリースタグと比べて確かめます。
手元でも同じスクリプトを実行できます。

## Credits

- **FM 合成エンジン**: [fmgen](http://retropc.net/cisc/sound/) by cisc — Swift への移植。
  利用条件は `Sources/FMSynthesis/fmgen-readme.txt`、改変内容は同じディレクトリの
  `fmgen-changes.md` を参照
- **参考エミュレーター**: [QUASI88](https://www.eonet.ne.jp/~showtime/quasi88/) by S.Fukunaga
- **参考エミュレーター**: [common source code project](https://takeda-toshiya.my.coocan.jp/common/index.html) by Takeda Toshiya (BubiC-8801MA)
- **参考エミュレーター**: [X88000](https://quagma.sakura.ne.jp/manuke/x88000.html) by Manuke
- **技術資料**: [PC-8801についてのページ](http://www.maroon.dti.ne.jp/youkan/pc88/) by youkan
- **技術資料**: [PC-8801 VRAM情報](http://mydocuments.g2.xrea.com/html/p8/vraminfo.html)
- **AI コーディング**: [Claude Code](https://claude.ai/code) (Anthropic)

## License

[GNU General Public License v2.0](LICENSE)

`Sources/FMSynthesis` は fmgen の移植で、GPLv2 に加えて fmgen の利用条件
(`fmgen-readme.txt`) に従います。特に、配布する際はフリーソフトとすること、
商用ソフト (シェアウェアを含む) に組み込む際は事前に原作者の合意を得ることが
求められています。
