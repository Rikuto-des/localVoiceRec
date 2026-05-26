import SwiftUI
import Contracts
import AppUI

/// `localVoiceRec` のメニューバー常駐アプリ。
///
/// このファイルは `.app` バンドル用の `.xcodeproj` から参照される想定。
/// SwiftPM の `swift build` では実行ファイル化しない（MenuBarExtra + Info.plist 制約のため）。
///
/// S0 時点では Mock で起動し、S2 以降に実装サービスへ差し替える。
@main
struct LocalVoiceRecApp: App {
    private let capture: any AudioCaptureService
    private let repository: any RecordingRepository
    private let transcription: any TranscriptionService
    private let summary: any SummaryService

    init() {
        // ─── S0: 全部 Mock ───
        // S2 以降: AudioCaptureModule / DataStoreModule / TranscriptionKitModule / SummaryKitModule
        //           の実装に差し替える
        let capture = FakeAudioCaptureService()
        let repository = InMemoryRecordingRepository()
        let transcription = FakeTranscriptionService()
        let summary = FakeSummaryService()
        self.capture = capture
        self.repository = repository
        self.transcription = transcription
        self.summary = summary

        // prewarm を fire-and-forget で起動
        Task.detached { await capture.prewarm() }
        Task.detached { await repository.prewarm() }
        Task.detached { await summary.prewarm() }
    }

    var body: some Scene {
        MainScene(
            capture: capture,
            repository: repository,
            transcription: transcription,
            summary: summary
        )
    }
}
