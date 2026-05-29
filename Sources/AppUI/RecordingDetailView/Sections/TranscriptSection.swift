import SwiftUI
import Contracts
import AppKit

extension RecordingDetailView {
    // MARK: - Transcript

    /// X3.1.a: mic/system セグメント数を 1 ループで数える。
    /// 旧実装は `segments.filter { ... }.count` × 2 回で各セグメントを最大 2 回触っていた。
    private func transcriptCounts() -> (total: Int, mic: Int, system: Int) {
        var micCount = 0
        var systemCount = 0
        for seg in viewModel.segments {
            switch seg.source {
            case .mic: micCount += 1
            case .system: systemCount += 1
            }
        }
        return (viewModel.segments.count, micCount, systemCount)
    }

    @ViewBuilder
    var transcriptSection: some View {
        let counts = transcriptCounts()
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            TranscriptHeader(
                segmentCount: counts.total,
                micCount: counts.mic,
                systemCount: counts.system
            ) {
                transcribeControls
            }

            if viewModel.isTranscribingSelected && viewModel.segments.isEmpty {
                inlineProgress("文字起こしを実行中…")
            } else if viewModel.segments.isEmpty {
                transcriptEmptyState
            } else {
                TranscriptSegmentList(
                    segments: viewModel.segments,
                    hideEcho: $hideEcho
                )
                if viewModel.isTranscribingSelected {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("追加の発話を解析中…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
                TranscriptFullTextSection(
                    segments: viewModel.segments,
                    isExpanded: $isFullTextExpanded,
                    hideEcho: $hideEcho
                )
            }
        }
    }

    @ViewBuilder
    private var transcriptEmptyState: some View {
        if let id = viewModel.selectedRecording?.id,
           viewModel.emptyTranscriptIDs.contains(id) {
            ContentUnavailableView {
                Label("発話が検出されませんでした", systemImage: "text.bubble")
            } description: {
                Text("録音音声は保存されています。無音区間が多い、未対応言語、または録音が短い場合に起こります。言語設定を確認してから「再実行」してください。")
            } actions: {
                Button {
                    if let recording = viewModel.selectedRecording {
                        Task { await viewModel.transcribeRecording(recording) }
                    }
                } label: {
                    Label("再実行", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isTranscribingSelected || viewModel.selectedRecording == nil)
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.md)
            .subtleSurface()
        } else {
            ContentUnavailableView {
                Label("文字起こしがまだありません", systemImage: "text.bubble")
            } description: {
                Text("「文字起こしを実行」を押すか、新しい録音を開始してください。")
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.md)
            .subtleSurface()
        }
    }

    // MARK: - 互換 API
    // ExportSection など他箇所から参照される全文文字列。
    // 旧実装と同じ `[mm:ss] mic: text` フォーマットを維持する。

    var fullTextString: String {
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

    func copyFullTextToPasteboard() {
        let text = fullTextString
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            fullTextCopyConfirmedAt = Date()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if let at = fullTextCopyConfirmedAt, Date().timeIntervalSince(at) >= 2.0 {
                    fullTextCopyConfirmedAt = nil
                }
            }
        }
    }

    @ViewBuilder
    var transcribeControls: some View {
        Button {
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
        .buttonStyle(.borderedProminent)
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
}
