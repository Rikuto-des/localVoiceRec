import SwiftUI
import Contracts

/// アプリ全体のメニューバーシーン。
/// 各サービスをプロトコル経由で受け取り、UI からは Mock / 実装の差し替えが可能。
///
/// **S2-C で UI Specialist が中身を拡張します。** S0 では最小の MenuBarExtra スケルトンのみ。
public struct MainScene: Scene {
    public let capture: any AudioCaptureService
    public let repository: any RecordingRepository
    public let transcription: any TranscriptionService
    public let summary: any SummaryService

    public init(
        capture: any AudioCaptureService,
        repository: any RecordingRepository,
        transcription: any TranscriptionService,
        summary: any SummaryService
    ) {
        self.capture = capture
        self.repository = repository
        self.transcription = transcription
        self.summary = summary
    }

    public var body: some Scene {
        MenuBarExtra("localVoiceRec", systemImage: "mic.fill") {
            MenuBarContentView(
                capture: capture,
                repository: repository,
                transcription: transcription,
                summary: summary
            )
        }
        .menuBarExtraStyle(.window)
    }
}
