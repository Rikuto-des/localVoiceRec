import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel` の `.interrupted` 状態と関連挙動の検証。
///
/// `FakeAudioCaptureService.emitInterruption(reason:)` を使って録音中に
/// 強制的に `.interrupted` 状態を作る。
@MainActor
@Suite("AppViewModel — interrupted state")
struct AppViewModelInterruptedTests {

    private func makeViewModel() -> (AppViewModel, FakeAudioCaptureService) {
        let capture = FakeAudioCaptureService()
        let repository = InMemoryRecordingRepository()
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService(availability: .available)
        let vm = AppViewModel(
            capture: capture,
            repository: repository,
            transcription: transcription,
            summary: summary
        )
        return (vm, capture)
    }

    /// `captureState` が指定タイプに収束するまで最大 `timeoutMs` ミリ秒待つ。
    /// `subscribeToCaptureState` の AsyncStream 経由で UI 側に伝わるラグを吸収するため。
    private func waitForState(
        _ vm: AppViewModel,
        timeoutMs: Int = 1000,
        predicate: (CaptureState) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if predicate(vm.captureState) { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    @Test("録音中に emitInterruption → vm.captureState == .interrupted, isCapturing は true のまま")
    func interruptedStateSurfaces() async {
        let (vm, capture) = makeViewModel()
        await vm.subscribeToCaptureState()

        await vm.startRecording()
        // 録音中であることを確認
        switch vm.captureState {
        case .recording: break
        default:
            Issue.record("Expected .recording before interruption, got \(vm.captureState)")
            return
        }

        // FakeAudioCaptureService に interruption を emit させる。
        await capture.emitInterruption(reason: .systemWillSleep)

        await waitForState(vm) { state in
            if case .interrupted = state { return true } else { return false }
        }

        switch vm.captureState {
        case .interrupted(let reason, _, _):
            #expect(reason == .systemWillSleep)
        default:
            Issue.record("Expected .interrupted, got \(vm.captureState)")
        }

        // isCapturing は `.interrupted` も含むため true のまま (UI に「中断状態」を見せる)
        #expect(vm.isCapturing == true)
        // 一方 isActivelyRecording は false (停止可能 UI を出す)
        #expect(vm.isActivelyRecording == false)
        #expect(vm.isPaused == false)
    }

    @Test("interrupted 後 stopRecording で recordings に保存され idle に戻る")
    func stopAfterInterruptedSavesRecording() async {
        let (vm, capture) = makeViewModel()
        await vm.subscribeToCaptureState()

        await vm.startRecording()
        await capture.emitInterruption(reason: .engineConfigurationChanged)

        await waitForState(vm) { state in
            if case .interrupted = state { return true } else { return false }
        }
        guard case .interrupted = vm.captureState else {
            Issue.record("Pre-condition failed: not interrupted")
            return
        }

        // stop は interrupted からも遷移可能 (FakeAudioCaptureService.stop の実装で確認)
        await vm.stopRecording()
        #expect(vm.captureState == .idle)
        #expect(vm.recordings.count == 1)
        #expect(vm.lastError == nil)
    }
}
