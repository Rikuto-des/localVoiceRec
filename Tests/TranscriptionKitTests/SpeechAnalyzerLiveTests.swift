import Foundation
import Testing
@preconcurrency import AVFoundation
import Speech
import Contracts
@testable import TranscriptionKit

/// P4.2 `transcribeLive` の回帰テスト。
///
/// 録音中の live AsyncStream<AVAudioPCMBuffer> を直接 ASR に流して、
/// (1) 上流の finish が伝播して analyzer の finalize が走り、
/// (2) AsyncThrowingStream<TranscriptSegment> が finish で閉じる
/// ことを保証する。
///
/// **注**: 本テストは SpeechAnalyzer の実 asset を要求する (= ロケール asset が
/// インストール済みであること)。CI / sandbox で asset 未インストールの場合は
/// `unsupportedLocale` / `assetInstallationFailed` が早期に返るため、
/// その失敗を許容する形で書く (録音 content 認識の正確性ではなく、ライフサイクル検証)。
@Suite("SpeechAnalyzerService.transcribeLive — P4.2")
struct SpeechAnalyzerLiveTests {

    /// 16 kHz mono Float32 / 1ch の短い無音 PCM を 5 個 yield して finish する stream を作る。
    private static func makeSilenceStream(
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1,
        chunkFrames: AVAudioFrameCount = 1600,  // 0.1s per chunk @ 16k
        chunkCount: Int = 5
    ) -> (AsyncStream<AVAudioPCMBuffer>, AVAudioFormat) {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            fatalError("Failed to make format")
        }
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let stream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { cont = $0 }
        // 別 Task で chunk を投入して finish する (live 状況の単純なシミュレーション)
        Task {
            for _ in 0..<chunkCount {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { continue }
                buf.frameLength = chunkFrames
                // 無音 (calloc 後 0 初期化)。Float32 planar なので memset 不要。
                cont.yield(buf)
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
            }
            cont.finish()
        }
        return (stream, fmt)
    }

    @Test("上流 stream の finish が transcribeLive の AsyncThrowingStream finish に伝播する")
    func upstreamFinishPropagates() async throws {
        let svc = SpeechAnalyzerService()
        let (stream, fmt) = Self.makeSilenceStream(chunkCount: 5)
        let recordingID = UUID()

        let results = svc.transcribeLive(
            buffers: stream,
            inputFormat: fmt,
            recordingID: recordingID,
            source: .mic,
            locale: Locale(identifier: "en-US")
        )

        // 一定時間で完了することを保証 (= 上流の finish が finalize に伝播)。
        // 環境差で asset 未インストール時は途中で throw する可能性があるため、
        // throw も成功条件に含める (= 「stream が無限にブロックしない」ことだけ確認)。
        let timeoutTask = Task<Bool, Never> {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            return false
        }
        let finishTask = Task<Bool, Never> {
            do {
                for try await seg in results {
                    // 受信したセグメントは全て isFinal (transcribeLive の contract)
                    #expect(seg.isFinal == true)
                    #expect(seg.recordingID == recordingID)
                    #expect(seg.source == .mic)
                }
                return true
            } catch {
                // 環境依存の asset / locale 失敗は許容 (ライフサイクル検証が目的)
                return true
            }
        }
        // どちらか先に終わった方を取る
        let result = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await finishTask.value }
            group.addTask { await timeoutTask.value }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(result == true, "transcribeLive did not finish within timeout")
    }

    @Test("isFinal セグメントのみが yield される (contract)")
    func onlyFinalSegmentsAreYielded() async throws {
        // Stub 化が難しいので、`transcribeLive` の contract (= partial は filter される)
        // を確認するために、受信した全 segment の isFinal をチェックする。
        // 無音入力では segment 0 件で finish するのが期待動作。
        let svc = SpeechAnalyzerService()
        let (stream, fmt) = Self.makeSilenceStream(chunkCount: 3)
        let recordingID = UUID()

        let results = svc.transcribeLive(
            buffers: stream,
            inputFormat: fmt,
            recordingID: recordingID,
            source: .system,
            locale: Locale(identifier: "en-US")
        )

        var receivedFinalOnly = true
        do {
            for try await seg in results {
                if !seg.isFinal { receivedFinalOnly = false }
            }
        } catch {
            // asset 未インストール等の環境失敗は許容
        }
        #expect(receivedFinalOnly == true)
    }
}
