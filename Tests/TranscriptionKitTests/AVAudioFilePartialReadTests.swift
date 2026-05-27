import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import TranscriptionKit

/// S8 で修正した `feedAudioFile` の partial-read 安全化に対する **回帰テスト**。
///
/// 背景:
/// - `AVAudioFile.read(into:)` (引数なし) は capacity 単位で読み続けると、
///   ファイル末尾の残量 < capacity の partial read で **nilError を返すケース** が
///   あり、Speech 入力経路で `analyzerFailed(message:)` を引き起こしていた。
/// - 修正は「残量を `audioFile.length - framePosition` から計算し、
///   `read(into:, frameCount: toRead)` で明示的に渡す」というもの。
///
/// このテストは:
/// 1. テスト一時ディレクトリに PoC と同じ形式 (Float32 / 2ch / 48 kHz / interleaved)
///    の WAV を `AVAudioFile(forWriting:)` で作る。長さは capacity の倍数で **割り切れない**
///    値にして、必ず末尾に partial read が発生する状態にする。
/// 2. `SpeechAnalyzerService.feedAudioFile` と同じロジックで全フレームを読み切れることを
///    assert する（フレーム合計が書き込み時と一致 / 例外なし）。
///
/// 補足:
/// - `feedAudioFile` は `private static` で外から呼べないため、**同じロジックを
///   再現したヘルパ (readAllFrames) を本テスト内に保持** している。
///   将来 `SpeechAnalyzerService` 側に internal な共有ヘルパが切り出されれば、
///   そちらに置き換えてよい。
@Suite("AVAudioFile partial read — S8 regression")
struct AVAudioFilePartialReadTests {

    /// PoC 互換: 2ch / 48 kHz / Float32 / interleaved。
    private static func makePoCLikeFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
    }

    /// 指定 frame 数の Float32 / interleaved バッファに低周波サイン波を満たす。
    private static func fillSineWave(buffer: AVAudioPCMBuffer, startFrame: AVAudioFramePosition) {
        guard let data = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        let freq = 440.0
        for f in 0..<frameCount {
            let t = Double(startFrame + AVAudioFramePosition(f)) / sampleRate
            let v = Float(sin(2.0 * .pi * freq * t)) * 0.1
            if buffer.format.isInterleaved {
                // interleaved: channel 0 のポインタに [frame*channels + ch] で格納
                let p = data[0]
                for ch in 0..<channels {
                    p[f * channels + ch] = v
                }
            } else {
                for ch in 0..<channels {
                    data[ch][f] = v
                }
            }
        }
    }

    /// テスト用 WAV を一時ディレクトリに作って URL を返す。
    /// totalFrames は capacity (48000/2 = 24000) で割り切れない値にすること。
    private static func writeFixtureWAV(
        url: URL,
        totalFrames: AVAudioFrameCount
    ) throws {
        let fmt = makePoCLikeFormat()
        // AVAudioFile はデフォルトで CAF / WAV を拡張子から推定する。.wav を指定。
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
                throw NSError(domain: "test", code: -1)
            }
            buf.frameLength = toWrite
            fillSineWave(buffer: buf, startFrame: AVAudioFramePosition(written))
            try file.write(from: buf)
            written += toWrite
        }
    }

    /// `SpeechAnalyzerService.feedAudioFile` と同じ partial-read ロジックの再現。
    /// 全フレームを読み切るまで callback で frame 数を渡す。
    @discardableResult
    private static func readAllFrames(url: URL) throws -> AVAudioFramePosition {
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat

        let readFrameCapacity: AVAudioFrameCount = AVAudioFrameCount(
            max(1024, Int(inputFormat.sampleRate / 2))
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: readFrameCapacity
        ) else {
            throw NSError(domain: "test", code: -2)
        }

        var totalRead: AVAudioFramePosition = 0
        while true {
            let remaining = audioFile.length - audioFile.framePosition
            if remaining <= 0 { break }
            let toRead = AVAudioFrameCount(min(Int64(readFrameCapacity), remaining))
            buffer.frameLength = 0
            try audioFile.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            totalRead += AVAudioFramePosition(buffer.frameLength)
        }
        return totalRead
    }

    @Test("末尾 partial read でも nilError を出さず全フレーム読める")
    func partialReadAtEOFSucceeds() throws {
        // capacity = max(1024, 24000) = 24000。これで割り切れない frame 長を選ぶ。
        // 例: 100_123 frames → 24000 * 4 = 96000 + 4123 (partial)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localVoiceRec-partialRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("fixture.wav")
        let totalFrames: AVAudioFrameCount = 100_123
        try Self.writeFixtureWAV(url: url, totalFrames: totalFrames)

        // 書き出した frame 数を `AVAudioFile(forReading:).length` から確認
        let probe = try AVAudioFile(forReading: url)
        #expect(probe.length == AVAudioFramePosition(totalFrames))

        // partial-read ロジックで読み切れること
        let total = try Self.readAllFrames(url: url)
        #expect(total == AVAudioFramePosition(totalFrames))
    }

    @Test("ちょうど capacity 倍数のサイズでも EOF で正常に止まる")
    func exactCapacityMultipleStops() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localVoiceRec-partialRead-exact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("fixture-exact.wav")
        // capacity = 24000、ちょうど 2 倍
        let totalFrames: AVAudioFrameCount = 48_000
        try Self.writeFixtureWAV(url: url, totalFrames: totalFrames)

        let total = try Self.readAllFrames(url: url)
        #expect(total == AVAudioFramePosition(totalFrames))
    }

    @Test("capacity 未満のサイズでも 1 回の partial read で完了する")
    func smallerThanCapacityCompletes() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localVoiceRec-partialRead-small-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("fixture-small.wav")
        // capacity = 24000 より小さく、partial read が最初の 1 回で発生
        let totalFrames: AVAudioFrameCount = 5_000
        try Self.writeFixtureWAV(url: url, totalFrames: totalFrames)

        let total = try Self.readAllFrames(url: url)
        #expect(total == AVAudioFramePosition(totalFrames))
    }
}
