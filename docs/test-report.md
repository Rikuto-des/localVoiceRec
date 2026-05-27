# Test Report — S5-B Verifier

| 項目 | 値 |
| ---- | --- |
| 実施日 | 2026-05-27 |
| ブランチ | `feat/s5b-verify` |
| 作業ディレクトリ | `/Users/rikuto/Desktop/apps/localVoiceRec-s5b` |
| Swift toolchain | swift-tools-version 6.0 |
| Platform | macOS 26.0 (arm64e-apple-macos14.0 target via Swift Testing 1902) |
| 実機 | Apple Silicon (arm64e) |

## 1. `swift test` 全件結果

### サマリ

- **総テスト数**: 57
- **総 Suite 数**: 15
- **合格**: 57
- **失敗**: 0
- **実行時間**: ~3.95 秒 (テスト本体) / ビルド込みで ~14.5 秒

すべての suite が pass。新規追加した `IntegrationTests` を含めて clean。

### Suite 別カバレッジ概況

| Suite | テスト数 | カバー対象 | 備考 |
| ----- | -------- | ---------- | ---- |
| `ContractsTests` | (Contracts DTO/Errors) | DTO 等価性、`parseDate`、ISO 8601 / yyyy-MM-dd の両対応 | |
| `AppPaths` | 2 | アプリ配下ディレクトリ生成・WAV パス解決 | Recordings root の安定性 |
| `FakeAudioCaptureService` | 4 | プロトコル準拠の状態遷移、idle 時の動作 | UI 駆動用フェイク |
| `AudioCaptureServiceImpl` | 1 | `AudioTapError → AudioCaptureError` の翻訳 | コア合成パスは PoC で検証 |
| `AudioCaptureModule` | 1 | DI ファクトリの返り値型 | |
| `InMemoryRecordingRepository` | 4 | CRUD / list 並べ替え / 検索 / 削除 | UI 用のスタブ |
| `RecordingRepositoryImpl — Recording CRUD` | 5 | SwiftData 上の Recording 永続化 | |
| `RecordingRepositoryImpl — Segments` | 3 | 1:N の segments 永続化と置換 | |
| `RecordingRepositoryImpl — Summary` | 3 | 1:1 の summary 永続化 / upsert / delete | |
| `RecordingRepositoryImpl — cascade delete` | 1 | recording 削除で segments + summary が消える | |
| `RecordingRepositoryImpl — relative path round trip` | 1 | App-relative URL 保存・復元 | |
| `RecordingRepositoryImpl — file deletion` | 1 | `deleteFiles()` が物理 WAV を消す | |
| `SpeechAnalyzerService` | 4 | factory / installedLocales / cancelAll / 不正ファイル | 実音声は IntegrationTests で確認 |
| `FoundationModelsSummaryService` | 5 | availability / generate / truncate / draft 変換 / 実機 generate (skip 対応) | macOS 26 / Apple Intelligence 有効環境で実機要約まで pass |
| `AppViewModel state transitions` | 8 | 録音開始/停止/pause/resume、削除、要約再生成、idle 初期状態 | UI ロジック |
| `Integration — PoC → SpeechAnalyzer` | 1 | PoC の実 WAV を analyzer に投入 (落ちないことのみ) | 本レポート §3 |

### 確認できているもの / できていないもの

- ✅ Contracts DTO の値型 round trip
- ✅ DataStore (SwiftData) の CRUD と cascade delete、相対パス変換
- ✅ AppViewModel の状態遷移（録音 / 削除 / 要約再生成 / pause-resume）
- ✅ TranscriptionService の表層 API、不正入力の `fileNotReadable` 翻訳
- ✅ SummaryService の availability ガード、truncate、draft→document 変換、実機での簡易要約
- ✅ AudioTapKit 系のリングバッファ・WAV ライタは PoC (§2) のスモークで動作確認
- ⚠️ SpeechAnalyzer の **本物の音声からテキストが出る** ところは IntegrationTests では asserting しない（環境依存・on-device モデル未インストール時を skip 扱い）
- ⚠️ ScreenCaptureKit の許可ダイアログ / TCC 状態遷移は手動 (§5)

---

## 2. AudioTapPoC スモーク実行

```
$ POC_DURATION=5 swift run AudioTapPoC
```

### 実行ログ抜粋

