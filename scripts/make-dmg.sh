#!/usr/bin/env bash
# .app から配布用 .dmg を作る
#
# create-dmg ベース、カスタム背景 + Applications ショートカット付き
# マウント画面はブランディング済み (Brand/DMG/dmg-background.png)
#
# 使い方:
#   ./scripts/make-dmg.sh
#
# 必須:
#   - brew install create-dmg
#   - dist/localVoiceRec.app (build-release.sh で生成)
#
# 任意 env:
#   DEVELOPMENT_TEAM  Developer ID Application 証明書の Team ID (DMG 自体も署名する場合)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP="dist/localVoiceRec.app"
DMG_BG="Brand/DMG/dmg-background.png"
VOL_ICON="Brand/AppIcon/AppIcon.icns"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP が無い。先に ./scripts/build-release.sh を実行" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg が見つからない。brew install create-dmg を実行" >&2
    exit 1
fi

if [[ ! -f "$DMG_BG" ]]; then
    echo "ERROR: DMG 背景 $DMG_BG が無い。Brand/DMG を確認" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG_NAME="localVoiceRec-${VERSION}.dmg"
DMG_PATH="dist/$DMG_NAME"

echo "==> building DMG: $DMG_PATH"
rm -f "$DMG_PATH"

# create-dmg の座標は 540x380 ウィンドウ基準。
# アプリ left @ (140,200)、Applications drop @ (400,200) で、背景画像の
# スロット枠とちょうど揃う。
#
# --no-internet-enable: 「インターネットからダウンロードされた DMG」用の
#   internet-enabled フラグを付けない（Gatekeeper を素直にする）
#
# --volicon は DMG マウント時のボリュームアイコンも我々の AppIcon に統一する。
CREATE_DMG_ARGS=(
    --volname "localVoiceRec ${VERSION}"
    --background "$DMG_BG"
    --window-pos 200 120
    --window-size 540 380
    --icon-size 96
    --icon "localVoiceRec.app" 140 200
    --hide-extension "localVoiceRec.app"
    --app-drop-link 400 200
    --no-internet-enable
)

if [[ -f "$VOL_ICON" ]]; then
    CREATE_DMG_ARGS+=(--volicon "$VOL_ICON")
fi

# create-dmg は内部で AppleScript を使うので、まれに Finder 競合で失敗する。
# 失敗時は 1 回だけリトライ。
if ! create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$APP"; then
    echo "(warn) create-dmg failed, retrying once..."
    sleep 2
    rm -f "$DMG_PATH"
    create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$APP"
fi

# DMG 自体の署名 (任意)。Developer ID Application 証明書がある場合のみ成功する
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "==> codesign DMG with Developer ID Application: $DEVELOPMENT_TEAM"
    codesign --sign "Developer ID Application: ${DEVELOPMENT_TEAM}" "$DMG_PATH" \
        2>/dev/null || echo "(warn) DMG codesign skipped (no matching identity)"
fi

# DMG を staple する (中身の .app は既に staple 済みなので、失敗しても致命的ではない)
xcrun stapler staple "$DMG_PATH" \
    2>/dev/null || echo "(warn) stapler on dmg skipped — .app は staple 済みなので可"

echo "==> SHA256:"
shasum -a 256 "$DMG_PATH"

echo "OK: $DMG_PATH"
