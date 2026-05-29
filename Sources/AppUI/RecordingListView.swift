import SwiftUI
import Contracts
#if DEBUG
import ContractsTestSupport
#endif

/// 録音一覧ウィンドウのウィンドウ ID。
let RecordingListWindowID = "recording-list"

/// 録音一覧 + 詳細を表示する NavigationSplitView。
///
/// ## HIG 準拠ポイント
/// - `NavigationSplitView` + `.navigationSplitViewStyle(.balanced)`
/// - サイドバーは `.sidebar` リストスタイルで一貫したサイドバー UI
/// - 空状態は `ContentUnavailableView`
/// - ツールバーは `.primaryAction` プレースメントで右寄せ
/// - すべてのアイコンボタンに `.help()`
struct RecordingListView: View {
    @Bindable var viewModel: AppViewModel
    @State private var searchText: String = ""
    @State private var selectedID: Recording.ID?
    /// 削除確認ダイアログの対象。nil なら閉じる。A4: 誤削除防止。
    @State private var pendingDeletion: Recording?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: Theme.Layout.listPaneMinWidth, ideal: 300)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: Theme.Layout.detailPaneMinWidth, ideal: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("録音一覧")
        .frame(
            minWidth: Theme.Layout.listWindowMinWidth,
            minHeight: Theme.Layout.listWindowMinHeight
        )
        .task {
            await viewModel.refreshList()
        }
        .onChange(of: searchText) { _, newValue in
            // A12: 毎キーストローク fetch を 300ms デバウンス。
            viewModel.searchDebounced(query: newValue)
        }
        .onChange(of: selectedID) { _, newValue in
            guard let id = newValue,
                  let recording = viewModel.recordings.first(where: { $0.id == id }) else {
                viewModel.clearSelection()
                return
            }
            Task { await viewModel.select(recording) }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // X4.6: `searchable` は常時マウントし、empty state は内側で表示する。
        // 旧実装は録音 0 件のとき searchable が消えて検索欄の出現/消失が起きていた。
        Group {
            if viewModel.recordings.isEmpty && searchText.isEmpty {
                emptyState
            } else if viewModel.recordings.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(selection: $selectedID) {
                    ForEach(bucketize(viewModel.recordings), id: \.name) { bucket in
                        Section {
                            ForEach(bucket.items) { recording in
                                RecordingRow(
                                    recording: recording,
                                    status: viewModel.status(for: recording.id)
                                )
                                    .tag(recording.id as Recording.ID?)
                                    .contextMenu {
                                        Button {
                                            FinderReveal.openRecordingFolder(for: recording)
                                        } label: {
                                            Label("Finder で開く", systemImage: "folder")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            // A4: 削除は必ず確認ダイアログを挟む
                                            pendingDeletion = recording
                                        } label: {
                                            Label("削除…", systemImage: "trash")
                                        }
                                    }
                                    .draggable(recording.micAudioURL)
                            }
                        } header: {
                            Text(bucket.name)
                        }
                    }
                }
                .listStyle(.sidebar)
                // A5: 標準の ⌫ キーで選択中の録音を削除（確認ダイアログ経由）
                .onDeleteCommand {
                    if let id = selectedID,
                       let recording = viewModel.recordings.first(where: { $0.id == id }) {
                        pendingDeletion = recording
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "タイトルで検索")
        // A4: 削除確認ダイアログ。文字起こし・要約も消える旨を明示。
        .alert(
            "この録音を削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { recording in
            Button("削除", role: .destructive) {
                Task {
                    await viewModel.deleteRecording(recording)
                    pendingDeletion = nil
                }
            }
            Button("キャンセル", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { recording in
            Text("\(recording.title) の音声・文字起こし・要約がすべて削除されます。この操作は取り消せません。")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        Task { await viewModel.retryAllPendingTranscriptions() }
                    } label: {
                        Label(pendingWorkCount > 0 ? "未処理を再処理（\(pendingWorkCount) 件）" : "未処理を再処理",
                              systemImage: "wand.and.stars")
                    }
                    .disabled(!hasPendingWork || viewModel.isTranscribing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("その他の操作")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refreshList() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .help("録音一覧を最新の状態に更新します (⌘⇧R)")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    /// 一括 retry 対象が 1 件でもあるか。
    private var hasPendingWork: Bool {
        pendingWorkCount > 0
    }

    /// 一括 retry 対象の件数。X4.9: ボタンラベルへ動的に出すために露出。
    private var pendingWorkCount: Int {
        viewModel.recordings.reduce(0) { count, r in
            switch viewModel.status(for: r.id) {
            case .pending, .emptyTranscript, .failed: return count + 1
            default: return count
            }
        }
    }

    /// 空状態 — macOS 14+ の `ContentUnavailableView` を使う (HIG 推奨)。
    private var emptyState: some View {
        ContentUnavailableView(
            "録音がまだありません",
            systemImage: "mic.slash",
            description: Text("メニューバーアイコンから録音を開始してください（⌘R）。")
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if viewModel.selectedRecording != nil {
            RecordingDetailView(viewModel: viewModel)
        } else {
            ContentUnavailableView(
                "録音を選択してください",
                systemImage: "waveform",
                description: Text("左の一覧から録音を選ぶと、文字起こしと要約が表示されます。")
            )
        }
    }
}

/// 相対日付バケットでまとめた録音グループ。
fileprivate struct RecordingBucket {
    let name: String
    let items: [Recording]
}

/// 録音を「今日 / 昨日 / 今週 / 今月 / それ以前」のバケットに分割する。
///
/// - `startedAt` の降順で並べ替えてから振り分ける。
/// - 空のバケットはスキップ。
fileprivate func bucketize(_ recordings: [Recording]) -> [RecordingBucket] {
    var calendar = Calendar.current
    calendar.locale = Locale(identifier: "ja_JP")
    let now = Date()

    let sorted = recordings.sorted { $0.startedAt > $1.startedAt }

    var today: [Recording] = []
    var yesterday: [Recording] = []
    var thisWeek: [Recording] = []
    var thisMonth: [Recording] = []
    var older: [Recording] = []

    let startOfToday = calendar.startOfDay(for: now)
    let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

    for recording in sorted {
        let date = recording.startedAt
        if calendar.isDate(date, inSameDayAs: now) {
            today.append(recording)
        } else if date >= startOfYesterday && date < startOfToday {
            yesterday.append(recording)
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            thisWeek.append(recording)
        } else if calendar.isDate(date, equalTo: now, toGranularity: .month) {
            thisMonth.append(recording)
        } else {
            older.append(recording)
        }
    }

    var buckets: [RecordingBucket] = []
    if !today.isEmpty { buckets.append(RecordingBucket(name: "今日", items: today)) }
    if !yesterday.isEmpty { buckets.append(RecordingBucket(name: "昨日", items: yesterday)) }
    if !thisWeek.isEmpty { buckets.append(RecordingBucket(name: "今週", items: thisWeek)) }
    if !thisMonth.isEmpty { buckets.append(RecordingBucket(name: "今月", items: thisMonth)) }
    if !older.isEmpty { buckets.append(RecordingBucket(name: "それ以前", items: older)) }
    return buckets
}

/// 一覧の 1 行。
///
/// HIG: サイドバー行は `.body` フォント + secondary メタ情報、複数行構造を避けすぎず簡潔に。
private struct RecordingRow: View {
    let recording: Recording
    let status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(recording.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(status: status)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text(AppFormatters.dateTime.string(from: recording.startedAt))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(AppFormatters.duration(recording.duration))
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(recording.title), \(AppFormatters.dateTime.string(from: recording.startedAt)), \(AppFormatters.duration(recording.duration)), \(status.accessibilityDescription)"
        )
    }
}

/// 各録音の処理状態を表すコンパクトなバッジ。
///
/// HIG: 状態は **色だけでなくアイコン形状でも区別** できるよう SF Symbol を選んでいる。
private struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .help("文字起こし未実行")
                .accessibilityLabel("文字起こし未実行")
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("文字起こし中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("文字起こしを実行中")
            .accessibilityLabel("文字起こしを実行中")
        case .summarizing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("要約中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("要約を生成中")
            .accessibilityLabel("要約を生成中")
        case .transcribed:
            Image(systemName: "text.bubble.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .help("文字起こし済み（要約なし）")
                .accessibilityLabel("文字起こし済み")
        case .completed:
            Image(systemName: "checkmark.seal.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.success)
                .help("文字起こし + 要約完了")
                .accessibilityLabel("完了")
        case .emptyTranscript:
            Image(systemName: "speaker.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .help("音声内容が検出されませんでした")
                .accessibilityLabel("音声未検出")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Palette.error)
                .help("処理に失敗しました")
                .accessibilityLabel("失敗")
        }
    }
}

private extension RecordingStatus {
    var accessibilityDescription: String {
        switch self {
        case .pending: return "文字起こし未実行"
        case .transcribing: return "文字起こし中"
        case .summarizing: return "要約中"
        case .transcribed: return "文字起こし済み"
        case .completed: return "文字起こしと要約が完了"
        case .emptyTranscript: return "音声未検出"
        case .failed: return "処理失敗"
        }
    }
}

#if DEBUG
#Preview("With recordings") {
    RecordingListView(
        viewModel: makePreviewViewModel(seed: [
            SampleData.recording,
            Recording(
                id: UUID(),
                title: "Weekly Sync",
                startedAt: Date().addingTimeInterval(-86400),
                endedAt: Date().addingTimeInterval(-86400 + 1200),
                micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
                systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
            )
        ])
    )
}

#Preview("With recordings (Dark)") {
    RecordingListView(
        viewModel: makePreviewViewModel(seed: [
            SampleData.recording,
            Recording(
                id: UUID(),
                title: "Weekly Sync",
                startedAt: Date().addingTimeInterval(-86400),
                endedAt: Date().addingTimeInterval(-86400 + 1200),
                micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
                systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
            )
        ])
    )
    .preferredColorScheme(.dark)
}

#Preview("Empty") {
    RecordingListView(
        viewModel: makePreviewViewModel(seed: [])
    )
}

@MainActor
private func makePreviewViewModel(seed: [Recording]) -> AppViewModel {
    AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: InMemoryRecordingRepository(seed: seed),
        transcription: FakeTranscriptionService(),
        summary: FakeSummaryService()
    )
}
#endif
