#!/usr/bin/env bash
# リリースタグを「unsafeFlags を外した専用コミット」に打つ。
#
# なぜ必要か:
#   コアは Debug でも -O でビルドする (Package.swift の alwaysOptimize)。-Onone だと
#   約 10 倍遅く、Debug 版アプリで遊べないため。ところが SwiftPM / Xcode は
#   unsafeFlags を含むパッケージを「バージョン指定の依存」として拒否する
#   (branch / revision 指定なら通る)。
#   そこで main は -O のまま残し、タグだけは alwaysOptimize を空にしたコミットに打つ。
#   そのコミットは main には入れない (タグからだけ辿れる)。
#
# 使い方:
#   ./scripts/tag-release.sh 1.2.0          # ローカルにタグを作るだけ
#   ./scripts/tag-release.sh 1.2.0 --push   # origin へタグを push
#
# 現在の HEAD を元にする。作業ツリーが汚れていたら止まる。終わると元のブランチに戻る。
# コアがリポジトリの直下にあるとき (分割後) だけ動く。タグを作った後、利用者と同じ条件
# (バージョン指定・Debug) でビルドできることを確かめ、できなければタグを消して止まる。
set -euo pipefail

usage() { echo "usage: $0 <version> [--push]" >&2; exit 2; }

[ $# -ge 1 ] && [ $# -le 2 ] || usage
version="$1"
push=0
if [ $# -eq 2 ]; then
    [ "$2" = "--push" ] || usage
    push=1
fi

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "error: バージョンは 1.2.0 の形 (先頭に v は付けない): $version" >&2
    exit 2
fi

pkg_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$pkg_root"

top="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
if [ "$top" != "$pkg_root" ]; then
    echo "error: パッケージがリポジトリの直下にない ($top)。分割後のコアリポジトリで実行する" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: 作業ツリーに未コミットの変更がある" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "error: タグ $version は既にある" >&2
    exit 1
fi

base="$(git rev-parse HEAD)"
orig_ref="$(git symbolic-ref -q --short HEAD || echo "$base")"
restore() { git checkout -q -f "$orig_ref"; }
trap restore EXIT

git checkout -q --detach "$base"

# alwaysOptimize の中身を空にする。複数行の配列を 1 行の [] に置き換える。
awk '
    /^let alwaysOptimize: \[SwiftSetting\] = \[$/ {
        print "let alwaysOptimize: [SwiftSetting] = []"
        skipping = 1; replaced++; next
    }
    skipping { if ($0 == "]") skipping = 0; next }
    { print }
    END { if (replaced != 1) exit 1 }
' Package.swift > Package.swift.tmp || {
    rm -f Package.swift.tmp
    echo "error: Package.swift に alwaysOptimize の定義が見つからない (形が変わった?)" >&2
    exit 1
}
mv Package.swift.tmp Package.swift

if grep -n '"-O"' Package.swift; then
    echo "error: alwaysOptimize の外に -O が残っている" >&2
    exit 1
fi
swift package dump-package >/dev/null

git commit -q -m "Release $version

Tag-only commit: alwaysOptimize is emptied so SwiftPM accepts this
package as a version-pinned dependency. main keeps the flag.
Built from $base." Package.swift
git tag -a "$version" -m "Bubilator88Core $version"

# 利用者と同じ条件で確かめる: 使い捨てのパッケージからバージョン指定で依存し、Debug で
# ビルドする。タグのコミットをルートとしてビルドしても意味がない (SwiftPM はルートの
# unsafeFlags を拒否しない)。"-O" 以外の unsafeFlags が紛れ込んでもここで止まる。
# 通らなければタグを消す。
consumer="$(mktemp -d)"
mkdir -p "$consumer/Sources/Consumer"
cat > "$consumer/Package.swift" <<EOF
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "file://$pkg_root", exact: "$version"),
    ],
    targets: [
        .target(name: "Consumer", dependencies: [
            .product(name: "Bubilator88Core", package: "$(basename "$pkg_root")"),
        ]),
    ]
)
EOF
echo 'import Bubilator88Core; let pc88 = PC88()' > "$consumer/Sources/Consumer/Consumer.swift"
if ! swift build --package-path "$consumer"; then
    git tag -d "$version" >/dev/null
    rm -rf "$consumer"
    echo "error: バージョン指定の依存としてビルドできない。タグ $version は消した" >&2
    exit 1
fi
rm -rf "$consumer"

echo "tagged $version -> $(git rev-parse --short HEAD) (base $(git rev-parse --short "$base"))"

if [ "$push" -eq 1 ]; then
    git push origin "refs/tags/$version"
fi
