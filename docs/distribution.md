# Distribution Guide — `localVoiceRec`

自前サイトで `.dmg` を配布するためのビルド・署名・公証・パッケージング手順。
**自動更新 (Sparkle 等) は導入しない**。バージョンアップは手動再ダウンロード方式。

---

## 1. 配布フロー概要

```
┌──────────────┐    ┌────────────┐    ┌──────────────┐    ┌──────────────┐    ┌─────────────┐
│ 1. Build      │ →  │ 2. Notarize │ →  │ 3. Make DMG   │ →  │ 4. Upload     │ →  │ 5. User DL  │
│ build-release │    │ notarize.sh │    │ make-dmg.sh   │    │ 自前 Web      │    │ + Install   │
└──────────────┘    └────────────┘    └──────────────┘    └──────────────┘    └─────────────┘
       ↓                  ↓                   ↓                   ↓                    ↓
   .app (signed)    .app (stapled)     .dmg (signed +       配布ページ更新       /Applications
                                       stapled)             + SHA256 掲載        にドラッグ
```

ワンショット実行:

```bash
./scripts/all.sh
```

---

## 2. 事前準備

### 2.1 Apple Developer アカウント

- 個人 or 法人の Apple Developer Program 加入 (年額 $99)
- Team ID (10 文字英数) を控える

### 2.2 証明書

1. Xcode → Settings → Accounts で Apple ID をサインイン
2. Team を選び **Manage Certificates** → **+** → **Developer ID Application**
3. Keychain Access で `Developer ID Application: <Your Name> (TEAM_ID)` が登録されていることを確認

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2.3 app-specific password

1. https://appleid.apple.com にログイン
2. **サインインとセキュリティ** → **App 用パスワード** → **+ 生成**
3. ラベル: `localVoiceRec-notarytool` 等
4. 表示された `xxxx-xxxx-xxxx-xxxx` を控える（再表示不可）

### 2.4 環境変数

`~/.zshrc` などに記載するか、リリース時に export する:

```bash
export APPLE_ID="you@example.com"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
export TEAM_ID="XXXXXXXXXX"                  # 10 文字の Team ID
export DEVELOPMENT_TEAM="XXXXXXXXXX"         # 同じく Team ID
```

> **Note**: シェル履歴に残らないように `read -s` で入力するか、`keychain-profile` 方式 (`xcrun notarytool store-credentials`) を推奨。本リポジトリでは env var 方式を採用。

---

## 3. ビルド・配布手順

### 3.1 ワンショット

```bash
./scripts/all.sh
ls dist/    # localVoiceRec-0.1.0.dmg
```

### 3.2 個別ステップ

```bash
# (a) Release ビルド → dist/localVoiceRec.app
./scripts/build-release.sh

# (b) Notarize + staple
./scripts/notarize.sh

# (c) DMG 生成
./scripts/make-dmg.sh
```

### 3.3 検証

```bash
# 公証されているか
spctl --assess --type execute -vv dist/localVoiceRec.app
# 期待: accepted, source=Notarized Developer ID

# 署名内容
codesign -dvv --entitlements - dist/localVoiceRec.app

# SHA256 (配布ページ掲載用)
shasum -a 256 dist/localVoiceRec-*.dmg
```

---

## 4. 自前サイトでのダウンロードページ

### 4.1 HTML 雛形

```html
<section>
  <h2>localVoiceRec v0.1.0 ダウンロード</h2>
  <p>macOS 26 (Tahoe) 以降 / Apple Silicon 専用</p>
  <a href="/downloads/localVoiceRec-0.1.0.dmg" class="download-btn">
    localVoiceRec-0.1.0.dmg をダウンロード
  </a>

  <h3>ファイル検証</h3>
  <p>ダウンロード後、SHA-256 を照合してください:</p>
  <pre><code>shasum -a 256 ~/Downloads/localVoiceRec-0.1.0.dmg</code></pre>
  <p>期待値: <code>b040ff94...（リリース毎に更新）</code></p>
</section>
```

### 4.2 運用ルール

