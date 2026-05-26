import Foundation
import Testing
import SwiftData
@testable import Contracts
@testable import DataStore

/// In-memory ModelContainer を組み立てて Repository を返す。
private func makeInMemoryRepo() throws -> RecordingRepositoryImpl {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: RecordingEntity.self, SegmentEntity.self, SummaryEntity.self,
        configurations: config
    )
    return RecordingRepositoryImpl(container: container)
}

/// recordingsRoot() 配下の dummy URL を作る（実ファイルは作らない）。
private func makeRecordingDTO(
    id: UUID = UUID(),
    title: String = "Meeting"
) throws -> Recording {
    let root = try AppPaths.recordingsRoot()
    let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
    return Recording(
        id: id,
        title: title,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_001_000),
        micAudioURL: dir.appendingPathComponent("mic.wav"),
        systemAudioURL: dir.appendingPathComponent("system.wav"),
        createdAt: Date(timeIntervalSince1970: 1_700_001_500)
    )
}

@Suite("RecordingRepositoryImpl — Recording CRUD")
struct RecordingCRUDTests {

    @Test func createAndGetRoundTrip() async throws {
        let repo = try makeInMemoryRepo()
        let dto = try makeRecordingDTO(title: "Hello")
        try await repo.create(dto)

        let loaded = try await repo.get(id: dto.id)
        #expect(loaded != nil)
        #expect(loaded?.id == dto.id)
        #expect(loaded?.title == "Hello")
        #expect(loaded?.startedAt == dto.startedAt)
        #expect(loaded?.endedAt == dto.endedAt)
        #expect(loaded?.micAudioURL.standardizedFileURL == dto.micAudioURL.standardizedFileURL)
        #expect(loaded?.systemAudioURL.standardizedFileURL == dto.systemAudioURL.standardizedFileURL)
    }

    @Test func listSortsByStartedAtDescending() async throws {
        let repo = try makeInMemoryRepo()
        let older = try makeRecordingDTO(title: "Older")
        var newerDTO = try makeRecordingDTO(title: "Newer")
        newerDTO = Recording(
            id: newerDTO.id,
            title: newerDTO.title,
            startedAt: older.startedAt.addingTimeInterval(3600),
            endedAt: older.endedAt.addingTimeInterval(3600),
            micAudioURL: newerDTO.micAudioURL,
            systemAudioURL: newerDTO.systemAudioURL,
            createdAt: newerDTO.createdAt
        )
        try await repo.create(older)
        try await repo.create(newerDTO)

        let list = try await repo.list(limit: nil, offset: nil)
        #expect(list.count == 2)
        #expect(list.first?.title == "Newer")
        #expect(list.last?.title == "Older")
    }

    @Test func listRespectsLimitAndOffset() async throws {
        let repo = try makeInMemoryRepo()
        // 3 件作成、startedAt をずらす
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            let id = UUID()
            let root = try AppPaths.recordingsRoot()
            let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let dto = Recording(
                id: id,
                title: "R\(i)",
                startedAt: base.addingTimeInterval(TimeInterval(i) * 100),
                endedAt: base.addingTimeInterval(TimeInterval(i) * 100 + 10),
                micAudioURL: dir.appendingPathComponent("mic.wav"),
                systemAudioURL: dir.appendingPathComponent("system.wav")
            )
            try await repo.create(dto)
        }
        let page = try await repo.list(limit: 1, offset: 1)
        #expect(page.count == 1)
        // 降順なので index 1 は R1
        #expect(page.first?.title == "R1")
    }

    @Test func searchByTitleSubstring() async throws {
        let repo = try makeInMemoryRepo()
        try await repo.create(try makeRecordingDTO(title: "Daily Standup"))
        try await repo.create(try makeRecordingDTO(title: "Sprint Review"))

        let hits = try await repo.search(query: "standup")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "Daily Standup")

        let all = try await repo.search(query: "")
        #expect(all.count == 2)
    }

    @Test func deleteRemovesRecord() async throws {
        let repo = try makeInMemoryRepo()
        let dto = try makeRecordingDTO()
        try await repo.create(dto)
        try await repo.delete(id: dto.id, deleteFilesImmediately: false)

        let after = try await repo.get(id: dto.id)
        #expect(after == nil)
    }

    @Test func deleteAllClearsStore() async throws {
        let repo = try makeInMemoryRepo()
        try await repo.create(try makeRecordingDTO(title: "A"))
        try await repo.create(try makeRecordingDTO(title: "B"))
        try await repo.deleteAll(deleteFilesImmediately: false)

        let list = try await repo.list(limit: nil, offset: nil)
        #expect(list.isEmpty)
    }
}

