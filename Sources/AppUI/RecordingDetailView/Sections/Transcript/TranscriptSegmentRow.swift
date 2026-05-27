import SwiftUI
import Contracts
import AppKit

/// 1 セグメントを表す行。
///
/// HIG 準拠の方針:
/// - 自分 (mic) は trailing / 相手 (system) は leading に寄せたチャットバブル
/// - 色 + アイコン + テキストの 3 要素で話者を区別 (色だけに依存しない)
/// - hover で コピー / 編集 (将来) / 該当時点から再生 (将来) のアクションを出す
/// - `isLikelyEcho == true` は opacity を落とし、「回り込み」バッジを付ける
/// - `accessibilityLabel` に「話者・時刻・本文」を組み立てて読み上げ
struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    /// 検索ハイライト対象の語句。空文字列なら無視。
    let highlightQuery: String
    /// コピー成功時に呼ばれる。
    let onCopy: () -> Void
    /// "該当時刻から再生" (将来用)。現状は disable してプレースホルダ表示。
    let onPlayFromHere: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering: Bool = false
    @State private var copiedAt: Date?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if segment.source == .mic {
                Spacer(minLength: 40)
                bubbleContent(alignment: .trailing)
            } else {
                bubbleContent(alignment: .leading)
                Spacer(minLength: 40)
            }
        }
        .focusable(true)
        .focused($isFocused)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .onCopyCommand {
            copySegment()
            return [NSItemProvider(object: segment.text as NSString)]
        }
        .opacity(segment.isLikelyEcho ? 0.45 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAction(named: Text("コピー")) { copySegment() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func bubbleContent(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.xs) {
            headerRow(alignment: alignment)
            bubble(alignment: alignment)
            footerRow(alignment: alignment)
        }
    }

    @ViewBuilder
    private func headerRow(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: segment.source == .mic ? "person.crop.circle.fill" : "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(segment.source == .mic ? Color.accentColor : Theme.Palette.systemAudio)
                .accessibilityHidden(true)
            Text(speakerLabel)
                .font(.caption2.weight(.semibold))
            Text(AppFormatters.timestampHMS(from: segment.startSec))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if segment.isLikelyEcho {
                echoBadge
            }
            if !segment.isFinal {
                Text("暫定")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Theme.Palette.warning.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: Theme.Layout.pillCornerRadius, style: .continuous)
                    )
                    .foregroundStyle(Theme.Palette.warning)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubble(alignment: HorizontalAlignment) -> some View {
        highlightedText(segment.text, query: highlightQuery)
            .font(.system(.body))
            .lineSpacing(4)
            .foregroundStyle(segment.source == .mic ? Theme.Palette.micText : Theme.Palette.systemText)
            .textSelection(.enabled)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                segment.source == .mic ? Theme.Palette.micBubble : Theme.Palette.systemBubble,
                in: RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .frame(maxWidth: Theme.Layout.bubbleMaxWidth, alignment: alignment == .trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func footerRow(alignment: HorizontalAlignment) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let at = copiedAt, Date().timeIntervalSince(at) < 2.0 {
                Label("コピーしました", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.success)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if isHovering {
                Button {
                    copySegment()
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("このセグメントをコピー (⌘C)")
                .accessibilityLabel("このセグメントをコピー")

                Button {
                    onPlayFromHere()
                } label: {
                    Label("この時刻から再生", systemImage: "play.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(true)
                .help("この時刻から再生 (準備中)")
                .accessibilityLabel("この時刻から再生 (準備中)")

                Button {
                    // 編集は未実装
                } label: {
                    Label("編集", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(true)
                .help("編集 (準備中)")
                .accessibilityLabel("編集 (準備中)")
            }
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    private var echoBadge: some View {
        Label("回り込み", systemImage: "arrow.uturn.left.circle")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Color.secondary.opacity(0.15),
                in: RoundedRectangle(cornerRadius: Theme.Layout.pillCornerRadius, style: .continuous)
            )
            .accessibilityLabel("回り込みの可能性あり")
    }

    private var speakerLabel: String {
        switch segment.source {
        case .mic: return "自分"
        case .system: return "相手"
        }
    }

    private var accessibilityDescription: String {
        let ts = AppFormatters.timestampHMSSpoken(from: segment.startSec)
        let echo = segment.isLikelyEcho ? "回り込みの可能性あり。" : ""
        let provisional = segment.isFinal ? "" : "暫定。"
        return "\(speakerLabel) \(ts): \(echo)\(provisional)\(segment.text)"
    }

    // MARK: - Helpers

    private func copySegment() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(segment.text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            copiedAt = Date()
        }
        onCopy()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                if let at = copiedAt, Date().timeIntervalSince(at) >= 2.0 {
                    copiedAt = nil
                }
            }
        }
    }

    /// 検索クエリにマッチした箇所を黄色でハイライトした `Text` を返す。
    /// 空クエリ・無一致なら通常の `Text` を返す。
    private func highlightedText(_ text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: trimmed, options: [.caseInsensitive]) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.5)
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchRange = range.upperBound..<attributed.endIndex
            if searchRange.isEmpty { break }
        }
        return Text(attributed)
    }
}

#if DEBUG
#Preview("Mic / System / Echo") {
    VStack(alignment: .leading, spacing: 12) {
        TranscriptSegmentRow(
            segment: TranscriptSegment(
                recordingID: UUID(), source: .mic,
                startSec: 28, endSec: 31,
                text: "はいはい、ではアジェンダの確認から始めます。",
                isFinal: true
            ),
            highlightQuery: "アジェンダ",
            onCopy: {},
            onPlayFromHere: {}
        )
        TranscriptSegmentRow(
            segment: TranscriptSegment(
                recordingID: UUID(), source: .system,
                startSec: 35, endSec: 40,
                text: "了解しました。まず Phase 0 の進捗をお願いします。",
                isFinal: true
            ),
            highlightQuery: "",
            onCopy: {},
            onPlayFromHere: {}
        )
        TranscriptSegmentRow(
            segment: TranscriptSegment(
                recordingID: UUID(), source: .system,
                startSec: 41, endSec: 42,
                text: "（マイクが拾った相手側の声）",
                isFinal: true,
                isLikelyEcho: true
            ),
            highlightQuery: "",
            onCopy: {},
            onPlayFromHere: {}
        )
        TranscriptSegmentRow(
            segment: TranscriptSegment(
                recordingID: UUID(), source: .mic,
                startSec: 45, endSec: 46,
                text: "暫定の中間結果",
                isFinal: false
            ),
            highlightQuery: "",
            onCopy: {},
            onPlayFromHere: {}
        )
    }
    .padding()
    .frame(width: 560)
}
#endif
