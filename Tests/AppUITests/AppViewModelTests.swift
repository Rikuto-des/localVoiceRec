import Testing
import Foundation
@testable import AppUI
import Contracts

/// `AppViewModel` の状態遷移を Mock service で検証する。
@MainActor
@Suite("AppViewModel state transitions")
struct AppViewModelTests {
    private func makeViewModel(
        seed: [Recording] = [],
        availability: SummaryAvailability = .available
    ) -> (AppViewModel, FakeAudioCaptureService, InMemoryRecordingRepository) {
        let capture = FakeAudioCaptureService()
        let repository = InMemoryRecordingRepository(seed: seed)
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService(availability: availability)
        let vm = AppViewModel(
            capture: capture,
            repository: repository,
            transcription: transcription,
            summary: summary
        )
        return (vm, capture, repository)
    }

    @Test("初期状態は idle で recordings が空")
    func initialState() async {
        let (vm, _, _) = makeViewModel()
        #expect(vm.captureState == .idle)
        #expect(vm.recordings.isEmpty)
        #expect(vm.selectedRecording == nil)
        #expect(vm.segments.isEmpty)
        #expect(vm.summaryDocument == nil)
        #expect(vm.lastError == nil)
    }

    @Test("startRecording 後 captureState が .recording になる")
    func startRecordingTransitionsToRecording() async {
        let (vm, _, _) = makeViewModel()
        await vm.startRecording()
        switch vm.captureState {
        case .recording:
            #expect(vm.lastError == nil)
        case .idle, .preparing, .paused, .finalizing, .failed, .interrupted:
            Issue.record("Expected .recording state, got \(vm.captureState)")
        }
    }

    @Test("stopRecording 後 captureState が .idle になり recordings に 1 件追加される")
    func stopRecordingCreatesRecording() async {
        let (vm, _, _) = makeViewModel()
        await vm.startRecording()
        await vm.stopRecording()

        #expect(vm.captureState == .idle)
        #expect(vm.recordings.count == 1)
        #expect(vm.lastError == nil)
    }

    @Test("pause / resume の状態遷移")
    func pauseResumeTransitions() async {
        let (vm, _, _) = makeViewModel()
        await vm.startRecording()

        await vm.pauseRecording()
        switch vm.captureState {
        case .paused:
            break
        case .idle, .preparing, .recording, .finalizing, .failed, .interrupted:
            Issue.record("Expected .paused state, got \(vm.captureState)")
        }

        await vm.resumeRecording()
        switch vm.captureState {
        case .recording:
            break
        case .idle, .preparing, .paused, .finalizing, .failed, .interrupted:
            Issue.record("Expected .recording state after resume, got \(vm.captureState)")
        }
    }

    @Test("select 後 segments と summary が読み込まれる")
    func selectLoadsSegmentsAndSummary() async throws {
        let recording = SampleData.recording
        let (vm, _, repo) = makeViewModel(seed: [recording])
        try await repo.saveSegments(SampleData.segments, for: recording.id)
        try await repo.saveSummary(SampleData.summary)

        await vm.refreshList()
        await vm.select(recording)

        #expect(vm.selectedRecording?.id == recording.id)
        #expect(vm.segments.count == SampleData.segments.count)
        #expect(vm.summaryDocument != nil)
        #expect(vm.summaryDocument?.overview == SampleData.summary.overview)
    }

    @Test("select で segments は startSec 昇順にソートされる")
    func selectSortsSegmentsByStartSec() async throws {
        let recording = SampleData.recording
        let (vm, _, repo) = makeViewModel(seed: [recording])

        let unsorted: [TranscriptSegment] = [
            TranscriptSegment(recordingID: recording.id, source: .mic,
                              startSec: 10.0, endSec: 12.0,
                              text: "second", isFinal: true),
            TranscriptSegment(recordingID: recording.id, source: .system,
                              startSec: 0.0, endSec: 2.0,
                              text: "first", isFinal: true),
        ]
        try await repo.saveSegments(unsorted, for: recording.id)

        await vm.refreshList()
        await vm.select(recording)

        #expect(vm.segments.first?.text == "first")
        #expect(vm.segments.last?.text == "second")
    }

    @Test("regenerateSummary で要約が更新される")
    func regenerateSummaryUpdatesDocument() async throws {
        let recording = SampleData.recording
        let (vm, _, repo) = makeViewModel(seed: [recording])
        try await repo.saveSegments(SampleData.segments, for: recording.id)

        await vm.refreshList()
        await vm.select(recording)

        #expect(vm.summaryDocument == nil)

        await vm.regenerateSummary(hint: nil)
        #expect(vm.summaryDocument != nil)
        #expect(vm.lastError == nil)
    }

    @Test("deleteRecording で recordings から消える")
    func deleteRecordingRemovesEntry() async throws {
        let recording = SampleData.recording
        let (vm, _, _) = makeViewModel(seed: [recording])

        await vm.refreshList()
        #expect(vm.recordings.count == 1)

        await vm.deleteRecording(recording)
        #expect(vm.recordings.isEmpty)
        #expect(vm.selectedRecording == nil)
    }

    @Test("summary が unavailable のときは regenerate でエラーが入る")
    func regenerateSummaryWhenUnavailable() async throws {
        let recording = SampleData.recording
        let (vm, _, repo) = makeViewModel(
            seed: [recording],
            availability: .unavailable(reason: .modelNotReady)
        )
        try await repo.saveSegments(SampleData.segments, for: recording.id)

        await vm.refreshList()
        await vm.select(recording)
        await vm.regenerateSummary(hint: nil)

        #expect(vm.lastError != nil)
    }
}