@Suite("RecordingRepositoryImpl — Segments")
struct SegmentTests {
    @Test func saveAndLoadSegments() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)

        let segments: [TranscriptSegment] = [
            TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 2, text: "hello", isFinal: true),
            TranscriptSegment(recordingID: rec.id, source: .system, startSec: 2, endSec: 4, text: "world", isFinal: true),
        ]
        try await repo.saveSegments(segments, for: rec.id)

        let loaded = try await repo.loadSegments(for: rec.id)
        #expect(loaded.count == 2)
        // sorted by startSec asc
        #expect(loaded[0].text == "hello")
        #expect(loaded[0].source == .mic)
        #expect(loaded[1].text == "world")
        #expect(loaded[1].source == .system)
    }

    @Test func appendSegmentAddsOne() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)

        let seg = TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 1, text: "hi", isFinal: true)
        try await repo.appendSegment(seg)
        try await repo.appendSegment(
            TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 1, endSec: 2, text: "there", isFinal: true)
        )
        let loaded = try await repo.loadSegments(for: rec.id)
        #expect(loaded.count == 2)
    }

    @Test func saveSegmentsReplacesExisting() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)

        let first = [
            TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 1, text: "old", isFinal: true)
        ]
        try await repo.saveSegments(first, for: rec.id)
        let replacement = [
            TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 1, text: "new", isFinal: true),
            TranscriptSegment(recordingID: rec.id, source: .system, startSec: 1, endSec: 2, text: "new2", isFinal: true),
        ]
        try await repo.saveSegments(replacement, for: rec.id)

        let loaded = try await repo.loadSegments(for: rec.id)
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { $0.text == "new" || $0.text == "new2" })
    }

    @Test func deleteSegmentsClearsForRecording() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)
        try await repo.saveSegments(
            [TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 1, text: "x", isFinal: true)],
            for: rec.id
        )
        try await repo.deleteSegments(for: rec.id)
        let loaded = try await repo.loadSegments(for: rec.id)
        #expect(loaded.isEmpty)
    }
}

@Suite("RecordingRepositoryImpl — Summary")
struct SummaryTests {
    @Test func saveAndLoadSummary() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)

        let summary = SummaryDocument(
            recordingID: rec.id,
            overview: "An important meeting.",
            decisions: ["Ship on Friday", "Hire two engineers"],
            actionItems: [
                ActionItem(title: "Write spec", assignee: "Alice", dueDate: Date(timeIntervalSince1970: 1_700_100_000)),
                ActionItem(title: "Review PR", assignee: nil, dueDate: nil),
            ],
            openQuestions: ["Budget?"],
            reviewItems: ["Check legal"],
            generatedAt: Date(timeIntervalSince1970: 1_700_010_000)
        )
        try await repo.saveSummary(summary)

        let loaded = try await repo.loadSummary(for: rec.id)
        #expect(loaded != nil)
        #expect(loaded?.overview == "An important meeting.")
        #expect(loaded?.decisions == ["Ship on Friday", "Hire two engineers"])
        #expect(loaded?.actionItems.count == 2)
        #expect(loaded?.actionItems.first?.title == "Write spec")
        #expect(loaded?.actionItems.first?.assignee == "Alice")
        #expect(loaded?.openQuestions == ["Budget?"])
        #expect(loaded?.reviewItems == ["Check legal"])
        #expect(loaded?.generatedAt == summary.generatedAt)
    }

    @Test func saveSummaryUpsert() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)

        let s1 = SummaryDocument(
            recordingID: rec.id,
            overview: "v1",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            reviewItems: [],
            generatedAt: Date()
        )
        try await repo.saveSummary(s1)
        let s2 = SummaryDocument(
            recordingID: rec.id,
            overview: "v2",
            decisions: ["d"],
            actionItems: [],
            openQuestions: [],
            reviewItems: [],
            generatedAt: Date()
        )
        try await repo.saveSummary(s2)

        let loaded = try await repo.loadSummary(for: rec.id)
        #expect(loaded?.overview == "v2")
        #expect(loaded?.decisions == ["d"])
    }

    @Test func deleteSummary() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)
        try await repo.saveSummary(
            SummaryDocument(
                recordingID: rec.id,
                overview: "x",
                decisions: [],
                actionItems: [],
                openQuestions: [],
                reviewItems: [],
                generatedAt: Date()
            )
        )
        try await repo.deleteSummary(for: rec.id)
        let loaded = try await repo.loadSummary(for: rec.id)
        #expect(loaded == nil)
    }
}

