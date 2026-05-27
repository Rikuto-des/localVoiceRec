import Foundation
import AVFAudio
import AudioToolbox

/// `AVAudioFile` 薄ラップの可逆音声ファイルライタ。
///
/// - 既定形式は **ALAC (Apple Lossless) を m4a コンテナで保存**。
///   PCM (WAV) 比でファイルサイズが 50-70% 削減され、可逆圧縮なので品質劣化なし。
/// - `Format.wav` を指定すれば従来の線形 PCM (WAV) で書き出すことも可能
///   (デバッグ用途や互換用、推奨は ALAC)。
/// - スレッドセーフではない。**writer ごとに 1 つのライタースレッドのみが書き込む** こと。
///
/// ## 注意
/// 型名は歴史的経緯で `WAVFileWriter` のままだが、実体は WAV 限定ではない。
/// 将来的に `LosslessAudioFileWriter` 等にリネーム可能。
public final class WAVFileWriter {

    public enum Format: Sendable {
        /// Apple Lossless (ALAC) を m4a コンテナで保存。既定。
        case alac
        /// 線形 PCM (WAV)。レガシー・互換性のため残置。
        case wav

        /// このフォーマットに適切なファイル拡張子。
        public var fileExtension: String {
            switch self {
            case .alac: return "m4a"
            case .wav:  return "wav"
            }
        }
    }

    private let file: AVAudioFile
    public let format: AVAudioFormat
    public let containerFormat: Format

    /// - Parameters:
    ///   - url: 書き出し先 URL。拡張子は `Format.fileExtension` に合わせること
    ///     (ALAC → `.m4a`, WAV → `.wav`)。
    ///   - format: 入力バッファの `AVAudioFormat`。サンプルレート / チャンネル数を引き継ぐ。
    ///   - containerFormat: 出力ファイルの形式。既定は `.alac`。
    /// - Throws: ``AudioTapError/fileCreationFailed(_:)``
    public init(
        url: URL,
        format: AVAudioFormat,
        containerFormat: Format = .alac
    ) throws {
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        switch containerFormat {
        case .alac:
            // ALAC は固定品質。bit depth は AVAudioFile が内部で input format から決める。
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
        case .wav:
            // 既存の WAV 互換挙動。format.settings を起点に明示上書き。
            settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = !format.isInterleaved
            settings[AVNumberOfChannelsKey] = Int(format.channelCount)
            settings[AVSampleRateKey] = format.sampleRate
        }

        do {
            self.file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            self.format = format
            self.containerFormat = containerFormat
        } catch {
            throw AudioTapError.fileCreationFailed(
                "url=\(url.path) container=\(containerFormat) err=\(error.localizedDescription)"
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
