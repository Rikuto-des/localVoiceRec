import Foundation
import AVFAudio

/// `AVAudioFile` 薄ラップの WAV ファイルライタ。
///
/// - フォーマットはコンストラクタで指定された `AVAudioFormat` をそのまま採用
///   (`AVAudioFile` の `commonFormat` 推論を避けるため、`settings` から明示的に作成)。
/// - キャプチャ format をそのまま保存することで再変換による品質劣化を避ける。
/// - スレッドセーフではない。**writer ごとに 1 つのライタースレッドのみが書き込む** こと。
public final class WAVFileWriter {

    private let file: AVAudioFile
    public let format: AVAudioFormat

    /// - Parameters:
    ///   - url: 書き出し先 (`.wav`)
    ///   - format: 入力バッファの `AVAudioFormat`。**ファイル形式もこれに合わせる**。
    /// - Throws: ``AudioTapError/fileCreationFailed(_:)``
    public init(url: URL, format: AVAudioFormat) throws {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = !format.isInterleaved
        settings[AVNumberOfChannelsKey] = Int(format.channelCount)
        settings[AVSampleRateKey] = format.sampleRate

        do {
            self.file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            self.format = format
        } catch {
            throw AudioTapError.fileCreationFailed(
                "url=\(url.path) err=\(error.localizedDescription)"
            )
        }
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }

    /// `AVAudioFile` は ARC 解放時に flush + close する。明示処理は不要。
    /// シーケンスポイント用に空メソッドを残す。
    public func close() { }

    /// これまでに書き込んだフレーム数 (`AVAudioFile.length` ベース)。
    public var framesWritten: AVAudioFramePosition { file.length }
}
