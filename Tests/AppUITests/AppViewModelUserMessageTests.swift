import Foundation
import Testing
@testable import AppUI
import Contracts
import ContractsTestSupport

/// `AppViewModel.userMessage(for:context:)` の全 enum case 網羅写像テスト。
///
/// 観点:
/// - `AudioCaptureError` / `TranscriptionError` / `SummaryError` / `RepositoryError`
///   それぞれの全 case が **case 名を表に出さず**、ユーザーに actionable な
///   日本語メッセージへ変換されること。
/// - 未対応の任意 Error は汎用フォールバックに落ちること。
@MainActor
@Suite("AppViewModel — userMessage mapping")
struct AppViewModelUserMessageTests {

    private func makeViewModel() -> AppViewModel {
        AppViewModel(
            capture: FakeAudioCaptureService(),
            repository: InMemoryRecordingRepository(),
            transcription: FakeTranscriptionService(),
            summary: FakeSummaryService()
        )
    }

    /// メッセージに enum case の生の名前 (camelCase) を含まないことを確認する補助。
    private func expectNoRawCaseName(_ message: String, _ rawCases: [String]) {
        for raw in rawCases {
            #expect(!message.contains(raw),
                    "メッセージに enum case 名 '\(raw)' が漏れている: \(message)")
        }
    }

    // MARK: - AudioCaptureError

    @Test("AudioCaptureError 全 case が日本語メッセージに写像される")
    func audioCaptureErrorMapping() {
        let vm = makeViewModel()
        let cases: [AudioCaptureError] = [
            .microphonePermissionDenied,
            .systemAudioPermissionDenied,
            .engineStartFailed(message: "engine X"),
            .processTapCreateFailed(status: -1),
            .aggregateDeviceCreateFailed(status: -2),
            .alreadyRecording,
            .notRecording,
            .fileWriteFailed(message: "disk"),
            .outputDirectoryUnavailable(URL(fileURLWithPath: "/tmp/x")),
            .diskWriteFailure(failureCount: 7),
        ]
        for err in cases {
            let msg = vm.userMessage(for: err, context: "test")
            #expect(!msg.isEmpty)
            expectNoRawCaseName(msg, [
                "microphonePermissionDenied",
                "systemAudioPermissionDenied",
                "engineStartFailed",
                "processTapCreateFailed",
                "aggregateDeviceCreateFailed",
                "alreadyRecording",
                "notRecording",
                "fileWriteFailed",
                "outputDirectoryUnavailable",
                "diskWriteFailure",
            ])
        }
    }

    @Test("マイク権限拒否は『システム設定』への誘導文を含む")
    func micDeniedMentionsSettings() {
        let vm = makeViewModel()
        let msg = vm.userMessage(for: AudioCaptureError.microphonePermissionDenied, context: "")
        #expect(msg.contains("マイク"))
        #expect(msg.contains("システム設定"))
    }

    @Test("画面収録権限拒否は『画面収録 / システムオーディオ』への言及を含む")
    func systemAudioDeniedMentionsScreenRecording() {
        let vm = makeViewModel()
        let msg = vm.userMessage(for: AudioCaptureError.systemAudioPermissionDenied, context: "")
        #expect(msg.contains("画面"))
    }

    @Test("diskWriteFailure は failureCount を含む")
    func diskWriteFailureIncludesCount() {
        let vm = makeViewModel()
        let msg = vm.userMessage(for: AudioCaptureError.diskWriteFailure(failureCount: 12), context: "")
        #expect(msg.contains("12"))
    }

    // MARK: - TranscriptionError

    @Test("TranscriptionError 全 case が日本語メッセージに写像される")
    func transcriptionErrorMapping() {
        let vm = makeViewModel()
        let cases: [TranscriptionError] = [
            .unsupportedLocale(identifier: "xx-YY"),
            .assetInstallationFailed(message: "net"),
            .analyzerFailed(message: "oom"),
            .fileNotReadable(URL(fileURLWithPath: "/tmp/missing.wav")),
            .cancelled,
        ]
        for err in cases {
            let msg = vm.userMessage(for: err, context: "transcribe")
            #expect(!msg.isEmpty)
            expectNoRawCaseName(msg, [
                "unsupportedLocale",
                "assetInstallationFailed",
                "analyzerFailed",
                "fileNotReadable",
                "cancelled",
            ])
        }
    }

    // MARK: - SummaryError

    @Test("SummaryError 全 case が日本語メッセージに写像される")
    func summaryErrorMapping() {
        let vm = makeViewModel()
        let cases: [SummaryError] = [
            .notAvailable(reason: .deviceNotEligible),
            .generationFailed(message: "x"),
            .contextWindowExceeded,
            .cancelled,
            .decodingFailed(message: "y"),
        ]
        for err in cases {
            let msg = vm.userMessage(for: err, context: "summary")
            #expect(!msg.isEmpty)
            expectNoRawCaseName(msg, [
                "notAvailable",
                "generationFailed",
                "contextWindowExceeded",
                "cancelled",
                "decodingFailed",
            ])
        }
    }

    // MARK: - RepositoryError

    @Test("RepositoryError 全 case が日本語メッセージに写像される")
    func repositoryErrorMapping() {
        let vm = makeViewModel()
        let cases: [RepositoryError] = [
            .notFound(UUID()),
            .ioFailed(message: "disk"),
            .storeUnavailable,
            .fileDeletionFailed(URL(fileURLWithPath: "/tmp/x"), message: "perm"),
        ]
        for err in cases {
            let msg = vm.userMessage(for: err, context: "repo")
            #expect(!msg.isEmpty)
            expectNoRawCaseName(msg, [
                "notFound",
                "ioFailed",
                "storeUnavailable",
                "fileDeletionFailed",
            ])
        }
    }

    // MARK: - Fallback

    private struct UnknownTestError: Error {}

    @Test("未対応の Error は汎用フォールバック文に落ちる")
    func unknownErrorFallback() {
        let vm = makeViewModel()
        let msg = vm.userMessage(for: UnknownTestError(), context: "x")
        #expect(msg.contains("予期しないエラー") || msg.contains("再起動"))
    }
}
