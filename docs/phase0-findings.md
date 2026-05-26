# Phase 0 — Audio Capture PoC 結果

> S1 (Audio Specialist) の Phase 0 PoC 検証ログ。
> ブランチ: `feat/s1-audio-poc`
> 実機: Apple Silicon (Mac16,8), macOS 26.2 (25C56), Xcode 26.5, Swift 6
> 日時: 2026-05-27

## 1. 動作確認結果

**結果: 成功** (mic.wav / system.wav とも生成、`afinfo` で WAV として正常認識)

- ビルド: `swift build` 成功 (warning 0、error 0)
- PoC バイナリ: `/Users/rikuto/Desktop/apps/localVoiceRec-s1/.build/debug/AudioTapPoC`
- 実行: `POC_DURATION=30 .build/debug/AudioTapPoC` で 30 秒キャプチャ → 終了コード 0

## 2. 出力 WAV 仕様 (`afinfo` 抜粋, 30 秒キャプチャ時)

### mic.wav
```
File type ID:   WAVE
Data format:    1 ch, 44100 Hz, Float32 (non-interleaved)
estimated duration: 30.300000 sec
audio bytes:    5,344,920
audio packets:  1,336,230
bit rate:       1,411,200 bps
source bit depth: F32
```

### system.wav
```
File type ID:   WAVE
Data format:    2 ch, 48000 Hz, Float32, interleaved
estimated duration: 30.360000 sec
audio bytes:    11,658,240
audio packets:  1,457,280
bit rate:       3,072,000 bps
source bit depth: F32
```

**重要**: マイクと system audio は **サンプルレートが異なる** (44.1 kHz vs 48 kHz)。
WAV 自体は別ファイルなので問題なし。SpeechAnalyzer に渡す前に `AVAudioConverter` で
`bestAvailableAudioFormat(compatibleWith:)` 形式へ各々変換する設計 (S2-D 責務)。

## 3. 同期メトリクス

30 秒キャプチャ実測:

| 指標 | 値 |
|---|---|
| Real elapsed (wall clock) | 30.538 s |
| mic.wav 録音長 | 30.300 s |
| system.wav 録音長 | 30.360 s |
| mic vs real drift | -0.238 s (mic が短い) |
| system vs real drift | -0.178 s (sys が短い) |
| mic vs system drift | -0.060 s (mic が 60 ms 早く終わる) |
| Ring buffer push 失敗 | 0 回 |

### drift の解釈

- **wall clock vs WAV duration**: `30.538 - 30.300 = 0.238 s` のうち大部分は
  「stop 要求 → 各 Task の自然終了 → stop_writer → `Date()` 取得」の事務作業時間。
  キャプチャエンジン自体のドリフトは数十 ms オーダー (mic vs sys の 60 ms 程度) と見るのが妥当。
- **mic vs system の 60 ms**: 別々のハードウェアクロック (内蔵マイク AD と aggregate device)
  で動くので、互いに drift する。S2-A 本実装では、`AVAudioPCMBuffer` に付随する
  `AVAudioTime` (mic 側) と IOProc の `inInputTime` (system audio 側) を時刻情報として保存し、
  Transcribe 時に整合させる方針が良い (本 PoC では収録のみで時刻は使っていない)。

### 短時間 (3s) ランの drift も同オーダー

| 指標 | 3s 値 |
|---|---|
| Real elapsed | 3.207 s |
| mic duration | 3.000 s |
| system duration | 3.040 s |

→ drift は時間に比例しない (定数オーダー)。30 秒で十分小さい (< 1 %)。

## 4. 権限ダイアログの挙動

- **マイク (NSMicrophoneUsageDescription)**:
  - CLI は SwiftPM `executableTarget`。binary に Info.plist 未埋め込みでも、
    親プロセスが `Terminal.app` (or `claude`) で **そのアプリにマイク権限がすでに付与されている**
    場合、`AVCaptureDevice.requestAccess(for: .audio)` は granted を即返す。
  - 今回は親プロセス `claude` (com.anthropic.claudefordesktop) のマイク権限が既に許可されていたため、
    PoC からは追加ダイアログは出なかった。
  - **S2 本番アプリ** では `App/Info.plist` の `NSMicrophoneUsageDescription` が必須 (S0 で配置済み)。

