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

    var recording: RecordingEntity?

    init(
        id: UUID,
        sourceRaw: String,
        startSec: Double,
        endSec: Double,
        text: String,
        isFinal: Bool,
        recording: RecordingEntity? = nil
    ) {
        self.id = id
        self.sourceRaw = sourceRaw
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
        self.isFinal = isFinal
        self.recording = recording
    }
}
