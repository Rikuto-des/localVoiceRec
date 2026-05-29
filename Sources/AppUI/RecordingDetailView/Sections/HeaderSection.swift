import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Header

    /// 録音詳細ヘッダ。Finder ボタンは toolbar 側 (`detailToolbarContent`) に
    /// 移設したため、ここはタイトル + メタ情報 (日時 / 長さ) のみを表示する。
    @ViewBuilder
    func header(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(recording.title)
                .font(Theme.Typography.detailTitle)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.Spacing.md) {
                Label {
                    Text(AppFormatters.dateTime.string(from: recording.startedAt))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "calendar")
                }
                Label {
                    Text(AppFormatters.duration(recording.duration))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}
