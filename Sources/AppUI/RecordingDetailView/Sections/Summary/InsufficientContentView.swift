import SwiftUI
import Contracts

/// P50 hallucination guard で生成がスキップされた、または中身がほぼ空だった時の表示。
///
/// `ContentUnavailableView` で「録音が短い / 相槌のみ」可能性を明示し、
/// 「再生成」ボタンで再試行可能にする。
struct InsufficientContentView: View {
    let onRegenerate: () -> Void
    let isRegenerating: Bool
    let canRegenerate: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            ContentUnavailableView {
                Label("十分な内容が無いため要約を生成しませんでした", systemImage: "text.magnifyingglass")
            } description: {
                Text("録音が短いか、相槌のみで構成されている可能性があります。\n手動で再生成する場合は下のボタンを押してください。")
                    .multilineTextAlignment(.center)
            } actions: {
                Button {
                    onRegenerate()
                } label: {
                    Label("要約を再生成", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRegenerating || !canRegenerate)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .subtleSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("十分な内容が無いため要約を生成しませんでした")
    }
}

/// `SummaryDocument` が「十分な内容が無いため要約を生成しませんでした」相当か判定するヘルパー。
///
/// - overview が定型文 ("十分な内容..." 等) を含み、かつ
/// - decisions / actionItems / openQuestions / reviewItems が全て空
/// の時 true。
enum SummaryInsufficiency {
    private static let markers: [String] = [
        "要約を生成できる十分な内容がありません",
        "十分な内容がありません",
        "十分な内容が無い"
    ]

    static func isInsufficient(_ summary: SummaryDocument) -> Bool {
        let trimmed = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEmpty = summary.decisions.isEmpty
            && summary.actionItems.isEmpty
            && summary.openQuestions.isEmpty
            && summary.reviewItems.isEmpty
        let hasMarker = markers.contains { trimmed.contains($0) }
        return hasMarker && allEmpty
    }
}

#if DEBUG
#Preview("Insufficient - 通常") {
    InsufficientContentView(
        onRegenerate: {},
        isRegenerating: false,
        canRegenerate: true
    )
    .padding()
    .frame(width: 480)
}
#endif
