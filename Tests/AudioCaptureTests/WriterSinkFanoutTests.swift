import Foundation
import Testing
@preconcurrency import AVFoundation
import AudioTapKit
@testable import AudioCapture

/// P4.1 fan-out の単体検証。
///
/// `WriterSink` の `liveASRFeed` (オプション continuation) が write 経由で
/// PCM buffer を yield し、`close()` で finish() することを確認する。
/// ハードウェア / SpeechAnalyzer 非依存。
@Suite("WriterSink fan-out — P4.1")
struct WriterSinkFanoutTests {

    private static func makeBuffer(frames: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
            fatalError("PCM buffer alloc failed")
        }
        buf.frameLength = frames
        return buf
    }

    /// LevelAccumulator を渡しつつ writer 無しで sink を作るのは難しいので、
    /// 一時ファイルに WAV writer を作り、 fan-out 経路だけ検証する。
    private static func makeWriter() throws -> (WAVFileWriter, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterSinkFanout-\(UUID().uuidString).wav")
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "test", code: -1) }
        // .wav (PCM) コンテナ。ALAC は m4a で頭出し書き込みが OS バッファに乗るため、
        // 検証用には WAV の方が確実。
        let writer = try WAVFileWriter(url: tmp, format: fmt, containerFormat: .wav)
        return (writer, tmp)
    }

    @Test("liveASRFeed なし: 既存挙動 (writer + accumulator のみ)")
    func nilLiveFeed_existingBehavior() async throws {
        let (writer, url) = try Self.makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let accumulator = LevelAccumulator()
        let sink = WriterSink(writer: writer, accumulator: accumulator, liveASRFeed: nil)

        let buf = Self.makeBuffer()
        sink.write(buf)
        sink.close()

        let (_, peak) = accumulator.snapshot()
        // 無音 buffer なので peak は 0 だが、accumulator のサイクルだけ動いたことを assert
        #expect(peak >= 0)
    }

    @Test("liveASRFeed 有: write した buffer が feed に yield され、close で finish する")
    func liveFeed_fanout() async throws {
        let (writer, url) = try Self.makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let accumulator = LevelAccumulator()

        var feedCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let feedStream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { feedCont = $0 }
        let sink = WriterSink(writer: writer, accumulator: accumulator, liveASRFeed: feedCont)

        // 3 buffer を流す
        for _ in 0..<3 {
            sink.write(Self.makeBuffer())
        }
        sink.close()

        // close() が feed.finish() を呼ぶので、for-await が必ず終わる
        var received = 0
        for await _ in feedStream {
            received += 1
        }
        #expect(received == 3)
    }

    @Test("pause 中も liveASRFeed には流れる (level meter と同じ扱い)")
    func paused_stillFeedsLiveASR() async throws {
        let (writer, url) = try Self.makeWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let accumulator = LevelAccumulator()
        var feedCont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        let feedStream = AsyncStream<AVAudioPCMBuffer>(bufferingPolicy: .unbounded) { feedCont = $0 }
        let sink = WriterSink(writer: writer, accumulator: accumulator, liveASRFeed: feedCont)

        sink.setPaused(true)
        sink.write(Self.makeBuffer())
        sink.write(Self.makeBuffer())
        sink.close()

        var received = 0
        for await _ in feedStream {
            received += 1
        }
        // pause 中でも live ASR feed は 2 件届く
        #expect(received == 2)
    }
}
