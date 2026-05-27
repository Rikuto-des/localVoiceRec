import Foundation
import Testing
import Contracts
import AudioTapKit
@testable import AudioCapture

/// AudioCaptureServiceImpl の軽い動作確認。
///
/// ハードウェアが繋がっていない CI / sandbox では `start()` 自体は失敗しうる。
/// ここでは **状態遷移と初期状態の API 契約** のみを確認し、
/// 実機統合テスト (start → 録音 → stop) は S3 verify フェーズで行う。
@Suite("AudioCaptureServiceImpl")
struct AudioCaptureServiceImplTests {

    @Test("初期状態は idle")
    func initialStateIsIdle() async {
        let svc = AudioCaptureServiceImpl()
        let state = await svc.currentState
        #expect(state == .idle)
    }

    @Test("stateUpdates は購読時に現在状態を yield する")
    func stateUpdatesReplaysCurrent() async {
        let svc = AudioCaptureServiceImpl()
        var iterator = svc.stateUpdates.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .idle)
    }

    @Test("stop を idle 状態で呼ぶと notRecording")
    func stopWhenIdleThrows() async {
        let svc = AudioCaptureServiceImpl()
        await #expect(throws: AudioCaptureError.notRecording) {
            _ = try await svc.stop()
        }
    }

    @Test("pause を idle 状態で呼ぶと notRecording")
    func pauseWhenIdleThrows() async {
        let svc = AudioCaptureServiceImpl()
        await #expect(throws: AudioCaptureError.notRecording) {
            try await svc.pause()
        }
    }

    @Test("resume を idle 状態で呼ぶと notRecording")
    func resumeWhenIdleThrows() async {
        let svc = AudioCaptureServiceImpl()
        await #expect(throws: AudioCaptureError.notRecording) {
            try await svc.resume()
        }
    }

    @Test("prewarm は no-op で完了する")
    func prewarmDoesNotThrow() async {
        let svc = AudioCaptureServiceImpl()
        await svc.prewarm()
        let state = await svc.currentState
        #expect(state == .idle)
    }

    @Test("AudioTapError → AudioCaptureError の翻訳")
    func errorTranslation() {
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.tapCreationFailed(-1))
                == .processTapCreateFailed(status: -1)
        )
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.aggregateDeviceCreationFailed(-2))
                == .aggregateDeviceCreateFailed(status: -2)
        )
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.engineStartFailed("boom"))
                == .engineStartFailed(message: "boom")
        )
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.alreadyRunning)
                == .alreadyRecording
        )
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.notRunning)
                == .notRecording
        )
        #expect(
            AudioCaptureServiceImpl.translate(AudioTapError.fileCreationFailed("oops"))
                == .fileWriteFailed(message: "oops")
        )
        // pass-through: AudioCaptureError をそのまま受けても元の値を返す
        #expect(
            AudioCaptureServiceImpl.translate(AudioCaptureError.notRecording)
                == .notRecording
        )
    }

    @Test("AudioCaptureModule.makeService は AudioCaptureService を返す")
    func factoryReturnsService() async {
        let svc: any AudioCaptureService = AudioCaptureModule.makeService()
        let state = await svc.currentState
        #expect(state == .idle)
    }
}

// MARK: - SystemAudioCaptureFlag (S15)

@Suite("SystemAudioCaptureFlag", .serialized)
struct SystemAudioCaptureFlagTests {

    /// 各テスト用の隔離 UserDefaults を作って store にセットする。
    private func withIsolatedStore(_ body: () -> Void) {
        let suite = "SystemAudioCaptureFlagTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prior = SystemAudioCaptureFlag.store
        SystemAudioCaptureFlag.store = defaults
        defer {
            SystemAudioCaptureFlag.store = prior
            defaults.removePersistentDomain(forName: suite)
        }
        body()
    }

    @Test("初期状態は false")
    func defaultIsFalse() {
        withIsolatedStore {
            #expect(SystemAudioCaptureFlag.everCaptured() == false)
        }
    }

    @Test("markCaptured で true になる")
    func markFlipsToTrue() {
        withIsolatedStore {
            SystemAudioCaptureFlag.markCaptured()
            #expect(SystemAudioCaptureFlag.everCaptured() == true)
        }
    }

    @Test("reset で false に戻る")
    func resetReturnsToFalse() {
        withIsolatedStore {
            SystemAudioCaptureFlag.markCaptured()
            SystemAudioCaptureFlag.reset()
            #expect(SystemAudioCaptureFlag.everCaptured() == false)
        }
    }

    @Test("authorizationStatus は everCaptured=true で systemAudio=.authorized を返す")
    func authorizationReflectsFlag() async {
        // 隔離 store を一時的に差し替え
        let suite = "SystemAudioCaptureFlagTests.auth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let prior = SystemAudioCaptureFlag.store
        SystemAudioCaptureFlag.store = defaults
        defer {
            SystemAudioCaptureFlag.store = prior
            defaults.removePersistentDomain(forName: suite)
        }

        let svc = AudioCaptureServiceImpl()
        let before = await svc.authorizationStatus()
        #expect(before.systemAudio == .notDetermined)

        SystemAudioCaptureFlag.markCaptured()
        let after = await svc.authorizationStatus()
        #expect(after.systemAudio == .authorized)
    }
}
