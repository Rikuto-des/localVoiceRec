import Foundation
import Contracts

// MARK: - JSON helpers

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            return try decoder.decode(T.self, from: Data("null".utf8))
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - RecordingEntity <-> Recording

extension RecordingEntity {
    /// DTO に変換する。`micAudioURL` / `systemAudioURL` は `AppPaths.resolveRecordingURL` で
    /// 相対パスから再構築する。
    func toDTO() throws -> Recording {
        let micURL = try AppPaths.resolveRecordingURL(micRelativePath)
        let sysURL = try AppPaths.resolveRecordingURL(systemRelativePath)
        return Recording(
            id: id,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            micAudioURL: micURL,
            systemAudioURL: sysURL,
            createdAt: createdAt
        )
    }

    /// DTO から `RecordingEntity` を作る。
    /// `micAudioURL` / `systemAudioURL` は `AppPaths.recordingsRoot()` 基準で相対パス化する。
    /// ルート外 URL の場合はパス文字列をそのまま保存（フェイルセーフ）。
    static func make(from dto: Recording) throws -> RecordingEntity {
        let base = try AppPaths.recordingsRoot()
        let micRel = AppPaths.relativePath(of: dto.micAudioURL, base: base) ?? dto.micAudioURL.path
        let sysRel = AppPaths.relativePath(of: dto.systemAudioURL, base: base) ?? dto.systemAudioURL.path
        return RecordingEntity(
            id: dto.id,
            title: dto.title,
            startedAt: dto.startedAt,
            endedAt: dto.endedAt,
            micRelativePath: micRel,
            systemRelativePath: sysRel,
            createdAt: dto.createdAt
        )
    }

    /// 既存 entity を DTO で上書きする（id 以外）。
    func update(from dto: Recording) throws {
        let base = try AppPaths.recordingsRoot()
        title = dto.title
        startedAt = dto.startedAt
        endedAt = dto.endedAt
        micRelativePath = AppPaths.relativePath(of: dto.micAudioURL, base: base) ?? dto.micAudioURL.path
        systemRelativePath = AppPaths.relativePath(of: dto.systemAudioURL, base: base) ?? dto.systemAudioURL.path
        createdAt = dto.createdAt
    }
}

// MARK: - SegmentEntity <-> TranscriptSegment

extension SegmentEntity {
    func toDTO(recordingID: UUID) -> TranscriptSegment {
        let source = TranscriptSegment.Source(rawValue: sourceRaw) ?? .mic
        return TranscriptSegment(
            id: id,
            recordingID: recordingID,
            source: source,
            startSec: startSec,
            endSec: endSec,
            text: text,
            isFinal: isFinal,
            isLikelyEcho: isLikelyEcho ?? false
        )
    }

    static func make(from dto: TranscriptSegment, recording: RecordingEntity?) -> SegmentEntity {
        SegmentEntity(
            id: dto.id,
            sourceRaw: dto.source.rawValue,
            startSec: dto.startSec,
            endSec: dto.endSec,
            text: dto.text,
            isFinal: dto.isFinal,
            isLikelyEcho: dto.isLikelyEcho,
            recording: recording
        )
    }
}

// MARK: - SummaryEntity <-> SummaryDocument

extension SummaryEntity {
    func toDTO() throws -> SummaryDocument {
        let decisions = try JSONCoding.decode([String].self, from: decisionsJSON)
        let actions = try JSONCoding.decode([ActionItem].self, from: actionItemsJSON)
        let openQs = try JSONCoding.decode([String].self, from: openQuestionsJSON)
        let reviews = try JSONCoding.decode([String].self, from: reviewItemsJSON)
        return SummaryDocument(
            recordingID: recordingID,
            overview: overview,
            decisions: decisions,
            actionItems: actions,
            openQuestions: openQs,
            reviewItems: reviews,
            generatedAt: generatedAt
        )
    }

    static func make(from dto: SummaryDocument, recording: RecordingEntity?) throws -> SummaryEntity {
        SummaryEntity(
            recordingID: dto.recordingID,
            overview: dto.overview,
            decisionsJSON: try JSONCoding.encode(dto.decisions),
            actionItemsJSON: try JSONCoding.encode(dto.actionItems),
            openQuestionsJSON: try JSONCoding.encode(dto.openQuestions),
            reviewItemsJSON: try JSONCoding.encode(dto.reviewItems),
            generatedAt: dto.generatedAt,
            recording: recording
        )
    }

    func update(from dto: SummaryDocument) throws {
        overview = dto.overview
        decisionsJSON = try JSONCoding.encode(dto.decisions)
        actionItemsJSON = try JSONCoding.encode(dto.actionItems)
        openQuestionsJSON = try JSONCoding.encode(dto.openQuestions)
        reviewItemsJSON = try JSONCoding.encode(dto.reviewItems)
        generatedAt = dto.generatedAt
    }
}