- **システム音声 (NSAudioCaptureUsageDescription)**:
  - `AudioHardwareCreateProcessTap` + `AudioDeviceStart` は **追加プロンプト無しで成功** した。
  - これは親プロセス由来の permission inherit 挙動と推測される (TCC のレスポンシブルプロセス)。
    クラッシュレポートでも `responsibleProc: claude` となっており、permission は
    `claude` のものが使われている。
  - **本番アプリでは初回 `AudioDeviceStart` で System Audio Recording 権限プロンプトが出る** はず
    (公式 doc 通り)。`App/Info.plist` の `NSAudioCaptureUsageDescription` も S0 で配置済み。
  - **未確定** だった「Process Tap の正式 TCC サービス定数名」は今回も不明 (実機 prompt が出なかったため)。

## 5. CPU / メモリ

| 指標 | 30 秒ランの値 |
|---|---|
| CPU time used | 0.532 s |
| Wall clock | 30.538 s |
| CPU 使用率 (= cpu/wall) | **1.7 %** |
| RSS 開始 | 18,628,608 bytes (≈ 17.8 MB) |
| RSS 終了 | 18,628,608 bytes |
| Δ RSS | 0 bytes (リーク観測なし) |

- CPU 1.7 % は consumer task (ring polling 5 ms 周期 + memcpy) と AVAudioEngine の
  常駐コストの合計。Process Tap 自体の負荷は無視できる。
- メモリは安定。SPSC ring buffer は最初に 1 回 allocate するだけで再アロケート無し。
  AVAudioPCMBuffer は consumer 側で生成し、`AVAudioFile.write` 後即解放される。

## 6. ハマりどころ・公式 doc になかった注意点

### a. `CATapDescription` の Swift API 名

公式 doc は Objective-C ヘッダのみ記載。実際の Swift 名はこう:

```swift
// ObjC: initStereoGlobalTapButExcludeProcesses:
// Swift:
CATapDescription(stereoGlobalTapButExcludeProcesses: [AudioObjectID])
// 同様に
CATapDescription(stereoMixdownOfProcesses: [AudioObjectID])
CATapDescription(monoGlobalTapButExcludeProcesses: [AudioObjectID])
CATapDescription(monoMixdownOfProcesses: [AudioObjectID])
```

空配列を `stereoGlobalTapButExcludeProcesses` に渡すと **全プロセスをタップ** する
(除外プロセスゼロ)。今回はこれを採用。

### b. `CATapMuteBehavior` の Swift import

Swift では `.unmuted` のようなドットシンタックスが効かない (NS_ENUM 経由のため
member 名が `CATapUnmuted` のままで stripping されない)。
回避: `CATapMuteBehavior(rawValue: 0)` (= unmuted) を直接渡す。

```swift
description.muteBehavior = CATapMuteBehavior(rawValue: 0) ?? description.muteBehavior
```

### c. `AudioBufferList` のメモリレイアウト

IOProc 内で受け取る `UnsafePointer<AudioBufferList>` を直接ポインタ算術で読むと
ARM64 のアライメント要件 (`AudioBuffer` は 8 byte align) で SEGV する。
**必ず `UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ptr))` を経由する**。

(最初のクラッシュ実例: `SPSCByteRingBuffer.push` 内の `memcpy` で
`Data Abort byte read Translation fault @ 0x04b3c00000001000`)

### d. `AVAudioPCMBuffer` の `sending` 移譲

Swift 6 strict concurrency 下で `AsyncStream.Continuation.yield(_:)` は
`sending Element` を要求する。`AVAudioPCMBuffer` (非 Sendable class) を yield するには、
task-isolated 領域で生成した直後に `UncheckedSendableBox` などで region transfer を
コンパイラに納得させる必要がある (本実装では `UncheckedSendableBox<AVAudioPCMBuffer>(buf).value`
で region 移譲)。

### e. macOS 26.x の Permission inherit

親プロセスのマイク/System Audio 権限が CLI 子プロセスに継承される (TCC responsiblePid)。
そのため CLI 単独の Info.plist 文字列が無くてもダイアログ無しで起動できる。
ただしこれは「開発時の便宜」であり、本番 `.app` バンドルでは Info.plist が必須。

### f. RT スレッドで ARC を踏まない

IOProc closure 内で AVAudioPCMBuffer (`class`) を生成すると ARC 操作が走り
realtime safety を破壊する。本実装では IOProc は `memcpy → ring.push` のみとし、
`AVAudioPCMBuffer` 生成は consumer Task (通常スレッド) で行う設計。

## 7. S2-A への引き継ぎ事項

