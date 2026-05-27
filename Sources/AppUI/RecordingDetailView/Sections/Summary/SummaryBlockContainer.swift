import SwiftUI

/// 5 セクション共通のシェル。
///
/// - アイコン + 色 + タイトルのヘッダ
/// - 右上にコピーボタン (内容がある時のみ)
/// - `DisclosureGroup` で折りたたみ
/// - `subtleSurface()` の枠で各セクションを物理的に分離
struct SummaryBlockContainer<Content: View>: View {
    let kind: SummarySectionKind
    let count: Int?
    let copyAction: (() -> Void)?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(
        kind: SummarySectionKind,
        count: Int? = nil,
        isExpanded: Binding<Bool>,
        copyAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.kind = kind
        self.count = count
        self._isExpanded = isExpanded
        self.copyAction = copyAction
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.xs)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(kind.tint)
                    .font(.headline)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            kind.tint.opacity(0.15),
                            in: Capsule()
                        )
                        .accessibilityLabel("\(count) 項目")
                }

                Spacer(minLength: 0)

                if let copyAction {
                    Button(action: copyAction) {
                        Image(systemName: "doc.on.doc")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .help("このセクションを Markdown 形式でコピー")
                    .accessibilityLabel("\(kind.title) をコピー")
                }
            }
            .contentShape(Rectangle())
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleSurface()
    }
}
