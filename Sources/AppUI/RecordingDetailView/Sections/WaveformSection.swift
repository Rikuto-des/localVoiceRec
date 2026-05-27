import SwiftUI
import Contracts

extension RecordingDetailView {
    // MARK: - Waveform

    @ViewBuilder
    func waveformSection(recording: Recording) -> some View {
        DisclosureGroup(isExpanded: $isWaveformExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                StaticWaveformView(
                    url: recording.micAudioURL,
                    label: "Mic（自分）",
                    tint: .accentColor
                )
                StaticWaveformView(
                    url: recording.systemAudioURL,
                    label: "System（相手）",
                    tint: Theme.Palette.warning
                )
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            Label("録音波形", systemImage: "waveform")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(Theme.Spacing.md)
        .subtleSurface()
    }
}
