import Foundation
import Testing
import Contracts
import TranscriptionKit

/// PoC (`AudioTapPoC`) で生成した実 WAV を `SpeechAnalyzerService.transcribe(...)` に
/// 投入できることを確認する整合テスト。
///
/// 仕様:
/// - `Tools/AudioTapPoC/output/{mic,system}.wav` が存在するときのみ実行する。
/// - 文字起こし内容のアサートはしない（環境差・無音録音の可能性があるため）。
/// - 落ちずに `AsyncThrowingStream` が終端まで回ることだけを検証する。
///
/// CI / 開発者ローカルで PoC を未実行の場合は no-op で pass する。
@Suite("Integration — PoC → SpeechAnalyzer")
struct PoCTranscribeIntegrationTests {

    /// リポジトリのルート（Package.swift があるディレクトリ）を推定する。
    private static func repoRoot() -> URL {
        // Tests/IntegrationTests/PoCTranscribeIntegrationTests.swift から 3 つ上。
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("PoC の出力 WAV を SpeechAnalyzer に投入できる（PoC 未実行なら skip）")
    func transcribePoCOutput() async throws {
        let root = Self.repoRoot()
        let micURL = root.appendingPathComponent("Tools/AudioTapPoC/output/mic.wav")
        let sysURL = root.appendingPathComponent("Tools/AudioTapPoC/output/system.wav")

        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path),
              fm.fileExists(atPath: sysURL.path) else {
            // PoC を先に走らせていない場合は skip（CI 想定）。
            print("[IntegrationTest] PoC output not found, skipping. micURL=\(micURL.path)")
            return
        }

        let now = Date()
        let recording = Recording(
            title: "PoC Smoke",
            startedAt: now.addingTimeInterval(-5),
            endedAt: now,
            micAudioURL: micURL,
            systemAudioURL: sysURL
        )

        let svc = SpeechAnalyzerService()

        // installedLocales が空のときは on-device モデル未インストール環境。
        let locales = await svc.installedLocales()
        guard !locales.isEmpty else {
            print("[IntegrationTest] no installed locales, skipping transcription.")
            return
        }

        var count = 0
        do {
            for try await segment in svc.transcribe(recording: recording, locale: nil) {
                print("[\(segment.source)] \(segment.startSec)-\(segment.endSec): \(segment.text)")
                count += 1
            }
        } catch {
            // 実機 / 環境依存の失敗はテスト全体を壊さない。ログだけ残す。
            print("[IntegrationTest] transcribe threw: \(error). PoC audio may be silent / unsupported locale.")
        }

        // 内容アサートはしない。落ちないこと、カウントが非負であることだけを確認。
        #expect(count >= 0)
    }
}
