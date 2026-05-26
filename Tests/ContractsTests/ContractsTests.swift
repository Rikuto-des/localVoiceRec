import Foundation
import Testing
@testable import Contracts

@Suite("InMemoryRecordingRepository")
struct InMemoryRepoTests {

    @Test func createAndList() async throws {
        let repo = InMemoryRecordingRepository()
        try await repo.create(SampleData.recording)
        let list = try await repo.list(limit: nil, offset: nil)
        #expect(list.count == 1)
        #expect(list.first?.id == SampleData.recording.id)
    }

    @Test func saveAndLoadSegments() async throws {
        let repo = InMemoryRecordingRepository()
        try await repo.create(SampleData.recording)
        try await repo.saveSegments(SampleData.segments, for: SampleData.recording.id)
        let loaded = try await repo.loadSegments(for: SampleData.recording.id)
        #expect(loaded.count == SampleData.segments.count)
    }

    @Test func saveAndLoadSummary() async throws {
        let repo = InMemoryRecordingRepository()
        try await repo.create(SampleData.recording)
        try await repo.saveSummary(SampleData.summary)
        let s = try await repo.loadSummary(for: SampleData.recording.id)
        #expect(s?.decisions.count == SampleData.summary.decisions.count)
    }

    @Test func deletePropagates() async throws {
        let repo = InMemoryRecordingRepository()
        try await repo.create(SampleData.recording)
        try await repo.saveSegments(SampleData.segments, for: SampleData.recording.id)
        try await repo.saveSummary(SampleData.summary)
        try await repo.delete(id: SampleData.recording.id, deleteFilesImmediately: true)
        #expect((try await repo.get(id: SampleData.recording.id)) == nil)
        #expect((try await repo.loadSegments(for: SampleData.recording.id)).isEmpty)
        #expect((try await repo.loadSummary(for: SampleData.recording.id)) == nil)
    }
}

@Suite("FakeAudioCaptureService")
struct FakeCaptureTests {
    @Test func startStopProducesRecording() async throws {
        let svc = FakeAudioCaptureService()
        let dir = FileManager.default.temporaryDirectory
        let session = try await svc.start(in: dir, title: "Test")
        let rec = try await svc.stop()
        #expect(session.id == rec.id)
        #expect(rec.title == "Test")
    }

    @Test func cannotStopWhenIdle() async {
        let svc = FakeAudioCaptureService()
        await #expect(throws: AudioCaptureError.self) {
            _ = try await svc.stop()
        }
    }
}

@Suite("FakeSummaryService")
struct FakeSummaryTests {
    @Test func generateProducesSummary() async throws {
        let svc = FakeSummaryService()
        let summary = try await svc.generate(from: SampleData.segments, recordingID: SampleData.recording.id)
        #expect(summary.recordingID == SampleData.recording.id)
        #expect(!summary.decisions.isEmpty)
    }

    @Test func unavailableThrows() async {
        let svc = FakeSummaryService(availability: .unavailable(reason: .deviceNotEligible))
        await #expect(throws: SummaryError.self) {
            _ = try await svc.generate(from: [], recordingID: UUID())
        }
    }
}

@Suite("AppPaths")
struct AppPathsTests {
    @Test func recordingDirectoryExistsAfterCreation() throws {
        let id = UUID()
        let dir = try AppPaths.recordingDirectory(for: id)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
        // クリーンアップ
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func relativePathRoundtrip() throws {
        let root = try AppPaths.recordingsRoot()
        let id = UUID()
        let url = root.appendingPathComponent("\(id.uuidString)/mic.wav")
        let relative = AppPaths.relativePath(of: url, base: root)
        #expect(relative == "\(id.uuidString)/mic.wav")
        if let relative {
            let resolved = try AppPaths.resolveRecordingURL(relative)
            #expect(resolved.standardizedFileURL.path == url.standardizedFileURL.path)
        }
    }
}
