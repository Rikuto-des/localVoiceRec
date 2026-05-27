import SwiftUI

/// 次回レビュー項目セクション。
struct ReviewItemsBlock: View {
    let items: [String]
    @Binding var isExpanded: Bool

    private let kind: SummarySectionKind = .reviewItems

    var body: some View {
        SummaryBlockContainer(
            kind: kind,
            count: items.count,
            isExpanded: $isExpanded,
            copyAction: items.isEmpty ? nil : {
                SummaryClipboard.copy(title: kind.title, lines: items)
            }
        ) {
            if items.isEmpty {
                EmptyLine(message: "次回レビュー項目はありません")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(kind.tint)
                                .accessibilityHidden(true)
                            Text(item)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("レビュー: \(item)")
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("ReviewItems - 通常") {
    @Previewable @State var expanded = true
    return ReviewItemsBlock(
        items: [
            "予算案の進捗確認",
            "対策チームの初期成果報告"
        ],
        isExpanded: $expanded
    )
    .padding()
    .frame(width: 480)
}
#endif
