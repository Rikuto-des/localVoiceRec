# Audio Debug — S10-A 実機診断レポート

実機録音で **system.wav が完全無音 (-240 dBFS = 完全 0)** という不具合が発生していた。
S10-A でこの原因を特定し、検出と回復ガイドを整備した。

---

## 1. 問題の確認方法

PoC を実行し、WAV の RMS / Peak を計測する。

```sh
# 録音 (5 秒) — 別ターミナルで何か音を再生しておく
POC_DURATION=5 swift run AudioTapPoC

# WAV の情報
afinfo Tools/AudioTapPoC/output/mic.wav
afinfo Tools/AudioTapPoC/output/system.wav

# RMS / Peak を計算 (Python ワンライナー)
python3 - <<'PY'
import struct, math
def rms_peak(path):
    with open(path, 'rb') as f:
        data = f.read()
    i = data.find(b'data')
    size = struct.unpack('<I', data[i+4:i+8])[0]
    raw = data[i+8:i+8+size]
    floats = struct.unpack('<' + 'f' * (len(raw)//4), raw)
    n = len(floats)
    s = sum(x*x for x in floats) / n
    rms = math.sqrt(s)
    peak = max(abs(x) for x in floats)
    rms_db = 20*math.log10(rms) if rms > 0 else float('-inf')
    peak_db = 20*math.log10(peak) if peak > 0 else float('-inf')
    print(f'{path}: RMS={rms_db:.2f} dBFS, Peak={peak_db:.2f} dBFS')
for p in ('Tools/AudioTapPoC/output/mic.wav','Tools/AudioTapPoC/output/system.wav'):
    rms_peak(p)
PY
```

健全な状態（音が出ている前提）:
- mic.wav: RMS が -40〜-20 dBFS 程度
- system.wav: RMS が -50〜-10 dBFS 程度
- system.wav が **-∞ dBFS / -240 dBFS** の場合は完全無音バッファ。下記の TCC 問題を疑う。

---

## 2. 仮説と検証

### 仮説 A: aggregate device の構成不備 → ❌ 反証
`SystemAudioTap.start()` のログを追加し、Core Audio API は全て `noErr` を返している。
タップ作成 → UID 取得 → format 取得 → aggregate device 作成 → IOProc 登録 → device start、
全ステップが成功している。

```
[com.example.localVoiceRec:audio] AudioHardwareCreateProcessTap ok: tapID=125
[com.example.localVoiceRec:audio] Tap UID: 3B8FF0B9-...
[com.example.localVoiceRec:audio] Tap stream format: sr=48000.000000 ch=2 bpf=8 bitsPerCh=32
[com.example.localVoiceRec:audio] AudioHardwareCreateAggregateDevice ok: aggID=126
[com.example.localVoiceRec:audio] IOProc created
[com.example.localVoiceRec:audio] AudioDeviceStart ok — capturing
```

### 仮説 B: IOProc が呼ばれていない → ❌ 反証
診断カウンタを追加:
- `ioProcCallCount` = 284 (3 秒で ~95 Hz)
- `receivedBytesTotal` = 1,163,264 byte (≈ 3 秒 × 48kHz × 2ch × 4byte)
- **IOProc は正常に呼ばれている**

### 仮説 C: バッファ内容が全ゼロ → ✅ **確定**
IOProc 内で「最初の 16 サンプルが全部 0 か」をプローブする `nonZeroBufferCount` を追加。
- システム音 (Submarine.aiff を再生中) でも `nonZeroBufferCount = 0`
- HAL は「サイレンス buffer」(全 0 のバイト列) を返してきている

### 仮説 D: TCC 権限が降りていない → ✅ **根本原因**

`/usr/bin/log show --predicate 'process == "tccd"'` で実機ログを追跡:

```
AUTHREQ_CTX: msgID=402.3031, function=<private>, service=kTCCServiceAudioCapture, preflight=yes
AUTHREQ_ATTRIBUTION: responsible={com.anthropic.claude-code}, accessing={AudioTapPoC}
AUTHREQ_RESULT: msgID=402.3031, authValue=1, authReason=0
                                          ^^^^^^^^^^^^
                                          1 = Denied, prompt was NOT shown
```

#### 結論 (実機でわかった真実)

1. **macOS の process tap (`AudioHardwareCreateProcessTap` + aggregate device) の権限は
   `kTCCServiceAudioCapture` (= Info.plist `NSAudioCaptureUsageDescription`) で制御される**。
   ヘッダ上の `kTCCServiceScreenCapture` (Screen Recording) ではない。
2. **権限が拒否されている場合、`AudioDeviceStart` は `noErr` を返し、HAL は silence buffer
   (mDataByteSize 通常 / 中身全ゼロ) を IOProc に流し続ける**。エラーで止まらない。
3. PoC を `swift run` で動かすと **責任プロセス (responsible process) = Claude Code** に
   なってしまい、Claude Code に NSAudioCaptureUsageDescription が無いため
   `authValue=1` (Denied) のまま prompt も出ない。
4. 同じことが **本番の `.app` でも起こりうる**:
   ユーザが過去に「許可しない」を選んでいる / コード署名が変わってバンドル ID が再認識
   / ProtectedDirectory 経由起動 等で responsible process が変わった、などのケース。

---

## 3. 採用した修正

