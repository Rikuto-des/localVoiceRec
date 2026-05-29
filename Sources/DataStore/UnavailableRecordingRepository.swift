import Foundation
import Contracts

/// `DataStoreModule.makeRepository()` の初期化に失敗した時に使う no-op フォールバック。
///
/// 旧実装では `InMemoryRecordingRepository` をフォールバックにしていたが、
/// 本番バイナリにテスト用 Mock が漏れる/ストア失敗をユーザが気付けない という問題が
/// あったため、専用の "録音不可" repository を永続化レイヤ (DataStore) 側に置く。
///
/// セマンティクス:
/// - 読み取り系 (list / get / search / load*) は空の結果を返す
/// - 書き込み系 (create / save* / append / delete*) は `storeUnavailable` を throw する
/// - UI 側は throw を捕捉して `lastError` 等でユーザに通知する
public actor UnavailableRecordingRepository: RecordingRepository {
    public init() {}

    // ─── Recording ───
    public func create(_ recording: Recording) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func list(limit: Int?, offset: Int?) async throws -> [Recording] { [] }

    public func search(query: String) async throws -> [Recording] { [] }

    public func get(id: UUID) async throws -> Recording? { nil }

    public func delete(id: UUID, deleteFilesImmediately: Bool) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func updateTitle(id: UUID, newTitle: String) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func deleteAll(deleteFilesImmediately: Bool) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func listWithStatus(limit: Int?, offset: Int?) async throws -> [RecordingStatusRow] { [] }

    // ─── TranscriptSegment ───
    public func saveSegments(_ segments: [TranscriptSegment], for recordingID: UUID) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func appendSegment(_ segment: TranscriptSegment) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func loadSegments(for recordingID: UUID) async throws -> [TranscriptSegment] { [] }

    public func deleteSegments(for recordingID: UUID) async throws {
        throw RepositoryError.storeUnavailable
    }

    // ─── SummaryDocument ───
    public func saveSummary(_ summary: SummaryDocument) async throws {
        throw RepositoryError.storeUnavailable
    }

    public func loadSummary(for recordingID: UUID) async throws -> SummaryDocument? { nil }

    public func deleteSummary(for recordingID: UUID) async throws {
        throw RepositoryError.storeUnavailable
    }
}
