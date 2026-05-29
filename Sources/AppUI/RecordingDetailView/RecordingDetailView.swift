import SwiftUI
import UniformTypeIdentifiers
import Contracts
import AppKit
#if DEBUG
import ContractsTestSupport
#endif

/// 個別録音の詳細ビュー。
///
/// 文字起こし（mic = 右寄せ / system = 左寄せのチャットスタイル）と
/// 構造化要約を縦並びで表示する。
///
/// ## HIG 準拠ポイント (S16-A)
/// - Typography: title2 → headline → subheadline → body → footnote → caption の階層
/// - セクションヘッダは `Label("...", systemImage:)` + `.headline` で統一
/// - カードは `Theme.Palette.surfaceSecondary`、適切な箇所は `.regularMaterial`
/// - 主操作 (再生成・エクスポート) は `.bordered` + `.controlSize(.small)`
/// - 破壊的操作には `role: .destructive`
/// - すべてのボタンに `.help()`
/// - Reduce Motion 環境変数を尊重
///
/// ## ファイル構成 (Phase 3.5)
/// 本ファイルはコンテナ + 共有ヘルパー + サブ型 + Previews のみを保持し、
/// 各セクションは `Sections/*.swift` に extension として分割している。
struct RecordingDetailView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var regenerateHint: String = ""
    @State var showHintField: Bool = false
    @State var showTranscribeReconfirm: Bool = false

    // ─── 全文テキスト関連 (S15) ───
    @State var isFullTextExpanded: Bool = false
    @State var fullTextCopyConfirmedAt: Date?

    // ─── 文字起こし表示オプション (E-series UI overhaul) ───
    /// 「回り込み」と推定されたセグメントを隠すか。検索バーと全文セクションで共有。
    @State var hideEcho: Bool = true

    // ─── Export 関連 ───
    @State var showFormatChooser: Bool = false
    @State var exportDocument: MinutesExportDocument?
    @State var exportFormat: ExportFormat = .markdown
    @State var exportSuggestedName: String = "minutes"
    @State var isPreparingExport: Bool = false

    // ─── ログ表示シート ───
    /// 「ログを表示」ボタンで開く会話ログ / Markdown プレビュー。
    /// `nil` の間はシート非表示。
    @State var previewMinutes: MeetingMinutes?
    @State var isPreparingPreview: Bool = false

    @State var isWaveformExpanded: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let recording = viewModel.selectedRecording {
                    header(recording: recording)
                    waveformSection(recording: recording)
                }
                transcriptSection
                summarySection
                diagnosticsSection
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(viewModel.selectedRecording?.title ?? "詳細")
    }

    // MARK: - Shared helpers

    func sectionHeader(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    /// 「進行中…」の inline 表示。spacing と背景を統一。
    func inlineProgress(_ message: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    /// 空状態の中間ボックス。
    func emptyBox(title: String, message: String, systemImage: String) -> some View {
        VStack(alignment: .center, spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(Theme.Spacing.lg)
        .subtleSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.sm) {
                    if let assignee = item.assignee {
                        Label(assignee, systemImage: "person")
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .monospacedDigit()
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Export Document

/// `.fileExporter` 用のドキュメント。テキストと選択フォーマットを保持する。
///
/// macOS 26 の `FileDocument` は値型でなければならないため、`struct` で実装する。
struct MinutesExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        // 読み込みは想定しないが、プロトコル要求のため両方宣言する
        var types: [UTType] = [.plainText]
        if let md = UTType("net.daringfireball.markdown") {
            types.append(md)
        }
        return types
    }

    static var writableContentTypes: [UTType] { readableContentTypes }

    let text: String
    let format: ExportFormat

    init(text: String, format: ExportFormat) {
        self.text = text
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
        self.format = .markdown
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = nil // SwiftUI が defaultFilename + 拡張子を使う
        return wrapper
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With data") {
    let vm = AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: previewRepository(),
        transcription: FakeTranscriptionService(),
        summary: FakeSummaryService()
    )
    return RecordingDetailView(viewModel: vm)
        .task {
            await vm.refreshList()
            await vm.select(SampleData.recording)
        }
        .frame(width: 600, height: 700)
}

#Preview("With data (Dark)") {
    let vm = AppViewModel(
        capture: FakeAudioCaptureService(),
        repository: previewRepository(),
        transcription: FakeTranscriptionService(),
        summary: FakeSummaryService()
    )
    return RecordingDetailView(viewModel: vm)
        .task {
            await vm.refreshList()
            await vm.select(SampleData.recording)
        }
        .frame(width: 600, height: 700)
        .preferredColorScheme(.dark)
}

@MainActor
private func previewRepository() -> InMemoryRecordingRepository {
    let repo = InMemoryRecordingRepository(seed: [SampleData.recording])
    Task {
        try? await repo.saveSegments(SampleData.segments, for: SampleData.recording.id)
        try? await repo.saveSummary(SampleData.summary)
    }
    return repo
}
#endif