### 必ず再利用するモジュール (Sources/AudioTapKit)

- `SystemAudioTap` — Core Audio process tap + aggregate device IOProc + ring buffer
- `MicCapture` — AVAudioEngine.inputNode tap (with deep copy)
- `WAVFileWriter` — AVAudioFile 薄ラップ
- `SPSCByteRingBuffer` — `Synchronization.Atomic<Int>` ベース、外部依存無し
- `UncheckedSendableBox<T>` — AVAudioPCMBuffer 等の非 Sendable class を AsyncStream 越しに転送
- `AudioTapError` — OSStatus 文字列化付きエラー型

### `AudioCaptureService` 実装に必要な追加事項 (S2-A)

1. **state machine + AsyncStream<CaptureState>**
   - `idle → preparing → recording → paused/finalizing/failed` の遷移を actor 内で管理。
   - `pause()/resume()` は **ファイル書き込みを止める** だけにし、ハードウェアは止めない (Contract 通り)。
     ring buffer は drain だけ続け、writer をスキップする。
2. **`AudioCaptureError` への翻訳**
   - 本 PoC の `AudioTapError` を `Contracts.AudioCaptureError` に詰め直す。
   - `processTapCreateFailed(status:)` / `aggregateDeviceCreateFailed(status:)` / `engineStartFailed(message:)`
     が既に Contract に定義済み。
3. **権限要求 (`requestAuthorization`)**
   - マイク: `AVCaptureDevice.requestAccess(for: .audio)` (本 PoC のヘルパを移植)。
   - System Audio: 初回 `tap.start()` を試して `deviceStartFailed` を権限拒否と推定する
     (現状の macOS API では事前 query API が無い。OSStatus 値での分岐は **未確定**)。
4. **ファイル配置**
   - `Contracts.AppPaths` を使い、`<recordingsRoot>/<UUID>/mic.wav`, `system.wav` に書き出す。
5. **time sync 情報の保存**
   - PoC では未実装だが、`AVAudioPCMBuffer` の `AVAudioTime` (mic 側) と
     IOProc の `inInputTime` (system 側) を保存しておくと、transcribe 時の word-level alignment で活用できる。
6. **prewarm**
   - `SystemAudioTap` と `MicCapture` をインスタンス化し、`start()` を打たない状態で
     hold しておくと、初回録音のレイテンシが減る (Core Audio HAL の internal cache を温める)。
7. **device 変更ハンドラ**
   - 出力デバイス変更時には aggregate device の作り直しが必要。
   - `AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, ...)`
     で listener を貼り、変更検知時に tap を再生成する (本 PoC では未実装)。

### 既知の TODO / 未確定

- **OSStatus 値による権限拒否の判定**: System Audio Recording 権限拒否時の
  正確な OSStatus が **未確定**。本番では UI 側で「設定アプリで許可してください」
  リンクを出す必要がある。
- **ファイル format**: 現状 PoC は capture format をそのまま書き出している。本番でも同方針。
  - 副作用: mic 44.1 kHz mono Float32, system 48 kHz stereo Float32 と
    異なるサンプルレートで保存される。S2-D (TranscriptionKit) で変換するので OK。
- **fmt chunk の "extensible" 形式**: AVAudioFile が WAVE_FORMAT_EXTENSIBLE で書く場合があり、
  古いプレーヤで互換性問題が出る可能性あり (今回 afinfo は問題なし)。

## 8. ビルド / 実行手順 (再現用)

```bash
cd /Users/rikuto/Desktop/apps/localVoiceRec-s1
swift build
# 30 秒 (デフォルト)
swift run AudioTapPoC
# 任意秒数
POC_DURATION=10 swift run AudioTapPoC

# 検証
afinfo Tools/AudioTapPoC/output/mic.wav
afinfo Tools/AudioTapPoC/output/system.wav
afplay Tools/AudioTapPoC/output/mic.wav    # 聴いて確認
afplay Tools/AudioTapPoC/output/system.wav
```

Ctrl+C で graceful shutdown (SIGINT → 残バッファ flush → 停止)。

## 9. 参考リンク

- 本 PoC のベース: [insidegui/AudioCap](https://github.com/insidegui/AudioCap) (MIT, Apple Engineer Guilherme Rambo)
- 公式 doc: <https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps>
- 内部仕様: `docs/api-references.md` Section 3 (Process Tap), Section 4 (AVAudioEngine)
