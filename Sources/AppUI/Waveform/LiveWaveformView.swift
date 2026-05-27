import SwiftUI
import Contracts
#if DEBUG
import ContractsTestSupport
#endif

/// 録音中のリアルタイム波形ビュー。
///
/// `AppViewModel.audioLevels` rolling buffer を読んで描画する。**View 側は購読しない**
/// — ViewModel が永続的に購読しているので、メニューバーポップアップを閉じて開き直しても
/// 履歴がリセットされない。
///
/// ## デザイン意図
/// - **mic は accentColor / system はオレンジ** で色分けし、
///   ユーザーが「マイクは動いている／システム音声は無音」を一瞬で判断できるようにする
/// - 上半分に mic、下半分に system を描画（左 → 右に時間が流れる）
/// - 数値表示は dBFS（小数 1 桁）+ 「無音」バッジで明示
struct LiveWaveformView: View {
    @Bindable var viewModel: AppViewModel

    /// 表示する時間窓（秒）。
    private let windowSeconds: Double = 4.0

    /// テスト用に外部から差し込めるオーバーライド buffer（通常は nil で `viewModel.audioLevels` を見る）。
    var historyOverride: [AudioLevelSnapshot]?

    private var history: [AudioLevelSnapshot] {
        historyOverride ?? viewModel.audioLevels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            headerRow(
                title: "Mic",
                systemImage: "mic.fill",
                color: .accentColor,
                rms: history.last?.micRMS ?? 0,
                isSilent: history.last?.isMicSilent ?? true
            )

            Canvas { ctx, size in
                drawBackground(ctx: ctx, size: size)
                drawWaveform(ctx: ctx, size: size, channel: .mic, color: .accentColor)
                // A10: 相手チャンネルは systemAudio 色 (warning と分離)
                drawWaveform(ctx: ctx, size: size, channel: .system, color: Theme.Palette.systemAudio)
                drawAxis(ctx: ctx, size: size)
            }
            .frame(height: 80)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    .fill(Theme.Palette.surfaceSecondary)
            )
            .accessibilityLabel(accessibilityLabel)

            headerRow(
                title: "System",
                systemImage: "speaker.wave.2.fill",
                // A10: warning (オレンジ) ではなく systemAudio (indigo) を使用
                color: Theme.Palette.systemAudio,
                rms: history.last?.systemRMS ?? 0,
                isSilent: history.last?.isSystemSilent ?? true
            )
        }
    }

    // MARK: - Header

    private func headerRow(
        title: String,
        systemImage: String,
        color: Color,
        rms: Float,
        isSilent: Bool
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label {
                Text(title).font(.caption.bold())
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Spacer()
            if isSilent {
                Label("無音", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.Palette.warning)
                    .help("信号レベルが -60 dBFS を下回っています。録音されていない可能性があります。")
                    .accessibilityLabel("無音を検出")
            }
            Text(Self.formatDB(rms: rms))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSilent ? Theme.Palette.warning : .secondary)
                .accessibilityLabel("レベル \(Self.formatDB(rms: rms))")
        }
    }

    // MARK: - Canvas helpers

    private enum Channel {
        case mic, system
    }

    private func drawBackground(ctx: GraphicsContext, size: CGSize) {
        // 中央のセパレータ
        var separator = Path()
        separator.move(to: CGPoint(x: 0, y: size.height / 2))
        separator.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(separator, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
    }

    private func drawAxis(ctx: GraphicsContext, size: CGSize) {
        // 静寂閾値ラインを薄く描画（dB スケール想定で、約 -60dBFS = 0.001 を上下に）
        // 線形振幅で 0.001 は事実上 0 なので、半分高さの 5% 位置に基準線を引く
        let halfH = size.height / 2
        let baseline = halfH * 0.05
        for y in [halfH - baseline, halfH + baseline] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
        }
    }

    private func drawWaveform(
        ctx: GraphicsContext,
        size: CGSize,
        channel: Channel,
        color: Color
    ) {
        guard let last = history.last else { return }
        let now = last.elapsedSec
        let start = now - windowSeconds
        let halfH = size.height / 2

        // バーの幅: 各 snapshot を等間隔で描画
        let count = history.count
        guard count > 0 else { return }
        let barWidth = max(1.0, size.width / CGFloat(max(count, 40)))

        for snap in history {
            // x 軸: elapsedSec を windowSeconds で正規化
            let normalizedX = (snap.elapsedSec - start) / windowSeconds
            let x = CGFloat(normalizedX.clamped(to: 0...1)) * size.width

            let rms: Float
            let peak: Float
            let isSilent: Bool
            switch channel {
            case .mic:
                rms = snap.micRMS
                peak = snap.micPeak
                isSilent = snap.isMicSilent
            case .system:
                rms = snap.systemRMS
                peak = snap.systemPeak
                isSilent = snap.isSystemSilent
            }

            // 振幅を 0..1 にクランプして可視化（peak はライト、rms は濃く）
            let peakHeight = CGFloat(min(max(peak, 0), 1)) * halfH
            let rmsHeight = CGFloat(min(max(rms, 0), 1)) * halfH

            // mic は上向き / system は下向き
            let direction: CGFloat = (channel == .mic) ? -1 : 1
            let yBase = halfH

            let peakRect = CGRect(
                x: x - barWidth / 2,
                y: yBase + (direction < 0 ? -peakHeight : 0),
                width: barWidth * 0.9,
                height: peakHeight
            )
            let rmsRect = CGRect(
                x: x - barWidth / 2,
                y: yBase + (direction < 0 ? -rmsHeight : 0),
                width: barWidth * 0.9,
                height: rmsHeight
            )

            let baseColor: Color = isSilent ? .secondary : color
            ctx.fill(
                Path(peakRect),
                with: .color(baseColor.opacity(0.35))
            )
            ctx.fill(
                Path(rmsRect),
                with: .color(baseColor.opacity(0.85))
            )
        }
    }

    // MARK: - Formatting

    private static func formatDB(rms: Float) -> String {
        let safe = max(rms, 1e-7)
        let db = 20.0 * log10(Double(safe))
        if db < -90 {
            return "-∞ dB"
        }
        return String(format: "%.1f dB", db)
    }

    private var accessibilityLabel: String {
        let last = history.last
        let micDB = last.map { Self.formatDB(rms: $0.micRMS) } ?? "-∞ dB"
        let sysDB = last.map { Self.formatDB(rms: $0.systemRMS) } ?? "-∞ dB"
        return "Mic: \(micDB), System: \(sysDB)"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
#Preview("Live waveform (Mock)") {
    let capture = FakeAudioCaptureService()
    let vm = AppViewModel(
        capture: capture,
        repository: InMemoryRecordingRepository(),
        transcription: FakeTranscriptionService(),
        summary: FakeSummaryService()
    )
    return LiveWaveformView(viewModel: vm)
        .padding()
        .frame(width: 360)
        .task {
            vm.startObservingAudioLevels()
            _ = try? await capture.start(in: URL(fileURLWithPath: NSTemporaryDirectory()), title: "preview")
        }
}
#endif
