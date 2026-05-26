# Verify Checklist — Pre-release (S5-B 観点のみ)

> このファイルは S5-A Security Auditor が `docs/release-checklist.md` を作成した時点で **そちらにマージしてこのファイルは削除する**前提。
> 現時点 (`feat/s5b-verify` 作成時) では `docs/release-checklist.md` が未存在のため、verify 観点だけを独立して残しておく。

## 1. 自動テスト

- [ ] `swift test` がローカルで 57/57 pass する (`docs/test-report.md` §1 参照)
- [ ] テスト実行に **新規警告が出ていない** (`unhandled resources` 等)
- [ ] FoundationModels の **実機 generate** テスト (`実機で .available の場合に最小入力で要約が返る`) が pass している (skip ではなく実行されている) ことを確認
- [ ] `IntegrationTests` (`PoCTranscribeIntegrationTests`) が pass している
  - PoC 出力が無い CI 環境では skip でも OK

## 2. PoC スモーク

- [ ] `POC_DURATION=5 swift run AudioTapPoC` が完走する
- [ ] `Tools/AudioTapPoC/output/{mic,system}.wav` が生成される
- [ ] `afinfo` で 想定 sr/ch (44.1k mono, 48k stereo Float32) が出る
- [ ] `Tap dropped pushes (ring full): 0` であること
- [ ] CPU < 10%、RSS の delta が ~MB オーダーに収まること

## 3. 手動 UI 検証

- [ ] `docs/manual-test-plan.md` のシナリオ 1〜5 を一通り pass
- [ ] シナリオ 6 (1 時間 stress) は **リリース前に最低 1 回** 実施し、結果を PR に貼る

## 4. ビルド / Xcode

- [ ] `App/Info.plist` の `NSMicrophoneUsageDescription` / `NSAudioCaptureUsageDescription` が日本語で記載されている
- [ ] `App/localVoiceRec.entitlements` に必要な entitlement のみ宣言されている
  - （詳細は S5-A の security-audit / release-checklist 側）
- [ ] `LSUIElement = true` で Dock アイコンが出ないこと
- [ ] `LSMinimumSystemVersion = 26.0` であること
- [ ] アプリ Bundle ID と TCC 表示名の整合（手動で System Settings 上で確認）

## 5. 動作環境マトリクス

最低限 verify されるべき環境:

| 環境 | OS | Apple Intelligence | 期待 |
| ---- | -- | ------------------ | ---- |
| Primary | macOS 26.0+ / Apple Silicon | ON | 全機能動作 |
| Secondary | macOS 26.0+ / Apple Silicon | OFF | 要約のみ `notAvailable` エラー表示 (クラッシュしない) |
| Edge | macOS 26.0+ / on-device locale 未インストール | ON | 文字起こしが `unsupportedLocale` を出し、UI がクラッシュしない |

## 6. リグレッション

- [ ] 一度 Recording を作成 → アプリ再起動 → 一覧に出る (SwiftData 永続化)
- [ ] 録音中にアプリを強制終了 → 再起動後にゾンビ WAV が残らない (or 残っても UI から削除できる)
- [ ] 削除した Recording のディレクトリが Finder 上から消えていることを目視確認

## 7. ドキュメント

- [ ] `docs/test-report.md` が最新の `swift test` 結果を反映している
- [ ] `docs/manual-test-plan.md` の手順が現在の UI 実装と合致している
- [ ] (s5a 側) `docs/security-audit.md` / `docs/release-checklist.md` が存在する場合、本ファイルの内容をそちらにマージ

## 8. 既知の未確認事項 / 持ち越し

- ⚠️ `SpeechAnalyzer` が PoC が出力する Float32 WAV をそのまま読めない可能性。IntegrationTests では `fileNotReadable` が観測された。
  → アプリ本体経由 (録音 → analyzer) では Float32 から `recommendedFormat` への変換が `SpeechAnalyzerService` 内で行われていれば問題なし。手動 UI 検証 (シナリオ 3) で確認する。
- ⚠️ 短時間 (5s) でも mic / system に 0.3〜0.4s の負方向 drift。1 時間 stress (シナリオ 6) で線形増加の有無を確認。
