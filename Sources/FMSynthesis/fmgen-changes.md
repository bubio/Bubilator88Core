# fmgen との関係と改変内容

本ディレクトリの YM2608 (OPNA) 実装は、cisc 氏の fmgen (FM Sound Generator)
を土台にしています。原典の著作権表示および利用条件は同ディレクトリの
`fmgen-readme.txt` (原文のまま無改変で同梱) を参照してください。

利用条件 1「由来を明記すること」と 3「改変したソースコードを配布する際は改変内容を
明示すること」に基づき、fmgen との関係と原典からの改変内容を以下に記します。

## 1. 位置付け

fmgen は OPN / OPNA / OPNB / OPM 系チップを共通のインターフェースで扱う汎用ライブラリ
です。本実装はその移植ではなく、**PC-8801 のサウンド回路 (OPNA + BEEP) を再現する
ために、fmgen の OPNA 関連部分を土台として組み直したもの**です。

- 対象は YM2608 のみです。OPM (YM2151)、OPN (YM2203)、OPNB (YM2610) 用のコードや
  インターフェースは移植していません。
- 駆動方法が異なります。fmgen は `Mix()` で任意の出力レートのバッファを一括生成します
  が、本実装は CPU の T ステートで `tick()` を進め、出力サンプルを 1 つずつ生成します。
- 一方で、FM 合成部はほぼ逐語的な移植で、SSG・ADPCM-B・リズム・レジスタ処理も
  fmgen のアルゴリズムや定数をそのまま引き継いでいます (§3)。独自に書いたのは
  タイマーと、PC-8801 固有の部分・追加機能です (§5)。

## 2. 移植元

