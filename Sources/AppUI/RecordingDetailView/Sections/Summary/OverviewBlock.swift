import SwiftUI

/// 概要セクション。1 段落のフラットテキスト。
struct OverviewBlock: View {
    let overview: String
    @Binding var isExpanded: Bool

    private let kind: SummarySectionKind = .overview

    var body: some View {
        SummaryBlockContainer(
            kind: kind,
            count: nil,
            isExpanded: $isExpanded,
            copyAction: {
                SummaryClipboard.copy(title: kind.title, paragraph: overview)
            }
        ) {
            Text(overview)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("概要: \(overview)")
        }
    }
}

#if DEBUG
#Preview("Overview - 通常") {
    @Previewable @State var expanded = true
    return OverviewBlock(
        overview: "予算編成のスケジュール調整と、コスト削減のための緊急対策チーム発足を確認した。",
        isExpanded: $expanded
    )
    .padding()
    .frame(width: 480)
}
#endif
