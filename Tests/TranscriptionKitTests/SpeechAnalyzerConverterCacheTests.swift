import Foundation
import Testing
@preconcurrency import AVFoundation
import Speech
@testable import TranscriptionKit

/// P4.3 で導入した `AVAudioConverter` のキャッシュ + `reset()` 戦略の回帰テスト。
///
/// 旧実装はイテレーションごとに `AVAudioConverter` / 出力 `AVAudioPCMBuffer` /
/// `ConverterFeedState` を alloc しており、バッテリー最小化と矛盾していた。
/// P4.3 ではループ外で 1 度だけ確保し、各 chunk 開始前に `converter.reset()` /
/// `feedState.reset()` / `outBuffer.frameLength = 0` で再利用する。
///
/// 旧バグ（「最初の "あ" だけ認識される」= 2 つ目以降の chunk が無音/歪み）が
/// 再発しないかを **複数 chunk + sample-rate conversion** の条件で検証する。
@Suite("SpeechAnalyzerService converter cache — P4.3 regression")
struct SpeechAnalyzerConverterCacheTests {

    /// 48 kHz Float32 / 2ch / interleaved の WAV を一時ディレクトリに作る。
    /// 内容は 440 Hz サイン波。`SpeechAnalyzer` を介さず、純粋に
    /// `feedAudioFile` が複数 chunk を正しく変換できるかを確認する。
    private static func writeSine48kStereoWAV(
        url: URL,
        totalFrames: AVAudioFrameCount
    ) throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            throw NSError(domain: "test", code: -1)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: fmt.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

        let chunk: AVAudioFrameCount = 4096
        var written: AVAudioFrameCount = 0
        while written < totalFrames {
            let toWrite = min(chunk, totalFrames - written)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: toWrite) else {
                throw NSError(domain: "test", code: -2)
            }
            buf.frameLength = toWrite
            if let data = buf.floatChannelData {
                let p = data[0]
                let channels = Int(fmt.channelCount)
                for f in 0..<Int(toWrite) {
                    let t = Double(Int(written) + f) / 48_000.0
                    let v = Float(sin(2.0 * .pi * 440.0 * t)) * 0.1
                    for ch in 0..<channels {
                        p[f * channels + ch] = v
                    }
                }
            }
            try file.write(from: buf)
            written += toWrite
        }
    }

    /// 平均パワー (mean square root) を計算。RMS が 0 ≒ 無音。
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var sum: Double = 0
        var count = 0
        if buffer.format.isInterleaved, let data = buffer.floatChannelData {
            let p = data[0]
            for i in 0..<(frameLength * channels) {
                let v = Double(p[i])
                sum += v * v
                count += 1
            }
        } else if let data = buffer.floatChannelData {
            for ch in 0..<channels {
                let p = data[ch]
                for i in 0..<frameLength {
                    let v = Double(p[i])
                    sum += v * v
                    count += 1
                }
            }
        }
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
    }

    @Test("複数 chunk + sample-rate conversion で全 chunk が無音にならない (旧 'あ' バグ非再発)")
    func multipleChunksWithSRCProduceNonSilentOutput() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localVoiceRec-converterCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("sine-48k.wav")
        // readFrameCapacity = max(1024, 48000/2) = 24000。
        // 100_000 frames → 24000 * 4 + 4000 → **5 chunk** (内 1 つは partial)
        // 旧バグ条件: chunk #2 以降が無音/歪みになる。
        let totalFrames: AVAudioFrameCount = 100_000
        try Self.writeSine48kStereoWAV(url: url, totalFrames: totalFrames)

        // 16 kHz mono に sample-rate + channel 変換させて、毎 chunk で converter を働かせる。
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            Issue.record("Failed to make target format")
            return
        }

        let audioFile = try AVAudioFile(forReading: url)
        let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // 別 Task で feed し、メイン側で消費する。
        let feedTask = Task<Void, Error> {
            defer { builder.finish() }
            try SpeechAnalyzerService.feedAudioFile(
                audioFile: audioFile,
                targetFormat: targetFormat,
                inputBuilder: builder
            )
        }

        var chunkRMS: [Float] = []
        var totalOutFrames: AVAudioFramePosition = 0
        for await input in stream {
            let buf = input.buffer
            #expect(buf.format.sampleRate == 16_000)
            #expect(buf.format.channelCount == 1)
            totalOutFrames += AVAudioFramePosition(buf.frameLength)
            chunkRMS.append(Self.rms(buf))
        }
        try await feedTask.value

        // chunk が 2 個以上 yield されていること（multi-chunk であることを保証）
        #expect(chunkRMS.count >= 2, "Expected multiple chunks, got \(chunkRMS.count)")

        // **全 chunk** が非無音であること（旧バグでは chunk #2 以降が ≒0 になっていた）
        // 0.001 は十分小さい閾値（信号は ±0.1 振幅サイン波なので RMS ≒ 0.07）。
        for (i, r) in chunkRMS.enumerated() {
            #expect(r > 0.001, "Chunk #\(i) RMS=\(r) is silent — converter reset regression?")
        }

        // 出力フレーム数 ≒ totalFrames * (16000/48000) = 33_333、誤差 ±数百を許容。
        let expected = Int(Double(totalFrames) * 16_000.0 / 48_000.0)
        let diff = abs(Int(totalOutFrames) - expected)
        #expect(diff < 1000, "Total out frames \(totalOutFrames) too far from expected \(expected)")
    }

    @Test("同一 format (変換不要) でも複数 chunk が正常に流れる")
    func multipleChunksWithoutConversion() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localVoiceRec-converterCache-noop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("sine-48k-noop.wav")
        let totalFrames: AVAudioFrameCount = 60_000
        try Self.writeSine48kStereoWAV(url: url, totalFrames: totalFrames)

        let audioFile = try AVAudioFile(forReading: url)
        // targetFormat = nil → inputFormat = outputFormat → 変換パス off
        let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feedTask = Task<Void, Error> {
            defer { builder.finish() }
            try SpeechAnalyzerService.feedAudioFile(
                audioFile: audioFile,
                targetFormat: nil,
                inputBuilder: builder
            )
        }

        var totalFramesOut: AVAudioFramePosition = 0
        var count = 0
        for await input in stream {
            totalFramesOut += AVAudioFramePosition(input.buffer.frameLength)
            count += 1
        }
        try await feedTask.value

        #expect(count >= 2)
        #expect(totalFramesOut == AVAudioFramePosition(totalFrames))
    }
}
