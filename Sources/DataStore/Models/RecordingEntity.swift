import Foundation
import SwiftData

/// SwiftData 永続化単位。**DataStore モジュール内に閉じる**。
/// UI 層には `Contracts.Recording`（DTO）に変換してから露出する。
///
/// `micRelativePath` / `systemRelativePath` は `AppPaths.recordingsRoot()` からの相対パスで
/// 保存し、ロード時に `AppPaths.resolveRecordingURL(_:)` で絶対 URL に再構築する。
/// これにより Sandbox / コンテナ移動・バックアップ復元でパスが壊れにくい。
@Model
final class RecordingEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date
    var micRelativePath: String
    var systemRelativePath: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SegmentEntity.recording)
    var segments: [SegmentEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \SummaryEntity.recording)
    var summary: SummaryEntity?

    init(
        id: UUID,
        title: String,
        startedAt: Date,
        endedAt: Date,
        micRelativePath: String,
        systemRelativePath: String,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.micRelativePath = micRelativePath
        self.systemRelativePath = systemRelativePath
        self.createdAt = createdAt
        self.segments = []
        self.summary = nil
    }
}
