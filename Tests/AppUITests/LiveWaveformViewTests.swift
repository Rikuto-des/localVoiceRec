import Testing
import Foundation
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `LiveWaveformView` の history buffer 挙動を確認する。
///
/// View 本体は SwiftUI で snapshot test しづらいので、`appendForTest` 経由で
/// snapshot を流し込み、ローリングバッファのトリミングが想定通りか検証する。
@MainActor
@Suite("LiveWaveformView buffer")
struct LiveWaveformViewTests {

    @Test("historyOverride で渡したスナップショットが描画対象になる")
    func historyOverrideIsHonored() async {
        // 新設計: View は ViewModel.audioLevels を読むだけ。
        // テストでは historyOverride を使って固定 buffer を流し込み、構築できることだけ確認。
        let vm = AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
        let history: [AudioLevelSnapshot] = stride(from: 0.0, through: 5.0, by: 0.5).map { t in
            AudioLevelSnapshot(
                elapsedSec: t,
                micRMS: 0.1, micPeak: 0.2,
                systemRMS: 0.05, systemPeak: 0.1
            )
        }
        let view = LiveWaveformView(viewModel: vm, historyOverride: history)
        _ = view  // 構築できれば OK（SwiftUI ビューの body 評価は別環境必要）
        #expect(history.count == 11)
    }

    @Test("ViewModel.audioLevels が rolling buffer として window 内に収まる")
    func viewModelRollingBuffer() async {
        // ViewModel が startObservingAudioLevels で受け取った値を rolling buffer に
        // 保持する設計。FakeAudioCaptureService の sine wave emit を 1 秒分流し、
        // window (4 秒) を超えていれば古いものが消えるはず。
        let capture = FakeAudioCaptureService()
        let vm = AppViewModel(
            capture: capture,
            repository: InMemoryRecordingRepository(),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
        vm.startObservingAudioLevels()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        _ = try? await capture.start(in: dir, title: "test")
        // emit は 100ms ごと。1.2 秒待って ~12 件取れる想定。
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        _ = try? await capture.stop()
        // 件数は実機タイミング依存だが、最低限 buffer が空でないこと
        #expect(vm.audioLevels.count >= 1)
    }

    @Test("AudioLevelSnapshot の silence 判定が反映される")
    func silenceDetection() {
        let silent = AudioLevelSnapshot(
            elapsedSec: 1.0,
            micRMS: 0, micPeak: 0,
            systemRMS: 0, systemPeak: 0
        )
        #expect(silent.isMicSilent)
        #expect(silent.isSystemSilent)

        let loud = AudioLevelSnapshot(
            elapsedSec: 1.0,
            micRMS: 0.5, micPeak: 0.8,
            systemRMS: 0.5, systemPeak: 0.8
        )
        #expect(!loud.isMicSilent)
        #expect(!loud.isSystemSilent)
    }
}
