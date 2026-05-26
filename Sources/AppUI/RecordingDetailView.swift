import SwiftUI
import Contracts

/// 個別録音の詳細ビュー。
///
/// 文字起こし（mic = 右寄せ / system = 左寄せのチャットスタイル）と
/// 構造化要約を縦並びで表示する。
struct RecordingDetailView: View {
    @Bindable var viewModel: AppViewModel
    @State private var regenerateHint: String = ""
    @State private var showHintField: Bool = false

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
            sectionHeader(title: "文字起こし", systemImage: "text.bubble")

            if viewModel.segments.isEmpty {
                emptyBox(message: "文字起こしがまだありません")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(viewModel.segments) { segment in
                        TranscriptBubble(segment: segment)
                    }
                }
            }
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

            if let summary = viewModel.summaryDocument {
                summaryContent(summary)
            } else {
                emptyBox(message: "要約はまだ生成されていません")
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
        }
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
