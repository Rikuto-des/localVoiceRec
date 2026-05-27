import Foundation
import Contracts

/// Foundation Models を叩かない偽 SummaryService。
public actor FakeSummaryService: SummaryService {
    private var configuredAvailability: SummaryAvailability

    public init(availability: SummaryAvailability = .available) {
        self.configuredAvailability = availability
    }

    public func availability() async -> SummaryAvailability { configuredAvailability }

    public func generate(
        from segments: [TranscriptSegment],
        recordingID: UUID
    ) async throws -> SummaryDocument {
        if case .unavailable(let reason) = configuredAvailability {
            throw SummaryError.notAvailable(reason: reason)
        }
        let combined = segments.map(\.text).joined(separator: " ")
        return SummaryDocument(
            recordingID: recordingID,
            overview: "サンプル要約: \(combined.prefix(60))",
            decisions: ["要件 A を確定", "次週レビューを設定"],
            actionItems: [
                ActionItem(title: "仕様書を更新", assignee: "Rikuto", dueDate: nil),
                ActionItem(title: "Phase 0 PoC のレビュー", assignee: nil, dueDate: nil),
            ],
            openQuestions: ["保存データ暗号化の方針は？"],
            reviewItems: ["セキュリティ entitlements", "UI ワイヤーフレーム"]
        )
    }

    public func regenerate(
        from segments: [TranscriptSegment],
        recordingID: UUID,
        hint: String?
    ) async throws -> SummaryDocument {
        try await generate(from: segments, recordingID: recordingID)
    }
}
