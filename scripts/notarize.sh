#!/usr/bin/env bash
# .app を notarytool で公証 → stapler でステープリング
#
# 必須 env:
#   APPLE_ID     Apple ID メールアドレス
#   APP_PASSWORD app-specific password (appleid.apple.com で発行)
#   TEAM_ID      Developer Team ID (10 文字)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${APPLE_ID:?Set APPLE_ID env}"
: "${APP_PASSWORD:?Set APP_PASSWORD env (app-specific password)}"
: "${TEAM_ID:?Set TEAM_ID env}"

APP="dist/localVoiceRec.app"
ZIP="dist/localVoiceRec.zip"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: $APP が無い。先に ./scripts/build-release.sh を実行" >&2
    exit 1
fi

echo "==> ditto: $APP -> $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarytool submit (wait)"
xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

echo "==> stapler staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "OK: notarization + stapling complete"
