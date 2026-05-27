# S9 UX レビュー: 自動文字起こしパイプラインのフィードバック設計

対象: `RecordingDetailView` / `RecordingListView` / `MenuBarContentView` / `MainScene` / `AppViewModel`
レビュー方針: 「ユーザーが **動いている / 失敗した / 待てば終わる** を直感的に判断できるか」。

---

## 0. 先に: 未指摘の compile-breaking バグ (最優先)

`Sources/AppUI/AppViewModel.swift` の作業ツリー (未コミット) で
`isTranscribing` / `isSummarizing` が **stored から computed (`!transcribingIDs.isEmpty`) に変更** されているにもかかわらず、同じファイル内で以下のように **代入が残っている**:

```swift
// L218-220 (transcribeRecording)
guard !isTranscribing else { return }
isTranscribing = true                       // ← computed への代入 = compile error
defer { isTranscribing = false }            // ← 同上

// L265-266 (summarizeRecording)
isSummarizing = true                        // ← 同上
defer { isSummarizing = false }
// regenerateSummary L295-296 も同様
```

このまま `xcodebuild` すると確実にビルド不能。修正は **「ID 集合への insert/remove」と「ガードは集合に含まれるかで判定」**:

```swift
public func transcribeRecording(_ recording: Recording, locale: Locale? = nil) async {
    guard !transcribingIDs.contains(recording.id) else { return }
    transcribingIDs.insert(recording.id)
    defer { transcribingIDs.remove(recording.id) }
    // ...
}

public func summarizeRecording(_ recording: Recording, segments: [TranscriptSegment]? = nil) async {
    let target = segments ?? self.segments
    guard !target.isEmpty else { return }
    guard !summarizingIDs.contains(recording.id) else { return }
    summaryAvailability = await summary.availability()
    guard case .available = summaryAvailability else { lastError = "要約サービスが利用できません"; return }
    summarizingIDs.insert(recording.id)
    defer { summarizingIDs.remove(recording.id) }
    // ...
}

public func regenerateSummary(hint: String? = nil) async {
    guard let recording = selectedRecording else { return }
    // ...
    summarizingIDs.insert(recording.id)
    defer { summarizingIDs.remove(recording.id) }
    // ...
}
```

これが直っていない限り、以降の UX 改善案はすべて適用不能なので **Must の最上位**。

---

## 1. レビュー結果サマリ

| 項目                                                       | 優先度 | セクション |
| ---------------------------------------------------------- | ------ | ---------- |
| `isTranscribing` / `isSummarizing` の代入を集合操作に置換  | Must   | §0         |
| メニューバーアイコンに「処理中」状態を追加 (mic.badge)     | Must   | §2.1       |
| 録音一覧の各行に状態バッジ                                 | Must   | §3.1       |
| select 時に空 segments なら自動 transcribe (1 回試行のみ)  | Must   | §4         |
| 「再実行」ボタンに confirmationDialog                      | Must   | §5         |
| パイプライン完了/失敗時の `UNUserNotification`             | Should | §2.2       |
| `lastError` の表示位置と「リトライ」アクション             | Should | §6         |
| 「無音/未検出」と「失敗」のエラー区別                      | Should | §7         |
| `RecordingDetailView` のセクションを per-recording 表示に  | Should | §3.2       |
| プレビュー: 進行中 / 失敗 / 自動パイプライン状態の Mock 追加 | Should | §8         |
| メニューバーで「直近の処理状態」を簡易表示                 | Nice   | §2.3       |
| 自動 transcribe の失敗フラグを per-recording で保持        | Nice   | §4         |

合計 **12 項目** (Must 5 / Should 5 / Nice 2)。

---

## 2. メニューバーアイコン / 通知 (観点 A1, C7)

### 2.1 [Must] メニューバーアイコンに「処理中」を追加

現状 (`MainScene.swift` `MenuBarLabel`) は `captureState` だけを見ている。
ユーザーがメニューを閉じている間にパイプラインが走っていることが分からない。
`captureState` が idle でも `viewModel.isTranscribing || viewModel.isSummarizing` なら微妙に違うアイコンにする:

