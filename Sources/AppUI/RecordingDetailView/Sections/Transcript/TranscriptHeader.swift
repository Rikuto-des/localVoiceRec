import SwiftUI
import Contracts

/// 文字起こしセクションのヘッダ。
///
/// 左: アイコン + タイトル + セグメント数 / 言語 / 直近処理時刻
/// 右: 「再実行」 (親から渡される `controls`)
struct TranscriptHeader<Controls: View>: View {
    let segmentCount: Int
    let micCount: Int
    let systemCount: Int
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Label("文字起こし", systemImage: "text.bubble")
                .font(Theme.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)

            if segmentCount > 0 {
                HStack(spacing: Theme.Spacing.sm) {
                    metaPill(systemImage: "list.bullet",
                             text: "\(segmentCount) 件")
                        .accessibilityLabel("セグメント \(segmentCount) 件")
                    metaPill(systemImage: "person.crop.circle",
                             text: "自分 \(micCount)")
                        .accessibilityLabel("自分 \(micCount) 件")
                    metaPill(systemImage: "speaker.wave.2",
                             text: "相手 \(systemCount)")
                        .accessibilityLabel("相手 \(systemCount) 件")
                }
            }
            Spacer()
            controls()
        }
    }

    @ViewBuilder
    private func metaPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Theme.Palette.surfaceSecondary,
                in: Capsule()
            )
    }
}

#if DEBUG
#Preview {
    TranscriptHeader(segmentCount: 12, micCount: 7, systemCount: 5) {
        Button("再実行") {}.buttonStyle(.bordered).controlSize(.small)
    }
    .padding()
    .frame(width: 600)
}
#endif