[BubiC-8801MA](https://github.com/bubio/BubiC-8801MA) 同梱の `src/vm/fmgen/`。
cisc 氏の fmgen (1998, 2003 版、`fmgen-readme.txt` の変更履歴で 008) に、
Common Source Code Project (武田氏) の改変が入ったものです。武田氏の改変のうち
左右独立の音量設定とステートセーブ (`ProcessState`) は本実装には引き継いでいません。

## 3. ファイルの対応

| fmgen | 内容 | 本実装 | 関係 |
|---|---|---|---|
| `fmgen.cpp` / `fmgeninl.h` / `fmgen.h` | オペレータ、4op チャンネル、テーブル類 | `FMSynthesizer.swift` の `FMOp` / `FMCh` と各テーブル | 移植 (構造・テーブル・固定小数点表現を踏襲) |
| `opna.cpp` `OPNBase::SetParameter`, `OPNABase::SetReg` | FM レジスタのデコード、ch3 効果音モード、CSM | `YM2608.swift` の `handleFMRegister` ほか | 移植 (スロット順・SL/RR テーブル等を踏襲、コードは書き直し) |
| `opna.cpp` `OPNABase::LFO`, `Mix6` | LFO、6 チャンネルの合成と定位 | `FMSynthesizer.generateSample` | 移植 |
| `opna.cpp` `OPNA::RhythmMix` | リズム音源 | `FMSynthesizer.generateRhythm` | 移植 |
| `opna.cpp` ADPCM-B (`ReadRAMN`, `DecodeADPCMBSample`, `WriteRAM`, `ReadRAM`, `ADPCMBMix`) | ADPCM-B の RAM アクセス・デコード・補間 | `YM2608.swift` の ADPCM 部 | 移植 (§4.3 の変更あり) |
| `opna.cpp` ステータス / IRQ (`SetStatus`, `UpdateStatus`, `ReadStatusEx`) | ステータスマスクと IRQ 判定 | `YM2608.swift` の `updateIRQLine`, `readExtStatus` | 移植 |
| `psg.cpp` | SSG (トーン・ノイズ・エンベロープ) | `YM2608.swift` の SSG 部 | アルゴリズムを移植 (ノイズ表・エンベロープ表の生成、固定小数点のシフト量、4 倍オーバーサンプリング、出力レベル表) |
| `fmtimer.cpp` | タイマー A/B | `YM2608.tick` | 独自実装 (周期は同じ) |
| `opna.cpp` `OPNA::LoadRhythmSample` | リズム WAV の読み込み | なし | 移植せず。呼び出し側が PCM を渡す |
| `opm.cpp`, `OPN`, `OPNB` | 他チップ | なし | 移植せず |

## 4. 挙動の違い

### 4.1 FM

| 項目 | fmgen | 本実装 |
|---|---|---|
| PG アンダーフロー (PR #99) | F-Number 0 と負の DT1 の組み合わせで位相増分が負のまま残り、無音になる | 乗算前に 18bit でラップさせる (実機 OPN の 17bit 加算器相当。本実装のスケールでは 2 倍なので 18bit)。実機録音と 0.02% 以内で一致 |
| SSG-EG で減衰量が負になったとき (#34) | `LogToLin` の引数が `uint` なので巨大な値に化け、無音になる | 最大振幅に飽和させる |
| LFO カウンタの進行 | LFO を使うチャンネルが鳴っている間だけ進む | LFO が有効 (reg 0x22 bit 3) なら常に進む |
| reg 0x22 bit 3 の切り替え | LFO カウンタを 0 に戻す | 戻さない |
| ch3 効果音モード / CSM の F-Number 反映 | `Mix()` のたびに反映 | レジスタ書き込み時に反映 |
| プリスケーラ (reg 0x2D-0x2F) | 切り替え可能 | 無視し、1/72 (リセット時の値) で固定 |
| 出力サンプリングレート | 任意 | 44,100 Hz 固定 |
| オペレータのリセット | レジスタ由来の値は `OPNABase::Reset` が全レジスタに 0 を書いて作り直す (RR は 2 になる) | 全フィールドを 0 に戻す (RR も 0) |

### 4.2 リズム

- WAV ファイル (`2608_*.WAV`、`2608_RYM.WAV`) は読まず、呼び出し側が PCM を渡します。
  fmgen は 6 音すべてが揃わないと全体を無効にしますが、本実装は音色ごとに扱います。
- 再生し終えた音色のキーオンビットを自動で落とします (fmgen は立てたまま)。
  出力には影響せず、デバッグ表示に使っています。

### 4.3 ADPCM-B

| 項目 | fmgen | 本実装 |
|---|---|---|
| 再生レートが出力レートを超えるとき | 区間内の複数のデコード値を平均する | 溜まった分をすべてデコードし、直近 2 値を線形補間する |
| コントロール 1 の書き込みモード / 読み出しモード移行時 | アドレスはそのまま | アドレスを開始アドレスに戻し、EOS を落とす |
| EOS の反映 | 一部は次のステータス読み出し後に反映 (`statusnext`) | 即時に反映 |
| リミットアドレスの初期値 | 0x3FFFF | 0x3FFFFF |
| ext reg 0x27 (FA/MA 店頭デモ用の EOS クリア) | あり | なし |

デコードを出力レートで行う点 (#14)、リミットアドレスを一致で判定する点 (#17)、
RAM 読み出しの先読みが 2 段 (最初の 2 回がダミー) である点は fmgen と同じです。
いずれも移植時の誤りを fmgen に合わせて直したものです。

### 4.4 SSG

| 項目 | fmgen | 本実装 |
|---|---|---|
| ミキサー (#41) | 有効なトーンとノイズの **OR**。両方無効だと常に負側 | トーンとノイズの **AND**。無効な入力は High 固定 (実機の PSG と同じ)。音量レジスタを DAC として使う音声再生のため |
| 出力 | 左右独立の音量 (武田氏の改変) | モノラル |
| エンベロープ | どのチャンネルも使っていないときは計算を省き、まとめて進める | 常にオーバーサンプリング単位で進める |
| I/O ポート A/B (reg 0x0E/0x0F) | レジスタ値 | 常に 0xFF (ジョイスティック未接続) |

### 4.5 タイマー・ステータス

- タイマーは CPU の T ステートで数える独自実装です。周期 (タイマー A は 72、
  タイマー B は 1152 OPNA クロック単位) と IRQ 判定の式は fmgen と同じです。
- データ書き込み後の約 10 µs、ステータスの BUSY (bit 7) を立てます (fmgen には無い)。

## 5. 追加した機能

原典にない機能として以下を追加しています。

- **PC-8801 の BEEP / SING** — ポート 0x40 の 2400 Hz BEEP と CMD SING を OPNA の出力に混ぜる
- **CPU クロック基準のサンプル生成** — T ステートからの誤差なしの出力サンプル生成と、
  オーディオ出力に合わせたクロックの微調整
- **YM2203 (OPN) として振る舞うモード** — reg 0xFF の ID を 0x00 にし、拡張ポートを
  オープンバスにする (`forceOPNMode`)
- **セーブステート対応** — `FMSynthesizerSerialize.swift` / `YM2608Serialize.swift`
  (fmgen / Common Source Code Project の `ProcessState` とは別形式)
- **疑似ステレオ** — モノラル出力向けの Haas 効果 (`ChorusEffect`)
- **CD ミックス出力段** — 1 極ローパスフィルタと Schroeder リバーブによる
  出力段 (`AudioPostProcessor.swift`)。既定は無効
- **イマーシブ/空間音声出力** — 音源別ステレオバッファの生成
- **デバッグ用ミュート** — FM/SSG/ADPCM/リズムの音源別・チャンネル別ミュート
  (`DebugOutputMask`, `DebugChannelMask`)。fmgen の `Mute` と違い、ミュート中の
  FM チャンネルは計算自体を省く
