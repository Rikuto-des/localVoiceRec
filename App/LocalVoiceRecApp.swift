import SwiftUI
import Contracts
import AppUI
import AudioCapture
import DataStore
import TranscriptionKit
import SummaryKit

/// `localVoiceRec` のメニューバー常駐アプリ。
///
/// このファイルは `.app` バンドル用の `.xcodeproj` から参照される想定。
/// SwiftPM の `swift build` では実行ファイル化しない（MenuBarExtra + Info.plist 制約のため）。
@main
struct LocalVoiceRecApp: App {
    private let capture: any AudioCaptureService
    private let repository: any RecordingRepository
    private let transcription: any TranscriptionService
    private let summary: any SummaryService

    init() {
        // ─── S3 統合: 実装サービスへ配線 ───
        let capture = AudioCaptureModule.makeService()
        let repository: any RecordingRepository
        do {
            repository = try DataStoreModule.makeRepository()
        } catch {
            // Repository の初期化失敗は致命的。フォールバックで InMemory に逃がしてアプリは起動する
            // （UI 上で「ストア利用不可」を見せる方が監査しやすい）
            assertionFailure("DataStoreModule.makeRepository failed: \(error)")
            repository = InMemoryRecordingRepository()
        }
        let transcription = TranscriptionKitModule.makeService()
        // SummaryKit は S4 で実装予定。それまでは Mock。
        let summary: any SummaryService = FakeSummaryService()

        self.capture = capture
        self.repository = repository
        self.transcription = transcription
        self.summary = summary

        // prewarm を fire-and-forget で起動
        Task.detached { await capture.prewarm() }
        Task.detached { await repository.prewarm() }
        Task.detached { await summary.prewarm() }
        // TranscriptionService.prewarm は locale が必要で throws するため、UI 操作起点に委ねる
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
