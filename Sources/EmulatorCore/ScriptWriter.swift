// ScriptWriter.swift — [ScriptStep] を正準スクリプトテキストへ直列化する。
//
// `ScriptParser` の逆操作。記録機能 (ScriptRecorder) が組み立てた [ScriptStep] を
// `.b88script` テキストに書き出す。`ScriptParser.parse(write(steps)) == steps` を
// 保証する (round-trip)。Machine には依存しない純粋関数。

public enum ScriptWriter {

    /// [ScriptStep] → 正準スクリプトテキスト (1 ステップ = 1 行、末尾改行つき)。
    /// `ScriptParser.parse` が読み戻せる表記のみを出力する。
    public static func write(_ steps: [ScriptStep]) -> String {
        var out = steps.map(line(for:)).joined(separator: "\n")
        if !out.isEmpty { out += "\n" }
        return out
    }

    /// `Keyboard.Key` の正準キー名 (`ScriptParser.key(named:)` の逆)。
    /// 名前を持たないキーは row-bit 表記 (`"\(row)-\(bit)"`) にフォールバックする。
    public static func keyName(for key: Keyboard.Key) -> String {
        if let name = canonicalNames[key] { return name }
        return "\(key.row)-\(key.bit)"
    }

    // MARK: - Per-step serialization

    private static func line(for step: ScriptStep) -> String {
        switch step {
        case .boot(let mode):                return "boot \(mode.rawValue)"
        case .clock(let mhz):                return "clock \(mhz)"
        case .dipsw1(let v):                 return "dipsw1 0x\(hex2(v))"
        case .dipsw2(let v):                 return "dipsw2 0x\(hex2(v))"
        case .diskMount(let d, let p, let i): return diskLine("disk \(d)", path: p, image: i)
        case .wait(let frames):              return "wait \(frames)"
        case .key(let key, let action):      return keyLine(key, action)
        case .diskSwap(let d, let p, let i): return diskLine("disk swap \(d)", path: p, image: i)
        case .diskSelect(let d, let i):      return "disk select \(d) \(i)"
        case .diskEject(let d):              return "disk eject \(d)"
        case .reset(let preserveRAM):        return preserveRAM ? "reset warm" : "reset cold"
        }
    }

    /// `<prefix> "<path>" [image <i>]`。image == 0 は省略 (パーサの既定)。
    private static func diskLine(_ prefix: String, path: String, image: Int) -> String {
        let base = "\(prefix) \"\(escapeQuoted(path))\""
        return image != 0 ? "\(base) image \(image)" : base
    }

    /// クォート文字列内の `\` と `"` を `\` でエスケープする (Foundation 非依存)。
    /// トークナイザが `\\` → `\`、`\"` → `"` として読み戻す。
    private static func escapeQuoted(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "\"" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func keyLine(_ key: Keyboard.Key, _ action: KeyAction) -> String {
        let name = keyName(for: key)
        switch action {
        case .down:           return "key \(name) down"
        case .up:             return "key \(name) up"
        case .tap(let hold):  return hold == 2 ? "key \(name) tap" : "key \(name) tap \(hold)"
        }
    }

    /// 2 桁大文字 16 進 (Foundation 非依存)。
    private static func hex2(_ v: UInt8) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return s.count == 1 ? "0\(s)" : s
    }

    // MARK: - Canonical reverse key-name table

    /// `Keyboard.Key` → 正準名。`ScriptParser.keyNameTable` は非単射
    /// (esc/escape、return/enter/kpreturn/kpenter が同一キー) なので、
    /// 衝突キーは明示的に正準名を先置きし、残りは 1:1 で逆引きする。
    /// どの別名も同じキーへ戻るため round-trip はどの選択でも成立するが、
    /// 読みやすさのため docs/BOOTTESTER.md と同じ名前を選ぶ。
    private static let canonicalNames: [Keyboard.Key: String] = {
        var rev: [Keyboard.Key: String] = [
            Keyboard.kpReturn: "return",
            Keyboard.esc: "esc",
        ]
        for (name, key) in ScriptParser.keyNameTable where rev[key] == nil {
            rev[key] = name
        }
        return rev
    }()
}
