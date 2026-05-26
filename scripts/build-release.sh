#!/usr/bin/env bash
# Release ビルドを行い、.app を dist/ に出力する。
#
# 使い方:
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build-release.sh
#
# DEVELOPMENT_TEAM が未設定でも実行は試みるが、Developer ID 署名は付かない。
# 完全な配布用ビルドには Apple Developer Team ID を必ず渡すこと。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1) xcodeproj を生成
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen が必要: brew install xcodegen" >&2
    exit 1
fi
echo "==> xcodegen generate"
xcodegen generate

# 2) Release ビルド (Hardened Runtime)
#
# xcodebuild 内蔵の CodeSign フェーズは、ソース or 出力ツリーに iCloud File Provider
# 由来の xattr (com.apple.FinderInfo, com.apple.fileprovider.fpfs#P 等) が付いていると
# "resource fork, Finder information, or similar detritus not allowed" で落ちる
# （特にプロジェクトが ~/Desktop など iCloud Drive 配下にある場合）。
# 対策として、ビルド時は codesign をスキップし、ビルド後に xattr を掃除してから
# codesign を別途行う。
DERIVED_DATA="$ROOT_DIR/build/derived"

# ソースツリーの xattr を掃除（ファイル内容には影響しない）
echo "==> xattr -cr (clean macOS resource forks on source tree)"
xattr -cr App Sources Tools 2>/dev/null || true
xattr -c Package.swift project.yml 2>/dev/null || true

echo "==> xcodebuild Release (CODE_SIGNING_ALLOWED=NO, derivedDataPath=$DERIVED_DATA)"
xcodebuild \
    -project localVoiceRec.xcodeproj \
    -scheme localVoiceRec \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

# 3) .app を dist/ に
APP_PATH=$(find "$DERIVED_DATA/Build/Products/Release" -name "localVoiceRec.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: built .app が見つかりません" >&2
    exit 1
fi
mkdir -p dist
rm -rf "dist/localVoiceRec.app"
cp -R "$APP_PATH" "dist/localVoiceRec.app"

# 4) xattr を掃除してから codesign
APP="dist/localVoiceRec.app"
echo "==> xattr -cr $APP"
xattr -cr "$APP"

ENTITLEMENTS="App/localVoiceRec.entitlements"

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SIGN_IDENTITY="Developer ID Application: ${DEVELOPMENT_TEAM}"
    echo "==> codesign with: $SIGN_IDENTITY"
    # --deep は非推奨だが、SwiftPM の動的フレームワークを含むため使用。
    # 個別署名にしたい場合は Frameworks 配下を for ループで先に署名すること。
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        --deep \
        "$APP"
    echo "==> codesign --verify --deep --strict"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "(warn) DEVELOPMENT_TEAM 未設定: adhoc 署名で代用（配布不可、ローカル検証のみ）"
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        --deep \
        "$APP"
fi

echo "OK: dist/localVoiceRec.app"
