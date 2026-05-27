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

# 3) .app を **/tmp に取り出して** 署名する
#
# プロジェクトが ~/Desktop / ~/Documents の iCloud Drive 配下にあると、
# File Provider が com.apple.FinderInfo / fileprovider.fpfs#P を再帰的・継続的に
# 付与してくる。codesign --verify が「detritus not allowed」で落ちる原因。
# iCloud 非同期領域である /tmp に取り出してから署名 → 戻すことで回避する。
APP_PATH=$(find "$DERIVED_DATA/Build/Products/Release" -name "localVoiceRec.app" -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: built .app が見つかりません" >&2
    exit 1
fi

STAGING_DIR=$(mktemp -d /tmp/lvr-sign.XXXXXX)
STAGING_APP="$STAGING_DIR/localVoiceRec.app"
echo "==> staging into $STAGING_APP"
cp -R "$APP_PATH" "$STAGING_APP"
xattr -cr "$STAGING_APP"

ENTITLEMENTS="App/localVoiceRec.entitlements"
# entitlement ファイルも掃除（読み込み時に拒否されるケースに備える）
xattr -c "$ENTITLEMENTS" 2>/dev/null || true

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    # Keychain から該当 team の Developer ID Application 証明書 SHA-1 を取得。
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" \
        | grep "(${DEVELOPMENT_TEAM})" \
        | head -1 \
        | awk -F'"' '{print $2}')
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "(error) Developer ID Application 証明書が Keychain に見つかりません (team=${DEVELOPMENT_TEAM})"
        echo "        Xcode → Settings → Accounts → Manage Certificates から Developer ID Application を作成してください。"
        exit 1
    fi
    echo "==> codesign with: $SIGN_IDENTITY"
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        --deep \
        "$STAGING_APP"
    echo "==> codesign --verify --deep --strict (in /tmp)"
    codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
else
    echo "(warn) DEVELOPMENT_TEAM 未設定: adhoc 署名で代用（配布不可、ローカル検証のみ）"
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign - \
        --deep \
        "$STAGING_APP"
fi

# 4) 署名済み .app を dist/ に移動
mkdir -p dist
rm -rf "dist/localVoiceRec.app"
mv "$STAGING_APP" "dist/localVoiceRec.app"
rm -rf "$STAGING_DIR"

echo "OK: dist/localVoiceRec.app"
