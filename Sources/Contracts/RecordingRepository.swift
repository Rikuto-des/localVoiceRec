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

    /// 録音一覧と各録音の状態 (segments/summary が存在するか) を 1 fetch で返す。
    ///
    /// 一覧バッジ用の `RecordingStatus` 算出時に、録音件数 N に対して
    /// `loadSegments` / `loadSummary` を N+1 回 await するのを避けるためのバッチ API。
    /// 並びは `list(limit:offset:)` と同じ（`startedAt` 降順）。
    func listWithStatus(limit: Int?, offset: Int?) async throws -> [RecordingStatusRow]

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

/// `listWithStatus(limit:offset:)` の戻り値。
/// 録音 1 件と、その録音に segments / summary が存在するかのフラグを束ねる。
public struct RecordingStatusRow: Sendable, Hashable {
    public let recording: Recording
    public let hasSegments: Bool
    public let hasSummary: Bool

    public init(recording: Recording, hasSegments: Bool, hasSummary: Bool) {
        self.recording = recording
        self.hasSegments = hasSegments
        self.hasSummary = hasSummary
    }
}

public enum RepositoryError: Error, Sendable, Hashable {
    case notFound(UUID)
    case ioFailed(message: String)
    case storeUnavailable
    case fileDeletionFailed(URL, message: String)
}
