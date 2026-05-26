import Foundation

/// プロセス内メモリで状態を持つ Repository。
/// UI Previews / S2 並列開発で UI が単独動作するために使う。
public actor InMemoryRecordingRepository: RecordingRepository {
    private var recordings: [UUID: Recording] = [:]
    private var segments: [UUID: [TranscriptSegment]] = [:]
    private var summaries: [UUID: SummaryDocument] = [:]

    public init(seed: [Recording] = []) {
        for r in seed { recordings[r.id] = r }
    }

    // ─── Recording ───
    public func create(_ recording: Recording) async throws {
        recordings[recording.id] = recording
    }

    public func list(limit: Int?, offset: Int?) async throws -> [Recording] {
        let sorted = recordings.values.sorted { $0.startedAt > $1.startedAt }
        let start = offset ?? 0
        let end = limit.map { min(start + $0, sorted.count) } ?? sorted.count
        guard start < sorted.count else { return [] }
        return Array(sorted[start..<end])
    }

    public func search(query: String) async throws -> [Recording] {
        let q = query.lowercased()
        guard !q.isEmpty else { return try await list(limit: nil, offset: nil) }
        return recordings.values
            .filter { $0.title.lowercased().contains(q) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func get(id: UUID) async throws -> Recording? {
        recordings[id]
    }

    public func delete(id: UUID, deleteFilesImmediately: Bool) async throws {
        recordings.removeValue(forKey: id)
        segments.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
        // In-memory mock has no real files to remove; deleteFilesImmediately is a no-op here.
        _ = deleteFilesImmediately
    }

    public func deleteAll(deleteFilesImmediately: Bool) async throws {
        recordings.removeAll()
        segments.removeAll()
        summaries.removeAll()
        _ = deleteFilesImmediately
    }

    // ─── Segments ───
    public func saveSegments(_ newSegments: [TranscriptSegment], for recordingID: UUID) async throws {
        segments[recordingID] = newSegments
    }

    public func appendSegment(_ segment: TranscriptSegment) async throws {
        segments[segment.recordingID, default: []].append(segment)
    }

    public func loadSegments(for recordingID: UUID) async throws -> [TranscriptSegment] {
        segments[recordingID] ?? []
    }

    public func deleteSegments(for recordingID: UUID) async throws {
        segments.removeValue(forKey: recordingID)
    }

    // ─── Summary ───
    public func saveSummary(_ summary: SummaryDocument) async throws {
        summaries[summary.recordingID] = summary
    }

    public func loadSummary(for recordingID: UUID) async throws -> SummaryDocument? {
        summaries[recordingID]
    }

    public func deleteSummary(for recordingID: UUID) async throws {
        summaries.removeValue(forKey: recordingID)
    }
}