```swift
// Sources/AppUI/MainScene.swift
private struct MenuBarLabel: View {
    let state: CaptureState
    let isProcessing: Bool   // ← 追加

    var body: some View {
        switch state {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .preparing, .finalizing:
            Image(systemName: "mic.circle")
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .idle:
            if isProcessing {
                // 文字起こし or 要約進行中: 点が付いたマイク
                Image(systemName: "mic.badge.plus")
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: "mic.fill")
            }
        }
    }
}

// MainScene.body 内
} label: {
    MenuBarLabel(
        state: viewModel.captureState,
        isProcessing: viewModel.isTranscribing || viewModel.isSummarizing
    )
}
```

- 「録音は停止したが裏でまだ動いている」をアイコンの脈動だけで伝えられる
- `symbolEffect(.pulse, options: .repeating)` は macOS 14+。`macOS 15+` をターゲットにしているなら問題なし

### 2.2 [Should] パイプライン完了 / 失敗の通知

`UNUserNotification` で完了/失敗を 1 通だけ出す。`LSUIElement=YES` でも通知は出せる。
ユーザーがメニューを閉じたまま放置していても結果が分かる:

```swift
// Sources/AppUI/AppViewModel.swift
import UserNotifications

private func runAutoPipeline(for recording: Recording) {
    pipelineTasks[recording.id]?.cancel()
    let task = Task { @MainActor [weak self] in
        defer { self?.pipelineTasks.removeValue(forKey: recording.id) }
        guard let self else { return }
        await self.transcribeRecording(recording)
        guard !Task.isCancelled else { return }
        let saved = (try? await self.repository.loadSegments(for: recording.id)) ?? []
        if !saved.isEmpty {
            await self.summarizeRecording(recording, segments: saved)
            await self.postCompletionNotification(recording: recording, ok: self.lastError == nil)
        } else {
            await self.postCompletionNotification(recording: recording, ok: false, reason: "音声が検出されませんでした")
        }
    }
    pipelineTasks[recording.id] = task
}

private func postCompletionNotification(recording: Recording, ok: Bool, reason: String? = nil) async {
    let center = UNUserNotificationCenter.current()
    // 権限は未要求なら 1 度だけ要求 (拒否されたら以降はサイレントに失敗)
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
    let content = UNMutableNotificationContent()
    if ok {
        content.title = "文字起こし完了"
        content.body = recording.title
    } else {
        content.title = "処理に失敗しました"
        content.body = reason ?? lastError ?? recording.title
    }
    content.sound = ok ? nil : .default
    let req = UNNotificationRequest(identifier: recording.id.uuidString, content: content, trigger: nil)
    try? await center.add(req)
}
```

- 通知をクリックしたら録音一覧を開く動線も `UNUserNotificationCenterDelegate` で追加可能 (今回はスコープ外)

### 2.3 [Nice] メニューバーポップオーバーに「直近の処理状態」

`MenuBarContentView` の `statusDescription` の下に、`isTranscribing || isSummarizing` のとき小さな行を追加:

```swift
// Sources/AppUI/MenuBarContentView.swift, statusDescription の直後
if viewModel.isTranscribing || viewModel.isSummarizing {
    HStack(spacing: Theme.Spacing.xs) {
        ProgressView().controlSize(.small)
        Text(viewModel.isSummarizing ? "要約を生成中..." : "文字起こしを実行中...")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

---

## 3. 録音一覧 (観点 A2, C8)

### 3.1 [Must] 各行に「文字起こし状態バッジ」

`RecordingRow` は現状タイトル + 日時 + 長さのみ。`transcribingIDs` / `summarizingIDs` / 永続済み segments の有無を見せる必要がある。

問題: 「永続済み segments があるか」は repository 経由で非同期に読まないと分からない。
ベタな解は `viewModel` 側に **`recordingStatuses: [UUID: RecordingStatus]`** を持たせて `refreshList()` で一括計算する:

```swift
// Sources/AppUI/AppViewModel.swift

