import SwiftUI
import Contracts

/// 要約セクション最上部のヘッダ。
///
/// - 左: アイコン + 「要約」タイトル
/// - 左下: 生成時刻 / モデル名
/// - 右: 再生成 / エクスポート
struct SummaryHeader<Trailing: View>: View {
    let summary: SummaryDocument?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label("要約", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                if let summary {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label(
                            summary.generatedAt.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock"
                        )
                        .monospacedDigit()
                        Text("·").foregroundStyle(.tertiary)
                        Label("Foundation Models", systemImage: "sparkles")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer()
            trailing()
        }
    }
}
