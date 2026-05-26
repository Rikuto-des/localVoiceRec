import Foundation

/// 構造化要約。Foundation Models が `@Generable` で生成し、UI に直接マッピングする。
///
/// 仕様 5.3 で定義された出力構造をそのまま値型化したもの。
public struct SummaryDocument: Sendable, Hashable, Codable {
    public let recordingID: UUID
    public let overview: String
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]
    public let reviewItems: [String]
    public let generatedAt: Date

    public init(
        recordingID: UUID,
        overview: String,
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String],
        reviewItems: [String],
        generatedAt: Date = Date()
    ) {
        self.recordingID = recordingID
        self.overview = overview
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.reviewItems = reviewItems
        self.generatedAt = generatedAt
    }
}

public struct ActionItem: Sendable, Hashable, Codable {
    public let title: String
    public let assignee: String?
    public let dueDate: Date?

    public init(title: String, assignee: String? = nil, dueDate: Date? = nil) {
        self.title = title
        self.assignee = assignee
        self.dueDate = dueDate
    }
}
