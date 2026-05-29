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
                    // A10: warning (オレンジ) との意味衝突を避けるため systemAudio に分離
                    tint: Theme.Palette.systemAudio
                )
            }
            .padding(.top, Theme.Spacing.sm)
        } label: {
            Label("録音波形", systemImage: "waveform")
                .font(Theme.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(Theme.Spacing.md)
        .cardSurface()
    }
}
