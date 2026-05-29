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

    // ─── タイトルインライン編集 (HeaderSection が利用) ───
    /// タイトル編集モードか。`HeaderSection` の `TitleEditableView` から bindings 経由で参照する。
    @State var isEditingTitle: Bool = false
    /// 編集中のドラフト文字列。
    @State var draftTitle: String = ""

    // ─── 全文テキスト関連 (S15) ───
    @State var isFullTextExpanded: Bool = false
    @State var fullTextCopyConfirmedAt: Date?

    // ─── 文字起こし表示オプション (E-series UI overhaul) ───
    /// 「回り込み」と推定されたセグメントを隠すか。検索バーと全文セクションで共有。
    @State var hideEcho: Bool = true

    // ─── Export 関連 ───
    // 旧 SwiftUI `.fileExporter` 経路は撤去 (sheet と同時提示できない問題で実質機能していなかった)。
    // 現在は `NSSavePanel` をシート閉じ後に直接呼ぶ。`isPreparingExport` だけ進捗フラグとして残す。
    @State var isPreparingExport: Bool = false

    // ─── ログ表示シート ───
    /// 「ログを表示」ボタンで開く会話ログ / Markdown プレビュー。
    /// `nil` の間はシート非表示。
    @State var previewMinutes: MeetingMinutes?
    @State var isPreparingPreview: Bool = false

    /// シート内「保存…」が押されたときに format を保持する。
    /// シートが `dismiss()` し終わった `onDismiss` でこの値を読み、`NSSavePanel` を起動する。
    /// SwiftUI が同時に複数の sheet 系 modal を提示できない制約への対処。
    @State var pendingSaveFormat: ExportFormat?

    @State var isWaveformExpanded: Bool = true

    // ─── 中央セクションのタブ選択 (Agent A が body 側で利用) ───
    /// 「文字起こし | 要約」のいずれを表示するか。
    /// 録音を開いた際、要約が実質的にあれば `.summary`、なければ `.transcript` を初期値にする
    /// (`body` 側の `.task` で計算)。
    @State var detailSectionTab: DetailSectionTab = .summary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let recording = viewModel.selectedRecording {
                    header(recording: recording)
                    waveformSection(recording: recording)
                    sectionTabPicker
                }
                selectedSectionBody
                diagnosticsSection
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: viewModel.selectedRecording?.id) {
            // 録音オープン時のデフォルトタブ。要約に実体があれば要約、なければ文字起こし。
            // 「実体」は要約自身が空でないかで判断する (transcript セグメント数では判断しない)。
            let summary = viewModel.summaryDocument
            let hasOverview = !(summary?.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            detailSectionTab = hasOverview ? .summary : .transcript
        }
        .navigationTitle(viewModel.selectedRecording?.title ?? "詳細")
    }

    // MARK: - Section tab (中央セクション切り替え)

    /// 「文字起こし | 要約」の segmented picker。中央寄せでマック標準の見た目に揃える。
    private var sectionTabPicker: some View {
        HStack {
            Spacer()
            Picker("", selection: $detailSectionTab) {
                ForEach(DetailSectionTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityLabel("セクション切り替え")
            Spacer()
        }
    }

    /// 選択中のタブに応じて transcript / summary のいずれかを表示する。
    @ViewBuilder
    private var selectedSectionBody: some View {
        Group {
            switch detailSectionTab {
            case .transcript: transcriptSection
            case .summary:    summarySection
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: detailSectionTab)
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
