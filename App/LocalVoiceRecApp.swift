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
        let repository: any RecordingRepository
        do {
            repository = try DataStoreModule.makeRepository()
        } catch {
            // Repository の初期化失敗は致命的。書き込み不可な専用 repository に逃がし、
            // UI 上で「録音不可 / ストア利用不可」を確認可能な状態にする。
            // 旧実装の InMemoryRecordingRepository フォールバックは本番バイナリに
            // Mock コードを残してしまうため、AppUI 内の UnavailableRecordingRepository に差し替え。
            assertionFailure("DataStoreModule.makeRepository failed: \(error)")
            repository = UnavailableRecordingRepository()
        }
        let transcription = TranscriptionKitModule.makeService()
        let capture = AudioCaptureModule.makeService()
        let summary = SummaryKitModule.makeService()

        self.capture = capture
        self.repository = repository
        self.transcription = transcription
        self.summary = summary

        // SpeechAnalyzer の asset を起動時に prewarm。失敗してもベストエフォート。
        // (録音操作の初回レイテンシを下げる)
        if let analyzer = transcription as? SpeechAnalyzerService {
            Task.detached {
                let locale = Locale.current
                try? await analyzer.installAsset(for: locale)
            }
        }

        // 初回起動でマイク権限プロンプトを早めに出す（録音前にユーザーに気付かせる）
        // notDetermined のときだけ要求。authorized/denied なら no-op。
        Task.detached {
            let status = await capture.authorizationStatus()
            if status.microphone == .notDetermined {
                _ = await capture.requestAuthorization()
            }
        }
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
