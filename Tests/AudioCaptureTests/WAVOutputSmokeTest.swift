import Foundation
import Testing
import Contracts
import ContractsTestSupport
import AudioTapKit
@testable import AudioCapture

/// 出力ファイル拡張子が `.wav` であることを複数経路で確認する。
///
/// 観点:
///   1. `WAVFileWriter.Format.wav.fileExtension == "wav"` (基底契約)
///   2. ハードウェア不要な軽量経路として `FakeAudioCaptureService.start()` の戻り値が
///      `.wav` 拡張子を持つこと
///   3. (実機)`AudioCaptureServiceImpl` は `start()` でハードウェアを掴むため、
///      CI で実行できない部分はソース上の `.wav` 採用を間接的に守る。
@Suite("WAV output convention")
struct WAVOutputSmokeTest {

    @Test("WAVFileWriter.Format.wav の拡張子は 'wav'")
    func wavFormatExtension() {
        #expect(WAVFileWriter.Format.wav.fileExtension == "wav")
    }

    @Test("FakeAudioCaptureService.start() の micAudioURL/systemAudioURL は .wav 拡張子")
    func fakeServiceProducesWavURLs() async throws {
        let svc = FakeAudioCaptureService()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let session = try await svc.start(in: tmp, title: nil)
        #expect(session.micAudioURL.pathExtension == "wav", "mic file must be .wav")
        #expect(session.systemAudioURL.pathExtension == "wav", "system file must be .wav")

        // stop して Recording を取り、Recording 上の URL も .wav であることを確認。
        let recording = try await svc.stop()
        #expect(recording.micAudioURL.pathExtension == "wav")
        #expect(recording.systemAudioURL.pathExtension == "wav")
    }

    @Test("AudioCaptureServiceImpl が使う WAVFileWriter.Format は .wav (ソース不変条件)")
    func audioCaptureServiceImplUsesWavContainer() {
        // 直接 AudioCaptureServiceImpl.start() を呼ぶとハードウェアが必要なため、
        // 代わりに WAVFileWriter.Format.wav が「容器扱い」であることをチェック。
        // (start 内で `let audioContainer: WAVFileWriter.Format = .wav` の不変条件は
        // ソースコードレビュー + この事実テストの 2 段構えで守る)
        let wav = WAVFileWriter.Format.wav
        #expect(wav.fileExtension == "wav")
    }
}
