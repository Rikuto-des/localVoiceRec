import SwiftUI
import Contracts

/// 録音一覧ウィンドウのウィンドウ ID。
let RecordingListWindowID = "recording-list"

/// 録音一覧 + 詳細を表示する NavigationSplitView。
struct RecordingListView: View {
    @Bindable var viewModel: AppViewModel
    @State private var searchText: String = ""
    @State private var selectedID: Recording.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: Theme.Layout.listPaneMinWidth, ideal: 300)
        } detail: {
            detailPane
                .navigationSplitViewColumnWidth(min: Theme.Layout.detailPaneMinWidth, ideal: 560)
        }
        .navigationTitle("録音一覧")
        .frame(
            minWidth: Theme.Layout.listWindowMinWidth,
            minHeight: Theme.Layout.listWindowMinHeight
        )
        .task {
            await viewModel.refreshList()
        }
        .onChange(of: searchText) { _, newValue in
            Task {
                if newValue.isEmpty {
                    await viewModel.refreshList()
                } else {
                    await viewModel.search(query: newValue)
                }
            }
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
        VStack(spacing: 0) {
            if viewModel.recordings.isEmpty {
                emptyState
            } else {
                List(selection: $selectedID) {
                    ForEach(viewModel.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            status: viewModel.status(for: recording.id)
                        )
                            .tag(recording.id as Recording.ID?)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { await viewModel.deleteRecording(recording) }
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $searchText, prompt: "タイトルで検索")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refreshList() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "mic.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("録音がまだありません")
                .font(.headline)
            Text("メニューバーから録音を開始してください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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

/// 一覧の 1 行。
private struct RecordingRow: View {
    let recording: Recording
    let status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(recording.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusBadge(status: status)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text(AppFormatters.dateTime.string(from: recording.startedAt))
                Text("·")
                Text(AppFormatters.duration(recording.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 各録音の処理状態を表すコンパクトなバッジ。
private struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .help("文字起こし未実行")
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("文字起こし中").font(.caption2).foregroundStyle(.secondary)
            }
            .help("文字起こしを実行中")
        case .summarizing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("要約中").font(.caption2).foregroundStyle(.secondary)
            }
            .help("要約を生成中")
        case .transcribed:
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(.secondary)
                .help("文字起こし済み（要約なし）")
        case .completed:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .help("文字起こし + 要約完了")
        case .emptyTranscript:
            Image(systemName: "speaker.slash")
                .foregroundStyle(.secondary)
                .help("音声内容が検出されませんでした")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help("処理に失敗しました")
        }
    }
}

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
