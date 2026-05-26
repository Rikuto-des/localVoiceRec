# Manual / UI Test Plan — localVoiceRec

自動テスト (`docs/test-report.md`) では確認できない **TCC 権限 / UI 表示 / 実音声 → 文字起こし → 要約 のエンドツーエンド** を人手で検証するためのチェックリスト。

## 前提

- macOS 26.0 以上 / Apple Silicon
- Apple Intelligence ON (Foundation Models が `.available` であること)
- ScreenCaptureKit / マイクを使うため、Terminal もしくは Xcode から起動した本体は TCC 許可リストに載る点に注意
- アプリの Bundle ID は `App/Info.plist` 上では `$(PRODUCT_BUNDLE_IDENTIFIER)` プレースホルダ。本書では `$BUNDLE_ID` と記載
- 録音保存先: `~/Library/Application Support/<App>/Recordings/`（実装は `AppPaths`）

---

## シナリオ 1: 初回起動 / 権限ダイアログ

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 1.0 | 事前に TCC をリセット: `tccutil reset Microphone $BUNDLE_ID && tccutil reset SystemAudioCapture $BUNDLE_ID` | エラーなく完了 |
| 1.1 | アプリを起動 | メニューバーにアイコンが出現、Dock には出ない（`LSUIElement=true`） |
| 1.2 | メニューバー → 「録音開始」 | マイク権限ダイアログが表示される（文言: `NSMicrophoneUsageDescription`） |
| 1.3 | 「許可」 | システム音声権限ダイアログが表示される（文言: `NSAudioCaptureUsageDescription`） |
| 1.4 | 「許可」 | 録音が開始、メニューバーアイコンが録音中状態になる |
| 1.5 | 「録音停止」 | 録音一覧に新規 Recording が 1 件追加される |

**失敗時**: System Settings → Privacy & Security → Microphone / System Recording に Bundle ID が登録されているか確認。`Console.app` で TCC 関連のエラーを grep (`tccd`, `screencaptured`)。

---

## シナリオ 2: 録音開始 → 停止

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 2.1 | メニューバー → 「録音開始」 | アイコンが録音中表示に変化 |
| 2.2 | 録音中インジケータの確認 | 経過時間 / 音声入力レベル等が表示される（実装に応じて） |
| 2.3 | 10 秒程度発話 + システム音 (動画再生など) | リアルタイムにレベルメータが反応 |
| 2.4 | 「録音停止」 | アイコンが idle に戻る |
| 2.5 | 録音一覧 (RecordingListView) を開く | 新規 Recording が最上位に追加される（`startedAt` 降順） |
| 2.6 | Finder で `~/Library/Application Support/<App>/Recordings/<id>/` を開く | `mic.wav` と `system.wav` が存在し、`afinfo` で長さが録音時間と一致する |

---

## シナリオ 3: 文字起こし

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 3.1 | 録音一覧から 1 件選択 | RecordingDetailView に遷移 |
| 3.2 | 文字起こしの進行状況 | 「処理中」インジケータ → セグメントが順次表示される |
| 3.3 | 2 チャンネル分離 | 各セグメントに `source = .mic` or `.system` のラベルが付与されている |
| 3.4 | タイムスタンプ | `startSec / endSec` が時系列順に並んでいる |
| 3.5 | 不正データの場合 | `installedLocales` が空でも UI がクラッシュしない（エラー表示またはスキップ） |

**確認ポイント**: マイクからの自分の発話は `.mic`、再生中の動画音声は `.system` に振り分けられる。AI 推定話者分離ではなく **チャンネル由来の確定的分離** であることを目視確認。

---

## シナリオ 4: 要約

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 4.1 | 文字起こし完了後、要約が自動生成（または「要約を生成」ボタン） | `SummaryDocument` が表示される |
| 4.2 | 構造化フィールドの表示 | 決定事項 / アクションアイテム / その他のセクションが見える |
| 4.3 | 「要約を再生成」ボタンを押す | スピナー表示 → 新しい要約に置き換わる |
| 4.4 | Apple Intelligence OFF 環境での再現 | `notAvailable` エラーが UI に表示される（クラッシュしない） |
| 4.5 | アクションアイテム形式 | 担当者 / 期限フィールドが表示される（提供されていれば） |

**注意**: Foundation Models のレスポンスは確率的なので、内容そのものを厳密に検証はしない。**型 / セクション / 文字数の妥当性** で評価する。

---

## シナリオ 5: 削除

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 5.1 | RecordingListView で 1 件を選択 → 削除 | 一覧から消える、Detail も閉じる |
| 5.2 | Finder で対応する `<id>/` ディレクトリを確認 | `mic.wav` と `system.wav` が物理削除されている (`RecordingRepositoryImpl.deleteFiles` 動作) |
| 5.3 | 「すべて削除」 | 確認ダイアログ → 一覧が空に、Recordings/ 配下の WAV が全て消える |
| 5.4 | 削除した Recording に紐付く Segments / Summary | SwiftData 上もカスケード削除されている（DataStoreTests の `deletingRecordingRemovesSegmentsAndSummary` でも自動確認済み） |

---

## シナリオ 6: 1 時間 stress (オプション)

長時間録音時のドリフト・メモリリーク・ファイルサイズ妥当性を確認。

| Step | 操作 | 期待結果 |
| ---- | ---- | -------- |
| 6.1 | 1 時間連続録音 | アプリが落ちない |
| 6.2 | `Activity Monitor` で RSS / CPU を監視 | RSS の単調増加が無い (リーク無し)、CPU は数 % 程度 |
| 6.3 | 録音停止後の WAV | `afinfo` の duration が ~3600 秒 ± 数秒。PoC で観測した秒 0.3 程度の drift が長時間で線形に増えていないか確認 |
| 6.4 | 文字起こし所要時間 | 処理が完了する（時間は計測しておく、後で性能改善時のベースラインに） |
| 6.5 | 要約 | 入力が `truncateIfNeeded` の閾値を超えても短縮された上で要約が返る |

---

## 補足: TCC リセットの注意

- `SystemAudioCapture` の identifier は macOS 26 で追加されたもの。古い OS では `ScreenCapture` が代替
- bundle id を変えるなどで TCC 状態がリセットされない場合、`/Library/Application Support/com.apple.TCC/TCC.db` を SQLite で直接確認
- マイクとシステム音声は **別々の許可**。両方リセットして再現すること

## 補足: 録音ファイル仕様（PoC 実測）

| ファイル | sr | ch | format |
| -------- | -- | -- | ------ |
| `mic.wav` | 44100 Hz | 1 | Float32 |
| `system.wav` | 48000 Hz | 2 | Float32 interleaved |

`SpeechAnalyzer` がこの format をそのまま受け付けるかは別途要確認（IntegrationTests では `fileNotReadable` が出た。`recommendedFormat` への明示変換が必要な可能性あり）。

---

このプランの実行結果は `docs/test-report.md` の末尾、または PR の `Manual QA` チェックボックスにて報告すること。
