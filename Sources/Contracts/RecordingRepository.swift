import Foundation

/// 録音 / 文字起こし / 要約の永続化窓口。
///
/// ## 設計上の重要事項
/// - 実装は SwiftData (`@Model`) ベース。ただし **UI には DTO（Recording / TranscriptSegment /
///   SummaryDocument）だけを露出する**。@Model 型は DataStore モジュール内に閉じる
/// - これにより SwiftData スキーマ変更が UI に伝播しない（モジュール疎結合）
/// - 削除時の物理消去（ゴミ箱経由ではなく即時）は `deleteFilesImmediately: true` で指定
public protocol RecordingRepository: Sendable {
    // ─── Recording ───
    func create(_ recording: Recording) async throws
    func list(limit: Int?, offset: Int?) async throws -> [Recording]
    func search(query: String) async throws -> [Recording]
    func get(id: UUID) async throws -> Recording?
    func delete(id: UUID, deleteFilesImmediately: Bool) async throws
    func deleteAll(deleteFilesImmediately: Bool) async throws

    // ─── TranscriptSegment ───
    func saveSegments(_ segments: [TranscriptSegment], for recordingID: UUID) async throws
    func appendSegment(_ segment: TranscriptSegment) async throws
    func loadSegments(for recordingID: UUID) async throws -> [TranscriptSegment]
    func deleteSegments(for recordingID: UUID) async throws

    // ─── SummaryDocument ───
    func saveSummary(_ summary: SummaryDocument) async throws
    func loadSummary(for recordingID: UUID) async throws -> SummaryDocument?
    func deleteSummary(for recordingID: UUID) async throws
}

public enum RepositoryError: Error, Sendable, Hashable {
    case notFound(UUID)
    case ioFailed(message: String)
    case storeUnavailable
    case fileDeletionFailed(URL, message: String)
}
