import SwiftUI
import Contracts
import AppKit

extension RecordingDetailView {
    // MARK: - Transcript

    @ViewBuilder
    var transcriptSection: some View {
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
    @ViewBuilder
    var fullTextSection: some View {
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

    @ViewBuilder
    var transcribeControls: some View {
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
}
