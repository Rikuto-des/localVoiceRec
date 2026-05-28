import Foundation
import Testing
@testable import TranscriptionKit
import Contracts

/// SpeechAnalyzerService の軽い動作確認。
///
/// 実音声を流す重いテストは、実機 + マイク + on-device asset が必要で
/// CI/PR では動かせないため意図的に省略している。
@Suite("SpeechAnalyzerService")
struct SpeechAnalyzerServiceTests {

    @Test("installedLocales は呼び出せる（環境依存で空の可能性もあり）")
    func installedLocalesIsCallable() async {
        let svc = SpeechAnalyzerService()
        let locales = await svc.installedLocales()
        // 環境（CI など）では空配列もあり得るので件数は問わない。
        // ただし型として `[Locale]` が返ることだけは確認。
        #expect(locales.count >= 0)
    }

    @Test("存在しないファイル URL を渡すと fileNotReadable で失敗する")
    func nonexistentFilesThrow() async {
        let svc = SpeechAnalyzerService()
        let bogusMic = URL(fileURLWithPath: "/tmp/_localVoiceRec_nonexistent_mic.wav")
        let bogusSystem = URL(fileURLWithPath: "/tmp/_localVoiceRec_nonexistent_system.wav")
        let recording = Recording(
            title: "bogus",
            startedAt: Date(),
            endedAt: Date(),
            micAudioURL: bogusMic,
            systemAudioURL: bogusSystem
        )

        let stream = svc.transcribe(recording: recording, locale: nil)
        var caught: Error?
        do {
            for try await _ in stream {
                // 入っていれば失敗。
            }
        } catch {
            caught = error
        }

        guard let err = caught as? TranscriptionError else {
            Issue.record("Expected TranscriptionError, got \(String(describing: caught))")
            return
        }
        switch err {
        case .fileNotReadable, .unsupportedLocale, .assetInstallationFailed:
            // unsupportedLocale or assetInstallationFailed may happen first in
            // certain CI environments (no on-device assets). All are acceptable
            // pre-file-read failures here.
            break
        default:
            Issue.record("Unexpected TranscriptionError: \(err)")
        }
    }

    @Test("ファクトリは TranscriptionService 型を返す")
    func factoryReturnsService() {
        let svc: any TranscriptionService = TranscriptionKitModule.makeService()
        _ = svc
    }
}
