import SwiftUI
import Contracts

/// `SummaryDocument` を 5 セクション (Overview / Decisions / ActionItems / OpenQuestions / ReviewItems)
/// に分割し、それぞれを `DisclosureGroup` で表示するコンテナ。
///
/// 各セクションの折りたたみ状態をこの View が保持する。
struct SummaryContent: View {
    let summary: SummaryDocument
    let onRegenerate: () -> Void
    let isRegenerating: Bool
    let canRegenerate: Bool

    @State private var overviewExpanded: Bool = SummarySectionKind.overview.defaultsExpanded
    @State private var decisionsExpanded: Bool = SummarySectionKind.decisions.defaultsExpanded
    @State private var actionsExpanded: Bool = SummarySectionKind.actionItems.defaultsExpanded
    @State private var questionsExpanded: Bool = SummarySectionKind.openQuestions.defaultsExpanded
    @State private var reviewExpanded: Bool = SummarySectionKind.reviewItems.defaultsExpanded

    var body: some View {
        if SummaryInsufficiency.isInsufficient(summary) {
            InsufficientContentView(
                onRegenerate: onRegenerate,
                isRegenerating: isRegenerating,
                canRegenerate: canRegenerate
            )
        } else {
            // IA レビュー反映: 会議要約を開く主目的は「自分が何をやるか」のため
            // ActionItems を Decisions より上に配置する。
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                OverviewBlock(
                    overview: summary.overview,
                    isExpanded: $overviewExpanded
                )
                ActionItemsBlock(
                    items: summary.actionItems,
                    isExpanded: $actionsExpanded
                )
                DecisionsBlock(
                    decisions: summary.decisions,
                    isExpanded: $decisionsExpanded
                )
                OpenQuestionsBlock(
                    questions: summary.openQuestions,
                    isExpanded: $questionsExpanded
                )
                ReviewItemsBlock(
                    items: summary.reviewItems,
                    isExpanded: $reviewExpanded
                )
            }
        }
    }
}

#if DEBUG
#Preview("SummaryContent - 通常") {
    SummaryContent(
        summary: SummaryDocument(
            recordingID: UUID(),
            overview: "予算編成のスケジュール調整と、コスト削減のための緊急対策チームの発足を確認した。",
            decisions: [
                "予算編成のスケジュールを 2024 年 8 月に進める",
                "コスト削減のための緊急対策チームを設置"
            ],
            actionItems: [
                ActionItem(title: "予算案を作成して全員に共有する", assignee: "田中", dueDate: Date().addingTimeInterval(86400 * 7)),
                ActionItem(title: "対策チームのキックオフ", assignee: "山田")
            ],
            openQuestions: ["優先順位はどう決めるか"],
            reviewItems: ["予算案の進捗確認"],
            generatedAt: Date()
        ),
        onRegenerate: {},
        isRegenerating: false,
        canRegenerate: true
    )
    .padding()
    .frame(width: 560)
}

#Preview("SummaryContent - 不十分") {
    SummaryContent(
        summary: SummaryDocument(
            recordingID: UUID(),
            overview: "要約を生成できる十分な内容がありません",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            reviewItems: [],
            generatedAt: Date()
        ),
        onRegenerate: {},
        isRegenerating: false,
        canRegenerate: true
    )
    .padding()
    .frame(width: 560)
}
#endif
