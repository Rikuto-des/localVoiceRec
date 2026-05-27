import SwiftUI
import Contracts

/// 録音中のライブ文字起こしを表示する小さなセクション (P4.5)。
///
/// メニューバーポップアップに格納される想定。直近 `maxVisible` 件の isFinal セグメントを
/// 縦並びで表示し、空のときは「文字起こし中…」プレースホルダを出す。
///
/// ## HIG 準拠ポイント
/// - 既存 `Theme.Typography` (footnote / caption2) を使用
/// - mic / system はアイコン + accent color で区別（色だけに依存しない）
/// - 録音停止時はフェードアウト想定 (上位 View で `.transition(.opacity)` を当てる)
/// - reduceMotion 時はアニメ無し
struct LiveTranscriptStrip: View {
    /// `AppViewModel.liveTranscriptSegments` をそのまま渡す。
    let segments: [TranscriptSegment]
    /// 録音中かどうか (停止直後の grace period でも true を渡し続けると placeholder が出続けるので
    /// 上位は録音停止後 false を渡すこと)。
    let isRecording: Bool
    /// 表示する直近件数。
    let maxVisible: Int = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "waveform.badge.mic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("ライブ文字起こし")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if isRecording, segments.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)

            if visibleSegments.isEmpty {
                placeholder
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(visibleSegments) { seg in
                        LiveTranscriptRow(segment: seg)
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibleSegments.map(\.id))
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .subtleSurface(cornerRadius: Theme.Layout.pillCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ライブ文字起こし")
    }

    /// 直近 N 件、startSec 昇順に並べる。
    private var visibleSegments: [TranscriptSegment] {
        let sorted = segments.sorted { $0.startSec < $1.startSec }
        return Array(sorted.suffix(maxVisible))
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(isRecording ? "文字起こし中…" : "発話なし")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(isRecording ? "文字起こし中" : "発話なし")
    }
}

/// 1 セグメントの 1 行表示。
private struct LiveTranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Image(systemName: segment.source == .mic ? "person.fill" : "speaker.wave.2.fill")
                .font(.caption2)
                .foregroundStyle(segment.source == .mic ? Color.accentColor : .secondary)
                .frame(width: 12, alignment: .center)
                .accessibilityHidden(true)
            Text(segment.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.source == .mic ? "自分" : "相手"): \(segment.text)")
    }
}

#if DEBUG
#Preview("With segments") {
    LiveTranscriptStrip(
        segments: [
            TranscriptSegment(recordingID: UUID(), source: .mic, startSec: 0, endSec: 1,
                              text: "こんにちは、よろしくお願いします。", isFinal: true),
            TranscriptSegment(recordingID: UUID(), source: .system, startSec: 2, endSec: 3,
                              text: "はい、お願いします。今日の議題はーー", isFinal: true),
            TranscriptSegment(recordingID: UUID(), source: .mic, startSec: 4, endSec: 5,
                              text: "Phase 4.5 の進捗を共有します。", isFinal: true),
        ],
        isRecording: true
    )
    .padding()
    .frame(width: 340)
}

#Preview("Empty (recording)") {
    LiveTranscriptStrip(segments: [], isRecording: true)
        .padding()
        .frame(width: 340)
}

#Preview("Empty (idle)") {
    LiveTranscriptStrip(segments: [], isRecording: false)
        .padding()
        .frame(width: 340)
}
#endif
