import SwiftUI

/// 決定事項セクション。決定済の項目を緑のチェック付きで列挙する。
struct DecisionsBlock: View {
    let decisions: [String]
    @Binding var isExpanded: Bool

    private let kind: SummarySectionKind = .decisions

    var body: some View {
        SummaryBlockContainer(
            kind: kind,
            count: decisions.count,
            isExpanded: $isExpanded,
            copyAction: decisions.isEmpty ? nil : {
                SummaryClipboard.copy(title: kind.title, lines: decisions)
            }
        ) {
            if decisions.isEmpty {
                EmptyLine(message: "決定事項はありません")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(kind.tint)
                                .accessibilityHidden(true)
                            Text(item)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("決定: \(item)")
                    }
                }
            }
        }
    }
}

/// 「（なし）」表示の共通子要素。
struct EmptyLine: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Decisions - 通常") {
    @Previewable @State var expanded = true
    return DecisionsBlock(
        decisions: [
            "予算編成のスケジュールを 2024 年 8 月に進める",
            "コスト削減のための緊急対策チームを設置"
        ],
        isExpanded: $expanded
    )
    .padding()
    .frame(width: 480)
}

#Preview("Decisions - 空") {
    @Previewable @State var expanded = true
    return DecisionsBlock(decisions: [], isExpanded: $expanded)
        .padding()
        .frame(width: 480)
}
#endif
