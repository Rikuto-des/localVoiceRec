import Foundation
import SwiftData

/// `SummaryDocument` の永続化単位。
///
/// `[String]` / `[ActionItem]` などは JSON 文字列にエンコードして保存する。
/// SwiftData は配列もある程度サポートするが、スキーマ進化の安定性 / DTO とのマッピング
/// 厳密性を優先して JSON 化する。
@Model
final class SummaryEntity {
    @Attribute(.unique) var recordingID: UUID
    var overview: String
    var decisionsJSON: String
    var actionItemsJSON: String
    var openQuestionsJSON: String
    var reviewItemsJSON: String
    var generatedAt: Date

    var recording: RecordingEntity?

    init(
        recordingID: UUID,
        overview: String,
        decisionsJSON: String,
        actionItemsJSON: String,
        openQuestionsJSON: String,
        reviewItemsJSON: String,
        generatedAt: Date,
        recording: RecordingEntity? = nil
    ) {
        self.recordingID = recordingID
        self.overview = overview
        self.decisionsJSON = decisionsJSON
        self.actionItemsJSON = actionItemsJSON
        self.openQuestionsJSON = openQuestionsJSON
        self.reviewItemsJSON = reviewItemsJSON
        self.generatedAt = generatedAt
        self.recording = recording
    }
}