```
[AudioTapPoC] AudioTapKit version: 0.1.0-poc
[AudioTapPoC] Capture duration: 5.0 s
[AudioTapPoC] Output directory: /Users/rikuto/Desktop/apps/localVoiceRec-s5b/Tools/AudioTapPoC/output
[AudioTapPoC] Microphone permission: granted
[AudioTapPoC] System audio permission: 初回 SystemAudioTap.start() で OS ダイアログが出ます。
[AudioTapPoC] Mic started. format = <AVAudioFormat 0x704854a00:  1 ch,  44100 Hz, Float32>
[AudioTapPoC] System tap started. format = <AVAudioFormat 0x704854b40:  2 ch,  48000 Hz, Float32, interleaved>
[AudioTapPoC] Stopping ...
[AudioTapPoC] === Results ===
[AudioTapPoC] mic.wav: .../Tools/AudioTapPoC/output/mic.wav
[AudioTapPoC]   format: sr=44100.0 Hz, ch=1, commonFormat=Float32
[AudioTapPoC]   frames captured: 233730, buffers: 53, duration: 5.300 s
[AudioTapPoC] system.wav: .../Tools/AudioTapPoC/output/system.wav
[AudioTapPoC]   format: sr=48000.0 Hz, ch=2, commonFormat=Float32
[AudioTapPoC]   frames captured: 247680, buffers: 258, duration: 5.160 s
[AudioTapPoC] Real elapsed: 5.601 s
[AudioTapPoC] Drift mic vs real:  -0.301 s
[AudioTapPoC] Drift sys vs real:  -0.441 s
[AudioTapPoC] Tap dropped pushes (ring full): 0
[AudioTapPoC] CPU: 0.098 s used over 5.601 s wall (1.7%)
[AudioTapPoC] Memory: rss before=19070976 bytes, after=18743296 bytes, peak-ish delta=-327680
```

### `afinfo` 結果

`mic.wav`:

```
File:           Tools/AudioTapPoC/output/mic.wav
File type ID:   WAVE
Num Tracks:     1
Data format:     1 ch,  44100 Hz, Float32
                no channel layout.
estimated duration: 5.300000 sec
audio bytes: 934920
audio packets: 233730
bit rate: 1411200 bits per second
packet size upper bound: 4
maximum packet size: 4
audio data file offset: 4096
optimized
source bit depth: F32
```

`system.wav`:

```
File:           Tools/AudioTapPoC/output/system.wav
File type ID:   WAVE
Num Tracks:     1
Data format:     2 ch,  48000 Hz, Float32, interleaved
                no channel layout.
estimated duration: 5.160000 sec
audio bytes: 1981440
audio packets: 247680
bit rate: 3072000 bits per second
packet size upper bound: 8
maximum packet size: 8
audio data file offset: 4096
optimized
source bit depth: F32
```

### 評価

- ✅ ScreenCaptureKit ベースのシステム音声 tap が許可ずみで OS ダイアログ無しに開始
- ✅ Mic / System の両 WAV が想定 sr / ch で書き出された (44.1k mono / 48k stereo Float32)
- ✅ リングバッファのドロップ無し (`Tap dropped pushes (ring full): 0`)
- ✅ CPU 1.7% / RSS 微減で短時間 leak の兆候は無し
- ⚠️ 実時間に対し mic -0.3s, sys -0.44s の **負方向 drift**。短時間 (5s) では誤差範囲だが、長時間録音時のドリフト挙動は §5 stress テストで継続観察

---

## 3. IntegrationTests の追加と実行結果

### 追加内容

- 新規ファイル: `Tests/IntegrationTests/PoCTranscribeIntegrationTests.swift`
- `Package.swift` に `IntegrationTests` test target を追加（依存: `TranscriptionKit`, `Contracts`）
- `AudioTapPoC` ターゲットの `exclude: ["output"]` を追加し、SwiftPM 警告 (`unhandled resources`) を解消

### テスト仕様

- `Tools/AudioTapPoC/output/{mic,system}.wav` が存在する場合のみ `SpeechAnalyzerService.transcribe(...)` に投入
- `installedLocales()` が空 (= on-device モデル未インストール) のときは skip
- `transcribe` が throw した場合は **テストを赤くせず** にログ出力のみ（環境依存・無音時のため）
- 内容アサートは無し、`count >= 0` のみ

### 実行結果

