import Foundation
import Contracts

/// エクスポート用に Recording / Segments / Summary を 1 つに束ねた中間値型。
///
/// - `segments` は時刻順 (`startSec` 昇順) で渡す前提。Exporter 側でもソートはする。
/// - `summary` が `nil` の場合、Markdown / Plain Text どちらの出力でも要約セクションは省略される。
public struct MeetingMinutes: Sendable {
    public let recording: Recording
    public let segments: [TranscriptSegment]
    public let summary: SummaryDocument?

    public init(
        recording: Recording,
        segments: [TranscriptSegment],
        summary: SummaryDocument?
    ) {
        self.recording = recording
        self.segments = segments
        self.summary = summary
    }
}
