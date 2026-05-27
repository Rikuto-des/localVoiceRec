import SwiftUI
import Contracts
import AppKit

/// 「全文テキスト (コピー用)」セクション。
///
/// 3 種類のコピー (plain / markdown / no timestamp) と「回り込み除外」トグルを提供する。
struct TranscriptFullTextSection: View {
    let segments: [TranscriptSegment]
    @Binding var isExpanded: Bool
    @Binding var hideEcho: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyConfirmedAt: Date?
    @State private var copyConfirmedMode: CopyMode?

    enum CopyMode {
        case plain
        case markdown
        case noTimestamp

        var label: String {
            switch self {
            case .plain: return "全文をコピー"
            case .markdown: return "Markdown でコピー"
            case .noTimestamp: return "タイムスタンプなしでコピー"
            }
        }

        var icon: String {
            switch self {
            case .plain: return "doc.on.doc"
            case .markdown: return "doc.richtext"
            case .noTimestamp: return "text.alignleft"
            }
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Slack や Notion に貼り付けやすい、整形済みプレーンテキストです。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let at = copyConfirmedAt,
                       Date().timeIntervalSince(at) < 2.0,
                       let mode = copyConfirmedMode {
                        Label("\(mode.label) をコピーしました", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.success)
                            .transition(reduceMotion ? .identity : .opacity)
                            .accessibilityLabel("クリップボードにコピーしました")
                    }
                }

                Toggle(isOn: $hideEcho) {
                    Text("回り込みを除外してコピー")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                ScrollView(.vertical) {
                    Text(verbatim: currentFullText)
                        .font(.system(.body))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Spacing.sm)
                }
                .frame(minHeight: 140, maxHeight: 320)
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

                HStack(spacing: Theme.Spacing.sm) {
                    copyButton(.plain)
                    copyButton(.markdown)
                    copyButton(.noTimestamp)
                }
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            Label("全文テキスト（コピー用）", systemImage: "text.alignleft")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.top, Theme.Spacing.sm)
    }

    // MARK: - Buttons

    @ViewBuilder
    private func copyButton(_ mode: CopyMode) -> some View {
        Button {
            copy(mode: mode)
        } label: {
            Label(mode.label, systemImage: mode.icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(visibleSegments.isEmpty)
        .help(helpText(for: mode))
    }

    private func helpText(for mode: CopyMode) -> String {
        switch mode {
        case .plain: return "タイムスタンプ付きプレーンテキストでクリップボードへコピー"
        case .markdown: return "Markdown 形式 (見出し + 引用) でクリップボードへコピー"
        case .noTimestamp: return "話者と本文のみをコピー"
        }
    }

    // MARK: - Text generation

    private var visibleSegments: [TranscriptSegment] {
        let sorted = segments.sorted { $0.startSec < $1.startSec }
        return hideEcho ? sorted.filter { !$0.isLikelyEcho } : sorted
    }

    private var currentFullText: String {
        formatted(mode: .plain)
    }

    func formatted(mode: CopyMode) -> String {
        let segs = visibleSegments
        guard !segs.isEmpty else { return "（文字起こし結果がここに表示されます）" }
        switch mode {
        case .plain:
            return segs.map { seg in
                let ts = AppFormatters.timestamp(from: seg.startSec)
                let speaker = seg.source == .mic ? "自分" : "相手"
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "[\(ts)] \(speaker): \(text)"
            }.joined(separator: "\n")
        case .markdown:
            var out = "## 文字起こし\n\n"
            for seg in segs {
                let ts = AppFormatters.timestamp(from: seg.startSec)
                let speaker = seg.source == .mic ? "自分" : "相手"
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "**\(speaker)** `\(ts)`\n> \(text)\n\n"
            }
            return out
        case .noTimestamp:
            return segs.map { seg in
                let speaker = seg.source == .mic ? "自分" : "相手"
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(speaker): \(text)"
            }.joined(separator: "\n")
        }
    }

    private func copy(mode: CopyMode) {
        let text = formatted(mode: mode)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            copyConfirmedAt = Date()
            copyConfirmedMode = mode
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                if let at = copyConfirmedAt, Date().timeIntervalSince(at) >= 2.0 {
                    copyConfirmedAt = nil
                    copyConfirmedMode = nil
                }
            }
        }
    }
}

#if DEBUG
private struct PreviewWrapper: View {
    @State var expanded = true
    @State var hide = true
    var body: some View {
        let rid = UUID()
        TranscriptFullTextSection(
            segments: [
                TranscriptSegment(recordingID: rid, source: .mic,
                                  startSec: 0, endSec: 3, text: "アジェンダを確認します。", isFinal: true),
                TranscriptSegment(recordingID: rid, source: .system,
                                  startSec: 4, endSec: 7, text: "了解です。", isFinal: true),
            ],
            isExpanded: $expanded,
            hideEcho: $hide
        )
        .padding()
        .frame(width: 580)
    }
}

#Preview {
    PreviewWrapper()
}
#endif