public enum RecordingStatus: Sendable, Hashable {
    case pending          // 文字起こし未実行 (segments 空 & 処理中でない)
    case transcribing     // 文字起こし中
    case summarizing      // 要約生成中
    case transcribed      // 文字起こしのみ完了
    case completed        // 要約まで完了
    case failed           // 直近の自動試行が失敗
}

public private(set) var recordingStatuses: [UUID: RecordingStatus] = [:]
/// select 時に 1 度だけ自動 transcribe を試行した録音
private var autoTranscribeAttempted: Set<UUID> = []

public func refreshList() async {
    do {
        recordings = try await repository.list(limit: nil, offset: nil)
        // 各録音の状態を一括算出 (segments / summary の存在のみ確認)
        var map: [UUID: RecordingStatus] = [:]
        for r in recordings {
            if transcribingIDs.contains(r.id) { map[r.id] = .transcribing; continue }
            if summarizingIDs.contains(r.id) { map[r.id] = .summarizing; continue }
            let segs = (try? await repository.loadSegments(for: r.id)) ?? []
            if segs.isEmpty {
                map[r.id] = .pending
            } else if (try? await repository.loadSummary(for: r.id)) != nil {
                map[r.id] = .completed
            } else {
                map[r.id] = .transcribed
            }
        }
        recordingStatuses = map
        lastError = nil
    } catch {
        lastError = "一覧の読み込みに失敗しました: \(String(describing: error))"
    }
}

