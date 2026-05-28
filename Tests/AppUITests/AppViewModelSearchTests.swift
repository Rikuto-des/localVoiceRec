import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel.searchDebounced` の挙動検証。
///
/// 観点:
/// - 連続呼び出し時、進行中の検索タスクが cancel され `repository.search` は 1 回しか走らない。
/// - 空文字なら `refreshList` 経路 (= `search` を呼ばない) に切り替わる。
@MainActor
@Suite("AppViewModel — searchDebounced")
struct AppViewModelSearchTests {

    private func makeViewModel(seed: [Recording] = [])
        -> (AppViewModel, InMemoryRecordingRepository)
    {
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository(seed: seed)
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService()
        let vm = AppViewModel(
            capture: capture, repository: repo,
            transcription: transcription, summary: summary
        )
        return (vm, repo)
    }

    @Test("searchDebounced を連続 5 回呼んでも repository.search は 1 回しか走らない")
    func searchDebouncedCancelsInflightTask() async throws {
        let (vm, repo) = makeViewModel(seed: [
            Recording(
                id: UUID(), title: "design review",
                startedAt: Date(), endedAt: Date(),
                micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
                systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
            )
        ])

        // baseline
        let before = await repo.searchCallCount
        #expect(before == 0)

        // 連続 5 回 — debounce は 300ms なので、間隔 10ms なら最後の 1 回だけが実行される
        for q in ["d", "de", "des", "desi", "design"] {
            vm.searchDebounced(query: q)
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        // debounce 確定を待つ (300ms + 余裕)
        try await Task.sleep(nanoseconds: 500_000_000)

        let after = await repo.searchCallCount
        #expect(after - before == 1, "debounce で 1 回だけ実行されるべき (実際: \(after - before))")
    }

    @Test("空文字 searchDebounced は repository.search を呼ばず refreshList ルートに乗る")
    func searchEmptyStringResetsToList() async throws {
        let recording = Recording(
            id: UUID(), title: "Morning standup",
            startedAt: Date(), endedAt: Date(),
            micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
        )
        let (vm, repo) = makeViewModel(seed: [recording])

        // 空文字を投入
        vm.searchDebounced(query: "")
        try await Task.sleep(nanoseconds: 500_000_000)

        // 1) search は呼ばれていない
        let calls = await repo.searchCallCount
        #expect(calls == 0)
        // 2) refreshList 経由で recordings が一覧復元されている
        #expect(vm.recordings.contains(where: { $0.id == recording.id }))
    }

    @Test("非空 → 空 と連続投入すると、最後の空文字が勝って refreshList ルートに乗る")
    func nonEmptyThenEmptyOnlyRefreshes() async throws {
        let (vm, repo) = makeViewModel(seed: [
            Recording(
                id: UUID(), title: "X",
                startedAt: Date(), endedAt: Date(),
                micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
                systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
            )
        ])
        vm.searchDebounced(query: "abc")
        try? await Task.sleep(nanoseconds: 10_000_000)
        vm.searchDebounced(query: "")
        try await Task.sleep(nanoseconds: 500_000_000)

        let calls = await repo.searchCallCount
        #expect(calls == 0, "後勝ちで空文字が選ばれるため search は呼ばれない")
    }
}
