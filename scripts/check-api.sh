#!/usr/bin/env bash
# 公開 API を直前のリリースと比べ、利用者のコードを壊す変更があれば失敗する。
#
# なぜ必要か:
#   1.0.0 以降、公開 API を壊す変更はメジャーバージョンでだけ行う約束 (README)。
#   それを PR ごとに機械で確かめる。比べるのは Bubilator88Core と、それが再エクスポート
#   する PC88Types。@_spi(Debug) はデバッガ用で予告なく変える約束なので対象外。
#
# なぜ swift package diagnose-api-breaking-changes を使わないか:
#   - library product の targets に挙がったモジュールしか比べない。PC88Types は
#     再エクスポートしているだけなので、基準のタグに無いものとして飛ばされる。
#   - SPI を除外できない。
#   - public を package / internal に下げても検出しない。ビルド済みモジュールには
#     公開されない宣言も (isInternal の印付きで) 入っていて、「削除」に見えないため。
#   そこで swift-api-digester で両者の API を JSON に書き出し、公開されない宣言と
#   SPI を取り除いてから比べる。
#
# 使い方:
#   ./scripts/check-api.sh           # 最新のリリースタグと比べる
#   ./scripts/check-api.sh 1.0.0     # 基準を指定する
#
# 意図して壊すとき (メジャーを上げるとき) は、出力された行をそのまま
# api-breakage-allowlist.txt (リポジトリ直下) に書くと、その行は失敗扱いにしない。
# メジャーのタグを打ったら基準が進むので、ファイルは消してよい。
set -euo pipefail

modules=(Bubilator88Core PC88Types)

pkg_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$pkg_root"

if [ $# -ge 1 ]; then
    base="$1"
else
    base="$(git tag --list --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
    if [ -z "$base" ]; then
        echo "error: リリースタグが見つからない (git fetch --tags が要るかもしれない)" >&2
        exit 1
    fi
fi
git rev-parse -q --verify "$base^{commit}" >/dev/null || {
    echo "error: $base が見つからない" >&2
    exit 1
}
echo "Comparing the public API with $base"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 基準はタグの中身を取り出してビルドする (作業ツリーには触らない)。
mkdir "$work/base"
git archive "$base" | tar -x -C "$work/base"
swift build --package-path "$work/base" --target Bubilator88Core
swift build --target Bubilator88Core
base_modules="$(swift build --package-path "$work/base" --show-bin-path)/Modules"
head_modules="$(swift build --show-bin-path)/Modules"

sdk="$(xcrun --show-sdk-path)"

# 公開されない宣言 (package / internal) と @_spi(Debug) を JSON から取り除く。
strip_hidden() {
    python3 - "$1" <<'PY'
import json, sys

def visible(node):
    return not node.get("isInternal") and "Debug" not in node.get("spi_group_names", [])

def prune(node):
    if "children" in node:
        node["children"] = [prune(c) for c in node["children"] if visible(c)]
    return node

path = sys.argv[1]
with open(path) as f:
    root = json.load(f)
prune(root["ABIRoot"])
with open(path, "w") as f:
    json.dump(root, f)
PY
}

dump() {  # <modules dir> <module> <output>
    xcrun swift-api-digester -dump-sdk -sdk "$sdk" -I "$1" -module "$2" -o "$3"
    strip_hidden "$3"
}

allowlist="$pkg_root/api-breakage-allowlist.txt"
failed=0
for m in "${modules[@]}"; do
    dump "$base_modules" "$m" "$work/base-$m.json"
    dump "$head_modules" "$m" "$work/head-$m.json"
    # 結果は分類ごとの見出し (/* ... */) と空行の間に 1 行ずつ出る。
    xcrun swift-api-digester -diagnose-sdk \
        -input-paths "$work/base-$m.json" -input-paths "$work/head-$m.json" \
        -o "$work/diff-$m.txt"
    breaks="$(grep -v -e '^$' -e '^/\*' "$work/diff-$m.txt" || true)"
    if [ -n "$breaks" ] && [ -f "$allowlist" ]; then
        breaks="$(grep -v -x -F -f "$allowlist" <<<"$breaks" || true)"
    fi
    if [ -z "$breaks" ]; then
        echo "$m: no breaking changes"
        continue
    fi
    failed=1
    echo "$m: breaking changes against $base"
    while IFS= read -r line; do
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::error title=API breakage ($m)::$line"
        else
            echo "  $line"
        fi
    done <<<"$breaks"
done

exit "$failed"
