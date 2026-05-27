import SwiftUI
import Contracts

/// アクションアイテムセクション。
///
/// 各行はカード形式で「何を / 誰が / いつまでに」を視覚的に分離する:
/// - 何を: `.body` 本文
/// - 誰が: `person` アイコンの caption2 バッジ
/// - いつまでに: `calendar` アイコンの caption2 バッジ
struct ActionItemsBlock: View {
    let items: [ActionItem]
    @Binding var isExpanded: Bool

    private let kind: SummarySectionKind = .actionItems

    var body: some View {
        SummaryBlockContainer(
            kind: kind,
            count: items.count,
            isExpanded: $isExpanded,
            copyAction: items.isEmpty ? nil : {
                SummaryClipboard.copy(
                    title: kind.title,
                    lines: items.map(Self.markdownLine(_:))
                )
            }
        ) {
            if items.isEmpty {
                EmptyLine(message: "アクションアイテムはありません")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        ActionItemCard(item: item, tint: kind.tint)
                    }
                }
            }
        }
    }

    static func markdownLine(_ item: ActionItem) -> String {
        var parts: [String] = [item.title]
        if let assignee = item.assignee, !assignee.isEmpty {
            parts.append("担当: \(assignee)")
        }
        if let due = item.dueDate {
            parts.append("期限: \(due.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " / ")
    }
}

/// 単一の ActionItem を 1 行のカードとして描画する。
struct ActionItemCard: View {
    let item: ActionItem
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            // 未チェックの ⃝ を装飾として置く (操作不能 = 議事録なので completion 概念は無い)
            Circle()
                .stroke(tint.opacity(0.6), lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if item.assignee != nil || item.dueDate != nil {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let assignee = item.assignee, !assignee.isEmpty {
                            MetaBadge(systemImage: "person.fill", text: assignee, tint: tint)
                        }
                        if let due = item.dueDate {
                            MetaBadge(
                                systemImage: "calendar",
                                text: due.formatted(date: .abbreviated, time: .omitted),
                                tint: tint,
                                monospacedDigit: true
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.06),
            in: RoundedRectangle(cornerRadius: Theme.Layout.pillCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.pillCornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["アクション: \(item.title)"]
        if let a = item.assignee { parts.append("担当 \(a)") }
        if let d = item.dueDate {
            parts.append("期限 \(d.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: ", ")
    }
}

struct MetaBadge: View {
    let systemImage: String
    let text: String
    let tint: Color
    var monospacedDigit: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text(text)
                .font(monospacedDigit ? .caption2.monospacedDigit() : .caption2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            tint.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Theme.Layout.pillCornerRadius, style: .continuous)
        )
    }
}

#if DEBUG
#Preview("ActionItems - 通常") {
    @Previewable @State var expanded = true
    return ActionItemsBlock(
        items: [
            ActionItem(title: "予算案を作成して全員に共有する", assignee: "田中", dueDate: Date().addingTimeInterval(86400 * 7)),
            ActionItem(title: "緊急対策チームのキックオフ", assignee: "山田"),
            ActionItem(title: "前回の議事録に目を通す")
        ],
        isExpanded: $expanded
    )
    .padding()
    .frame(width: 520)
}

#Preview("ActionItems - 空") {
    @Previewable @State var expanded = true
    return ActionItemsBlock(items: [], isExpanded: $expanded)
        .padding()
        .frame(width: 520)
}
#endif
