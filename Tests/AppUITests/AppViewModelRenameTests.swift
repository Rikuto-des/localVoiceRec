import Testing
import Foundation
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel.renameRecording` の振る舞いを検証する。
@MainActor
@Suite("AppViewModel renameRecording")
struct AppViewModelRenameTests {
    private func makeViewModel(
        seed: [Recording] = []
    ) -> (AppViewModel, InMemoryRecordingRepository) {
        let capture = FakeAudioCaptureService()
        let repository = InMemoryRecordingRepository(seed: seed)
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService()
        let vm = AppViewModel(
            capture: capture,
            repository: repository,
            transcription: transcription,
            summary: summary
        )
        return (vm, repository)
    }

    @Test("新しいタイトルでタイトルが更新される")
    func renameUpdatesTitle() async throws {
        let recording = SampleData.recording
        let (vm, _) = makeViewModel(seed: [recording])
        await vm.refreshList()

        await vm.renameRecording(recording, newTitle: "新タイトル")

        let updated = vm.recordings.first { $0.id == recording.id }
        #expect(updated?.title == "新タイトル")
        #expect(vm.lastError == nil)
    }

    @Test("選択中の録音をリネームすると selectedRecording も差し替わる")
    func renameUpdatesSelectedRecording() async throws {
        let recording = SampleData.recording
        let (vm, _) = makeViewModel(seed: [recording])
        await vm.refreshList()
        await vm.select(recording)

        await vm.renameRecording(recording, newTitle: "別のタイトル")

        #expect(vm.selectedRecording?.id == recording.id)
        #expect(vm.selectedRecording?.title == "別のタイトル")
    }

    @Test("空文字 / 空白だけのタイトルは無視される")
    func renameIgnoresEmptyTitle() async throws {
        let recording = SampleData.recording
        let (vm, _) = makeViewModel(seed: [recording])
        await vm.refreshList()
        let original = recording.title

        await vm.renameRecording(recording, newTitle: "")
        await vm.renameRecording(recording, newTitle: "   \n  ")

        let after = vm.recordings.first { $0.id == recording.id }
        #expect(after?.title == original)
        #expect(vm.lastError == nil)
    }

    @Test("同じタイトルを渡しても repository は呼ばれず no-op")
    func renameSameTitleIsNoOp() async throws {
        let recording = SampleData.recording
        let (vm, repo) = makeViewModel(seed: [recording])
        await vm.refreshList()

        await vm.renameRecording(recording, newTitle: recording.title)

        // タイトルは変わらず、エラーも入らない
        let after = vm.recordings.first { $0.id == recording.id }
        #expect(after?.title == recording.title)
        #expect(vm.lastError == nil)

        // repository から fetch しても変化なし (副作用が無かったことの間接確認)
        let fetched = try await repo.get(id: recording.id)
        #expect(fetched?.title == recording.title)
    }

    @Test("前後空白は trim されて保存される")
    func renameTrimsWhitespace() async throws {
        let recording = SampleData.recording
        let (vm, _) = makeViewModel(seed: [recording])
        await vm.refreshList()

        await vm.renameRecording(recording, newTitle: "  パディング有り  ")

        let updated = vm.recordings.first { $0.id == recording.id }
        #expect(updated?.title == "パディング有り")
    }
}