public func status(for id: UUID) -> RecordingStatus {
    if transcribingIDs.contains(id) { return .transcribing }
    if summarizingIDs.contains(id) { return .summarizing }
    return recordingStatuses[id] ?? .pending
}
```

行側:

```swift
// Sources/AppUI/RecordingListView.swift
private struct RecordingRow: View {
    let recording: Recording
    let status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(recording.title).font(.body).lineLimit(1)
                Spacer()
                StatusBadge(status: status)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text(AppFormatters.dateTime.string(from: recording.startedAt))
                Text("·")
                Text(AppFormatters.duration(recording.duration))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let status: RecordingStatus
    var body: some View {
        switch status {
        case .pending:
            Label("未処理", systemImage: "circle.dashed")
                .labelStyle(.iconOnly).foregroundStyle(.secondary)
        case .transcribing:
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                Text("文字起こし中").font(.caption2).foregroundStyle(.secondary)
            }
        case .summarizing:
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                Text("要約中").font(.caption2).foregroundStyle(.secondary)
            }
        case .transcribed:
            Image(systemName: "text.bubble.fill").foregroundStyle(.secondary)
        case .completed:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// ForEach 内
RecordingRow(recording: recording, status: viewModel.status(for: recording.id))
```

注: 一覧表示のたびに全録音の `loadSegments` / `loadSummary` を呼ぶのは O(N) のディスク I/O。録音数が増えると重い。
将来的には Repository に `summary listMetadata()` を追加して 1 クエリで取れるようにしたほうが良いが、現段階の規模 (~数十件) では許容範囲。

### 3.2 [Should] 詳細ペインの状態判定を `selectedRecording.id` ベースに

`RecordingDetailView` の判定は `viewModel.isTranscribing` (= 全体フラグ) を見ている。並列で複数録音が処理中の場合 (S8 で `pipelineTasks` 辞書を導入したことから想定される) **別録音の処理状態が表示に混ざる** 可能性。`isTranscribingSelected` / `isSummarizingSelected` (既に追加済み) に置換:

```swift
// RecordingDetailView.swift L68, L85, L107, L130, L156, L212
if viewModel.isTranscribingSelected && viewModel.segments.isEmpty { ... }
// ↑ "viewModel.isTranscribing" を "viewModel.isTranscribingSelected" に置換
```

---

## 4. select で空 segments なら自動 transcribe (観点 B4, B5, B6) — [Must]

ユーザー要望: **「文字起こしは自動が UX として良い」**。
ただし無限ループ / 連打で複数走らせる事故を避ける必要がある。
要件まとめ:

1. `select(_:)` 時に空 segments かつ `pipelineTasks` に未登録なら **1 度だけ** 自動起動
2. パイプライン中の録音をクリックしても重複起動しない (`pipelineTasks[id]` の存在で判定)
3. 自動 transcribe が失敗したら、その録音についてはもう自動再試行しない (`autoTranscribeAttempted` に記録)
4. ユーザーが明示的に「文字起こしを実行」ボタンを押した場合は `autoTranscribeAttempted` をリセット (= 再試行解禁)

```swift
// Sources/AppUI/AppViewModel.swift

private var autoTranscribeAttempted: Set<UUID> = []

public func select(_ recording: Recording) async {
    selectedRecording = recording
    segments = []
    summaryDocument = nil
    do {
        async let segmentsAsync = repository.loadSegments(for: recording.id)
        async let summaryAsync = repository.loadSummary(for: recording.id)
        let loadedSegments = try await segmentsAsync
        let loadedSummary = try await summaryAsync
        segments = loadedSegments.sorted { $0.startSec < $1.startSec }
        summaryDocument = loadedSummary
        summaryAvailability = await summary.availability()
        lastError = nil

        // ─── 自動文字起こしトリガ ───
        if loadedSegments.isEmpty,
           pipelineTasks[recording.id] == nil,
           !autoTranscribeAttempted.contains(recording.id) {
            autoTranscribeAttempted.insert(recording.id)
            runAutoPipeline(for: recording)
        }
    } catch {
        lastError = "詳細の読み込みに失敗しました: \(String(describing: error))"
    }
}

// 手動ボタンが押されたら自動試行フラグをクリアする
public func transcribeRecording(_ recording: Recording, locale: Locale? = nil) async {
    autoTranscribeAttempted.remove(recording.id)   // ← 手動でもう一度開く道を残す
    // ... (既存処理)
}
```

理由付け:

- 連続クリックは `pipelineTasks` ガードで重複起動なし
- 失敗時の自動リトライは `autoTranscribeAttempted` で 1 回まで (= 無限ループ無し)
- 手動 transcribe を 1 度叩けばまた自動経路に戻れる
- `runAutoPipeline` が transcribe → summarize の両方を回すので、segments があって要約だけ無い録音への自動要約も同経路でカバー可能 (拡張案):

```swift
// 上の自動トリガを次のように拡張すれば「要約だけが無い」録音も自動で要約まで完走
if pipelineTasks[recording.id] == nil,
   !autoTranscribeAttempted.contains(recording.id) {
    if loadedSegments.isEmpty {
        autoTranscribeAttempted.insert(recording.id)
        runAutoPipeline(for: recording)
    } else if loadedSummary == nil, case .available = summaryAvailability {
        // segments はあるが要約だけ無い → 要約のみ自動実行 (transcribe はスキップ)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.summarizeRecording(recording, segments: loadedSegments)
        }
    }
}
```

---

## 5. 「再実行」ボタンの confirmation (観点 D9) — [Must]

`transcribeRecording` は冒頭で `deleteSegments(for:)` する。Code Reviewer が指摘した通り、過去の文字起こし結果が消える。**confirmationDialog** を入れる:

```swift
// Sources/AppUI/RecordingDetailView.swift
@State private var showTranscribeReconfirm: Bool = false

