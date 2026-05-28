import Foundation
import AVFAudio

/// `AVAudioFile` 薄ラップの可逆音声ファイルライタ。
///
/// - 出力は **Linear PCM (WAV)** に固定。可逆・非圧縮で Float32/Int16/Int32 いずれも書ける。
/// - スレッドセーフではない。**writer ごとに 1 つのライタースレッドのみが書き込む** こと。
public final class WAVFileWriter {

    public enum Format: Sendable {
        /// 線形 PCM (WAV)。
        case wav

        /// このフォーマットに適切なファイル拡張子。
        public var fileExtension: String {
            switch self {
            case .wav: return "wav"
            }
        }
    }

    private let file: AVAudioFile
    public let format: AVAudioFormat

    /// - Parameters:
    ///   - url: 書き出し先 URL。拡張子は `.wav`。
    ///   - format: 入力バッファの `AVAudioFormat`。サンプルレート / チャンネル数を引き継ぐ。
    /// - Throws: ``AudioTapError/fileCreationFailed(_:)``
    public init(
        url: URL,
        format: AVAudioFormat
    ) throws {
        // Linear PCM (WAV) 設定。format.settings を起点に明示上書き。
        var settings: [String: Any] = format.settings
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
