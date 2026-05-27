import Foundation
import SwiftData

/// `TranscriptSegment` の永続化単位。
///
/// `source` は `TranscriptSegment.Source.rawValue`（"mic" / "system"）を String で保存する。
/// enum を直接 @Model プロパティにすると SwiftData のスキーマ進化が窮屈になるため文字列化。
@Model
final class SegmentEntity {
    @Attribute(.unique) var id: UUID
    var sourceRaw: String
    var startSec: Double
    var endSec: Double
    var text: String
    var isFinal: Bool

    /// マイク回り込みで相手音声を二重転写したと推定されるセグメントは `true`。
    /// SwiftData 既存ストアとの互換性のため optional + 既定 false で扱う。
    var isLikelyEcho: Bool?

    var recording: RecordingEntity?

    init(
        id: UUID,
        sourceRaw: String,
        startSec: Double,
        endSec: Double,
        text: String,
        isFinal: Bool,
        isLikelyEcho: Bool = false,
        recording: RecordingEntity? = nil
    ) {
        self.id = id
        self.sourceRaw = sourceRaw
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.isFinal = isFinal
        self.isLikelyEcho = isLikelyEcho
        self.recording = recording
    }
}
