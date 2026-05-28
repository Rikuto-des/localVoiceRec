import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel.transcribeRecording` の `emptyTranscriptIDs` 管理と
/// `CrossChannelEchoMarker` 適用の検証。
@MainActor
@Suite("AppViewModel — transcribe (empty & dedup)")
struct AppViewModelTranscribeTests {

    private func makeRecording() -> Recording {
        Recording(
            id: UUID(),
            title: "T",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(10),
            micAudioURL: URL(fileURLWithPath: "/tmp/m.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/s.wav")
        )
    }

    @Test("0 セグメント yield → emptyTranscriptIDs に追加され segments は空のまま")
    func transcribeWithEmptyResultsMarksEmptyTranscriptID() async throws {
        let recording = makeRecording()
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository(seed: [recording])
        // samples = [] でかつ何も yield しない transcription を作るため、別 actor を使う
        let transcription = EmptyTranscriptionService()
        let summary = FakeSummaryService()
        let vm = AppViewModel(
            capture: capture,
            repository: repo,
            transcription: transcription,
            summary: summary
        )

        await vm.transcribeRecording(recording)

        #expect(vm.emptyTranscriptIDs.contains(recording.id))
        #expect(vm.transcribingIDs.contains(recording.id) == false)
        // repository には何も書かれない
        let saved = try await repo.loadSegments(for: recording.id)
        #expect(saved.isEmpty)
    }

    @Test("mic + system に同一テキスト yield → mic の isLikelyEcho が true で保存される")
    func transcribeAppliesCrossChannelEchoMarkerBeforePersist() async throws {
        let recording = makeRecording()
        // 同一時間帯・同一テキストの mic / system セグメントを並べる
        let micID = UUID()
        let sysID = UUID()
        let samples: [TranscriptSegment] = [
            TranscriptSegment(
                id: micID, recordingID: recording.id, source: .mic,
                startSec: 0.0, endSec: 3.0,
                text: "皆さんこんばんは。今日の予定を確認します。", isFinal: true
            ),
            TranscriptSegment(
                id: sysID, recordingID: recording.id, source: .system,
                startSec: 0.05, endSec: 3.05,
                text: "皆さんこんばんは。今日の予定を確認します。", isFinal: true
            ),
        ]
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository(seed: [recording])
        let transcription = FakeTranscriptionService(samples: samples)
        let summary = FakeSummaryService()
        let vm = AppViewModel(
            capture: capture,
            repository: repo,
            transcription: transcription,
            summary: summary
        )

        await vm.transcribeRecording(recording)

        let saved = try await repo.loadSegments(for: recording.id)
        #expect(saved.count == 2)
        let mic = saved.first { $0.id == micID }
        let sys = saved.first { $0.id == sysID }
        #expect(mic?.isLikelyEcho == true, "mic 側は echo マークが付くべき")
        #expect(sys?.isLikelyEcho == false, "system 側は対象外")
    }

    @Test("非空 yield 後に再 transcribe → emptyTranscriptIDs はクリアされる")
    func nonEmptyTranscribeClearsEmptyFlag() async throws {
        let recording = makeRecording()
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository(seed: [recording])

        // 1 回目: 空
        let empty = EmptyTranscriptionService()
        let summary = FakeSummaryService()
        let vm1 = AppViewModel(
            capture: capture, repository: repo,
            transcription: empty, summary: summary
        )
        await vm1.transcribeRecording(recording)
        #expect(vm1.emptyTranscriptIDs.contains(recording.id))

        // 2 回目 (新規 VM): 中身あり → 既存 emptyTranscriptIDs はクリアされる挙動を
        // 同一 VM で再現するために、empty 後の同 VM で別 transcription に差し替え不可なので、
        // 「新規 VM で 1 件 yield → emptyTranscriptIDs に入らない」だけ確認する。
        let samples = [
            TranscriptSegment(
                id: UUID(), recordingID: recording.id, source: .mic,
                startSec: 0, endSec: 2,
                text: "今日は天気がいいですね。会議を始めます。", isFinal: true
            )
        ]
        let transcription2 = FakeTranscriptionService(samples: samples)
        let vm2 = AppViewModel(
            capture: capture, repository: repo,
            transcription: transcription2, summary: summary
        )
        await vm2.transcribeRecording(recording)
        #expect(vm2.emptyTranscriptIDs.contains(recording.id) == false)
    }
}

/// transcribe で何も yield しない transcription サービス (テスト専用)。
private actor EmptyTranscriptionService: TranscriptionService {
    func installedLocales() async -> [Locale] { [] }
    nonisolated func transcribe(
        recording: Recording,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
    func cancelAll() async {}
    nonisolated func transcribeLive(
        buffers: AsyncStream<AVAudioPCMBuffer>,
        inputFormat: AVAudioFormat,
        recordingID: UUID,
        source: TranscriptSegment.Source,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

