import SwiftUI
import AVFoundation

/// 保存された WAV ファイルの静的波形ビュー。
///
/// AVAudioFile を開いて全 frame からダウンサンプルし、横ピクセル数分の peak 値を取って
/// 棒グラフで描画する。
///
/// ## デザイン意図
/// - 詳細画面で **mic.wav と system.wav の概形** を一目で見せ、
///   「音声が録れているか／システム音声が無音か」を視覚的に確認できる
/// - 計算は `Task.detached` で並列化、表示中は ProgressView を表示
struct StaticWaveformView: View {
    let url: URL
    let label: String
    let tint: Color

    /// 描画解像度（横方向のサンプル数）。
    private let resolution: Int = 240

    @State private var peaks: [Float] = []
    @State private var maxPeak: Float = 0
    @State private var isLoading: Bool = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header
            Canvas { ctx, size in
                guard !peaks.isEmpty else { return }
                drawBars(ctx: ctx, size: size)
            }
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: Theme.Layout.cornerRadius, style: .continuous)
                    .fill(Theme.Palette.surfaceSecondary)
            )
            .overlay {
                if isLoading {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("波形を解析中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("波形を解析中")
                } else if let err = loadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.error)
                        .padding(.horizontal, Theme.Spacing.sm)
                } else if peaks.isEmpty {
                    Text("（未解析）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            await load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
            Spacer()
            if !peaks.isEmpty {
                Text(maxPeakLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSilent ? Theme.Palette.warning : .secondary)
                    .accessibilityLabel("ピーク \(maxPeakLabel)")
                if isSilent {
                    // 「無音」を示すアイコンには `waveform.slash` を使い、メニューバーの
                    // 「録音中断」三角アイコンと意味的に区別する。
                    // 三角警告は「動作中の異常」を示すが、ここは事後の「信号なし」事実通知。
                    Label("無音", systemImage: "waveform.slash")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.Palette.warning)
                        .labelStyle(.iconOnly)
                        .help("""
                            このチャンネルは録音中に信号がほぼ検出されませんでした。\
                            考えられる原因:
                            ・Mic 側: 端末のミュート、入力デバイスの選択ミス、マイク権限拒否
                            ・System 側: 録音中に Mac から音が出ていない、画面とシステムオーディオの収録権限が未許可、Bluetooth など外部デバイスにルーティングされている
                            システム設定 → プライバシーとセキュリティ で権限を確認してください。
                            """)
                        .accessibilityLabel("このチャンネルは無音です")
                }
            }
        }
    }

    private var isSilent: Bool {
        // -60dBFS 相当 (0.001) 以下を「無音」扱い
        maxPeak < 0.001
    }

    private var maxPeakLabel: String {
        let safe = max(maxPeak, 1e-7)
        let db = 20.0 * log10(Double(safe))
        if db < -90 {
            return "-∞ dBFS"
        }
        return String(format: "%.1f dBFS", db)
    }

    // MARK: - Canvas

    private func drawBars(ctx: GraphicsContext, size: CGSize) {
        let count = peaks.count
        guard count > 0 else { return }
        let barWidth = size.width / CGFloat(count)
        let midY = size.height / 2

        for (idx, peak) in peaks.enumerated() {
            let normalized = CGFloat(min(max(peak, 0), 1))
            // 表示用に弱信号を見やすくする log-scale 補正
            let scaled = normalized > 0 ? pow(normalized, 0.6) : 0
            let h = scaled * (size.height * 0.95)
            let x = CGFloat(idx) * barWidth
            let rect = CGRect(
                x: x,
                y: midY - h / 2,
                width: max(barWidth * 0.85, 1),
                height: h
            )
            let color: Color = isSilent ? .secondary : tint
            ctx.fill(Path(rect), with: .color(color.opacity(0.85)))
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        loadError = nil
        peaks = []
        maxPeak = 0

        let target = url
        let res = resolution
        let result = await Task.detached(priority: .utility) { () -> Result<(peaks: [Float], max: Float), Error> in
            do {
                let (p, m) = try Self.computePeaks(url: target, resolution: res)
                return .success((p, m))
            } catch {
                return .failure(error)
            }
        }.value

        isLoading = false
        switch result {
        case .success(let payload):
            peaks = payload.peaks
            maxPeak = payload.max
        case .failure(let error):
            loadError = "解析失敗: \(error.localizedDescription)"
        }
    }

    /// AVAudioFile を開いて全 frame を読み、`resolution` 個に均等分割して各区間の peak を取る。
    nonisolated static func computePeaks(url: URL, resolution: Int) throws -> ([Float], Float) {
        // 存在しないファイルや空ファイルはエラーにせず空配列を返す（detail で表示中は珍しくない）
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], 0)
        }
        let file = try AVAudioFile(forReading: url)
        let total = AVAudioFrameCount(file.length)
        guard total > 0 else { return ([], 0) }
        let format = file.processingFormat

        // 読み込みは chunk 単位で実施（巨大ファイル対策）
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
            // 異常 format (channelCount = 0 など) では PCMBuffer が作れない。
            // crash させずに空波形として返す (loadError には反映されないが、UI 上は無音表示)。
            return ([], 0)
        }

        let bucketsCount = max(resolution, 1)
        let framesPerBucket = Double(total) / Double(bucketsCount)
        var bucketPeaks = [Float](repeating: 0, count: bucketsCount)
        var overallMax: Float = 0

        var readSoFar: AVAudioFramePosition = 0
        while readSoFar < AVAudioFramePosition(total) {
            buffer.frameLength = 0
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)

            for f in 0..<frames {
                let globalFrame = Int(readSoFar) + f
                let bucketIdx = min(
                    bucketsCount - 1,
                    Int(Double(globalFrame) / framesPerBucket)
                )
                // 多チャンネルなら最大値を取る
                var sample: Float = 0
                for c in 0..<channelCount {
                    let v = abs(channelData[c][f])
                    if v > sample { sample = v }
                }
                if sample > bucketPeaks[bucketIdx] {
                    bucketPeaks[bucketIdx] = sample
                }
                if sample > overallMax {
                    overallMax = sample
                }
            }
            readSoFar += AVAudioFramePosition(frames)
        }

        return (bucketPeaks, overallMax)
    }
}

#Preview("Static waveform (missing file)") {
    StaticWaveformView(
        url: URL(fileURLWithPath: "/tmp/nonexistent.wav"),
        label: "Mic",
        tint: .accentColor
    )
    .padding()
    .frame(width: 360)
}
