import Foundation
import SwiftData
import Contracts

/// SwiftData ベースの `RecordingRepository` 実装。
///
/// 設計:
/// - `ModelContainer` は外から注入できる（テストは in-memory configuration を渡す）。
/// - `ModelContext` は actor 内でだけ生成・使用し、外に漏らさない。
///   これで SwiftData の concurrency 制約（`ModelContext` は actor 越えできない）を満たす。
/// - `@Model` 型は public にしない。UI には DTO だけを返す。
/// - 削除時のファイル消去 (`deleteFilesImmediately: true`) は `FileManager` で同期実行し、
///   失敗時は `RepositoryError.fileDeletionFailed` を投げる。
public actor RecordingRepositoryImpl: RecordingRepository {

    private let container: ModelContainer
    private lazy var context: ModelContext = ModelContext(container)

    // MARK: - Init

    public init(container: ModelContainer) {
        self.container = container
    }

    /// デフォルト: `AppPaths.storeURL()` 配下に on-disk store を作る。
    /// CloudKit 同期は `.none` を明示（オンデバイス完結要件）。
    public init() throws {
        let url = try AppPaths.storeURL()
        let config = ModelConfiguration(
            "Default",
            schema: Schema([
                RecordingEntity.self,
                SegmentEntity.self,
                SummaryEntity.self,
            ]),
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        self.container = try ModelContainer(
            for: RecordingEntity.self, SegmentEntity.self, SummaryEntity.self,
            configurations: config
        )
    }

    // MARK: - Lifecycle

    public func prewarm() async {
        // ModelContext の lazy 生成を起こす。失敗してもベストエフォート。
        _ = context
    }

    // MARK: - Recording

    public func create(_ recording: Recording) async throws {
        if let existing = try fetchEntity(id: recording.id) {
            try existing.update(from: recording)
        } else {
            let entity = try RecordingEntity.make(from: recording)
            context.insert(entity)
        }
        try saveOrThrow()
    }

    public func list(limit: Int?, offset: Int?) async throws -> [Recording] {
        var descriptor = FetchDescriptor<RecordingEntity>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        if let limit {
            descriptor.fetchLimit = limit
        }
        if let offset {
            descriptor.fetchOffset = offset
        }
        let entities = try fetchOrThrow(descriptor)
        return try entities.map { try $0.toDTO() }
    }

    public func search(query: String) async throws -> [Recording] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            return try await list(limit: nil, offset: nil)
        }
        // SwiftData の #Predicate はメソッド呼び出し制約があるため、フェッチしてから filter する。
        let descriptor = FetchDescriptor<RecordingEntity>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let entities = try fetchOrThrow(descriptor)
        return try entities
            .filter { $0.title.lowercased().contains(q) }
            .map { try $0.toDTO() }
    }

    public func get(id: UUID) async throws -> Recording? {
        guard let entity = try fetchEntity(id: id) else { return nil }
        return try entity.toDTO()
    }

    public func delete(id: UUID, deleteFilesImmediately: Bool) async throws {
        guard let entity = try fetchEntity(id: id) else { return }
        let micRel = entity.micRelativePath
        let sysRel = entity.systemRelativePath

        context.delete(entity)
        try saveOrThrow()

        if deleteFilesImmediately {
            try removeFile(relativePath: micRel)
            try removeFile(relativePath: sysRel)
            try removeRecordingDirectory(for: id)
        }
    }

    public func deleteAll(deleteFilesImmediately: Bool) async throws {
        let descriptor = FetchDescriptor<RecordingEntity>()
        let entities = try fetchOrThrow(descriptor)
        let snapshot: [(UUID, String, String)] = entities.map {
            ($0.id, $0.micRelativePath, $0.systemRelativePath)
        }
        for e in entities {
            context.delete(e)
        }
        try saveOrThrow()

        if deleteFilesImmediately {
            for (id, micRel, sysRel) in snapshot {
                try removeFile(relativePath: micRel)
                try removeFile(relativePath: sysRel)
                try removeRecordingDirectory(for: id)
            }
        }
    }

    // MARK: - Segments

    public func saveSegments(_ segments: [TranscriptSegment], for recordingID: UUID) async throws {
        let recording = try fetchEntity(id: recordingID)
        // 既存セグメントを全消去してから入れ替える（contract が "save" = 置換のセマンティクス）。
        try deleteSegmentEntities(for: recordingID)
        for seg in segments {
            // recordingID 不一致のセグメントは contract 上ありえないが、念のため一致させる。
            let normalized = TranscriptSegment(
                id: seg.id,
                recordingID: recordingID,
                source: seg.source,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: seg.text,
                isFinal: seg.isFinal
            )
            let entity = SegmentEntity.make(from: normalized, recording: recording)
            context.insert(entity)
        }
        try saveOrThrow()
    }

    public func appendSegment(_ segment: TranscriptSegment) async throws {
        let recording = try fetchEntity(id: segment.recordingID)
        let entity = SegmentEntity.make(from: segment, recording: recording)
        context.insert(entity)
        try saveOrThrow()
    }

    public func loadSegments(for recordingID: UUID) async throws -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<SegmentEntity>(
            predicate: #Predicate<SegmentEntity> { seg in
                seg.recording?.id == recordingID
            },
            sortBy: [SortDescriptor(\.startSec, order: .forward)]
        )
        let entities = try fetchOrThrow(descriptor)
        return entities.map { $0.toDTO(recordingID: recordingID) }
    }

    public func deleteSegments(for recordingID: UUID) async throws {
        try deleteSegmentEntities(for: recordingID)
        try saveOrThrow()
    }

    private func deleteSegmentEntities(for recordingID: UUID) throws {
        let descriptor = FetchDescriptor<SegmentEntity>(
            predicate: #Predicate<SegmentEntity> { seg in
                seg.recording?.id == recordingID
            }
        )
        let entities = try fetchOrThrow(descriptor)
        for e in entities {
            context.delete(e)
        }
    }

    // MARK: - Summary

    public func saveSummary(_ summary: SummaryDocument) async throws {
        if let existing = try fetchSummary(recordingID: summary.recordingID) {
            try existing.update(from: summary)
        } else {
            let recording = try fetchEntity(id: summary.recordingID)
            let entity = try SummaryEntity.make(from: summary, recording: recording)
            context.insert(entity)
        }
        try saveOrThrow()
    }

    public func loadSummary(for recordingID: UUID) async throws -> SummaryDocument? {
        guard let entity = try fetchSummary(recordingID: recordingID) else { return nil }
        return try entity.toDTO()
    }

    public func deleteSummary(for recordingID: UUID) async throws {
        guard let entity = try fetchSummary(recordingID: recordingID) else { return }
        context.delete(entity)
        try saveOrThrow()
    }

    // MARK: - Private helpers

    private func fetchEntity(id: UUID) throws -> RecordingEntity? {
        let descriptor = FetchDescriptor<RecordingEntity>(
            predicate: #Predicate<RecordingEntity> { $0.id == id }
        )
        return try fetchOrThrow(descriptor).first
    }

    private func fetchSummary(recordingID: UUID) throws -> SummaryEntity? {
        let descriptor = FetchDescriptor<SummaryEntity>(
            predicate: #Predicate<SummaryEntity> { $0.recordingID == recordingID }
        )
        return try fetchOrThrow(descriptor).first
    }

    private func fetchOrThrow<T>(_ descriptor: FetchDescriptor<T>) throws -> [T] where T: PersistentModel {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw RepositoryError.ioFailed(message: "fetch failed: \(error)")
        }
    }

    private func saveOrThrow() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            throw RepositoryError.ioFailed(message: "save failed: \(error)")
        }
    }

    private func removeFile(relativePath: String) throws {
        let url: URL
        do {
            url = try AppPaths.resolveRecordingURL(relativePath)
        } catch {
            throw RepositoryError.ioFailed(message: "resolve path failed: \(error)")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw RepositoryError.fileDeletionFailed(url, message: "\(error)")
        }
    }

    private func removeRecordingDirectory(for id: UUID) throws {
        let fm = FileManager.default
        let dir: URL
        do {
            dir = try AppPaths.recordingsRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        } catch {
            throw RepositoryError.ioFailed(message: "resolve dir failed: \(error)")
        }
        guard fm.fileExists(atPath: dir.path) else { return }
        // ディレクトリが空のときだけ消す（他の予期せぬファイルを誤って消さないため）。
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard contents.isEmpty else { return }
        do {
            try fm.removeItem(at: dir)
        } catch {
            throw RepositoryError.fileDeletionFailed(dir, message: "\(error)")
        }
    }
}
