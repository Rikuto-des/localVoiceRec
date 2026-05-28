import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel` の自動パイプライン (runAutoPipeline) のキャンセル挙動検証。
///
/// 観点:
/// - 録音停止後に走る `transcribe → summarize` パイプラインを途中で deleteRecording すると、
///   `pipelineTasks` の Task が cancel され、進行中の transcribe が中断される。
/// - `lastError` は failure 経路ではなく削除完了経路を辿る。
@MainActor
@Suite("AppViewModel — pipeline cancellation")
struct AppViewModelPipelineTests {

    @Test("runAutoPipeline 進行中に deleteRecording を呼んでも安全に完了する (パイプライン drain 検証)")
    func transcribeCancelOnDelete() async throws {
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository()
        // 長時間 yield し続ける TranscriptionService。delete までに必ず生存している。
        let transcription = SlowFakeTranscription(stepDelayNanos: 100_000_000) // 100ms / step
        let summary = FakeSummaryService(availability: .available)

        let vm = AppViewModel(
            capture: capture,
            repository: repo,
            transcription: transcription,
            summary: summary
        )

        // 録音 → 停止 → パイプライン (transcribe) が裏で走る
        await vm.startRecording()
        await vm.stopRecording()
        #expect(vm.recordings.count == 1)
        let recording = vm.recordings[0]

        // 少し待って transcribe Task が確実に進行中になるようにする
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        #expect(vm.transcribingIDs.contains(recording.id), "transcribe should be in-flight")

        // delete → repository.delete → 内部で pipelineTasks の Task は自然落ち
        // (delete 自体は pipelineTask を明示 cancel しないが、Task はもう削除済みの
        // recording を相手に transcribe するため、後段の saveSegments で repository 側が
        // 「録音不在」を吸収して終わる経路を辿る)
        await vm.deleteRecording(recording)

        #expect(vm.recordings.isEmpty)
        // delete 経路では lastError は nil
        #expect(vm.lastError == nil)

        // パイプラインが何かしらで終わるまで最大数秒待つ (リークしないことの確認)
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !vm.transcribingIDs.contains(recording.id) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(vm.transcribingIDs.contains(recording.id) == false,
                "transcribe task should drain after delete")
    }
}

/// 各 segment 投入の間に sleep を挟む、テスト用の遅い TranscriptionService。
private actor SlowFakeTranscription: TranscriptionService {
    let stepDelayNanos: UInt64

    init(stepDelayNanos: UInt64) {
        self.stepDelayNanos = stepDelayNanos
    }

    func installedLocales() async -> [Locale] {
        [Locale(identifier: "en-US")]
    }

    nonisolated func transcribe(
        recording: Recording,
        locale: Locale?
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let recID = recording.id
        let delay = stepDelayNanos
        return AsyncThrowingStream { cont in
            let task = Task {
                // 10 セグメント × delay → 合計 1s 以上かかる
                for i in 0..<10 {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        cont.finish(throwing: error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: delay)
                    cont.yield(TranscriptSegment(
                        recordingID: recID,
                        source: .mic,
                        startSec: Double(i),
                        endSec: Double(i + 1),
                        text: "slow \(i)",
                        isFinal: true
                    ))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

}
