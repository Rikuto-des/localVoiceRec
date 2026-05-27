import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Header

    @ViewBuilder
    func header(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Button {
                    FinderReveal.openRecordingFolder(for: recording)
                } label: {
                    Label("Finder で開く", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("録音ファイルが入っているフォルダを Finder で開きます")
                .accessibilityLabel("Finder で録音フォルダを開く")
            }
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
