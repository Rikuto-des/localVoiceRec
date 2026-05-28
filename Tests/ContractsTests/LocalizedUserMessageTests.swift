import Foundation
import Testing
@testable import Contracts

/// `localizedUserMessage` 拡張の全 case 網羅テスト。
///
/// 観点:
/// - `AudioCaptureError` / `TranscriptionError` / `SummaryError` / `RepositoryError`
///   の各 case について、`localizedUserMessage` が:
///   - 空文字でないこと
///   - 汎用フォールバック ("予期しないエラー") に落ちていないこと
///     (= ちゃんと case 別に固有の actionable 文を返している)
@Suite("Contracts — localizedUserMessage")
struct LocalizedUserMessageTests {

    private let fallbackMarker = "予期しないエラー"

    @Test("AudioCaptureError 全 case で固有メッセージを返す")
    func audioCaptureErrorMessages() {
        let cases: [AudioCaptureError] = [
            .microphonePermissionDenied,
            .systemAudioPermissionDenied,
            .engineStartFailed(message: "engine"),
            .processTapCreateFailed(status: -1),
            .aggregateDeviceCreateFailed(status: -2),
            .alreadyRecording,
            .notRecording,
            .fileWriteFailed(message: "disk"),
            .outputDirectoryUnavailable(URL(fileURLWithPath: "/tmp/x")),
            .diskWriteFailure(failureCount: 5),
        ]
        for err in cases {
            let msg = err.localizedUserMessage
            #expect(!msg.isEmpty, "空メッセージ: \(err)")
            #expect(!msg.contains(fallbackMarker),
                    "汎用フォールバックに落ちている: \(err) → \(msg)")
        }
    }

    @Test("diskWriteFailure は failureCount を文字列に埋め込む")
    func diskWriteFailureIncludesCount() {
        let msg = AudioCaptureError.diskWriteFailure(failureCount: 42).localizedUserMessage
        #expect(msg.contains("42"))
    }

    @Test("TranscriptionError 全 case で固有メッセージを返す")
    func transcriptionErrorMessages() {
        let cases: [TranscriptionError] = [
            .unsupportedLocale(identifier: "xx-YY"),
            .assetInstallationFailed(message: "net"),
            .analyzerFailed(message: "oom"),
            .fileNotReadable(URL(fileURLWithPath: "/tmp/missing.wav")),
            .cancelled,
        ]
        for err in cases {
            let msg = err.localizedUserMessage
            #expect(!msg.isEmpty, "空メッセージ: \(err)")
            #expect(!msg.contains(fallbackMarker),
                    "汎用フォールバックに落ちている: \(err) → \(msg)")
        }
    }

    @Test("SummaryError 全 case で固有メッセージを返す")
    func summaryErrorMessages() {
        let cases: [SummaryError] = [
            .notAvailable(reason: .deviceNotEligible),
            .notAvailable(reason: .appleIntelligenceNotEnabled),
            .notAvailable(reason: .modelNotReady),
            .notAvailable(reason: .unsupportedOS),
            .generationFailed(message: "x"),
            .contextWindowExceeded,
            .cancelled,
            .decodingFailed(message: "y"),
        ]
        for err in cases {
            let msg = err.localizedUserMessage
            #expect(!msg.isEmpty, "空メッセージ: \(err)")
            #expect(!msg.contains(fallbackMarker),
                    "汎用フォールバックに落ちている: \(err) → \(msg)")
        }
    }

    @Test("RepositoryError 全 case で固有メッセージを返す")
    func repositoryErrorMessages() {
        let cases: [RepositoryError] = [
            .notFound(UUID()),
            .ioFailed(message: "disk"),
            .storeUnavailable,
            .fileDeletionFailed(URL(fileURLWithPath: "/tmp/x"), message: "perm"),
        ]
        for err in cases {
            let msg = err.localizedUserMessage
            #expect(!msg.isEmpty, "空メッセージ: \(err)")
            #expect(!msg.contains(fallbackMarker),
                    "汎用フォールバックに落ちている: \(err) → \(msg)")
        }
    }
}
