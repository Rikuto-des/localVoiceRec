import Foundation
import Contracts

/// エクスポート用に Recording / Segments / Summary を 1 つに束ねた中間値型。
///
/// - `segments` は時刻順 (`startSec` 昇順) で渡す前提。Exporter 側でもソートはする。
/// - `summary` が `nil` の場合、Markdown / Plain Text どちらの出力でも要約セクションは省略される。
/// - `excludeEchoes` (既定 `true`): `isLikelyEcho == true` の mic セグメントを出力から除外する。
///   Slack/Notion 等への議事録貼り付けを「相手の声の二重表示」で汚さないための既定動作。
struct MeetingMinutes: Sendable, Identifiable {
    /// `.sheet(item:)` バインディングで使うための識別子。録音の ID をそのまま流用。
    var id: UUID { recording.id }

    let recording: Recording
    let segments: [TranscriptSegment]
    let summary: SummaryDocument?
    let excludeEchoes: Bool

    init(
        recording: Recording,
        segments: [TranscriptSegment],
        summary: SummaryDocument?,
        excludeEchoes: Bool = true
    ) {
        self.recording = recording
        self.segments = segments
        self.summary = summary
        self.excludeEchoes = excludeEchoes
    }

    /// `excludeEchoes` を考慮した、Exporter が実際にレンダリングすべき segments。
    var renderableSegments: [TranscriptSegment] {
        if excludeEchoes {
            return segments.filter { !$0.isLikelyEcho }
        }
        return segments
    }
}
