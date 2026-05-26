# localVoiceRec アーキテクチャ

> S0 (Bootstrap + Contract 凍結) で確定した設計。S2 以降の並列開発における **契約** を明文化する。

## モジュール構成

| モジュール | 役割 | 依存 |
|---|---|---|
| **Contracts** | プロトコル / 値型 DTO / Mock 実装 | なし |
| **AudioTapKit** | Core Audio process tap + AVAudioEngine の薄いラッパ | Contracts |
| **AudioCapture** | `AudioCaptureService` の本番実装 (2ch 録音 + 権限) | Contracts, AudioTapKit |
| **DataStore** | SwiftData `@Model` + `RecordingRepository` 実装 | Contracts |
| **TranscriptionKit** | SpeechAnalyzer による `TranscriptionService` 実装 | Contracts |
| **SummaryKit** | Foundation Models による `SummaryService` 実装 | Contracts |
| **AppUI** | `MenuBarExtra` + ビュー群 (Contract のみ依存) | Contracts |
| **AudioTapPoC** | Phase 0 PoC CLI (executable) | AudioTapKit |

すべて SwiftPM のローカルパッケージ。`.app` バンドル化は `localVoiceRec.xcodeproj` が SPM パッケージ + `App/` 配下の `LocalVoiceRecApp.swift` / `Info.plist` / `localVoiceRec.entitlements` を取り込んで行う。

## Contract 凍結ファイル一覧（**並列フェーズ中の編集禁止**）

S0 以降、以下のファイルは **オーケストレータの承認なしに編集してはならない**。各サブエージェントのプロンプトに明記する。

```
Sources/Contracts/
├── DTO/
│   ├── Recording.swift
│   ├── TranscriptSegment.swift
│   └── SummaryDocument.swift
├── AudioCaptureService.swift
├── TranscriptionService.swift
├── SummaryService.swift
├── RecordingRepository.swift
└── Mocks/
    ├── InMemoryRecordingRepository.swift
    ├── FakeAudioCaptureService.swift
    ├── FakeTranscriptionService.swift
    ├── FakeSummaryService.swift
    └── SampleData.swift
```

加えて以下も S2 並列中は触らない:
- `Package.swift`（モジュール追加・依存変更はオーケストレータ専管）
- `App/Info.plist`
- `App/localVoiceRec.entitlements`
- `localVoiceRec.xcodeproj/`

## モジュール責任分界

### 1. AudioCapture (S2-A)
- `Sources/AudioCapture/` 配下を編集可
- `AudioCaptureService` を実装した `AudioCaptureServiceImpl`（actor）を提供
- `AudioTapKit` を経由してハードウェアを叩く
- 2 つの WAV ファイルを書き出す（生のフォーマットを保持、変換は TranscriptionKit 側）

### 2. DataStore (S2-B)
- `Sources/DataStore/` 配下を編集可
- SwiftData `@Model`（`RecordingEntity`, `SegmentEntity`, `SummaryEntity`）を **モジュール内に閉じる**
- 公開 API は `RecordingRepository` プロトコル経由のみ（戻り値・引数は Contracts 配下の DTO）
- `ModelContainer` は `ModelConfiguration(cloudKitDatabase: .none)` を使う

### 3. AppUI (S2-C)
- `Sources/AppUI/` 配下を編集可
- **SwiftData `@Model` 型を直接 import してはならない**（DataStore モジュールに依存しない）
- 依存は `Contracts` のみ
- Previews は `InMemoryRecordingRepository` + `FakeXxxService` を使う
- 進捗イベントの switch には `default` を必ず書く（Contract enum 追加耐性）

### 4. TranscriptionKit (S2-D)
- `Sources/TranscriptionKit/` 配下を編集可
- `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` で取得した format に
  `AVAudioConverter` で変換してから流す
- 2 つの `SpeechTranscriber` を **同一 locale / preset** で生成（バックエンド共有）

### 5. SummaryKit (S4)
- `Sources/SummaryKit/` 配下を編集可
- `SystemLanguageModel.default.availability` を尊重し、UI に状態を伝える
- `prewarm()` は実推論の 1 秒以上前に呼ぶ

## エラー伝播ルール

- 各 service は自モジュールの `*Error` を throw する
- UI 側は `Error` で受け、表示用文字列に変換するヘルパを `AppUI` 内に持つ
- ロギングは `Logger`（os.log）。ファイル出力なし（プライバシー要件）

## イベントストリーム規約

| ストリーム | 型 | 終了条件 |
|---|---|---|
| `AudioCaptureService.state` | `AsyncStream<CaptureState>` | actor 解放時 |
| `TranscriptionService.transcribe(...)` | `AsyncThrowingStream<TranscriptSegment, Error>` | EOF or error |

## サンプルレート / フォーマット

- **キャプチャ時**: ハードウェア由来の format を尊重（44.1k / 48k / 16k のいずれか想定）
- **WAV 書き出し**: キャプチャ時の format をそのまま保存（変換は推論時に行う）
- **SpeechAnalyzer 入力時**: `bestAvailableAudioFormat(compatibleWith:)` で取得した format に
  `AVAudioConverter` で変換
- **絶対にやらないこと**: 16kHz 等の固定値を contract や実装にハードコードする

## ネットワーク禁止の保証

- `App/localVoiceRec.entitlements` に **`network.client` / `network.server` を含めない**
- S5 で `codesign --display --entitlements -` の出力を証跡保存
- Asset DL（SpeechAnalyzer 初回ロケール DL）はユーザー操作なしには発生しない設計
  （実装は `installedLocales` を優先）

## 参照

- 仕様: [spec.md](spec.md)
- API 詳細: [api-references.md](api-references.md)