- DMG ファイル名は **必ずバージョン番号を含める** (`localVoiceRec-{version}.dmg`)
- 配布ページに **SHA-256** を必ず掲載
- 過去バージョンも一定期間アーカイブ（ロールバック用）

---

## 5. 初回起動時の Gatekeeper 対応

公証済み DMG であれば、原則として macOS の Gatekeeper はそのまま通る。
ただし、ユーザー環境のポリシーや破損で警告が出るケースもあるためサポート手順を用意する。

### 5.1 検証コマンド（ユーザー向け）

```bash
spctl --assess --type execute -vv /Applications/localVoiceRec.app
# OK 例: accepted, source=Notarized Developer ID
```

### 5.2 「開発元が未確認のため開けません」が出た場合

| 状況 | 対処 |
|---|---|
| 通常 (たまに発生) | Finder で `.app` を **右クリック → 開く** → 「開く」 |
| Quarantine 属性が残っている | `xattr -d com.apple.quarantine /Applications/localVoiceRec.app` |
| 署名が壊れた (DMG コピー失敗等) | DMG を再ダウンロード、SHA-256 を再照合 |

---

## 6. バージョン管理

`App/Info.plist` の以下を更新してから build する。`make-dmg.sh` がここを読み取り、DMG ファイル名にバージョンを含める。

- `CFBundleShortVersionString` — ユーザー向け表示版 (`0.1.0`, `0.2.0` など)
- `CFBundleVersion` — ビルド番号 (毎ビルドでインクリメント)

> 本ドキュメントでは `App/Info.plist` の編集権限なし。S5-A 以前のフェーズで対応済みであることを前提とする。

---

## 7. トラブルシュート

### 7.1 `notarytool submit` がタイムアウト / Invalid

```bash
# 過去のログを取得
xcrun notarytool log <submission-id> \
    --apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID"
```

主な失敗原因:

- Hardened Runtime が無効 (`flags=0x10002(adhoc,runtime)` を確認)
- 署名漏れの dylib/framework (`codesign --verify --deep --strict` で事前検査)
- entitlements の整合性
- Info.plist に `LSMinimumSystemVersion` 不在

### 7.2 証明書失効

`security find-identity -v -p codesigning` で `CSSMERR_TP_CERT_REVOKED` 等が出たら、Apple Developer Portal で証明書を再発行 → Keychain に取り込み直す。

### 7.3 Hardened Runtime によるクラッシュ

dylib injection や JIT を使うコードがあると、Hardened Runtime で起動時に Killed:9。本アプリは該当なしだが、追加 dylib を入れる場合は以下の entitlement を検討:

- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

セキュリティポスチャに影響するため、**追加する場合は `docs/security-audit.md` の更新が必須**。

### 7.4 `codesign` の "resource fork, Finder information, or similar detritus not allowed"

iCloud Drive / Desktop 配下にプロジェクトがあると、File Provider が `com.apple.FinderInfo` や `com.apple.fileprovider.fpfs#P` xattr を付与してしまい、xcodebuild 内蔵 CodeSign 段階で落ちる。

`scripts/build-release.sh` では以下で回避済み:

1. `xcodebuild` に `CODE_SIGNING_ALLOWED=NO` を渡してビルドのみ実行
2. `xattr -cr dist/localVoiceRec.app` で xattr を全削除
3. `codesign --force --options runtime --entitlements ... --sign "Developer ID Application: ..."` で改めて署名

### 7.5 DMG の staple が `Error 65`

```
CloudKit query ... failed due to "Record not found".
```

→ DMG 内の `.app` が **まだ公証されていない** ことを示す。先に `notarize.sh` を回して `.app` を staple 済みにすること。
DMG 自体の staple は **任意**（中の `.app` が staple 済みなら、オフライン環境でも Gatekeeper を通る）。

---

## 8. 関連ドキュメント

- [`release-checklist.md`](release-checklist.md) — リリース毎にチェックする項目
- [`security-audit.md`](security-audit.md) — 配布前のセキュリティ検証 (読み取り専用)
- [`spec.md`](spec.md) — 仕様書
