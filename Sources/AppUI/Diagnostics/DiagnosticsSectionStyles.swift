import SwiftUI

/// `DiagnosticsPanel` 配下のセクション共通スタイル / ローレベル要素。
///
/// 旧 `DiagnosticsPanel` 内の `section(title:content:)` / `row(label:value:isWarning:help:)`
/// を各セクション View から再利用できるように切り出したもの。挙動は完全に同一。
enum DiagnosticsSectionStyles {

    /// caption.bold() + .secondary のセクションタイトル風ヘッダ + コンテンツの縦並び。
    @ViewBuilder
    static func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// ラベル + 値 + 警告アイコンの行。
    static func row(
        label: String,
        value: String,
        isWarning: Bool,
        help: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: Theme.Spacing.xs) {
                if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.warning)
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                Text(value)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isWarning ? Theme.Palette.warning : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(isWarning ? "（要確認）" : "")")
    }
}