private var transcribeControls: some View {
    Button {
        if viewModel.segments.isEmpty {
            // 初回 = 警告不要
            Task {
                if let r = viewModel.selectedRecording { await viewModel.transcribeRecording(r) }
            }
        } else {
            showTranscribeReconfirm = true
        }
    } label: {
        if viewModel.isTranscribingSelected {
            Label("実行中...", systemImage: "ellipsis")
        } else if viewModel.segments.isEmpty {
            Label("文字起こしを実行", systemImage: "waveform.badge.plus")
        } else {
            Label("再実行", systemImage: "arrow.triangle.2.circlepath")
        }
    }
    .disabled(viewModel.isTranscribingSelected || viewModel.selectedRecording == nil)
    .confirmationDialog(
        "文字起こしを再実行しますか?",
        isPresented: $showTranscribeReconfirm,
        titleVisibility: .visible
    ) {
        Button("再実行する", role: .destructive) {
            Task {
                if let r = viewModel.selectedRecording { await viewModel.transcribeRecording(r) }
            }
        }
        Button("キャンセル", role: .cancel) { }
    } message: {
        Text("既存の文字起こし結果は削除されます。要約も再生成が必要になる場合があります。")
    }
}
```

同様の警告を「要約を再生成」にも付けても良いが、要約は再生成しても直前のものを内部で破棄せず diff も取れないため、現状の confirmation 無しでも被害は小さい (Nice 級)。

---

## 6. エラー表示の場所とリトライ (観点 A3) — [Should]

現状 `lastError` を表示しているのは `MenuBarContentView` のみ。**録音一覧 / 詳細を開いて作業しているユーザーはエラーに気付けない**。
詳細ビューの上部に薄い帯で出して、リトライアクションも横に置く:

```swift
// Sources/AppUI/RecordingDetailView.swift, body 内 header の前に
if let err = viewModel.lastError {
    errorBanner(err)
}

@ViewBuilder
private func errorBanner(_ message: String) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        Text(message).font(.caption).foregroundStyle(.primary).lineLimit(3)
        Spacer()
        Button("再試行") {
            Task {
                if let r = viewModel.selectedRecording {
                    if viewModel.segments.isEmpty {
                        await viewModel.transcribeRecording(r)
                    } else {
                        await viewModel.summarizeRecording(r)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }
    .padding(Theme.Spacing.sm)
    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius))
}
```

注: 現状 `lastError` は **直近 1 件しか保持しない**ので、複数録音が並列で動いて 1 つだけ失敗すると別録音のエラーが上書きされる。本格対応は `errors: [UUID: String]` への拡張だが、まずはバナー表示だけ入れる方が ROI が良い。

---

## 7. 「無音」と「失敗」の区別 (観点 E10) — [Should]

`runAutoPipeline` は transcribe 後に `saved.isEmpty` で要約をスキップしているが、ユーザーから見ると **何も表示されない**ため「文字起こし失敗」と区別できない。
`TranscriptionService` 自体は throw していないので、`lastError` も nil のまま。

簡易対応: パイプラインで segments が空に終わったときに専用メッセージを `lastError` ではなく **`emptyTranscriptIDs: Set<UUID>`** に記録し、UI 上で別文言を出す:

```swift
// AppViewModel.swift
public private(set) var emptyTranscriptIDs: Set<UUID> = []

private func runAutoPipeline(for recording: Recording) {
    pipelineTasks[recording.id]?.cancel()
    let task = Task { @MainActor [weak self] in
        defer { self?.pipelineTasks.removeValue(forKey: recording.id) }
        guard let self else { return }
        await self.transcribeRecording(recording)
        guard !Task.isCancelled else { return }
        let saved = (try? await self.repository.loadSegments(for: recording.id)) ?? []
        if saved.isEmpty {
            self.emptyTranscriptIDs.insert(recording.id)
        } else {
            self.emptyTranscriptIDs.remove(recording.id)
            await self.summarizeRecording(recording, segments: saved)
        }
    }
    pipelineTasks[recording.id] = task
}

// transcribeRecording 内、成功時 (final segments を save した直後) にも
// finalized が空なら emptyTranscriptIDs に記録、空でなければ remove
```

`RecordingDetailView` 側:

```swift
} else if viewModel.segments.isEmpty {
    if viewModel.emptyTranscriptIDs.contains(viewModel.selectedRecording?.id ?? UUID()) {
        emptyBox(message: "音声内容が検出されませんでした。無音または対応言語外の可能性があります。")
    } else {
        emptyBox(message: "文字起こしがまだありません。「文字起こしを実行」を押してください。")
    }
}
```

これで「失敗 (赤バナー)」「無音 (グレーボックス + 説明)」「未実行 (グレーボックス + ボタン誘導)」の三状態が区別できる。

---

## 8. プレビュー強化 (観点 F11) — [Should]

現状 `RecordingDetailView` の `#Preview` は完成形しかない。状態網羅できるよう Mock を増やす:

