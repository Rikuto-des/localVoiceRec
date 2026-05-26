#!/usr/bin/env bash
# build → notarize → dmg のワンショット
#
# 必須 env:
#   DEVELOPMENT_TEAM, APPLE_ID, APP_PASSWORD, TEAM_ID
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/build-release.sh"
"$DIR/notarize.sh"
"$DIR/make-dmg.sh"