### A. 診断ログ (`SystemAudioTap`)
- `os_log` subsystem=`com.example.localVoiceRec` category=`audio` で起動シーケンスをトレース
- IOProc 内で **RT-safe** な atomic カウンタを更新:
  - `ioProcCallCount` — IOProc 呼び出し回数
  - `nonZeroBufferCount` — 中身が全 0 でないバッファ数 (先頭 16 サンプル peek)
  - `receivedBytesTotal` — push 合計 byte
- `stop()` 時に上記をログ。`ioProcCalls >= 10 && nonZeroBuffers == 0 && bytesReceived > 0`
  なら **TCC 拒否疑い** を ERROR レベルで明示する。

### B. CATapDescription / aggregate device の構成見直し
- `description.muteBehavior = .unmuted (=0)` を明示 (デフォルトと同じだが堅牢化)
- `description.uuid = UUID()` を明示生成 (auto-restore による予期しない設定継承を回避)
- `kAudioAggregateDeviceTapAutoStartKey: 1` を追加 (tap が音を受け取るまで `AudioDeviceStart` を待つ)
- `kAudioSubTapExtraInputLatencyKey: 0` を明示

> これらは「健全な構成」の確認であり、TCC denial の状態では効果は無い (HAL が silence を返す挙動は変わらない)。
> ただしユーザが将来 TCC を許可した後の挙動は確実になる。

### C. PoC (`AudioTapPoC`) に診断カウンタ表示を追加
`Results` セクションで `Tap IOProc calls / non-zero buffers / bytes received` を表示する。
TCC 拒否時の見分け方が一目で分かる。

### D. RMS / Peak の emit (`AudioCaptureServiceImpl`)
`Contracts.AudioLevelSnapshot` を 100ms ごとに `liveAudioLevels` ストリームへ流す:

- `WriterSink.write` の中で `LevelAccumulator.add(buffer)` を呼ぶ (pause 中も累積)
- 別 `Task.detached(priority: .utility)` が 100ms ごとに snapshot を取り continuation.yield
- stop 時に level emit task を cancel → await

`LevelAccumulator` の設計:
- `sumSq` は `Double` 累積 (Float32 で 100ms 分加算すると精度劣化するため)
- mic は 1ch、system は 2ch でも **全 channel 平均の RMS / 全 channel max の Peak** を返す
- Float32 / Int16 / Int32 を扱う (otherFormat / Float64 は no-op + 警告ログ予定)

これにより UI 側 (S10-B) が録音中に **「mic は鳴ってるが system が無音」を即時可視化** できる。

---

## 4. 修正後の計測値

### TCC 拒否状態 (= 現在の `swift run` PoC、`responsible=Claude Code`)
```
mic.wav:    RMS=-41.04 dBFS, Peak=-29.43 dBFS  (健全)
system.wav: RMS=-inf dBFS,   Peak=-inf dBFS    (silence buffer)
Tap IOProc calls:                284
Tap non-zero buffers observed:   0    ← TCC 拒否のシグネチャ
Tap bytes received total:        1163264
```
→ `stop()` ログに ERROR で TCC 拒否疑いを出力する。

### TCC 許可状態 (本番 .app 想定)
- PoC からは検証できない (TCC 受領は signed bundle が必要)
- 本番 .app では:
  1. 初回 `start()` → 「システム音声録音」プロンプト
  2. 許可 → 以降 `nonZeroBuffers > 0` になる
  3. RMS > -60 dBFS が `liveAudioLevels` で観測できる

---

## 5. メンテナンス時の確認手順

新規リリース / 署名変更 / 大規模リファクタ後に必ず以下を確認:

### 5.1 PoC で診断カウンタを見る
```sh
POC_DURATION=5 swift run AudioTapPoC
```
- `Tap non-zero buffers observed: 0` → 即座に TCC を疑う
- `non-zero > 0` & RMS > -60 dBFS → 健全

### 5.2 TCC ログを直接見る (確定診断)
```sh
/usr/bin/log show --predicate 'process == "tccd"' --last 1m \
  | grep -E "AudioCapture|AUTHREQ_RESULT"
```
`service=kTCCServiceAudioCapture` & `authValue=1` なら拒否。

### 5.3 本番 .app での TCC リセット手順 (ユーザ向け)
権限を一度リセットして再付与したい場合:
```sh
# システム単位での再プロンプト発生
tccutil reset SystemAudioRecording <bundle-id>
# あるいは
tccutil reset AudioCapture <bundle-id>
```
→ 次回 `start()` で再度プロンプト。

### 5.4 自前のレベルメーター (UI) で常時監視
S10-B 以降は `liveAudioLevels` を UI で表示するため:
- `systemPeak < silenceThreshold (=0.001)` が **数秒継続** したら「権限疑い」を表示する
- mic だけ鳴って system が静寂 → 95% TCC 問題

---

## 6. 残課題

- [ ] **本番 .app での実機 RMS 検証**: 署名済み `.app` で再録音して system.wav RMS > -60 dBFS を確認。
      本リポでは `Tools/build-dmg.sh` を経由してから手動テスト。
- [ ] **UI 側 (S10-B)**: `liveAudioLevels` を購読し、`systemPeak == 0` が 3 秒継続したら
      「システム音声録音の許可が必要です」バナーを出す。
- [ ] **`tccutil reset` の自動化**: 設定画面に「権限をリセット」ボタンを置くと UX が良いが、
      Sandbox 内からは `tccutil` を直接叩けないため、手順をテキストで提示するのが現実解。
