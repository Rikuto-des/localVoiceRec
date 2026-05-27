import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Summary

    /// 要約セクション全体のレイアウト。
    ///
    /// 表示状態を以下に整理:
    /// - `availabilityNotice` (Apple Intelligence 不可)
    /// - 失敗バナー (`lastError` が summary 由来の場合は赤バナー + 再生成)
    /// - 生成中 (`isSummarizingSelected`)
    /// - 生成済 (`SummaryContent` が 5 ブロックに分割表示)
    /// - 未生成 (`ContentUnavailableView` 的な空状態)
    @ViewBuilder
    var summarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SummaryHeader(summary: viewModel.summaryDocument) {
                regenerateControls
            }

            availabilityNotice
            summaryErrorBanner

            if viewModel.isSummarizingSelected && viewModel.summaryDocument == nil {
                inlineProgress("要約を生成中…")
            } else if let summary = viewModel.summaryDocument {
                SummaryContent(
                    summary: summary,
                    onRegenerate: {
                        Task { await viewModel.regenerateSummary(hint: nil) }
                    },
                    isRegenerating: viewModel.isSummarizingSelected,
                    canRegenerate: !viewModel.isBusy
                        && !viewModel.isSummarizingSelected
                        && !viewModel.segments.isEmpty
                        && isSummaryAvailable
                )
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

    /// 直近の `lastError` が要約由来っぽい場合だけ赤バナーを出す。
    /// 完全な分類は AppViewModel 側に無いため、文字列マッチングで簡易判定する。
    @ViewBuilder
    var summaryErrorBanner: some View {
        if let err = viewModel.lastError,
           err.contains("要約") || err.localizedCaseInsensitiveContains("summary") {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.Palette.error)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("要約の生成に失敗しました")
                        .font(.subheadline.weight(.semibold))
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await viewModel.regenerateSummary(hint: nil) }
                } label: {
                    Label("再生成", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isBusy || viewModel.isSummarizingSelected || !isSummaryAvailable)
            }
            .padding(Theme.Spacing.sm)
            .background(
                Theme.Palette.error.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.error.opacity(0.4), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
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
                TextField("ヒント(任意)", text: $regenerateHint)
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
            .help(showHintField ? "ヒントを使って要約を再生成します" : "要約を再生成します(任意でヒントを与えられます)")

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
}
