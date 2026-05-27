import Foundation
import Testing
@preconcurrency import AVFoundation
import Speech
import Contracts
@testable import TranscriptionKit

/// `SpeechAnalyzerService` の 0-frame / cancel ライフサイクル検証。
///
/// 重い実音声テストではなく、「ストリームが必ず終わる (= リークしない)」ことだけを保証する。
///
/// **環境依存**: asset 未インストールの場合は `unsupportedLocale` / `assetInstallationFailed`
/// が返るため、その失敗を「正常終了」として許容する (ライフサイクル検証が目的)。
@Suite("SpeechAnalyzerService — cancel / empty input lifecycle")
struct SpeechAnalyzerCancelTests {

    /// 0-frame の WAV (length=0) を作る。
    private static func makeZeroLengthWAV() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroLen-\(UUID().uuidString).wav")
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "test", code: -1) }
        // AVAudioFile を 0 フレームで作って即 close (ARC drop)。
        // 結果として header だけの WAV が残る。
        var settings = fmt.settings
        settings[AVLinearPCMIsNonInterleaved] = !fmt.isInterleaved
        settings[AVNumberOfChannelsKey] = Int(fmt.channelCount)
        settings[AVSampleRateKey] = fmt.sampleRate
        _ = try AVAudioFile(
            forWriting: tmp,
            settings: settings,
            commonFormat: fmt.commonFormat,
            interleaved: fmt.isInterleaved
        )
        return tmp
    }

    @Test("length=0 の WAV: transcribe が例外なし or 環境例外で確実に終わる")
    func transcribeOnEmptyFile() async throws {
        let mic = try Self.makeZeroLengthWAV()
        let system = try Self.makeZeroLengthWAV()
        defer {
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: system)
        }

        let svc = SpeechAnalyzerService()
        let recording = Recording(
            title: "empty",
            startedAt: Date(),
            endedAt: Date(),
            micAudioURL: mic,
            systemAudioURL: system
        )

        // 一定時間で終わることだけ保証 (= 無限にブロックしない)。
        // 60s: asset 初回 DL の余裕値 (SpeechAnalyzerLiveTests と同じ)。
        let stream = svc.transcribe(recording: recording, locale: Locale(identifier: "en-US"))

        let timeoutTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return false
        }
        let finishTask = Task<Bool, Never> {
            var count = 0
            do {
                for try await _ in stream {
                    count += 1
                }
            } catch {
                // 環境依存の TranscriptionError は許容 (= 確実に終わる)
            }
            // 0-frame 入力では実質 segment が出ないか、即 finalize される。
            // count >= 0 は trivially true なので「stream が止まった」事実だけ確認。
            return true
        }
        let result = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await finishTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result == true, "transcribe on empty file did not finish within timeout")
    }

    @Test("transcribe ストリーム for-await 中に外側 Task を cancel しても確実に終わる")
    func cancelMidStreamStopsAnalyzer() async throws {
        let mic = try Self.makeZeroLengthWAV()
        let system = try Self.makeZeroLengthWAV()
        defer {
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: system)
        }
        let svc = SpeechAnalyzerService()
        let recording = Recording(
            title: "cancel",
            startedAt: Date(),
            endedAt: Date(),
            micAudioURL: mic,
            systemAudioURL: system
        )

        // 別 Task で for-await を回し、開始直後にキャンセル。
        let consumer = Task<Bool, Never> {
            let stream = svc.transcribe(recording: recording, locale: Locale(identifier: "en-US"))
            do {
                for try await _ in stream {
                    if Task.isCancelled { break }
                }
                return true  // 正常 finish
            } catch {
                // CancellationError / TranscriptionError.cancelled / asset 失敗いずれも OK
                return true
            }
        }
        // ごく短い遅延の後 cancel (stream 開始してから cancel が伝わるように)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        consumer.cancel()

        // 一定時間で必ず終わること (リーク防止)
        let timeoutTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            return false
        }
        let result = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await consumer.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result == true, "cancelled transcribe stream did not terminate within timeout")

        // cancelAll を呼んでも安全
        await svc.cancelAll()
    }
}
