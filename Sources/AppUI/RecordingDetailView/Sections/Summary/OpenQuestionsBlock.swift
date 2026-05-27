import SwiftUI

/// 未解決の問いセクション。
struct OpenQuestionsBlock: View {
    let questions: [String]
    @Binding var isExpanded: Bool

    private let kind: SummarySectionKind = .openQuestions

    var body: some View {
        SummaryBlockContainer(
            kind: kind,
            count: questions.count,
            isExpanded: $isExpanded,
            copyAction: questions.isEmpty ? nil : {
                SummaryClipboard.copy(title: kind.title, lines: questions)
            }
        ) {
            if questions.isEmpty {
                EmptyLine(message: "未解決の問いはありません")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            Image(systemName: "questionmark.diamond.fill")
                                .foregroundStyle(kind.tint)
                                .accessibilityHidden(true)
                            Text(q)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("未解決: \(q)")
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("OpenQuestions - 通常") {
    @Previewable @State var expanded = true
    return OpenQuestionsBlock(
        questions: [
            "次回会議までに誰が予算案をレビューするか",
            "コスト削減の優先順位はどう決めるか"
        ],
        isExpanded: $expanded
    )
    .padding()
    .frame(width: 480)
}
#endif
