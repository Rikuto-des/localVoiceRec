# localVoiceRec

会議を Mac 上で録音し、デバイス内で文字起こし・構造化要約まで完結させる macOS ネイティブアプリ。

**音声・文字起こし・要約のすべてを端末内で処理し、データを一切外部に送信しない。** ネットワーク権限を持たないため、技術的に外部通信できません。

## 要件

- macOS 26 (Tahoe) 以降
- Apple Silicon（M1 以降）

## 技術スタック

| レイヤー | 採用技術 |
|---|---|
| 言語 | Swift |
| UI | SwiftUI（MenuBarExtra） |
| 収音 | AVAudioEngine + Core Audio process tap |
| 文字起こし | SpeechAnalyzer（macOS 26 標準） |
| 要約 | Foundation Models（オンデバイス） |
| 永続化 | SwiftData |

## ドキュメント

- [仕様書](docs/spec.md)
- [配布手順](docs/distribution.md)
- [Cloudflare Pages サイト構築手順](docs/cloudflare-pages-setup.md)

## 配布サイト

`site/` 配下に静的サイト（HTML/CSS のみ、ビルド不要）。Cloudflare Pages にデプロイして
`.dmg` のダウンロードページとして公開する。詳細は
[`docs/cloudflare-pages-setup.md`](docs/cloudflare-pages-setup.md)。

## 配布版のインストール

1. 配布サイトから `localVoiceRec-<version>.dmg` をダウンロード
2. 公開されている SHA-256 と一致するか確認:
   ```bash
   shasum -a 256 ~/Downloads/localVoiceRec-<version>.dmg
   ```
3. DMG を開き、`localVoiceRec.app` を `Applications` フォルダにドラッグ
4. 初回起動で Gatekeeper 警告が出た場合は [`docs/distribution.md`](docs/distribution.md) の「初回起動時の Gatekeeper 対応」を参照

リリース担当者向けのビルド・公証・パッケージング手順は [`docs/distribution.md`](docs/distribution.md) を参照。

## 開発フェーズ

| フェーズ | 内容 |
|---|---|
| Phase 0 | システム音声 2ch 取得の技術検証（PoC） |
| Phase 1 | 録音 + ローカル保存 + 一覧 |
| Phase 2 | SpeechAnalyzer による文字起こし |
| Phase 3 | Foundation Models による構造化要約 |
| Phase 4 | セキュリティ硬化・配布・署名/公証 |

---

*すべての処理は端末内で完結します。*