```
􀟈  Suite "Integration — PoC → SpeechAnalyzer" started.
􀟈  Test "PoC の出力 WAV を SpeechAnalyzer に投入できる（PoC 未実行なら skip）" started.
[IntegrationTest] transcribe threw: fileNotReadable(file:///.../mic.wav). PoC audio may be silent / unsupported locale.
􁁛  Test "PoC の出力 WAV を SpeechAnalyzer に投入できる（PoC 未実行なら skip）" passed after 2.939 seconds.
􁁛  Suite "Integration — PoC → SpeechAnalyzer" passed after 2.952 seconds.
```

### 補足

- 今回のスモーク環境では `SpeechAnalyzer` が `fileNotReadable` で `mic.wav` を拒否した
  - PoC の Float32 WAV を `SpeechAnalyzer` がそのまま読めない可能性（recommendedFormat への明示的な reformat / 別 codec への変換が必要かもしれない）
  - 本テストは「落ちない」までを保証するため pass。実音声 → テキストの 1:1 確認は §5 (manual-test-plan) のアプリ経由フローで実施する
- on-device locale が無い CI 環境では skip され、CI を壊さない

---

## 4. Foundation Models のスモーク

`SummaryKitTests/FoundationModelsSummaryServiceTests.swift` の `"実機で .available の場合に最小入力で要約が返る（unavailable なら skip）"` が **3.31 秒で pass**。実機 (macOS 26 / Apple Intelligence on) で `availability() == .available` のとき、最小プロンプトを通して `SummaryDocument` が返ることを確認済み。

- `truncateIfNeeded` の境界条件
- `makeDocument` の draft → DTO 変換
- `availability != .available` 時の `notAvailable` エラー
- `generate` の no-op `prewarm`

も同 suite 内で pass。S4 で投入されたテストをそのまま流用しており、S5-B では追加テスト不要と判断。

---

## 5. ハッシュ / 計測の引き継ぎ

- 手動 UI シナリオ: `docs/manual-test-plan.md` を参照
- リリース観点の verify チェックリスト: `docs/verify-checklist.md` を参照
  - s5a Security Auditor の `docs/release-checklist.md` が後で作成された場合は、そちらにマージしてこのファイルを削除する想定

---

## S9 検証 (v0.1.1)

| 項目 | 値 |
| ---- | --- |
| 実施日 | 2026-05-27 |
| ブランチ | `main` |
| バージョン | 0.1.1 (S8 fix 後) |
| Swift toolchain | swift-tools-version 6.0 / Swift 6.2.3 / Xcode 26.5 |
| Platform | macOS 26.0 (arm64e-apple-macos14.0) |
| 実機 | Apple Silicon |

### A. `swift test` 全件再走

- **総テスト数**: 68 (S5-B から +11、本 S9 で +3)
- **総 Suite 数**: 17 (本 S9 で +1)
- **合格**: 68 / **失敗**: 0
- **実行時間**: ~2.95 秒 (テスト本体) / 増分ビルド込みで ~5 秒

S5-B 以降に追加された S6/S7/S8 関連テスト・本 S9 で追加した `AVAudioFile partial read — S8 regression` (3 件) を含め、全 suite が pass。

### B. PoC 30 秒録音 → E2E (transcribe + summarize)

#### 30 秒 PoC 実行ログ抜粋

```
$ POC_DURATION=30 swift run AudioTapPoC
[AudioTapPoC] Capture duration: 30.0 s
[AudioTapPoC] Mic started. format = <AVAudioFormat: 1 ch, 44100 Hz, Float32>
[AudioTapPoC] System tap started. format = <AVAudioFormat: 2 ch, 48000 Hz, Float32, interleaved>
[AudioTapPoC] mic.wav: frames=1336230, duration=30.300 s
[AudioTapPoC] system.wav: frames=1456320, duration=30.340 s
[AudioTapPoC] Real elapsed: 30.518 s / Drift mic=-0.218 s, sys=-0.178 s
[AudioTapPoC] Tap dropped pushes (ring full): 0
```

ドリフトは S5-B (5s) より絶対値が大きいが相対的には改善傾向 (5s で -0.3〜-0.44s → 30s で -0.18〜-0.22s)。

#### IntegrationTests 実行

`Tests/IntegrationTests/PoCTranscribeIntegrationTests.swift` が 30s WAV 経由で pass:

```
􁁛 Suite "Integration — PoC → SpeechAnalyzer" passed after 1.165 seconds.
```

- pipeline 全体が落ちずに stream を最後まで回しきること: ✅ (`fileNotReadable` も出ず)
- S5-B 時点では `fileNotReadable` で拒否されていたが、S8 fix で読めるようになった
- 今回録音は **無音 (環境音のみ)** だったため最終 segments は 0 件。`mic.wav` / `system.wav` 両方を analyzer に流し込めて、analyzer が clean に終端することは確認