```swift
// Sources/AppUI/RecordingDetailView.swift 末尾

#Preview("Transcribing in progress") {
    let vm = AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
        transcription: SlowFakeTranscriptionService(),   // ← 後述
        summary: FakeSummaryService()
    )
    return RecordingDetailView(viewModel: vm)
        .task {
            await vm.refreshList()
            await vm.select(SampleData.recording)
            // 自動 transcribe (§4) のトリガを待つだけで進行中状態が見える
        }
        .frame(width: 600, height: 700)
}

#Preview("Empty / no audio detected") {
    let vm = AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
        transcription: EmptyFakeTranscriptionService(),
        summary: FakeSummaryService()
    )
    // emptyTranscriptIDs を手で立てるためのテストフック (Mock 用 ViewModel 拡張)
    return RecordingDetailView(viewModel: vm)
        .task { await vm.select(SampleData.recording) }
        .frame(width: 600, height: 700)
}

#Preview("Error state") {
    let vm = AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
        transcription: FailingFakeTranscriptionService(),
        summary: FakeSummaryService()
    )
    return RecordingDetailView(viewModel: vm)
        .task {
            await vm.select(SampleData.recording)
            await vm.transcribeRecording(SampleData.recording)
        }
        .frame(width: 600, height: 700)
}
```

不足している Mock (Sources/Contracts/Mocks/ 配下に追加):

- `SlowFakeTranscriptionService` — segments を 500ms 間隔で yield して「進行中」を可視化
- `EmptyFakeTranscriptionService` — 何も yield しない (無音シナリオ)
- `FailingFakeTranscriptionService` — `AsyncThrowingStream` で `throw` する

これらは Sources/ 編集禁止ルール下では別エージェントの仕事だが、設計だけ示しておく。

---

## 9. その他気づいた点 (本指示にないが重要)

1. **`pipelineTasks` の `[weak self]` キャプチャと `defer`**: 未コミット差分で `defer { self?.pipelineTasks.removeValue(forKey: recording.id) }` が `guard let self else { return }` の **前** にあるため、`self == nil` の経路でも `pipelineTasks` を辞書から消そうとして無害だが意図不明瞭。順序を `guard let self else { return }` の後にして、`defer { self.pipelineTasks.removeValue(...) }` にした方がコード意図が明確。

2. **`stopRecording()` → `runAutoPipeline()` 内で `transcribeRecording` を await している間、`pipelineTasks` は埋まっているが `transcribingIDs` は `transcribeRecording` 突入後の最初の文でようやく挿入される**。この空白期間 (数 ms) に `select` から自動トリガが入ると 2 重起動の可能性。`runAutoPipeline` の冒頭で `transcribingIDs.insert(recording.id)` を先回りで入れる、または `pipelineTasks[id] != nil` を「処理中」判定として一元化することを推奨。

3. **エクスポート時の状態確認**: 自動 transcribe / summarize が走っている最中にエクスポートボタンを押せてしまう。中途半端な状態のエクスポートを防ぐため、`Button.disabled(... || viewModel.isTranscribingSelected || viewModel.isSummarizingSelected)` を追加。

4. **`MenuBarContentView` で `lastError` を `lineLimit(3)` で抑えているが、エクスポート長文エラーが切れる**。`Text(lastError).textSelection(.enabled)` を加えると診断時にコピーしやすい。

---

## 10. 適用順序の提案

1. **§0** (compile fix) を入れないと何もビルドできない
2. **§4** (自動 select transcribe) — ユーザーの一番の要望
3. **§5** (再実行 confirmation) — 既存データ破壊リスクの即時対応
4. **§3.1** (一覧バッジ) + **§3.2** (Selected 系プロパティへの差し替え) — 同時に入れると整合
5. **§2.1** (メニューバー処理中アイコン) — 1 ファイル変更で済む
6. 残り (Should / Nice) は順次

以上。
