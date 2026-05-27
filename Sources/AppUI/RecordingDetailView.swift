import SwiftUI
import UniformTypeIdentifiers
import Contracts
import ExportKit

/// 個別録音の詳細ビュー。
///
/// 文字起こし（mic = 右寄せ / system = 左寄せのチャットスタイル）と
/// 構造化要約を縦並びで表示する。
struct RecordingDetailView: View {
    @Bindable var viewModel: AppViewModel
    @State private var regenerateHint: String = ""
    @State private var showHintField: Bool = false
    @State private var showTranscribeReconfirm: Bool = false

    // ─── Export 関連 ───
    @State private var showFormatChooser: Bool = false
    @State private var exportDocument: MinutesExportDocument?
    @State private var exportFormat: ExportFormat = .markdown
    @State private var exportSuggestedName: String = "minutes"
    @State private var isPreparingExport: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let recording = viewModel.selectedRecording {
                    header(recording: recording)
                }
                transcriptSection
                summarySection
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(viewModel.selectedRecording?.title ?? "詳細")
    }

    // MARK: - Header

    private func header(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(recording.title)
                .font(.title2.bold())
            HStack(spacing: Theme.Spacing.sm) {
                Label(
                    AppFormatters.dateTime.string(from: recording.startedAt),
                    systemImage: "calendar"
                )
                Label(
                    AppFormatters.duration(recording.duration),
                    systemImage: "clock"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                sectionHeader(title: "文字起こし", systemImage: "text.bubble")
                Spacer()
                transcribeControls
            }

            if viewModel.isTranscribingSelected && viewModel.segments.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("文字起こしを実行中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius))
            } else if viewModel.segments.isEmpty {
                if let id = viewModel.selectedRecording?.id,
                   viewModel.emptyTranscriptIDs.contains(id) {
                    emptyBox(message: "音声内容が検出されませんでした。無音または対応言語外の可能性があります。")
                } else {
                    emptyBox(message: "文字起こしを準備しています…時間がかかる場合は「文字起こしを実行」を押してください。")
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(viewModel.segments) { segment in
                        TranscriptBubble(segment: segment)
                    }
                    if viewModel.isTranscribingSelected {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("追加の発話を解析中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                }
            }
        }
    }

    private var transcribeControls: some View {
        Button {
            // 初回（segments 空）はそのまま実行。
            // 既存 segments がある場合は confirmation を出す（誤って消さない）。
            if viewModel.segments.isEmpty {
                Task {
                    if let recording = viewModel.selectedRecording {
                        await viewModel.transcribeRecording(recording)
                    }
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
            "文字起こしを再実行しますか？",
            isPresented: $showTranscribeReconfirm,
            titleVisibility: .visible
        ) {
            Button("再実行する", role: .destructive) {
                Task {
                    if let recording = viewModel.selectedRecording {
                        await viewModel.transcribeRecording(recording)
                    }
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("既存の文字起こし結果は上書きされます。要約も再生成が必要になる場合があります。")
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                sectionHeader(title: "要約", systemImage: "doc.text.magnifyingglass")
                Spacer()
                regenerateControls
            }

            availabilityNotice

            if viewModel.isSummarizingSelected && viewModel.summaryDocument == nil {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("要約を生成中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius))
            } else if let summary = viewModel.summaryDocument {
                summaryContent(summary)
            } else if viewModel.segments.isEmpty {
                emptyBox(message: "先に文字起こしを実行してください")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    emptyBox(message: "要約はまだ生成されていません")
                    Button {
                        Task {
                            if let recording = viewModel.selectedRecording {
                                await viewModel.summarizeRecording(recording)
                            }
                        }
                    } label: {
                        Label("要約を生成", systemImage: "sparkles")
                    }
                    .disabled(viewModel.isSummarizingSelected || !isSummaryAvailable)
                }
            }
        }
    }

    @ViewBuilder
    private var availabilityNotice: some View {
        switch viewModel.summaryAvailability {
        case .available:
            EmptyView()
        case .unavailable(let reason):
            Label(reasonText(reason), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(Theme.Spacing.sm)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius))
        }
    }

    private func reasonText(_ reason: SummaryAvailability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "この端末では Apple Intelligence が利用できません"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence が有効になっていません"
        case .modelNotReady:
            return "モデルの準備が完了していません"
        case .unsupportedOS:
            return "OS バージョンが要約機能に対応していません"
        }
    }

    private var regenerateControls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if showHintField {
                TextField("ヒント（任意）", text: $regenerateHint)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            Button {
                if !showHintField {
                    showHintField = true
                } else {
                    Task {
                        let hint = regenerateHint.isEmpty ? nil : regenerateHint
                        await viewModel.regenerateSummary(hint: hint)
                        showHintField = false
                        regenerateHint = ""
                    }
                }
            } label: {
                Label("要約を再生成", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(
                viewModel.isBusy ||
                viewModel.isSummarizingSelected ||
                viewModel.segments.isEmpty ||
                !isSummaryAvailable
            )

            if showHintField {
                Button {
                    showHintField = false
                    regenerateHint = ""
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }

            // ─── Export ───
            Button {
                showFormatChooser = true
            } label: {
                Label("エクスポート", systemImage: "square.and.arrow.up")
            }
            .disabled(
                viewModel.selectedRecording == nil ||
                isPreparingExport ||
                viewModel.isTranscribingSelected ||
                viewModel.isSummarizingSelected
            )
            .confirmationDialog(
                "エクスポート形式を選択",
                isPresented: $showFormatChooser,
                titleVisibility: .visible
            ) {
                ForEach(ExportFormat.allCases) { format in
                    Button(format.displayName) {
                        Task { await prepareExport(format: format) }
                    }
                }
                Button("キャンセル", role: .cancel) { }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { newValue in
                        if !newValue { exportDocument = nil }
                    }
                ),
                document: exportDocument,
                contentType: utType(for: exportFormat),
                defaultFilename: exportSuggestedName
            ) { result in
                switch result {
                case .success:
                    exportDocument = nil
                case .failure(let error):
                    viewModel.reportExportFailure("エクスポートに失敗しました: \(error.localizedDescription)")
                    exportDocument = nil
                }
            }
        }
    }

    private func utType(for format: ExportFormat) -> UTType {
        UTType(format.utTypeIdentifier) ?? (format == .markdown ? .plainText : .plainText)
    }

    private func prepareExport(format: ExportFormat) async {
        guard let recording = viewModel.selectedRecording else { return }
        isPreparingExport = true
        defer { isPreparingExport = false }
        do {
            let text = try await viewModel.exportText(for: recording, format: format)
            self.exportFormat = format
            self.exportSuggestedName = suggestedFilename(for: recording, format: format)
            self.exportDocument = MinutesExportDocument(text: text, format: format)
        } catch {
            viewModel.reportExportFailure("エクスポート用データの生成に失敗しました: \(String(describing: error))")
        }
    }

    private func suggestedFilename(for recording: Recording, format: ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyyMMdd"
        let dateStr = formatter.string(from: recording.startedAt)
        let safeTitle = recording.title
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safeTitle)_\(dateStr)"
        // 拡張子は SwiftUI が contentType から自動で付与する
        // 形式選択結果は exportFormat 経由で反映される
        // （format 引数自体は将来の拡張用に残しておく）
    }

    private var isSummaryAvailable: Bool {
        switch viewModel.summaryAvailability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    private func summaryContent(_ summary: SummaryDocument) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            summaryBlock(title: "概要") {
                Text(summary.overview)
                    .font(.body)
            }

            summaryBlock(title: "決定事項") {
                bulletList(summary.decisions)
            }

            summaryBlock(title: "アクションアイテム") {
                if summary.actionItems.isEmpty {
                    Text("（なし）").foregroundStyle(.secondary).font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            ActionItemRow(item: item)
                        }
                    }
                }
            }

            summaryBlock(title: "未解決の問い") {
                bulletList(summary.openQuestions)
            }

            summaryBlock(title: "レビュー項目") {
                bulletList(summary.reviewItems)
            }

            HStack {
                Spacer()
                Text("生成: \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius)
        )
    }

    private func bulletList(_ items: [String]) -> some View {
        Group {
            if items.isEmpty {
                Text("（なし）").foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text("•").foregroundStyle(.secondary)
                            Text(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func emptyBox(message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(Theme.Spacing.lg)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius)
            )
    }
}

// MARK: - TranscriptBubble

private struct TranscriptBubble: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack {
            if segment.source == .mic {
                Spacer(minLength: 40)
                bubble(alignment: .trailing)
            } else {
                bubble(alignment: .leading)
                Spacer(minLength: 40)
            }
        }
    }

    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: segment.source == .mic ? "person.fill" : "speaker.wave.2.fill")
                    .font(.caption2)
                Text(speakerLabel)
                    .font(.caption2)
                Text(AppFormatters.timestamp(from: segment.startSec))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(segment.source == .mic ? .secondary : .secondary)

            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.source == .mic ? Theme.Palette.micText : Theme.Palette.systemText)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    segment.source == .mic ? Theme.Palette.micBubble : Theme.Palette.systemBubble,
                    in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius)
                )
                .frame(maxWidth: Theme.Layout.bubbleMaxWidth, alignment: alignment == .trailing ? .trailing : .leading)

            if !segment.isFinal {
                Text("（暫定）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var speakerLabel: String {
        switch segment.source {
        case .mic: return "自分"
        case .system: return "相手"
        }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                HStack(spacing: Theme.Spacing.sm) {
                    if let assignee = item.assignee {
                        Label(assignee, systemImage: "person")
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Export Document

/// `.fileExporter` 用のドキュメント。テキストと選択フォーマットを保持する。
///
/// macOS 26 の `FileDocument` は値型でなければならないため、`struct` で実装する。
private struct MinutesExportDocument: FileDocument {
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

@MainActor
private func previewRepository() -> InMemoryRecordingRepository {
    let repo = InMemoryRecordingRepository(seed: [SampleData.recording])
    Task {
        try? await repo.saveSegments(SampleData.segments, for: SampleData.recording.id)
        try? await repo.saveSummary(SampleData.summary)
    }
    return repo
}