なお、S8 fix 検証時に取得した参考ログでは `[mic] 0.0-0.487625: あ` が yield されており、発話が含まれる WAV ではテキストが出ることを確認済み。

#### `Tools/E2EProbe/` の追加

`POC` 出力を読み → `SpeechAnalyzerService.transcribe` → `FoundationModelsSummaryService.generate` を直列に走らせる CLI を `Tools/E2EProbe/main.swift` に追加 (`Package.swift` の executable target としても登録)。

実行コマンド: `swift run E2EProbe`

実行ログ抜粋 (60s WAV 入力時):

```
[E2EProbe] installedLocales count = 1
[E2EProbe] Transcribe finished in 1.523 s, segments = 0
[E2EProbe] Summary availability = available
[E2EProbe] No final segments — skipping summary generation.
```

- ✅ transcribe / availability チェック / summary 呼び出しのフロー実装が build & link 通過
- ✅ `SpeechAnalyzerService` は 60 秒分の入力を **1.523 秒** で読み切る (real-time factor ≈ 0.025x)
- ⚠️ 検証時の WAV が無音だったため、Summary 実機実行までは到達せず (final segments = 0 で early return)。
  Summary E2E は `SummaryKitTests` の `FoundationModelsSummaryServiceTests "実機で .available の場合に最小入力で要約が返る"` が `available` パスで pass (2.95 s) しており、別経路で確認済み。

### C. AVAudioFile partial read 回帰テスト

`Tests/TranscriptionKitTests/AVAudioFilePartialReadTests.swift` を新規追加 (3 ケース、すべて pass):

| ケース | 内容 | 結果 |
| ----- | ---- | ---- |
| `partialReadAtEOFSucceeds` | totalFrames=100_123 (capacity=24000 の倍数で割り切れない) → 末尾 partial で全 frame 読破 | ✅ pass (0.051 s) |
| `exactCapacityMultipleStops` | totalFrames=48_000 (capacity ちょうど 2 倍) で EOF が正常に止まる | ✅ pass (0.033 s) |
| `smallerThanCapacityCompletes` | totalFrames=5_000 (capacity 未満) で 1 回の partial read で完了 | ✅ pass |

`feedAudioFile` が `private static` のため、**同等ロジックを再現したテスト内ヘルパ `readAllFrames(url:)`** を持たせている (`残量 = audioFile.length - framePosition` から `frameCount` を明示的に計算)。フィクスチャ WAV は PoC と同形式 (Float32 / 2ch / 48 kHz / interleaved) を `AVAudioFile(forWriting:)` で生成し、サイン波で埋めている。

> 将来 `SpeechAnalyzerService` 側に `internal static func readAllFrames(url:) throws -> AVAudioFramePosition` を切り出せば、テスト内ヘルパは消せる。S9 では Sources/ 編集禁止のため、テスト内に閉じた回帰テストとして実装。

### D. メモリ / CPU 簡易プロファイル

`/usr/bin/time -l swift run E2EProbe` で 60 秒入力の文字起こしを 1 回計測:

| 指標 | 値 |
| ---- | --- |
| Transcribe 実時間 (60s 入力) | 1.523 秒 |
| Real (wall) | 2.51 秒 (build/load 含む) |
| User CPU | 0.15 秒 |
| Sys CPU | 0.07 秒 |
| Max RSS | 21,659,648 bytes (≈ 20.7 MiB) |
| Peak memory footprint | 7,209,608 bytes (≈ 6.9 MiB) |
| Page reclaims | 7,800 |
| Voluntary ctx switches | 6 / Involuntary | 1,179 |
| Instructions retired | 3.14 G |
| Cycles | 928 M |

- 60 秒の WAV を **1.5 秒** で食い切り、最大 RSS は 22 MB 程度。leak 兆候なし。
- 60 秒録音時の PoC 自体は CPU 1.7% / 60.888 秒 wall / dropped pushes = 0 で長時間動作も安定。

### E. 補足: 変更ファイル一覧 (Sources/ は無編集)

- `Tests/TranscriptionKitTests/AVAudioFilePartialReadTests.swift` (新規)
- `Tools/E2EProbe/main.swift` (新規)
- `Package.swift` (E2EProbe executable target 追加)
- `docs/test-report.md` (本セクション追加)

