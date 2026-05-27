import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Summary

    @ViewBuilder
    var summarySection: some View {
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
    var availabilityNotice: some View {
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

    func reasonText(_ reason: SummaryAvailability.UnavailableReason) -> String {
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

    /// 要約の再生成ボタン + ヒント入力欄 + エクスポート (ExportSection 側で実装) を横並びで配置。
    @ViewBuilder
    var regenerateControls: some View {
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

            exportControls
        }
    }

    var isSummaryAvailable: Bool {
        switch viewModel.summaryAvailability {
        case .available:
            return true
        case .unavailable:
            return false
        }
    }

    @ViewBuilder
    func summaryContent(_ summary: SummaryDocument) -> some View {
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

    @ViewBuilder
    func summaryBlock<Content: View>(
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

    @ViewBuilder
    func bulletList(_ items: [String]) -> some View {
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