@Suite("RecordingRepositoryImpl — relative path round trip")
struct RelativePathTests {
    @Test func micAndSystemURLsResolveUnderRecordingsRoot() async throws {
        let repo = try makeInMemoryRepo()
        let dto = try makeRecordingDTO()
        try await repo.create(dto)

        let loaded = try await repo.get(id: dto.id)
        #expect(loaded != nil)
        let root = try AppPaths.recordingsRoot().standardizedFileURL.path
        #expect(loaded!.micAudioURL.standardizedFileURL.path.hasPrefix(root))
        #expect(loaded!.systemAudioURL.standardizedFileURL.path.hasPrefix(root))
        #expect(loaded!.micAudioURL.lastPathComponent == "mic.wav")
        #expect(loaded!.systemAudioURL.lastPathComponent == "system.wav")
    }
}

@Suite("RecordingRepositoryImpl — cascade delete")
struct CascadeTests {
    @Test func deletingRecordingRemovesSegmentsAndSummary() async throws {
        let repo = try makeInMemoryRepo()
        let rec = try makeRecordingDTO()
        try await repo.create(rec)
        try await repo.saveSegments(
            [TranscriptSegment(recordingID: rec.id, source: .mic, startSec: 0, endSec: 1, text: "x", isFinal: true)],
            for: rec.id
        )
        try await repo.saveSummary(
            SummaryDocument(
                recordingID: rec.id,
                overview: "x",
                decisions: [],
                actionItems: [],
                openQuestions: [],
                reviewItems: [],
                generatedAt: Date()
            )
        )

        try await repo.delete(id: rec.id, deleteFilesImmediately: false)

        let segs = try await repo.loadSegments(for: rec.id)
        let sum = try await repo.loadSummary(for: rec.id)
        #expect(segs.isEmpty)
        #expect(sum == nil)
    }
}

@Suite("RecordingRepositoryImpl — file deletion")
struct FileDeletionTests {
    @Test func deleteFilesImmediatelyRemovesWAVs() async throws {
        let repo = try makeInMemoryRepo()
        let id = UUID()
        let dir = try AppPaths.recordingDirectory(for: id)
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        try Data("mic".utf8).write(to: micURL)
        try Data("sys".utf8).write(to: sysURL)

        let dto = Recording(
            id: id,
            title: "with files",
            startedAt: Date(),
            endedAt: Date(),
            micAudioURL: micURL,
            systemAudioURL: sysURL
        )
        try await repo.create(dto)
        try await repo.delete(id: id, deleteFilesImmediately: true)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: micURL.path))
        #expect(!fm.fileExists(atPath: sysURL.path))
        // ディレクトリが空なら消えるはず
        #expect(!fm.fileExists(atPath: dir.path))
    }
}
