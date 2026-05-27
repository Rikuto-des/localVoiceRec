import SwiftUI
import UniformTypeIdentifiers
import Contracts
import ExportKit
import AppKit

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
struct RecordingDetailView: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var regenerateHint: String = ""
    @State private var showHintField: Bool = false
    @State private var showTranscribeReconfirm: Bool = false

    // ─── 全文テキスト関連 (S15) ───
    @State private var isFullTextExpanded: Bool = false
    @State private var fullTextCopyConfirmedAt: Date?

    // ─── Export 関連 ───
    @State private var showFormatChooser: Bool = false
    @State private var exportDocument: MinutesExportDocument?
    @State private var exportFormat: ExportFormat = .markdown
    @State private var exportSuggestedName: String = "minutes"
    @State private var isPreparingExport: Bool = false

    @State private var isWaveformExpanded: Bool = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let recording = viewModel.selectedRecording {
                    header(recording: recording)
                    waveformSection(recording: recording)
                }
                transcriptSection
                summarySection
                DiagnosticsPanel(viewModel: viewModel)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(viewModel.selectedRecording?.title ?? "詳細")
    }

    // MARK: - Header

    private func header(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Button {
                    FinderReveal.openRecordingFolder(for: recording)
                } label: {
                    Label("Finder で開く", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("録音ファイルが入っているフォルダを Finder で開きます")
                .accessibilityLabel("Finder で録音フォルダを開く")
            }
            HStack(spacing: Theme.Spacing.md) {
                Label {
                    Text(AppFormatters.dateTime.string(from: recording.startedAt))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "calendar")
                }
                Label {
                    Text(AppFormatters.duration(recording.duration))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Waveform

    private func waveformSection(recording: Recording) -> some View {
        DisclosureGroup(isExpanded: $isWaveformExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                StaticWaveformView(
                    url: recording.micAudioURL,
                    label: "Mic（自分）",
                    tint: .accentColor
                )
                StaticWaveformView(
                    url: recording.systemAudioURL,
                    label: "System（相手）",
                    tint: Theme.Palette.warning
                )
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            Label("録音波形", systemImage: "waveform")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(Theme.Spacing.md)
        .subtleSurface()
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(title: "文字起こし", systemImage: "text.bubble")
                Spacer()
                transcribeControls
            }

            if viewModel.isTranscribingSelected && viewModel.segments.isEmpty {
                inlineProgress("文字起こしを実行中…")
            } else if viewModel.segments.isEmpty {
                if let id = viewModel.selectedRecording?.id,
                   viewModel.emptyTranscriptIDs.contains(id) {
                    emptyBox(
                        title: "音声内容が検出されませんでした",
                        message: "無音または対応言語外の可能性があります。",
                        systemImage: "speaker.slash"
                    )
                } else {
                    emptyBox(
                        title: "文字起こしを準備しています",
                        message: "時間がかかる場合は「文字起こしを実行」を押してください。",
                        systemImage: "ellipsis.bubble"
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(viewModel.segments) { segment in
                        TranscriptBubble(segment: segment)
                    }
                    if viewModel.isTranscribingSelected {
                        HStack(spacing: Theme.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("追加の発話を解析中…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                    fullTextSection
                }
            }
        }
    }

    // MARK: - Full text (S15: Slack 等への貼り付け用)

    /// 折りたたみ式の「全文テキスト」セクション。
    /// `[mm:ss] mic: 内容` 形式のプレーンテキストで、TextEditor 経由でコピーペースト可能。
    private var fullTextSection: some View {
        DisclosureGroup(isExpanded: $isFullTextExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Slack や Notion に貼り付けやすい、タイムスタンプ付きプレーンテキストです。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let at = fullTextCopyConfirmedAt,
                       Date().timeIntervalSince(at) < 2.0 {
                        Label("コピーしました", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.success)
                            .transition(reduceMotion ? .identity : .opacity)
                            .accessibilityLabel("クリップボードにコピーしました")
                    }
                    Button {
                        copyFullTextToPasteboard()
                    } label: {
                        Label("全文をコピー", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.segments.isEmpty)
                    .help("全文をクリップボードへコピーします")
                }

                TextEditor(text: .constant(fullTextString))
                    .font(.system(.body, design: .monospaced))
                    .lineSpacing(2)
                    .frame(minHeight: 140, maxHeight: 320)
                    .padding(Theme.Spacing.xs)
                    .background(
                        Theme.Palette.textField,
                        in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                            .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
                    )
                    .accessibilityLabel("全文テキスト")
                    .accessibilityHint("選択してコピーできます")
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            Label("全文テキスト（コピー用）", systemImage: "text.alignleft")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.top, Theme.Spacing.sm)
    }

    /// `[mm:ss] mic: text` 形式の plain text を組み立てる。
    /// segments が空の場合は説明文を返す（TextEditor の placeholder 代わり）。
    private var fullTextString: String {
        let sorted = viewModel.segments.sorted { $0.startSec < $1.startSec }
        guard !sorted.isEmpty else {
            return "（文字起こし結果がここに表示されます）"
        }
        var out = ""
        for seg in sorted {
            let ts = AppFormatters.timestamp(from: seg.startSec)
            let speaker = seg.source == .mic ? "mic" : "system"
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "[\(ts)] \(speaker): \(text)\n"
        }
        return out
    }

    private func copyFullTextToPasteboard() {
        let text = fullTextString
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            fullTextCopyConfirmedAt = Date()
        }
        // 2 秒後にバッジを消す
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                // 自分以降に別のコピーが走っていなければ消す
                if let at = fullTextCopyConfirmedAt, Date().timeIntervalSince(at) >= 2.0 {
                    fullTextCopyConfirmedAt = nil
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
                Label("実行中…", systemImage: "ellipsis")
            } else if viewModel.segments.isEmpty {
                Label("文字起こしを実行", systemImage: "waveform.badge.plus")
            } else {
                Label("再実行", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(viewModel.isTranscribingSelected || viewModel.selectedRecording == nil)
        .help(viewModel.segments.isEmpty ? "Speech フレームワークで文字起こしを開始します" : "既存の文字起こしを破棄して再実行します")
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
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(title: "要約", systemImage: "doc.text.magnifyingglass")
                Spacer()
                regenerateControls
            }

            availabilityNotice

            if viewModel.isSummarizingSelected && viewModel.summaryDocument == nil {
                inlineProgress("要約を生成中…")
            } else if let summary = viewModel.summaryDocument {
                summaryContent(summary)
            } else if viewModel.segments.isEmpty {
                emptyBox(
                    title: "要約はまだありません",
                    message: "先に文字起こしを実行してください。",
                    systemImage: "doc.text"
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    emptyBox(
                        title: "要約はまだ生成されていません",
                        message: "「要約を生成」を押すと Apple Intelligence で要約します。",
                        systemImage: "sparkles"
                    )
                    Button {
                        Task {
                            if let recording = viewModel.selectedRecording {
                                await viewModel.summarizeRecording(recording)
                            }
                        }
                    } label: {
                        Label("要約を生成", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(viewModel.isSummarizingSelected || !isSummaryAvailable)
                    .help("Apple Intelligence で要約を生成します")
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
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.warning)
                    .accessibilityHidden(true)
                Text(reasonText(reason))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.sm)
            .background(
                Theme.Palette.warning.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.warning.opacity(0.4), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
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
                    .controlSize(.small)
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                viewModel.isBusy ||
                viewModel.isSummarizingSelected ||
                viewModel.segments.isEmpty ||
                !isSummaryAvailable
            )
            .help(showHintField ? "ヒントを使って要約を再生成します" : "要約を再生成します（任意でヒントを与えられます）")

            if showHintField {
                Button {
                    showHintField = false
                    regenerateHint = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .accessibilityLabel("ヒント入力をキャンセル")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("ヒント入力を閉じます")
            }

            // ─── Export ───
            Button {
                showFormatChooser = true
            } label: {
                Label("エクスポート", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                viewModel.selectedRecording == nil ||
                isPreparingExport ||
                viewModel.isTranscribingSelected ||
                viewModel.isSummarizingSelected
            )
            .help("議事録を Markdown / プレーンテキストでエクスポートします")
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            summaryBlock(title: "決定事項") {
                bulletList(summary.decisions)
            }

            summaryBlock(title: "アクションアイテム") {
                if summary.actionItems.isEmpty {
                    Text("（なし）")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func summaryBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleSurface()
    }

    private func bulletList(_ items: [String]) -> some View {
        Group {
            if items.isEmpty {
                Text("（なし）")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Text("•")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(item)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityAddTraits(.isHeader)
    }

    /// 「進行中…」の inline 表示。spacing と背景を統一。
    private func inlineProgress(_ message: String) -> some View {
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
    private func emptyBox(title: String, message: String, systemImage: String) -> some View {
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

// MARK: - TranscriptBubble

/// チャット風の発話バブル。
///
/// HIG: 自分 (mic) は trailing / 相手 (system) は leading に寄せる。
/// 色は `Theme.Palette.micBubble` (accentColor) と `systemBubble` (controlBackground) で
/// アクセシビリティ的にも 1 種の色だけに依存しないよう、アイコン + ラベルテキストでも区別。
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerLabel) \(AppFormatters.timestamp(from: segment.startSec)): \(segment.text)")
    }

    private func bubble(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: segment.source == .mic ? "person.fill" : "speaker.wave.2.fill")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text(speakerLabel)
                    .font(.caption2)
                Text(AppFormatters.timestamp(from: segment.startSec))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)

            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.source == .mic ? Theme.Palette.micText : Theme.Palette.systemText)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    segment.source == .mic ? Theme.Palette.micBubble : Theme.Palette.systemBubble,
                    in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                )
                .frame(maxWidth: Theme.Layout.bubbleMaxWidth, alignment: alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)

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
