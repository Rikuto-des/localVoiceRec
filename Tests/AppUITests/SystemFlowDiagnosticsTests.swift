import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `SystemFlowSnapshot` が診断に流れ込むパスと、停止時の警告ロジックの検証。
@MainActor
@Suite("SystemFlow diagnostics & stop warning")
struct SystemFlowDiagnosticsTests {

    private func makeViewModel()
        -> (AppViewModel, FakeAudioCaptureService, InMemoryRecordingRepository)
    {
        let capture = FakeAudioCaptureService()
        let repo = InMemoryRecordingRepository()
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService()
        let vm = AppViewModel(
            capture: capture, repository: repo,
            transcription: transcription, summary: summary
        )
        return (vm, capture, repo)
    }

    @Test("refreshDiagnostics は capture.setSystemFlowSnapshot で注入された値を表に出す")
    func refreshDiagnosticsExposesInjectedSystemFlow() async {
        let (vm, capture, _) = makeViewModel()
        // 初期: nil (Fake が常時 nil を返す)
        await vm.refreshDiagnostics()
        #expect(vm.diagnostics.systemFlow == nil)

        // 値を注入
        let injected = SystemFlowSnapshot(
            callCount: 100,
            bytesReceived: 4_096_000,
            nonZeroBufferCount: 95,
            droppedPushCount: 0
        )
        await capture.setSystemFlowSnapshot(injected)
        await vm.refreshDiagnostics()

        #expect(vm.diagnostics.systemFlow == injected)
        #expect(vm.diagnostics.systemFlow?.callCount == 100)
        #expect(vm.diagnostics.systemFlow?.bytesReceived == 4_096_000)
        #expect(vm.diagnostics.systemFlow?.nonZeroBufferCount == 95)
    }

    @Test("nil → snapshot → nil とトグルしても診断が正しく追従する")
    func systemFlowToggleNilSnapshotNil() async {
        let (vm, capture, _) = makeViewModel()

        await vm.refreshDiagnostics()
        #expect(vm.diagnostics.systemFlow == nil)

        let snap = SystemFlowSnapshot(callCount: 1, bytesReceived: 2, nonZeroBufferCount: 3, droppedPushCount: 0)
        await capture.setSystemFlowSnapshot(snap)
        await vm.refreshDiagnostics()
        #expect(vm.diagnostics.systemFlow == snap)

        await capture.setSystemFlowSnapshot(nil)
        await vm.refreshDiagnostics()
        #expect(vm.diagnostics.systemFlow == nil)
    }

    @Test("stopRecording 時、mic アクティブだが system flow が全 0 → lastError に警告メッセージ")
    func stopWarnsWhenSystemFlowIsZeroAfterActiveMic() async throws {
        let (vm, capture, _) = makeViewModel()
        // ViewModel が capture.liveAudioLevels を購読し audioLevels に積むようにする
        vm.startObservingAudioLevels()

        // 録音開始 → FakeAudioCaptureService が level emitter を回し
        //   mic / system 共に動くサンプルを yield する。
        await vm.startRecording()

        // audioLevels に mic ピークが乗るのを待つ (まばらでもよい)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if vm.audioLevels.contains(where: { $0.micPeak >= AudioLevelSnapshot.silenceThreshold }) {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            vm.audioLevels.contains(where: { $0.micPeak >= AudioLevelSnapshot.silenceThreshold }),
            "mic が一度でも有音 (peak >= threshold) を観測しているはず"
        )

        // 停止時に system が全 0 だった、と返すよう注入する
        let zeroSystemFlow = SystemFlowSnapshot(
            callCount: 50,
            bytesReceived: 0,
            nonZeroBufferCount: 0,
            droppedPushCount: 0
        )
        await capture.setSystemFlowSnapshot(zeroSystemFlow)

        await vm.stopRecording()

        // 警告メッセージが lastError に入る
        #expect(vm.lastError != nil, "system flow 全 0 警告が出るはず")
        #expect(vm.lastError?.contains("システム音声") == true)
    }

    @Test("stopRecording 時に systemFlow != nil かつ非ゼロなら警告は出ない")
    func stopDoesNotWarnWhenSystemFlowHasData() async throws {
        let (vm, capture, _) = makeViewModel()
        vm.startObservingAudioLevels()
        await vm.startRecording()

        try? await Task.sleep(nanoseconds: 200_000_000)

        let goodFlow = SystemFlowSnapshot(
            callCount: 50,
            bytesReceived: 8000,
            nonZeroBufferCount: 40,
            droppedPushCount: 0
        )
        await capture.setSystemFlowSnapshot(goodFlow)

        await vm.stopRecording()
        // lastError は nil (正常停止)
        #expect(vm.lastError == nil)
    }
}
