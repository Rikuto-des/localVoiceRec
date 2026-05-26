#!/usr/bin/env bash
# .app から配布用 .dmg を作る (Applications シンボリックリンク付き)
#
# 使い方:
#   ./scripts/make-dmg.sh
#
# 任意 env:
#   DEVELOPMENT_TEAM  Developer ID Application 証明書の Team ID（DMG 自体も署名する場合）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP="dist/localVoiceRec.app"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP が無い。先に ./scripts/build-release.sh を実行" >&2
    exit 1
fi

DMG_DIR="$(mktemp -d)"
trap 'rm -rf "$DMG_DIR"' EXIT

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG_NAME="localVoiceRec-${VERSION}.dmg"
DMG_PATH="dist/$DMG_NAME"

echo "==> staging .app and /Applications symlink in $DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

echo "==> hdiutil create $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create -volname "localVoiceRec ${VERSION}" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# DMG 自体の署名（任意）。Developer ID Application 証明書がある場合のみ成功する
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "==> codesign DMG with Developer ID Application: $DEVELOPMENT_TEAM"
    codesign --sign "Developer ID Application: ${DEVELOPMENT_TEAM}" "$DMG_PATH" \
        2>/dev/null || echo "(warn) DMG codesign skipped (no matching identity)"
fi

# DMG を staple する（中身の .app は既に staple 済みなので、失敗しても致命的ではない）
xcrun stapler staple "$DMG_PATH" \
    2>/dev/null || echo "(warn) stapler on dmg skipped — .app は staple 済みなので可"

echo "==> SHA256:"
shasum -a 256 "$DMG_PATH"

echo "OK: $DMG_PATH"
