import SwiftUI
import Contracts
#if DEBUG
import ContractsTestSupport
#endif

/// 診断パネル。
///
/// 「録音されていなさそう / 文字起こしが出ない」というユーザー訴えに対し、
/// 原因切り分けに必要な情報をまとめて表示する:
///
/// - マイク / システム音声の権限状態 (`PermissionsSection`)
/// - インストール済み Speech locale / 要約 availability (`SummaryAvailabilitySection`)
/// - SystemAudioTap IOProc カウンタ (`SystemFlowSection`)
/// - 選択中の録音のファイル URL
/// - 直近 5 分の os.log エントリをクリップボードへ (`LogCopySection` + `DiagnosticsLogCollector`)
///
/// IA レビュー後の運用: RecordingDetailView の toolbar から sheet で表示する。
/// 以前の inline DisclosureGroup スタイルは廃止し、シートに合わせたフラット表示。
struct DiagnosticsPanel: View {
    @Bindable var viewModel: AppViewModel
    @State private var isRefreshing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if isRefreshing {
                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("診断情報を更新中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("診断情報を更新中")
            }
            content
        }
        .task {
            await refresh()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            PermissionsSection(viewModel: viewModel)

            Divider()

            SummaryAvailabilitySection(viewModel: viewModel)

            if let flow = viewModel.diagnostics.systemFlow {
                Divider()
                SystemFlowSection(flow: flow)
            }

            if let recording = viewModel.selectedRecording {
                Divider()
                DiagnosticsSectionStyles.section(title: "選択中の録音ファイル") {
                    filePathRow(label: "mic", url: recording.micAudioURL)
                    filePathRow(label: "system", url: recording.systemAudioURL)
                }
            }

            HStack {
                LogCopySection()
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                .help("診断情報を取得し直します")
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    // MARK: - File path row (selected recording)

    private func filePathRow(label: String, url: URL) -> some View {
        let path = url.path
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Button {
                copyToClipboard(path)
            } label: {
                Image(systemName: "doc.on.doc")
                    .accessibilityLabel("\(label) ファイルパスをコピー")
            }
            .buttonStyle(.borderless)
            .help("ファイルパスをコピー")
            Button {
                FinderReveal.reveal(url)
            } label: {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("\(label) ファイルを Finder で表示")
            }
            .buttonStyle(.borderless)
            .help("Finder で表示")
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await viewModel.refreshDiagnostics()
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#if DEBUG
#Preview("Diagnostics") {
    DiagnosticsPanel(
        viewModel: AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
    )
    .padding()
    .frame(width: 360)
}

#Preview("Diagnostics (Dark)") {
    DiagnosticsPanel(
        viewModel: AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(seed: [SampleData.recording]),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
    )
    .padding()
    .frame(width: 360)
    .preferredColorScheme(.dark)
}
#endif
