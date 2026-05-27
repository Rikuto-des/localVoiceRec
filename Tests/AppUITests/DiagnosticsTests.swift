import Testing
import Foundation
@testable import AppUI
import Contracts

/// 診断情報 / 一括 retry の挙動を検証する。
@MainActor
@Suite("Diagnostics & bulk retry")
struct DiagnosticsTests {
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

    @Test("DiagnosticsInfo.empty は notDetermined / 空 locale を持つ")
    func emptyDefaults() {
        let info = DiagnosticsInfo.empty
        #expect(info.micAuthorization == .notDetermined)
        #expect(info.systemAudioAuthorization == .notDetermined)
        #expect(info.installedLocales.isEmpty)
        if case .available = info.summaryAvailability {
            // ok
        } else {
            Issue.record("expected .available for default")
        }
    }

    @Test("refreshDiagnostics は capture / transcription / summary から値を取得する")
    func refreshDiagnosticsPopulatesFields() async {
        let (vm, _, _) = makeViewModel()
        await vm.refreshDiagnostics()

        #expect(vm.diagnostics.micAuthorization == .authorized)
        #expect(vm.diagnostics.systemAudioAuthorization == .authorized)
        // FakeTranscriptionService が ja-JP / en-US を返す
        #expect(vm.diagnostics.installedLocales.count == 2)
        if case .available = vm.diagnostics.summaryAvailability {
            // ok
        } else {
            Issue.record("expected available summary")
        }
    }

    @Test("retryAllPendingTranscriptions は pending な録音だけ処理する")
    func retryAllProcessesPending() async throws {
        let recording = SampleData.recording
        let (vm, _, _) = makeViewModel(seed: [recording])
        await vm.refreshList()

        // pending な状態のはず（segments 無し）
        #expect(vm.status(for: recording.id) == .pending)

        await vm.retryAllPendingTranscriptions()
        // FakeTranscriptionService が 2 件 yield するので transcribed になっているはず
        #expect(vm.status(for: recording.id) == .transcribed || vm.status(for: recording.id) == .completed)
    }

    @Test("retryAllPendingTranscriptions は既に transcribed な録音をスキップする")
    func retryAllSkipsTranscribed() async throws {
        let recording = SampleData.recording
        let (vm, _, repo) = makeViewModel(seed: [recording])
        // 事前に segments を入れて transcribed 状態に
        try await repo.saveSegments(SampleData.segments, for: recording.id)
        await vm.refreshList()
        #expect(vm.status(for: recording.id) == .transcribed)

        // 既存 segments を覚えておく
        let beforeCount = (try await repo.loadSegments(for: recording.id)).count

        await vm.retryAllPendingTranscriptions()

        // status は変わらず（再 transcribe されない）
        let afterCount = (try await repo.loadSegments(for: recording.id)).count
        #expect(beforeCount == afterCount)
    }
}
